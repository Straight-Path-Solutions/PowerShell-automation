#Requires -Version 5.1
# =============================================================================
# Helpers\Helpers.Host.ps1  -  Host-pack shared helpers
# =============================================================================
#
# WHAT BELONGS HERE:
#   Data transformation functions for host hardware, OS, and privilege data.
#   Normalizes output from Get-DbaComputerSystem, Get-DbaOperatingSystem,
#   Get-DbaPrivilege into consistent hashtable structures.
#
# WHAT DOES NOT BELONG HERE:
#   - Remote execution (WMI queries, PS Remoting) → belongs in spokes
#   - Check logic or threshold evaluation → belongs in spokes
#   - dbatools cmdlet invocation → belongs in spokes
#
# DEPENDENCIES:
#   - Helpers.Shared.ps1 (MUST be dot-sourced before this file)
#
# CONTRACT REFERENCES:
#   - Contract B: Spoke-level data transformations
#
# LOADING:
#   Dot-source this file in Host pack spokes.
#   The engine's Publish-HealthSuiteFunctions promotes all functions to global scope.
#
# REGION MAP:
#   1. Computer system summary  (Get-DbaComputerSystem normalization)
#   2. Operating system summary (Get-DbaOperatingSystem normalization)
#   3. Privilege summary        (Get-DbaPrivilege normalization)
#   4. Utility functions        (ComputerName extraction, DbaSize conversion)
#
# =============================================================================

# =============================================================================
#  1.  COMPUTER SYSTEM SUMMARY
# =============================================================================
#region ComputerSystem

