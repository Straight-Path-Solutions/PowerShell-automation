#Requires -Version 5.1
# =============================================================================
# Helpers\Checkup.Engine.ps1  -  Engine-facing primitives for the SQL Health Suite
# =============================================================================
#
# WHAT BELONGS HERE:
#   Helpers used ONLY by Core.Checkup.ps1 (the engine).
#   Persistence (JSON read/write), metrics aggregation, deduplication,
#   connection testing, console output, and path resolution.
#
# WHAT DOES NOT BELONG HERE:
#   Spoke-facing primitives (Cfg, Invoke-DBATools, Invoke-Check, New-Finding, etc.)
#     -> Helper.Shared.ps1
#   Pack-specific shared calculations (Build-AgentJobMetrics, etc.)
#     -> Common.<PackName>.ps1
#   Check logic of any kind
#     -> Checks.*.ps1
#
# DEPENDENCIES:
#   - Helper.Shared.ps1 (must be dot-sourced first by Core.Checkup.ps1)
#   - dbatools module
#
# CONTRACT REFERENCES:
#   - Contract J: JSON findings format and serialization rules
#   - Contract D: Target object structure
#   - Contract A: Engine-spoke orchestration
#   - Contract E: Config visibility in transcripts
#
# LOADING:
#   Dot-sourced by Core.Checkup.ps1 immediately after Helper.Shared.ps1.
#   Publish-HealthSuiteFunctions (Helper.Shared.ps1) promotes all functions
#   defined here into global scope so spoke runspaces can reach them if needed.
#
# REGION MAP:
#   1.  JSON I/O               - Write-InstancesJson, Write-JsonFile         (Contract J)
#   2.  Deduplication          - Convert-ToCanonicalJson, Remove-DuplicateChecks
#   3.  Metrics & formatting   - Measure-Findings, Format-FindingsSummary
#   4.  Connection testing     - Test-SqlConnection
#   5.  Console output         - Write-VLog, Write-Section, Write-PackParams
#   6.  Path resolution        - Resolve-TargetsPs1Path
#   7.  Fetch progress         - Write-FetchProgress, Initialize-FetchProgress
# =============================================================================


# =============================================================================
#  1. JSON I/O  (Contract J)
# =============================================================================
#region JSON I/O

function Write-InstancesJson {
    <#
    .SYNOPSIS
        Serialise a collection of instance envelopes to the findings JSON file.
        This file is the system of record (Contract J); HTML is built from it exclusively.

    .DESCRIPTION
        Accepts either an array of instance objects (the normal case) or a JSON string /
        a pre-wrapped object with an 'instances' property (for idempotent re-serialisation).
        Writes UTF-8 without BOM so the file is portable across toolchains.

        Contract J rules enforced:
          - No HTML in any field (enforced by callers via New-Finding)
          - status is always lowercase (enforced by New-Finding / Test-Status)
          - lastCheck is always ISO-8601 UTC with Z suffix (enforced by New-Instance)
          - Serialised with Depth 100 so nested evidence objects are not truncated

    .PARAMETER Inputs
        Array of pscustomobject instances as returned by New-Instance (Helper.Shared.ps1).
        Also accepts a JSON string or an already-wrapped { instances: [...] } object.

    .PARAMETER Path
        Full path to the output JSON file. Parent directory is created if absent.

    .OUTPUTS
        pscustomobject - The wrapped payload object ({ instances: [...] }) so callers 
        can inspect totals without re-reading the file.

    .EXAMPLE
        $payload = Write-InstancesJson -Inputs $allInstances -Path 'Output\findings.json'
        Write-Host "Wrote $($payload.instances.Count) instances"

    .NOTES
        Contract: J (JSON findings format)
        
        Used by: Core.Checkup.ps1 (final report write)
        
        Single-element arrays are explicitly wrapped in brackets to prevent ConvertTo-Json
        from serializing them as bare objects. Empty arrays serialize as "[]".
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object]$Inputs,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    # Normalise: accept a JSON string, a wrapped object, or a plain array.
    if ($Inputs -is [string]) {
        try { 
            $Inputs = $Inputs | ConvertFrom-Json -ErrorAction Stop 
        } catch {
            Write-Warning "Failed to parse Inputs as JSON: $_"
            $Inputs = @()
        }
    }

    if ($null -ne $Inputs -and 
        $Inputs.PSObject -and 
        $Inputs.PSObject.Properties['instances']) {
        $instances = $Inputs.instances
    } else {
        $instances = $Inputs
    }

    # Ensure instances is an array
    if ($null -eq $instances) {
        $instances = @()
    } elseif ($instances -isnot [array]) {
        $instances = @($instances)
    }

    # Serialize instances array with explicit bracket handling
    $instancesJson = if ($instances.Count -eq 0) {
        '[]'
    } elseif ($instances.Count -eq 1) {
        # Single element: force brackets explicitly
        '[' + ($instances[0] | ConvertTo-Json -Depth 100 -Compress) + ']'
    } else {
        # Multiple elements: pipeline serialization preserves the array naturally
        $instances | ConvertTo-Json -Depth 100 -Compress
    }

    $json    = '{"instances":' + $instancesJson + '}'
    $payload = $json | ConvertFrom-Json   # rebuild payload object for the return value

    # Ensure the output directory exists
    $dir = Split-Path -Path $Path -Parent
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }

    # Write UTF-8 without BOM
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $json, $utf8)

    return $payload
}

