#Requires -Version 5.1
<#
.SYNOPSIS
    Spoke.Instance.ps1 - SQL Server instance health checks spoke.

.DESCRIPTION
    Instance-level checks: build compliance, version/EOS status, server memory,
    max DOP, ad-hoc workloads, security settings (xp_cmdshell, DAC, OLEDB, CLR),
    performance settings (cost threshold, fill factor, workers, packet size),
    database authentication, SQL feature inventory, error log scan, trace flags,
    startup parameters, and sp_configure audit.

    Get-DbaFeature and Get-DbaStartupParameter require WMI / PS Remoting.
    On Linux SQL instances these checks will silently produce no data.

    All checks emit findings via $Findings ([ref] array) using Invoke-Check.
    Status values: 'pass' | 'attention' | 'fail' | 'info'

.NOTES
    Spoke contract (Contract A):
        param([object]$Target, [hashtable]$Config, [ref]$Findings)

    Catalog: $global:CheckCat_Instance in Checkup.Catalog.ps1
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][object]   $Target,
    [Parameter(Mandatory)][hashtable]$Config,
    [Parameter(Mandatory)][ref]      $Findings
)

#region -- [00] Init ---------------------------------------------------------
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root '3. Helpers\Helpers.Shared.ps1')

$sql                = Get-SqlConnectionSplat -Target $Target
$global:__checkFile = Split-Path -Leaf $PSCommandPath

$spoke = 'Instance'
#endregion

