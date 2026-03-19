#Requires -Version 5.1
# =============================================================================
# Helpers\Common.Targets.ps1  -  Target construction & discovery helpers
# =============================================================================
#
# WHAT BELONGS HERE:
#   Everything that turns raw config rows (from targets.json / Targets.ps1)
#   into fully-hydrated Target objects (Contract D) that the engine can pass
#   to spokes.  Also: writing targets.json from a Targets.ps1 definition file.
#
# WHAT DOES NOT BELONG HERE:
#   Connection testing (probe logic)       -> Checkup.Engine.ps1 (Test-SqlConnection)
#   Spoke invocation or check logic        -> Core.Checkup.ps1 / Checks.*.ps1
#   Finding creation                       -> Helper.Shared.ps1 (New-Finding)
#
# CONTRACT D - TARGET OBJECT SCHEMA:
#   Every function here ultimately produces objects conforming to Contract D:
#
#     [pscustomobject]@{
#         SqlInstance  = [string]           # "server" or "server\instance"
#         Description  = [string]           # Human label shown in output
#         Credential   = [PSCredential]     # $null = Windows Integrated auth
#         # (discovery functions add: ComputerName, InstanceName, Port, etc.)
#     }
#
#   Spokes access the target exclusively via Get-SqlConnectionSplat (Helper.Shared.ps1),
#   which extracts SqlInstance and, when present, Credential.
#
# CREDENTIAL MODES:
#   Three mutually-exclusive modes control how credentials are resolved:
#     -SingleCredential  One prompt; same PSCredential applied to every target.
#     -NoCredential      Windows Integrated auth for all targets ($null Credential).
#     (neither)          Per-target or per-CredKey prompts (default).
#
# LOADING:
#   Dot-sourced by Core.Checkup.ps1 immediately after Checkup.Engine.ps1.
#
# REGION MAP:
#   1.  Target construction            - New-TargetObject          (Contract D 1)
#   2.  Explicit target list hydration - Get-ConfiguredTargets     (Contract D 2)
#   3.  Discovery integration          - Get-MergedTargets         (Contract D + E)
#   4.  Targets.ps1 persistence        - Write-TargetsJsonFromPs1  (Config export)
#   5.  Private helpers                - Internal utilities
# =============================================================================


# =============================================================================
#  1. TARGET CONSTRUCTION  (Contract D 1)
# =============================================================================
#region Target construction

function New-TargetObject {
    <#
    .SYNOPSIS
        Construct a single Target object conforming to Contract D.

    .DESCRIPTION
        Combines ComputerName and InstanceName into the canonical SqlInstance
        string that dbatools expects:
          - Default instance (MSSQLSERVER) -> "ComputerName"
          - Named instance                 -> "ComputerName\InstanceName"

        All target builders (Get-ConfiguredTargets, Get-MergedTargets) delegate
        here for final object construction so the SqlInstance derivation logic
        lives in exactly one place.

        Used by: Get-ConfiguredTargets, Get-MergedTargets

    .PARAMETER ComputerName
        NetBIOS name or FQDN of the SQL Server host.

    .PARAMETER InstanceName
        SQL Server instance name. Empty string or 'MSSQLSERVER' indicates the
        default instance.

    .PARAMETER Description
        Human-readable label shown in console output and HTML report.
        Used to distinguish targets when the same host runs multiple instances.

    .PARAMETER Credential
        PSCredential for SQL authentication. $null indicates Windows Integrated
        authentication should be used.

    .EXAMPLE
        New-TargetObject -ComputerName 'SQL01' -InstanceName 'PROD'
        
        Creates target for SQL01\PROD with Windows Integrated auth.

    .EXAMPLE
        $cred = Get-Credential
        New-TargetObject -ComputerName 'SQL02' -InstanceName 'MSSQLSERVER' -Credential $cred
        
        Creates target for default instance on SQL02 with SQL authentication.

    .OUTPUTS
        PSCustomObject with properties: ComputerName, InstanceName, SqlInstance,
        Description, Credential.

    .NOTES
        Contract: D 1 - Target Object Schema
        
        The SqlInstance property is the canonical form used by all dbatools cmdlets.
        Default instance names (blank, 'MSSQLSERVER') are normalized to omit the
        backslash notation for compatibility.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ComputerName,

        [string]$InstanceName = '',

        [string]$Description = '',

        [System.Management.Automation.PSCredential]$Credential = $null
    )

    # Normalize: treat blank or 'MSSQLSERVER' as the default (unnamed) instance.
    $effectiveInstance = if ([string]::IsNullOrWhiteSpace($InstanceName) -or
                             $InstanceName -eq 'MSSQLSERVER') {
        'MSSQLSERVER'
    } else {
        $InstanceName
    }

    # Build the dbatools SqlInstance string.
    $sqlInstance = if ($effectiveInstance -eq 'MSSQLSERVER') {
        $ComputerName
    } else {
        '{0}\{1}' -f $ComputerName, $effectiveInstance
    }

    [pscustomobject]@{
        ComputerName = $ComputerName
        InstanceName = $effectiveInstance
        SqlInstance  = $sqlInstance
        Description  = $Description
        Credential   = $Credential
    }
}

