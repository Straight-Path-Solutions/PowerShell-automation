#Requires -Version 5.1
# =============================================================================
# Checkup.Engine.ps1  -  SQL Health Suite Engine / Orchestrator
# =============================================================================
#
# VERSION: 1.0.0
#
# ROLE IN THE ARCHITECTURE:
#   This is the HUB.  It is the single orchestrator responsible for running
#   a complete health-check pass from target loading through to JSON + HTML
#   output.  It never contains check logic (Contract A boundary rule).
#
# WHAT BELONGS HERE:
#   Targets + spoke discovery, the spoke execution loop, JSON persistence,
#   HTML builder invocation, artifact housekeeping, and the run summary.
#
# WHAT DOES NOT BELONG HERE:
#   Check logic of any kind           -> Spokes\Spoke.*.ps1
#   Pack-specific shared calculations -> Helpers\Helpers.<PackName>.ps1
#   Shared primitives                 -> Helpers\Helpers.Shared.ps1
#   Visual / formatting changes       -> Helpers\Report.HtmlBuilder.ps1
#
# CONTRACT REFERENCES (see CONTRACTS.md):
#   Contract A  - Engine -> Spoke invocation: -Target, -Config, -Findings ([ref])
#   Contract D  - Target object schema
#   Contract E  - Settings / Config flow (Menu builds Settings; engine adds only
#                 three operational flags: ReadOnly, EnableDiscovery, Use*Credential)
#   Contract G  - Register-CheckSection (section registry, Reset + Flush lifecycle)
#   Contract J  - JSON output schema  (Write-InstancesJson, system of record)
#
# DATA FLOW:
#   Start-Checkup.ps1        -> builds $Settings, calls this engine once
#   Checkup.Engine.ps1              -> builds $Config, runs targets x spokes loop
#   Spokes\Spoke.*.ps1              -> append findings to [ref]$Findings
#   Write-InstancesJson             -> Findings_<ts>.json  (system of record)
#   Helpers\Report.HtmlBuilder.ps1  -> Report_<ts>.html    (projection of JSON)
#
# STEP MAP:
#   0.  Prerequisites check         - Verify dbatools + minimum version
#   1.  Settings normalisation      - Contract E: copy $Settings -> $Config + 3 flags
#   2.  Build targets               - Contract D: hydrate from targets.json
#   3.  Discover spokes             - find all Spoke.*.ps1 in Spokes\ folder
#   4.  Execute checks              - Contract A: invoke each spoke per target
#   5.  Persist findings            - Contract J: Write-InstancesJson
#   6.  Build HTML report           - Helpers\Report.HtmlBuilder.ps1
#   7.  Housekeeping                - prune old JSON + transcript artifacts
#   8.  Timing summary              - tree-output mode only
#   9.  Final summary               - run-wide counters + artifact paths
# =============================================================================

[CmdletBinding(SupportsShouldProcess)]
param(
    # ---- Targets ----------------------------------------------------------------
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ConfigPath,           # Path to targets.json
    
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$TargetsPs1Path,       # Path to Targets.ps1 (legacy support)
    
    [Parameter(Mandatory)]
    [bool]$ReplaceTargetConfig,    # Force-rebuild targets.json

    # ---- Outputs ----------------------------------------------------------------
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$OutputFolder,         # JSON, HTML, transcripts
    
    [Parameter(Mandatory)]
    [string]$TemplatePath,         # HTML template ('' = auto-locate)
    
    [Parameter(Mandatory)]
    [ValidateRange(1, 1000)]
    [int]$KeepLastReports,         # Historical run retention count

    # ---- Settings persistence ---------------------------------------------------
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$SettingsPath,         # Path to settings.json
    
    [Parameter(Mandatory)]
    [bool]$OverwriteSettings,      # Overwrite settings.json this run

    # ---- Run behaviour ----------------------------------------------------------
    [Parameter(Mandatory)]
    [bool]$OpenReportAfterRun,
    
    [Parameter(Mandatory)]
    [bool]$UseSingleCredential,
    
    [Parameter(Mandatory)]
    [bool]$UseNoCredential,
    
    [Parameter(Mandatory)]
    [bool]$EnableDiscovery,

    # ---- Settings bag from the menu (Contract E) --------------------------------
    [Parameter(Mandatory)]
    [ValidateNotNull()]
    [hashtable]$Settings
)

$ErrorActionPreference = 'Stop'

# =============================================================================
#  ENGINE VERSION
#
#  This constant is referenced in the HTML report builder to stamp the version
#  that generated each report.  Update on every release.
# =============================================================================
$script:ENGINE_VERSION = '1.0.0'