function Write-JsonFile {
    <#
    .SYNOPSIS
        Serialise any object to a UTF-8-without-BOM JSON file.
        General-purpose helper used for settings.json persistence.

    .DESCRIPTION
        Provides consistent JSON serialization for configuration files and other
        non-findings payloads. Always writes UTF-8 without BOM for cross-platform
        compatibility.

    .PARAMETER Object
        The object to serialise. Passed directly to ConvertTo-Json.

    .PARAMETER Path
        Full destination path. Parent directory is created if absent.

    .PARAMETER Depth
        ConvertTo-Json -Depth value. Defaults to 100 to avoid silent truncation.

    .EXAMPLE
        Write-JsonFile -Object $settings -Path 'Config\settings.json'

    .NOTES
        Not a Contract J function - that is Write-InstancesJson.
        Use this only for settings.json and other non-findings payloads.
        
        Used by: Core.Checkup.ps1 (settings persistence)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object]$Object,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [int]$Depth = 100
    )

    # Guard against null object
    if ($null -eq $Object) {
        Write-Warning "Write-JsonFile: Object is null, writing empty object"
        $Object = @{}
    }

    $dir = Split-Path -Path $Path -Parent
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }

    $json = $Object | ConvertTo-Json -Depth $Depth
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $json, $utf8)
}

#endregion


# =============================================================================
#  2. DEDUPLICATION
# =============================================================================
#region Deduplication

function Convert-ToCanonicalJson {
    <#
    .SYNOPSIS
        Produce a stable, order-normalised JSON fingerprint for any object.
        Used by Remove-DuplicateChecks to detect structurally identical findings
        that may have been emitted by more than one spoke in the same run.

    .DESCRIPTION
        Recursively sorts dictionary/hashtable keys and array elements to ensure
        that two objects that differ only in property order produce the same string.

        Primitives (string, bool, numeric, DateTime, Guid) are returned as-is so
        ConvertTo-Json serialises them faithfully.

    .PARAMETER InputObject
        The object to fingerprint.

    .PARAMETER Depth
        Maximum recursion depth passed to ConvertTo-Json. Default 100.

    .EXAMPLE
        $sig1 = Convert-ToCanonicalJson -InputObject @{ B=2; A=1 }
        $sig2 = Convert-ToCanonicalJson -InputObject @{ A=1; B=2 }
        # $sig1 -eq $sig2 -> $true

    .NOTES
        This function is intentionally NOT exported for spoke use.
        Findings are deduplicated at the engine level, not inside spokes.
        
        Used by: Remove-DuplicateChecks (internal only)
        
        Performance: Uses ordered hashtables and minimal allocations. Safe for
        hundreds of findings per target.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        $InputObject,

        [int]$Depth = 100
    )

    function Normalize {
        param([object]$obj)

        if ($null -eq $obj) { return $null }

        # Pass primitives through unchanged
        if ($obj -is [string]   -or $obj -is [char]    -or $obj -is [bool]    -or
            $obj -is [byte]     -or $obj -is [int16]   -or $obj -is [int32]   -or
            $obj -is [int64]    -or $obj -is [double]  -or $obj -is [single]  -or
            $obj -is [decimal]  -or $obj -is [datetime]-or $obj -is [guid]) {
            return $obj
        }

        # Sort dictionary keys
        if ($obj -is [System.Collections.IDictionary]) {
            $ordered = [ordered]@{}
            foreach ($k in ($obj.Keys | Sort-Object)) { 
                $ordered[$k] = Normalize $obj[$k] 
            }
            return $ordered
        }

        # Recurse into enumerables (excluding strings, already handled above)
        if ($obj -is [System.Collections.IEnumerable]) {
            $tmp = @()
            foreach ($item in $obj) { 
                $tmp += Normalize $item 
            }
            return , $tmp
        }

        # PSCustomObject / any other object: sort by property name
        $propNames = @()
        try { 
            $propNames = @($obj.PSObject.Properties | ForEach-Object { $_.Name }) 
        } catch {}

        if ($propNames.Length -gt 0) {
            $ordered = [ordered]@{}
            foreach ($p in ($propNames | Sort-Object)) {
                try { 
                    $ordered[$p] = Normalize ($obj.$p) 
                } catch { 
                    $ordered[$p] = $null 
                }
            }
            return $ordered
        }

        return $obj
    }

    $norm = Normalize $InputObject
    return ($norm | ConvertTo-Json -Depth $Depth -Compress)
}

function Remove-DuplicateChecks {
    <#
    .SYNOPSIS
        Remove structurally identical findings from a flat findings array.
        Preserves order; first occurrence wins.

    .DESCRIPTION
        Deduplication is the engine's responsibility and runs after all spokes have
        completed for a target (Contract A: spokes are append-only and cannot see
        findings from other spokes).

        Uses Convert-ToCanonicalJson to fingerprint each finding. Falls back to
        Out-String if JSON serialisation fails (e.g. circular reference).

    .PARAMETER Checks
        The flat array of finding objects to deduplicate.
        Accepts pipeline input.

    .EXAMPLE
        $targetFindings = Remove-DuplicateChecks -Checks $targetFindings
        Write-Host "Deduplicated to $($targetFindings.Count) findings"

    .EXAMPLE
        $unique = $allFindings | Remove-DuplicateChecks
        
    .NOTES
        Only call this at the engine level, never inside a spoke.
        
        Used by: Core.Checkup.ps1 (per-target finding consolidation)
        
        Performance: O(n) with hashtable lookup. Handles thousands of findings
        efficiently. Null-safe and handles empty arrays gracefully.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Checks
    )
    
    begin {
        $seen = @{}
        $out  = New-Object System.Collections.ArrayList
    }
    
    process {
        foreach ($c in $Checks) {
            if ($null -eq $c) { continue }
            
            try {
                $sig = Convert-ToCanonicalJson -InputObject $c -Depth 100
            } catch {
                # Fallback for objects that can't be JSON-serialized
                $sig = ($c | Out-String)
            }

            if (-not $seen.ContainsKey($sig)) {
                $seen[$sig] = $true
                [void]$out.Add($c)
            }
        }
    }
    
    end { 
        , @($out) 
    }
}

