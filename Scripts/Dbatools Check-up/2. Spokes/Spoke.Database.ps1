#Requires -Version 5.1
<#
.SYNOPSIS
    Spoke.Database.ps1 - Database health checks spoke.

.DESCRIPTION
    Database-level checks: accessibility/state, backups, recovery model,
    VLF counts, collation drift, file layout policy, MAXDOP (db scoped),
    compatibility level, owner compliance, feature usage inventory, auto-shrink,
    auto-close, page verify, trustworthy, TDE, statistics, service broker,
    containment, query store, auto-growth events, and free space.

.NOTES
    Spoke contract (Contract A):
        param([object]$Target, [hashtable]$Config, [ref]$Findings)

    Config keys consumed (ALL required - no defaults, MissingConfigKey if absent):
        Database.Enabled
        Database.IncludeSystem
        Database.ExcludeDatabases
        Database.VlfCountWarn
        Database.VlfCountFail
        Database.DbOwnerComplianceEnabled
        Database.DbOwnerExpectedPrincipal
        Database.RequireAutoShrinkOff
        Database.RequireAutoCloseOff
        Database.RequirePageVerifyChecksum
        Database.RequireTrustworthyOff
        Database.TrustworthyAllowList
        Database.RequireTde
        Database.RequireAutoUpdateStats
        Database.RequireAutoCreateStats
        Database.QueryStoreWarnIfOff
        Database.QueryStoreFailIfError
        Database.GrowthEventsAttentionCount
        Database.GrowthEventsFailCount
        Database.FreeSpacePctAttention
        Database.FreeSpacePctFail
        Database.RecoveryModelComplianceEnabled
        Database.RecoveryModelExpected
        Database.CompatibilityLevelComplianceEnabled
        Database.MinBackupFullHours
        Database.MinBackupDiffHours
        Database.MinBackupLogHours
        Database.AllowMultipleLogFiles
        Database.AllowPercentGrowth

    Catalog: $global:CheckCat_Database in .\Checkup.Catalog.ps1
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
. (Join-Path $root '3. Helpers\Helpers.Database.ps1')
. (Join-Path $root 'Checkup.Catalog.ps1')

$sql = Get-SqlConnectionSplat -Target $Target
$global:__checkFile = Split-Path -Leaf $PSCommandPath

$spoke = 'Database'
#endregion

#region -- [01] Pack-level enable check ------------------------------------
Register-CheckSection -File $global:__checkFile -Number 1 `
    -Title 'Database Pack - Enable Check' `
    -Function 'Config' `
    -Key 'PackEnabled'

$packEnabled = Cfg $Config 'Database.Enabled' -Default $true
if (-not [bool]$packEnabled) {
    $Findings.Value += New-Finding `
        -Label    'Database Pack (disabled)' `
        -Category 'Configuration' -Priority 'Low' -Status 'info' `
        -Details  'Database pack disabled by config (Database.Enabled = false).' `
        -Source   'Config' `
        -SpokeFile $spoke
    return
}
#endregion

#region -- [02] Config Fetch --------------------------------------------
Register-CheckSection -File $global:__checkFile -Number 2 `
    -Title 'Database Pack - Config Fetch' `
    -Function 'Config' `
    -Key 'ConfigFetch'

# Define config keys with their types and variable names
$configSpec = @{
    IncludeSystem                       = @{ Type = [bool];   Var = 'includeSystem' }
    ExcludeDatabases                    = @{ Type = [array];  Var = 'excludeDbPats' }
    VlfCountWarn                        = @{ Type = [int];    Var = 'vlfWarn' }
    VlfCountFail                        = @{ Type = [int];    Var = 'vlfFail' }
    DbOwnerComplianceEnabled            = @{ Type = [bool];   Var = 'ownerChkOn' }
    DbOwnerExpectedPrincipal            = @{ Type = [string]; Var = 'ownerExpected' }
    RequireAutoShrinkOff                = @{ Type = [bool];   Var = 'requireAutoShrinkOff' }
    RequireAutoCloseOff                 = @{ Type = [bool];   Var = 'requireAutoCloseOff' }
    RequirePageVerifyChecksum           = @{ Type = [bool];   Var = 'requirePageVerify' }
    RequireTrustworthyOff               = @{ Type = [bool];   Var = 'requireTrustworthyOff' }
    TrustworthyAllowList                = @{ Type = [array];  Var = 'trustworthyAllowRaw' }
    RequireTde                          = @{ Type = [bool];   Var = 'requireTde' }
    RequireAutoUpdateStats              = @{ Type = [bool];   Var = 'requireAutoUpdateStats' }
    RequireAutoCreateStats              = @{ Type = [bool];   Var = 'requireAutoCreateStats' }
    QueryStoreWarnIfOff                 = @{ Type = [bool];   Var = 'qsWarnIfOff' }
    QueryStoreFailIfError               = @{ Type = [bool];   Var = 'qsFailIfError' }
    GrowthEventsAttentionCount          = @{ Type = [int];    Var = 'growthAttnCount' }
    GrowthEventsFailCount               = @{ Type = [int];    Var = 'growthFailCount' }
    FreeSpacePctAttention               = @{ Type = [double]; Var = 'freeSpaceAttn' }
    FreeSpacePctFail                    = @{ Type = [double]; Var = 'freeSpaceFail' }
    RecoveryModelComplianceEnabled      = @{ Type = [bool];   Var = 'recoveryModelComplianceEnabled' }
    RecoveryModelExpected               = @{ Type = [string]; Var = 'recoveryModelExpected' }
    CompatibilityLevelComplianceEnabled = @{ Type = [bool];   Var = 'compatComplianceEnabled' }
    MinBackupFullHours                  = @{ Type = [int];    Var = 'minFullHours' }
    MinBackupDiffHours                  = @{ Type = [int];    Var = 'minDiffHours' }
    MinBackupLogHours                   = @{ Type = [int];    Var = 'minLogHours' }
    AllowMultipleLogFiles               = @{ Type = [bool];   Var = 'allowMultiLog' }
    AllowPercentGrowth                  = @{ Type = [bool];   Var = 'allowPctGrowth' }
    FeatureUsageEnabled                 = @{ Type = [bool];   Var = 'featureUsageEnabled' }
}

# Validate that $configSpec was created successfully
if ($null -eq $configSpec -or $configSpec.Count -eq 0) {
    $Findings.Value += New-SkipFinding -Key 'Database.ConfigSpecError' `
        -CheckLabel 'Database pack (error: config specification failed to initialize)' `
        -SpokeFile $spoke
    return
}

# Fetch and validate all config keys in one pass
$keys = @($configSpec.Keys)
foreach ($key in $keys) {
    $value = Cfg $Config "Database.$key"
    
    # Check for missing config
    if ($value -is [MissingConfigKey]) {
        $Findings.Value += New-SkipFinding -Key "Database.$key" `
            -CheckLabel "Database pack (missing: Database.$key)" `
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

# Normalize array config values
$excludeDbPats = ConvertTo-StringArray -Value $excludeDbPats

$trustworthyAllowList = @(
    ConvertTo-StringArray -Value $trustworthyAllowRaw |
    ForEach-Object { if ($_) { $_.ToLowerInvariant() } }
)

# Derived values
$minLogMinutes = $minLogHours * 60

# Validation
if ($vlfWarn -lt 0)   { $vlfWarn = 0 }
if ($vlfFail -lt 0)   { $vlfFail = 0 }
if ($vlfWarn -gt $vlfFail) {
    $Findings.Value += New-SkipFinding -Key 'Database.VlfThresholdConflict' `
        -CheckLabel 'Database pack (invalid config: VlfCountWarn > VlfCountFail)' `
        -SpokeFile $spoke
    return
}

if ($freeSpaceAttn -lt 0)   { $freeSpaceAttn = 0 }
if ($freeSpaceFail -lt 0)   { $freeSpaceFail = 0 }
if ($freeSpaceAttn -lt $freeSpaceFail) {
    $Findings.Value += New-SkipFinding -Key 'Database.FreeSpaceThresholdConflict' `
        -CheckLabel 'Database pack (invalid config: FreeSpacePctAttention < FreeSpacePctFail)' `
        -SpokeFile $spoke
    return
}
#endregion

#region -- [03] Data Fetch -----------------------------------------------
Register-CheckSection -File $global:__checkFile -Number 3 `
    -Title 'Database - Data Fetch' `
    -Function 'Get-DbaDatabase' `
    -Key 'DataFetch'

$pfToken = $null
try { $pfToken = Write-FetchProgress -Spoke 'Database' -Start } catch {}

# ── Core DB enumeration ───────────────────────────────────────────────────
if ($pfToken) { Update-FetchProgress -Token $pfToken -Label 'Fetching database list' }
$dbsRaw = Invoke-DBATools { Get-DbaDatabase @sql -EnableException }

$dbs = @()
if ($dbsRaw) {
    $filtered = Select-DatabaseScope -Databases @($dbsRaw) -IncludeSystem $includeSystem
    if ($filtered) {
        $dbs = Select-DatabaseByExcludePattern -Databases @($filtered) -ExcludePatterns $excludeDbPats
    }
    $dbs = @($dbs | Sort-Object Name)
}

$dbNames = @($dbs | Select-Object -ExpandProperty Name)

# "Healthy" = accessible + Normal status (user scope)
if ($pfToken) { Update-FetchProgress -Token $pfToken -Label 'Identifying eligible databases' }
$dbsHealthy = @(
    $dbs | Where-Object {
        (Get-DatabaseAccessibility $_) -and ((Get-DatabaseHealthStatus ([string]$_.Status)) -eq 'pass')
    }
)
$dbNamesHealthy = @($dbsHealthy | Select-Object -ExpandProperty Name)

# ── System DB scope for backup checks ────────────────────────────────────
$systemDbNames = @('master', 'model', 'msdb')
$dbsSystem     = @()

if ($pfToken) { Update-FetchProgress -Token $pfToken -Label 'Fetching system database data' }
if ($dbsRaw) {
    $dbsSystem = @(
        @($dbsRaw) |
        Where-Object {
            $_.Name -in $systemDbNames -and
            $_.Name -notin $dbNames -and
            (Get-DatabaseAccessibility $_) -and
            (Get-DatabaseHealthStatus ([string]$_.Status)) -eq 'pass'
        } |
        Where-Object {
            $n = $_.Name
            $excluded = $false
            foreach ($pat in $excludeDbPats) {
                if ($n -like $pat) { $excluded = $true; break }
            }
            -not $excluded
        } |
        Sort-Object Name
    )
}

$dbsAllHealthy     = @(
    @($dbsHealthy) + @($dbsSystem) |
    Sort-Object Name -Unique
)
$dbNamesAllHealthy = @($dbsAllHealthy | Select-Object -ExpandProperty Name)

# ── Compatibility check ───────────────────────────────────────────────────
if ($pfToken) { Update-FetchProgress -Token $pfToken -Label 'Checking compatibility levels' }
$compat = $null
if ($dbNamesHealthy.Count -gt 0) {
    $compat = Invoke-DBATools { Test-DbaDbCompatibility @sql -Database $dbNamesHealthy -EnableException }
}

# ── dbatools test/measure cmdlets (user-healthy DBs only) ─────────────────
$vlf        = @()
$collation  = @()
$maxdop     = @()
$queryStore = @()
$growthEvts = @()
$dbSpace    = @()

