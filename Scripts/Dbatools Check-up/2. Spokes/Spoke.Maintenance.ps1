#Requires -Version 5.1
<#
.SYNOPSIS
    Spoke.Maintenance.ps1 - SQL Server maintenance health checks spoke.

.DESCRIPTION
    Covers maintenance-related checks including index health (duplicate, unused, disabled),
    statistics staleness, wait statistics, CHECKDB history, error log retention, and
    identity column usage.

    All checks emit findings via $Findings ([ref] array) using Invoke-Check.
    Status values: 'pass' | 'attention' | 'fail' | 'info'

.NOTES
    Spoke contract (Contract A):
        param([object]$Target, [hashtable]$Config, [ref]$Findings)

    Catalog: $global:CheckCat_Maintenance in Checkup.Catalog.ps1
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

$sql = Get-SqlConnectionSplat -Target $Target
$global:__checkFile = Split-Path -Leaf $PSCommandPath

$spoke = 'Maintenance'
#endregion

#region -- [01] Pack-level enable check ------------------------------------
$packEnabled = Cfg $Config 'Maintenance.Enabled' -Default $true
if (-not [bool]$packEnabled) {
    $Findings.Value += New-Finding `
        -Label    'Maintenance Pack (disabled)' `
        -Category 'Configuration' -Priority 'Low' -Status 'info' `
        -Details  'Maintenance pack disabled by config (Maintenance.Enabled = false).' `
        -Source   'Config' `
        -SpokeFile $spoke
    return
}
#endregion

#region -- [02] Config prefetch --------------------------------------------
# Define config keys with their types and variable names
$configSpec = @{
    IncludeSystemDatabases   = @{ Type = [bool];   Var = 'includeSystem' }
    CheckDuplicateIndexes    = @{ Type = [bool];   Var = 'checkDupIdx' }
    CheckUnusedIndexes       = @{ Type = [bool];   Var = 'checkUnusedIdx' }
    UnusedIndexIgnoreUptime  = @{ Type = [bool];   Var = 'unusedIgnoreUptime' }
    CheckDisabledIndexes     = @{ Type = [bool];   Var = 'checkDisabledIdx' }
    CheckStatsStaleness      = @{ Type = [bool];   Var = 'checkStats' }
    StatsStaleDays           = @{ Type = [int];    Var = 'statsStaleDays' }
    CheckWaitStats           = @{ Type = [bool];   Var = 'checkWaits' }
    WaitStatsThreshold       = @{ Type = [int];    Var = 'waitThreshold' }
    WaitStatsTopN            = @{ Type = [int];    Var = 'waitTopN' }
    CheckLastGoodCheckDb     = @{ Type = [bool];   Var = 'checkCheckDb' }
    CheckDbMaxDays           = @{ Type = [int];    Var = 'checkDbMaxDays' }
    CheckErrorLogConfig      = @{ Type = [bool];   Var = 'checkElogCfg' }
    ErrorLogMinFiles         = @{ Type = [int];    Var = 'elogMinFiles' }
    IdentityUsageWarnPercent = @{ Type = [int];    Var = 'identityWarnPct' }
    IdentityUsageFailPercent = @{ Type = [int];    Var = 'identityFailPct' }
}

# Fetch and validate all config keys in one pass
foreach ($key in $configSpec.Keys) {
    $value = Cfg $Config "Maintenance.$key"
    
    # Check for missing config
    if ($value -is [MissingConfigKey]) {
        $Findings.Value += New-SkipFinding -Key "Maintenance.$key" `
            -CheckLabel "Maintenance pack (missing: Maintenance.$key)" `
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

# Validate config relationships
if ($statsStaleDays -lt 0) { $statsStaleDays = 0 }
if ($waitThreshold -lt 0)  { $waitThreshold = 0 }
if ($waitTopN -lt 1)       { $waitTopN = 1 }
if ($checkDbMaxDays -lt 0) { $checkDbMaxDays = 0 }
if ($elogMinFiles -lt 0)   { $elogMinFiles = 0 }
if ($identityWarnPct -lt 0)   { $identityWarnPct = 0 }
if ($identityWarnPct -gt 100) { $identityWarnPct = 100 }
if ($identityFailPct -lt 0)   { $identityFailPct = 0 }
if ($identityFailPct -gt 100) { $identityFailPct = 100 }
#endregion

#region -- [03] Data prefetch -----------------------------------------------
$pfToken = Write-FetchProgress -Spoke 'Maintenance' -Start

Register-CheckSection -File $global:__checkFile -Number 3 `
    -Title    'Maintenance - Data Prefetch' `
    -Function 'Get-DbaDatabase' `
    -Key      'DataPrefetch'

# Fetch the database list once. Per-check cmdlets (index finders, stats) will
# iterate this list and call their own dbatools commands per database.
$allDbs = Invoke-DBATools  { Get-DbaDatabase @sql -EnableException }
if (-not $allDbs) { $allDbs = @() }

# Filter to the scope we care about
$targetDbs = @($allDbs | Where-Object {
    $_.IsAccessible -and
    ($includeSystem -or -not $_.IsSystemObject)
})

Write-FetchProgress -Token $pfToken -End
#endregion

#region -- [04] Duplicate / Overlapping Indexes ----------------------------
Register-CheckSection -File $global:__checkFile -Number 4 `
    -Title    'Duplicate / Overlapping Indexes' `
    -Function 'Find-DbaDbDuplicateIndex' `
    -Key      'DuplicateIndexes'

Invoke-Check -SpokeFile $spoke -CatalogName 'Maintenance' -Function 'Find-DbaDbDuplicateIndex' -Key 'DuplicateIndexes' `
    -Target $Target -Config $Config -Findings $Findings -Run {
        param($sql, $t, $cfg)

        if (-not $checkDupIdx) {
            return @{ Status = 'info'; Details = 'Duplicate index check disabled (Maintenance.CheckDuplicateIndexes = false).' }
        }
        if ($targetDbs.Count -eq 0) {
            return @{ Status = 'attention'; Details = 'No accessible databases found; duplicate index check skipped.' }
        }

        $totalDup   = 0
        $dbsWithDup = [System.Collections.Generic.List[string]]::new()

        foreach ($db in $targetDbs) {
            $dup = Invoke-DBATools  { Find-DbaDbDuplicateIndex @sql -Database $db.Name -EnableException }
            if ($dup) {
                $cnt = @($dup).Count
                if ($cnt -gt 0) {
                    $totalDup += $cnt
                    $dbsWithDup.Add("$($db.Name)($cnt)")
                }
            }
        }

        if ($totalDup -eq 0) {
            return @{ Status = 'pass'; Details = "No duplicate or overlapping indexes found across $($targetDbs.Count) database(s)." }
        }

        $sample = Summarize-Examples $dbsWithDup 5
        return @{
            Status  = 'attention'
            Details = "$totalDup duplicate/overlapping index candidate(s) found across $($dbsWithDup.Count) database(s). Databases: $sample."
        }
    }
#endregion

#region -- [05] Unused Indexes ---------------------------------------------
Register-CheckSection -File $global:__checkFile -Number 5 `
    -Title    'Unused Indexes' `
    -Function 'Find-DbaDbUnusedIndex' `
    -Key      'UnusedIndexes'

Invoke-Check -SpokeFile $spoke -CatalogName 'Maintenance' -Function 'Find-DbaDbUnusedIndex' -Key 'UnusedIndexes' `
    -Target $Target -Config $Config -Findings $Findings -Run {
        param($sql, $t, $cfg)

        if (-not $checkUnusedIdx) {
            return @{ Status = 'info'; Details = 'Unused index check disabled (Maintenance.CheckUnusedIndexes = false).' }
        }
        if ($targetDbs.Count -eq 0) {
            return @{ Status = 'attention'; Details = 'No accessible databases found; unused index check skipped.' }
        }

        $totalUnused   = 0
        $dbsWithUnused = [System.Collections.Generic.List[string]]::new()

        $uptimeSplat = @{}
        if ($unusedIgnoreUptime) { $uptimeSplat['IgnoreUptime'] = $true }

        foreach ($db in $targetDbs) {
            $unused = Invoke-DBATools  { Find-DbaDbUnusedIndex @sql -Database $db.Name @uptimeSplat -EnableException }
            if ($unused) {
                $cnt = @($unused).Count
                if ($cnt -gt 0) {
                    $totalUnused += $cnt
                    $dbsWithUnused.Add("$($db.Name)($cnt)")
                }
            }
        }

        if ($totalUnused -eq 0) {
            return @{ Status = 'pass'; Details = "No unused indexes found across $($targetDbs.Count) database(s)." }
        }

        $sample = Summarize-Examples $dbsWithUnused 5
        return @{
            Status  = 'attention'
            Details = "$totalUnused unused index candidate(s) found across $($dbsWithUnused.Count) database(s). Databases: $sample."
        }
    }
#endregion

#region -- [06] Disabled Indexes -------------------------------------------
Register-CheckSection -File $global:__checkFile -Number 6 `
    -Title    'Disabled Indexes' `
    -Function 'Find-DbaDbDisabledIndex' `
    -Key      'DisabledIndexes'

Invoke-Check -SpokeFile $spoke -CatalogName 'Maintenance' -Function 'Find-DbaDbDisabledIndex' -Key 'DisabledIndexes' `
    -Target $Target -Config $Config -Findings $Findings -Run {
        param($sql, $t, $cfg)

        if (-not $checkDisabledIdx) {
            return @{ Status = 'info'; Details = 'Disabled index check disabled (Maintenance.CheckDisabledIndexes = false).' }
        }
        if ($targetDbs.Count -eq 0) {
            return @{ Status = 'attention'; Details = 'No accessible databases found; disabled index check skipped.' }
        }

        $totalDisabled   = 0
        $dbsWithDisabled = [System.Collections.Generic.List[string]]::new()

        foreach ($db in $targetDbs) {
            $dis = Invoke-DBATools  { Find-DbaDbDisabledIndex @sql -Database $db.Name -EnableException }
            if ($dis) {
                $cnt = @($dis).Count
                if ($cnt -gt 0) {
                    $totalDisabled += $cnt
                    $dbsWithDisabled.Add("$($db.Name)($cnt)")
                }
            }
        }

        if ($totalDisabled -eq 0) {
            return @{ Status = 'pass'; Details = "No disabled indexes found across $($targetDbs.Count) database(s)." }
        }

        $sample = Summarize-Examples $dbsWithDisabled 5
        return @{
            Status  = 'attention'
            Details = "$totalDisabled disabled index(es) found across $($dbsWithDisabled.Count) database(s). Disabled indexes waste storage and may confuse the optimizer. Databases: $sample."
        }
    }
#endregion

#region -- [07] Stale Statistics -------------------------------------------
Register-CheckSection -File $global:__checkFile -Number 7 `
    -Title    'Stale Statistics' `
    -Function 'Get-DbaDbStatistic' `
    -Key      'StatsStaleness'

Invoke-Check -SpokeFile $spoke -CatalogName 'Maintenance' -Function 'Get-DbaDbStatistic' -Key 'StatsStaleness' `
    -Target $Target -Config $Config -Findings $Findings -Run {
        param($sql, $t, $cfg)

        if (-not $checkStats) {
            return @{ Status = 'info'; Details = 'Statistics staleness check disabled (Maintenance.CheckStatsStaleness = false).' }
        }
        if ($targetDbs.Count -eq 0) {
            return @{ Status = 'attention'; Details = 'No accessible databases found; statistics staleness check skipped.' }
        }

        $now            = Get-Date
        $totalStale     = 0
        $dbsWithStale   = [System.Collections.Generic.List[string]]::new()

        foreach ($db in $targetDbs) {
            $stats = Invoke-DBATools  { Get-DbaDbStatistic @sql -Database $db.Name -EnableException }
            if (-not $stats) { continue }

            $stale = @($stats | Where-Object {
                $_.LastUpdated -and
                ($now - $_.LastUpdated).TotalDays -ge $statsStaleDays
            })

            if ($stale.Count -gt 0) {
                $totalStale += $stale.Count
                $dbsWithStale.Add("$($db.Name)($($stale.Count))")
            }
        }

        if ($totalStale -eq 0) {
            return @{ Status = 'pass'; Details = "No statistics older than $statsStaleDays day(s) found across $($targetDbs.Count) database(s)." }
        }

        $sample = Summarize-Examples $dbsWithStale 5
        return @{
            Status  = 'attention'
            Details = "$totalStale statistic(s) not updated in >= $statsStaleDays day(s) across $($dbsWithStale.Count) database(s). Databases: $sample."
        }
    }
#endregion

#region -- [08] Wait Statistics --------------------------------------------
Register-CheckSection -File $global:__checkFile -Number 8 `
    -Title    'Top Wait Statistics' `
    -Function 'Get-DbaWaitStatistic' `
    -Key      'WaitStats'

# Pre-process wait stats and create entry findings BEFORE rollup
$waits = $null
if ($checkWaits) {
    $waits = Invoke-DBATools  { Get-DbaWaitStatistic @sql -Threshold $waitThreshold -EnableException }
    
    if ($waits) {
        $rows = @($waits | Sort-Object WaitSeconds -Descending | Select-Object -First $waitTopN)
        
        # Create entry findings
        $entrySplat = $global:CheckCat_Maintenance['Get-DbaWaitStatistic']['WaitStatsEntry']
        foreach ($w in $rows) {
            $wt   = [string]$w.WaitType
            $cat  = if ($w.PSObject.Properties['Category']) { [string]$w.Category } else { '' }
            $secs = try { [math]::Round([double]$w.WaitSeconds, 1) } catch { '?' }
            $pct  = try { [math]::Round([double]$w.Percentage, 1) } catch { '?' }
            $avg  = try { [math]::Round([double]$w.AverageWaitSeconds, 3) } catch { $null }
            $avgStr = if ($null -ne $avg) { ", avg $($avg)s/wait" } else { '' }
            $catStr = if ($cat) { " [$cat]" } else { '' }
            
            $Findings.Value += New-Finding @entrySplat `
                -Status  'info' `
                -Details "$wt$catStr - ${secs}s total, ${pct}% of waits$avgStr." `
                -SpokeFile $spoke
        }
    }
}