function Get-HostComputerSystemSummary {
    <#
    .SYNOPSIS
        Normalizes Get-DbaComputerSystem output into a standard hashtable.
    
    .DESCRIPTION
        Extracts CPU, RAM, VM status, and reboot status from a single
        Get-DbaComputerSystem row. Returns a hashtable with nullable fields
        for safe consumption by findings logic.
        
        VM detection uses manufacturer/model string matching - this is a
        heuristic, not authoritative. False negatives possible on bare metal
        with generic OEM strings.
        
        PhysicalCores and NumaNodeCount are populated by separate functions
        after additional data collection.
    
    .PARAMETER Row
        Single row object from Get-DbaComputerSystem.
    
    .OUTPUTS
        @{
            LogicalCores     = [int?]    NumberLogicalProcessors
            SocketCount      = [int?]    NumberProcessors (socket count)
            PhysicalCores    = [int?]    Populated by Add-HostPhysicalCoreCount
            IsHyperThreading = [bool?]   IsHyperThreading property
            HtRatio          = [double?] LogicalCores / PhysicalCores
            TotalRamGB       = [double?] TotalPhysicalMemory in GB
            IsVm             = [bool?]   Inferred from Manufacturer/Model
            VmHint           = [string]  Vendor string (VMware, Azure, etc)
            NumaNodeCount    = [int?]    Populated by Add-HostNumaNodeCount
            PendingReboot    = [bool?]   PendingReboot flag
        }
    
    .EXAMPLE
        $sysInfo = Get-DbaComputerSystem -ComputerName SERVER01
        $summary = Get-HostComputerSystemSummary -Row $sysInfo
        
        $summary.LogicalCores  # 16
        $summary.IsVm          # $true
        $summary.VmHint        # "VMware"
    
    .NOTES
        Contract: B 2 - Spoke data transformation
        
        PhysicalCores and HtRatio remain null until Add-HostPhysicalCoreCount
        is called with Win32_Processor CIM data.
        
        Arrays always contain zero or more elements (never null).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object]$Row
    )

    $s = @{
        LogicalCores     = $null
        SocketCount      = $null
        PhysicalCores    = $null   # filled by Add-HostPhysicalCoreCount
        IsHyperThreading = $null
        HtRatio          = $null   # filled after PhysicalCores is known
        TotalRamGB       = $null
        IsVm             = $null
        VmHint           = ''
        NumaNodeCount    = $null   # filled by Add-HostNumaNodeCount
        PendingReboot    = $null
    }

    if ($null -eq $Row) { return $s }

    # Logical processors
    if ($Row.PSObject.Properties['NumberLogicalProcessors'] -and $null -ne $Row.NumberLogicalProcessors) {
        $s.LogicalCores = [int]$Row.NumberLogicalProcessors
    }

    # Socket count
    if ($Row.PSObject.Properties['NumberProcessors'] -and $null -ne $Row.NumberProcessors) {
        $s.SocketCount = [int]$Row.NumberProcessors
    }

    # HyperThreading flag
    if ($Row.PSObject.Properties['IsHyperThreading'] -and $null -ne $Row.IsHyperThreading) {
        $s.IsHyperThreading = [bool]$Row.IsHyperThreading
    }

    # Total RAM
    if ($Row.PSObject.Properties['TotalPhysicalMemory'] -and $null -ne $Row.TotalPhysicalMemory) {
        $s.TotalRamGB = ConvertTo-GigabytesFromDbaSize $Row.TotalPhysicalMemory
    }

    # Pending reboot
    if ($Row.PSObject.Properties['PendingReboot'] -and $null -ne $Row.PendingReboot) {
        $s.PendingReboot = [bool]$Row.PendingReboot
    }

    # VM detection via Manufacturer / Model heuristic
    $mfr   = if ($Row.PSObject.Properties['Manufacturer'] -and $Row.Manufacturer) { [string]$Row.Manufacturer } else { '' }
    $model = if ($Row.PSObject.Properties['Model']        -and $Row.Model)        { [string]$Row.Model        } else { '' }
    $combined = "$mfr $model".ToLowerInvariant()

    # Vendor keyword mapping (key = lowercase match string, value = display name)
    $vmKeywords = @{
        'vmware'                = 'VMware'
        'virtualbox'            = 'VirtualBox'
        'kvm'                   = 'KVM'
        'xen'                   = 'Xen'
        'hyper-v'               = 'Hyper-V'
        'parallels'             = 'Parallels'
        'qemu'                  = 'QEMU'
        'bochs'                 = 'Bochs'
        'amazon ec2'            = 'AWS EC2'
        'google compute'        = 'Google Cloud'
        'microsoft corporation' = 'Azure'        # Azure VMs report this manufacturer
        'innotek'               = 'VirtualBox'   # VirtualBox's manufacturer string
    }

    $matchedKw = $vmKeywords.Keys | Where-Object { $combined -match [regex]::Escape($_) } | Select-Object -First 1

    if ($matchedKw) {
        $s.IsVm   = $true
        $s.VmHint = $vmKeywords[$matchedKw]
    } elseif ($mfr -or $model) {
        # Manufacturer/Model readable but no VM keyword → likely physical
        $s.IsVm   = $false
        $s.VmHint = ''
    }
    # else: both strings empty → IsVm stays $null (indeterminate)

    return $s
}

function Add-HostPhysicalCoreCount {
    <#
    .SYNOPSIS
        Populates PhysicalCores and HtRatio on a computer system summary.
    
    .DESCRIPTION
        Uses Win32_Processor CIM rows (one row per CPU socket) to sum
        NumberOfCores across all sockets. Updates the summary hashtable
        in place.
    
    .PARAMETER Summary
        Hashtable returned by Get-HostComputerSystemSummary.
    
    .PARAMETER Processors
        Array of Win32_Processor CIM objects from Get-CimInstance.
    
    .EXAMPLE
        $cimProcs = Get-CimInstance -ClassName Win32_Processor -ComputerName SERVER01
        Add-HostPhysicalCoreCount -Summary $summary -Processors $cimProcs
        
        # $summary.PhysicalCores now populated
        # $summary.HtRatio now calculated if LogicalCores was already set
    
    .NOTES
        Contract: B 2 - Spoke data transformation
        
        Modifies the $Summary hashtable in place. No return value.
        
        HtRatio calculation requires both LogicalCores and PhysicalCores.
        If LogicalCores is null, HtRatio remains null.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Summary,
        
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Processors
    )

    $totalPhys = 0
    foreach ($p in $Processors) {
        if ($null -eq $p) { continue }
        
        $cores = $null
        if ($p.PSObject.Properties['NumberOfCores'] -and $null -ne $p.NumberOfCores) {
            $cores = [int]$p.NumberOfCores
        }
        if ($null -ne $cores) { $totalPhys += $cores }
    }

    if ($totalPhys -gt 0) {
        $Summary.PhysicalCores = $totalPhys

        if ($null -ne $Summary.LogicalCores -and $Summary.LogicalCores -gt 0) {
            $Summary.HtRatio = [math]::Round([double]$Summary.LogicalCores / $totalPhys, 2)
        }
    }
}