if ($dbNamesHealthy.Count -gt 0) {

    if ($pfToken) { Update-FetchProgress -Token $pfToken -Label 'Measuring VLF counts' }
    $vlf = Invoke-DBATools { Measure-DbaDbVirtualLogFile @sql -Database $dbNamesHealthy -EnableException }
    if (-not $vlf) { $vlf = @() }
    
    if ($pfToken) { Update-FetchProgress -Token $pfToken -Label 'Testing collation match' }
    $collation = Invoke-DBATools { Test-DbaDbCollation @sql -Database $dbNamesHealthy -EnableException }
    if (-not $collation) { $collation = @() }
    
    if ($pfToken) { Update-FetchProgress -Token $pfToken -Label 'Testing MAXDOP' }
    $maxdop = Invoke-DBATools { Test-DbaMaxDop @sql -EnableException }
    if (-not $maxdop) { $maxdop = @() }

    # ── Query Store: skip system DBs; skip if neither warning flag is set ─
    if (($qsWarnIfOff -or $qsFailIfError) -and $dbNamesHealthyUserOnly.Count -gt 0) {
        if ($pfToken) { Update-FetchProgress -Token $pfToken -Label 'Fetching Query Store state' }
        $queryStore = Invoke-DBATools { Test-DbaDbQueryStore @sql -EnableException }
        if (-not $queryStore) { $queryStore = @() }
    }

    # ── Growth events: skip if both thresholds are 0 (disabled) ──────────
    # No -EnableException: inaccessible DBs would throw and discard all results.
    # -WarningAction SilentlyContinue suppresses per-DB noise; [04] surfaces those DBs.
    if ($growthAttnCount -gt 0 -or $growthFailCount -gt 0) {
        if ($pfToken) { Update-FetchProgress -Token $pfToken -Label 'Reading Default Trace growth events' }
        $growthEvts = Invoke-DBATools { Find-DbaDbGrowthEvent @sql -Database $dbNamesHealthy -EventType Growth -WarningAction SilentlyContinue }
        if (-not $growthEvts) { $growthEvts = @() }
    }

    # ── Free space: skip if both thresholds are 0 (disabled) ─────────────
    # No -EnableException: same reason as growth events above.
    if ($freeSpaceAttn -gt 0 -or $freeSpaceFail -gt 0) {
        if ($pfToken) { Update-FetchProgress -Token $pfToken -Label 'Fetching database space usage' }
        $dbSpace = Invoke-DBATools { Get-DbaDbSpace @sql -Database $dbNamesHealthy -WarningAction SilentlyContinue }
        if (-not $dbSpace) { $dbSpace = @() }
    }
}

# ── File-layout (all in-scope DBs, not just healthy) ─────────────────────
# No -EnableException: this runs against ALL in-scope DBs including inaccessible ones
# (Restoring, Offline, etc.). A single bad DB would throw and discard results for
# all others. Warnings are suppressed; [04] and [05] surface the bad databases.
$dbFiles      = @()
$featureUsage = @()

if ($dbNames.Count -gt 0) {
    if ($pfToken) { Update-FetchProgress -Token $pfToken -Label 'Fetching database file layout' }
    $dbFiles = Invoke-DBATools { Get-DbaDbFile @sql -Database $dbNames -WarningAction SilentlyContinue }
    if (-not $dbFiles) { $dbFiles = @() }

    # ── Feature usage: SLOW - gate behind config flag ────────────────────
    if ($featureUsageEnabled) {
        if ($pfToken) { Update-FetchProgress -Token $pfToken -Label 'Scanning Enterprise feature usage (slow)' }
        $featureUsage = Invoke-DBATools { Get-DbaDbFeatureUsage @sql -Database $dbNames -WarningAction SilentlyContinue }
        if (-not $featureUsage) { $featureUsage = @() }
    }
}

# ── Scope summary (informational) ─────────────────────────────────────────
if ($pfToken) { Update-FetchProgress -Token $pfToken -Label 'Summarizing database scope' }
$systemNote = if ($dbsSystem.Count -gt 0) {
    '; system DBs always-checked (backup): {0}' -f ($dbsSystem.Name -join ', ')
} else { '' }

$Findings.Value += New-InfoFinding -Label '[DB] Scope' -Category 'Compliance' -Priority 'Low' `
    -Details ("In scope: {0} database(s); eligible (online): {1}; IncludeSystem={2}{3}." -f $dbNames.Count, $dbNamesHealthy.Count, $includeSystem, $systemNote) `
    -Source 'Scope' `
    -SpokeFile $spoke

if ($pfToken) { Write-FetchProgress -Token $pfToken -End }
#endregion

#region -- [04] Accessible --------------------------------------------------
Register-CheckSection -File $global:__checkFile -Number 4 `
    -Title '[DB] Accessible' `
    -Function 'Get-DbaDatabase' `
    -Key 'DbAccessible'

Invoke-Check -SpokeFile $spoke -CatalogName 'Database' -Function 'Get-DbaDatabase' -Key 'DbAccessible' `
    -Target $Target -Config $Config -Findings $Findings -Run {
        param($sql, $t, $cfg)

        if (-not $dbsRaw)          { return @{ Status='attention'; Details='Could not enumerate databases (Get-DbaDatabase returned no data).' } }
        if ($dbNames.Count -eq 0)  { return @{ Status='info';      Details='No databases in scope.' } }

        $bad = @($dbs | Where-Object { -not (Get-DatabaseAccessibility $_) })

        if ($bad.Count -eq 0) {
            return @{ Status='pass'; Details=('All {0} in-scope database(s) are accessible.' -f $dbNames.Count) }
        }

        # ── per-item entries ──────────────────────────────────────────────────
        $entrySplat = $global:CheckCat_Database['Get-DbaDatabase']['DbAccessibleEntry']
        foreach ($d in $bad) {
            $statusStr = ([string]$d.Status).Trim()
            $Findings.Value += New-Finding @entrySplat -Status 'fail' `
                -Details ("Database: $($d.Name); Status: $statusStr") `
                -SpokeFile $spoke
        }

        return @{ Status='fail'; Details=('{0} of {1} in-scope database(s) are not accessible.' -f $bad.Count, $dbNames.Count) }
    }
#endregion

#region -- [05] Status ------------------------------------------------------
Register-CheckSection -File $global:__checkFile -Number 5 `
    -Title '[DB] Status' `
    -Function 'Get-DbaDatabase' `
    -Key 'DbStatus'

Invoke-Check -SpokeFile $spoke -CatalogName 'Database' -Function 'Get-DbaDatabase' -Key 'DbStatus' `
    -Target $Target -Config $Config -Findings $Findings -Run {
        param($sql, $t, $cfg)

        if (-not $dbsRaw)          { return @{ Status='attention'; Details='Could not enumerate databases (Get-DbaDatabase returned no data).' } }
        if ($dbNames.Count -eq 0)  { return @{ Status='info';      Details='No databases in scope.' } }

        $bad = @()
        foreach ($d in @($dbs)) {
            $statusStr = [string]$d.Status
            if ($statusStr.Trim() -notmatch '(?i)^Normal$') {
                $bad += $d
            }
        }

        if ($bad.Count -eq 0) {
            return @{ Status='pass'; Details=('All {0} in-scope database(s) have Normal status.' -f $dbNames.Count) }
        }

        # ── per-item entries ──────────────────────────────────────────────────
        $entrySplat = $global:CheckCat_Database['Get-DbaDatabase']['DbStatusEntry']
        foreach ($d in $bad) {
            $statusStr = ([string]$d.Status).Trim()
            $Findings.Value += New-Finding @entrySplat -Status 'attention' `
                -Details ("Database: $($d.Name); Status: $statusStr") `
                -SpokeFile $spoke
        }

        return @{ Status='attention'; Details=('Non-Normal database status detected on {0} database(s).' -f $bad.Count) }
    }
#endregion

#region -- [06] Owner (Inventory) -------------------------------------------
Register-CheckSection -File $global:__checkFile -Number 6 `
    -Title '[DB] Owner (Inventory)' `
    -Function 'Get-DbaDatabase' `
    -Key 'DbOwner'

Invoke-Check -SpokeFile $spoke -CatalogName 'Database' -Function 'Get-DbaDatabase' -Key 'DbOwner' `
    -Target $Target -Config $Config -Findings $Findings -Run {
        param($sql, $t, $cfg)

        if (-not $dbsRaw)          { return @{ Status='attention'; Details='Could not enumerate databases (Get-DbaDatabase returned no data).' } }
        if ($dbNames.Count -eq 0)  { return @{ Status='info';      Details='No databases in scope.' } }

        # ── per-item entries ──────────────────────────────────────────────────
        $entrySplat = $global:CheckCat_Database['Get-DbaDatabase']['DbOwnerEntry']
        
        foreach ($db in $dbs) {
            $owner = Get-DatabaseOwnerName -Database $db
            
            $Findings.Value += New-Finding @entrySplat -Status 'info' `
                -Details "Database: $($db.Name); Owner: $owner" `
                -SpokeFile $spoke
        }

        # ── rollup finding ────────────────────────────────────────────────────
        $owners = @($dbs | ForEach-Object { Get-DatabaseOwnerName -Database $_ })
        $uniqueOwners = @($owners | Select-Object -Unique | Sort-Object)
        
        return @{ 
            Status = 'info'
            Details = "$($dbs.Count) database(s) in scope; $($uniqueOwners.Count) unique owner(s). See individual entries above."
        }
    }
#endregion

#region -- [07] Backups (Full) ----------------------------------------------
Register-CheckSection -File $global:__checkFile -Number 7 `
    -Title '[DB] Backups (Full)' `
    -Function 'Get-DbaLastBackup' `
    -Key 'BackupFull'

$backupFullResults = @()
if ($dbNamesAllHealthy.Count -gt 0) {
    foreach ($d in @($dbsAllHealthy)) {
        $last = $d.LastFullBackup
        if ($last -is [datetime] -and $last -eq [datetime]::MinValue) { $last = $null }
        $dt   = Get-DatabaseBackupDate $last
        $age  = ConvertTo-BackupAge $last
        $rm   = if ($d.PSObject.Properties['RecoveryModel']) { " (RecoveryModel: $([string]$d.RecoveryModel))" } else { '' }
        $st   = if ($null -eq $dt) { 'fail' }
                elseif (((Get-Date) - $dt).TotalHours -gt $minFullHours) { 'fail' }
                else { 'pass' }

        $backupFullResults += @{
            Database = $d.Name
            Status   = $st
            Details  = "$($d.Name) - last full backup: $age.$rm"
        }
    }

    $entrySplat = $global:CheckCat_Database['Get-DbaLastBackup']['BackupFullEntry']
    foreach ($result in $backupFullResults) {
        $Findings.Value += New-Finding @entrySplat `
            -Status  $result.Status `
            -Details $result.Details `
            -SpokeFile $spoke
    }
}

Invoke-Check -SpokeFile $spoke -CatalogName 'Database' -Function 'Get-DbaLastBackup' -Key 'BackupFull' `
    -Target $Target -Config $Config -Findings $Findings -Run {
        param($sql, $t, $cfg)

        if ($dbNamesAllHealthy.Count -eq 0) {
            return @{ Status='info'; Details='No eligible databases (none are Normal + accessible, or none in scope).' }
        }

        $failCount = @($backupFullResults | Where-Object { $_.Status -ne 'pass' }).Count
        $total     = $backupFullResults.Count

        if ($failCount -eq 0) {
            return @{ Status='pass'; Details="All $total database(s) have a full backup within the last $minFullHours hour(s). See individual entries above." }
        }
        return @{
            Status  = 'fail'
            Details = "$failCount of $total database(s) are missing or have a stale full backup (threshold: $minFullHours hours). See individual entries above."
        }
    }
#endregion

#region -- [08] Backups (Diff) ----------------------------------------------
Register-CheckSection -File $global:__checkFile -Number 8 `
    -Title '[DB] Backups (Diff)' `
    -Function 'Get-DbaLastBackup' `
    -Key 'BackupDiff'

$backupDiffResults = @()
if ($minDiffHours -gt 0 -and $dbNamesHealthy.Count -gt 0) {
    foreach ($d in @($dbsHealthy)) {
        $last  = $d.LastDiffBackup
        if ($last -is [datetime] -and $last -eq [datetime]::MinValue) { $last = $null }
        $dt    = Get-DatabaseBackupDate $last
        $age   = ConvertTo-BackupAge $last
        $rm    = if ($d.PSObject.Properties['RecoveryModel']) { [string]$d.RecoveryModel } else { '' }
        $rmStr = if ($rm) { " (RecoveryModel: $rm)" } else { '' }
        $st    = if ($null -eq $dt) { 'fail' }
                 elseif (((Get-Date) - $dt).TotalHours -gt $minDiffHours) { 'fail' }
                 else { 'pass' }

        $backupDiffResults += @{
            Database = $d.Name
            Status   = $st
            Details  = "$($d.Name) - last differential backup: $age.$rmStr"
        }
    }

    $entrySplat = $global:CheckCat_Database['Get-DbaLastBackup']['BackupDiffEntry']
    foreach ($result in $backupDiffResults) {
        $Findings.Value += New-Finding @entrySplat `
            -Status  $result.Status `
            -Details $result.Details `
            -SpokeFile $spoke
    }
}