# =============================================================================
#  BOOTSTRAP
#
#  Dot-sources are intentionally OUTSIDE the main try/finally block.
#  A failure here means the engine cannot function at all; the error should
#  propagate to the caller (Start-Checkup.ps1) immediately.
#  Publish-HealthSuiteFunctions promotes every function in Helpers.*.ps1 into
#  global scope so spoke runspaces that dot-source only Helpers.Shared.ps1 still
#  have access to the engine helpers they may need.
# =============================================================================
$helpersPath = Join-Path $PSScriptRoot '3. Helpers'

. "$helpersPath\Helpers.Shared.ps1"
. "$helpersPath\Helpers.Engine.ps1"
. "$helpersPath\Helpers.Targets.ps1"
Publish-HealthSuiteFunctions

# =============================================================================
#  LOGGING PREFERENCES
#
#  These script-scope variables are read by Write-VLog, Write-PackParams, and
#  Invoke-Check (Helpers.Shared.ps1) via PowerShell's normal scope walk.
#  They must be set before any Write-VLog call.
#
#  All values default to the most verbose / safest mode so a missing or empty
#  Logging block in $Settings never produces a silent run.
#
#  Contract E: these come from Settings.Logging, which is a menu responsibility.
#  The engine must never hard-code a non-default value here.
# =============================================================================
$_loggingCfg = if ($Settings.ContainsKey('Logging') -and $Settings['Logging'] -is [hashtable]) {
    $Settings['Logging']
} else { @{} }

$_timestampPack    = $true    # Per-spoke elapsed time appended to summary line
$_enableTranscript = $true    # Start-Transcript / Stop-Transcript lifecycle
$_useTreeOutput    = $false   # Tree-prefixed output (vs classic indented style)

# Override defaults with any values present in the Logging config block.
if ($null -ne $_loggingCfg['TimestampEveryPack']) { $_timestampPack    = [bool]$_loggingCfg['TimestampEveryPack']}
if ($null -ne $_loggingCfg['EnableTranscript'])   { $_enableTranscript = [bool]$_loggingCfg['EnableTranscript']  }
if ($null -ne $_loggingCfg['UseTreeOutput'])      { $_useTreeOutput    = [bool]$_loggingCfg['UseTreeOutput']     }

# =============================================================================
#  DBATOOLS GLOBAL SAFETY SETTINGS
#
#  Applied once at engine startup.  Spokes never need to repeat these.
#  Failures are swallowed - dbatools may not be installed on a fresh machine
#  and the engine must surface that error clearly, not die here silently.
# =============================================================================
try { Set-DbatoolsConfig -FullName sql.connection.trustcert -Value $true  -Register -ErrorAction SilentlyContinue } catch {}
try { Set-DbatoolsConfig -FullName sql.connection.encrypt   -Value $false -Register -ErrorAction SilentlyContinue } catch {}
try { Set-DbatoolsConfig -FullName message.maximumlevel     -Value 3      -Register -ErrorAction SilentlyContinue } catch {}

# =============================================================================
#  OUTPUT FOLDER + ARTIFACT PATHS
# =============================================================================
if (-not (Test-Path -LiteralPath $OutputFolder)) {
    New-Item -ItemType Directory -Force -Path $OutputFolder | Out-Null
}

$Timestamp = Get-Date -Format 'yyyy.MM.dd_HH.mm'
$JsonPath  = Join-Path $OutputFolder "Json-Findings\Findings_${Timestamp}.json"

# Ensure subdirectories exist
$jsonFolder = Split-Path -Parent $JsonPath
if (-not (Test-Path -LiteralPath $jsonFolder)) {
    New-Item -ItemType Directory -Force -Path $jsonFolder | Out-Null
}

# =============================================================================
#  TRANSCRIPT
#
#  Started here - before the banner - so the entire run is captured.
#  Stopped unconditionally in the finally block even on hard failure.
# =============================================================================
$_transcriptPath = $null
if ($_enableTranscript) {
    $_transcriptFolder = Join-Path $OutputFolder "Run-Transcripts"
    if (-not (Test-Path -LiteralPath $_transcriptFolder)) {
        New-Item -ItemType Directory -Force -Path $_transcriptFolder | Out-Null
    }
    
    $_transcriptPath = Join-Path $_transcriptFolder "Transcript_${Timestamp}.txt"
    try   { Start-Transcript -Path $_transcriptPath -Force | Out-Null }
    catch {
        Write-Warning "[Engine] Could not start transcript: $($_.Exception.Message)"
        $_transcriptPath = $null
    }
}

# =============================================================================
#  PRE-INIT  (variables referenced in finally or final summary)
#
#  Declared here so the finally block and summary section always have defined
#  variables to read, even when an exception aborts the run before they are set.
# =============================================================================
$__runSw       = [System.Diagnostics.Stopwatch]::StartNew()
$Targets       = @()
$SpokeFiles    = @()  # Renamed from CheckFiles
$ReportPath    = ''
$RunTotalPass  = 0
$RunTotalAttn  = 0
$RunTotalFail  = 0
$RunTotalInfo  = 0
$RunTotalCheck = 0
$RunConnFail   = 0    # targets skipped entirely due to connection failure

