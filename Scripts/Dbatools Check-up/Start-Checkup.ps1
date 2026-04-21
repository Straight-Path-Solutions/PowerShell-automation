#Requires -Version 5.1
<#
.SYNOPSIS
  Launcher / Menu for the SQL Health Suite.
  Builds the canonical Settings object and hands off to Checkup.Engine.ps1.

.DESCRIPTION
  This file owns:
    - Operational parameters (paths, credentials, housekeeping).
    - The single canonical $Settings hashtable (all thresholds & toggles defined here once).
    - Calling the engine exactly once.

  It does NOT run checks, query SQL, or write findings.

.NOTES
  Architecture: Menu -> Engine (Checkup.Engine.ps1) -> Spokes (Spoke.*.ps1) -> JSON -> HTML
  Read-only posture: this suite NEVER modifies SQL Server configuration.

  Version: 1.0.0
  Last Updated: 2026-03-18

  HOW TO CONFIGURE:
    Operational flags (paths, credentials)  -> param() block below.
    All health thresholds & check toggles   -> $Settings hashtable below.
#>

# =============================================================================
#  PARAMETERS & PATHS
# =============================================================================
[CmdletBinding()]
param(
    # -------------------------------------------------------------------------
    #  PATH RESOLUTION
    # -------------------------------------------------------------------------
    $ScriptPath = $(Switch ($Host.name) {
        'Visual Studio Code Host'     { Split-Path $psEditor.GetEditorContext().CurrentFile.Path }
        'Windows PowerShell ISE Host' { Split-Path -Path $psISE.CurrentFile.FullPath }
        'ConsoleHost'                 { $PSScriptRoot }
    })

    # -------------------------------------------------------------------------
    #  PATHS  (all I/O controlled here - nothing buried elsewhere)
    # -------------------------------------------------------------------------
  , [string]$ConfigPath             = (Join-Path $ScriptPath 'targets.json')
  , [bool]  $ReplaceTargetConfig    = $false  # $true = overwrite targets.json with a freshly generated list; $false = keep the existing file.
  , [string]$TargetsPs1Path         = (Join-Path $ScriptPath '3. Helpers\Targets.ps1')  # Legacy PS1 support
  , [string]$OutputFolder           = (Join-Path $ScriptPath '4. Output')
  , [string]$TemplatePath           = (Join-Path $ScriptPath '4. Output\Report.Template.html')
  , [string]$SettingsPath           = (Join-Path $ScriptPath '4. Output\settings.json')
  , [bool]  $OverwriteSettings      = $true   # $true = overwrite the settings.json export each run; $false = keep the existing export.

    # -------------------------------------------------------------------------
    #  CREDENTIAL & DISCOVERY
    # -------------------------------------------------------------------------
  , [bool]$UseSingleCredential      = $false  # $true = prompt once and reuse the same SQL credential for all targets.
  , [bool]$UseNoCredential          = $true   # $true = Windows auth only (no SQL credential); $false = prompt per target.
  , [bool]$EnableDiscovery          = $false  # $true = auto-discover SQL instances on reachable hosts before running checks.

    # -------------------------------------------------------------------------
    #  OUTPUT HOUSEKEEPING
    # -------------------------------------------------------------------------
  , [int] $KeepLastReports          = 5     # Number of historical HTML reports to retain; older ones are deleted automatically.
  , [bool]$OpenReportAfterRun       = $true  # $true = open the HTML report in the default browser when the run finishes.

    # -------------------------------------------------------------------------
    #  OPERATIONAL MODES
    # -------------------------------------------------------------------------
  , [switch]$DryRun                 = $false  # Validate config without executing checks
  , [switch]$GenerateExampleTargets = $false  # Create example files and exit
)

# =============================================================================
#  CONSTANTS
# =============================================================================
$SUITE_VERSION                      = '1.1.0'
$MIN_DBATOOLS_VERSION               = [version]'2.7.0'
$ErrorActionPreference              = 'Stop'
$VerbosePreference                  = 'SilentlyContinue'