Invoke-Check -SpokeFile $spoke -CatalogName 'Database' -Function 'Get-DbaLastBackup' -Key 'BackupDiff' `
    -Target $Target -Config $Config -Findings $Findings -Run {
        param($sql, $t, $cfg)

        if ($minDiffHours -le 0) {
            return @{ Status='info'; Details='DIFF backup check disabled (Database.MinBackupDiffHours <= 0).' }
        }
        if ($dbNamesHealthy.Count -eq 0) {
            return @{ Status='info'; Details='No eligible databases (none are Normal + accessible, or none in scope).' }
        }

        $failCount = @($backupDiffResults | Where-Object { $_.Status -ne 'pass' }).Count
        $eligible  = $backupDiffResults.Count

        if ($failCount -eq 0) {
            return @{ Status='pass'; Details="All $eligible eligible database(s) have a differential backup within the last $minDiffHours hour(s). See individual entries above." }
        }
        return @{
            Status  = 'fail'
            Details = "$failCount of $eligible eligible database(s) are missing or have a stale differential backup (threshold: $minDiffHours hours). See individual entries above."
        }
    }
#endregion

#region -- [09] Backups (Log) -----------------------------------------------
Register-CheckSection -File $global:__checkFile -Number 9 `
    -Title '[DB] Backups (Log)' `
    -Function 'Get-DbaLastBackup' `
    -Key 'BackupLog'

$backupLogResults = @()
if ($minLogMinutes -gt 0 -and $dbNamesHealthy.Count -gt 0) {
    foreach ($d in @($dbsHealthy)) {
        $rm = if ($d.PSObject.Properties['RecoveryModel']) {
            " (RecoveryModel: $([string]$d.RecoveryModel))"
        } else { '' }

        if ($rm -notmatch '(?i)Full|Bulk') {
            $backupLogResults += @{
                Database = $d.Name
                Status   = 'info'
                Details  = "$($d.Name) - log backup not required $rm."
                Skipped  = $true
            }
            continue
        }

        $last  = $d.LastLogBackup
        if ($last -is [datetime] -and $last -eq [datetime]::MinValue) { $last = $null }
        $dt    = Get-DatabaseBackupDate $last
        $age   = ConvertTo-BackupAge $last
        $rmStr = if ($rm) { $rm } else { '' }
        $st    = if ($null -eq $dt) { 'fail' }
                 elseif (((Get-Date) - $dt).TotalMinutes -gt $minLogMinutes) { 'fail' }
                 else { 'pass' }

        $backupLogResults += @{
            Database = $d.Name
            Status   = $st
            Details  = "$($d.Name) - last log backup: $age.$rmStr"
            Skipped  = $false
        }
    }

    $entrySplat = $global:CheckCat_Database['Get-DbaLastBackup']['BackupLogEntry']
    foreach ($result in $backupLogResults) {
        $Findings.Value += New-Finding @entrySplat `
            -Status  $result.Status `
            -Details $result.Details `
            -SpokeFile $spoke
    }
}

Invoke-Check -SpokeFile $spoke -CatalogName 'Database' -Function 'Get-DbaLastBackup' -Key 'BackupLog' `
    -Target $Target -Config $Config -Findings $Findings -Run {
        param($sql, $t, $cfg)

        if ($minLogMinutes -le 0) {
            return @{ Status='info'; Details='LOG backup check disabled (Database.MinBackupLogHours <= 0).' }
        }
        if ($dbNamesHealthy.Count -eq 0) {
            return @{ Status='info'; Details='No eligible databases (none are Normal + accessible, or none in scope).' }
        }

        $skipped   = @($backupLogResults | Where-Object { $_.Skipped -eq $true }).Count
        $eligible  = $backupLogResults.Count - $skipped
        $failCount = @($backupLogResults | Where-Object { $_.Status -eq 'fail' }).Count
        $skipNote  = if ($skipped -gt 0) { " ($skipped non-Full/BulkLogged database(s) not checked.)" } else { '' }

        if ($failCount -eq 0) {
            return @{ Status='pass'; Details="All $eligible eligible database(s) have a log backup within the last $minLogMinutes minute(s).$skipNote See individual entries above." }
        }
        return @{
            Status  = 'fail'
            Details = "$failCount of $eligible eligible database(s) are missing or have a stale log backup (threshold: $minLogMinutes minutes).$skipNote See individual entries above."
        }
    }
#endregion

#region -- [10] Recovery Model ----------------------------------------------
Register-CheckSection -File $global:__checkFile -Number 10 `
    -Title '[DB] Recovery Model' `
    -Function 'Test-DbaDbRecoveryModel' `
    -Key 'RecoveryModel'

# Process recovery model and create entry findings FIRST
$recoveryModelResults = @()
if ($dbNamesHealthy.Count -gt 0) {
    $expectedRm = $recoveryModelExpected.Trim()
    
    foreach ($d in @($dbsHealthy)) {
        $rm = if ($d.PSObject.Properties['RecoveryModel']) { [string]$d.RecoveryModel } else { 'Unknown' }
        $rmNorm = $rm.Trim()
        
        if ($recoveryModelComplianceEnabled) {
            $st = if ($rmNorm -eq $expectedRm) { 'pass' } else { 'attention' }
            $detail = if ($rmNorm -eq $expectedRm) {
                "Database: $($d.Name); Recovery Model: $rmNorm (compliant)"
            } else {
                "Database: $($d.Name); Current: $rmNorm; Expected: $expectedRm"
            }
        } else {
            $st = 'info'
            $detail = "Database: $($d.Name); Recovery Model: $rmNorm"
        }
        
        $recoveryModelResults += @{
            Database = $d.Name
            Status   = $st
            Details  = $detail
            RecoveryModel = $rmNorm
        }
    }
    
    # Create entry findings
    $entrySplat = $global:CheckCat_Database['Test-DbaDbRecoveryModel']['RecoveryModelEntry']
    foreach ($result in $recoveryModelResults) {
        $Findings.Value += New-Finding @entrySplat `
            -Status  $result.Status `
            -Details $result.Details `
            -SpokeFile $spoke
    }
}

Invoke-Check -SpokeFile $spoke -CatalogName 'Database' -Function 'Test-DbaDbRecoveryModel' -Key 'RecoveryModel' `
    -Target $Target -Config $Config -Findings $Findings -Run {
        param($sql, $t, $cfg)

        if ($dbNamesHealthy.Count -eq 0) { return @{ Status='info'; Details='No eligible databases.' } }

        # Build inventory
        $inventory = @{}
        foreach ($result in $recoveryModelResults) {
            $rm = $result.RecoveryModel
            if (-not $inventory.ContainsKey($rm)) { $inventory[$rm] = 0 }
            $inventory[$rm]++
        }
        
        $invStr = ($inventory.GetEnumerator() | 
            Sort-Object Key | 
            ForEach-Object { "$($_.Key): $($_.Value)" }) -join ', '

        if (-not $recoveryModelComplianceEnabled) {
            return @{ 
                Status  = 'info'
                Details = "Recovery model inventory: $invStr ($($dbNamesHealthy.Count) total). Compliance checking disabled (Database.RecoveryModelComplianceEnabled = false). See individual entries above."
            }
        }

        $compliantCount = @($recoveryModelResults | Where-Object { $_.Status -eq 'pass' }).Count
        $nonCompliantCount = @($recoveryModelResults | Where-Object { $_.Status -ne 'pass' }).Count
        $compliancePct = if ($dbNamesHealthy.Count -gt 0) {
            [math]::Round(($compliantCount / $dbNamesHealthy.Count) * 100, 1)
        } else { 0 }

        if ($nonCompliantCount -eq 0) {
            return @{ 
                Status  = 'pass'
                Details = "All $($dbNamesHealthy.Count) eligible database(s) are set to the expected recovery model: $recoveryModelExpected (100% compliant). Recovery model breakdown: $invStr. See individual entries above."
            }
        }

        return @{ 
            Status  = 'attention'
            Details = "Recovery model compliance: $compliancePct% ($compliantCount of $($dbNamesHealthy.Count) compliant). Expected: $recoveryModelExpected. Recovery model breakdown: $invStr. See individual entries above."
        }
    }
#endregion

#region -- [11] VLF Count ---------------------------------------------------
Register-CheckSection -File $global:__checkFile -Number 11 `
    -Title '[DB] VLF Count' `
    -Function 'Measure-DbaDbVirtualLogFile' `
    -Key 'VlfCount'

$vlfResults = @()
if ($dbNamesHealthy.Count -gt 0 -and $vlf) {
    $entrySplat = $global:CheckCat_Database['Measure-DbaDbVirtualLogFile']['VlfCountEntry']

    foreach ($row in @($vlf | Where-Object { $_.Database -in $dbNamesHealthy })) {
        $cnt = if ($row.PSObject.Properties['Total'])    { [int]$row.Total }
               elseif ($row.PSObject.Properties['VlfCount']) { [int]$row.VlfCount }
               else { continue }

        $logSizeMB = if ($row.PSObject.Properties['LogSizeMB']) { [math]::Round([double]$row.LogSizeMB, 1) } else { $null }

        $st = if    ($vlfFail -gt 0 -and $cnt -ge $vlfFail) { 'fail' }
              elseif ($vlfWarn -gt 0 -and $cnt -ge $vlfWarn) { 'attention' }
              else                                            { 'pass' }

        $vlfResults += @{ Database = $row.Database; Status = $st; VlfCount = $cnt; LogSizeMB = $logSizeMB }

        if ($st -ne 'pass') {
            $logNote = if ($null -ne $logSizeMB) { "; Log size: $logSizeMB MB" } else { '' }
            $Findings.Value += New-Finding @entrySplat -Status $st `
                -Details "Database: $($row.Database); VLF count: $cnt (warn>=$vlfWarn, fail>=$vlfFail)$logNote" `
                -SpokeFile $spoke
        }
    }
}

Invoke-Check -SpokeFile $spoke -CatalogName 'Database' -Function 'Measure-DbaDbVirtualLogFile' -Key 'VlfCount' `
    -Target $Target -Config $Config -Findings $Findings -Run {
        param($sql, $t, $cfg)

        if ($dbNamesHealthy.Count -eq 0) { return @{ Status='info';      Details='No eligible databases.' } }
        if (-not $vlf)                   { return @{ Status='attention'; Details='Could not measure VLFs (Measure-DbaDbVirtualLogFile returned no data).' } }
        if ($vlfResults.Count -eq 0)     { return @{ Status='info';      Details='No VLF data matched in-scope databases.' } }

        $failCount = @($vlfResults | Where-Object { $_.Status -eq 'fail' }).Count
        $attnCount = @($vlfResults | Where-Object { $_.Status -eq 'attention' }).Count

        if ($failCount -eq 0 -and $attnCount -eq 0) {
            return @{ Status='pass'; Details="All $($vlfResults.Count) eligible database(s) have acceptable VLF counts (warn>=$vlfWarn, fail>=$vlfFail)." }
        }

        $worst = if ($failCount -gt 0) { 'fail' } else { 'attention' }
        return @{
            Status  = $worst
            Details = "High VLF counts detected: $failCount fail, $attnCount attention out of $($vlfResults.Count) database(s) (warn>=$vlfWarn, fail>=$vlfFail). See individual entries above."
        }
    }
#endregion

#region -- [12] Collation Match ---------------------------------------------
Register-CheckSection -File $global:__checkFile -Number 12 `
    -Title '[DB] Collation Match' `
    -Function 'Test-DbaDbCollation' `
    -Key 'CollationMatch'

