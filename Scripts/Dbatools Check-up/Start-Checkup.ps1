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
  Architecture: Menu -> Engine (Checkup.Engine.ps1) -> Spokes (Checks.*.ps1) -> JSON -> HTML
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
  , [bool]  $ReplaceTargetConfig    = $false
  , [string]$TargetsPs1Path         = (Join-Path $ScriptPath '3. Helpers\Targets.ps1')  # Legacy PS1 support
  , [string]$OutputFolder           = (Join-Path $ScriptPath '4. Output')
  , [string]$TemplatePath           = (Join-Path $ScriptPath '4. Output\Report.Template.html')
  , [string]$SettingsPath           = (Join-Path $ScriptPath '4. Output\settings.json')
  , [bool]  $OverwriteSettings      = $false

    # -------------------------------------------------------------------------
    #  CREDENTIAL & DISCOVERY
    # -------------------------------------------------------------------------
  , [bool]$UseSingleCredential      = $false
  , [bool]$UseNoCredential          = $true
  , [bool]$EnableDiscovery          = $false

    # -------------------------------------------------------------------------
    #  OUTPUT HOUSEKEEPING
    # -------------------------------------------------------------------------
  , [int] $KeepLastReports          = 5
  , [bool]$OpenReportAfterRun       = $true

    # -------------------------------------------------------------------------
    #  OPERATIONAL MODES
    # -------------------------------------------------------------------------
  , [switch]$DryRun                 = $false  # Validate config without executing checks
  , [switch]$GenerateExampleTargets = $false  # Create example files and exit
)

# =============================================================================
#  CONSTANTS
# =============================================================================
$SUITE_VERSION                      = '1.0.0'
$MIN_DBATOOLS_VERSION               = [version]'2.7.25'
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

    ConnectionTestTimeoutSeconds = 10
    CheckTimeoutSeconds = 300 # 5 minutes - adjust as needed;
    
    # -------------------------------------------------------------------------
    #  DATABASE PACK
    # -------------------------------------------------------------------------
    Database = @{
        Enabled                      = $true

        # Scope control
        IncludeSystem                = $true   # $true = include system DBs in check scope.
        ExcludeDatabases             = @()     # Glob patterns, e.g. @('ReportServer*','tempdb').

        # VLF thresholds
        VlfCountWarn                 = 150    # Attention when VLF count exceeds this.
        VlfCountFail                 = 300    # Fail when VLF count exceeds this.

        # Owner compliance
        DbOwnerComplianceEnabled     = $true
        DbOwnerExpectedPrincipal     = 'sa'

        # Known anti-patterns - set $true to escalate attention -> fail
        RequireAutoShrinkOff         = $true
        RequireAutoCloseOff          = $true
        RequirePageVerifyChecksum    = $true

        # Security settings
        RequireTrustworthyOff        = $true
        TrustworthyAllowList         = @('msdb')  # DBs where TRUSTWORTHY ON is expected and suppressed.
        RequireTde                   = $false      # $false = inventory only; $true = fail if unencrypted.

        # Statistics
        RequireAutoUpdateStats       = $true
        RequireAutoCreateStats       = $false  # Low signal on most instances; attention only.

        # Query Store (SQL 2016+ only - silently skipped on older instances)
        QueryStoreWarnIfOff          = $true
        QueryStoreFailIfError        = $true

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
        AllowMultipleLogFiles       = $false  
        AllowPercentGrowth          = $false  

        FeatureUsageEnabled         = $false  # $true = include feature usage checks; $false = skip and do not report on feature usage. this is a slow collection.
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
        $_ -notin @('Suite', 'Logging', 'ConnectionTestTimeoutSeconds') -and 
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