# =============================================================================
#  SETTINGS  (single source of truth - every knob defined ONCE, right here)
#  The engine and all check spokes read ONLY from this object for configuration.
#  Secondary reporting logic such as check priority, category, and other metadata
#  is defined in the .\Checkup.Catalog.ps1 file.
#  To tune behaviour: change the values below. Do not add knobs elsewhere.
# =============================================================================
$Settings = @{

    # -------------------------------------------------------------------------
    #  SUITE METADATA
    # -------------------------------------------------------------------------
    Suite = @{
        Version      = $SUITE_VERSION
        RunTimestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        RunMode      = if ($DryRun) { 'DryRun' } else { 'Full' }
    }

    # -------------------------------------------------------------------------
    #  LOGGING & VERBOSITY
    # -------------------------------------------------------------------------
    Logging = @{
        EnableTranscript   = $true   # Write a full PowerShell transcript alongside the log.
        TimestampEveryPack = $true   # Show elapsed time per check pack in live output.
    }

    ConnectionTestTimeoutSeconds = 10   # Seconds to wait when testing whether a SQL instance is reachable before skipping it.
    CheckTimeoutSeconds = 300           # Maximum seconds any single check is allowed to run before it is aborted (5 min default).
    
    # -------------------------------------------------------------------------
    #  DATABASE PACK
    # -------------------------------------------------------------------------
    Database = @{
        Enabled                      = $true  # $false = skip all database-level checks entirely.

        # Scope control
        IncludeSystem                = $true   # $true = include system DBs in check scope.
        ExcludeDatabases             = @()     # Glob patterns, e.g. @('ReportServer*','tempdb').

        # VLF thresholds
        VlfCountWarn                 = 150    # Attention when VLF count exceeds this.
        VlfCountFail                 = 300    # Fail when VLF count exceeds this.

        # Owner compliance
        DbOwnerComplianceEnabled     = $true  # $true = flag databases whose owner does not match DbOwnerExpectedPrincipal.
        DbOwnerExpectedPrincipal     = 'sa'   # Login name that every database owner should match.

        # Known anti-patterns - set $true to escalate attention -> fail
        RequireAutoShrinkOff         = $true  # Auto Shrink shrinks files then lets them regrow, causing fragmentation and I/O spikes.
        RequireAutoCloseOff          = $true  # Auto Close tears down the SQL engine after the last connection, adding reconnect latency.
        RequirePageVerifyChecksum    = $true  # CHECKSUM page verify detects storage corruption; weaker options miss silent data loss.

        # Security settings
        RequireTrustworthyOff        = $true          # TRUSTWORTHY ON enables cross-DB ownership chains; flag unless on the allowlist below.
        TrustworthyAllowList         = @('msdb')      # DBs where TRUSTWORTHY ON is expected and suppressed.
        RequireTde                   = $false      # $false = inventory only; $true = fail if unencrypted.

        # Statistics
        RequireAutoUpdateStats       = $true   # Auto Update Stats keeps query plan estimates accurate; disabling it causes bad execution plans.
        RequireAutoCreateStats       = $false  # Low signal on most instances; attention only.

        # Query Store (SQL 2016+ only - silently skipped on older instances)
        QueryStoreWarnIfOff          = $true  # $true = 'attention' when Query Store is disabled; useful for workload regression analysis.
        QueryStoreFailIfError        = $true  # $true = 'fail' when Query Store is in an error state and not collecting data.

        # Auto-growth events (counts from Default Trace window, typically ~24h)
        GrowthEventsAttentionCount   = 5
        GrowthEventsFailCount        = 25

        # Free space thresholds (percent free)
        FreeSpacePctAttention        = 15.0
        FreeSpacePctFail             = 5.0

        # Compatibility level compliance
        CompatibilityLevelComplianceEnabled = $true  # $true = fail on any DB with unexpected compatibility level; $false = info only.

        # Recovery model compliance
        RecoveryModelComplianceEnabled = $false # if enabled all databases must match the expected recovery model; if disabled recovery model is returned as informational
        RecoveryModelExpected          = 'Full'  # Valid values: 'Full', 'Simple', 'BulkLogged'

        # Minimum backup recency thresholds (hours since last backup)
        MinBackupFullHours           = 168   # Full backup stale after this many hours.
        MinBackupDiffHours           = 24    # Differential backup stale after this many hours.
        MinBackupLogHours            = 2     # Log backup stale after this many hours.

        # File rules
        AllowMultipleLogFiles       = $false  # $false = flag databases with more than one log file (rarely beneficial, complicates VLF management).
        AllowPercentGrowth          = $false  # $false = flag files using percentage-based auto-growth (produces unpredictably large or tiny growths).

        FeatureUsageEnabled         = $false  # $true = include feature usage checks; $false = skip and do not report on feature usage. this is a slow collection.
    }

    # -------------------------------------------------------------------------
    #  HOST PACK
    # -------------------------------------------------------------------------
    Host = @{
        Enabled                        = $true   # $false = skip all host-level checks entirely.

        # Power plan
        # SQL Server performs best with the 'High performance' power plan.
        PowerPlanName                  = ''  # '' = accept whatever Test-DbaPowerPlan recommends; or set an exact name e.g. 'High performance'.
        PowerPlanNonCompliantIsFail    = $true              # $true → 'fail'; $false → 'attention'.

        # Pending reboot
        # A pending reboot can cause unexpected behaviour; flag it so the team is aware.
        PendingRebootIsFail            = $false  # $true → 'fail' if a reboot is pending; $false → 'attention'.

        # Domain membership
        # Useful in environments where domain-joined servers are mandated by policy.
        RequireDomainMember            = $true   # $true = servers must be domain-joined; $false = skip domain check.
        DomainNonMemberIsFail          = $false  # $true → 'fail' if not domain-joined; $false → 'attention'.

        # OS build compliance
        # Ensure hosts meet a minimum Windows patch level.
        MinOsBuild                     = 0       # 0 = disabled; Windows Server 2019 = 17763; 2022 = 20348.
        OsBuildNonCompliantIsFail      = $false  # $true → 'fail' if OS build < MinOsBuild; $false → 'attention'.

        # Virtual machine
        # Running SQL Server in a VM is fine but worth surfacing for capacity planning.
        WarnIfVirtualMachine           = $false  # $true → 'attention' when VM detected; $false → 'info' only.

        # Lock Pages in Memory (LPIM)
        # LPIM prevents Windows from paging SQL Server buffer pool to disk.
        RequireLpim                    = $false  # $true = SQL Server service account must hold the LPIM privilege; $false = skip check.
        LpimNonCompliantIsFail         = $false  # $true → 'fail' if LPIM not granted; $false → 'attention'.

        # Instant File Initialization (IFI)
        # IFI lets SQL Server skip zeroing data files, dramatically speeding up growth events and restores.
        RequireIfi                     = $true   # $true = SQL Server service account must hold the IFI privilege; $false = skip check.
        IfiNonCompliantIsFail          = $false  # $true → 'fail' if IFI not enabled; $false → 'attention'.
    }

    # -------------------------------------------------------------------------
    #  INSTANCE PACK
    # -------------------------------------------------------------------------
    Instance = @{
        Enabled                   = $true  # $false = skip all instance-level checks entirely.

        # sp_configure policies
        MinCostThreshold          = 50      # CostThreshold: flag if below this value.
        RequireOptimizeForAdHoc   = $true   # OptimizeForAdHoc: fail if not best practice.
        RequireRemoteDAC          = $true   # RemoteDAC: attention if disabled.
        RequireAdHocDistQOff      = $true   # AdHocDistributed: attention if enabled.
        RequireOleAutomationOff   = $true   # OleAutomation: attention if enabled.
        AllowCLR                  = $false   # $true = CLR integration is permitted; $false = flag as 'attention' if CLR is enabled on the instance.
        RequireBackupCompression  = $true   # BackupCompression: attention if disabled.
        MaxWorkerThreadsMax       = 0       # 0 = skip check (auto is acceptable).
        NetworkPacketSizeMax      = 0       # 0 = skip check.
        AllowContainedDbAuth      = $false  # ContainedDbAuth: attention if enabled.

        #Fill factor
        CheckInstanceFillFactor   = $true   # Set to $false to skip the fill factor check entirely
        ExpectedFillFactor        = 100     # Expected fill factor (0 and 100 are treated as equivalent defaults)

        # Error log scan (Get-DbaErrorLog — reactive scan for Sev 17+ events)
        ErrorLogScanDays          = 7       # How many days back to scan for errors.

        # Messages matching any of these strings are suppressed from the error log findings.
        ErrorLogExclusions = @(
            'BACKUP DATABASE successfully processed',
            'CHECKDB found 0 allocation errors and 0 consistency errors in database',
            'found 0 errors and repaired 0 errors',
            'Database backed up',
            'Log was backed up',
            'informational message only. No user action is required'
        )

        # Startup parameters
        # NOTE: Get-DbaStartupParameter uses -Credential (Windows/WMI), NOT -SqlCredential.
        # Will not work on Linux hosts or where WMI/PS Remoting is unavailable.
        CheckStartupParams        = $true  # $true = verify trace flags and startup parameter best practices (requires WMI/PS Remoting).

        # Instance Build checking policy
        BuildMode         = 'Latest'   # 'Latest' | 'MaxBehind' | 'MinimumBuild'
        BuildMaxBehind    = 1          # Used when BuildMode = 'MaxBehind'.
        BuildMinimum      = $null      # Used when BuildMode = 'MinimumBuild'; e.g. '15.0.4153.1'.
    }

    # -------------------------------------------------------------------------
    #  MAINTENANCE PACK
    # -------------------------------------------------------------------------
    Maintenance = @{
        Enabled                   = $true  # $false = skip all maintenance-level checks entirely.

        # Database scope
        IncludeSystemDatabases    = $false  # $true → include master/model/msdb/tempdb.

        # Duplicate / Overlapping indexes
        CheckDuplicateIndexes     = $true   # $true = flag indexes that are exact or functional duplicates of another index on the same table.

        # Unused indexes
        CheckUnusedIndexes        = $true   # $true = flag indexes with zero seeks/scans/lookups since the last service restart.
        UnusedIndexIgnoreUptime   = $false  # $true → bypass the 7-day uptime guard (stats are unreliable on recently restarted instances).

        # Disabled indexes
        CheckDisabledIndexes      = $true   # $true = flag indexes that have been explicitly disabled and are no longer maintained.

        # Statistics staleness
        CheckStatsStaleness       = $true   # $true = flag statistics objects not updated within StatsStaleDays.
        StatsStaleDays            = 7       # Flag stats not updated in this many days.

        # Wait statistics
        CheckWaitStats            = $true   # $true = surface the top waits by cumulative wait time since the last service restart.
        WaitStatsThreshold        = 100     # Minimum WaitSeconds for a wait type to be reported.
        WaitStatsTopN             = 10      # Number of top waits to surface (by WaitSeconds).

        # Last good CHECKDB
        CheckLastGoodCheckDb      = $true   # $true = flag databases where DBCC CHECKDB has not completed successfully within CheckDbMaxDays.
        CheckDbMaxDays            = 7       # Flag databases whose last good CHECKDB exceeds this.

        # Identity column usage
        IdentityUsageWarnPercent  = 80      # Attention when identity column capacity used % >= this.
        IdentityUsageFailPercent  = 95      # Fail    when identity column capacity used % >= this.

        # Error log retention configuration
        CheckErrorLogConfig       = $true   # $true = flag instances retaining fewer SQL error log files than ErrorLogMinFiles.
        ErrorLogMinFiles          = 52       # Warn if fewer log files are retained than this.
    }

}