#region -- [01] Pack-level enable check --------------------------------------
$packEnabled = Cfg $Config 'Instance.Enabled' -Default $true
if (-not [bool]$packEnabled) {
    $Findings.Value += New-Finding `
        -Label    'Instance Pack (disabled)' `
        -Category 'Configuration' -Priority 'Low' -Status 'info' `
        -Details  'Instance pack disabled by config (Instance.Enabled = false).' `
        -Source   'Config' `
        -SpokeFile $spoke
    return
}
#endregion

#region -- [02] Config prefetch ----------------------------------------------
# Define config keys with their types and variable names
$configSpec = @{
    # Build
    BuildMode                = @{ Type = [string]; Var = 'buildMode' }
    BuildMaxBehind           = @{ Type = [int];    Var = 'buildMaxBehind' }
    BuildMinimum             = @{ Type = [string]; Var = 'buildMinimum' }
    # sp_configure thresholds
    MinCostThreshold         = @{ Type = [int];    Var = 'minCostThresh' }
    RequireOptimizeForAdHoc  = @{ Type = [bool];   Var = 'requireAdHoc' }
    RequireRemoteDAC         = @{ Type = [bool];   Var = 'requireDAC' }
    RequireAdHocDistQOff     = @{ Type = [bool];   Var = 'requireADQOff' }
    RequireOleAutomationOff  = @{ Type = [bool];   Var = 'requireOleOff' }
    AllowCLR                 = @{ Type = [bool];   Var = 'allowClr' }
    RequireBackupCompression = @{ Type = [bool];   Var = 'requireBackupComp' }
    CheckInstanceFillFactor  = @{ Type = [bool];   Var = 'checkInstanceFillFactor' }
    ExpectedFillFactor       = @{ Type = [int];    Var = 'expectedFillFactor' }
    MaxWorkerThreadsMax      = @{ Type = [int];    Var = 'maxWorkerThreadsMax' }
    NetworkPacketSizeMax     = @{ Type = [int];    Var = 'networkPacketSizeMax' }
    AllowContainedDbAuth     = @{ Type = [bool];   Var = 'allowContainedAuth' }
    # Error log scan
    ErrorLogScanDays         = @{ Type = [int];    Var = 'errorLogScanDays' }
    ErrorLogExclusions       = @{ Type = [array];  Var = 'errorLogExclusions' }
    # Misc
    CheckStartupParams       = @{ Type = [bool];   Var = 'checkStartupParams' }
}

# Fetch and validate all config keys in one pass
foreach ($key in $configSpec.Keys) {
    $value = Cfg $Config "Instance.$key"
    
    # Check for missing config
    if ($value -is [MissingConfigKey]) {
        $Findings.Value += New-SkipFinding -Key "Instance.$key" `
            -CheckLabel "Instance pack (missing: Instance.$key)" `
            -SpokeFile $spoke
        return
    }
    
    # Cast to typed variable and set in current scope
    $spec = $configSpec[$key]
    if ($spec.Type -eq [array]) {
        Set-Variable -Name $spec.Var -Value @($value) -Scope Script
    } else {
        Set-Variable -Name $spec.Var -Value ($value -as $spec.Type) -Scope Script
    }
}

# Build error log exclusion regex pattern (do once, use many times)
$errorLogExclusionPattern = if ($errorLogExclusions -and $errorLogExclusions.Count -gt 0) {
    '(' + (($errorLogExclusions | ForEach-Object { [regex]::Escape($_) }) -join '|') + ')'
} else {
    $null
}
#endregion

#region -- [03] Data prefetch ------------------------------------------------
$pfToken = Write-FetchProgress -Spoke 'Instance' -Start

Register-CheckSection -File $global:__checkFile -Number 3 `
    -Title    'Instance - Data prefetch' `
    -Function 'Test-DbaBuild' `
    -Key      'DataPrefetch'

# Build compliance — guard to first element; Test-DbaBuild returns one row per
# instance but defensive wrapping prevents property-on-array bugs.
$buildRaw = switch ($buildMode) {
    'Latest'       { Invoke-DBATools  { Test-DbaBuild @sql -Latest -EnableException } }
    'MaxBehind'    { Invoke-DBATools  { Test-DbaBuild @sql -MaxBehind $buildMaxBehind -EnableException } }
    'MinimumBuild' { if ($buildMinimum) {
                         Invoke-DBATools  { Test-DbaBuild @sql -MinimumBuild $buildMinimum -EnableException }
                     } else { $null } }
    default        { Invoke-DBATools  { Test-DbaBuild @sql -Latest -EnableException } }
}
$build = if ($buildRaw) { @($buildRaw)[0] } else { $null }


# Memory / DOP / AdHoc
$memResult   = Invoke-DBATools  { Test-DbaMaxMemory        @sql -EnableException }
$dopResult   = Invoke-DBATools  { Test-DbaMaxDop           @sql -EnableException }
$adHocResult = Invoke-DBATools  { Test-DbaOptimizeForAdHoc @sql -EnableException }

# Get all sp_configure settings once
$allSpCfg = Invoke-DBATools  { Get-DbaSpConfigure @sql -EnableException }
if (-not $allSpCfg) { $allSpCfg = @() }

# Index by DisplayName for O(1) lookup inside check blocks
$spIdx = @{}
foreach ($r in @($allSpCfg)) {
    if ($r.PSObject.Properties['DisplayName']) {
        $spIdx[$r.DisplayName] = $r
    }
}

# Feature discovery (WMI - ComputerName, NOT @sql)
$featureResult = Invoke-DBATools  { Get-DbaFeature -ComputerName $Target.ComputerName -EnableException }
if (-not $featureResult) { $featureResult = @() }

# Error log - recent high-severity entries (last N days)
$errLogAfter  = (Get-Date).AddDays(-$errorLogScanDays)
$errorLogRows = Invoke-DBATools  { Get-DbaErrorLog @sql -LogNumber 0 -After $errLogAfter -EnableException }
if (-not $errorLogRows) { $errorLogRows = @() }

# Trace flags
$traceFlags = Invoke-DBATools  { Get-DbaTraceFlag @sql -EnableException }
if (-not $traceFlags) { $traceFlags = @() }

# Startup parameters (WMI - uses -Credential, NOT -SqlCredential)
$startupParams = $null
if ($checkStartupParams) {
    $winCred = if ($Target.PSObject.Properties['Credential']) { $Target.Credential } else { $null }
    $startupParams = if ($winCred) {
        Invoke-DBATools  { Get-DbaStartupParameter -SqlInstance $Target.SqlInstance -Credential $winCred -Simple -EnableException }
    } else {
        Invoke-DBATools  { Get-DbaStartupParameter -SqlInstance $Target.SqlInstance -Simple -EnableException }
    }
}

Write-FetchProgress -Token $pfToken -End
#endregion

#region -- [04] Build compliance ---------------------------------------------
Register-CheckSection -File $global:__checkFile -Number 4 `
    -Title    'Instance - Build compliance' `
    -Function 'Test-DbaBuild' `
    -Key      'BuildCompliance'

Invoke-Check -SpokeFile $spoke -CatalogName 'Instance' -Function 'Test-DbaBuild' -Key 'BuildCompliance' `
    -Target $Target -Config $Config -Findings $Findings -Run {
        param($sql, $t, $cfg)
        
        if (-not $build) {
            return @{ Status = 'attention'; Details = 'Test-DbaBuild returned no data; build compliance check skipped.' }
        }
        
        $compliant  = [bool]$build.Compliant
        $st         = if ($compliant) { 'pass' } else { 'attention' }
        $matchType  = if ($build.PSObject.Properties['MatchType']) { $build.MatchType } else { 'n/a' }
        $buildStr   = if ($build.PSObject.Properties['Build'])     { $build.Build }     else { 'n/a' }
        
        @{ Status = $st; Details = "Build: $buildStr. Match: $matchType. Compliant: $compliant. Mode: $buildMode." }
    }
#endregion

#region -- [05] Version / end-of-support status ------------------------------
Register-CheckSection -File $global:__checkFile -Number 5 `
    -Title    'Instance - Version / end-of-support status' `
    -Function 'Test-DbaBuild' `
    -Key      'VersionSupport'

Invoke-Check -SpokeFile $spoke -CatalogName 'Instance' -Function 'Test-DbaBuild' -Key 'VersionSupport' `
    -Target $Target -Config $Config -Findings $Findings -Run {
        param($sql, $t, $cfg)
        
        if (-not $build) {
            return @{ Status = 'attention'; Details = 'Test-DbaBuild returned no data; end-of-support check skipped.' }
        }
        
        $buildStr  = if ($build.PSObject.Properties['Build'])     { $build.Build }     else { 'n/a' }
        $matchType = if ($build.PSObject.Properties['MatchType']) { $build.MatchType } else { 'n/a' }
        
        @{
            Status  = 'info'
            Details = "Build: $buildStr. Match type: $matchType. For end-of-support status, cross-reference against https://dbatools.io/builds."
        }
    }
#endregion

#region -- [06] Max server memory --------------------------------------------
Register-CheckSection -File $global:__checkFile -Number 6 `
    -Title    'Instance - Max server memory' `
    -Function 'Test-DbaMaxMemory' `
    -Key      'MaxServerMemory'

Invoke-Check -SpokeFile $spoke -CatalogName 'Instance' -Function 'Test-DbaMaxMemory' -Key 'MaxServerMemory' `
    -Target $Target -Config $Config -Findings $Findings -Run {
        param($sql, $t, $cfg)
        
        if (-not $memResult) {
            return @{ Status = 'attention'; Details = 'Test-DbaMaxMemory returned no data; memory configuration check skipped.' }
        }
        
        $cur = if ($memResult.PSObject.Properties['MaxValue'])         { [long]$memResult.MaxValue }         else { $null }
        $rec = if ($memResult.PSObject.Properties['RecommendedValue']) { [long]$memResult.RecommendedValue } else { $null }
        $tot = if ($memResult.PSObject.Properties['Total'])            { [long]$memResult.Total }            else { $null }
        
        if ($null -eq $cur -or $null -eq $rec) {
            return @{ Status = 'attention'; Details = 'Test-DbaMaxMemory returned unexpected object shape; check skipped.' }
        }
        
        # Compliant when configured value is within 10% of the recommendation
        $compliant = ($cur -le ($rec * 1.10)) -and ($cur -ge ($rec * 0.90))
        $st = if ($compliant) { 'pass' } else { 'attention' }
        $totStr = if ($null -ne $tot) { "; Total RAM: $tot MB" } else { '' }
        
        @{ Status = $st; Details = "Max server memory: $cur MB. Recommended: $rec MB. Compliant: $compliant$totStr." }
    }
#endregion

#region -- [07] Max DOP ------------------------------------------------------
Register-CheckSection -File $global:__checkFile -Number 7 `
    -Title    'Instance - Max degree of parallelism (DOP)' `
    -Function 'Test-DbaMaxDop' `
    -Key      'InstanceMaxDop'

Invoke-Check -SpokeFile $spoke -CatalogName 'Instance' -Function 'Test-DbaMaxDop' -Key 'InstanceMaxDop' `
    -Target $Target -Config $Config -Findings $Findings -Run {
        param($sql, $t, $cfg)
        
        if (-not $dopResult) {
            return @{ Status = 'attention'; Details = 'Test-DbaMaxDop returned no data; DOP check skipped.' }
        }
        
        # Test-DbaMaxDop returns one row per instance-level result; filter to instance-level only
        $instRow = @($dopResult) | Where-Object {
            -not $_.PSObject.Properties['Database'] -or [string]::IsNullOrEmpty($_.Database)
        } | Select-Object -First 1
        
        if (-not $instRow) { $instRow = @($dopResult)[0] }
        
        $cur = if ($instRow.PSObject.Properties['CurrentInstanceMaxDop']) { [int]$instRow.CurrentInstanceMaxDop } else { $null }
        $rec = if ($instRow.PSObject.Properties['RecommendedMaxDop'])     { [int]$instRow.RecommendedMaxDop }     else { $null }
        
        if ($null -eq $cur -or $null -eq $rec) {
            return @{ Status = 'attention'; Details = 'Test-DbaMaxDop returned unexpected object shape; check skipped.' }
        }
        
        $compliant = ($cur -eq $rec)
        $st        = if ($compliant) { 'pass' } else { 'attention' }
        
        @{ Status = $st; Details = "Instance MAXDOP: $cur. Recommended: $rec. Compliant: $compliant." }
    }
#endregion

#region -- [08] Optimize for ad-hoc ------------------------------------------
Register-CheckSection -File $global:__checkFile -Number 8 `
    -Title    'Instance - Optimize for ad-hoc workloads' `
    -Function 'Test-DbaOptimizeForAdHoc' `
    -Key      'OptimizeForAdHoc'

Invoke-Check -SpokeFile $spoke -CatalogName 'Instance' -Function 'Test-DbaOptimizeForAdHoc' -Key 'OptimizeForAdHoc' `
    -Target $Target -Config $Config -Findings $Findings -Run {
        param($sql, $t, $cfg)
        
        if (-not $adHocResult) {
            return @{ Status = 'info'; Details = 'Test-DbaOptimizeForAdHoc returned no data; check skipped.' }
        }
        
        $cur = if ($adHocResult.PSObject.Properties['CurrentOptimizeAdHoc'])     { [int]$adHocResult.CurrentOptimizeAdHoc }     else { $null }
        $rec = if ($adHocResult.PSObject.Properties['RecommendedOptimizeAdHoc']) { [int]$adHocResult.RecommendedOptimizeAdHoc } else { $null }
        
        if ($null -eq $cur) {
            return @{ Status = 'info'; Details = 'Test-DbaOptimizeForAdHoc returned unexpected object shape; check skipped.' }
        }
        
        $isBp  = ($cur -eq 1)
        $ok    = if ($requireAdHoc) { $isBp } else { $true }
        $st    = if ($ok) { 'pass' } else { 'attention' }
        $recStr = if ($null -ne $rec) { $rec } else { '1' }
        
        @{ Status = $st; Details = "Optimize for ad-hoc workloads: $cur (recommended: $recStr). Best practice met: $isBp. Required by config: $requireAdHoc." }
    }
#endregion

#region -- [09] xp_cmdshell disabled -----------------------------------------
Register-CheckSection -File $global:__checkFile -Number 9 `
    -Title    'Instance - xp_cmdshell disabled' `
    -Function 'Get-DbaSpConfigure' `
    -Key      'XpCmdShell'

Invoke-Check -SpokeFile $spoke -CatalogName 'Instance' -Function 'Get-DbaSpConfigure' -Key 'XpCmdShell' `
    -Target $Target -Config $Config -Findings $Findings -Run {
        param($sql, $t, $cfg)
        
        if (-not $spIdx.ContainsKey('xp_cmdshell')) {
            return @{ Status = 'attention'; Details = 'xp_cmdshell could not be read from sp_configure.' }
        }
        
        $val     = $spIdx['xp_cmdshell'].RunningValue
        $enabled = [bool][int]$val
        $st      = if (-not $enabled) { 'pass' } else { 'fail' }
        
        @{ Status = $st; Details = "xp_cmdshell enabled: $enabled. This feature permits OS command execution from SQL and should be disabled." }
    }
#endregion

#region -- [10] Remote DAC ---------------------------------------------------
Register-CheckSection -File $global:__checkFile -Number 10 `
    -Title    'Instance - Remote DAC' `
    -Function 'Get-DbaSpConfigure' `
    -Key      'RemoteDAC'

Invoke-Check -SpokeFile $spoke -CatalogName 'Instance' -Function 'Get-DbaSpConfigure' -Key 'RemoteDAC' `
    -Target $Target -Config $Config -Findings $Findings -Run {
        param($sql, $t, $cfg)
        
        if (-not $spIdx.ContainsKey('remote admin connections')) {
            return @{ Status = 'attention'; Details = 'remote admin connections could not be read from sp_configure.' }
        }
        
        $enabled = [bool][int]$spIdx['remote admin connections'].RunningValue
        $st      = if ($requireDAC) { if ($enabled) { 'pass' } else { 'attention' } } else { 'pass' }
        
        @{ Status = $st; Details = "Remote DAC (remote admin connections): $enabled. Required by config: $requireDAC." }
    }
#endregion

#region -- [11] Ad hoc distributed queries -----------------------------------
Register-CheckSection -File $global:__checkFile -Number 11 `
    -Title    'Instance - Ad hoc distributed queries' `
    -Function 'Get-DbaSpConfigure' `
    -Key      'AdHocDistributed'

Invoke-Check -SpokeFile $spoke -CatalogName 'Instance' -Function 'Get-DbaSpConfigure' -Key 'AdHocDistributed' `
    -Target $Target -Config $Config -Findings $Findings -Run {
        param($sql, $t, $cfg)
        
        if (-not $spIdx.ContainsKey('Ad Hoc Distributed Queries')) {
            return @{ Status = 'attention'; Details = 'Ad Hoc Distributed Queries could not be read from sp_configure.' }
        }
        
        $enabled = [bool][int]$spIdx['Ad Hoc Distributed Queries'].RunningValue
        $st      = if ($requireADQOff) { if (-not $enabled) { 'pass' } else { 'attention' } } else { 'pass' }
        
        @{ Status = $st; Details = "Ad Hoc Distributed Queries enabled: $enabled. Require disabled: $requireADQOff." }
    }
#endregion

#region -- [12] OLE automation procedures ------------------------------------
Register-CheckSection -File $global:__checkFile -Number 12 `
    -Title    'Instance - OLE automation procedures' `
    -Function 'Get-DbaSpConfigure' `
    -Key      'OleAutomation'

Invoke-Check -SpokeFile $spoke -CatalogName 'Instance' -Function 'Get-DbaSpConfigure' -Key 'OleAutomation' `
    -Target $Target -Config $Config -Findings $Findings -Run {
        param($sql, $t, $cfg)
        
        if (-not $spIdx.ContainsKey('Ole Automation Procedures')) {
            return @{ Status = 'attention'; Details = 'Ole Automation Procedures could not be read from sp_configure.' }
        }
        
        $enabled = [bool][int]$spIdx['Ole Automation Procedures'].RunningValue
        $st      = if ($requireOleOff) { if (-not $enabled) { 'pass' } else { 'attention' } } else { 'pass' }
        
        @{ Status = $st; Details = "OLE Automation Procedures enabled: $enabled. Require disabled: $requireOleOff." }
    }
#endregion

#region -- [13] CLR integration ----------------------------------------------
Register-CheckSection -File $global:__checkFile -Number 13 `
    -Title    'Instance - CLR integration' `
    -Function 'Get-DbaSpConfigure' `
    -Key      'ClrEnabled'

Invoke-Check -SpokeFile $spoke -CatalogName 'Instance' -Function 'Get-DbaSpConfigure' -Key 'ClrEnabled' `
    -Target $Target -Config $Config -Findings $Findings -Run {
        param($sql, $t, $cfg)
        
        if (-not $spIdx.ContainsKey('clr enabled')) {
            return @{ Status = 'attention'; Details = 'clr enabled could not be read from sp_configure.' }
        }
        
        $enabled = [bool][int]$spIdx['clr enabled'].RunningValue
        $st      = if ($allowClr) { 'pass' } else { if ($enabled) { 'attention' } else { 'pass' } }
        
        @{ Status = $st; Details = "CLR integration enabled: $enabled. Allowed by config: $allowClr." }
    }
#endregion

#region -- [14] Cost threshold for parallelism -------------------------------
Register-CheckSection -File $global:__checkFile -Number 14 `
    -Title    'Instance - Cost threshold for parallelism' `
    -Function 'Get-DbaSpConfigure' `
    -Key      'CostThreshold'

Invoke-Check -SpokeFile $spoke -CatalogName 'Instance' -Function 'Get-DbaSpConfigure' -Key 'CostThreshold' `
    -Target $Target -Config $Config -Findings $Findings -Run {
        param($sql, $t, $cfg)
        
        if (-not $spIdx.ContainsKey('cost threshold for parallelism')) {
            return @{ Status = 'attention'; Details = 'cost threshold for parallelism could not be read from sp_configure.' }
        }
        
        $cur = [int]$spIdx['cost threshold for parallelism'].RunningValue
        $st  = if ($cur -ge $minCostThresh) { 'pass' } else { 'attention' }
        
        @{ Status = $st; Details = "Cost threshold for parallelism: $cur. Minimum required: $minCostThresh. Default SQL value (5) is too low for most OLTP workloads." }
    }
#endregion

#region -- [15] Backup compression default -----------------------------------
Register-CheckSection -File $global:__checkFile -Number 15 `
    -Title    'Instance - Backup compression default' `
    -Function 'Get-DbaSpConfigure' `
    -Key      'BackupCompression'

Invoke-Check -SpokeFile $spoke -CatalogName 'Instance' -Function 'Get-DbaSpConfigure' -Key 'BackupCompression' `
    -Target $Target -Config $Config -Findings $Findings -Run {
        param($sql, $t, $cfg)
        
        if (-not $spIdx.ContainsKey('backup compression default')) {
            return @{ Status = 'attention'; Details = 'backup compression default could not be read from sp_configure.' }
        }
        
        $enabled = [bool][int]$spIdx['backup compression default'].RunningValue
        $st      = if ($requireBackupComp) { if ($enabled) { 'pass' } else { 'attention' } } else { 'pass' }
        
        @{ Status = $st; Details = "Backup compression default: $enabled. Required by config: $requireBackupComp." }
    }
#endregion

#region -- [16] Fill factor --------------------------------------------------
Register-CheckSection -File $global:__checkFile -Number 16 `
    -Title    'Instance - Fill factor' `
    -Function 'Get-DbaSpConfigure' `
    -Key      'FillFactor'

Invoke-Check -SpokeFile $spoke -CatalogName 'Instance' -Function 'Get-DbaSpConfigure' -Key 'FillFactor' `
    -Target $Target -Config $Config -Findings $Findings -Run {
        param($sql, $t, $cfg)
        
        if (-not $checkInstanceFillFactor) {
            return @{ Status = 'info'; Details = 'Fill factor check is disabled in settings.' }
        }
        
        if (-not $spIdx.ContainsKey('fill factor (%)')) {
            return @{ Status = 'attention'; Details = 'fill factor (%) could not be read from sp_configure.' }
        }
        
        $cur = [int]$spIdx['fill factor (%)'].RunningValue
        
        # SQL Server treats 0 and 100 as equivalent (both mean "fill completely")
        $curNormalized = if ($cur -eq 0) { 100 } else { $cur }
        $expNormalized = if ($expectedFillFactor -eq 0) { 100 } else { $expectedFillFactor }
        
        $st = if ($curNormalized -eq $expNormalized) { 'pass' } else { 'attention' }
        
        @{ 
            Status  = $st
            Details = "Instance fill factor: $cur (normalized: $curNormalized%). Expected: $expectedFillFactor (normalized: $expNormalized%)."
        }
    }
#endregion

#region -- [17] Max worker threads -------------------------------------------
Register-CheckSection -File $global:__checkFile -Number 17 `
    -Title    'Instance - Max worker threads' `
    -Function 'Get-DbaSpConfigure' `
    -Key      'MaxWorkerThreads'

Invoke-Check -SpokeFile $spoke -CatalogName 'Instance' -Function 'Get-DbaSpConfigure' -Key 'MaxWorkerThreads' `
    -Target $Target -Config $Config -Findings $Findings -Run {
        param($sql, $t, $cfg)
        
        if (-not $spIdx.ContainsKey('max worker threads')) {
            return @{ Status = 'attention'; Details = 'max worker threads could not be read from sp_configure.' }
        }
        
        $cur = [int]$spIdx['max worker threads'].RunningValue
        
        if ($maxWorkerThreadsMax -eq 0) {
            return @{ Status = 'info'; Details = "Max worker threads: $cur (0 = auto). No threshold configured; informational only." }
        }
        
        $st = if ($cur -eq 0 -or $cur -le $maxWorkerThreadsMax) { 'pass' } else { 'attention' }
        
        @{ Status = $st; Details = "Max worker threads: $cur. Threshold: $maxWorkerThreadsMax (0 = auto)." }
    }
#endregion

#region -- [18] Network packet size ------------------------------------------
Register-CheckSection -File $global:__checkFile -Number 18 `
    -Title    'Instance - Network packet size' `
    -Function 'Get-DbaSpConfigure' `
    -Key      'NetworkPacketSize'

Invoke-Check -SpokeFile $spoke -CatalogName 'Instance' -Function 'Get-DbaSpConfigure' -Key 'NetworkPacketSize' `
    -Target $Target -Config $Config -Findings $Findings -Run {
        param($sql, $t, $cfg)
        
        if (-not $spIdx.ContainsKey('network packet size (B)')) {
            return @{ Status = 'attention'; Details = 'network packet size (B) could not be read from sp_configure.' }
        }
        
        $cur = [int]$spIdx['network packet size (B)'].RunningValue
        
        if ($networkPacketSizeMax -eq 0) {
            return @{ Status = 'info'; Details = "Network packet size: $cur bytes. No threshold configured; informational only." }
        }
        
        $st = if ($cur -le $networkPacketSizeMax) { 'pass' } else { 'attention' }
        
        @{ Status = $st; Details = "Network packet size: $cur bytes. Max allowed: $networkPacketSizeMax bytes." }
    }
#endregion

#region -- [19] Contained database authentication ----------------------------
Register-CheckSection -File $global:__checkFile -Number 19 `
    -Title    'Instance - Contained database authentication' `
    -Function 'Get-DbaSpConfigure' `
    -Key      'ContainedDbAuth'

Invoke-Check -SpokeFile $spoke -CatalogName 'Instance' -Function 'Get-DbaSpConfigure' -Key 'ContainedDbAuth' `
    -Target $Target -Config $Config -Findings $Findings -Run {
        param($sql, $t, $cfg)
        
        if (-not $spIdx.ContainsKey('contained database authentication')) {
            return @{ Status = 'attention'; Details = 'contained database authentication could not be read from sp_configure.' }
        }
        
        $enabled = [bool][int]$spIdx['contained database authentication'].RunningValue
        $st      = if ($allowContainedAuth) { 'pass' } else { if ($enabled) { 'attention' } else { 'pass' } }
        
        @{ Status = $st; Details = "Contained database authentication: $enabled. Allowed by config: $allowContainedAuth. Enabling this allows users to authenticate directly to contained DBs, bypassing instance logins." }
    }
#endregion

#region -- [20] SQL feature discovery (rollup + entries) ---------------------
Register-CheckSection -File $global:__checkFile -Number 20 `
    -Title    'Instance - SQL feature discovery' `
    -Function 'Get-DbaFeature' `
    -Key      'FeatureDiscovery'

# Entry: One finding per installed feature (created BEFORE rollup)
$featureEntries = @()
if ($featureResult.Count -gt 0) {
    $features    = @($featureResult) | Select-Object -Property Feature, InstanceName -Unique | Sort-Object Feature, InstanceName
    $entrySplat  = $global:CheckCat_Instance['Get-DbaFeature']['FeatureDiscoveryEntry']

    if ($entrySplat) {
        foreach ($feat in $features) {
            $instanceInfo = if ($feat.InstanceName) { " (Instance: $($feat.InstanceName))" } else { '' }

            $Findings.Value += New-Finding @entrySplat `
                -Status  'info' `
                -Details "Feature installed: $($feat.Feature)$instanceInfo on $($Target.ComputerName)." `
                -SpokeFile $spoke

            $featureEntries += $feat
        }
    }
}