#endregion


# =============================================================================
#  3. METRICS & FORMATTING
# =============================================================================
#region Metrics & formatting

function Measure-Findings {
    <#
    .SYNOPSIS
        Aggregate a findings array into pass/attention/fail/info counts plus
        a per-category breakdown.

    .DESCRIPTION
        Used by the engine to produce per-spoke, per-target, and run-wide summary
        lines. Also used to compute the totals written to the transcript.

        All inputs are null-guarded so the function is safe to call even when a
        spoke emits no findings (e.g. fast-exit / pack disabled).

    .PARAMETER Findings
        Flat array of finding objects (pscustomobject with at least a 'status' property).
        Accepts $null and empty arrays without throwing.

    .OUTPUTS
        pscustomobject with properties:
            Total      [int]
            Pass       [int]
            Attention  [int]
            Fail       [int]
            Info       [int]
            ByCategory [pscustomobject[]]  (one row per category, same counters)

    .EXAMPLE
        $metrics = Measure-Findings -Findings $targetFindings
        Write-Host "Total: $($metrics.Total), Fail: $($metrics.Fail)"

    .EXAMPLE
        $metrics = Measure-Findings -Findings @()
        # Returns all zeroes, safe for empty arrays

    .NOTES
        Used by: Core.Checkup.ps1, Report.HtmlBuilder.ps1
        
        Null-safe: Handles $null, empty arrays, and arrays with null elements.
        Category breakdown is sorted alphabetically for consistent output.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Findings
    )

    # Materialise into a real array, dropping nulls
    $rows = @(if ($null -ne $Findings) { 
        $Findings | Where-Object { $null -ne $_ } 
    })

    $pass = [int]@($rows | Where-Object { $_.status -eq 'pass'      }).Count
    $attn = [int]@($rows | Where-Object { $_.status -eq 'attention' }).Count
    $fail = [int]@($rows | Where-Object { $_.status -eq 'fail'      }).Count
    $info = [int]@($rows | Where-Object { $_.status -eq 'info'      }).Count

    $byCat = @($rows | Group-Object category | Sort-Object Name | ForEach-Object {
        $grp = @($_.Group)
        [pscustomobject]@{
            Category  = $_.Name
            Total     = [int]$grp.Count
            Pass      = [int]@($grp | Where-Object { $_.status -eq 'pass'      }).Count
            Attention = [int]@($grp | Where-Object { $_.status -eq 'attention' }).Count
            Fail      = [int]@($grp | Where-Object { $_.status -eq 'fail'      }).Count
            Info      = [int]@($grp | Where-Object { $_.status -eq 'info'      }).Count
        }
    })

    [pscustomobject]@{
        Total      = [int]$rows.Count
        Pass       = $pass
        Attention  = $attn
        Fail       = $fail
        Info       = $info
        ByCategory = $byCat
    }
}

function Format-FindingsSummary {
    <#
    .SYNOPSIS
        Format a Measure-Findings result into a compact one-line string for
        console and transcript output.

    .DESCRIPTION
        Produces strings like:
            "14 findings (Pass 8 - Attn 4 - Fail 2)"
            "14 findings (Pass 8 - Attn 4 - Fail 2 - Info 1)"

        Info is omitted when zero to reduce noise in console output.

    .PARAMETER Metrics
        pscustomobject returned by Measure-Findings.

    .PARAMETER MaxCats
        Maximum number of category breakdown entries to show.
        Reserved for future use; currently the summary line does not include
        per-category detail (the engine writes that separately if needed).

    .EXAMPLE
        $metrics = Measure-Findings -Findings $findings
        $summary = Format-FindingsSummary -Metrics $metrics
        Write-Host $summary

    .EXAMPLE
        Format-FindingsSummary -Metrics @{ Total=0; Pass=0; Attention=0; Fail=0; Info=0 }
        # Output: "0 findings (Pass 0 - Attn 0 - Fail 0)"

    .NOTES
        Used by: Core.Checkup.ps1 (console output), Report transcripts
        
        The output format is intentionally compact for single-line transcript entries.
        Use Measure-Findings.ByCategory for detailed category breakdowns.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        $Metrics,

        [int]$MaxCats = 3
    )

    # Validate Metrics structure
    if (-not ($Metrics.PSObject.Properties.Name -contains 'Total')) {
        Write-Warning "Format-FindingsSummary: Metrics object missing 'Total' property"
        return "Invalid metrics object"
    }

    if ($Metrics.PSObject.Properties.Name -contains 'Info' -and [int]$Metrics.Info -gt 0) {
        '{0} findings (Pass {1} - Attn {2} - Fail {3} - Info {4})' -f `
            $Metrics.Total, $Metrics.Pass, $Metrics.Attention, $Metrics.Fail, $Metrics.Info
    } else {
        '{0} findings (Pass {1} - Attn {2} - Fail {3})' -f `
            $Metrics.Total, $Metrics.Pass, $Metrics.Attention, $Metrics.Fail
    }
}