# =============================================================================
#  END OF CONFIGURATION SECTION
#  Everything below this line is bootstrapping and execution logic.
# =============================================================================

# =============================================================================
#  GENERATE EXAMPLE FILES (if requested)
# =============================================================================
if ($GenerateExampleTargets) {
    Write-Host ''
    Write-Host '>>> Generating example configuration files...' -ForegroundColor Cyan
    
    $exampleTargetsPath = Join-Path $ScriptPath 'targets.example.json'
    $exampleSettingsPath = Join-Path $ScriptPath 'settings.example.json'
    
    # Generate example targets.json
    $exampleTargetsContent = @'
[
    {
        "ComputerName": "localhost",
        "InstanceName": "mssqlserver",
        "Description": "Local Default Instance",
        "CredKey": null
    },
    {
        "ComputerName": "labsql1",
        "InstanceName": "express",
        "Description": "Lab Express Edition",
        "CredKey": "prod"
    },
    {
        "ComputerName": "labsql1",
        "InstanceName": "sql2019",
        "Description": "Lab SQL 2019",
        "CredKey": "prod"
    },
    {
        "ComputerName": "sqlprod01",
        "InstanceName": "mssqlserver",
        "Description": "Production Primary",
        "CredKey": "prod"
    }
]
'@
    
    $exampleTargetsContent | Out-File -FilePath $exampleTargetsPath -Encoding UTF8 -Force
    Write-Host "  [OK] Created: $exampleTargetsPath" -ForegroundColor Green
    
    Write-Host ''
    Write-Host '  NOTE: This suite uses targets.json' -ForegroundColor Yellow
    Write-Host '        The JSON format supports:' -ForegroundColor Gray
    Write-Host '          - ComputerName: Server hostname (required)' -ForegroundColor Gray
    Write-Host '          - InstanceName: Instance name or "mssqlserver" for default (required)' -ForegroundColor Gray
    Write-Host '          - Description: Friendly name for reports (optional)' -ForegroundColor Gray
    Write-Host '          - CredKey: Credential key for SQL auth (optional, null = Windows auth)' -ForegroundColor Gray
    
    # Generate example settings.json (minimal subset)
    $exampleSettings = @{
        _comment = "This is an example settings file. The actual settings are defined in Start-Checkup.ps1."
        Database = @{
            Enabled = $true
            IncludeSystem = $true
        }
    } | ConvertTo-Json -Depth 10
    
    $exampleSettings | Out-File -FilePath $exampleSettingsPath -Encoding UTF8 -Force
    Write-Host "  [OK] Created: $exampleSettingsPath" -ForegroundColor Green
    
    Write-Host ''
    Write-Host '>>> Next steps:' -ForegroundColor Yellow
    Write-Host '  1. Review and customize targets.example.json' -ForegroundColor Gray
    Write-Host '  2. Copy to targets.json in the suite root folder' -ForegroundColor Gray
    Write-Host '  3. Adjust thresholds in the $Settings block of Start-Checkup.ps1' -ForegroundColor Gray
    Write-Host '  4. Run: .\Start-Checkup.ps1' -ForegroundColor Gray
    Write-Host ''
    
    return
}

