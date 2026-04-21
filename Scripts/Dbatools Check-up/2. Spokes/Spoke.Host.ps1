#Requires -Version 5.1
<#
.SYNOPSIS
    Spoke.Host.ps1 - Host health checks spoke.

.DESCRIPTION
    Host-level checks for the SQL Server machine:
      - Power plan compliance
      - Pending reboot
      - Domain membership
      - OS version / build compliance
      - OS inventory (name, uptime, RAM)     [info]
      - Virtual machine detection            [info/attention]
      - HyperThreading ratio                 [info]
      - NUMA node count                      [info]
      - Lock Pages in Memory (LPIM)
      - Instant File Initialization (IFI)
      - OS privilege inventory               [info]
      - SQL Firewall Rules inventory         [info]

    All checks emit findings via $Findings ([ref] array) using Invoke-Check.
    Status values: 'pass' | 'attention' | 'fail' | 'info'

.NOTES
    Spoke contract (Contract A):
        param([object]$Target, [hashtable]$Config, [ref]$Findings)

    Catalog: $global:CheckCat_Host in Checkup.Catalog.ps1
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][object]   $Target,
    [Parameter(Mandatory)][hashtable]$Config,
    [Parameter(Mandatory)][ref]      $Findings
)

#region -- [00] Init --------------------------------------------------------
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root '3. Helpers\Helpers.Shared.ps1')
. (Join-Path $root '3. Helpers\Helpers.Host.ps1')

$sql = Get-SqlConnectionSplat -Target $Target
$global:__checkFile = Split-Path -Leaf $PSCommandPath

$spoke = 'Host'
#endregion