# Process collation and create entry findings FIRST
if ($dbNamesHealthy.Count -gt 0 -and $collation) {
    $non = @(
        $collation | Where-Object {
            $_.Database -in $dbNamesHealthy -and
            $_.PSObject.Properties['IsEqual'] -and
            (-not [bool]$_.IsEqual)
        }
    )
    
    if ($non.Count -gt 0) {
        $entrySplat = $global:CheckCat_Database['Test-DbaDbCollation']['CollationMatchEntry']
        foreach ($row in $non) {
            $Findings.Value += New-Finding @entrySplat -Status 'attention' `
                -Details ("Database: $($row.Database); DB collation: $($row.DatabaseCollation); Server collation: $($row.ServerCollation)") `
                -SpokeFile $spoke
        }
    }
}

Invoke-Check -SpokeFile $spoke -CatalogName 'Database' -Function 'Test-DbaDbCollation' -Key 'CollationMatch' `
    -Target $Target -Config $Config -Findings $Findings -Run {
        param($sql, $t, $cfg)

        if ($dbNamesHealthy.Count -eq 0) { return @{ Status='info'; Details='No eligible databases.' } }
        if (-not $collation) { return @{ Status='attention'; Details='Could not test collation match (Test-DbaDbCollation returned no data).' } }

        $non = @(
            $collation | Where-Object {
                $_.Database -in $dbNamesHealthy -and
                $_.PSObject.Properties['IsEqual'] -and
                (-not [bool]$_.IsEqual)
            }
        )
        
        if ($non.Count -eq 0) {
            return @{ Status='pass'; Details=('All {0} eligible database(s) match the server collation.' -f $dbNamesHealthy.Count) }
        }

        return @{ Status='attention'; Details=('Collation mismatch(es) detected. See individual entries above.') }
    }
#endregion

#region -- [13] File Growth Type --------------------------------------------
Register-CheckSection -File $global:__checkFile -Number 13 `
    -Title '[DB] File Growth Type' `
    -Function 'Get-DbaDbFile' `
    -Key 'FileGrowthType'

# Process file growth and create entry findings FIRST
if ($dbNames.Count -gt 0 -and $dbFiles) {
    $pctFiles = @($dbFiles | Where-Object { ([string]$_.GrowthType) -match '(?i)percent' })
    
    if ($pctFiles.Count -gt 0) {
        $st = if ($allowPctGrowth) { 'attention' } else { 'fail' }
        $dbsPct = @($pctFiles | Group-Object Database)
        $entrySplat = $global:CheckCat_Database['Get-DbaDbFile']['FileGrowthTypeEntry']
        
        foreach ($g in $dbsPct) {
            $growthPcts = ($g.Group | ForEach-Object {
                $pct = if ($_.PSObject.Properties['Growth']) { $_.Growth } else { '?' }
                "$($_.LogicalName)=$pct%"
            }) -join '; '
            $Findings.Value += New-Finding @entrySplat -Status $st `
                -Details ("Database: $($g.Name); File(s) with percent growth: $growthPcts") `
                -SpokeFile $spoke
        }
    }
}

Invoke-Check -SpokeFile $spoke -CatalogName 'Database' -Function 'Get-DbaDbFile' -Key 'FileGrowthType' `
    -Target $Target -Config $Config -Findings $Findings -Run {
        param($sql, $t, $cfg)

        if ($dbNames.Count -eq 0) { return @{ Status='info'; Details='No databases in scope.' } }
        if (-not $dbFiles) { return @{ Status='attention'; Details='Could not retrieve DB file layout (Get-DbaDbFile returned no data).' } }

        $pctFiles = @($dbFiles | Where-Object { ([string]$_.GrowthType) -match '(?i)percent' })
        
        if ($pctFiles.Count -eq 0) {
            return @{ Status='pass'; Details=('No database files use percent growth ({0} database(s) checked).' -f $dbNames.Count) }
        }

        $st = if ($allowPctGrowth) { 'attention' } else { 'fail' }
        return @{ Status=$st; Details=('Percent-growth files detected in database(s). See individual entries above.') }
    }
#endregion

#region -- [14] File Placement ----------------------------------------------
Register-CheckSection -File $global:__checkFile -Number 14 `
    -Title '[DB] File Placement' `
    -Function 'Get-DbaDbFile' `
    -Key 'FilePlacement'

# Process file placement and create entry findings FIRST
if ($dbNames.Count -gt 0 -and $dbFiles) {
    $entrySplat = $global:CheckCat_Database['Get-DbaDbFile']['FilePlacementEntry']

    foreach ($dbName in $dbNames) {
        $files = @($dbFiles | Where-Object { $_.Database -eq $dbName })
        if ($files.Count -eq 0) { continue }
        
        $dataDrives = @(); $logDrives = @(); $onC = $false
        foreach ($f in $files) {
            $drv = Get-DatabaseDriveTag -Path ([string]$f.PhysicalName)
            if ($drv -eq 'C:') { $onC = $true }
            if (([string]$f.Type) -match '(?i)log') { if ($drv) { $logDrives  += $drv } }
            else                                    { if ($drv) { $dataDrives += $drv } }
        }
        $dataDrives = @($dataDrives | Sort-Object -Unique)
        $logDrives  = @($logDrives  | Sort-Object -Unique)
        $sameDrive  = $false
        foreach ($d in $dataDrives) { if ($logDrives -contains $d) { $sameDrive = $true } }

        if ($onC -or $sameDrive) {
            $bits = @()
            if ($onC)      { $bits += 'files on C:' }
            if ($sameDrive){ $bits += 'data/log share drive' }

            $Findings.Value += New-Finding @entrySplat -Status 'attention' `
                -Details ("Database: $dbName; Issue(s): $($bits -join '; ')") `
                -SpokeFile $spoke
        }
    }
}

Invoke-Check -SpokeFile $spoke -CatalogName 'Database' -Function 'Get-DbaDbFile' -Key 'FilePlacement' `
    -Target $Target -Config $Config -Findings $Findings -Run {
        param($sql, $t, $cfg)

        if ($dbNames.Count -eq 0) { return @{ Status='info'; Details='No databases in scope.' } }
        if (-not $dbFiles) { return @{ Status='attention'; Details='Could not retrieve DB file layout (Get-DbaDbFile returned no data).' } }

        # Count issues from entries already created
        $issueCount = @($Findings.Value | Where-Object { 
            $_.Label -eq 'File Placement - Entry' -and $_.Status -eq 'attention' 
        }).Count

        if ($issueCount -eq 0) {
            return @{ Status='pass'; Details=('No file placement issues detected across {0} database(s).' -f $dbNames.Count) }
        }
        return @{ Status='attention'; Details=('File placement issues detected. See individual entries above.') }
    }
#endregion

#region -- [15] MAXDOP ------------------------------------------------------
Register-CheckSection -File $global:__checkFile -Number 15 `
    -Title '[DB] MAXDOP' `
    -Function 'Test-DbaMaxDop' `
    -Key 'DbMaxDop'

# Test-DbaMaxDop returns one instance-level row (Database='N/A') plus one row
# per database. Compliance is derived: a DB-scoped MAXDOP of 0 means "inherit
# from instance" which is the recommended/safe state; otherwise it must equal
# RecommendedMaxDop.
$maxdopDbRows = @()
if ($maxdop) {
    $maxdopDbRows = @(
        $maxdop | Where-Object {
            ([string]$_.Database) -ne 'N/A' -and
            ([string]$_.Database) -in $dbNamesHealthy
        }
    )
}

if ($maxdopDbRows.Count -gt 0) {
    $non = @(
        $maxdopDbRows | Where-Object {
            $dbMaxDop  = [int]$_.DatabaseMaxDop
            $recMaxDop = [int]$_.RecommendedMaxDop
            # Non-compliant only when explicitly set AND wrong
            $dbMaxDop -ne 0 -and $dbMaxDop -ne $recMaxDop
        }
    )

    if ($non.Count -gt 0) {
        $entrySplat = $global:CheckCat_Database['Test-DbaMaxDop']['DbMaxDopEntry']
        foreach ($row in $non) {
            $Findings.Value += New-Finding @entrySplat -Status 'attention' `
                -Details ("Database: $($row.Database); DB-scoped MAXDOP: $($row.DatabaseMaxDop); Recommended: $($row.RecommendedMaxDop)") `
                -SpokeFile $spoke
        }
    }
}

Invoke-Check -SpokeFile $spoke -CatalogName 'Database' -Function 'Test-DbaMaxDop' -Key 'DbMaxDop' `
    -Target $Target -Config $Config -Findings $Findings -Run {
        param($sql, $t, $cfg)

        if ($dbNamesHealthy.Count -eq 0) { return @{ Status='info'; Details='No eligible databases.' } }
        if (-not $maxdop) {
            return @{ Status='attention'; Details='Could not evaluate MAXDOP (Test-DbaMaxDop returned no data).' }
        }
        if ($maxdopDbRows.Count -eq 0) {
            # Cmdlet returned data but no per-DB rows matched in-scope names.
            # This is normal when all DBs defer to instance (Database='N/A' only).
            return @{ Status='pass'; Details=('Test-DbaMaxDop returned no per-database rows for {0} in-scope database(s); all databases are deferring to the instance-level MAXDOP setting.' -f $dbNamesHealthy.Count) }
        }

        $non = @(
            $maxdopDbRows | Where-Object {
                $dbMaxDop  = [int]$_.DatabaseMaxDop
                $recMaxDop = [int]$_.RecommendedMaxDop
                $dbMaxDop -ne 0 -and $dbMaxDop -ne $recMaxDop
            }
        )

        if ($non.Count -eq 0) {
            return @{ Status='pass'; Details=('All {0} eligible database(s) have compliant MAXDOP settings (0 = defer to instance, or matches recommended).' -f $maxdopDbRows.Count) }
        }

        return @{ Status='attention'; Details=('Noncompliant DB-scoped MAXDOP on {0} of {1} database(s). See individual entries above.' -f $non.Count, $maxdopDbRows.Count) }
    }
#endregion

#region -- [16] Compatibility Level -----------------------------------------
Register-CheckSection -File $global:__checkFile -Number 16 `
    -Title '[DB] Compatibility Level' `
    -Function 'Test-DbaDbCompatibility' `
    -Key 'DbCompatibility'