#endregion


# =============================================================================
#  4. CONNECTION TESTING
# =============================================================================
#region Connection testing

function Test-SqlConnection {
    <#
    .SYNOPSIS
        Test SQL Server connectivity for a target before invoking any spokes.
        Returns $true on success, $false on any failure.

    .DESCRIPTION
        Uses a two-phase probe strategy:

          Phase 1 - Connect-DbaInstance
            Lightweight SMO connection with ConnectTimeout. Succeeds if the
            server object is returned with a populated Version property.

          Phase 2 - Invoke-DbaQuery (fallback)
            Runs "SELECT 1" via the query engine. Catches edge cases where the
            SMO object is returned but is not fully functional (e.g. limited
            connectivity, named-pipe only, authentication anomalies).

        If both phases fail, $false is returned and the engine records a
        'fail' finding for this target and skips all spokes (Contract A).

    .PARAMETER Target
        Target object with SqlInstance property (Contract D).
        SqlCredential is included in the probe when Credential is non-null.

    .PARAMETER TimeoutSeconds
        Connection timeout in seconds. Supplied from Config['ConnectionTestTimeoutSeconds']
        by the engine; default here is defensive only.

    .EXAMPLE
        if (Test-SqlConnection -Target $tgt -TimeoutSeconds 10) {
            # Proceed with spokes
        }

    .EXAMPLE
        $canConnect = Test-SqlConnection -Target @{ SqlInstance='localhost'; Credential=$null } -TimeoutSeconds 5

    .NOTES
        Contract: D (Target structure), A (Engine-spoke orchestration)
        
        This function never throws - it returns $true/$false exclusively.
        Spokes should never call this directly; it is an engine-only helper.
        
        Used by: Core.Checkup.ps1 (pre-spoke connectivity check)
        
        Performance: Both phases respect the timeout parameter. Total test time
        will not exceed 2x TimeoutSeconds in the worst case (both phases timing out).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [object]$Target,

        [ValidateRange(1, 300)]
        [int]$TimeoutSeconds = 5
    )

    # Validate Target structure
    if (-not $Target.PSObject.Properties['SqlInstance']) {
        Write-Warning "Test-SqlConnection: Target missing SqlInstance property"
        return $false
    }

    $baseParams = @{
        SqlInstance     = $Target.SqlInstance
        ConnectTimeout  = $TimeoutSeconds
        EnableException = $true
    }
    if ($Target.PSObject.Properties['Credential'] -and $Target.Credential) { 
        $baseParams.SqlCredential = $Target.Credential 
    }

    # Phase 1: SMO connection
    try {
        $server = Connect-DbaInstance @baseParams
        if ($server -and $server.Version) { 
            return $true 
        }
    } catch {
        # Fall through to phase 2
    }

    # Phase 2: Direct query fallback
    try {
        $queryParams = @{
            SqlInstance     = $Target.SqlInstance
            Query           = 'SELECT 1 AS Alive'
            QueryTimeout    = $TimeoutSeconds
            EnableException = $true
        }
        if ($Target.PSObject.Properties['Credential'] -and $Target.Credential) { 
            $queryParams.SqlCredential = $Target.Credential 
        }

        $result = Invoke-DbaQuery @queryParams
        return ($null -ne $result)
    } catch {
        return $false
    }
}

#endregion


# =============================================================================
#  5. CONSOLE OUTPUT
# =============================================================================
#region Console output

function Write-VLog {
    <#
    .SYNOPSIS
        Write a console line only when the verbose logging flag is active.

    .DESCRIPTION
        Reads $_verboseRun from the calling scope (set in Core.Checkup.ps1 from
        Config['Logging']['VerboseRun']). No-ops silently when the flag is $false,
        so spokes and helpers can call this freely without conditionals.

    .PARAMETER Message
        The line to write.

    .PARAMETER Color
        Foreground colour passed to Write-Host. Default: Gray.

    .PARAMETER Indent
        Number of two-space indentation levels prepended to Message.

    .EXAMPLE
        Write-VLog "Starting backup checks" -Color Cyan
        
    .EXAMPLE
        Write-VLog "  Processing AG listener" -Indent 1

    .NOTES
        Contract: E (Config visibility)
        
        Used by: Core.Checkup.ps1, all spokes (conditional console output)
        
        Requires $_verboseRun to be set in the caller's scope (typically script scope).
        Silently no-ops when the variable is not found or is $false.
    #>
    [CmdletBinding()]
    param(
        [string]$Message = '',

        [ValidateSet('Black', 'DarkBlue', 'DarkGreen', 'DarkCyan', 'DarkRed', 
                     'DarkMagenta', 'DarkYellow', 'Gray', 'DarkGray', 'Blue', 
                     'Green', 'Cyan', 'Red', 'Magenta', 'Yellow', 'White')]
        [string]$Color = 'Gray',

        [ValidateRange(0, 10)]
        [int]$Indent = 0
    )

    # Check if verbose logging is enabled in caller's scope
    $verboseEnabled = $false
    try {
        $verboseEnabled = Get-Variable -Name '_verboseRun' -Scope Script -ValueOnly -ErrorAction SilentlyContinue
    } catch {}

    if (-not $verboseEnabled) { return }

    $prefix = '  ' * $Indent
    Write-Host "${prefix}${Message}" -ForegroundColor $Color
}