function Get-PhysicalNumaNodeCount {
    <#
    .SYNOPSIS
        Queries Win32_NumaNode to return the authoritative NUMA node count.

    .DESCRIPTION
        Uses the Win32_NumaNode CIM class — the most accurate source for NUMA
        topology — to count physical NUMA nodes on the target host. Updates
        the provided computer system summary hashtable in place.

        This replaces the previous socket-designation heuristic used inline
        in Spoke.Host.ps1 region [03], which could under-count on systems
        where sockets span multiple NUMA nodes.

        Used by: Spoke.Host.ps1 region [03]

    .PARAMETER Summary
        Hashtable returned by Get-HostComputerSystemSummary. NumaNodeCount
        will be set on this object in place.

    .PARAMETER ComputerName
        Target computer name for the CIM query.

    .EXAMPLE
        Get-PhysicalNumaNodeCount -Summary $csSummary -ComputerName 'SQL01'
        $csSummary.NumaNodeCount   # 2

    .NOTES
        Contract: B 2 - Spoke data transformation

        Modifies $Summary in place. No return value.
        Sets NumaNodeCount = $null if the CIM query fails (network, WMI
        unavailable, etc.) so callers can distinguish "not queried" from
        "query failed".

        Win32_NumaNode is available on all Windows Server versions supported
        by SQL Server 2016+. On single-socket systems it returns one node.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Summary,

        [Parameter(Mandatory)]
        [string]$ComputerName
    )

    try {
        $numaNodes = @(Get-CimInstance -ClassName Win32_NumaNode `
                        -ComputerName $ComputerName -ErrorAction Stop)
        $Summary.NumaNodeCount = $numaNodes.Count
    } catch {
        $Summary.NumaNodeCount = $null
    }
}

#endregion

# =============================================================================
#  2.  OPERATING SYSTEM SUMMARY
# =============================================================================
#region OperatingSystem

function Get-HostOsSummary {
    <#
    .SYNOPSIS
        Normalizes Get-DbaOperatingSystem output into a standard hashtable.
    
    .DESCRIPTION
        Extracts OS version, architecture, build number, uptime, and memory
        status from a single Get-DbaOperatingSystem row.
        
        Used by: Spoke.Host.ps1
    
    .PARAMETER Row
        Single row object from Get-DbaOperatingSystem.
    
    .OUTPUTS
        @{
            OsVersion     = [string]   Friendly OS name (e.g. "Windows Server 2019")
            Architecture  = [string]   "x64" or "x86"
            Build         = [int?]     Windows build number (e.g. 17763)
            LastBootTime  = [datetime?] Last boot timestamp
            UptimeDays    = [int?]     Days since last boot
            TotalMemoryGB = [double?]  Total visible memory in GB
            FreeMemoryGB  = [double?]  Free physical memory in GB
        }
    
    .EXAMPLE
        $osInfo = Get-DbaOperatingSystem -ComputerName SERVER01
        $summary = Get-HostOsSummary -Row $osInfo
        
        $summary.OsVersion    # "Windows Server 2019"
        $summary.UptimeDays   # 42
    
    .NOTES
        Contract: B 2 - Spoke data transformation
        
        LastBootTime is converted to local time for display.
        UptimeDays is calculated from UTC to avoid DST issues.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object]$Row
    )

    $s = @{
        OsVersion     = '(unknown)'
        Architecture  = '(unknown)'
        Build         = $null
        LastBootTime  = $null
        UptimeDays    = $null
        TotalMemoryGB = $null
        FreeMemoryGB  = $null
    }

    if ($null -eq $Row) { return $s }

    # Friendly OS name
    if ($Row.PSObject.Properties['OSVersion'] -and $Row.OSVersion) {
        $s.OsVersion = [string]$Row.OSVersion
    }

    # Architecture
    if ($Row.PSObject.Properties['Architecture'] -and $Row.Architecture) {
        $s.Architecture = [string]$Row.Architecture
    }

    # Build number
    if ($Row.PSObject.Properties['Build'] -and $null -ne $Row.Build) {
        try { $s.Build = [int]$Row.Build } catch {}
    }

    # Last boot time → uptime calculation
    if ($Row.PSObject.Properties['LastBootTime'] -and $null -ne $Row.LastBootTime) {
        try {
            $s.LastBootTime = [datetime]$Row.LastBootTime
            $s.UptimeDays   = [int]([datetime]::UtcNow - $s.LastBootTime.ToUniversalTime()).TotalDays
        } catch {}
    }

    # Memory values
    if ($Row.PSObject.Properties['TotalVisibleMemory'] -and $null -ne $Row.TotalVisibleMemory) {
        $s.TotalMemoryGB = ConvertTo-GigabytesFromDbaSize $Row.TotalVisibleMemory
    }

    if ($Row.PSObject.Properties['FreePhysicalMemory'] -and $null -ne $Row.FreePhysicalMemory) {
        $s.FreeMemoryGB = ConvertTo-GigabytesFromDbaSize $Row.FreePhysicalMemory
    }

    return $s
}

#endregion

# =============================================================================
#  3.  PRIVILEGE SUMMARY
# =============================================================================
#region Privilege

function Get-HostPrivilegeSummary {
    <#
    .SYNOPSIS
        Normalizes Get-DbaPrivilege output into a summary hashtable.

    .DESCRIPTION
        Aggregates Lock Pages in Memory (LPIM), Instant File Initialization (IFI),
        Log on as Batch, Log on as Service, and Generate Security Audit privileges
        across all returned accounts.

        Get-DbaPrivilege returns NO rows for accounts with none of the recognised
        privileges. An empty result set is normal.

        Used by: Spoke.Host.ps1 (regions [12], [13], [14])

    .PARAMETER Rows
        Array of objects from Get-DbaPrivilege.

    .OUTPUTS
        @{
            HasLpim       = [bool]     Any account has LockPagesInMemory
            LpimAccounts  = [string[]] Account names with LPIM (guaranteed array)
            HasIfi        = [bool]     Any account has InstantFileInitialization
            IfiAccounts   = [string[]] Account names with IFI (guaranteed array)
            AllPrivileges = [string[]] "Account (TAG,TAG)" inventory strings
            RawRows       = [object[]] Original dbatools row objects (for per-account iteration)
            RawCount      = [int]      Total rows returned
        }

    .EXAMPLE
        $privs   = Get-DbaPrivilege -ComputerName SERVER01
        $summary = Get-HostPrivilegeSummary -Rows $privs

        $summary.HasLpim       # $true
        $summary.LpimAccounts  # @('NT SERVICE\MSSQLSERVER', 'DOMAIN\SqlAdmin')
        $summary.RawRows       # original dbatools objects for detailed iteration

    .NOTES
        Contract: B 2 - Spoke data transformation

        All array fields are guaranteed to be arrays (never null).
        An empty privilege set returns RawCount=0 with all arrays empty.

        RawRows exposes the original row objects so calling code (regions [13]
        and [14] in Spoke.Host.ps1) can iterate per-account property checks
        without re-querying the host. This avoids the previous bug where
        AllPrivileges (formatted strings) was incorrectly iterated as objects.

        AllPrivileges inventory strings cover: LPIM, IFI, Batch, Service,
        SecurityAudit — matching the full set that region [14] reports.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Rows
    )

    $s = @{
        HasLpim       = $false
        LpimAccounts  = @()
        HasIfi        = $false
        IfiAccounts   = @()
        AllPrivileges = @()
        RawRows       = @()
        RawCount      = 0
    }

    $safeRows = @($Rows | Where-Object { $null -ne $_ })
    $s.RawCount = $safeRows.Count
    $s.RawRows  = $safeRows

    if ($s.RawCount -eq 0) { return $s }

    $lpimAccts = [System.Collections.Generic.List[string]]::new()
    $ifiAccts  = [System.Collections.Generic.List[string]]::new()
    $allPrivs  = [System.Collections.Generic.List[string]]::new()

    foreach ($row in $safeRows) {
        $user    = ''
        $hasLpim = $false
        $hasIfi  = $false
        $hasBatch         = $false
        $hasService       = $false
        $hasSecurityAudit = $false

        if ($row.PSObject.Properties['User'] -and $row.User) {
            $user = [string]$row.User
        }
        if ($row.PSObject.Properties['LockPagesInMemory']         -and $row.LockPagesInMemory)         { $hasLpim         = $true }
        if ($row.PSObject.Properties['InstantFileInitialization']  -and $row.InstantFileInitialization) { $hasIfi          = $true }
        if ($row.PSObject.Properties['LogonAsBatch']               -and $row.LogonAsBatch)              { $hasBatch        = $true }
        if ($row.PSObject.Properties['LogonAsService']             -and $row.LogonAsService)            { $hasService      = $true }
        if ($row.PSObject.Properties['GenerateSecurityAudit']      -and $row.GenerateSecurityAudit)     { $hasSecurityAudit = $true }

        if ($hasLpim) { $lpimAccts.Add($user) }
        if ($hasIfi)  { $ifiAccts.Add($user)  }

        # Build compact privilege tag string for inventory display
        $tags = [System.Collections.Generic.List[string]]::new()
        if ($hasLpim)          { $tags.Add('LPIM')          }
        if ($hasIfi)           { $tags.Add('IFI')           }
        if ($hasBatch)         { $tags.Add('Batch')         }
        if ($hasService)       { $tags.Add('Service')       }
        if ($hasSecurityAudit) { $tags.Add('SecurityAudit') }

        if ($user -and $tags.Count -gt 0) {
            $allPrivs.Add("$user ($($tags -join ','))")
        } elseif ($user) {
            $allPrivs.Add($user)
        }
    }

    $s.HasLpim       = $lpimAccts.Count -gt 0
    $s.LpimAccounts  = @($lpimAccts)
    $s.HasIfi        = $ifiAccts.Count -gt 0
    $s.IfiAccounts   = @($ifiAccts)
    $s.AllPrivileges = @($allPrivs)

    return $s
}

#endregion

# =============================================================================
#  4.  UTILITY FUNCTIONS
# =============================================================================
#region Utilities

function Resolve-PrivilegeSid {
    <#
    .SYNOPSIS
        Resolves a Windows SID or account name to a human-readable display name.

    .DESCRIPTION
        Get-DbaPrivilege may return accounts as raw SID strings (e.g. S-1-5-80-...).
        This function translates them to NTAccount display names (DOMAIN\User or
        NT SERVICE\ServiceName) by querying the target computer's security subsystem.

        Falls back gracefully: if translation fails for any reason, the original
        input string is returned unchanged so findings are never empty.

        Used by: Spoke.Host.ps1 (regions [13] and [14])

    .PARAMETER AccountName
        The account name or SID string returned by Get-DbaPrivilege.

    .PARAMETER ComputerName
        Target computer name. Used to resolve SIDs that are local to the host
        (e.g. local service accounts, local groups).

    .PARAMETER Credential
        Optional PSCredential for the remote CIM/WMI call. Pass $null for
        Windows integrated auth.

    .OUTPUTS
        [string] Human-readable account name, or the original input on failure.

    .EXAMPLE
        Resolve-PrivilegeSid -AccountName 'S-1-5-80-3880718306-...' `
                             -ComputerName 'SQL01'
        # Returns: 'NT SERVICE\MSSQLSERVER'

    .NOTES
        Contract: B 4 - Utility / data normalization

        Translation is attempted via [System.Security.Principal.SecurityIdentifier].
        For SIDs that are local to the remote machine (e.g. local service accounts)
        the .Translate() call succeeds because it queries the local SAM on that host
        through the Windows security subsystem - no explicit remoting required.

        If the input is already an NTAccount-style string (contains '\' or starts
        with a letter), it is returned as-is without attempting translation.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$AccountName,

        [Parameter(Mandatory)]
        [string]$ComputerName,

        [AllowNull()]
        [System.Management.Automation.PSCredential]$Credential = $null
    )

    # Empty input - nothing to resolve
    if ([string]::IsNullOrWhiteSpace($AccountName)) { return $AccountName }

    # Already looks like an NTAccount (DOMAIN\User or NT SERVICE\Foo) - return as-is
    if ($AccountName -match '^[^S]' -or $AccountName -match '\\') {
        return $AccountName
    }

    # Attempt SID translation
    try {
        $sid = [System.Security.Principal.SecurityIdentifier]::new($AccountName)
        $ntAccount = $sid.Translate([System.Security.Principal.NTAccount])
        return $ntAccount.Value
    } catch {
        # Translation failed (unknown SID, network error, etc.) - return original
        return $AccountName
    }
}