#endregion


# =============================================================================
#  2. EXPLICIT TARGET LIST HYDRATION
# =============================================================================
#region Configured targets

function Get-ConfiguredTargets {
    <#
    .SYNOPSIS
        Hydrate an array of raw config rows into Contract D Target objects,
        resolving credentials according to the active credential mode.

    .DESCRIPTION
        Reads the raw JSON rows from targets.json (each row has ComputerName,
        InstanceName, Description, and optionally CredKey) and:

          -SingleCredential  Prompts once. All targets share that credential.
          -NoCredential      No prompt. Credential = $null on every target.
          (neither)          Per-row: if CredKey is set, re-uses a previously
                             prompted credential for the same key; otherwise
                             prompts individually for each target.

        Rows with a blank or absent ComputerName are warned and skipped rather
        than throwing, so a single bad row does not abort target loading.

        Used by: Core.Checkup.ps1 (when discovery is disabled), Get-MergedTargets

    .PARAMETER RawTargets
        Array of raw config objects from targets.json.
        Each object must have at least a ComputerName property.

    .PARAMETER SingleCredential
        Prompt once and apply the resulting PSCredential to every target.
        Mutually exclusive with -NoCredential.

    .PARAMETER NoCredential
        Use Windows Integrated authentication for all targets (Credential = $null).
        Mutually exclusive with -SingleCredential.

    .EXAMPLE
        $raw = Get-Content 'targets.json' | ConvertFrom-Json
        Get-ConfiguredTargets -RawTargets $raw -NoCredential
        
        Load targets with Windows Integrated auth for all instances.

    .EXAMPLE
        Get-ConfiguredTargets -RawTargets $raw -SingleCredential
        
        Prompt once for credentials and apply to all targets.

    .OUTPUTS
        [object[]] Contract D Target objects with properties: ComputerName,
        InstanceName, SqlInstance, Description, Credential.

    .NOTES
        Contract: D 2 - Target List Loading
        
        The CredKey property in raw config rows is used only in default mode
        (neither -SingleCredential nor -NoCredential). It allows grouping
        multiple targets that share the same credential without repeated prompts.
        
        Credential prompts use Get-Credential, which respects the current
        execution policy and may fall back to console prompts in non-interactive
        environments.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [object[]]$RawTargets,

        [switch]$SingleCredential,

        [switch]$NoCredential
    )

    if ($SingleCredential -and $NoCredential) {
        throw 'Get-ConfiguredTargets: use either -SingleCredential or -NoCredential, not both.'
    }

    $targets   = @()
    $credCache = @{}   # CredKey -> PSCredential (used in default per-key mode only)

    # Prompt once if using a single shared credential.
    $sharedCred = if ($SingleCredential) {
        Get-Credential -Message 'Enter SQL Server credentials to use for ALL targets in this run'
    } else { $null }

    foreach ($row in $RawTargets) {

        # Extract string fields defensively - older PS5.1 deserializers may give
        # PSNoteProperty objects rather than plain strings.
        $cn   = Get-RowString $row 'ComputerName'
        $inst = Get-RowString $row 'InstanceName'
        $desc = Get-RowString $row 'Description'
        $key  = Get-RowString $row 'CredKey'

        if ([string]::IsNullOrWhiteSpace($cn)) {
            Write-Warning "Skipping target row with empty ComputerName: $($row | ConvertTo-Json -Compress)"
            continue
        }

        $cred = if ($NoCredential) {
            $null
        } elseif ($SingleCredential) {
            $sharedCred
        } elseif (-not [string]::IsNullOrWhiteSpace($key)) {
            # Re-use a previously prompted credential for this CredKey grouping.
            if (-not $credCache.ContainsKey($key)) {
                $credCache[$key] = Get-Credential -Message ("Enter SQL Server credentials for CredKey '{0}'" -f $key)
            }
            $credCache[$key]
        } else {
            # Individual prompt per target.
            $targetLabel = if (-not [string]::IsNullOrWhiteSpace($inst) -and $inst -ne 'MSSQLSERVER') {
                '{0}\{1}' -f $cn, $inst
            } else {
                $cn
            }
            Get-Credential -Message ("Enter SQL Server credentials for {0}" -f $targetLabel)
        }

        $targets += New-TargetObject -ComputerName $cn -InstanceName $inst `
                                     -Description $desc -Credential $cred
    }

    return $targets
}

#endregion


# =============================================================================
#  3. DISCOVERY INTEGRATION
# =============================================================================
#region Merged / discovered targets

function Get-MergedTargets {
    <#
    .SYNOPSIS
        Build Contract D Target objects by merging the explicit target list with
        instances discovered via Find-DbaInstance on the same hosts.

    .DESCRIPTION
        Step 1 - Build configured targets via Get-ConfiguredTargets.
        Step 2 - For each unique host, run Find-DbaInstance to enumerate instances.
        Step 3 - Merge: configured targets that match a discovered instance get the
                 discovery metadata (Port, Availability, Confidence, ScanTypes)
                 grafted onto them.
        Step 4 - When -AlsoDiscover is set, any instance found by discovery that
                 is NOT in the configured list is appended automatically (with a
                 placeholder description and the host's credential re-used).

        Discovery failures per host are caught and logged but do not abort the
        overall target loading process.

        Used by: Core.Checkup.ps1 (when discovery is enabled)

    .PARAMETER RawTargets
        Raw target config rows (same format as Get-ConfiguredTargets).

    .PARAMETER SingleCredential
        Passed through to Get-ConfiguredTargets.

    .PARAMETER NoCredential
        Passed through to Get-ConfiguredTargets.

    .PARAMETER AlsoDiscover
        When set, auto-discovered instances not in the explicit list are appended
        to the result with a standard placeholder description and the host's
        credential re-used.

    .EXAMPLE
        $raw = Get-Content 'targets.json' | ConvertFrom-Json
        Get-MergedTargets -RawTargets $raw -NoCredential -AlsoDiscover
        
        Discover all instances on configured hosts and include unlisted instances.

    .OUTPUTS
        [object[]] Merged Contract D Target objects with discovery metadata:
        ComputerName, InstanceName, SqlInstance, Port, Availability, Confidence,
        ScanTypes, Description, Credential.

    .NOTES
        Contract: D 3 - Target Discovery
        Contract: E - Discovery Integration
        
        Find-DbaInstance is best-effort - failures per host are caught and produce
        an empty discovery result for that host (configured targets are unaffected).
        
        Discovery metadata columns (Port, Availability, etc.) are only populated
        when discovery succeeds. Configured targets without a discovery match are
        marked as Availability='Unavailable'.
        
        This function is only called when EnableDiscovery = $true in config.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [object[]]$RawTargets,

        [switch]$SingleCredential,

        [switch]$NoCredential,

        [switch]$AlsoDiscover
    )

    # Step 1: Hydrate configured targets.
    $gcParams = @{ RawTargets = $RawTargets }
    if ($SingleCredential) { $gcParams.SingleCredential = $true }
    elseif ($NoCredential) { $gcParams.NoCredential     = $true }

    $configured = Get-ConfiguredTargets @gcParams
    if ($null -eq $configured -or ($configured | Measure-Object).Count -eq 0) {
        return @()
    }

    # Step 2: Discover all instances on each unique host.
    # Build a map: "HOSTNAME|INSTANCENAME" (uppercase) -> discovery result row.
    $discoveryMap = @{}
    $byHost = $configured | Group-Object ComputerName
    $discoveryFailures = @()

    foreach ($group in $byHost) {
        $hostName = $group.Name
        try {
            $found = Find-DbaInstance -ComputerName $hostName -Verbose:$false
            
            foreach ($r in $found) {
                $inst = if ($r.PSObject.Properties['InstanceName'] -and $r.InstanceName) {
                    [string]$r.InstanceName
                } else { 'MSSQLSERVER' }

                $mapKey = New-DiscoveryKey -ComputerName $r.ComputerName -InstanceName $inst
                $discoveryMap[$mapKey] = $r
            }
        } catch {
            $discoveryFailures += [pscustomobject]@{
                Host    = $hostName
                Message = $_.Exception.Message
            }
            Write-Warning "[Targets] Find-DbaInstance failed for '$hostName': $($_.Exception.Message)"
        }
    }

    # Log summary of discovery failures if any occurred.
    if ($discoveryFailures.Count -gt 0) {
        Write-Warning "[Targets] Discovery failed for $($discoveryFailures.Count) host(s). Configured targets on these hosts will be marked as unavailable."
    }

    # Step 3: Merge configured targets with their discovery counterparts.
    $merged = @()

    foreach ($t in $configured) {
        $mapKey = New-DiscoveryKey -ComputerName $t.ComputerName -InstanceName $t.InstanceName

        if ($discoveryMap.ContainsKey($mapKey)) {
            # Discovery hit - enrich with metadata.
            $r = $discoveryMap[$mapKey]
            $merged += [pscustomobject]@{
                ComputerName = $t.ComputerName
                InstanceName = $t.InstanceName
                SqlInstance  = (Get-DiscoveryProperty $r 'SqlInstance' $t.SqlInstance)
                Port         = (Get-DiscoveryProperty $r 'Port'         $null)
                Availability = (Get-DiscoveryProperty $r 'Availability' 'Unknown')
                Confidence   = (Get-DiscoveryProperty $r 'Confidence'   'Unknown')
                ScanTypes    = (Get-DiscoveryProperty $r 'ScanTypes'    'Explicit')
                Description  = $t.Description
                Credential   = $t.Credential
            }
        } else {
            # No discovery hit - use configured values and mark as unavailable.
            $merged += [pscustomobject]@{
                ComputerName = $t.ComputerName
                InstanceName = $t.InstanceName
                SqlInstance  = $t.SqlInstance
                Port         = $null
                Availability = 'Unavailable'
                Confidence   = 'None'
                ScanTypes    = 'Explicit'
                Description  = $t.Description
                Credential   = $t.Credential
            }
        }
    }

    # Step 4: Append auto-discovered instances not present in the configured list.
    if ($AlsoDiscover) {

        # Build a host->credential lookup from the already-configured targets so
        # auto-discovered instances on the same host can re-use the same credential.
        $credByHost = @{}
        foreach ($t in $configured) {
            $hostKey = $t.ComputerName.ToUpper()
            if (-not $credByHost.ContainsKey($hostKey)) {
                $credByHost[$hostKey] = $t.Credential
            }
        }

        # Index already-merged targets by their discovery key.
        $existing = @{}
        foreach ($m in $merged) {
            $existing[(New-DiscoveryKey -ComputerName $m.ComputerName -InstanceName $m.InstanceName)] = $true
        }

        foreach ($kv in $discoveryMap.GetEnumerator()) {
            if ($existing.ContainsKey($kv.Key)) { continue }   # already in merged list

            $r    = $kv.Value
            $inst = if ($r.PSObject.Properties['InstanceName'] -and $r.InstanceName) {
                [string]$r.InstanceName
            } else { 'MSSQLSERVER' }

            $sqlInst = if ($r.PSObject.Properties['SqlInstance'] -and $r.SqlInstance) {
                $r.SqlInstance
            } else {
                if ($inst -eq 'MSSQLSERVER') { $r.ComputerName }
                else                          { '{0}\{1}' -f $r.ComputerName, $inst }
            }

            $hostKey   = $r.ComputerName.ToUpper()
            $credReuse = if ($credByHost.ContainsKey($hostKey)) { $credByHost[$hostKey] } else { $null }

            $merged += [pscustomobject]@{
                ComputerName = $r.ComputerName
                InstanceName = $inst
                SqlInstance  = $sqlInst
                Port         = (Get-DiscoveryProperty $r 'Port'         $null)
                Availability = (Get-DiscoveryProperty $r 'Availability' 'Unknown')
                Confidence   = (Get-DiscoveryProperty $r 'Confidence'   'Unknown')
                ScanTypes    = (Get-DiscoveryProperty $r 'ScanTypes'    'Default')
                Description  = 'Auto-discovered instance - add to Targets.ps1 for a meaningful description.'
                Credential   = $credReuse
            }
        }
    }

    $merged | Select-Object ComputerName, InstanceName, SqlInstance, Port,
                            Availability, Confidence, ScanTypes, Description, Credential
}

#endregion


# =============================================================================
#  4. TARGETS.PS1 PERSISTENCE
# =============================================================================
#region Persistence

function Write-TargetsJsonFromPs1 {
    <#
    .SYNOPSIS
        Dot-source a Targets.ps1 definition file and serialize its
        $TargetsConfig array to targets.json.

    .DESCRIPTION
        Targets.ps1 contains a plain PowerShell array ($TargetsConfig) that
        defines the ComputerName, InstanceName, Description, and CredKey for
        each target. This function converts that definition into the flat JSON
        format that Core.Checkup.ps1 and Get-ConfiguredTargets consume.

        The output deliberately omits Credential (a PSCredential cannot be
        serialized to JSON) and stores only CredKey, which is resolved at
        runtime by Get-ConfiguredTargets.

        Used by: Start-SqlHealthSuite.ps1 (initialization path)

    .PARAMETER TargetsPs1Path
        Full path to Targets.ps1. Must define $TargetsConfig at script or
        local scope.

    .PARAMETER ConfigPath
        Output path for targets.json. Parent directory is created if absent.

    .EXAMPLE
        Write-TargetsJsonFromPs1 -TargetsPs1Path '.\Targets.ps1' -ConfigPath '.\Config\targets.json'
        
        Converts Targets.ps1 definition to JSON config file.

    .NOTES
        Contract: D 4 - Target Config Persistence
        
        Only four columns are written to targets.json:
          ComputerName, InstanceName, Description, CredKey.
        
        Credentials are never persisted to disk for security reasons.
        
        If Targets.ps1 defines $TargetsConfig in a way that makes it inaccessible
        (e.g., in a nested scope or function), this will throw an error.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$TargetsPs1Path,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ConfigPath
    )

    if (-not (Test-Path -LiteralPath $TargetsPs1Path)) {
        throw "Targets definition file not found: $TargetsPs1Path"
    }

    # Dot-source in the current scope so $TargetsConfig is accessible.
    . $TargetsPs1Path

    # $TargetsConfig may land in script or local scope depending on how the
    # ps1 was written. Try both.
    $tc = if (Get-Variable -Name TargetsConfig -Scope Script -ErrorAction SilentlyContinue) {
        $script:TargetsConfig
    } elseif (Get-Variable -Name TargetsConfig -Scope Local -ErrorAction SilentlyContinue) {
        $TargetsConfig
    } else { $null }

    if ($null -eq $tc) {
        throw "`$TargetsConfig was not defined in $TargetsPs1Path"
    }

    # Normalize each row to the expected four-column structure.
    $rows = foreach ($r in $tc) {
        [pscustomobject]@{
            ComputerName = [string]$r.ComputerName
            InstanceName = [string]$r.InstanceName
            Description  = [string]$r.Description
            CredKey      = [string]$r.CredKey
        }
    }

    # Ensure parent directory exists.
    $parentDir = Split-Path -Parent $ConfigPath
    if ($parentDir -and -not (Test-Path -LiteralPath $parentDir)) {
        New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
    }

    # Write as UTF-8 without BOM for cross-platform compatibility.
    $json = @($rows) | ConvertTo-Json -Depth 10 -Compress
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($ConfigPath, $json, $utf8)
}