function Write-Section {
    <#
    .SYNOPSIS
        Print a clearly visible section header to the console.
        Used by the engine to delineate the nine run steps.

    .PARAMETER Title
        The step title, e.g. 'STEP 1 - Settings'.

    .EXAMPLE
        Write-Section -Title 'STEP 3 - Target Resolution'

    .NOTES
        Used by: Core.Checkup.ps1 (run step headers)
        
        Emits three lines: blank line, separator, title, separator.
        Always visible regardless of verbose logging settings.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Title
    )

    Write-Host ''
    Write-Host ('-' * 70) -ForegroundColor DarkGray
    Write-Host "  $Title"  -ForegroundColor Cyan
    Write-Host ('-' * 70) -ForegroundColor DarkGray
}

function Write-PackParams {
    <#
    .SYNOPSIS
        Emit the Config sub-hashtable for a given spoke to the console.
        Controlled by the $_showCheckParams logging flag.

    .DESCRIPTION
        Extracts the pack name from the spoke filename (strips 'Checks.' prefix
        and '.ps1' suffix), then prints every key/value pair in Config[PackName].

        This makes the effective config for each pack visible in the transcript,
        which is essential for post-run audit (Contract E: all config visible,
        no hidden knobs).

    .PARAMETER PackName
        The spoke filename, e.g. 'Checks.Agent.ps1'.

    .PARAMETER Config
        The full $Config hashtable passed to the engine.

    .EXAMPLE
        Write-PackParams -PackName 'Checks.Agent.ps1' -Config $Config

    .EXAMPLE
        Write-PackParams -PackName 'Checks.Storage.ps1' -Config $Config
        # Output (if Config.Storage exists):
        #   [Config.Storage]
        #     DiskFreePercentWarn = 15
        #     DiskFreePercentFail = 10

    .NOTES
        Contract: E (Config visibility)
        
        Used by: Core.Checkup.ps1 (per-spoke config display)
        
        Only active when $_showCheckParams is $true (set from Logging.ShowCheckParams).
        Supports both classic and tree output modes (via $_useTreeOutput).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$PackName,

        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [hashtable]$Config
    )

    # Check if parameter display is enabled
    $showParams = $false
    try {
        $showParams = Get-Variable -Name '_showCheckParams' -Scope Script -ValueOnly -ErrorAction SilentlyContinue
    } catch {}

    if (-not $showParams) { return }

    # Derive sub-key: 'Checks.Agent.ps1' -> 'Agent'
    $subKey = $PackName -replace '^Checks\.', '' -replace '\.ps1$', ''

    if ($Config.ContainsKey($subKey) -and $Config[$subKey] -is [hashtable]) {
        # Check if tree output mode is enabled
        $useTree = $false
        try {
            $useTree = Get-Variable -Name '_useTreeOutput' -Scope Script -ValueOnly -ErrorAction SilentlyContinue
        } catch {}

        if ($useTree) {
            Write-TreeLine -Level 3 -Tag 'CFG' -Text "Config.$subKey"
            foreach ($k in ($Config[$subKey].Keys | Sort-Object)) {
                Write-TreeLine -Level 4 -Tag 'CFG' -Text ('{0} = {1}' -f $k, $Config[$subKey][$k])
            }
        } else {
            Write-Host "    [Config.$subKey]" -ForegroundColor DarkYellow
            foreach ($k in ($Config[$subKey].Keys | Sort-Object)) {
                Write-Host ('      {0,-35} = {1}' -f $k, $Config[$subKey][$k]) -ForegroundColor DarkGray
            }
        }
    }
}

#endregion


# =============================================================================
#  6. PATH RESOLUTION
# =============================================================================
#region Path resolution

function Resolve-TargetsPs1Path {
    <#
    .SYNOPSIS
        Locate Targets.ps1 relative to the engine root, trying several
        conventional locations before giving up.

    .DESCRIPTION
        Called by the engine when targets.json is absent or -ReplaceTargetConfig
        is specified. Returns the full resolved path on success, or $null if
        none of the candidate paths exist.

        Search order:
          1. The path supplied by the caller (-InputPath), if any
          2. <EngineRoot>\Helpers\Targets.ps1
          3. <EngineRoot>\Targets.ps1
          4. <EngineRoot>\..\Helpers\Targets.ps1  (engine in a subfolder)
          5. <EngineRoot>\..\Targets.ps1

    .PARAMETER InputPath
        Optional explicit path provided by the menu / Start-SqlHealthSuite.ps1.

    .PARAMETER EngineRoot
        $PSScriptRoot of Core.Checkup.ps1.

    .OUTPUTS
        [string] Resolved absolute path, or $null.

    .EXAMPLE
        $targetsPath = Resolve-TargetsPs1Path -EngineRoot $PSScriptRoot
        if ($targetsPath) {
            . $targetsPath
        }

    .EXAMPLE
        $path = Resolve-TargetsPs1Path -InputPath 'C:\MyTargets.ps1' -EngineRoot $PSScriptRoot
        # Returns 'C:\MyTargets.ps1' if it exists, otherwise searches fallback locations

    .NOTES
        Used by: Core.Checkup.ps1 (target discovery)
        
        Returning $null rather than throwing lets the engine emit a meaningful
        error message with context about what it tried.
        
        All candidate paths are de-duplicated before testing to avoid redundant
        file system checks.
    #>
    [CmdletBinding()]
    param(
        [string]$InputPath,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$EngineRoot
    )

    $candidates = @()

    # Priority 1: Explicit path if provided
    if ($InputPath) { 
        $candidates += $InputPath 
    }

    # Priority 2: Standard locations relative to engine
    $candidates += (Join-Path $EngineRoot 'Helpers\Targets.ps1')
    $candidates += (Join-Path $EngineRoot 'Targets.ps1')

    # Priority 3: Parent directory (engine in subfolder scenario)
    $parent = Split-Path -Path $EngineRoot -Parent
    if ($parent) {
        $candidates += (Join-Path $parent 'Helpers\Targets.ps1')
        $candidates += (Join-Path $parent 'Targets.ps1')
    }

    # Test candidates in order, return first match
    foreach ($p in ($candidates | Where-Object { $_ } | Select-Object -Unique)) {
        if (Test-Path -LiteralPath $p) {
            return (Resolve-Path -LiteralPath $p).Path
        }
    }

    return $null
}