# Process compatibility and create entry findings FIRST.
# Output shape: ServerLevel='Version160', DatabaseCompatibility='Version160', IsEqual=bool.
$compatResults = @()
if ($dbNamesHealthy.Count -gt 0 -and $compat) {

    # Derive server max compat from the ServerLevel property (e.g. "Version160" -> 160).
    # Take the first row that has a parseable ServerLevel - all rows share the same server level.
    $serverMaxCompat = 0
    $firstCompatRow = @($compat | Where-Object { $_.PSObject.Properties['ServerLevel'] }) | Select-Object -First 1
    if ($firstCompatRow) {
        $slStr = [string]$firstCompatRow.ServerLevel
        if ($slStr -match 'Version(\d+)') { $serverMaxCompat = [int]$Matches[1] }
    }

    foreach ($row in @($compat | Where-Object { $_.Database -in $dbNamesHealthy })) {
        $dbCompatStr = [string]$row.DatabaseCompatibility
        $currentCompat = if ($dbCompatStr -match 'Version(\d+)') { [int]$Matches[1] } else { 0 }
        $isCompliant   = $row.PSObject.Properties['IsEqual'] -and [bool]$row.IsEqual

        if ($compatComplianceEnabled) {
            $st = if ($isCompliant) { 'pass' } else { 'attention' }
            $detail = if ($isCompliant) {
                "Database: $($row.Database); Compatibility Level: $currentCompat (compliant with server maximum: $serverMaxCompat)"
            } else {
                "Database: $($row.Database); Current: $currentCompat; Recommended: $serverMaxCompat"
            }
        } else {
            $st     = 'info'
            $detail = "Database: $($row.Database); Compatibility Level: $currentCompat"
        }

        $compatResults += @{
            Database = $row.Database
            Status   = $st
            Details  = $detail
            Level    = $currentCompat
        }
    }

    # Create entry findings
    $entrySplat = $global:CheckCat_Database['Test-DbaDbCompatibility']['DbCompatibilityEntry']
    foreach ($result in $compatResults) {
        $Findings.Value += New-Finding @entrySplat `
            -Status   $result.Status `
            -Details  $result.Details `
            -SpokeFile $spoke
    }
}

Invoke-Check -SpokeFile $spoke -CatalogName 'Database' -Function 'Test-DbaDbCompatibility' -Key 'DbCompatibility' `
    -Target $Target -Config $Config -Findings $Findings -Run {
        param($sql, $t, $cfg)

        if ($dbNamesHealthy.Count -eq 0) { return @{ Status='info'; Details='No eligible databases.' } }
        if (-not $compat)                { return @{ Status='attention'; Details='Could not evaluate compatibility (Test-DbaDbCompatibility returned no data).' } }
        if ($compatResults.Count -eq 0)  { return @{ Status='attention'; Details='Test-DbaDbCompatibility returned data but no rows matched in-scope databases.' } }

        # Re-derive server max compat from results (closure cannot see pre-region variables)
        $serverMaxCompat = 0
        $firstCompatRow  = @($compat | Where-Object { $_.PSObject.Properties['ServerLevel'] }) | Select-Object -First 1
        if ($firstCompatRow) {
            $slStr = [string]$firstCompatRow.ServerLevel
            if ($slStr -match 'Version(\d+)') { $serverMaxCompat = [int]$Matches[1] }
        }

        # Build inventory string
        $inventory = @{}
        foreach ($result in $compatResults) {
            $lvl = $result.Level
            if (-not $inventory.ContainsKey($lvl)) { $inventory[$lvl] = 0 }
            $inventory[$lvl]++
        }
        $invStr = ($inventory.GetEnumerator() |
            Sort-Object Key -Descending |
            ForEach-Object {
                $lvl = if ($_.Key -eq 0) { 'Unknown' } else { [string]$_.Key }
                "$lvl`: $($_.Value)"
            }) -join ', '

        if (-not $compatComplianceEnabled) {
            return @{
                Status  = 'info'
                Details = "Compatibility level inventory: $invStr ($($compatResults.Count) total). Server maximum: $serverMaxCompat. Compliance checking disabled (Database.CompatibilityLevelComplianceEnabled = false). See individual entries above."
            }
        }

        $compliantCount    = @($compatResults | Where-Object { $_.Status -eq 'pass' }).Count
        $nonCompliantCount = @($compatResults | Where-Object { $_.Status -ne 'pass' }).Count
        $compliancePct     = [math]::Round(($compliantCount / $compatResults.Count) * 100, 1)

        if ($nonCompliantCount -eq 0) {
            return @{
                Status  = 'pass'
                Details = "All $($compatResults.Count) eligible database(s) are at the recommended compatibility level: $serverMaxCompat (100% compliant). Compatibility level breakdown: $invStr. See individual entries above."
            }
        }

        return @{
            Status  = 'attention'
            Details = "Compatibility level compliance: $compliancePct% ($compliantCount of $($compatResults.Count) compliant). Recommended: $serverMaxCompat. Compatibility level breakdown: $invStr. See individual entries above."
        }
    }
#endregion

#region -- [17] Owner Compliance --------------------------------------------
Register-CheckSection -File $global:__checkFile -Number 17 `
    -Title '[DB] Owner Compliance' `
    -Function 'Test-DbaDbOwner' `
    -Key 'DbOwnerCompliance'

# Process owner compliance and create entry findings FIRST
if ($ownerChkOn -and $dbNames.Count -gt 0 -and $dbsRaw) {
    $expected = $ownerExpected.Trim().ToLowerInvariant()
    $bad = @()
    
    foreach ($d in @($dbs)) {
        $o = Get-DatabaseOwnerName -Database $d
        if (([string]$o).Trim().ToLowerInvariant() -ne $expected) {
            $bad += [PSCustomObject]@{ Name = $d.Name; Owner = $o }
        }
    }

    if ($bad.Count -gt 0) {
        $entrySplat = $global:CheckCat_Database['Test-DbaDbOwner']['DbOwnerComplianceEntry']
        foreach ($b in $bad) {
            $Findings.Value += New-Finding @entrySplat -Status 'attention' `
                -Details ("Database: $($b.Name); Current owner: $($b.Owner); Expected: $ownerExpected") `
                -SpokeFile $spoke
        }
    }
}

Invoke-Check -SpokeFile $spoke -CatalogName 'Database' -Function 'Test-DbaDbOwner' -Key 'DbOwnerCompliance' `
    -Target $Target -Config $Config -Findings $Findings -Run {
        param($sql, $t, $cfg)

        if (-not $ownerChkOn) { return @{ Status='info'; Details='DB owner compliance check disabled (Database.DbOwnerComplianceEnabled = false).' } }
        if (-not $dbsRaw) { return @{ Status='attention'; Details='Could not enumerate databases (Get-DbaDatabase returned no data).' } }
        if ($dbNames.Count -eq 0) { return @{ Status='info'; Details='No databases in scope.' } }
        if ([string]::IsNullOrWhiteSpace($ownerExpected)) {
            return @{ Status='attention'; Details='Owner compliance is enabled but Database.DbOwnerExpectedPrincipal is blank.' }
        }

        $expected = $ownerExpected.Trim().ToLowerInvariant()
        $bad = @()
        
        foreach ($d in @($dbs)) {
            $o = Get-DatabaseOwnerName -Database $d
            if (([string]$o).Trim().ToLowerInvariant() -ne $expected) {
                $bad += $d.Name
            }
        }

        if ($bad.Count -eq 0) {
            return @{ Status='pass'; Details=('All {0} in-scope database(s) are owned by {1}.' -f $dbNames.Count, $ownerExpected) }
        }

        return @{ Status='attention'; Details=('DB owner mismatch(es) vs {0}. See individual entries above.' -f $ownerExpected) }
    }
#endregion

#region -- [18] Feature Usage -----------------------------------------------
Register-CheckSection -File $global:__checkFile -Number 18 `
    -Title '[DB] Feature Usage (Inventory)' `
    -Function 'Get-DbaDbFeatureUsage' `
    -Key 'FeatureUsage'

# Entry findings only emitted when the feature is enabled
if ($featureUsageEnabled -and $dbNames.Count -gt 0) {
    $rows = @()
    if ($featureUsage) {
        $rows = @($featureUsage | Where-Object { $_.Database -in $dbNames })
    }

    $dbsWithFeatures    = @()
    $dbsWithoutFeatures = @()

    if ($rows.Count -gt 0) {
        $groupedByDb = $rows | Group-Object -Property Database

        foreach ($g in $groupedByDb) {
            $dbName   = $g.Name
            $features = @($g.Group | Select-Object -ExpandProperty Feature -Unique | Sort-Object)
            $dbsWithFeatures += $dbName

            $entrySplat = $global:CheckCat_Database['Get-DbaDbFeatureUsage']['FeatureUsageEntry']
            $Findings.Value += New-Finding @entrySplat -Status 'attention' `
                -Details ("Database: $dbName; Enterprise features detected ($($features.Count)): $($features -join ', ')") `
                -SpokeFile $spoke
        }

        $dbsWithoutFeatures = @($dbNames | Where-Object { $_ -notin $dbsWithFeatures })
    } else {
        $dbsWithoutFeatures = @($dbNames)
    }

    $entrySplat = $global:CheckCat_Database['Get-DbaDbFeatureUsage']['FeatureUsageEntry']
    foreach ($dbName in $dbsWithoutFeatures) {
        $Findings.Value += New-Finding @entrySplat -Status 'info' `
            -Details ("Database: $dbName; No Enterprise features detected") `
            -SpokeFile $spoke
    }
}

Invoke-Check -SpokeFile $spoke -CatalogName 'Database' -Function 'Get-DbaDbFeatureUsage' -Key 'FeatureUsage' `
    -Target $Target -Config $Config -Findings $Findings -Run {
        param($sql, $t, $cfg)

        if (-not $featureUsageEnabled) {
            return @{ Status='info'; Details='Feature usage scan disabled (Database.FeatureUsageEnabled = false).' }
        }
        if ($dbNames.Count -eq 0) {
            return @{ Status='info'; Details='No databases in scope.' }
        }

        $rows = @()
        if ($featureUsage) {
            $rows = @($featureUsage | Where-Object { $_.Database -in $dbNames })
        }

        $dbsWithFeaturesCount = 0
        if ($rows.Count -gt 0) {
            $dbsWithFeaturesCount = @($rows | Group-Object -Property Database).Count
        }

        if ($dbsWithFeaturesCount -eq 0) {
            return @{
                Status  = 'pass'
                Details = "Enterprise feature usage: $($dbNames.Count) database(s) checked, 0 have Enterprise features. All databases are using Standard/Express-compatible features only. See individual entries above."
            }
        }

        $allUniqueFeatures  = @($rows | Select-Object -ExpandProperty Feature -Unique | Sort-Object)
        $uniqueFeatureCount = $allUniqueFeatures.Count

        return @{
            Status  = 'attention'
            Details = "Enterprise feature usage: $($dbNames.Count) database(s) checked, $dbsWithFeaturesCount have Enterprise features. Total unique Enterprise features detected: $uniqueFeatureCount ($($allUniqueFeatures -join ', ')). See individual entries above."
        }
    }
#endregion

#region -- [19] Auto Shrink -------------------------------------------------
Register-CheckSection -File $global:__checkFile -Number 19 `
    -Title '[DB] Auto Shrink' `
    -Function 'Get-DbaDatabase' `
    -Key 'AutoShrink'

# Process auto shrink and create entry findings FIRST
if ($dbNames.Count -gt 0 -and $dbsRaw) {
    $bad = @()
    foreach ($d in @($dbs)) {
        $v = $null
        if ($d.PSObject.Properties['AutoShrink']) { $v = $d.AutoShrink }
        elseif ($d.PSObject.Properties['AutoShrinkEnabled']) { $v = $d.AutoShrinkEnabled }
        if ($null -eq $v) { continue }
        if ([bool]$v) { $bad += $d.Name }
    }

    if ($bad.Count -gt 0) {
        $st = if ($requireAutoShrinkOff) { 'fail' } else { 'attention' }
        $entrySplat = $global:CheckCat_Database['Get-DbaDatabase']['AutoShrinkEntry']
        foreach ($n in $bad) {
            $Findings.Value += New-Finding @entrySplat -Status $st `
                -Details ("Database: $n; AutoShrink: ON") `
                -SpokeFile $spoke
        }
    }
}

Invoke-Check -SpokeFile $spoke -CatalogName 'Database' -Function 'Get-DbaDatabase' -Key 'AutoShrink' `
    -Target $Target -Config $Config -Findings $Findings -Run {
        param($sql, $t, $cfg)

        if ($dbNames.Count -eq 0) { return @{ Status='info'; Details='No databases in scope.' } }
        if (-not $dbsRaw) { return @{ Status='attention'; Details='Could not enumerate databases (Get-DbaDatabase returned no data).' } }

        $bad = @()
        foreach ($d in @($dbs)) {
            $v = $null
            if ($d.PSObject.Properties['AutoShrink']) { $v = $d.AutoShrink }
            elseif ($d.PSObject.Properties['AutoShrinkEnabled']) { $v = $d.AutoShrinkEnabled }
            if ($null -eq $v) { continue }
            if ([bool]$v) { $bad += $d.Name }
        }

        if ($bad.Count -eq 0) {
            return @{ Status='pass'; Details=('Auto Shrink is OFF on all {0} in-scope database(s) (desired).' -f $dbNames.Count) }
        }

        $st = if ($requireAutoShrinkOff) { 'fail' } else { 'attention' }
        return @{ Status=$st; Details=('Auto Shrink is ON for {0} of {1} database(s) - known anti-pattern causing fragmentation and I/O overhead. See individual entries above.' -f $bad.Count, $dbNames.Count) }
    }
#endregion

#region -- [20] Auto Close --------------------------------------------------
Register-CheckSection -File $global:__checkFile -Number 20 `
    -Title '[DB] Auto Close' `
    -Function 'Get-DbaDatabase' `
    -Key 'AutoClose'

# Process auto close and create entry findings FIRST
if ($dbNames.Count -gt 0 -and $dbsRaw) {
    $bad = @()
    foreach ($d in @($dbs)) {
        $v = $null
        if ($d.PSObject.Properties['AutoClose']) { $v = $d.AutoClose }
        if ($null -eq $v) { continue }
        if ([bool]$v) { $bad += $d.Name }
    }

    if ($bad.Count -gt 0) {
        $st = if ($requireAutoCloseOff) { 'fail' } else { 'attention' }
        $entrySplat = $global:CheckCat_Database['Get-DbaDatabase']['AutoCloseEntry']
        foreach ($n in $bad) {
            $Findings.Value += New-Finding @entrySplat -Status $st `
                -Details ("Database: $n; AutoClose: ON") `
                -SpokeFile $spoke
        }
    }
}

Invoke-Check -SpokeFile $spoke -CatalogName 'Database' -Function 'Get-DbaDatabase' -Key 'AutoClose' `
    -Target $Target -Config $Config -Findings $Findings -Run {
        param($sql, $t, $cfg)

        if ($dbNames.Count -eq 0) { return @{ Status='info'; Details='No databases in scope.' } }
        if (-not $dbsRaw) { return @{ Status='attention'; Details='Could not enumerate databases (Get-DbaDatabase returned no data).' } }

        $bad = @()
        foreach ($d in @($dbs)) {
            $v = $null
            if ($d.PSObject.Properties['AutoClose']) { $v = $d.AutoClose }
            if ($null -eq $v) { continue }
            if ([bool]$v) { $bad += $d.Name }
        }

        if ($bad.Count -eq 0) {
            return @{ Status='pass'; Details=('Auto Close is OFF on all {0} in-scope database(s) (desired).' -f $dbNames.Count) }
        }

        $st = if ($requireAutoCloseOff) { 'fail' } else { 'attention' }
        return @{ Status=$st; Details=('Auto Close is ON for {0} of {1} database(s) - causes repeated connection overhead and resource cache flushes. See individual entries above.' -f $bad.Count, $dbNames.Count) }
    }
#endregion

#region -- [21] Page Verify -------------------------------------------------
Register-CheckSection -File $global:__checkFile -Number 21 `
    -Title '[DB] Page Verify' `
    -Function 'Get-DbaDatabase' `
    -Key 'PageVerify'

# Process page verify and create entry findings FIRST
if ($dbNames.Count -gt 0 -and $dbsRaw) {
    $bad = @()
    foreach ($d in @($dbs)) {
        $v = $null
        if ($d.PSObject.Properties['PageVerify']) { $v = [string]$d.PageVerify }
        elseif ($d.PSObject.Properties['PageVerifyMode']) { $v = [string]$d.PageVerifyMode }
        if ($null -eq $v) { continue }
        if ($v -notmatch '(?i)checksum') { $bad += [PSCustomObject]@{ Name = $d.Name; Setting = $v } }
    }

    if ($bad.Count -gt 0) {
        $st = if ($requirePageVerify) { 'fail' } else { 'attention' }
        $entrySplat = $global:CheckCat_Database['Get-DbaDatabase']['PageVerifyEntry']
        foreach ($b in $bad) {
            $Findings.Value += New-Finding @entrySplat -Status $st `
                -Details ("Database: $($b.Name); PageVerify: $($b.Setting)") `
                -SpokeFile $spoke
        }
    }
}

Invoke-Check -SpokeFile $spoke -CatalogName 'Database' -Function 'Get-DbaDatabase' -Key 'PageVerify' `
    -Target $Target -Config $Config -Findings $Findings -Run {
        param($sql, $t, $cfg)

        if ($dbNames.Count -eq 0) { return @{ Status='info'; Details='No databases in scope.' } }
        if (-not $dbsRaw) { return @{ Status='attention'; Details='Could not enumerate databases (Get-DbaDatabase returned no data).' } }

        $bad = @()
        foreach ($d in @($dbs)) {
            $v = $null
            if ($d.PSObject.Properties['PageVerify']) { $v = [string]$d.PageVerify }
            elseif ($d.PSObject.Properties['PageVerifyMode']) { $v = [string]$d.PageVerifyMode }
            if ($null -eq $v) { continue }
            if ($v -notmatch '(?i)checksum') { $bad += $d.Name }
        }

        if ($bad.Count -eq 0) {
            return @{ Status='pass'; Details=('All {0} in-scope database(s) have PAGE_VERIFY = CHECKSUM (desired).' -f $dbNames.Count) }
        }

        $st = if ($requirePageVerify) { 'fail' } else { 'attention' }
        return @{ Status=$st; Details=('PAGE_VERIFY is not CHECKSUM on {0} of {1} database(s) - torn-page detection is reduced. See individual entries above.' -f $bad.Count, $dbNames.Count) }
    }
#endregion

#region -- [22] TRUSTWORTHY -------------------------------------------------
Register-CheckSection -File $global:__checkFile -Number 22 `
    -Title '[DB] TRUSTWORTHY' `
    -Function 'Get-DbaDatabase' `
    -Key 'Trustworthy'

# Process trustworthy and create entry findings FIRST
if ($dbNames.Count -gt 0 -and $dbsRaw) {
    $bad = @()
    foreach ($d in @($dbs)) {
        $v = $null
        if ($d.PSObject.Properties['Trustworthy']) { $v = $d.Trustworthy }
        elseif ($d.PSObject.Properties['IsTrustworthy']) { $v = $d.IsTrustworthy }
        if ($null -eq $v -or -not [bool]$v) { continue }
        $nameNorm = ([string]$d.Name).ToLowerInvariant()
        if ($trustworthyAllowList -contains $nameNorm) { continue }
        $bad += $d.Name
    }

    if ($bad.Count -gt 0) {
        $st = if ($requireTrustworthyOff) { 'fail' } else { 'attention' }
        $note = if ($trustworthyAllowList.Count -gt 0) { " (allow-list: $($trustworthyAllowList -join ', '))" } else { '' }
        $entrySplat = $global:CheckCat_Database['Get-DbaDatabase']['TrustworthyEntry']
        foreach ($n in $bad) {
            $Findings.Value += New-Finding @entrySplat -Status $st `
                -Details ("Database: $n; Trustworthy: ON$note") `
                -SpokeFile $spoke
        }
    }
}

Invoke-Check -SpokeFile $spoke -CatalogName 'Database' -Function 'Get-DbaDatabase' -Key 'Trustworthy' `
    -Target $Target -Config $Config -Findings $Findings -Run {
        param($sql, $t, $cfg)

        if ($dbNames.Count -eq 0) { return @{ Status='info'; Details='No databases in scope.' } }
        if (-not $dbsRaw) { return @{ Status='attention'; Details='Could not enumerate databases (Get-DbaDatabase returned no data).' } }

        $bad = @()
        foreach ($d in @($dbs)) {
            $v = $null
            if ($d.PSObject.Properties['Trustworthy']) { $v = $d.Trustworthy }
            elseif ($d.PSObject.Properties['IsTrustworthy']) { $v = $d.IsTrustworthy }
            if ($null -eq $v -or -not [bool]$v) { continue }
            $nameNorm = ([string]$d.Name).ToLowerInvariant()
            if ($trustworthyAllowList -contains $nameNorm) { continue }
            $bad += $d.Name
        }

        if ($bad.Count -eq 0) {
            return @{ Status='pass'; Details=('TRUSTWORTHY = OFF on all {0} in-scope database(s) (desired).' -f $dbNames.Count) }
        }

        $st = if ($requireTrustworthyOff) { 'fail' } else { 'attention' }
        $note = if ($trustworthyAllowList.Count -gt 0) { " (allow-list: $($trustworthyAllowList -join ', '))" } else { '' }
        return @{ Status=$st; Details=('TRUSTWORTHY = ON on {0} of {1} database(s) - known privilege-escalation attack vector{2}. See individual entries above.' -f $bad.Count, $dbNames.Count, $note) }
    }
#endregion

#region -- [23] TDE / Encryption --------------------------------------------
Register-CheckSection -File $global:__checkFile -Number 23 `
    -Title '[DB] TDE / Encryption' `
    -Function 'Get-DbaDatabase' `
    -Key 'TdeEnabled'

# Process TDE and create entry findings FIRST (only when RequireTde = true)
if ($requireTde -and $dbNames.Count -gt 0 -and $dbsRaw) {
    $unencrypted = @()
    foreach ($d in @($dbs)) {
        $v = $null
        if ($d.PSObject.Properties['EncryptionEnabled']) { $v = $d.EncryptionEnabled }
        elseif ($d.PSObject.Properties['IsEncrypted']) { $v = $d.IsEncrypted }
        if ($null -eq $v) { $unencrypted += $d.Name; continue }
        if (-not [bool]$v) { $unencrypted += $d.Name }
    }

    if ($unencrypted.Count -gt 0) {
        $entrySplat = $global:CheckCat_Database['Get-DbaDatabase']['TdeEnabledEntry']
        foreach ($n in $unencrypted) {
            $Findings.Value += New-Finding @entrySplat -Status 'fail' `
                -Details ("Database: $n; TDE: NOT enabled") `
                -SpokeFile $spoke
        }
    }
}

Invoke-Check -SpokeFile $spoke -CatalogName 'Database' -Function 'Get-DbaDatabase' -Key 'TdeEnabled' `
    -Target $Target -Config $Config -Findings $Findings -Run {
        param($sql, $t, $cfg)

        if ($dbNames.Count -eq 0) { return @{ Status='info'; Details='No databases in scope.' } }
        if (-not $dbsRaw) { return @{ Status='attention'; Details='Could not enumerate databases (Get-DbaDatabase returned no data).' } }

        $encrypted = @(); $unencrypted = @()
        foreach ($d in @($dbs)) {
            $v = $null
            if ($d.PSObject.Properties['EncryptionEnabled']) { $v = $d.EncryptionEnabled }
            elseif ($d.PSObject.Properties['IsEncrypted']) { $v = $d.IsEncrypted }
            if ($null -eq $v) { $unencrypted += $d.Name; continue }
            if ([bool]$v) { $encrypted += $d.Name } else { $unencrypted += $d.Name }
        }

        if (-not $requireTde) {
            $details = 'TDE inventory: {0} of {1} database(s) encrypted.' -f $encrypted.Count, $dbNames.Count
            return @{ Status='info'; Details=$details }
        }

        if ($unencrypted.Count -eq 0) {
            return @{ Status='pass'; Details=('All {0} in-scope database(s) have TDE enabled.' -f $dbNames.Count) }
        }

        return @{ Status='fail'; Details=('{0} of {1} database(s) do not have TDE enabled. See individual entries above.' -f $unencrypted.Count, $dbNames.Count) }
    }
#endregion

#region -- [24] Auto Update Statistics --------------------------------------
Register-CheckSection -File $global:__checkFile -Number 24 `
    -Title '[DB] Auto Update Statistics' `
    -Function 'Get-DbaDatabase' `
    -Key 'AutoUpdateStats'

# Process auto update stats and create entry findings FIRST
if ($dbNames.Count -gt 0 -and $dbsRaw) {
    $bad = @()
    foreach ($d in @($dbs)) {
        $v = $null
        if ($d.PSObject.Properties['AutoUpdateStatisticsEnabled']) { $v = $d.AutoUpdateStatisticsEnabled }
        elseif ($d.PSObject.Properties['AutoUpdateStatistics']) { $v = $d.AutoUpdateStatistics }
        if ($null -eq $v) { continue }
        if (-not [bool]$v) { $bad += $d.Name }
    }

    if ($bad.Count -gt 0) {
        $st = if ($requireAutoUpdateStats) { 'fail' } else { 'attention' }
        $entrySplat = $global:CheckCat_Database['Get-DbaDatabase']['AutoUpdateStatsEntry']
        foreach ($n in $bad) {
            $Findings.Value += New-Finding @entrySplat -Status $st `
                -Details ("Database: $n; AutoUpdateStatistics: OFF") `
                -SpokeFile $spoke
        }
    }
}

Invoke-Check -SpokeFile $spoke -CatalogName 'Database' -Function 'Get-DbaDatabase' -Key 'AutoUpdateStats' `
    -Target $Target -Config $Config -Findings $Findings -Run {
        param($sql, $t, $cfg)

        if ($dbNames.Count -eq 0) { return @{ Status='info'; Details='No databases in scope.' } }
        if (-not $dbsRaw) { return @{ Status='attention'; Details='Could not enumerate databases (Get-DbaDatabase returned no data).' } }

        $bad = @()
        foreach ($d in @($dbs)) {
            $v = $null
            if ($d.PSObject.Properties['AutoUpdateStatisticsEnabled']) { $v = $d.AutoUpdateStatisticsEnabled }
            elseif ($d.PSObject.Properties['AutoUpdateStatistics']) { $v = $d.AutoUpdateStatistics }
            if ($null -eq $v) { continue }
            if (-not [bool]$v) { $bad += $d.Name }
        }

        if ($bad.Count -eq 0) {
            return @{ Status='pass'; Details=('Auto Update Statistics is ON for all {0} in-scope database(s) (desired).' -f $dbNames.Count) }
        }

        $st = if ($requireAutoUpdateStats) { 'fail' } else { 'attention' }
        return @{ Status=$st; Details=('Auto Update Statistics is OFF for {0} of {1} database(s) - stale statistics cause poor query plans. See individual entries above.' -f $bad.Count, $dbNames.Count) }
    }
#endregion

#region -- [25] Auto Create Statistics --------------------------------------
Register-CheckSection -File $global:__checkFile -Number 25 `
    -Title '[DB] Auto Create Statistics' `
    -Function 'Get-DbaDatabase' `
    -Key 'AutoCreateStats'

# Process auto create stats and create entry findings FIRST
if ($dbNames.Count -gt 0 -and $dbsRaw) {
    $bad = @()
    foreach ($d in @($dbs)) {
        $v = $null
        if ($d.PSObject.Properties['AutoCreateStatisticsEnabled']) { $v = $d.AutoCreateStatisticsEnabled }
        elseif ($d.PSObject.Properties['AutoCreateStatistics']) { $v = $d.AutoCreateStatistics }
        if ($null -eq $v) { continue }
        if (-not [bool]$v) { $bad += $d.Name }
    }

    if ($bad.Count -gt 0) {
        $st = if ($requireAutoCreateStats) { 'fail' } else { 'attention' }
        $entrySplat = $global:CheckCat_Database['Get-DbaDatabase']['AutoCreateStatsEntry']
        foreach ($n in $bad) {
            $Findings.Value += New-Finding @entrySplat -Status $st `
                -Details ("Database: $n; AutoCreateStatistics: OFF") `
                -SpokeFile $spoke
        }
    }
}

Invoke-Check -SpokeFile $spoke -CatalogName 'Database' -Function 'Get-DbaDatabase' -Key 'AutoCreateStats' `
    -Target $Target -Config $Config -Findings $Findings -Run {
        param($sql, $t, $cfg)

        if ($dbNames.Count -eq 0) { return @{ Status='info'; Details='No databases in scope.' } }
        if (-not $dbsRaw) { return @{ Status='attention'; Details='Could not enumerate databases (Get-DbaDatabase returned no data).' } }

        $bad = @()
        foreach ($d in @($dbs)) {
            $v = $null
            if ($d.PSObject.Properties['AutoCreateStatisticsEnabled']) { $v = $d.AutoCreateStatisticsEnabled }
            elseif ($d.PSObject.Properties['AutoCreateStatistics']) { $v = $d.AutoCreateStatistics }
            if ($null -eq $v) { continue }
            if (-not [bool]$v) { $bad += $d.Name }
        }

        if ($bad.Count -eq 0) {
            return @{ Status='pass'; Details=('Auto Create Statistics is ON for all {0} in-scope database(s) (desired).' -f $dbNames.Count) }
        }

        $st = if ($requireAutoCreateStats) { 'fail' } else { 'attention' }
        return @{ Status=$st; Details=('Auto Create Statistics is OFF for {0} of {1} database(s) - missing statistics lead to poor plan choices. See individual entries above.' -f $bad.Count, $dbNames.Count) }
    }
#endregion

#region -- [26] Service Broker State ----------------------------------------
Register-CheckSection -File $global:__checkFile -Number 26 `
    -Title '[DB] Service Broker State' `
    -Function 'Get-DbaDatabase' `
    -Key 'BrokerEnabled'

Invoke-Check -SpokeFile $spoke -CatalogName 'Database' -Function 'Get-DbaDatabase' -Key 'BrokerEnabled' `
    -Target $Target -Config $Config -Findings $Findings -Run {
        param($sql, $t, $cfg)

        if ($dbNames.Count -eq 0) { return @{ Status='info'; Details='No databases in scope.' } }
        if (-not $dbsRaw) { return @{ Status='attention'; Details='Could not enumerate databases (Get-DbaDatabase returned no data).' } }

        $enabled = @(); $disabled = @()
        foreach ($d in @($dbs)) {
            if ($d.PSObject.Properties['BrokerEnabled']) {
                if ([bool]$d.BrokerEnabled) { $enabled += $d.Name } else { $disabled += $d.Name }
            } else {
                $disabled += $d.Name
            }
        }

        $details = 'Service Broker inventory: {0} enabled, {1} disabled ({2} total).' -f $enabled.Count, $disabled.Count, $dbNames.Count
        return @{ Status='info'; Details=$details }
    }
#endregion

#region -- [27] Containment Type --------------------------------------------
Register-CheckSection -File $global:__checkFile -Number 27 `
    -Title '[DB] Containment Type' `
    -Function 'Get-DbaDatabase' `
    -Key 'ContainmentType'

# Process containment and create entry findings FIRST
if ($dbNames.Count -gt 0 -and $dbsRaw) {
    $contained = @()
    foreach ($d in @($dbs)) {
        if (-not $d.PSObject.Properties['ContainmentType']) { continue }
        $v = [string]$d.ContainmentType
        if ($v -notmatch '(?i)^none$') { $contained += [PSCustomObject]@{ Name = $d.Name; Type = $v } }
    }

    if ($contained.Count -gt 0) {
        $entrySplat = $global:CheckCat_Database['Get-DbaDatabase']['ContainmentEntry']
        foreach ($c in $contained) {
            $Findings.Value += New-Finding @entrySplat -Status 'attention' `
                -Details ("Database: $($c.Name); ContainmentType: $($c.Type)") `
                -SpokeFile $spoke
        }
    }
}

Invoke-Check -SpokeFile $spoke -CatalogName 'Database' -Function 'Get-DbaDatabase' -Key 'ContainmentType' `
    -Target $Target -Config $Config -Findings $Findings -Run {
        param($sql, $t, $cfg)

        if ($dbNames.Count -eq 0) { return @{ Status='info'; Details='No databases in scope.' } }
        if (-not $dbsRaw) { return @{ Status='attention'; Details='Could not enumerate databases (Get-DbaDatabase returned no data).' } }

        $contained = @()
        foreach ($d in @($dbs)) {
            if (-not $d.PSObject.Properties['ContainmentType']) { continue }
            $v = [string]$d.ContainmentType
            if ($v -notmatch '(?i)^none$') { $contained += $d.Name }
        }

        if ($contained.Count -eq 0) {
            return @{ Status='pass'; Details=('No contained databases found ({0} checked). Containment type = None on all.' -f $dbNames.Count) }
        }

        return @{ Status='attention'; Details=('Contained database(s) detected - review authentication, user scope, and cross-db chain ownership. See individual entries above.') }
    }
#endregion

#region -- [28] Query Store State -------------------------------------------
Register-CheckSection -File $global:__checkFile -Number 28 `
    -Title '[DB] Query Store State' `
    -Function 'Test-DbaDbQueryStore' `
    -Key 'QueryStoreState'

# Test-DbaDbQueryStore returns long-format rows (one per setting per DB), plus
# instance-level trace-flag rows where Database = the instance name.
# Pivot on Name='ActualState' to get one state value per DB; filter to user DBs only.
$qsStateByDb = @{}
if ($queryStore) {
    foreach ($row in @($queryStore | Where-Object {
            ([string]$_.Name) -eq 'ActualState' -and
            $_.Database -in $dbNamesHealthyUserOnly
        })) {
        $qsStateByDb[[string]$row.Database] = [string]$row.Value
    }
}

if ($qsStateByDb.Count -gt 0) {
    $entrySplat = $global:CheckCat_Database['Test-DbaDbQueryStore']['QueryStoreStateEntry']

    foreach ($kvp in $qsStateByDb.GetEnumerator()) {
        $dbName = $kvp.Key
        $state  = $kvp.Value

        if ($state -match '(?i)error') {
            $Findings.Value += New-Finding @entrySplat -Status 'fail' `
                -Details ("Database: $dbName; Query Store state: Error") `
                -SpokeFile $spoke
        } elseif ($state -match '(?i)readonly') {
            $Findings.Value += New-Finding @entrySplat -Status 'attention' `
                -Details ("Database: $dbName; Query Store state: ReadOnly (storage limit reached)") `
                -SpokeFile $spoke
        } elseif ($state -match '(?i)^off$' -and $qsWarnIfOff) {
            $Findings.Value += New-Finding @entrySplat -Status 'attention' `
                -Details ("Database: $dbName; Query Store state: Off") `
                -SpokeFile $spoke
        }
    }
}

Invoke-Check -SpokeFile $spoke -CatalogName 'Database' -Function 'Test-DbaDbQueryStore' -Key 'QueryStoreState' `
    -Target $Target -Config $Config -Findings $Findings -Run {
        param($sql, $t, $cfg)

        if ($dbNamesHealthyUserOnly.Count -eq 0) { return @{ Status='info'; Details='No eligible user databases.' } }
        if (-not $queryStore) {
            return @{ Status='info'; Details='Test-DbaDbQueryStore returned no data; instance may be SQL Server 2014 or earlier (Query Store requires 2016+).' }
        }
        if ($qsStateByDb.Count -eq 0) {
            return @{ Status='info'; Details='No ActualState rows found in Test-DbaDbQueryStore output for in-scope user databases.' }
        }

        $errors   = @($qsStateByDb.GetEnumerator() | Where-Object { $_.Value -match '(?i)error' })
        $off      = @($qsStateByDb.GetEnumerator() | Where-Object { $_.Value -match '(?i)^off$' })
        $readOnly = @($qsStateByDb.GetEnumerator() | Where-Object { $_.Value -match '(?i)readonly' })
        $readWrite= @($qsStateByDb.GetEnumerator() | Where-Object { $_.Value -match '(?i)readwrite' })

        $lines = @()
        if ($errors.Count -gt 0) {
            $lines += ('ERROR state ({0} db(s)) - Query Store has stopped collecting data and may be losing history.' -f $errors.Count)
        }
        if ($readOnly.Count -gt 0) {
            $lines += ('READ_ONLY ({0} db(s)) - storage limit reached; consider increasing MaxStorageSizeInMB.' -f $readOnly.Count)
        }
        if ($off.Count -gt 0 -and $qsWarnIfOff) {
            $lines += ('OFF ({0} db(s)) - Query Store disabled.' -f $off.Count)
        }

        if ($lines.Count -eq 0) {
            return @{
                Status  = 'pass'
                Details = ('Query Store enabled on {0} of {1} user db(s) checked. Breakdown: ReadWrite={2}, ReadOnly={3}, Off={4}, Error={5}.' -f
                           ($readWrite.Count + $readOnly.Count), $qsStateByDb.Count,
                           $readWrite.Count, $readOnly.Count, $off.Count, $errors.Count)
            }
        }

        $st = if ($errors.Count -gt 0 -and $qsFailIfError) { 'fail' } else { 'attention' }
        return @{ Status=$st; Details=($lines -join ' | ') + ' See individual entries above.' }
    }
#endregion

#region -- [29] Recent Auto-Growth Events -----------------------------------
Register-CheckSection -File $global:__checkFile -Number 29 `
    -Title '[DB] Recent Auto-Growth Events' `
    -Function 'Find-DbaDbGrowthEvent' `
    -Key 'GrowthEvents'

# Process growth events and create entry findings FIRST
$growthEventResults = @()
if ($dbNamesHealthy.Count -gt 0 -and $growthEvts) {
    $rows = @($growthEvts)
    $total = $rows.Count

    if ($total -gt 0) {
        $byDb = @{}
        foreach ($r in $rows) {
            $n = [string]$r.DatabaseName
            if (-not $byDb.ContainsKey($n)) { $byDb[$n] = @{ Count = 0; Last = $null } }
            $byDb[$n].Count++
            $evtTime = $null
            if ($r.PSObject.Properties['StartTime'] -and $r.StartTime) { $evtTime = $r.StartTime }
            if ($null -ne $evtTime -and ($null -eq $byDb[$n].Last -or $evtTime -gt $byDb[$n].Last)) {
                $byDb[$n].Last = $evtTime
            }
        }

        $st = 'info'
        if ($growthFailCount -gt 0 -and $total -ge $growthFailCount) { $st = 'fail' }
        elseif ($growthAttnCount -gt 0 -and $total -ge $growthAttnCount) { $st = 'attention' }

        if ($st -ne 'info') {
            $entrySplat = $global:CheckCat_Database['Find-DbaDbGrowthEvent']['GrowthEventEntry']
            foreach ($kvp in $byDb.GetEnumerator()) {
                $lastStr = if ($kvp.Value.Last) { $kvp.Value.Last.ToString('yyyy-MM-dd HH:mm') } else { 'unknown' }
                $Findings.Value += New-Finding @entrySplat -Status $st `
                    -Details ("Database: $($kvp.Key); Growth events: $($kvp.Value.Count); Last event: $lastStr") `
                    -SpokeFile $spoke
            }
        }
        
        $growthEventResults = @{ Total = $total; Status = $st }
    }
}

Invoke-Check -SpokeFile $spoke -CatalogName 'Database' -Function 'Find-DbaDbGrowthEvent' -Key 'GrowthEvents' `
    -Target $Target -Config $Config -Findings $Findings -Run {
        param($sql, $t, $cfg)

        if ($dbNamesHealthy.Count -eq 0) { return @{ Status='info'; Details='No eligible databases.' } }
        if (-not $growthEvts) {
            return @{ Status='info'; Details='Find-DbaDbGrowthEvent returned no data; Default Trace may be disabled or no growth events occurred in the trace window.' }
        }

        $rows = @($growthEvts)
        $total = $rows.Count

        if ($total -eq 0) {
            return @{ Status='pass'; Details='No auto-growth events found in the Default Trace for in-scope databases (desired - files are correctly pre-sized or trace window is short).' }
        }

        $st = $growthEventResults.Status
        $suffix = if ($st -ne 'info') { ' See individual entries above.' } else { '' }
        
        return @{ Status=$st; Details=('{0} auto-growth event(s) detected in Default Trace (attention>={1}, fail>={2}).{3}' -f $total, $growthAttnCount, $growthFailCount, $suffix) }
    }
#endregion

#region -- [30] Free Space % ------------------------------------------------
Register-CheckSection -File $global:__checkFile -Number 30 `
    -Title '[DB] Free Space %' `
    -Function 'Get-DbaDbSpace' `
    -Key 'DbFreeSpacePct'

# Process free space and create entry findings FIRST
if ($dbNamesHealthy.Count -gt 0 -and $dbSpace) {
    $spaceRows = @($dbSpace)
    $worstByDb = @{}
    $freeMBByDb = @{}
    
    foreach ($r in $spaceRows) {
        $n = [string]$r.Database
        if ($n -notin $dbNamesHealthy) { continue }

        $pctUsed = $null
        if ($r.PSObject.Properties['PercentUsed'] -and $null -ne $r.PercentUsed) { $pctUsed = [double]$r.PercentUsed }
        elseif ($r.PSObject.Properties['UsedPercent'] -and $null -ne $r.UsedPercent) { $pctUsed = [double]$r.UsedPercent }
        elseif ($r.PSObject.Properties['Used'] -and $r.PSObject.Properties['FileSize'] -and $r.FileSize -gt 0) {
            $pctUsed = ([double]$r.Used / [double]$r.FileSize) * 100
        }
        if ($null -eq $pctUsed) { continue }

        $pctFree = 100.0 - $pctUsed

        $freeMB = $null
        if ($r.PSObject.Properties['AvailableMB'] -and $null -ne $r.AvailableMB) { $freeMB = [math]::Round([double]$r.AvailableMB, 1) }
        elseif ($r.PSObject.Properties['FreeSpaceMB'] -and $null -ne $r.FreeSpaceMB) { $freeMB = [math]::Round([double]$r.FreeSpaceMB, 1) }

        if (-not $worstByDb.ContainsKey($n) -or $pctFree -lt $worstByDb[$n]) {
            $worstByDb[$n] = [math]::Round($pctFree, 1)
            $freeMBByDb[$n] = $freeMB
        }
    }

    if ($worstByDb.Count -gt 0) {
        $entrySplat = $global:CheckCat_Database['Get-DbaDbSpace']['DbFreeSpaceEntry']

        foreach ($entry in $worstByDb.GetEnumerator()) {
            $pctFree = $entry.Value
            $freeMBStr = if ($null -ne $freeMBByDb[$entry.Key]) { "; Free: $($freeMBByDb[$entry.Key]) MB" } else { '' }

            if ($pctFree -lt $freeSpaceFail) {
                $Findings.Value += New-Finding @entrySplat -Status 'fail' `
                    -Details ("Database: $($entry.Key); Free space: $($pctFree)%$freeMBStr (threshold fail<$freeSpaceFail%)") `
                    -SpokeFile $spoke
            } elseif ($pctFree -lt $freeSpaceAttn) {
                $Findings.Value += New-Finding @entrySplat -Status 'attention' `
                    -Details ("Database: $($entry.Key); Free space: $($pctFree)%$freeMBStr (threshold attention<$freeSpaceAttn%)") `
                    -SpokeFile $spoke
            }
        }
    }
}

Invoke-Check -SpokeFile $spoke -CatalogName 'Database' -Function 'Get-DbaDbSpace' -Key 'DbFreeSpacePct' `
    -Target $Target -Config $Config -Findings $Findings -Run {
        param($sql, $t, $cfg)

        if ($dbNamesHealthy.Count -eq 0) { return @{ Status='info'; Details='No eligible databases.' } }
        if (-not $dbSpace) { return @{ Status='attention'; Details='Could not retrieve database space data (Get-DbaDbSpace returned no data).' } }

        $spaceRows = @($dbSpace)
        if ($spaceRows.Count -eq 0) { return @{ Status='info'; Details='Get-DbaDbSpace returned zero rows for in-scope databases.' } }

        $worstByDb = @{}
        foreach ($r in $spaceRows) {
            $n = [string]$r.Database
            if ($n -notin $dbNamesHealthy) { continue }

            $pctUsed = $null
            if ($r.PSObject.Properties['PercentUsed'] -and $null -ne $r.PercentUsed) { $pctUsed = [double]$r.PercentUsed }
            elseif ($r.PSObject.Properties['UsedPercent'] -and $null -ne $r.UsedPercent) { $pctUsed = [double]$r.UsedPercent }
            elseif ($r.PSObject.Properties['Used'] -and $r.PSObject.Properties['FileSize'] -and $r.FileSize -gt 0) {
                $pctUsed = ([double]$r.Used / [double]$r.FileSize) * 100
            }
            if ($null -eq $pctUsed) { continue }

            $pctFree = 100.0 - $pctUsed

            if (-not $worstByDb.ContainsKey($n) -or $pctFree -lt $worstByDb[$n]) {
                $worstByDb[$n] = [math]::Round($pctFree, 1)
            }
        }

        if ($worstByDb.Count -eq 0) { return @{ Status='info'; Details='No usable space data returned from Get-DbaDbSpace (property names may differ on this SQL version).' } }

        $statuses = @()
        foreach ($entry in $worstByDb.GetEnumerator()) {
            $pctFree = $entry.Value
            if ($pctFree -lt $freeSpaceFail) { $statuses += 'fail' }
            elseif ($pctFree -lt $freeSpaceAttn) { $statuses += 'attention' }
            else { $statuses += 'pass' }
        }

        $worst = Get-WorstDatabaseStatus -Statuses $statuses
        if ($worst -eq 'pass') {
            return @{ Status='pass'; Details=('All {0} eligible database(s) have >= {1}% free space.' -f $worstByDb.Count, $freeSpaceAttn) }
        }
       
        return @{
            Status  = $worst
            Details = 'Low free space (attention<{0}%, fail<{1}%). See individual entries above.' -f $freeSpaceAttn, $freeSpaceFail
        }
    }
#endregion

#region -- [31] Multiple Log Files ------------------------------------------
Register-CheckSection -File $global:__checkFile -Number 31 `
    -Title '[DB] Multiple Log Files' `
    -Function 'Get-DbaDbFile' `
    -Key 'MultipleLogFiles'

# Process multiple log files and create entry findings FIRST
if ($dbNames.Count -gt 0 -and $dbFiles) {
    $entrySplat = $global:CheckCat_Database['Get-DbaDbFile']['MultipleLogFilesEntry']

    foreach ($dbName in $dbNames) {
        $files = @($dbFiles | Where-Object { $_.Database -eq $dbName })
        if ($files.Count -eq 0) { continue }
        
        $logFiles = @($files | Where-Object { ([string]$_.Type) -match '(?i)log' })
        $logFileCount = $logFiles.Count

        if ($logFileCount -gt 1) {
            $logFileNames = @($logFiles | ForEach-Object {
                if ($_.PSObject.Properties['LogicalName']) { $_.LogicalName }
                elseif ($_.PSObject.Properties['Name']) { $_.Name }
                else { '(unknown)' }
            })

            $st = if ($allowMultiLog) { 'info' } else { 'attention' }

            $Findings.Value += New-Finding @entrySplat -Status $st `
                -Details ("Database: $dbName; Log file count: $logFileCount; Log files: $($logFileNames -join ', ')") `
                -SpokeFile $spoke
        }
    }
}

Invoke-Check -SpokeFile $spoke -CatalogName 'Database' -Function 'Get-DbaDbFile' -Key 'MultipleLogFiles' `
    -Target $Target -Config $Config -Findings $Findings -Run {
        param($sql, $t, $cfg)

        if ($dbNames.Count -eq 0) { return @{ Status='info'; Details='No databases in scope.' } }
        if (-not $dbFiles) { return @{ Status='attention'; Details='Could not retrieve DB file layout (Get-DbaDbFile returned no data).' } }

        # Count issues from entries already created
        $issueCount = @($Findings.Value | Where-Object { 
            $_.Label -match 'Multiple Log Files.*Entry' 
        }).Count

        if ($issueCount -eq 0) {
            return @{ 
                Status  = 'pass'
                Details = "All $($dbNames.Count) in-scope database(s) have a single log file (recommended configuration)."
            }
        }

        $st = if ($allowMultiLog) { 'info' } else { 'attention' }
        
        return @{ 
            Status  = $st
            Details = "Multiple log files detected in $issueCount of $($dbNames.Count) database(s). SQL Server can only write to one log file at a time; additional log files provide no performance benefit. See individual entries above."
        }
    }
#endregion