# =============================================================================
#  BANNER
# =============================================================================
Write-Host ''
Write-Host '|=============================================================|' -ForegroundColor Cyan
Write-Host '|     SQL Health Suite  -  Checkup Engine / Orchestrator      |' -ForegroundColor Cyan
Write-Host '|=============================================================|' -ForegroundColor Cyan
Write-Host "  Version      : $script:ENGINE_VERSION" -ForegroundColor DarkGray
Write-Host "  Run started  : $(Get-Date -f 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor DarkGray
Write-Host "  Findings     : $JsonPath" -ForegroundColor DarkGray
if ($_transcriptPath) {
    Write-Host "  Transcript   : $_transcriptPath" -ForegroundColor DarkGray
}
Write-Host ''

# =============================================================================
#  MAIN RUN
#
#  All steps live inside a single try/finally so the transcript is always
#  stopped and the stopwatch always halted - even on hard failure.
# =============================================================================
try {

# =============================================================================
#  STEP 0 - PREREQUISITES CHECK
#
#  Addresses gaps #3 and #4 from the polish document:
#    - Clear upfront error if dbatools is missing
#    - Version check against minimum supported release
#
#  This happens BEFORE any settings load so the user gets immediate,
#  actionable feedback if their environment is not ready.
# =============================================================================
Write-Section 'STEP 0 - Prerequisites'

# Check for dbatools module
$dbatoolsModule = Get-Module -Name dbatools -ListAvailable -ErrorAction SilentlyContinue | 
                  Sort-Object Version -Descending | 
                  Select-Object -First 1

if (-not $dbatoolsModule) {
    $errorMessage = "ERROR: dbatools module is required but not installed. For more information: https://dbatools.io/download"
    Write-Host $errorMessage -ForegroundColor Red
    throw "dbatools module not found"
}

# Check minimum version (Contract: engine requires dbatools 2.7.0+)
$minVersion = [version]'2.7.0'
$installedVersion = $dbatoolsModule.Version

if ($installedVersion -lt $minVersion) {
    $errorMessage = " WARNING: dbatools version $installedVersion is installed, but version $minVersion or higher is recommended."

    Write-Host $errorMessage -ForegroundColor Yellow
    Write-Host "Press Enter to continue anyway, or Ctrl+C to exit..."
    Read-Host
} else {
    Write-Host "  [+] dbatools $installedVersion installed" -ForegroundColor Green
}

# Import the module explicitly (ensures it's loaded)
try {
    Import-Module dbatools -ErrorAction Stop
    Write-Host "  [+] dbatools module loaded" -ForegroundColor Green
} catch {
    throw "Failed to load dbatools module: $($_.Exception.Message)"
}

# Initialize the fetch progress system (clean up any orphaned spinners)
Initialize-FetchProgress
Write-Host "  [+] Fetch progress system initialized" -ForegroundColor Green

    # =========================================================================
    #  STEP 1 - SETTINGS NORMALISATION  (Contract E)
    #
    #  $Settings arrives from Start-Checkup.ps1 (the menu).
    #  The engine's only additions to $Config are the three operational flags
    #  at the bottom of this section:
    #    ReadOnly            = $true   (hard-wired, always)
    #    EnableDiscovery     = <from param>
    #    UseSingleCredential = <from param>
    #    UseNoCredential     = <from param>
    #
    #  The engine NEVER defaults or injects pack-level keys.  That is the
    #  menu's sole responsibility (Contract E boundary rule).
    #
    #  settings.json is persisted here so the exact config for this run is
    #  auditable alongside Findings_<ts>.json and Transcript_<ts>.txt.
    # =========================================================================
    Write-Section 'STEP 1 - Settings'

    # Ensure settings folder exists
    $settingsFolder = Split-Path -Parent $SettingsPath
    if (-not (Test-Path -LiteralPath $settingsFolder)) {
        New-Item -ItemType Directory -Force -Path $settingsFolder | Out-Null
    }

    if (Test-Path -LiteralPath $SettingsPath) {
        if ($OverwriteSettings) {
            Write-Host "  Overwriting settings.json at $SettingsPath" -ForegroundColor Yellow
            Write-JsonFile -Object $Settings -Path $SettingsPath -Depth 100
        } else {
            # Load from disk so the exact persisted config is used for this run.
            try {
                $raw      = Get-Content -LiteralPath $SettingsPath -Raw | ConvertFrom-Json
                $Settings = ConvertTo-Hashtable -InputObject $raw
                Write-Host "  Loaded settings from $SettingsPath" -ForegroundColor Green
            } catch {
                Write-Warning "[Engine] Could not parse $SettingsPath - using in-memory Settings. $_"
            }
        }
    } else {
        Write-Host "  Creating settings.json at $SettingsPath" -ForegroundColor Yellow
        Write-JsonFile -Object $Settings -Path $SettingsPath -Depth 100
    }

    # Build $Config - the object every spoke receives.
    $Config = @{}
    foreach ($k in $Settings.Keys) { $Config[$k] = $Settings[$k] }

    # Three engine-only operational flags (Contract E).
    $Config['EnableDiscovery']     = $EnableDiscovery
    $Config['UseSingleCredential'] = $UseSingleCredential
    $Config['UseNoCredential']     = $UseNoCredential
    $Config['ReadOnly']            = $true   # Hard-wired; spokes must honour this.
    
    # Embed engine version for reference by spokes if needed
    $Config['EngineVersion']       = $script:ENGINE_VERSION

    # =========================================================================
    #  STEP 2 - BUILD TARGETS  (Contract D)
    #
    #  targets.json is rebuilt from Targets.ps1 when explicitly requested
    #  or when the file does not yet exist.
    #
    #  A fully pre-hydrated targets.json (SqlInstance already present on every
    #  row) bypasses the target builder entirely - useful for CI pipelines
    #  that construct targets.json externally.
    # =========================================================================
    Write-Section 'STEP 2 - Build Targets'

    if ($ReplaceTargetConfig -or -not (Test-Path -LiteralPath $ConfigPath)) {
        $resolvedPs1 = Resolve-TargetsPs1Path -InputPath $TargetsPs1Path -EngineRoot $PSScriptRoot
        if (-not $resolvedPs1) {
            throw ("targets.json is missing and Targets.ps1 was not found. " +
                   "Searched: '$TargetsPs1Path', '$PSScriptRoot\3. Helpers\Targets.ps1', '$PSScriptRoot\Targets.ps1'")
        }
        $verb = if ($ReplaceTargetConfig) { 'Rebuilding' } else { 'Creating' }
        Write-Host "  $verb targets.json from $resolvedPs1 ..." -ForegroundColor Yellow
        Write-TargetsJsonFromPs1 -TargetsPs1Path $resolvedPs1 -ConfigPath $ConfigPath
    } else {
        Write-Host "  Using existing targets.json: $ConfigPath" -ForegroundColor Green
    }

    $parsedJson = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json

    # PS5.1 quirk: @() around an already-typed Object[] wraps it as a single
    # element instead of enumerating it.  Explicit type check avoids the double-wrap.
    $rawArray = if ($parsedJson -is [System.Array]) { $parsedJson } else { @($parsedJson) }
    if ($rawArray.Count -eq 0) { throw "No targets defined in $ConfigPath" }

    # A pre-hydrated row has SqlInstance already populated.  If ANY row is missing
    # SqlInstance, run the target builder to hydrate all rows (credential prompts, etc.).
    $needsBuild = @($rawArray | Where-Object {
        -not ($_.PSObject.Properties.Name -contains 'SqlInstance') -or
        [string]::IsNullOrWhiteSpace($_.SqlInstance)
    }).Count -gt 0

    if ($needsBuild) {
        if ($EnableDiscovery) {
            if    ($UseSingleCredential) { $Targets = Get-MergedTargets -RawTargets $rawArray -SingleCredential -AlsoDiscover }
            elseif ($UseNoCredential)    { $Targets = Get-MergedTargets -RawTargets $rawArray -NoCredential    -AlsoDiscover }
            else                         { $Targets = Get-MergedTargets -RawTargets $rawArray                  -AlsoDiscover }
        } else {
            if    ($UseSingleCredential) { $Targets = Get-ConfiguredTargets -RawTargets $rawArray -SingleCredential }
            elseif ($UseNoCredential)    { $Targets = Get-ConfiguredTargets -RawTargets $rawArray -NoCredential     }
            else                         { $Targets = Get-ConfiguredTargets -RawTargets $rawArray                   }
        }
    } else {
        # All rows already have SqlInstance - pass through and ensure Credential exists.
        $Targets = @($rawArray | ForEach-Object {
            if ($_.PSObject.Properties.Name -notcontains 'Credential') {
                $_ | Add-Member -NotePropertyName Credential -NotePropertyValue $null -Force
            }
            $_
        })
    }

    $Targets = @($Targets)
    if ($Targets.Count -eq 0) { throw 'Target builder returned no usable targets.' }

    Write-Host "  $($Targets.Count) target(s) ready:" -ForegroundColor Green
    foreach ($t in $Targets) { Write-Host "    * $($t.SqlInstance)" -ForegroundColor Gray }

    # =========================================================================
    #  STEP 3 - DISCOVER SPOKES
    #
    #  Searches the Spokes\ folder for all Spoke.*.ps1 files.
    #  Deduplication + alphabetical sort give a deterministic execution order
    #  across runs regardless of filesystem ordering.
    # =========================================================================
    Write-Section 'STEP 3 - Discover Spokes'

    $spokesFolder = Join-Path $PSScriptRoot '2. Spokes'
    
    if (-not (Test-Path -LiteralPath $spokesFolder)) {
        Write-Warning "[Engine] Spokes folder not found: $spokesFolder"
        $SpokeFiles = @()
    } else {
        $SpokeFiles = @(Get-ChildItem -LiteralPath $spokesFolder -Filter 'Spoke.*.ps1' -File -ErrorAction SilentlyContinue |
                        Sort-Object Name)
    }

    if ($SpokeFiles.Count -eq 0) {
        Write-Warning '[Engine] No Spoke.*.ps1 files found. The run will produce an empty report.'
    } else {
        Write-Host "  $($SpokeFiles.Count) spoke(s) discovered:" -ForegroundColor Green
        foreach ($f in $SpokeFiles) { Write-Host "    * $($f.Name)" -ForegroundColor Gray }
    }

    # =========================================================================
    #  STEP 4 - EXECUTE CHECKS  (Contract A)
    #
    #  Isolation rules (Contract A §2):
    #    Target-level:  a target that fails connection is recorded and skipped;
    #                   the run continues to the next target.
    #    Spoke-level:   a spoke that throws hard gets a 'fail' finding emitted
    #                   to JSON/HTML (not just a console message) and is skipped;
    #                   the run continues to the next spoke.
    #    Check-level:   spokes implement their own per-check isolation internally
    #                   via Invoke-DBATools / try-catch (Contract H).
    #
    #  Only a failure in the ENGINE ITSELF (e.g. JSON write, fatal PowerShell
    #  exception outside the foreach) aborts the run.
    # =========================================================================
    Write-Section 'STEP 4 - Execute Checks'

    $AllInstances = @()

    foreach ($target in $Targets) {

        Write-Host ''

        # --- Target header -------------------------------------------------------
        $credLabel = if ($target.Credential) { $target.Credential.UserName } else { 'Windows Integrated' }

        if ($_useTreeOutput) {
            Write-TreeLine -Level 1 -Tag 'INF' -Text "Target: $($target.SqlInstance)" -Branch
            if ($target.Description) {
                Write-TreeLine -Level 2 -Tag 'CFG' -Text "Description : $($target.Description)"
            }
            Write-TreeLine -Level 2 -Tag 'CFG' -Text "Credential  : $credLabel"
        } else {
            Write-Host "  |-- Target: $($target.SqlInstance)" -ForegroundColor White
            if ($target.Description) {
                Write-Host "  |   Description : $($target.Description)" -ForegroundColor DarkGray
            }
            Write-Host "  |   Credential  : $credLabel" -ForegroundColor DarkGray
        }

        # --- Connection test -----------------------------------------------------
        # ConnectionTestTimeoutSeconds flows through $Config from $Settings
        # (Contract E).  The fallback here is purely defensive.
        $connTimeout = if ($Config.ContainsKey('ConnectionTestTimeoutSeconds')) {
            [int]$Config['ConnectionTestTimeoutSeconds']
        } else { 5 }

        $connLabel = "Testing connectivity (timeout: ${connTimeout}s) ..."

        if ($_useTreeOutput) { Write-TreeInlineStart -Level 2 -Text $connLabel }
        else                  { Write-Host "  |   [TEST] $connLabel" -NoNewline }

        $connectionOk = Test-SqlConnection -Target $target -TimeoutSeconds $connTimeout

        if (-not $connectionOk) {
            if ($_useTreeOutput) {
                Write-TreeInlineEnd -Level 2 -FinalText "$connLabel FAIL"
                Write-TreeLine -Level 3 -Tag 'WRN' -Text "Cannot connect to $($target.SqlInstance). All checks skipped."
            } else {
                Write-Host ' FAILED' -ForegroundColor Red
                Write-Host "  |   [WRN] Cannot connect to $($target.SqlInstance). All checks skipped." -ForegroundColor Yellow
            }

            # Emit a real finding so the failure is visible in JSON/HTML (Contract J).
            # Guard against a blank SqlInstance (target was never hydrated).
            $instanceName = if ([string]::IsNullOrWhiteSpace($target.SqlInstance)) {
                '(unknown - SqlInstance blank; check targets.json)'
            } else { $target.SqlInstance }

            $AllInstances += New-Instance `
                -Name        $instanceName `
                -Description ($target.Description) `
                -Checks      @(
                    New-Finding `
                        -Label    'SQL Connection Test' `
                        -Category 'Availability' `
                        -Priority 'High' `
                        -Status   'fail' `
                        -Details  "Cannot connect to '$instanceName' (timeout: ${connTimeout}s). All checks skipped." `
                        -Source   'Test-DbaConnection'
                )

            $RunConnFail++
            $RunTotalFail++
            $RunTotalCheck++
            continue   # Skip all spokes for this target.
        }

        if ($_useTreeOutput) { Write-TreeInlineEnd -Level 2 -FinalText "$connLabel PASS" }
        else                  { Write-Host ' OK' -ForegroundColor Green }

        # --- Spoke execution loop ------------------------------------------------
        $targetFindings = @()
        $targetSw       = [System.Diagnostics.Stopwatch]::StartNew()

        foreach ($spokeFile in $SpokeFiles) {

            # $fileKey is the stable identifier for this spoke in the section registry
            # (Contract G).  Computed once and reused for reset + count below.
            $fileKey = Split-Path -Leaf $spokeFile.FullName

            # Spoke header
            if (-not $_useTreeOutput) {
                Write-Host "  |++|-- $fileKey" -ForegroundColor Yellow
            }
            Write-PackParams -PackName $fileKey -Config $Config

            # Reset the section registry so counts from a previous target/spoke pair
            # do not bleed into this one (Contract G).
            Reset-RegisteredChecks -File $fileKey

            $before = $targetFindings.Count
            $packSw = [System.Diagnostics.Stopwatch]::StartNew()

            if ($_useTreeOutput) { Write-TreeInlineStart -Level 2 -Text "$fileKey ... " }

                # CONTRACT A - invoke the spoke via the stable three-parameter contract.
                # -ErrorAction Stop promotes non-terminating errors to terminating so the
                # catch block reliably intercepts all spoke-level failures.
            $spokePath = (Resolve-Path -LiteralPath $spokeFile.FullName).Path
            $spokeOk   = Invoke-Spoke `
                            -SpokePath $spokePath `
                            -Target    $target `
                            -Config    $Config `
                            -Findings  ([ref]$targetFindings)

            if (-not $spokeOk) {
                Write-Host "  |   Spoke failed - continuing to next spoke" -ForegroundColor Yellow
            }

            # Flush the final check section's accumulated summary line (Contract G).
            if (Get-Command Flush-CheckSection -ErrorAction SilentlyContinue) {
                Flush-CheckSection
            }

            $packSw.Stop()

            # --- Per-spoke summary -------------------------------------------
            $after    = $targetFindings.Count
            $newSlice = @(if ($after -gt $before) { $targetFindings[$before..($after - 1)] } else { @() })
            $m        = Measure-Findings -Findings $newSlice

            $declared = Get-RegisteredCheckCount -File $fileKey
            if ($declared -le 0) {
                try {
                    $declared = @(
                        Select-String -Path $spokeFile.FullName `
                                      -Pattern '\bRegister-CheckSection\b' `
                                      -ErrorAction SilentlyContinue
                    ).Count
                } catch {}
            }

            # $packSw.Elapsed is always valid here - it was started before Invoke-Spoke
            $elapsed  = Format-TimeSpan -TimeSpan $packSw.Elapsed   # <-- FIXED
            $declText = if ($declared -gt 0) { "$declared checks: " } else { '' }
            $summary  = Format-FindingsSummary -Metrics $m

            if ($_useTreeOutput) {
                $rollup = if ($m.Fail -gt 0) { 'FAIL' } elseif ($m.Attention -gt 0) { 'ATTN' } else { 'PASS' }
                Write-TreeInlineEnd -Level 2 -FinalText "$fileKey ... $rollup  [$elapsed]"
                Write-TreeLine -Level 3 -Tag 'SUM' -Text "${declText}${summary}"
            } else {
                $timeText = if ($_timestampPack) { " - $elapsed" } else { '' }
                Write-Host "  |==|   ${declText}${summary}${timeText}" -ForegroundColor DarkGray
            }

            $RunTotalPass  += $m.Pass
            $RunTotalAttn  += $m.Attention
            $RunTotalFail  += $m.Fail
            $RunTotalInfo  += $m.Info
            $RunTotalCheck += $m.Total
        }

        $targetSw.Stop()

        # Deduplicate across spokes - a key that appears in two packs
        # (misconfiguration) must surface once in JSON/HTML, not twice.
        if ($targetFindings) {
            $targetFindings = Remove-DuplicateChecks -Checks $targetFindings
        }

        # --- Target footer -------------------------------------------------------
        $tm        = Measure-Findings -Findings $targetFindings
        $tmSummary = Format-FindingsSummary -Metrics $tm
        $tmElapsed = Format-TimeSpan -Seconds $targetSw.Elapsed.TotalSeconds

        if ($_useTreeOutput) {
            Write-TreeLine -Level 2 -Tag 'SUM' -Text "Target complete: $tmSummary  [$tmElapsed]"
        } else {
            Write-Host "  |--- Target complete: $tmSummary  [$tmElapsed]" -ForegroundColor Cyan
        }

        $AllInstances += New-Instance `
            -Name        $target.SqlInstance `
            -Description ($target.Description) `
            -Checks      $targetFindings
    }

    # =========================================================================
    #  STEP 5 - PERSIST FINDINGS  (Contract J)
    #
    #  JSON is the system of record.  HTML is built from this file only - the
    #  report builder never queries SQL or re-runs checks.
    #  All connection-failure findings are already in $AllInstances so they
    #  appear in JSON/HTML alongside the real check results.
    #
    #  Addresses gap #6: Engine version is now embedded in JSON metadata.
    # =========================================================================
    Write-Section 'STEP 5 - Persist Findings'

    # Create metadata object
    $metadata = @{
        generatedBy      = 'SQL Health Suite'
        version          = $script:ENGINE_VERSION
        timestamp        = (Get-Date -Format 'o')
        targetCount      = $Targets.Count
        connectionFailed = $RunConnFail
    }

    # Wrap instances with metadata
    $jsonOutput = @{
        metadata  = $metadata
        instances = $AllInstances
    }

    # Write the JSON file - pass the complete wrapped object
    Write-JsonFile -Object $jsonOutput -Path $JsonPath -Depth 100

    # Compute totals from the serialised objects (includes connection-fail findings).
    $allChecks  = @($AllInstances | ForEach-Object { $_.checks } | Where-Object { $_ })
    $runMetrics = Measure-Findings -Findings $allChecks

    Write-VLog -Message "  Written : $JsonPath" -Color Green
    Write-VLog -Message "  Totals  : $(Format-FindingsSummary -Metrics $runMetrics)" -Color DarkGray

    # =========================================================================
    #  STEP 6 - BUILD HTML REPORT
    #
    #  Called BEFORE housekeeping so that the current run's JSON and HTML both
    #  exist before any pruning occurs (the current run is never self-pruned).
    # =========================================================================
    Write-Section 'STEP 6 - Build HTML Report'

    $reportBuilder     = Join-Path $OutputFolder 'Report.HtmlBuilder.ps1'
    $effectiveTemplate = if ($TemplatePath) { $TemplatePath }
                         else               { Join-Path $OutputFolder 'Report.Template.html' }

    # Ensure Reports folder exists
    $reportsFolder = Join-Path $OutputFolder 'Reports'
    if (-not (Test-Path -LiteralPath $reportsFolder)) {
        New-Item -ItemType Directory -Force -Path $reportsFolder | Out-Null
    }

    $rbSplat = @{
        JsonPath      = (Resolve-Path $JsonPath).Path
        TemplatePath  = (Resolve-Path $effectiveTemplate).Path
        OutputFolder  = (Resolve-Path $reportsFolder).Path
        KeepLast      = [int]$KeepLastReports
        OpenAfter     = [bool]$OpenReportAfterRun
        EngineVersion = $script:ENGINE_VERSION  # Pass version to report builder
    }
    $ReportPath = & $reportBuilder @rbSplat
    Write-VLog -Message "  Written : $ReportPath" -Color Green

    # =========================================================================
    #  STEP 7 - HOUSEKEEPING  (prune old artifacts)
    #
    #  Report.HtmlBuilder manages Report_*.html rotation via its own KeepLast
    #  parameter.  The engine handles JSON and transcript pruning here.
    #
    #  Addresses gap #9: Housekeeping is now centralized with clear logging.
    # =========================================================================
    Write-Section 'STEP 7 - Housekeeping'
    
    $removedFiles = [System.Collections.Generic.List[string]]::new()
    
    # Prune old JSON findings
    $jsonFolder = Join-Path $OutputFolder 'Json-Findings'
    if (Test-Path $jsonFolder) {
        $oldJsons = @(Get-ChildItem $jsonFolder -Filter 'Findings_*.json' | 
                      Sort-Object LastWriteTime -Descending | 
                      Select-Object -Skip $KeepLastReports)
        foreach ($old in $oldJsons) {
            try {
                Remove-Item -LiteralPath $old.FullName -Force
                [void]$removedFiles.Add("JSON: $($old.Name)")
            } catch {
                Write-Warning "Could not remove old JSON: $($old.Name)"
            }
        }
    }
    
    # Prune old transcripts
    $transcriptFolder = Join-Path $OutputFolder 'Run-Transcripts'
    if (Test-Path $transcriptFolder) {
        $oldTranscripts = @(Get-ChildItem $transcriptFolder -Filter 'Transcript_*.txt' | 
                            Sort-Object LastWriteTime -Descending | 
                            Select-Object -Skip $KeepLastReports)
        foreach ($old in $oldTranscripts) {
            try {
                Remove-Item -LiteralPath $old.FullName -Force
                [void]$removedFiles.Add("Transcript: $($old.Name)")
            } catch {
                Write-Warning "Could not remove old transcript: $($old.Name)"
            }
        }
    }
    
    # Prune old HTML reports (belt-and-suspenders with Report.HtmlBuilder)
    $reportsFolder = Join-Path $OutputFolder 'Reports'
    if (Test-Path $reportsFolder) {
        $oldReports = @(Get-ChildItem $reportsFolder -Filter 'Report_*.html' | 
                        Sort-Object LastWriteTime -Descending | 
                        Select-Object -Skip $KeepLastReports)
        foreach ($old in $oldReports) {
            try {
                Remove-Item -LiteralPath $old.FullName -Force
                [void]$removedFiles.Add("Report: $($old.Name)")
            } catch {
                Write-Warning "Could not remove old report: $($old.Name)"
            }
        }
    }
    
    if ($removedFiles.Count -gt 0) {
        Write-Host "  Pruned $($removedFiles.Count) old artifact(s) (retention: $KeepLastReports)" -ForegroundColor DarkGray
    } else {
        Write-Host "  No old artifacts to prune" -ForegroundColor DarkGray
    }

    # =========================================================================
    #  STEP 8 - TIMING SUMMARY  (tree output mode only)
    # =========================================================================
    if ($_useTreeOutput) {
        Write-Host ''
        Write-TimingSummary -Top 15
    }

    # =========================================================================
    #  STEP 9 - FINAL SUMMARY
    #
    #  Addresses gap #8: Connection failures are now prominently displayed.
    # =========================================================================
    $elapsed = Format-TimeSpan -Seconds $__runSw.Elapsed.TotalSeconds

    Write-Host ''
    Write-Host ('=' * 70) -ForegroundColor Cyan
    Write-Host '  RUN COMPLETE' -ForegroundColor Green
    Write-Host ('=' * 70) -ForegroundColor Cyan
    Write-Host ''
    Write-Host "  Suite Version    : $script:ENGINE_VERSION" -ForegroundColor White
    Write-Host "  Targets checked  : $($Targets.Count)" -ForegroundColor White
    
    # Prominent connection failure display (Gap #8)
    if ($RunConnFail -gt 0) {
        Write-Host ''
        Write-Host '  [!] CONNECTION FAILURES:' -ForegroundColor Yellow
        Write-Host "    $RunConnFail target(s) could not be reached" -ForegroundColor Yellow
        Write-Host "    All checks were skipped for these targets" -ForegroundColor Yellow
        Write-Host "    See report for details" -ForegroundColor Yellow
        Write-Host ''
    }
    
    Write-Host "  Spokes executed  : $($SpokeFiles.Count)" -ForegroundColor White
    Write-Host "  Total findings   : $RunTotalCheck"       -ForegroundColor White
    Write-Host "    [+]  Pass      : $RunTotalPass"        -ForegroundColor Green
    Write-Host "    [!]  Attention : $RunTotalAttn"        -ForegroundColor Yellow
    Write-Host "    [x]  Fail      : $RunTotalFail"        -ForegroundColor Red
    if ($RunTotalInfo -gt 0) {
        Write-Host "    [?]  Info      : $RunTotalInfo"    -ForegroundColor Cyan
    }
    Write-Host "  Elapsed          : $elapsed"              -ForegroundColor White
    Write-Host ''
    Write-Host '  ARTIFACTS:' -ForegroundColor DarkGray
    if ($_transcriptPath) {
        Write-Host "    Transcript   : $_transcriptPath"     -ForegroundColor DarkGray
    }
    Write-Host "    Findings JSON: $JsonPath"               -ForegroundColor DarkGray
    Write-Host "    HTML Report  : $(if ($ReportPath) { $ReportPath } else { '(not built)' })" `
               -ForegroundColor DarkGray

    if ($removedFiles.Count -gt 0) {
        Write-Host ''
        Write-Host "  Pruned $($removedFiles.Count) old artifact(s):" -ForegroundColor DarkGray
        foreach ($n in ($removedFiles | Select-Object -First 5)) { 
            Write-Host "    - $n" -ForegroundColor DarkGray 
        }
        if ($removedFiles.Count -gt 5) {
            Write-Host "    ... and $($removedFiles.Count - 5) more" -ForegroundColor DarkGray
        }
    }

    Write-Host ''
    Write-Host ('=' * 70) -ForegroundColor Cyan
    Write-Host ''

} finally {
    if ($Targets) {
        foreach ($target in $Targets) {
            if ($target.Credential) {
                try {
                    $target.Credential.Password.Dispose()
                } catch {
                    # Silently handle disposal errors
                }
            }
        }
    }
    
    # Clear any credential caches that may exist in scope
    if (Get-Variable -Name 'credCache' -Scope Script -ErrorAction SilentlyContinue) {
        foreach ($cred in $script:credCache.Values) {
            try {
                if ($cred -and $cred.Password) {
                    $cred.Password.Dispose()
                }
            } catch {}
        }
        Remove-Variable -Name 'credCache' -Scope Script -Force -ErrorAction SilentlyContinue
    }
    
    # Always stop the stopwatch and close the transcript - even on hard failure.
    try   { $__runSw.Stop() }        catch {}
    if ($_transcriptPath) {
        try { Stop-Transcript | Out-Null } catch {}
    }
}