# Create rollup finding
Invoke-Check -SpokeFile $spoke -CatalogName 'Maintenance' -Function 'Get-DbaWaitStatistic' -Key 'WaitStats' `
    -Target $Target -Config $Config -Findings $Findings -Run {
        param($sql, $t, $cfg)

        if (-not $checkWaits) {
            return @{ Status = 'info'; Details = 'Wait statistics check disabled (Maintenance.CheckWaitStats = false).' }
        }

        if (-not $waits) {
            return @{ Status = 'info'; Details = "Get-DbaWaitStatistic returned no results above the $waitThreshold-second threshold." }
        }

        $total = @($waits).Count
        $more = if ($total -gt $waitTopN) { " (top $waitTopN of $total shown)" } else { '' }
        
        return @{
            Status  = 'info'
            Details = "$total wait type(s) above ${waitThreshold}s threshold$more. See individual entries above."
        }
    }
#endregion

#region -- [09] Last Good CHECKDB ------------------------------------------
Register-CheckSection -File $global:__checkFile -Number 9 `
    -Title    'Last Good CHECKDB (Instance-wide)' `
    -Function 'Get-DbaLastGoodCheckDb' `
    -Key      'LastGoodCheckDb'

# Pre-process CHECKDB results and create entry findings BEFORE rollup
$checkDbRows = $null
$overdue = @()
if ($checkCheckDb) {
    $checkDbRows = Invoke-DBATools  { Get-DbaLastGoodCheckDb @sql -EnableException }
    
    if ($checkDbRows) {
        $all = @($checkDbRows | Where-Object { $_.Database -ne 'tempdb' })
        $overdue = @($all | Where-Object {
            $_.Status -ne 'Ok' -or
            ($null -ne $_.DaysSinceLastGoodCheckDb -and $_.DaysSinceLastGoodCheckDb -gt $checkDbMaxDays)
        })
        
        # Create entry findings for overdue databases
        $entrySplat = $global:CheckCat_Maintenance['Get-DbaLastGoodCheckDb']['LastGoodCheckDbEntry']
        foreach ($r in ($overdue | Sort-Object {
            if ($null -ne $_.DaysSinceLastGoodCheckDb) { [int]$_.DaysSinceLastGoodCheckDb } else { 9999 }
        } -Descending)) {
            $days   = if ($null -eq $_.DaysSinceLastGoodCheckDb) { 'never' } else { "$([int]$_.DaysSinceLastGoodCheckDb) day(s)" }
            $status = if ($_.PSObject.Properties['Status']) { [string]$_.Status } else { 'unknown' }
            $purity = if ($_.PSObject.Properties['DataPurityEnabled']) { [bool]$_.DataPurityEnabled } else { $null }
            $purityStr = if ($null -ne $purity) { " DataPurity: $purity." } else { '' }
            $entryStatus = if ($null -eq $_.DaysSinceLastGoodCheckDb) { 'fail' } else { 'attention' }
            
            $Findings.Value += New-Finding @entrySplat `
                -Status  $entryStatus `
                -Details "$($r.Database): last good CHECKDB $days ago. Status: $status.$purityStr" `
                -SpokeFile $spoke
        }
    }
}

# Create rollup finding
Invoke-Check -SpokeFile $spoke -CatalogName 'Maintenance' -Function 'Get-DbaLastGoodCheckDb' -Key 'LastGoodCheckDb' `
    -Target $Target -Config $Config -Findings $Findings -Run {
        param($sql, $t, $cfg)

        if (-not $checkCheckDb) {
            return @{ Status = 'info'; Details = 'Last good CHECKDB check disabled (Maintenance.CheckLastGoodCheckDb = false).' }
        }

        if (-not $checkDbRows) {
            return @{ Status = 'attention'; Details = 'Get-DbaLastGoodCheckDb returned no data. Check permissions or connectivity.' }
        }

        $all = @($checkDbRows | Where-Object { $_.Database -ne 'tempdb' })
        
        if ($overdue.Count -eq 0) {
            return @{ Status = 'pass'; Details = "All $($all.Count) database(s) have a good CHECKDB within the last $checkDbMaxDays day(s)." }
        }

        $neverCount = @($overdue | Where-Object { $null -eq $_.LastGoodCheckDb }).Count
        $neverNote  = if ($neverCount -gt 0) { " $neverCount have never had a successful CHECKDB." } else { '' }

        return @{
            Status  = 'fail'
            Details = "$($overdue.Count) of $($all.Count) database(s) exceed the $checkDbMaxDays-day CHECKDB threshold.$neverNote See individual entries above."
        }
    }
#endregion

#region -- [10] Error Log Retention Configuration --------------------------
Register-CheckSection -File $global:__checkFile -Number 10 `
    -Title    'Error Log Retention Configuration' `
    -Function 'Get-DbaErrorLogConfig' `
    -Key      'ErrorLogConfig'

Invoke-Check -SpokeFile $spoke -CatalogName 'Maintenance' -Function 'Get-DbaErrorLogConfig' -Key 'ErrorLogConfig' `
    -Target $Target -Config $Config -Findings $Findings -Run {
        param($sql, $t, $cfg)

        if (-not $checkElogCfg) {
            return @{ Status = 'info'; Details = 'Error log config check disabled (Maintenance.CheckErrorLogConfig = false).' }
        }

        $elog = Invoke-DBATools  { Get-DbaErrorLogConfig @sql -EnableException }

        if (-not $elog) {
            return @{ Status = 'info'; Details = 'Get-DbaErrorLogConfig returned no data. SQL Server error log configuration could not be retrieved.' }
        }

        $logCount = if ($elog.PSObject.Properties['LogCount']) { 
            [int]$elog.LogCount 
        } else { 
            0 
        }

        if ($logCount -lt $elogMinFiles) {
            return @{
                Status  = 'fail'
                Details = "Error log retention is set to $logCount file(s), which is below the recommended minimum of $elogMinFiles. Increase via sp_cycle_errorlog or configure 'Limit the number of error log files before they are recycled' in SSMS (Server Properties > Advanced)."
            }
        }

        return @{
            Status  = 'pass'
            Details = "Error log retention: $logCount file(s) (meets or exceeds recommended minimum of $elogMinFiles)."
        }
    }
#endregion

#region -- [11] Identity Column Usage --------------------------------------
Register-CheckSection -File $global:__checkFile -Number 11 `
    -Title    'Identity Column Usage' `
    -Function 'Test-DbaIdentityUsage' `
    -Key      'IdentityUsage'

# Pre-process identity usage and create entry findings BEFORE rollup
$identityRows    = $null
$failing         = @()
$warning         = @()
$identityThreshold = [int][Math]::Min($identityWarnPct, $identityFailPct)

$systemSplat = @{}
if (-not $includeSystem) { $systemSplat['ExcludeSystem'] = $true }

$identityRows = Invoke-DBATools  {
    Test-DbaIdentityUsage @sql -Threshold $identityThreshold @systemSplat -EnableException
}

if ($identityRows) {
    $all     = @($identityRows)
    $failing = @($all | Where-Object { [double]$_.PercentUsed -ge $identityFailPct })
    $warning = @($all | Where-Object {
        [double]$_.PercentUsed -ge $identityWarnPct -and
        [double]$_.PercentUsed -lt $identityFailPct
    })

    $entrySplat = $global:CheckCat_Maintenance['Test-DbaIdentityUsage']['IdentityUsageEntry']

    foreach ($r in ($failing | Sort-Object { [double]$_.PercentUsed } -Descending)) {
        $pct = [math]::Round([double]$r.PercentUsed, 1)
        $Findings.Value += New-Finding @entrySplat `
            -Status  'fail' `
            -Details "$($r.Database).$($r.TableName).$($r.ColumnName): $pct% of identity range consumed (>= $identityFailPct% threshold). Last value: $($r.LastValue); Max rows: $($r.MaxNumberRows)." `
            -SpokeFile $spoke
    }

    foreach ($r in ($warning | Sort-Object { [double]$_.PercentUsed } -Descending)) {
        $pct = [math]::Round([double]$r.PercentUsed, 1)
        $Findings.Value += New-Finding @entrySplat `
            -Status  'attention' `
            -Details "$($r.Database).$($r.TableName).$($r.ColumnName): $pct% of identity range consumed ($identityWarnPct%-$identityFailPct% warning band). Last value: $($r.LastValue); Max rows: $($r.MaxNumberRows)." `
            -SpokeFile $spoke
    }
}

# Create rollup finding
Invoke-Check -SpokeFile $spoke -CatalogName 'Maintenance' -Function 'Test-DbaIdentityUsage' -Key 'IdentityUsage' `
    -Target $Target -Config $Config -Findings $Findings -Run {
        param($sql, $t, $cfg)

        if (-not $identityRows) {
            return @{ Status = 'pass'; Details = "No identity columns found at or above $identityThreshold% utilization." }
        }

        $all = @($identityRows)
        $fmtCol = { param($r) "$($r.Database).$($r.TableName).$($r.ColumnName)($([math]::Round([double]$r.PercentUsed,1))%)" }

        if ($failing.Count -gt 0) {
            $sample   = Summarize-Examples ($failing | ForEach-Object { & $fmtCol $_ }) 6
            $warnNote = if ($warning.Count -gt 0) { " Additionally, $($warning.Count) column(s) are between $identityWarnPct% and $identityFailPct%." } else { '' }
            return @{
                Status  = 'fail'
                Details = "$($failing.Count) identity column(s) at or above $identityFailPct% capacity: $sample.$warnNote See individual entries above."
            }
        }

        if ($warning.Count -gt 0) {
            $sample = Summarize-Examples ($warning | ForEach-Object { & $fmtCol $_ }) 6
            return @{
                Status  = 'attention'
                Details = "$($warning.Count) identity column(s) between $identityWarnPct% and $identityFailPct% capacity: $sample. See individual entries above."
            }
        }

        return @{
            Status  = 'pass'
            Details = "All $($all.Count) identity column(s) above $identityThreshold% are within acceptable range (below $identityFailPct% capacity)."
        }
    }
#endregion