# Rollup: Count of installed features (created AFTER entries)
Invoke-Check -SpokeFile $spoke -CatalogName 'Instance' -Function 'Get-DbaFeature' -Key 'FeatureDiscovery' `
    -Target $Target -Config $Config -Findings $Findings -Run {
        param($sql, $t, $cfg)
        
        if ($featureResult.Count -eq 0) {
            return @{ Status = 'info'; Details = 'Get-DbaFeature returned no data. WMI / PS Remoting may be unavailable on this host (normal for Linux SQL Server instances).' }
        }
        
        $count = $featureEntries.Count
        $names = ($featureEntries | Select-Object -ExpandProperty Feature -Unique | Sort-Object) -join ', '
        
        @{ 
            Status  = 'info'
            Details = "$count SQL feature(s) installed on $($t.ComputerName): $names. See individual entries above."
        }
    }
#endregion

#region -- [21] Error log scan (rollup + entries) ----------------------------
Register-CheckSection -File $global:__checkFile -Number 21 `
    -Title    'Instance - Recent high-severity error log entries' `
    -Function 'Get-DbaErrorLog' `
    -Key      'ErrorLogScan'

# Pre-process error log data for both rollup and entries
$errorLogEntries = @()
if ($errorLogRows.Count -gt 0) {
    $rows = @($errorLogRows)
    
    # Apply exclusions BEFORE pattern matching
    if ($errorLogExclusionPattern) {
        $rows = @($rows | Where-Object { $_.Text -notmatch $errorLogExclusionPattern })
    }
    
    $severePatterns = 'severity 1[789]|severity 2[0-9]|i/o error|error detected|fatal error|corrupt|checksum|torn page|823|824|825|OS error'
    $severe = @($rows | Where-Object { $_.Text -match $severePatterns })
    
    if ($severe.Count -gt 0) {
        # Group similar errors by normalized text pattern
        $grouped = $severe | Group-Object -Property {
            $text = ([string]$_.Text).Trim() -replace '\s+', ' '
            
            # Normalize patterns to group similar errors
            $text = $text -replace '\b\d{4}-\d{2}-\d{2}\b', '<DATE>'
            $text = $text -replace '\b\d{2}:\d{2}:\d{2}\b', '<TIME>'
            $text = $text -replace '\bspid\s*\d+\b', 'spid <N>'
            $text = $text -replace '\bprocess ID\s+\d+\b', 'process ID <N>'
            $text = $text -replace '\bdatabase ID\s+\d+\b', 'database ID <N>'
            $text = $text -replace '\bpage\s+\(\d+:\d+\)', 'page (<N>:<N>)'
            $text = $text -replace '\b0x[0-9A-Fa-f]+\b', '0x<HEX>'
            
            if ($text.Length -gt 150) { $text = $text.Substring(0, 150) }
            
            return $text
        }
        
        $entrySplat = $global:CheckCat_Instance['Get-DbaErrorLog']['ErrorLogEntry']
        
        foreach ($group in $grouped) {
            $entries = @($group.Group | Sort-Object LogDate)
            $count = $entries.Count
            
            $firstEntry = $entries[0]
            $firstText = ([string]$firstEntry.Text).Trim() -replace '\s+', ' '
            if ($firstText.Length -gt 200) { $firstText = $firstText.Substring(0, 200) + '...' }
            
            $earliest = try { [datetime]$entries[0].LogDate } catch { $null }
            $latest   = try { [datetime]$entries[-1].LogDate } catch { $null }
            
            $timeRange = if ($earliest -and $latest -and $count -gt 1) {
                " between $($earliest.ToString('yyyy-MM-dd HH:mm')) and $($latest.ToString('yyyy-MM-dd HH:mm'))"
            } elseif ($earliest) {
                " at $($earliest.ToString('yyyy-MM-dd HH:mm'))"
            } else {
                ""
            }
            
            $severity = try { [string]$firstEntry.Severity } catch { '?' }
            $countText = if ($count -gt 1) { "$count times" } else { "1 time" }
            
            $Findings.Value += New-Finding @entrySplat `
                -Status  'attention' `
                -Details "[$countText$timeRange] Severity $severity - $firstText" `
                -SpokeFile $spoke
            
            $errorLogEntries += @{ Count = $count; Severity = $severity }
        }
    }
}

# Rollup: Summary of error log scan (created AFTER entries)
Invoke-Check -SpokeFile $spoke -CatalogName 'Instance' -Function 'Get-DbaErrorLog' -Key 'ErrorLogScan' `
    -Target $Target -Config $Config -Findings $Findings -Run {
        param($sql, $t, $cfg)
        
        if ($errorLogRows.Count -eq 0) {
            return @{ Status = 'info'; Details = "No error log entries found in the past $errorLogScanDays day(s), or log could not be read." }
        }
        
        $totalScanned = $errorLogRows.Count
        
        if ($errorLogEntries.Count -eq 0) {
            $rows = @($errorLogRows)
            if ($errorLogExclusionPattern) {
                $rows = @($rows | Where-Object { $_.Text -notmatch $errorLogExclusionPattern })
            }
            $excludedCount = $totalScanned - $rows.Count
            $excludedText = if ($excludedCount -gt 0) { " ($excludedCount excluded by filter)" } else { '' }
            
            return @{ 
                Status  = 'pass'
                Details = "$totalScanned log entry(ies) scanned over $errorLogScanDays day(s)$excludedText. No high-severity or I/O error entries detected." 
            }
        }
        
        return @{
            Status  = 'attention'
            Details = "$($errorLogEntries.Count) high-severity/I/O error pattern(s) found in the past $errorLogScanDays day(s). See aggregated entries above."
        }
    }
#endregion

#region -- [22] Active global trace flags ------------------------------------
Register-CheckSection -File $global:__checkFile -Number 22 `
    -Title    'Instance - Active global trace flags' `
    -Function 'Get-DbaTraceFlag' `
    -Key      'TraceFlags'

Invoke-Check -SpokeFile $spoke -CatalogName 'Instance' -Function 'Get-DbaTraceFlag' -Key 'TraceFlags' `
    -Target $Target -Config $Config -Findings $Findings -Run {
        param($sql, $t, $cfg)
        
        if ($traceFlags.Count -eq 0) {
            return @{ Status = 'info'; Details = 'No global trace flags are currently active on this instance.' }
        }
        
        $globalFlags = @($traceFlags | Where-Object { [bool]$_.Global })
        
        if ($globalFlags.Count -eq 0) {
            return @{ Status = 'info'; Details = 'No global trace flags active.' }
        }
        
        $flags = ($globalFlags | Select-Object -ExpandProperty TraceFlag | Sort-Object) -join ', '
        
        @{ Status = 'info'; Details = "$($globalFlags.Count) global trace flag(s) active: $flags." }
    }
#endregion

#region -- [23] SQL startup parameters ---------------------------------------
Register-CheckSection -File $global:__checkFile -Number 23 `
    -Title    'Instance - SQL Server startup parameters' `
    -Function 'Get-DbaStartupParameter' `
    -Key      'StartupParams'

Invoke-Check -SpokeFile $spoke -CatalogName 'Instance' -Function 'Get-DbaStartupParameter' -Key 'StartupParams' `
    -Target $Target -Config $Config -Findings $Findings -Run {
        param($sql, $t, $cfg)
        
        if (-not $checkStartupParams) {
            return @{ Status = 'info'; Details = 'Startup parameter check disabled by config (Instance.CheckStartupParams = false).' }
        }
        
        if (-not $startupParams) {
            return @{ Status = 'info'; Details = 'Get-DbaStartupParameter returned no data. WMI access may be unavailable (expected on Linux hosts or when -Credential is not provided).' }
        }
        
        $su  = if ($startupParams.PSObject.Properties['SingleUser'])   { [bool]$startupParams.SingleUser }   else { $false }
        $ms  = if ($startupParams.PSObject.Properties['MinimalStart']) { [bool]$startupParams.MinimalStart } else { $false }
        $tfs = if ($startupParams.PSObject.Properties['TraceFlags'])   { $startupParams.TraceFlags }         else { 'None' }
        
        $warnings = @()
        if ($su) { $warnings += 'SingleUser=ON' }
        if ($ms) { $warnings += 'MinimalStart=ON' }
        
        $st      = if ($warnings.Count -gt 0) { 'attention' } else { 'pass' }
        $warnStr = if ($warnings.Count -gt 0) { " WARNING: $($warnings -join ', ')." } else { '' }
        
        @{ Status = $st; Details = "Startup parameters inventoried.$warnStr TraceFlags: $tfs. ErrorLog: $($startupParams.ErrorLog)." }
    }
#endregion

#region -- [24] sp_configure inventory (rollup + entries) --------------------
Register-CheckSection -File $global:__checkFile -Number 24 `
    -Title    'Instance - sp_configure Full Inventory' `
    -Function 'Get-DbaSpConfigure' `
    -Key      'SpCfgInventory'

# Pre-process sp_configure inventory data
$spCfgInventoryEntries = @()
$excludeList = @(
    'xp_cmdshell',
    'remote admin connections',
    'Ad Hoc Distributed Queries',
    'Ole Automation Procedures',
    'clr enabled',
    'cost threshold for parallelism',
    'backup compression default',
    'fill factor (%)',
    'max worker threads',
    'network packet size (B)',
    'contained database authentication'
)

if ($spIdx.Count -gt 0) {
    foreach ($key in $spIdx.Keys) {
        $r = $spIdx[$key]
        
        $displayName = if ($r.PSObject.Properties['DisplayName']) { $r.DisplayName } else { $key }
        
        # Skip if already checked in dedicated region
        if ($excludeList -contains $displayName) {
            continue
        }
        
        $isDefault = if ($r.PSObject.Properties['IsRunningDefaultValue']) { [bool]$r.IsRunningDefaultValue } else { $null }
        
        # Only create entries for NON-DEFAULT settings
        if ($null -ne $isDefault -and -not $isDefault) {
            $runVal      = if ($r.PSObject.Properties['RunningValue'])    { $r.RunningValue }    else { '?' }
            $cfgVal      = if ($r.PSObject.Properties['ConfiguredValue']) { $r.ConfiguredValue } else { '?' }
            $defVal      = if ($r.PSObject.Properties['DefaultValue'])    { $r.DefaultValue }    else { '?' }
            $isDynamic   = if ($r.PSObject.Properties['IsDynamic'])       { [bool]$r.IsDynamic } else { $false }
            $description = if ($r.PSObject.Properties['Description'])     { $r.Description }     else { '' }
            
            $dynFlag = if ($isDynamic) { '[dynamic]' } else { '[requires restart]' }
            $entryDetails = "$displayName`: running=$runVal, configured=$cfgVal, default=$defVal $dynFlag. $description"
            
            $entrySplat = $global:CheckCat_Instance['Get-DbaSpConfigure']['SpCfgInventoryEntry']
            $Findings.Value += New-Finding @entrySplat `
                -Status  'info' `
                -Details $entryDetails `
                -SpokeFile $spoke
            
            $spCfgInventoryEntries += @{ Name = $displayName }
        }
    }
}

# Rollup: Summary of sp_configure inventory (created AFTER entries)
Invoke-Check -SpokeFile $spoke -CatalogName 'Instance' -Function 'Get-DbaSpConfigure' -Key 'SpCfgInventory' `
    -Target $Target -Config $Config -Findings $Findings -Run {
        param($sql, $t, $cfg)
        
        if ($spIdx.Count -eq 0) {
            return @{ Status = 'info'; Details = 'Get-DbaSpConfigure returned no data; sp_configure inventory skipped.' }
        }
        
        $totalCount      = $spIdx.Count
        $excludedCount   = $excludeList.Count
        $inventoriedCount = $totalCount - $excludedCount
        $nonDefaultCount  = $spCfgInventoryEntries.Count
        
        if ($nonDefaultCount -eq 0) {
            return @{ 
                Status  = 'pass'
                Details = "$inventoriedCount sp_configure setting(s) inventoried for '$($t.SqlInstance)' (excluding $excludedCount already checked in dedicated regions). All are running at default values."
            }
        }
        
        return @{ 
            Status  = 'info'
            Details = "$inventoriedCount sp_configure setting(s) inventoried for '$($t.SqlInstance)' (excluding $excludedCount already checked in dedicated regions). $nonDefaultCount setting(s) are running at non-default values. See individual entries above."
        }
    }
#endregion

#region -- [25] sp_configure pending changes (rollup + entries) --------------
Register-CheckSection -File $global:__checkFile -Number 25 `
    -Title    'Instance - sp_configure Pending Changes' `
    -Function 'Get-DbaSpConfigure' `
    -Key      'SpCfgPending'

# Pre-process pending changes data
$spCfgPendingEntries = @()
if ($spIdx.Count -gt 0) {
    foreach ($key in $spIdx.Keys) {
        $r = $spIdx[$key]
        
        $runVal = $null
        $cfgVal = $null
        if ($r.PSObject.Properties['RunningValue'])    { $runVal = $r.RunningValue }
        if ($r.PSObject.Properties['ConfiguredValue']) { $cfgVal = $r.ConfiguredValue }
        
        # Skip if we can't compare or values match
        if ($null -eq $runVal -or $null -eq $cfgVal) { continue }
        if ("$runVal" -eq "$cfgVal") { continue }
        
        $displayName = if ($r.PSObject.Properties['DisplayName']) { $r.DisplayName } else { $key }
        $isDynamic   = if ($r.PSObject.Properties['IsDynamic'])   { [bool]$r.IsDynamic } else { $false }
        $restartNote = if ($isDynamic) { 'dynamic — may self-apply without restart' } else { 'non-dynamic — requires SQL Server restart to take effect' }
        
        $entryDetails = "$displayName`: running=$runVal, configured=$cfgVal. $restartNote."
        
        $entrySplat = $global:CheckCat_Instance['Get-DbaSpConfigure']['SpCfgPendingEntry']
        $Findings.Value += New-Finding @entrySplat `
            -Status  'attention' `
            -Details $entryDetails `
            -SpokeFile $spoke
        
        $spCfgPendingEntries += @{ Name = $displayName }
    }
}

# Rollup: Summary of pending changes (created AFTER entries)
Invoke-Check -SpokeFile $spoke -CatalogName 'Instance' -Function 'Get-DbaSpConfigure' -Key 'SpCfgPending' `
    -Target $Target -Config $Config -Findings $Findings -Run {
        param($sql, $t, $cfg)
        
        if ($spIdx.Count -eq 0) {
            return @{ Status = 'info'; Details = 'Get-DbaSpConfigure returned no data; pending-change check skipped.' }
        }
        
        $pendingCount = $spCfgPendingEntries.Count
        
        if ($pendingCount -eq 0) {
            return @{ Status = 'pass'; Details = "All sp_configure settings: ConfiguredValue matches RunningValue. No pending changes detected on '$($t.SqlInstance)'." }
        }
        
        return @{
            Status  = 'attention'
            Details = "$pendingCount sp_configure setting(s) on '$($t.SqlInstance)' have a ConfiguredValue that differs from RunningValue. Non-dynamic settings will not apply until the SQL Server service is restarted. See entry rows above for details."
        }
    }
#endregion