# =============================================================================
#  DBATOOLS DEPENDENCY CHECK
# =============================================================================
try {
    Import-Module dbatools -ErrorAction Stop
    $dbaModule = Get-Module dbatools
    
    if ($dbaModule.Version -lt $MIN_DBATOOLS_VERSION) {
        Write-Warning "dbatools version $($dbaModule.Version) is installed, but version $MIN_DBATOOLS_VERSION or higher is recommended."
        Write-Warning "Update with: Update-Module dbatools -Force"
        Write-Host ''
        
        $continue = Read-Host "Continue anyway? (y/n)"
        if ($continue -ne 'y') {
            throw "Execution cancelled by user."
        }
    }
} catch {
    Write-Host ''
    Write-Host '[ERROR] dbatools module is required but not found.' -ForegroundColor Red
    Write-Host ''
    Write-Host 'Install dbatools with:' -ForegroundColor Yellow
    Write-Host '  Install-Module dbatools -Scope CurrentUser' -ForegroundColor Cyan
    Write-Host ''
    Write-Host 'Or if already installed, import it manually:' -ForegroundColor Yellow
    Write-Host '  Import-Module dbatools' -ForegroundColor Cyan
    Write-Host ''
    throw "dbatools is required. See: https://dbatools.io"
}

# =============================================================================
#  BANNER
# =============================================================================
Write-Host ''
Write-Host '+=====================================================' -ForegroundColor Cyan
Write-Host '|         SQL Health Suite  -  Launcher / Menu        ' -ForegroundColor Cyan
Write-Host "|         Version: $SUITE_VERSION                     " -ForegroundColor Cyan
Write-Host '|         READ-ONLY  -  Discovery & Diagnostics Only  ' -ForegroundColor Cyan
Write-Host '+=====================================================' -ForegroundColor Cyan
Write-Host "  Started : $(Get-Date -f 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor DarkGray
Write-Host "  Mode    : $(if ($DryRun) { 'DRY RUN (Validation Only)' } else { 'Full Execution' })" -ForegroundColor $(if ($DryRun) { 'Yellow' } else { 'DarkGray' })
Write-Host "  Output  : $OutputFolder" -ForegroundColor DarkGray
Write-Host "  dbatools: v$($dbaModule.Version)" -ForegroundColor DarkGray
Write-Host ''