#endregion


# =============================================================================
#  7. FETCH PROGRESS
# =============================================================================
#region Fetch progress

function Initialize-FetchProgress {
    <#
    .SYNOPSIS
        Initialize or reset the fetch progress system at the start of a run.

    .DESCRIPTION
        Cleans up any orphaned event subscriptions from previous runs and ensures
        the fetch progress system is in a clean state. Should be called once at
        the beginning of Checkup.Engine.ps1 execution.

    .EXAMPLE
        Initialize-FetchProgress
        # Called once at start of engine run

    .NOTES
        Used by: Checkup.Engine.ps1 (initialization phase)

        Silently handles cases where no subscriptions exist or cleanup fails.
        Non-blocking - never throws exceptions that would halt the engine.
    #>
    [CmdletBinding()]
    param()

    # Clean up any orphaned event subscriptions from previous runs
    try {
        Get-EventSubscriber | Where-Object {
            $_.SourceIdentifier -like 'fetchSpinner_*'
        } | ForEach-Object {
            try {
                Unregister-Event -SourceIdentifier $_.SourceIdentifier -ErrorAction SilentlyContinue
            } catch {}
        }
    } catch {}

    # Clean up any orphaned events
    try {
        Get-Event | Where-Object {
            $_.SourceIdentifier -like 'fetchSpinner_*'
        } | ForEach-Object {
            try {
                Remove-Event -SourceIdentifier $_.SourceIdentifier -ErrorAction SilentlyContinue
            } catch {}
        }
    } catch {}
}