function Get-HostComputerName {
    <#
    .SYNOPSIS
        Extracts plain computer name from a Target object for WMI/PS Remoting.
    
    .DESCRIPTION
        Returns hostname without instance suffix for use with dbatools
        -ComputerName parameters (Get-DbaComputerSystem, Get-DbaPrivilege, etc).
        
        Prefers Target.ComputerName (set by engine). Falls back to stripping
        instance suffix from Target.SqlInstance.
        
        Used by: All Host pack spokes
    
    .PARAMETER Target
        Target object from the engine (must have SqlInstance property).
    
    .OUTPUTS
        [string] Hostname only (e.g. 'SERVER01' not 'SERVER01\INSTANCE').
    
    .EXAMPLE
        $computerName = Get-HostComputerName -Target $Target
        $sysInfo = Get-DbaComputerSystem -ComputerName $computerName
    
    .NOTES
        Contract: B 2 - Target property extraction
        
        Throws if SqlInstance cannot be parsed to extract a hostname.
        This prevents downstream WMI/PS Remoting failures with better error context.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Target
    )

    # Prefer pre-resolved ComputerName property set by engine
    if ($Target.PSObject.Properties['ComputerName'] -and
        -not [string]::IsNullOrWhiteSpace($Target.ComputerName)) {
        return [string]$Target.ComputerName
    }

    # Fall back: strip instance/port suffix from SqlInstance
    if ($Target.PSObject.Properties['SqlInstance'] -and
        -not [string]::IsNullOrWhiteSpace($Target.SqlInstance)) {
        $raw = [string]$Target.SqlInstance
        # Handle SERVER\INSTANCE and SERVER,PORT forms
        $hostPart = ($raw -split '[\\,]')[0].Trim()
        if ($hostPart) { return $hostPart }
    }

    # Cannot extract computer name - fail explicitly
    throw "Target.SqlInstance '$($Target.SqlInstance)' cannot be parsed to extract a computer name. Expected formats: 'SERVER', 'SERVER\INSTANCE', or 'SERVER,PORT'."
}
function ConvertTo-GigabytesFromDbaSize {
    <#
    .SYNOPSIS
        Converts a DbaSize object to gigabytes with fallback handling.
    
    .DESCRIPTION
        Safely extracts the Gigabyte property from DbaSize objects returned
        by dbatools cmdlets. Falls back to division if .Gigabyte property
        access fails.
        
        Used by: All Host pack summary functions
    
    .PARAMETER DbaSizeValue
        DbaSize object or numeric value from dbatools output.
    
    .OUTPUTS
        [double?] Value in gigabytes rounded to 1 decimal place, or null.
    
    .EXAMPLE
        $ramGB = ConvertTo-GigabytesFromDbaSize $Row.TotalPhysicalMemory
        # 64.0
    
    .EXAMPLE
        $diskGB = ConvertTo-GigabytesFromDbaSize $Drive.Size
        # 500.0
    
    .NOTES
        Contract: B 2 - Data type normalization
        
        Returns null if conversion fails or input is null.
        Rounds to 1 decimal place for consistent display.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object]$DbaSizeValue
    )

    if ($null -eq $DbaSizeValue) { return $null }
    
    try {
        # Try .Gigabyte property first (DbaSize object)
        return [math]::Round([double]$DbaSizeValue.Gigabyte, 1)
    } catch {
        try {
            # Fallback: treat as raw bytes
            return [math]::Round([double]$DbaSizeValue / 1GB, 1)
        } catch {
            return $null
        }
    }
}

#endregion