# =============================================================================
#  LOAD HELPERS
# =============================================================================
$common = Join-Path $ScriptPath '3. Helpers\Helpers.Shared.ps1'
$targs  = Join-Path $ScriptPath '3. Helpers\Helpers.Targets.ps1'

if (-not (Test-Path $common)) { 
    throw "Required file not found: 3. Helpers\Helpers.Shared.ps1`nExpected path: $common" 
}
if (-not (Test-Path $targs))  { 
    throw "Required file not found: 3. Helpers\Helpers.Targets.ps1`nExpected path: $targs" 
}

. $common
. $targs

# =============================================================================
#  DRY RUN MODE (validation without execution)
# =============================================================================
if ($DryRun) {
    Write-Host '[DryRun] Validating configuration...' -ForegroundColor Yellow
    Write-Host ''
    
    # Validate targets file exists
    if (Test-Path $ConfigPath) {
        Write-Host "  [OK] Targets file found: $ConfigPath" -ForegroundColor Green
        
        try {
            $targetsJson = Get-Content $ConfigPath -Raw | ConvertFrom-Json
            $targetCount = @($targetsJson).Count
            Write-Host "  [OK] Loaded $targetCount target(s)" -ForegroundColor Green
            
            foreach ($t in $targetsJson) {
                $instance = if ($t.InstanceName -eq 'mssqlserver') { $t.ComputerName } else { "$($t.ComputerName)\$($t.InstanceName)" }
                $desc = if ($t.Description) { " ($($t.Description))" } else { '' }
                $auth = if ($t.CredKey) { " [SQL Auth: $($t.CredKey)]" } else { ' [Windows Auth]' }
                Write-Host "       - $instance$desc$auth" -ForegroundColor DarkGray
            }
        } catch {
            Write-Host "  [FAIL] Error loading targets.json: $_" -ForegroundColor Red
        }
    } else {
        Write-Host "  [WARN] Targets file not found: $ConfigPath" -ForegroundColor Yellow
        Write-Host "         Run with -GenerateExampleTargets to create a template" -ForegroundColor Gray
    }
    
    Write-Host ''
    
    # Validate output folder
    if (Test-Path $OutputFolder) {
        Write-Host "  [OK] Output folder exists: $OutputFolder" -ForegroundColor Green
    } else {
        Write-Host "  [INFO] Output folder will be created: $OutputFolder" -ForegroundColor Cyan
    }
    
    # Validate template
    if (Test-Path $TemplatePath) {
        Write-Host "  [OK] HTML template found: $TemplatePath" -ForegroundColor Green
    } else {
        Write-Host "  [FAIL] HTML template not found: $TemplatePath" -ForegroundColor Red
    }
    
    Write-Host ''
    
    # Report enabled packs
    $enabledPacks = $Settings.Keys | Where-Object { 
        $_ -notin @('Suite', 'Logging', 'ConnectionTestTimeoutSeconds','CheckTimeoutSeconds') -and 
        $Settings[$_].Enabled -eq $true 
    }
    
    Write-Host "  [INFO] Enabled check packs ($($enabledPacks.Count)):" -ForegroundColor Cyan
    foreach ($pack in $enabledPacks | Sort-Object) {
        Write-Host "         - $pack" -ForegroundColor DarkGray
    }
    
    Write-Host ''
    Write-Host '[DryRun] Validation complete. No checks were executed.' -ForegroundColor Yellow
    Write-Host ''
    
    return
}