function Write-FetchProgress {
    <#
    .SYNOPSIS
        Display an animated spinner during long-running spoke data fetch operations.

    .DESCRIPTION
        Spokes call this at the start and end of their data-fetch region to provide
        visual feedback during slow dbatools operations. The spinner updates in-place
        on the console (when supported) to avoid cluttering the transcript.

        Three-phase operation:
          -Start: Begins the spinner, returns a token hashtable
          -Update: Updates the label text (optional, can be called multiple times)
          -End:   Stops the spinner, prints elapsed time

        In non-interactive environments (ISE, pipeline), falls back to simple
        in-progress and done messages without animation.

    .PARAMETER Spoke
        The spoke short-name shown in the spinner, e.g. 'Agent', 'Host'.
        Required when using -Start.

    .PARAMETER Label
        Initial fetch description when using -Start (default: "Fetching Data").
        New description when using -Update.

    .PARAMETER IntervalMs
        Spinner update interval in milliseconds. Default: 120ms.

    .PARAMETER Start
        Switch: begin the spinner. Returns a token hashtable.

    .PARAMETER Token
        Pass the hashtable returned by -Start. Required when using -Update or -End.

    .PARAMETER Update
        Switch: update the spinner label text without stopping it.

    .PARAMETER End
        Switch: stop the spinner and print the DONE line.

    .EXAMPLE
        $pfToken = Write-FetchProgress -Spoke 'Agent' -Start

        Update-FetchProgress -Token $pfToken -Label 'Step 1 - Jobs'
        $jobs = Invoke-DBATools { Get-DbaAgentJob @sql -EnableException }

        Update-FetchProgress -Token $pfToken -Label 'Step 2 - History'
        $history = Invoke-DBATools { Get-DbaAgentJobHistory @sql -EnableException }

        Write-FetchProgress -Token $pfToken -End

    .EXAMPLE
        $token = Write-FetchProgress -Spoke 'Security' -Label 'Analyzing permissions' -Start
        # ... work ...
        Write-FetchProgress -Token $token -End

    .NOTES
        Used by: All spokes (data fetch phase)

        Console capability detection:
          - Full spinner: ConsoleHost + UserInteractive
          - Fallback: ISE, VS Code, non-interactive (static messages)

        The spinner uses System.Timers.Timer with event registration to update
        the console asynchronously. All resources (timer, events) are cleaned up
        automatically in the -End phase.

        Thread-safe: Each invocation uses a unique GUID-based SourceIdentifier
        to prevent conflicts when multiple runspaces use fetch progress.

        Requires PowerShell 5.1 or later. No PS7-only syntax used.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Start')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Start')]
        [ValidateNotNullOrEmpty()]
        [string]$Spoke,

        [Parameter(ParameterSetName = 'Start')]
        [Parameter(Mandatory, ParameterSetName = 'Update')]
        [string]$Label = 'Fetching Data',

        [Parameter(ParameterSetName = 'Start')]
        [ValidateRange(50, 1000)]
        [int]$IntervalMs = 120,

        [Parameter(Mandatory, ParameterSetName = 'Start')]
        [switch]$Start,

        [Parameter(Mandatory, ParameterSetName = 'Update')]
        [Parameter(Mandatory, ParameterSetName = 'End')]
        [ValidateNotNull()]
        [hashtable]$Token,

        [Parameter(Mandatory, ParameterSetName = 'Update')]
        [switch]$Update,

        [Parameter(Mandatory, ParameterSetName = 'End')]
        [switch]$End
    )

    # Helper: detect if we're in an interactive console that supports \r updates
    function Test-SpinnerCapable {
        try {
            return ($Host.Name -eq 'ConsoleHost' -and [Environment]::UserInteractive)
        } catch {
            return $false
        }
    }

    # -Start path --------------------------------------------------------------
    if ($PSCmdlet.ParameterSetName -eq 'Start') {
        $sw      = [System.Diagnostics.Stopwatch]::StartNew()
        $prefix  = "  |  |   "
        $frames  = @('-', '\', '|', '/')
        $srcId   = "fetchSpinner_{0}" -f ([Guid]::NewGuid().ToString('N'))
        $initial = "{0}[{1}] {2} ... " -f $prefix, $frames[0], $Label
        $capable = Test-SpinnerCapable

        if ($capable) {
            # Wrap the full spinner setup in try/catch so any console or
            # event-registration failure falls through to the static fallback.
            try {
                [Console]::Write($initial)

                $timer           = New-Object System.Timers.Timer
                $timer.Interval  = [Math]::Max(50, $IntervalMs)
                $timer.AutoReset = $true

                $token = @{
                    Spoke          = $Spoke
                    Label          = $Label
                    Prefix         = $prefix
                    Frames         = $frames
                    FrameIndex     = 0
                    Stopwatch      = $sw
                    SourceId       = $srcId
                    Timer          = $timer
                    LastLen        = $initial.Length
                    SpinnerCapable = $true
                }

                # Event action updates the same console line in-place
                Register-ObjectEvent `
                    -InputObject      $timer `
                    -EventName        Elapsed `
                    -SourceIdentifier $srcId `
                    -MessageData      $token `
                    -Action {
                        $t = $event.MessageData
                        if (-not $t -or -not $t.Timer) { return }
                        try {
                            if (-not $t.Frames -or $t.Frames.Count -eq 0) { return }
                            $t.FrameIndex = ($t.FrameIndex + 1) % $t.Frames.Count
                            $frame = $t.Frames[$t.FrameIndex]
                            $sec   = [Math]::Round($t.Stopwatch.Elapsed.TotalSeconds, 1)
                            $line  = "{0}[{1}] {2} ... [{3}s]" -f $t.Prefix, $frame, $t.Label, $sec
                            $pad   = ''
                            if ($t.LastLen -gt $line.Length) {
                                $pad = ' ' * ($t.LastLen - $line.Length)
                            } else {
                                $t.LastLen = $line.Length
                            }
                            [Console]::Write("`r$line$pad")
                        } catch {}
                    } | Out-Null

                $timer.Start()
                return $token

            } catch {
                # Console or event setup failed - fall through to static fallback
                $capable = $false
            }
        }

        # Static fallback: one line per label update, no in-place overwrite
        Write-Host $initial -NoNewline -ForegroundColor DarkGray

        return @{
            Spoke          = $Spoke
            Label          = $Label
            Prefix         = $prefix
            Frames         = $frames
            Stopwatch      = $sw
            SpinnerCapable = $false
        }
    }

    # -Update path -------------------------------------------------------------
    if ($PSCmdlet.ParameterSetName -eq 'Update') {
        if ($null -eq $Token) {
            Write-Warning "Write-FetchProgress -Update called with null token"
            return
        }

        $Token.Label = $Label

        if (-not $Token.SpinnerCapable) {
            # Finish the previous -NoNewline write, then start the next label line
            Write-Host ''

            $pfx    = if ($Token.ContainsKey('Prefix') -and $Token.Prefix) { $Token.Prefix } else { '  |  |   ' }
            $fr     = if ($Token.ContainsKey('Frames') -and $Token.Frames) { $Token.Frames } else { @('-', '\', '|', '/') }
            $line   = '{0}[{1}] {2} ... ' -f $pfx, $fr[0], $Label
            Write-Host $line -NoNewline -ForegroundColor DarkGray
        }
        # Spinner-capable: timer event picks up the updated $Token.Label automatically
    }

    # -End path ----------------------------------------------------------------
    if ($PSCmdlet.ParameterSetName -eq 'End') {
        if ($null -eq $Token) {
            Write-Warning "Write-FetchProgress -End called with null token"
            return
        }

        # Safely stop the stopwatch and capture elapsed time.
        # Stopwatch.Elapsed is a value-type (TimeSpan) but Stopwatch itself can be
        # null if -Start failed before assigning it.
        $elapsedSpan = $null
        if ($Token.ContainsKey('Stopwatch') -and $null -ne $Token.Stopwatch) {
            try {
                $Token.Stopwatch.Stop()
                $elapsedSpan = $Token.Stopwatch.Elapsed
            } catch {}
        }

        # Format elapsed - '?' when TimeSpan could not be obtained
        if ($null -ne $elapsedSpan) {
            try   { $elapsed = Format-TimeSpan -TimeSpan $elapsedSpan }
            catch { $elapsed = '?' }
        } else {
            $elapsed = '?'
        }

        $labelText = if ($Token.ContainsKey('Label') -and $Token.Label) { $Token.Label } else { 'Fetching Data' }
        $doneText  = "  |  |   [DONE] $labelText  [$elapsed]"

        if ($Token.ContainsKey('SpinnerCapable') -and $Token.SpinnerCapable) {
            # Stop and dispose the timer
            try { if ($Token.ContainsKey('Timer')    -and $Token.Timer)    { $Token.Timer.Stop()    } } catch {}
            try { if ($Token.ContainsKey('SourceId') -and $Token.SourceId) {
                    Unregister-Event -SourceIdentifier $Token.SourceId -ErrorAction SilentlyContinue } } catch {}
            try { if ($Token.ContainsKey('SourceId') -and $Token.SourceId) {
                    Remove-Event     -SourceIdentifier $Token.SourceId -ErrorAction SilentlyContinue } } catch {}
            try { if ($Token.ContainsKey('Timer')    -and $Token.Timer)    { $Token.Timer.Dispose() } } catch {}

            # Clear the spinner line then write DONE on a fresh line
            try {
                # PS 5.1-safe: no ternary - use if/else to get LastLen
                $lastLen = 0
                if ($Token.ContainsKey('LastLen')) { $lastLen = [int]$Token.LastLen }
                $clearLen = [Math]::Max(0, $lastLen + 2)
                [Console]::Write("`r" + (' ' * $clearLen) + "`r")
            } catch {}

        } else {
            # Finish the -NoNewline line from the last Update (or Start)
            Write-Host ''
        }

        Write-Host $doneText -ForegroundColor DarkGray
    }
}



function Update-FetchProgress {
    <#
    .SYNOPSIS
        Update the label text of an active fetch progress spinner.

    .DESCRIPTION
        Convenience wrapper for Write-FetchProgress -Update. Updates the spinner
        label text without stopping the spinner, allowing spokes to show progress
        through multiple data fetch steps.

    .PARAMETER Token
        The token hashtable returned by Write-FetchProgress -Start.

    .PARAMETER Label
        New descriptive text to display in the spinner.

    .EXAMPLE
        $token = Write-FetchProgress -Spoke 'Database' -Start

        Update-FetchProgress -Token $token -Label 'Step 1 - Enumerate Databases'
        $dbs = Get-DbaDatabase @sql

        Update-FetchProgress -Token $token -Label 'Step 2 - VLF Counts'
        $vlf = Measure-DbaDbVirtualLogFile @sql

        Write-FetchProgress -Token $token -End

    .NOTES
        Used by: All spokes (data fetch phase)

        Equivalent to: Write-FetchProgress -Token $token -Label 'new text' -Update
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [hashtable]$Token,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Label
    )

    Write-FetchProgress -Token $Token -Label $Label -Update
}