#region -- [01] Pack-level enable check -------------------------------------
$packEnabled = Cfg $Config 'Host.Enabled' -Default $true
if (-not [bool]$packEnabled) {
    $Findings.Value += New-Finding `
        -Label    'Host Pack (disabled)' `
        -Category 'Configuration' -Priority 'Low' -Status 'info' `
        -Details  'Host pack disabled by config (Host.Enabled = false).' `
        -Source   'Config' `
        -SpokeFile $spoke
    return
}
#endregion

#region -- [02] Config prefetch ---------------------------------------------
# Define config keys with their types and variable names
$configSpec = @{
    PowerPlanName               = @{ Type = [string]; Var = 'powerPlanName' }
    PowerPlanNonCompliantIsFail = @{ Type = [bool];   Var = 'ppNonCompliantIsFail' }
    PendingRebootIsFail         = @{ Type = [bool];   Var = 'pendingRebootIsFail' }
    RequireDomainMember         = @{ Type = [bool];   Var = 'requireDomainMember' }
    DomainNonMemberIsFail       = @{ Type = [bool];   Var = 'domainNonMemberIsFail' }
    MinOsBuild                  = @{ Type = [int];    Var = 'minOsBuild' }
    OsBuildNonCompliantIsFail   = @{ Type = [bool];   Var = 'osBuildNonCompliantIsFail' }
    WarnIfVirtualMachine        = @{ Type = [bool];   Var = 'warnIfVirtualMachine' }
    RequireLpim                 = @{ Type = [bool];   Var = 'requireLpim' }
    LpimNonCompliantIsFail      = @{ Type = [bool];   Var = 'lpimNonCompliantIsFail' }
    RequireIfi                  = @{ Type = [bool];   Var = 'requireIfi' }
    IfiNonCompliantIsFail       = @{ Type = [bool];   Var = 'ifiNonCompliantIsFail' }
}

# Fetch and validate all config keys in one pass
foreach ($key in $configSpec.Keys) {
    $value = Cfg $Config "Host.$key"
    
    # Check for missing config
    if ($value -is [MissingConfigKey]) {
        $Findings.Value += New-SkipFinding -Key "Host.$key" `
            -CheckLabel "Host pack (missing: Host.$key)" `
            -SpokeFile $spoke
        return
    }
    
    # Cast to typed variable and set in current scope
    $spec = $configSpec[$key]
    Set-Variable -Name $spec.Var -Value ($value -as $spec.Type) -Scope Script
}

# Normalize/validate config values
if ($minOsBuild -lt 0) { $minOsBuild = 0 }  # Clamp to minimum
#endregion

#region -- [03] Data prefetch -----------------------------------------------
$pfToken = Write-FetchProgress -Spoke 'Host' -Start

Register-CheckSection -File $global:__checkFile -Number 3 `
    -Title    'Host - Data prefetch' `
    -Function 'Get-DbaComputerSystem' `
    -Key      'DataPrefetch'

$computerName = Get-HostComputerName -Target $Target

# Power plan - Test-DbaPowerPlan uses -ComputerName + Windows -Credential
$powerPlan = Invoke-DBATools  {
    if ([string]::IsNullOrWhiteSpace($powerPlanName)) {
        Test-DbaPowerPlan -ComputerName $computerName -EnableException
    } else {
        Test-DbaPowerPlan -ComputerName $computerName -PowerPlan $powerPlanName -EnableException
    }
}
if (-not $powerPlan) { $powerPlan = @() }

# Computer system - Get-DbaComputerSystem uses -ComputerName + Windows -Credential
# Properties: NumberLogicalProcessors, NumberProcessors, IsHyperThreading,
#             TotalPhysicalMemory, PendingReboot, Manufacturer, Model
$computerSystem = Invoke-DBATools  { Get-DbaComputerSystem -ComputerName $computerName -EnableException }
if (-not $computerSystem) { $computerSystem = @() }

# Physical core count per socket via CIM (Win32_Processor.NumberOfCores)
# NUMA node count derived from physical socket count
$cimProcessors = $null
try {
    $cimProcessors = @(Get-CimInstance -ClassName Win32_Processor -ComputerName $computerName -ErrorAction Stop)
} catch {
    # CIM query failed - will handle in checks
}

# Domain membership via CIM Win32_ComputerSystem.PartOfDomain
$wmiComputerSystem = $null
try {
    $wmiComputerSystem = Get-CimInstance -ClassName Win32_ComputerSystem -ComputerName $computerName -ErrorAction Stop
} catch {
    # CIM query failed - will handle in checks
}

# OS info - Get-DbaOperatingSystem uses -ComputerName + Windows -Credential
# Properties: OSVersion, Architecture, Build, LastBootTime,
#             TotalVisibleMemory, FreePhysicalMemory
$operatingSystem = Invoke-DBATools  { Get-DbaOperatingSystem -ComputerName $computerName -EnableException }
if (-not $operatingSystem) { $operatingSystem = @() }

# OS privileges (LPIM, IFI) - Get-DbaPrivilege uses -ComputerName + Windows -Credential
# Properties: ComputerName, User, LogonAsBatch, InstantFileInitialization, LockPagesInMemory
# Requires local admin / PS Remoting
$privilegeRows = Invoke-DBATools  { Get-DbaPrivilege -ComputerName $computerName -EnableException }
if (-not $privilegeRows) { $privilegeRows = @() }

# Firewall rules - Get-DbaFirewallRule uses -SqlInstance + -Credential (Windows)
# Properties: DisplayName, Type, Protocol, LocalPort, Program
# Error rows have a non-null .Error property
$firewallRules = $null; $firewallErr = $null
try {
    $fwSplat = @{ SqlInstance = $Target.SqlInstance; Type = 'AllInstance'; EnableException = $true }
    if ($sql.SqlCredential) { $fwSplat['Credential'] = $sql.SqlCredential }
    $firewallRules = @(Get-DbaFirewallRule @fwSplat)
} catch {
    $firewallErr = $_.Exception.Message
}

# --- Pre-compute summaries ---
# Build summary objects once for use across all checks
$csSummary = $null
$osSummary = $null
$privSummary = $null

if ($computerSystem -and $computerSystem.Count -gt 0) {
    $csSummary = Get-HostComputerSystemSummary -Row $computerSystem[0]
    
    # Add physical core count if CIM succeeded
    if ($cimProcessors -and $cimProcessors.Count -gt 0) {
        Add-HostPhysicalCoreCount -Summary $csSummary -Processors $cimProcessors
    }

    # NUMA node count via Win32_NumaNode (authoritative source)
    Get-PhysicalNumaNodeCount -Summary $csSummary -ComputerName $computerName
}


if ($operatingSystem -and $operatingSystem.Count -gt 0) {
    $osSummary = Get-HostOsSummary -Row $operatingSystem[0]
}

if ($privilegeRows -and $privilegeRows.Count -gt 0) {
    $privSummary = Get-HostPrivilegeSummary -Rows $privilegeRows
}

Write-FetchProgress -Token $pfToken -End
#endregion

#region -- [04] Power Plan --------------------------------------------------
Register-CheckSection -File $global:__checkFile -Number 4 `
    -Title    'Host - Power plan compliance' `
    -Function 'Test-DbaPowerPlan' `
    -Key      'PowerPlan'

Invoke-Check -SpokeFile $spoke -CatalogName 'Host' -Function 'Test-DbaPowerPlan' -Key 'PowerPlan' `
    -Target $Target -Config $Config -Findings $Findings -Run {
        param($sql, $t, $cfg)

        if ($powerPlan.Count -eq 0) {
            return @{ 
                Status = 'attention'
                Details = "Test-DbaPowerPlan returned no data for '$computerName' (check WMI connectivity or Windows credentials)."
            }
        }

        $row = $powerPlan[0]
        $active = if ($row.PSObject.Properties['ActivePowerPlan']) { [string]$row.ActivePowerPlan } else { '' }
        $rec = if ($row.PSObject.Properties['RecommendedPowerPlan']) { [string]$row.RecommendedPowerPlan } else { '' }
        $best = if ($row.PSObject.Properties['IsBestPractice']) { [bool]$row.IsBestPractice } else { $false }

        if ($best) {
            return @{ 
                Status = 'pass'
                Details = "Power plan '$active' meets best-practice recommendation ('$rec')."
            }
        }

        $st = if ($ppNonCompliantIsFail) { 'fail' } else { 'attention' }
        return @{ 
            Status = $st
            Details = "Active power plan: '$active'; recommended: '$rec'. Consider switching to High Performance or Balanced configured for maximum processor state."
        }
    }
#endregion

#region -- [05] Pending Reboot ----------------------------------------------
Register-CheckSection -File $global:__checkFile -Number 5 `
    -Title    'Host - Pending reboot' `
    -Function 'Get-DbaComputerSystem' `
    -Key      'PendingReboot'

Invoke-Check -SpokeFile $spoke -CatalogName 'Host' -Function 'Get-DbaComputerSystem' -Key 'PendingReboot' `
    -Target $Target -Config $Config -Findings $Findings -Run {
        param($sql, $t, $cfg)

        if (-not $csSummary) {
            return @{ 
                Status = 'attention'
                Details = "Get-DbaComputerSystem returned no data for '$computerName' (check WMI / Windows credentials)."
            }
        }

        $pr = $csSummary.PendingReboot

        if ($null -eq $pr) {
            return @{ 
                Status = 'attention'
                Details = "PendingReboot property could not be read for '$computerName'."
            }
        }

        if ($pr) {
            $st = if ($pendingRebootIsFail) { 'fail' } else { 'attention' }
            return @{ 
                Status = $st
                Details = 'PendingReboot: True - a reboot is pending. Resolve before performing maintenance or patching.'
            }
        }

        return @{ Status = 'pass'; Details = 'PendingReboot: False.' }
    }
#endregion

#region -- [06] Domain Membership -------------------------------------------
Register-CheckSection -File $global:__checkFile -Number 6 `
    -Title    'Host - Domain membership' `
    -Function 'Get-CimInstance' `
    -Key      'DomainMember'

Invoke-Check -SpokeFile $spoke -CatalogName 'Host' -Function 'Get-CimInstance' -Key 'DomainMember' `
    -Target $Target -Config $Config -Findings $Findings -Run {
        param($sql, $t, $cfg)

        if (-not $wmiComputerSystem) {
            return @{ 
                Status = 'attention'
                Details = "Win32_ComputerSystem CIM query returned no data for '$computerName' (check firewall / WMI access)."
            }
        }

        $isDomain = if ($wmiComputerSystem.PSObject.Properties['PartOfDomain']) {
            [bool]$wmiComputerSystem.PartOfDomain
        } else {
            $null
        }

        if ($null -eq $isDomain) {
            return @{
                Status = 'attention'
                Details = "PartOfDomain property could not be read for '$computerName'."
            }
        }

        if (-not $requireDomainMember) {
            return @{ 
                Status = 'info'
                Details = "Domain membership check not enforced (Host.RequireDomainMember = false). PartOfDomain: $isDomain."
            }
        }

        if ($isDomain) {
            return @{ Status = 'pass'; Details = 'PartOfDomain: True.' }
        }

        $st = if ($domainNonMemberIsFail) { 'fail' } else { 'attention' }
        return @{ 
            Status = $st
            Details = 'PartOfDomain: False - host is not domain-joined. Verify this is intentional (workgroup / standalone SQL).'
        }
    }
#endregion

#region -- [07] OS Version/Build Compliance ---------------------------------
Register-CheckSection -File $global:__checkFile -Number 7 `
    -Title    'Host - OS version/build compliance' `
    -Function 'Get-DbaOperatingSystem' `
    -Key      'OsVersionBuild'

Invoke-Check -SpokeFile $spoke -CatalogName 'Host' -Function 'Get-DbaOperatingSystem' -Key 'OsVersionBuild' `
    -Target $Target -Config $Config -Findings $Findings -Run {
        param($sql, $t, $cfg)

        if (-not $osSummary) {
            return @{ 
                Status = 'attention'
                Details = "Get-DbaOperatingSystem returned no data for '$computerName' (check remoting / WMI / credentials)."
            }
        }

        $buildStr = if ($null -ne $osSummary.Build) { [string]$osSummary.Build } else { '(unknown)' }

        if ($minOsBuild -le 0) {
            return @{ 
                Status = 'info'
                Details = "OS: '$($osSummary.OsVersion)'; Build: $buildStr; Architecture: $($osSummary.Architecture). Minimum build enforcement disabled (Host.MinOsBuild = 0)."
            }
        }

        if ($null -eq $osSummary.Build) {
            return @{ 
                Status = 'attention'
                Details = "OS build number could not be determined for '$computerName'; cannot verify minimum build $minOsBuild."
            }
        }

        if ($osSummary.Build -lt $minOsBuild) {
            $st = if ($osBuildNonCompliantIsFail) { 'fail' } else { 'attention' }
            return @{ 
                Status = $st
                Details = "OS: '$($osSummary.OsVersion)'; Build $($osSummary.Build) is below required minimum $minOsBuild."
            }
        }

        return @{ 
            Status = 'pass'
            Details = "OS: '$($osSummary.OsVersion)'; Build $($osSummary.Build) meets required minimum $minOsBuild."
        }
    }
#endregion

#region -- [08] OS Inventory (Info) -----------------------------------------
Register-CheckSection -File $global:__checkFile -Number 8 `
    -Title    'Host - OS inventory' `
    -Function 'Get-DbaOperatingSystem' `
    -Key      'OsInventory'

Invoke-Check -SpokeFile $spoke -CatalogName 'Host' -Function 'Get-DbaOperatingSystem' -Key 'OsInventory' `
    -Target $Target -Config $Config -Findings $Findings -Run {
        param($sql, $t, $cfg)

        if (-not $osSummary) {
            return @{ 
                Status = 'info'
                Details = "Get-DbaOperatingSystem returned no data for '$computerName'; inventory unavailable."
            }
        }

        $uptime = if ($null -ne $osSummary.UptimeDays) { "$($osSummary.UptimeDays) days" } else { '(unknown)' }
        $totMem = if ($null -ne $osSummary.TotalMemoryGB) { "$($osSummary.TotalMemoryGB) GB" } else { '(unknown)' }
        $freMem = if ($null -ne $osSummary.FreeMemoryGB) { "$($osSummary.FreeMemoryGB) GB" } else { '(unknown)' }
        $buildStr = if ($null -ne $osSummary.Build) { $osSummary.Build } else { '(unknown)' }

        return @{ 
            Status = 'info'
            Details = "OS: '$($osSummary.OsVersion)' ($($osSummary.Architecture)); Build: $buildStr; Uptime: $uptime; RAM: $totMem total / $freMem free."
        }
    }
#endregion

#region -- [09] Virtual Machine Detection -----------------------------------
Register-CheckSection -File $global:__checkFile -Number 9 `
    -Title    'Host - Virtual machine detection' `
    -Function 'Get-DbaComputerSystem' `
    -Key      'VirtualMachine'

Invoke-Check -SpokeFile $spoke -CatalogName 'Host' -Function 'Get-DbaComputerSystem' -Key 'VirtualMachine' `
    -Target $Target -Config $Config -Findings $Findings -Run {
        param($sql, $t, $cfg)

        if (-not $csSummary) {
            return @{ 
                Status = 'info'
                Details = "Get-DbaComputerSystem returned no data for '$computerName'; virtual machine detection skipped."
            }
        }

        $isVm = $csSummary.IsVm
        $hint = $csSummary.VmHint

        if ($null -eq $isVm) {
            return @{ 
                Status = 'info'
                Details = "Virtual machine status could not be determined for '$computerName' (Manufacturer/Model strings were empty or unrecognised)."
            }
        }

        if (-not $isVm) {
            return @{ 
                Status = 'pass'
                Details = 'Physical host detected (no recognised virtualisation keywords in Manufacturer/Model).'
            }
        }

        $hvNote = if ([string]::IsNullOrWhiteSpace($hint)) { '' } else { " (Platform hint: $hint)" }

        if ($warnIfVirtualMachine) {
            return @{ 
                Status = 'attention'
                Details = "Virtual machine detected$hvNote. Verify NUMA affinity, memory ballooning, and storage I/O are optimised for SQL Server on this platform."
            }
        }

        return @{ Status = 'info'; Details = "Virtual machine detected$hvNote." }
    }
#endregion

#region -- [10] HyperThreading Ratio (Info) ---------------------------------
Register-CheckSection -File $global:__checkFile -Number 10 `
    -Title    'Host - HyperThreading ratio' `
    -Function 'Get-DbaComputerSystem' `
    -Key      'HyperthreadingRatio'

Invoke-Check -SpokeFile $spoke -CatalogName 'Host' -Function 'Get-DbaComputerSystem' -Key 'HyperthreadingRatio' `
    -Target $Target -Config $Config -Findings $Findings -Run {
        param($sql, $t, $cfg)

        if (-not $csSummary) {
            return @{ 
                Status = 'info'
                Details = "Get-DbaComputerSystem returned no data for '$computerName'; HyperThreading ratio unavailable."
            }
        }

        $logical = $csSummary.LogicalCores
        $physical = $csSummary.PhysicalCores
        $ratio = $csSummary.HtRatio
        $isHt = $csSummary.IsHyperThreading

        if ($null -eq $logical) {
            return @{ 
                Status = 'info'
                Details = "Logical processor count could not be determined for '$computerName'."
            }
        }

        if ($null -eq $physical) {
            $htNote = if ($null -ne $isHt) {
                if ($isHt) { ' HyperThreading active (per Get-DbaComputerSystem).' }
                else { ' HyperThreading not detected (per Get-DbaComputerSystem).' }
            } else { '' }
            return @{ 
                Status = 'info'
                Details = "Logical processors: $logical. Physical core count unavailable (Win32_Processor CIM query failed or was not run); HyperThreading ratio cannot be computed.$htNote"
            }
        }

        $htNote = if ($null -ne $isHt) {
            if ($isHt) { ' - HyperThreading is active.' } else { ' - HyperThreading not detected or disabled.' }
        } else { '' }

        return @{ 
            Status = 'info'
            Details = "Logical processors: $logical; Physical cores: $physical; HT ratio: $ratio$htNote"
        }
    }
#endregion

#region -- [11] NUMA Topology (Info) ----------------------------------------
Register-CheckSection -File $global:__checkFile -Number 11 `
    -Title    'Host - NUMA topology' `
    -Function 'Get-DbaComputerSystem' `
    -Key      'NUMANodes'

Invoke-Check -SpokeFile $spoke -CatalogName 'Host' -Function 'Get-DbaComputerSystem' -Key 'NUMANodes' `
    -Target $Target -Config $Config -Findings $Findings -Run {
        param($sql, $t, $cfg)

        if (-not $csSummary) {
            return @{ 
                Status = 'info'
                Details = "Get-DbaComputerSystem returned no data for '$computerName'; NUMA topology unavailable."
            }
        }

        $numa = $csSummary.NumaNodeCount

        if ($null -eq $numa) {
            return @{ 
                Status = 'info'
                Details = "NUMA node count could not be determined for '$computerName' (CIM query may have failed or was not run)."
            }
        }

        $numaNote = if ($numa -gt 1) {
            ' Verify SQL Server MAXDOP and affinity mask settings are tuned for multi-NUMA topology.'
        } else { '' }

        return @{ Status = 'info'; Details = "NUMA nodes: $numa.$numaNote" }
    }
#endregion

#region -- [12] Lock Pages in Memory (LPIM) ---------------------------------
Register-CheckSection -File $global:__checkFile -Number 12 `
    -Title    'Host - Lock Pages in Memory (LPIM)' `
    -Function 'Get-DbaPrivilege' `
    -Key      'LockPagesInMemory'

Invoke-Check -SpokeFile $spoke -CatalogName 'Host' -Function 'Get-DbaPrivilege' -Key 'LockPagesInMemory' `
    -Target $Target -Config $Config -Findings $Findings -Run {
        param($sql, $t, $cfg)

        if (-not $privSummary) {
            return @{ 
                Status = 'info'
                Details = "Get-DbaPrivilege returned no data for '$computerName' (requires local admin / PS Remoting; may not be available in all environments)."
            }
        }

        if (-not $requireLpim) {
            $accts = if ($privSummary.HasLpim -and $privSummary.LpimAccounts.Count -gt 0) {
                " Granted to: $(($privSummary.LpimAccounts -join ', '))."
            } else { ' Not granted.' }
            return @{ 
                Status = 'info'
                Details = "SeLockMemoryPrivilege (LPIM) check not enforced (Host.RequireLpim = false).$accts"
            }
        }

        if ($privSummary.HasLpim) {
            $accts = $privSummary.LpimAccounts -join ', '
            return @{ 
                Status = 'pass'
                Details = "SeLockMemoryPrivilege (LPIM) is granted. Account(s): $accts."
            }
        }

        $st = if ($lpimNonCompliantIsFail) { 'fail' } else { 'attention' }
        return @{ 
            Status = $st
            Details = "SeLockMemoryPrivilege (Lock Pages in Memory) is NOT granted. Without LPIM the OS may page out the SQL Server buffer pool under memory pressure."
        }
    }
#endregion

#region -- [13] Instant File Initialization (IFI) ---------------------------
Register-CheckSection -File $global:__checkFile -Number 13 `
    -Title    'Host - Instant File Initialization (IFI)' `
    -Function 'Get-DbaPrivilege' `
    -Key      'InstantFileInit'

# Get credential for SID resolution
$credential = if ($Target.PSObject.Properties['Credential']) { $Target.Credential } else { $null }

# Get accounts with IFI directly from raw rows (AllPrivileges contains formatted
# strings for display only; RawRows holds the original dbatools objects)
$ifiAccounts = @()
if ($privSummary) {
    foreach ($row in $privSummary.RawRows) {
        if ($row.PSObject.Properties['InstantFileInitialization'] -and $row.InstantFileInitialization) {
            $rawAccount = if ($row.PSObject.Properties['User']) { [string]$row.User } else { '(unknown)' }
            if ($rawAccount -notin $ifiAccounts) {
                $ifiAccounts += $rawAccount
            }
        }
    }


}

# Create rollup finding AFTER entries
Invoke-Check -SpokeFile $spoke -CatalogName 'Host' -Function 'Get-DbaPrivilege' -Key 'InstantFileInit' `
    -Target $Target -Config $Config -Findings $Findings -Run {
        param($sql, $t, $cfg)

        if (-not $privSummary) {
            return @{ 
                Status = 'info'
                Details = "Get-DbaPrivilege returned no data for '$computerName' (requires local admin / PS Remoting)."
            }
        }

        $hasIfi = $ifiAccounts.Count -gt 0

        if (-not $requireIfi) {
            if ($hasIfi) {
                return @{ 
                    Status = 'info'
                    Details = "SeManageVolumePrivilege (IFI) check not enforced (Host.RequireIfi = false). Granted to $($ifiAccounts.Count) account(s). See individual entries above."
                }
            } else {
                return @{ 
                    Status = 'info'
                    Details = "SeManageVolumePrivilege (IFI) check not enforced (Host.RequireIfi = false). Not granted to any accounts."
                }
            }
        }

        if ($hasIfi) {
            return @{ 
                Status = 'pass'
                Details = "SeManageVolumePrivilege (Instant File Initialization) is granted to $($ifiAccounts.Count) account(s). IFI eliminates data file zeroing during growth and restore. See individual entries above."
            }
        }

        $st = if ($ifiNonCompliantIsFail) { 'fail' } else { 'attention' }
        return @{ 
            Status = $st
            # After:
            Details = "SeManageVolumePrivilege (Instant File Initialization) is granted to $($ifiAccounts.Count) account(s). IFI eliminates data file zeroing during growth and restore. Account details are in the OS Privilege Inventory below."
        }
    }
#endregion

#region -- [14] OS Privilege Inventory (Info) -------------------------------
Register-CheckSection -File $global:__checkFile -Number 14 `
    -Title    'Host - OS privilege inventory' `
    -Function 'Get-DbaPrivilege' `
    -Key      'ServerPrivileges'

    # Build per-account privilege groups from raw rows
$accountGroups = @{}
if ($privSummary) {
    foreach ($row in $privSummary.RawRows) {
        $rawAccount = if ($row.PSObject.Properties['User'] -and $row.User) {
            [string]$row.User
        } else { '(unknown)' }

        $privs = [System.Collections.Generic.List[string]]::new()
        if ($row.PSObject.Properties['InstantFileInitialization']  -and $row.InstantFileInitialization) { $privs.Add('IFI')           }
        if ($row.PSObject.Properties['LockPagesInMemory']          -and $row.LockPagesInMemory)         { $privs.Add('LPIM')          }
        if ($row.PSObject.Properties['LogonAsBatch']               -and $row.LogonAsBatch)              { $privs.Add('Batch')         }
        if ($row.PSObject.Properties['LogonAsService']             -and $row.LogonAsService)            { $privs.Add('Service')       }
        if ($row.PSObject.Properties['GenerateSecurityAudit']      -and $row.GenerateSecurityAudit)     { $privs.Add('SecurityAudit') }

        if ($privs.Count -gt 0) {
            if (-not $accountGroups.ContainsKey($rawAccount)) {
                $accountGroups[$rawAccount] = [System.Collections.Generic.List[string]]::new()
            }
            foreach ($p in $privs) {
                if ($p -notin $accountGroups[$rawAccount]) {
                    $accountGroups[$rawAccount].Add($p)
                }
            }
        }
    }

    # Create entry findings FIRST
    $entrySplat = $global:CheckCat_Host['Get-DbaPrivilege']['ServerPrivilegesEntry']

    foreach ($acctEntry in ($accountGroups.GetEnumerator() | Sort-Object Key)) {
        $rawAccount     = $acctEntry.Key
        $displayAccount = Resolve-PrivilegeSid -AccountName $rawAccount `
                            -ComputerName $computerName -Credential $credential
        $privs = $acctEntry.Value | Sort-Object

        $Findings.Value += New-Finding @entrySplat `
            -Status  'info' `
            -Details "Account: $displayAccount; Privileges: $($privs -join ', ')" `
            -SpokeFile $spoke
    }
}

# Create rollup finding AFTER entries
Invoke-Check -SpokeFile $spoke -CatalogName 'Host' -Function 'Get-DbaPrivilege' -Key 'ServerPrivileges' `
    -Target $Target -Config $Config -Findings $Findings -Run {
        param($sql, $t, $cfg)

        if (-not $privSummary) {
            return @{ 
                Status = 'info'
                Details = "Get-DbaPrivilege returned no data for '$computerName' (requires local admin / PS Remoting; may not be available in all environments)."
            }
        }

        $count = $privSummary.RawCount
        $uniqueAccounts = $accountGroups.Count
        $allPrivs = @($accountGroups.Values | ForEach-Object { $_ } | Select-Object -Unique | Sort-Object)

        return @{ 
            Status = 'info'
            Details = "OS privilege inventory: $count account(s) with privileges; $uniqueAccounts unique account(s). Privileges observed: $($allPrivs -join ', '). See individual entries above."
        }
    }
#endregion

#region -- [15] SQL Firewall Rules Inventory (Info) -------------------------
Register-CheckSection -File $global:__checkFile -Number 15 `
    -Title    'Host - SQL Firewall Rules Inventory' `
    -Function 'Get-DbaFirewallRule' `
    -Key      'FirewallRules'

Invoke-Check -SpokeFile $spoke -CatalogName 'Host' -Function 'Get-DbaFirewallRule' -Key 'FirewallRules' `
    -Target $Target -Config $Config -Findings $Findings -Run {
        param($sql, $t, $cfg)

        if ($firewallErr) {
            return @{
                Status = 'info'
                Details = "Get-DbaFirewallRule error for '$computerName': $firewallErr. Verify the NetSecurity module is available and PS Remoting is enabled."
            }
        }

        if ($null -eq $firewallRules -or $firewallRules.Count -eq 0) {
            return @{
                Status = 'info'
                Details = "No dbatools-managed SQL Server firewall rules found on '$computerName'. Note: Get-DbaFirewallRule only surfaces rules created by New-DbaFirewallRule; manually-created rules are not visible to this check."
            }
        }

        # Check for error rows - Get-DbaFirewallRule returns error rows with .Error property
        $errorRows = @($firewallRules | Where-Object {
            $_.PSObject.Properties['Error'] -and -not [string]::IsNullOrWhiteSpace($_.Error)
        })
        if ($errorRows.Count -gt 0) {
            $errMsg = [string]$errorRows[0].Error
            return @{
                Status = 'info'
                Details = "Get-DbaFirewallRule returned an error for '$computerName': $errMsg. Verify the NetSecurity module is available and PS Remoting is enabled on the host."
            }
        }

        # Summarise by Type
        $byType = $firewallRules |
            Group-Object -Property Type |
            ForEach-Object {
                $ports = @($_.Group | ForEach-Object {
                    if ($_.PSObject.Properties['LocalPort'] -and $_.LocalPort) { 
                        [string]$_.LocalPort 
                    }
                } | Where-Object { $_ } | Select-Object -Unique)
                $portStr = if ($ports.Count -gt 0) { ":$($ports -join '/')" } else { '' }
                "$($_.Name)($($_.Count)$portStr)"
            }

        $total = $firewallRules.Count
        return @{
            Status = 'info'
            Details = "$total dbatools-managed SQL Server firewall rule(s) found on '$computerName': $($byType -join ', '). Note: manually-created rules are not visible to this check."
        }
    }
#endregion