# =============================================================================
#  INVOKE Checkup Engine  (engine reads ONLY $Settings + the explicit path/flag args)
# =============================================================================
$core = Join-Path $ScriptPath 'Checkup.Engine.ps1'
if (-not (Test-Path $core)) { 
    throw "Checkup Engine not found: Checkup.Engine.ps1`nExpected path: $core" 
}

Write-Host '[Launcher] Handing off to Checkup.Engine.ps1 ...' -ForegroundColor Cyan
Write-Host ''

$checkupSplat = @{
    ConfigPath          = $ConfigPath
    TargetsPs1Path      = $TargetsPs1Path
    ReplaceTargetConfig = $ReplaceTargetConfig
    OutputFolder        = $OutputFolder
    TemplatePath        = $TemplatePath
    SettingsPath        = $SettingsPath
    OverwriteSettings   = $OverwriteSettings
    KeepLastReports     = $KeepLastReports
    OpenReportAfterRun  = $OpenReportAfterRun
    UseSingleCredential = $UseSingleCredential
    UseNoCredential     = $UseNoCredential
    EnableDiscovery     = $EnableDiscovery
    Settings            = $Settings
}

try {
    & $core @checkupSplat
    
    Write-Host ''
    Write-Host '+=====================================================' -ForegroundColor Green
    Write-Host '|         SQL Health Suite  -  Execution Complete     ' -ForegroundColor Green
    Write-Host '+=====================================================' -ForegroundColor Green
    Write-Host "  Finished: $(Get-Date -f 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor DarkGray
    Write-Host "  Version : $SUITE_VERSION" -ForegroundColor DarkGray
    Write-Host ''
    
} catch {
    Write-Host ''
    Write-Host '+=====================================================' -ForegroundColor Red
    Write-Host '|         SQL Health Suite  -  Execution Failed       ' -ForegroundColor Red
    Write-Host '+=====================================================' -ForegroundColor Red
    Write-Host "  Error: $_" -ForegroundColor Red
    Write-Host ''
    throw
}