#endregion

# =============================================================================
#  8. Invoke Spoke with isolation
# =============================================================================
#region Fetch progress
function Invoke-Spoke {
    <#
    .SYNOPSIS
        Execute a spoke script with full isolation: catch any unhandled error,
        clean up orphaned fetch-progress resources, and always return a findings
        array regardless of what the spoke does.

    .DESCRIPTION
        Three guarantees:
          1. The engine never crashes due to a spoke error - the error is caught,
             logged, and converted into a synthetic 'fail' finding.
          2. Orphaned spinner timers / event subscriptions are always cleaned up
             via Initialize-FetchProgress in the finally block.
          3. The [ref] findings array is always in a consistent state on return -
             either populated by the spoke or containing only the synthetic finding.

    .PARAMETER SpokePath
        Full path to the spoke .ps1 file.

    .PARAMETER Target
        Target object passed through to the spoke (Contract D).

    .PARAMETER Config
        Config hashtable passed through to the spoke.

    .PARAMETER Findings
        [ref] to the findings ArrayList/array for this target. The spoke appends
        to this directly; the wrapper appends the synthetic finding on error.

    .OUTPUTS
        [bool] - $true if the spoke completed without error, $false if it threw.

    .NOTES
        Used by: Core.Checkup.ps1 (spoke dispatch loop)

        The synthetic finding uses category 'SpokeError' and status 'fail' so it
        is always visible in the report and counts toward the fail total.

        Initialize-FetchProgress is called in finally to guarantee timer cleanup
        even when the spoke crashes mid-fetch.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$SpokePath,

        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [object]$Target,

        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [hashtable]$Config,

        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [ref]$Findings
    )

    $spokeName = Split-Path -Leaf $SpokePath
    $success   = $true

    try {
        & $SpokePath -Target $Target -Config $Config -Findings $Findings
    }
    catch {
        $success      = $false
        $errorMessage = $_.Exception.Message
        $errorLine    = ''

        try {
            # InvocationInfo is not always present (e.g. engine-level terminating errors)
            if ($_.InvocationInfo -and $_.InvocationInfo.ScriptLineNumber) {
                $errorLine = " (line $($_.InvocationInfo.ScriptLineNumber))"
            }
        } catch {}

        Write-Host "  |   |   [ERR] Spoke error in $spokeName$errorLine`: $errorMessage" -ForegroundColor Red

        # Append a synthetic finding so the report reflects the failure
        try {
            $Findings.Value += [pscustomobject]@{
                label    = "$spokeName - Unhandled Error"
                status   = 'fail'
                category = 'SpokeError'
                priority = 'Critical'
                details  = "Spoke threw an unhandled exception$errorLine`: $errorMessage"
                source   = $spokeName
                spokeFile = $spokeName
            }
        } catch {}
    }
    finally {
        # Always clean up orphaned spinner resources regardless of success/failure.
        # This is safe to call even when no spinner was active.
        try { Initialize-FetchProgress } catch {}
    }

    return $success
}
#endregion