#endregion


# =============================================================================
#  5. PRIVATE HELPERS
# =============================================================================
#region Private helpers

function Get-RowString {
    <#
    .SYNOPSIS
        Safely extract a string-valued property from a raw config row object.

    .DESCRIPTION
        Returns an empty string when the property is absent or null, rather than
        throwing or returning $null. This prevents repeated null checks throughout
        Get-ConfiguredTargets and Get-MergedTargets.

        Necessary because PowerShell 5.1's JSON deserializer may return
        PSNoteProperty objects that don't behave like plain strings in all contexts,
        particularly when accessed via hashtable syntax in older PS versions.

    .PARAMETER Row
        A PSCustomObject or hashtable representing a raw config row.

    .PARAMETER PropertyName
        The property name to extract.

    .EXAMPLE
        $cn = Get-RowString $row 'ComputerName'
        if ($cn) { ... }
        
        Safe extraction without risking $null reference exceptions.

    .NOTES
        Intentionally not exported (no entry in Publish-HealthSuiteFunctions).
        This is an internal helper used only within Common.Targets.ps1.
        
        The function explicitly checks PSObject.Properties to handle both
        hashtables and PSCustomObjects uniformly.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Row,

        [Parameter(Mandatory)]
        [string]$PropertyName
    )

    if ($null -eq $Row) { return '' }

    if ($Row.PSObject.Properties[$PropertyName] -and $Row.$PropertyName) {
        return [string]$Row.$PropertyName
    }
    return ''
}

function New-DiscoveryKey {
    <#
    .SYNOPSIS
        Create a normalized discovery map key from ComputerName and InstanceName.

    .DESCRIPTION
        Generates a case-insensitive key for indexing discovery results.
        Format: "HOSTNAME|INSTANCENAME" (uppercase).

        Centralizes the key generation logic that was duplicated across
        Get-MergedTargets, ensuring consistent behavior when matching
        configured targets to discovered instances.

    .PARAMETER ComputerName
        The SQL Server host name.

    .PARAMETER InstanceName
        The SQL Server instance name.

    .EXAMPLE
        $key = New-DiscoveryKey -ComputerName 'SQL01' -InstanceName 'PROD'
        # Returns: "SQL01|PROD"

    .NOTES
        Intentionally not exported - internal helper.
        
        Keys are uppercase to ensure case-insensitive matching regardless of
        how hostnames are cased in targets.json vs. Find-DbaInstance results.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ComputerName,

        [Parameter(Mandatory)]
        [string]$InstanceName
    )

    return ('{0}|{1}' -f $ComputerName, $InstanceName).ToUpper()
}

function Get-DiscoveryProperty {
    <#
    .SYNOPSIS
        Safely extract a property from a Find-DbaInstance result row.

    .DESCRIPTION
        Returns the property value if it exists and is non-null, otherwise
        returns the specified fallback value. This handles cases where
        Find-DbaInstance may return incomplete metadata depending on the
        discovery method used (registry scan vs. network scan vs. WMI).

    .PARAMETER Row
        A discovery result row from Find-DbaInstance.

    .PARAMETER PropertyName
        The property to extract (e.g., 'Port', 'Availability').

    .PARAMETER Fallback
        Value to return if the property is absent or null.

    .EXAMPLE
        $port = Get-DiscoveryProperty $discoveryRow 'Port' $null
        
        Extract port number or return null if not discovered.

    .NOTES
        Intentionally not exported - internal helper.
        
        Used in Get-MergedTargets to safely hydrate discovery metadata
        without risking null reference exceptions when properties are missing.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Row,

        [Parameter(Mandatory)]
        [string]$PropertyName,

        [object]$Fallback = $null
    )

    if ($null -eq $Row) { return $Fallback }

    if ($Row.PSObject.Properties[$PropertyName] -and $null -ne $Row.$PropertyName) {
        return $Row.$PropertyName
    }
    return $Fallback
}

#endregion