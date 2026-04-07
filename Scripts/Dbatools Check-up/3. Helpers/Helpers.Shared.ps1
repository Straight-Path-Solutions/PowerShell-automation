#Requires -Version 5.1
# =============================================================================
# Helpers\Helper.Shared.ps1  -  Spoke-facing primitives for the SQL Health Suite
# =============================================================================
#
# WHAT BELONGS HERE:
#   Only primitives that are genuinely shared across multiple spokes OR that
#   implement a contract defined in CONTRACTS.md (Contract B, C, E, G, H, I).
#
# WHAT DOES NOT BELONG HERE:
#   Pack-specific logic  -> Common.<PackName>.ps1
#   Engine orchestration -> Checkup.Engine.ps1 (Write-InstancesJson, Measure-Findings, etc.)
#
# READ-ONLY POSTURE:
#   Assert-ReadOnly lets spokes self-certify they make no writes.
#   The engine also enforces Config['ReadOnly'] = $true on every spoke invocation.
#
# LOADING:
#   Dot-source this file at the top of every spoke and helper.
#   The engine calls Publish-HealthSuiteFunctions after dot-sourcing to promote
#   all Common.*.ps1 functions into global scope for spoke runspaces.
#
# REGION MAP:
#   1.  Scoring constants          - category weights, priority multipliers
#   2.  Sentinel types             - MissingConfigKey class
#   3.  Status & scoring helpers   - Get-DefaultWeight, Test-Status, Status-FromPct, New-ThresholdStatus
#   4.  Finding factories          - New-Finding, New-Instance, New-InfoFinding, New-SkipFinding
#   5.  Config helpers             - Cfg, Ensure-ConfigKeys, Import-CheckCategory, ConvertTo-Hashtable
#   6.  Connection helpers         - Get-SqlConnectionSplat
#   7.  dbatools wrapper           - Invoke-DBATools
#   8.  Console output             - Format-TimeSpan, tree-output primitives
#   9.  Invoke-Check               - unified check runner (Contract B)
#   10. Section registry           - Register-CheckSection, Get-RegisteredCheckCount, etc.
#   11. Miscellaneous helpers      - First-NonEmpty, Summarize-Examples, Convert-ToGB, etc.
#   12. Bootstrap                  - Publish-HealthSuiteFunctions, Initialize-TreeOutput
# =============================================================================

# =============================================================================
#  1. SCORING CONSTANTS
# =============================================================================
#region Scoring constants

# Base weights per category.  Final weight = round(Base x PriorityMultiplier).
# See Contract C 4.1 for the full table.
$Global:WeightByCategory = @{
    'Security'       = 18
    'Reliability'    = 16
    'Recoverability' = 16
    'Availability'   = 16
    'Compliance'     = 14
    'Performance'    = 12
    'Maintenance'    = 10
    'Configuration'  = 10
    'Uncategorized'  = 10
}

$Global:PriorityMultiplier = @{
    'High'   = 1.20
    'Medium' = 1.00
    'Low'    = 0.80
}

#endregion

# =============================================================================
#  2. SENTINEL TYPES
# =============================================================================
#region Sentinel types

# Returned by Cfg when a key is absent and no -Default is supplied.
# Spokes check for this type to detect missing config early (Contract I).
class MissingConfigKey {
    [string]$Name
    MissingConfigKey([string]$Name) { $this.Name = $Name }
    [string] ToString() { return "MissingConfigKey:$($this.Name)" }
}

#endregion

# =============================================================================
#  3. STATUS & SCORING HELPERS
# =============================================================================
#region Status & scoring helpers

function Get-DefaultWeight {
    <#
    .SYNOPSIS
        Compute a finding weight from Category + Priority.
    
    .DESCRIPTION
        Weight = round(BaseWeight x PriorityMultiplier), clamped to [Min, Max].
        Uses global WeightByCategory and PriorityMultiplier tables by default.
        
        Used by: New-Finding
    
    .PARAMETER Category
        Finding category (Security, Reliability, etc.)
    
    .PARAMETER Priority
        Finding priority (High, Medium, Low)
    
    .EXAMPLE
        Get-DefaultWeight -Category 'Security' -Priority 'High'
        
        Output: 22 (18 * 1.20, rounded)
    
    .NOTES
        Contract: C 4.1 (Scoring)
        
        The Min/Max/RoundTo parameters exist for testing edge cases but should
        not be used in production code. Always use the defaults.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Category,
        [ValidateSet('High','Medium','Low')][string]$Priority = 'Medium',
        [hashtable]$CategoryMap = $Global:WeightByCategory,
        [hashtable]$PriorityMap = $Global:PriorityMultiplier,
        [int]$Min     = 1,
        [int]$Max     = 30,
        [int]$RoundTo = 1
    )
    
    $base = $CategoryMap[$Category]
    if ($null -eq $base) { $base = $CategoryMap['Uncategorized'] }
    
    $mult = $PriorityMap[$Priority]
    if ($null -eq $mult) { $mult = 1.0 }
    
    $w = [math]::Round($base * $mult / $RoundTo) * $RoundTo
    [int]([math]::Min($Max, [math]::Max($Min, $w)))
}

function New-ThresholdStatus {
    <#
    .SYNOPSIS
        Map a numeric value to pass/attention/fail given threshold boundaries.
    
    .DESCRIPTION
        Similar to Status-FromPct but for non-percentage values.
        Useful for absolute thresholds (MB, count, seconds, etc.).
        
        Used by: Backup, Performance spokes
    
    .PARAMETER Value
        The numeric value to evaluate
    
    .PARAMETER PassMin
        Minimum value for 'pass' status
    
    .PARAMETER AttentionMin
        Minimum value for 'attention' status
    
    .PARAMETER HigherIsBetter
        $true if higher values are better, $false if lower is better
    
    .EXAMPLE
        New-ThresholdStatus -Value 50 -PassMin 100 -AttentionMin 50 -HigherIsBetter $true
        
        Output: 'attention' (50 meets AttentionMin but not PassMin)
    
    .NOTES
        Contract: C (Scoring)
        
        This function uses the same directional logic as Status-FromPct.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][double]$Value,
        [Parameter(Mandatory)][double]$PassMin,
        [Parameter(Mandatory)][double]$AttentionMin,
        [bool]$HigherIsBetter = $true
    )
    
    if ($HigherIsBetter) {
        if ($Value -ge $PassMin)          { return 'pass'      }
        if ($Value -ge $AttentionMin)     { return 'attention' }
        return 'fail'
    } else {
        if ($Value -le $PassMin)          { return 'pass'      }
        if ($Value -le $AttentionMin)     { return 'attention' }
        return 'fail'
    }
}

#endregion

# =============================================================================
#  4. FINDING FACTORIES
# =============================================================================
#region Finding factories

function New-Instance {
    <#
    .SYNOPSIS
        Wrap a target's findings into the instance envelope for JSON serialization.
    
    .DESCRIPTION
        Creates the top-level instance object containing metadata and checks array.
        Used by Write-InstancesJson to build the final JSON structure.
        
        Used by: Checkup.Engine.ps1
    
    .PARAMETER Name
        Instance name (e.g., 'SERVER\INSTANCE')
    
    .PARAMETER Description
        Optional description or connection info
    
    .PARAMETER LastCheck
        Timestamp of the health check run
    
    .PARAMETER Checks
        Array of finding objects from New-Finding
    
    .EXAMPLE
        New-Instance -Name 'SQL01\PROD' -Checks $findings
        
        Output: PSCustomObject with name, description, lastCheck, checks
    
    .NOTES
        Contract: E (JSON Structure)
        
        The lastCheck field is serialized as ISO 8601 with 'Z' suffix for UTC.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$Description = '',
        [DateTime]$LastCheck = (Get-Date),
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Checks
    )
    
    [pscustomobject]@{
        name        = $Name
        description = $Description
        lastCheck   = $LastCheck.ToString('s') + 'Z'
        checks      = $Checks
    }
}

function New-Finding {
    <#
    .SYNOPSIS
        Create a finding object with normalized fields and computed weight.
    
    .DESCRIPTION
        This is the ONLY approved way to create a finding object.
        Handles field normalization, weight calculation, key generation,
        and comprehensive null/validation checks.
        
        Used by: All spokes (via Invoke-Check), New-InfoFinding, New-SkipFinding
    
    .PARAMETER Label
        Human-readable check name
    
    .PARAMETER Category
        Finding category (Security, Reliability, etc.)
    
    .PARAMETER Priority
        Finding priority (High, Medium, Low)
    
    .PARAMETER Status
        Check result (pass, attention, fail, info)
    
    .PARAMETER Details
        Detailed description or recommendation
    
    .PARAMETER WeightOverride
        Override automatic weight calculation (rare)
    
    .PARAMETER Source
        Data source for the finding (e.g., 'Get-DbaDatabase')
    
    .PARAMETER SpokeFile
        Name of the spoke file that generated this finding
    
    .EXAMPLE
        New-Finding -Label 'Backup Age' -Category 'Recoverability' -Priority 'High' `
                    -Status 'fail' -Details 'Last backup: 48h ago' -Source 'Get-DbaLastBackup'
    
    .NOTES
        Contract: B (Check Execution), C (Scoring)
        
        Weight calculation:
        - info findings always get weight=0
        - Others use Get-DefaultWeight (Category x Priority)
        - WeightOverride bypasses calculation (use sparingly)
        
        Key generation:
        - label "Backup Age" -> key "backup_age"
        - Used for deduplication and grouping in reports
        
        Null-safe and validates all inputs with meaningful defaults.
    #>
    [CmdletBinding()]
    param(
        [object]$Label    = 'Unnamed',
        [object]$Category = 'Uncategorized',
        [object]$Priority = 'Medium',
        [Parameter(Mandatory)][string]$Status,
        [object]$Details  = '',
        [int]$WeightOverride,
        [hashtable]$CategoryMap = $Global:WeightByCategory,
        [hashtable]$PriorityMap = $Global:PriorityMultiplier,
        [object]$Source,
        [string]$SpokeFile = ''
    )

    # Normalize input - accept strings or hashtables
    $labelStr   = if ($Label    -is [hashtable] -and $Label.ContainsKey('Label'))       { [string]$Label.Label       } else { [string]$Label    }
    $catStr     = if ($Category -is [hashtable] -and $Category.ContainsKey('Category')) { [string]$Category.Category } else { [string]$Category }
    $srcStr     = if ($Source   -is [hashtable] -and $Source.ContainsKey('Source'))     { [string]$Source.Source     } else { [string]$Source   }
    $detailsStr = if ($Details  -is [hashtable]) { [string]($Details | Out-String) }     else { [string]$Details }
    $prioStr    = if ($Priority -is [hashtable] -and $Priority.ContainsKey('Priority')) { [string]$Priority.Priority } else { [string]$Priority }

    # Defensive null handling with warnings
    if ($null -eq $labelStr -or [string]::IsNullOrWhiteSpace($labelStr)) {
        Write-Warning "New-Finding called with null/empty Label. Using 'Unnamed'."
        $labelStr = 'Unnamed'
    }
    
    if ($null -eq $catStr -or [string]::IsNullOrWhiteSpace($catStr)) {
        $catStr = 'Uncategorized'
    }
    
    if ($null -eq $Status -or [string]::IsNullOrWhiteSpace($Status)) {
        Write-Warning "New-Finding called with null/empty Status. Defaulting to 'attention'."
        $Status = 'attention'
        if ([string]::IsNullOrWhiteSpace($detailsStr)) {
            $detailsStr = "Check did not return a valid status."
        }
    }

    # Normalize and validate status early
    $st = ([string]$Status).Trim().ToLowerInvariant()
    $validStatuses = @('pass', 'attention', 'fail', 'info')
    
    if ($st -notin $validStatuses) {
        Write-Warning "Invalid status '$Status' provided to New-Finding. Defaulting to 'attention'."
        $originalStatus = $st
        $st = 'attention'
        if ([string]::IsNullOrWhiteSpace($detailsStr)) {
            $detailsStr = "Invalid status '$originalStatus' was provided for this check."
        } else {
            $detailsStr = "[Invalid status '$originalStatus' was returned] $detailsStr"
        }
    }
    
    # Info findings have no priority
    $effectivePriority = if ($st -eq 'info') { $null } else { $prioStr }

    # Calculate weight
    $weight = if ($PSBoundParameters.ContainsKey('WeightOverride')) {
        $WeightOverride
    } elseif ($st -eq 'info') {
        0
    } else {
        Get-DefaultWeight -Category $catStr -Priority $prioStr `
                          -CategoryMap $CategoryMap -PriorityMap $PriorityMap
    }

    # Generate key from label (safe for null/empty)
    $key = if ([string]::IsNullOrWhiteSpace($labelStr)) {
        'unnamed'
    } else {
        ($labelStr -replace '\s+', '_' -replace '[^\w\-]', '').ToLower()
    }

    [pscustomobject]@{
        label    = $labelStr
        key      = $key
        category = $catStr
        priority = $effectivePriority
        status   = $st
        details  = $detailsStr
        weight   = $weight
        source   = $srcStr
        spoke    = $SpokeFile
    }
}

function New-InfoFinding {
    <#
    .SYNOPSIS
        Create an informational finding (status=info, weight=0).
    
    .DESCRIPTION
        Convenience wrapper around New-Finding for informational checks.
        Info findings don't affect health score but provide useful context.
        
        Used by: Spokes that need to report non-actionable information
    
    .PARAMETER Label
        Human-readable check name
    
    .PARAMETER Category
        Finding category (defaults to Uncategorized)
    
    .PARAMETER Priority
        Finding priority (defaults to Low, ignored for info)
    
    .PARAMETER Details
        Information to display
    
    .PARAMETER Source
        Data source
    
    .PARAMETER SpokeFile
        Name of the spoke file
    
    .EXAMPLE
        New-InfoFinding -Label 'SQL Version' -Details 'SQL Server 2022 RTM' -Source 'Get-DbaInstanceProperty'
    
    .NOTES
        Contract: B (Check Execution)
        
        Info findings are useful for:
        - Configuration documentation
        - Version reporting
        - Environmental context
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Label,
        [object]$Category = 'Uncategorized',
        [ValidateSet('High','Medium','Low')][object]$Priority = 'Low',
        [object]$Details = '',
        [object]$Source,
        [string]$SpokeFile = ''
    )
    
    New-Finding -Label $Label -Category $Category -Priority $Priority `
                -Status 'info' -Details $Details -Source $Source -SpokeFile $SpokeFile
}

function New-SkipFinding {
    <#
    .SYNOPSIS
        Create a finding when a check is skipped due to missing configuration.
    
    .DESCRIPTION
        Generates an 'attention' finding explaining that a config key is missing.
        Helps users understand why checks didn't run.
        
        Used by: Spokes when required config is absent
    
    .PARAMETER Key
        The missing config key name
    
    .PARAMETER CheckLabel
        The check that was skipped
    
    .PARAMETER SpokeFile
        Name of the spoke file
    
    .EXAMPLE
        New-SkipFinding -Key 'MaxBackupAgeHours' -CheckLabel 'Backup Age Check'
    
    .NOTES
        Contract: I (Configuration)
        
        This is the graceful degradation pattern: instead of throwing,
        emit a finding that explains the missing config.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$CheckLabel,
        [string]$SpokeFile = ''
    )
    
    New-Finding `
        -Label    $CheckLabel `
        -Category 'Configuration' `
        -Priority 'Low' `
        -Status   'attention' `
        -Details  "Check skipped: required config key '$Key' is absent from Settings. Add it to Start-Checkup.ps1." `
        -Source   'Config' `
        -SpokeFile $SpokeFile
}

#endregion

# =============================================================================
#  5. CONFIG HELPERS
# =============================================================================
#region Config helpers

function Cfg {
    <#
    .SYNOPSIS
        Read a value from the Config hashtable using dot-notation.
    
    .DESCRIPTION
        Supports both flat keys ('MaxCpuPercent') and nested keys ('Agent.SkipOnExpress').
        Returns a MissingConfigKey sentinel when the key is absent and no -Default
        is supplied, enabling explicit missing-key handling.
        
        Used by: All spokes
    
    .PARAMETER Config
        The Config hashtable
    
    .PARAMETER Name
        The key name (supports dot-notation for nested keys)
    
    .PARAMETER Default
        Optional default value if key is absent
    
    .EXAMPLE
        $val = Cfg $Config 'Agent.SkipOnExpress'
        if ($val -is [MissingConfigKey]) {
            return New-SkipFinding -Key 'Agent.SkipOnExpress' -CheckLabel 'Agent Status'
        }
    
    .EXAMPLE
        $maxAge = Cfg $Config 'MaxBackupAgeHours' -Default 24
        # Returns 24 if key is absent
    
    .NOTES
        Contract: I (Configuration)
        
        ALWAYS prefer Cfg over direct hashtable access ($Config['x']['y']) in spokes.
        The sentinel pattern enables validation loops at spoke init.
        
        Duck-type fallback exists for environments where the MissingConfigKey class
        isn't loaded, but this should be rare in normal execution.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$Name,
        [object]$Default = $null
    )

    $hasDefault = $PSBoundParameters.ContainsKey('Default')

    # Direct key match
    if ($Config.ContainsKey($Name)) {
        return $Config[$Name]
    }

    # Dot-notation: 'Pack.Key' -> $Config['Pack']['Key']
    $parts = $Name -split '\.'
    if ($parts.Count -gt 1 -and $Config.ContainsKey($parts[0])) {
        $sub = $Config[$parts[0]]
        if ($sub -is [hashtable] -and $sub.ContainsKey($parts[1])) {
            return $sub[$parts[1]]
        }
    }

    # Return default if provided
    if ($hasDefault) {
        return $Default
    }

    # Return MissingConfigKey sentinel
    try {
        return [MissingConfigKey]::new($Name)
    } catch {
        # Duck-type fallback for rare cases where class isn't loaded
        return [pscustomobject]@{
            PSTypeName = 'MissingConfigKey'
            Name       = $Name
        }
    }
}

function Import-CheckCategory {
    <#
    .SYNOPSIS
        Return the $script:CheckCat_<Name> hashtable from CheckCatalog.ps1.
    
    .DESCRIPTION
        Lazily loads CheckCatalog.ps1 if not already in scope.
        Returns the catalog hashtable for the specified pack.
        
        Used by: Invoke-Check
    
    .PARAMETER Name
        The pack name (Agent, Backup, Security, etc.)
    
    .EXAMPLE
        $catalog = Import-CheckCategory -Name 'Agent'
        $entry = $catalog['Get-DbaService']['AgentRunning']
    
    .NOTES
        Contract: B (Check Execution)
        
        This function searches for CheckCatalog.ps1 in multiple locations to
        handle different execution contexts (direct invoke, dot-sourced, etc.).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name
    )

    $tryVarNames = @(
        "CheckCat_$Name",
        "CheckCat_$($Name.ToUpper())",
        "CheckCat_$($Name.ToLower())"
    )

    # Check if already loaded in current scope
    foreach ($vn in $tryVarNames) {
        foreach ($scope in 'Global', 'Script') {
            $v = Get-Variable -Name $vn -Scope $scope -ErrorAction SilentlyContinue
            if ($v -and $v.Value -is [hashtable]) {
                return $v.Value
            }
        }
    }

    # Attempt to dot-source CheckCatalog.ps1
    $helpersRoot = $PSScriptRoot
    $candidates = @(
        (Join-Path $helpersRoot 'CheckCatalog.ps1'),
        (Join-Path (Split-Path $helpersRoot -Parent) 'Helpers\CheckCatalog.ps1'),
        (Join-Path (Split-Path $helpersRoot -Parent) 'CheckCatalog.ps1')
    ) | Select-Object -Unique

    foreach ($p in $candidates) {
        if (Test-Path -LiteralPath $p) {
            . $p
            break
        }
    }

    # Re-check after sourcing
    foreach ($vn in $tryVarNames) {
        foreach ($scope in 'Global', 'Script') {
            $v = Get-Variable -Name $vn -Scope $scope -ErrorAction SilentlyContinue
            if ($v -and $v.Value -is [hashtable]) {
                return $v.Value
            }
        }
    }

    throw "Category '$Name' not defined in CheckCatalog.ps1. Ensure CheckCatalog.ps1 exists and contains `$script:CheckCat_$Name."
}

function ConvertTo-Hashtable {
    <#
    .SYNOPSIS
        Recursively convert a PSCustomObject to a hashtable.
    
    .DESCRIPTION
        Normalizes JSON-loaded settings (PSCustomObject) to hashtables.
        Handles nested objects and arrays recursively.
        
        Used by: Checkup.Engine.ps1 (settings.json loader)
    
    .PARAMETER InputObject
        The object to convert (PSCustomObject, array, or primitive)
    
    .EXAMPLE
        $settings = Get-Content settings.json | ConvertFrom-Json
        $config = ConvertTo-Hashtable -InputObject $settings
    
    .NOTES
        Contract: I (Configuration)
        
        This normalization ensures consistent hashtable-based config access
        throughout the suite, regardless of how settings were loaded.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$InputObject)
    
    # Null -> empty hashtable
    if ($null -eq $InputObject) {
        return @{}
    }
    
    # Already a hashtable -> return as-is
    if ($InputObject -is [hashtable]) {
        return $InputObject
    }
    
    # Array -> recursively convert elements
    if ($InputObject -is [System.Collections.IEnumerable] -and -not ($InputObject -is [string])) {
        $arr = @()
        foreach ($item in $InputObject) {
            $arr += (ConvertTo-Hashtable -InputObject $item)
        }
        return $arr
    }
    
    # PSCustomObject -> convert properties to hashtable
    if ($InputObject.PSObject -and $InputObject.PSObject.Properties.Count -gt 0) {
        $ht = @{}
        foreach ($p in $InputObject.PSObject.Properties) {
            $ht[$p.Name] = ConvertTo-Hashtable -InputObject $p.Value
        }
        return $ht
    }
    
    # Primitive -> return as-is
    return $InputObject
}

#endregion

# =============================================================================
#  6. CONNECTION HELPERS
# =============================================================================
#region Connection helpers

function Get-SqlConnectionSplat {
    <#
    .SYNOPSIS
        Build the dbatools connection splat from a Target object.
    
    .DESCRIPTION
        Creates the @{SqlInstance='...'; SqlCredential=$cred} hashtable for
        dbatools cmdlets. Call once at spoke init; reuse for all dbatools calls.
        
        Used by: All spokes, Invoke-Check
    
    .PARAMETER Target
        The Target object containing SqlInstance and optional Credential
    
    .EXAMPLE
        $sql = Get-SqlConnectionSplat -Target $Target
        $db = Get-DbaDatabase @sql
    
    .NOTES
        Contract: D (Target Structure)
        
        The splat pattern enables credential passthrough without exposing
        connection details in every dbatools call.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Target)
    
    $ht = @{ SqlInstance = $Target.SqlInstance }
    if ($Target.Credential) {
        $ht.SqlCredential = $Target.Credential
    }
    return $ht
}

#endregion

# =============================================================================
#  7. DBATOOLS WRAPPER  (Contract H)
# =============================================================================
#region Invoke-DBATools

function Invoke-DBATools {
    <#
    .SYNOPSIS
        Execute a dbatools scriptblock safely. Returns $null on any error.
    
    .DESCRIPTION
        ALL dbatools calls in spokes MUST be wrapped in Invoke-DBATools. This ensures
        consistent error handling and suppresses dbatools' verbose warnings.
        
        Used by: All spokes
    
    .PARAMETER Script
        The scriptblock containing dbatools cmdlet(s)
    
    .PARAMETER PassThruWarnings
        If set, allows dbatools warnings through (debugging only)
    
    .EXAMPLE
        $svc = Invoke-DBATools { Get-DbaService @sql -Type Agent -EnableException }
        if ($null -eq $svc) {
            return @{ Status='attention'; Details='Service not found.' }
        }
    
    .NOTES
        Contract: H (Error Handling)
        
        Rules:
        - Always pass -EnableException to the dbatools cmdlet inside the block
        - Always null-check the return value before use
        - A $null result must never produce a false 'pass'; handle explicitly
        - Use -PassThruWarnings only when debugging; dbatools is very chatty
        
        The caller decides what $null means for each check (missing data vs error).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][scriptblock]$Script,
        [switch]$PassThruWarnings
    )
    
    $prevWA = $WarningPreference
    try {
        if (-not $PassThruWarnings) {
            $WarningPreference = 'SilentlyContinue'
        }
        return (& $Script)
    } catch {
        return $null
    } finally {
        $WarningPreference = $prevWA
    }
}

#endregion

# =============================================================================
#  8. CONSOLE OUTPUT
# =============================================================================
#region Console output

function Format-TimeSpan {
    <#
    .SYNOPSIS
        Format a TimeSpan or seconds value as a human-readable string.
    
    .DESCRIPTION
        Unified time formatting function. Accepts either TimeSpan or double seconds.
        Replaces the deprecated Format-Duration and Format-Elapsed functions.
        
        Used by: Engine, Invoke-Check, tree output
    
    .PARAMETER TimeSpan
        A TimeSpan object to format
    
    .PARAMETER Seconds
        A numeric seconds value to format
    
    .EXAMPLE
        Format-TimeSpan -TimeSpan ([TimeSpan]::FromSeconds(125))
        Output: '2m 5.0s'
    
    .EXAMPLE
        Format-TimeSpan -Seconds 3725
        Output: '1h 2m 5.0s'
    
    .NOTES
        Formatting rules:
        - < 1s: milliseconds
        - < 60s: seconds with 2 decimal places
        - < 60m: minutes + seconds
        - >= 60m: hours + minutes + seconds
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ParameterSetName='TimeSpan')]
        [TimeSpan]$TimeSpan,
        
        [Parameter(Mandatory, ParameterSetName='Seconds')]
        [double]$Seconds
    )
    
    $elapsed = if ($PSCmdlet.ParameterSetName -eq 'Seconds') {
        [TimeSpan]::FromSeconds($Seconds)
    } else {
        $TimeSpan
    }
    
    if ($elapsed.TotalSeconds -lt 1) {
        return '{0:N0}ms' -f $elapsed.TotalMilliseconds
    }
    
    if ($elapsed.TotalSeconds -lt 60) {
        return '{0:N2}s' -f $elapsed.TotalSeconds
    }
    
    if ($elapsed.TotalSeconds -lt 3600) {
        $m = [int]$elapsed.TotalMinutes
        $s = $elapsed.TotalSeconds % 60
        return '{0}m {1:N1}s' -f $m, $s
    }
    
    $h = [int][math]::Floor($elapsed.TotalSeconds / 3600)
    $m = [int][math]::Floor(($elapsed.TotalSeconds % 3600) / 60)
    $s = $elapsed.TotalSeconds % 60
    return '{0}h {1}m {2:N1}s' -f $h, $m, $s
}

# Backward compatibility aliases
Set-Alias -Name Format-Duration -Value Format-TimeSpan -Scope Global -ErrorAction SilentlyContinue
Set-Alias -Name Format-Elapsed -Value Format-TimeSpan -Scope Global -ErrorAction SilentlyContinue

# =============================================================================
#  Tree-output primitives
# =============================================================================

# Initialize tree output state (safe under Set-StrictMode)
if (-not (Get-Variable -Name __TreeTimings -Scope Script -ErrorAction SilentlyContinue)) {
    $script:__TreeTimings = New-Object System.Collections.Generic.List[object]
}

if (-not (Get-Variable -Name __SectionKey -Scope Script -ErrorAction SilentlyContinue)) {
    $script:__SectionKey    = $null
    $script:__SectionPass   = 0
    $script:__SectionAttn   = 0
    $script:__SectionFail   = 0
    $script:__SectionInfo   = 0
    $script:__SectionStart  = $null
}

function Initialize-TreeOutput {
    <#
    .SYNOPSIS
        Initialize or reset tree output state for a new run.
    
    .DESCRIPTION
        Resets timing lists and section counters to prevent state leakage
        between runs. Called by the engine before each health check.
        
        Used by: Checkup.Engine.ps1
    
    .PARAMETER Reset
        If set, force reset even if already initialized
    
    .EXAMPLE
        Initialize-TreeOutput -Reset
    
    .NOTES
        This is critical for runspace isolation - tree state must be explicitly
        reset between runs to prevent timing data from accumulating.
    #>
    [CmdletBinding()]
    param([switch]$Reset)
    
    if ($Reset -or -not $script:__TreeTimings) {
        $script:__TreeTimings = New-Object System.Collections.Generic.List[object]
    }
    
    if ($Reset -or $null -eq $script:__SectionKey) {
        $script:__SectionKey   = $null
        $script:__SectionPass  = 0
        $script:__SectionAttn  = 0
        $script:__SectionFail  = 0
        $script:__SectionInfo  = 0
        $script:__SectionStart = $null
    }
}

function Get-HostWidth {
    <#
    .SYNOPSIS
        Get the console buffer width, with fallback for non-interactive hosts.
    #>
    [CmdletBinding()]
    param()
    
    try {
        return $Host.UI.RawUI.BufferSize.Width
    } catch {
        return 180
    }
}

function Get-TreePrefix {
    <#
    .SYNOPSIS
        Generate the tree-structure prefix for a given indentation level.
    
    .PARAMETER Level
        Indentation level (0=root, 1=first child, etc.)
    
    .PARAMETER Branch
        If set, use branch symbol (|--) instead of continuation (|  )
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$Level,
        [switch]$Branch
    )
    
    if ($Level -le 0) { return '' }
    
    $pipes = if ($Level -eq 1) { '' } else { '|  ' * ($Level - 1) }
    
    if ($Branch) {
        return $pipes + '|-- '
    }
    return $pipes + '   '
}

function Write-TreeLine {
    <#
    .SYNOPSIS
        Write a line with tree structure prefix and tag.
    
    .PARAMETER Level
        Indentation level
    
    .PARAMETER Text
        Line text
    
    .PARAMETER Tag
        Tag label (INF, WRN, ERR, CFG, SUM, CHK)
    
    .PARAMETER Branch
        If set, use branch symbol
    
    .EXAMPLE
        Write-TreeLine -Level 1 -Tag 'CHK' -Text 'Agent Running' -Branch
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$Level,
        [Parameter(Mandatory)][string]$Text,
        [ValidateSet('INF','WRN','ERR','CFG','SUM','CHK')][string]$Tag = 'INF',
        [switch]$Branch
    )
    
    $prefix = Get-TreePrefix -Level $Level -Branch:$Branch
    $line = if ($Tag) { "$prefix[$Tag] $Text" } else { "$prefix$Text" }
    Write-Host $line
}

function Write-TreeInlineStart {
    <#
    .SYNOPSIS
        Start an inline tree output (no newline).
    
    .DESCRIPTION
        Used for checks that update in-place with timing info.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$Level,
        [Parameter(Mandatory)][string]$Text
    )
    
    $prefix = Get-TreePrefix -Level $Level
    Write-Host ("$prefix[CHK] $Text") -NoNewline
}

function Write-TreeInlineEnd {
    <#
    .SYNOPSIS
        Complete an inline tree output with final text.
    
    .DESCRIPTION
        Overwrites the in-progress line with final status/timing.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$Level,
        [Parameter(Mandatory)][string]$FinalText
    )
    
    $prefix = Get-TreePrefix -Level $Level
    $width = Get-HostWidth
    $line = ("$prefix[CHK] $FinalText").PadRight([Math]::Max(20, $width - 1))
    Write-Host ("`r$line")
}

function Write-TimingSummary {
    <#
    .SYNOPSIS
        Print the N slowest checks from $script:__TreeTimings.
    
    .DESCRIPTION
        Only meaningful when tree output is enabled. Entries are populated by
        Invoke-Check adding to $script:__TreeTimings on each check execution.
        
        Used by: Checkup.Engine.ps1 (at end of run)
    
    .PARAMETER Top
        Number of slow checks to display (default 15)
    
    .EXAMPLE
        Write-TimingSummary -Top 10
    
    .NOTES
        Helps identify performance bottlenecks across all checks.
    #>
    [CmdletBinding()]
    param([int]$Top = 15)
    
    if (-not $script:__TreeTimings -or $script:__TreeTimings.Count -eq 0) {
        return
    }

    Write-TreeLine -Level 0 -Tag 'SUM' -Text "Timing Summary (Top $Top slow checks)"
    
    $script:__TreeTimings |
        Sort-Object Ms -Descending |
        Select-Object -First $Top |
        ForEach-Object {
            Write-TreeLine -Level 1 -Tag 'SUM' -Text (
                '{0} / {1} / {2}  {3}  [{4}]' -f
                $_.Target, $_.Spoke, $_.Check,
                $_.Status.ToUpperInvariant(),
                (Format-TimeSpan -TimeSpan $_.Elapsed)
            )
        }
}

#endregion

# =============================================================================
#  9. INVOKE-CHECK  (Contract B)
# =============================================================================
#region Invoke-Check

function Extract-CheckResult {
    <#
    .SYNOPSIS
        Extract and validate Status/Details from a check's return value.
    
    .DESCRIPTION
        Handles both hashtables and PSCustomObjects. Validates structure and
        provides meaningful defaults when fields are missing.
        
        Used by: Invoke-Check
    
    .PARAMETER Result
        The return value from a check scriptblock
    
    .EXAMPLE
        $extracted = Extract-CheckResult -Result $checkReturnValue
        $status = $extracted.Status
        $details = $extracted.Details
    
    .NOTES
        This function handles the complexity of PowerShell's dual access
        patterns (hashtable indexer vs property access) in one place.
    #>
    [CmdletBinding()]
    param($Result)
    
    # Null result -> attention status with message
    if ($null -eq $Result) {
        return @{
            Status  = 'attention'
            Details = 'Check returned null.'
        }
    }
    
    $status = $null
    $details = $null
    
    # Try hashtable access first
    if ($Result -is [hashtable]) {
        $status = $Result['Status']
        $details = $Result['Details']
    }
    # Then try property access (PSCustomObject)
    elseif ($Result.PSObject -and $Result.PSObject.Properties) {
        $prop = $Result.PSObject.Properties | Where-Object { $_.Name -eq 'Status' } | Select-Object -First 1
        if ($prop) { $status = $prop.Value }
        
        $prop = $Result.PSObject.Properties | Where-Object { $_.Name -eq 'Details' } | Select-Object -First 1
        if ($prop) { $details = $prop.Value }
    }
    
    # Validate status field
    if (-not $status) {
        return @{
            Status  = 'attention'
            Details = "Check did not return a Status field. Returned: $($Result.GetType().Name)"
        }
    }
    
    return @{
        Status  = [string]$status
        Details = if ($details) { [string]$details } else { '' }
    }
}


function Invoke-Check {
    <#
    .SYNOPSIS
        Execute a single check scriptblock and append the result as a finding.
        Failure-tolerant: any error in the -Run block produces a synthetic
        'fail' finding rather than propagating to the spoke or engine.

    .DESCRIPTION
        Invoke-Check is the single choke point for all check logic. Every check
        in every spoke runs through here. This makes it the right place to enforce:
          - Consistent finding shape (via New-Finding)
          - Consistent error handling (try/catch around -Run)
          - Catalog-driven label/category/priority lookup

        Error isolation contract:
          If -Run throws, Invoke-Check catches the error, emits a finding with:
            status   = 'fail'
            label    = '<CatalogName>/<Key> - Check Error'
            details  = the exception message + script line if available
          and returns normally. The spoke continues to the next check.

    .PARAMETER SpokeFile
        Short name of the calling spoke, e.g. 'Database'. Used in the finding's
        spokeFile property and in error messages.

    .PARAMETER CatalogName
        Top-level key in $global:CheckCat_* for label/category/priority lookup.

    .PARAMETER Function
        Second-level key (dbatools function name) in the catalog.

    .PARAMETER Key
        Third-level key (check identifier) in the catalog.

    .PARAMETER Target
        Target object (Contract D). Passed to -Run as $t.

    .PARAMETER Config
        Full config hashtable. Passed to -Run as $cfg.

    .PARAMETER Findings
        [ref] to the spoke's findings collection. Invoke-Check appends to this.

    .PARAMETER Run
        The check scriptblock. Must accept param($sql, $t, $cfg) and return a
        hashtable with at minimum a 'Status' key. 'Details' is optional.

    .NOTES
        Used by: All spokes (every individual check region)

        The -Run scriptblock runs in the spoke's scope so it can see all spoke-
        level variables ($dbs, $vlf, etc.) without being passed explicitly.
        This is by design (Contract A).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$SpokeFile,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$CatalogName,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Function,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Key,

        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [object]$Target,

        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [hashtable]$Config,

        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [ref]$Findings,

        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [scriptblock]$Run
    )

    # -- Catalog lookup --------------------------------------------------------
    # Resolve the catalog global by convention: $global:CheckCat_<CatalogName>
    $catalogVar  = "CheckCat_$CatalogName"
    $catalog     = Get-Variable -Name $catalogVar -Scope Global -ValueOnly -ErrorAction SilentlyContinue

    $label    = "$CatalogName/$Key"
    $category = 'General'
    $priority = 'Medium'

    if ($catalog -and
        $catalog.ContainsKey($Function) -and
        $catalog[$Function].ContainsKey($Key)) {
        $entry = $catalog[$Function][$Key]
        if ($entry.ContainsKey('Label'))    { $label    = $entry.Label    }
        if ($entry.ContainsKey('Category')) { $category = $entry.Category }
        if ($entry.ContainsKey('Priority')) { $priority = $entry.Priority }
    }

    # -- SQL connection splat --------------------------------------------------
    $sql = Get-SqlConnectionSplat -Target $Target

    # -- Run the check - fully isolated ---------------------------------------
    $result = $null
    try {
        $result = & $Run $sql $Target $Config
    }
    catch {
        $errorMessage = $_.Exception.Message
        $errorLine    = ''
        try {
            if ($_.InvocationInfo -and $_.InvocationInfo.ScriptLineNumber) {
                $errorLine = " (line $($_.InvocationInfo.ScriptLineNumber))"
            }
        } catch {}

        Write-Host "    [CHECK ERR] $label$errorLine`: $errorMessage" -ForegroundColor DarkRed

        $Findings.Value += New-Finding `
            -Label    "$spokeName - Unhandled Error" `
            -Category 'Uncategorized' `
            -Priority 'High' `
            -Status   'fail' `
            -Details  "Spoke threw an unhandled exception$errorLine`: $errorMessage" `
            -Source   $spokeName `
            -SpokeFile $spokeName

        return   # <-- spoke continues to the next check
    }

    # -- Normalise result ------------------------------------------------------
    if ($null -eq $result) {
        # -Run returned nothing - treat as a non-finding info result
        $result = @{ Status = 'info'; Details = 'Check returned no result.' }
    }

    $extracted = Extract-CheckResult -Result $result
    $status    = $extracted.Status.Trim().ToLowerInvariant()
    $details   = $extracted.Details

    if ($status -notin @('pass', 'attention', 'fail', 'info')) { $status = 'info' }

    # -- Append the finding ----------------------------------------------------
    $Findings.Value += New-Finding `
        -Label     $label `
        -Category  $category `
        -Priority  $priority `
        -Status    $status `
        -Details   $details `
        -Source    $Function `
        -SpokeFile $SpokeFile
}

#endregion

# =============================================================================
#  10. SECTION REGISTRY  (Contract G)
# =============================================================================
#region Section registry

# Per-spoke section counter - initialize as ConcurrentDictionary for thread safety
if (-not (Get-Variable -Name __sectionRegistry -Scope Script -ErrorAction SilentlyContinue)) {
    $script:__sectionRegistry = [System.Collections.Concurrent.ConcurrentDictionary[string,object]]::new()
}

function Reset-RegisteredChecks {
    <#
    .SYNOPSIS
        Reset the section registry for a given spoke file.
    
    .DESCRIPTION
        Called by the engine before each spoke run to clear previous state.
        
        Used by: Checkup.Engine.ps1
    
    .PARAMETER File
        The spoke file name
    
    .EXAMPLE
        Reset-RegisteredChecks -File 'Spoke.Agent.ps1'
    
    .NOTES
        Contract: G (Section Registration)
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$File)
    
    try {
        # For ConcurrentDictionary, we need to remove the key entirely or replace with new dictionary
        if ($script:__sectionRegistry -is [System.Collections.Concurrent.ConcurrentDictionary[string,object]]) {
            # Remove the file entry
            [void]$script:__sectionRegistry.TryRemove($File, [ref]$null)
        } else {
            # Fallback for regular hashtable (shouldn't happen, but defensive)
            $script:__sectionRegistry[$File] = @{}
        }
    } catch {
        Write-Warning "Failed to reset registered checks for $File`: $_"
    }
}

function Register-CheckSection {
    <#
    .SYNOPSIS
        Declare a check section within a spoke.
    
    .DESCRIPTION
        Call immediately before the Invoke-Check block it describes.
        -Number must be unique and ascending within the spoke file.
        Thread-safe implementation using ConcurrentDictionary.
        
        Used by: All spokes
    
    .PARAMETER File
        The spoke file name
    
    .PARAMETER Number
        Unique section number (ascending order)
    
    .PARAMETER Title
        Human-readable section title
    
    .PARAMETER Function
        dbatools function or logical grouping
    
    .PARAMETER Key
        Check key
    
    .EXAMPLE
        Register-CheckSection -File 'Spoke.Agent.ps1' -Number 1 `
                              -Title 'Agent Service Status' `
                              -Function 'Get-DbaService' -Key 'AgentRunning'
    
    .NOTES
        Contract: G (Section Registration)
        
        The engine uses this to generate the "X checks: Y findings" summary.
        Thread-safe for potential future parallel execution.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$File,
        [Parameter(Mandatory)][int]$Number,
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Function,
        [string]$Key
    )
    
    try {
        # Ensure registry is initialized
        if (-not $script:__sectionRegistry) {
            $script:__sectionRegistry = [System.Collections.Concurrent.ConcurrentDictionary[string,object]]::new()
        }
        
        # Get or create the per-file registry (also a ConcurrentDictionary)
        $newInner = [System.Collections.Concurrent.ConcurrentDictionary[int,object]]::new()
        $fileRegistry = $script:__sectionRegistry.GetOrAdd($File, $newInner)

        $fileRegistry[$Number] = @{
            Title    = $Title
            Function = $Function
            Key      = $Key
        }
    } catch {
        Write-Warning "Failed to register check section: $_"
    }
}

function Get-RegisteredCheckCount {
    <#
    .SYNOPSIS
        Get the number of registered checks for a spoke file.
    
    .PARAMETER File
        The spoke file name
    
    .EXAMPLE
        $count = Get-RegisteredCheckCount -File 'Spoke.Agent.ps1'
    
    .NOTES
        Contract: G (Section Registration)
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$File)
    
    try {
        if (-not $script:__sectionRegistry) {
            return 0
        }
        
        $fileRegistry = $null
        if ($script:__sectionRegistry.TryGetValue($File, [ref]$fileRegistry)) {
            if ($fileRegistry) {
                return $fileRegistry.Count
            }
        }
        return 0
    } catch {
        return 0
    }
}

function Get-RegisteredChecks {
    <#
    .SYNOPSIS
        Get all registered checks for a spoke file.
    
    .PARAMETER File
        The spoke file name
    
    .EXAMPLE
        $checks = Get-RegisteredChecks -File 'Spoke.Agent.ps1'
    
    .NOTES
        Contract: G (Section Registration)
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$File)
    
    try {
        if (-not $script:__sectionRegistry) {
            return @()
        }
        
        $fileRegistry = $null
        if ($script:__sectionRegistry.TryGetValue($File, [ref]$fileRegistry)) {
            if ($fileRegistry) {
                return , @($fileRegistry.Values)
            }
        }
        return @()
    } catch {
        return @()
    }
}

#endregion

# =============================================================================
#  11. MISCELLANEOUS HELPERS
# =============================================================================
#region Miscellaneous helpers

function First-NonEmpty {
    <#
    .SYNOPSIS
        Return the first non-null, non-empty value from a list.
    
    .DESCRIPTION
        Useful when a dbatools object may expose the same data under different
        property names across versions or editions.
        
        Used by: Various spokes
    
    .PARAMETER Values
        Array of values to search
    
    .EXAMPLE
        $val = First-NonEmpty -Values @($obj.Name, $obj.DisplayName, 'Unknown')
    
    .NOTES
        Returns $null if all values are null or empty strings.
    #>
    [CmdletBinding()]
    param([object[]]$Values = @())
    
    if ($null -eq $Values) { return $null }
    
    # Unwrap single collection into array
    if ($Values.Count -eq 1 -and $Values[0] -is [System.Collections.IEnumerable] -and -not ($Values[0] -is [string])) {
        $Values = @($Values[0])
    }
    
    foreach ($v in $Values) {
        if ($null -ne $v) {
            $s = [string]$v
            if ($s.Length -gt 0) {
                return $v
            }
        }
    }
    
    return $null
}

function Summarize-Examples {
    <#
    .SYNOPSIS
        Join up to $Max items as semicolon-delimited string, truncating with '...'.
    
    .DESCRIPTION
        Used to generate compact example lists in finding details.
        
        Used by: Security, Backup spokes
    
    .PARAMETER Items
        Array of items to summarize
    
    .PARAMETER Max
        Maximum items to include (default 5)
    
    .EXAMPLE
        Summarize-Examples -Items @('db1','db2','db3','db4','db5','db6') -Max 3
        Output: 'db1; db2; db3...'
    #>
    [CmdletBinding()]
    param(
        [object[]]$Items,
        [int]$Max = 5
    )
    
    $arr = @($Items)
    if ($arr.Count -le $Max) {
        return ($arr -join '; ')
    }
    
    return (($arr | Select-Object -First $Max) -join '; ') + '...'
}

function Convert-ToGB {
    <#
    .SYNOPSIS
        Convert bytes to GB, rounded to 2 decimal places.
    
    .PARAMETER bytes
        The byte count
    
    .EXAMPLE
        Convert-ToGB -bytes 5368709120
        Output: 5.00
    
    .NOTES
        Uses 1GB = 1073741824 bytes (binary, not decimal).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][long]$bytes)
    
    return [math]::Round($bytes / 1GB, 2)
}

function Get-Milliseconds {
    <#
    .SYNOPSIS
        Extract a numeric millisecond value from a number or string like "123.45 ms".
    
    .DESCRIPTION
        Used to normalize timing values from dbatools output.
        
        Used by: Performance spokes
    
    .PARAMETER v
        The value to parse (number or string)
    
    .EXAMPLE
        Get-Milliseconds -v "45.67 ms"
        Output: 45.67
    #>
    [CmdletBinding()]
    param($v)
    
    if ($v -is [double] -or $v -is [int]) {
        return [double]$v
    }
    
    $num = ($v.ToString() -replace '[^\d\.]', '')
    if ([string]::IsNullOrWhiteSpace($num)) {
        return $null
    }
    
    return [double]$num
}

function Get-SpCfgVal {
    <#
    .SYNOPSIS
        Safe sp_configure lookup from $__spIdx hashtable.
    
    .DESCRIPTION
        Returns a hashtable with RunningValue, IsRunningDefaultValue, and metadata.
        Returns $null if the config option doesn't exist.
        
        Used by: Configuration spokes
    
    .PARAMETER name
        The sp_configure option name
    
    .EXAMPLE
        $maxdop = Get-SpCfgVal -name 'max degree of parallelism'
        if ($maxdop) {
            $currentValue = $maxdop.RunningValue
        }
    
    .NOTES
        This function expects $__spIdx to be populated by the spoke before calling.
        Typically: $__spIdx = Get-DbaSpConfigure @sql | Group-Object -AsHashTable -Property ConfigName
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$name)
    
    $r = $__spIdx[$name]
    if ($null -eq $r) { return $null }
    
    if (-not $r.PSObject.Properties['RunningValue']) {
        return $null
    }

    $isDefault = $null
    if ($r.PSObject.Properties['IsRunningDefaultValue']) {
        $isDefault = [bool]$r.IsRunningDefaultValue
    }

    return @{
        RunningValue          = $r.RunningValue
        IsRunningDefaultValue = $isDefault
        ConfiguredValue       = if ($r.PSObject.Properties['ConfiguredValue']) { $r.ConfiguredValue } else { $null }
        DefaultValue          = if ($r.PSObject.Properties['DefaultValue'])    { $r.DefaultValue }    else { $null }
        DisplayName           = if ($r.PSObject.Properties['DisplayName'])     { $r.DisplayName }     else { $name }
        Description           = if ($r.PSObject.Properties['Description'])     { $r.Description }     else { '' }
    }
}

#endregion

# =============================================================================
#  12. BOOTSTRAP
# =============================================================================
#region Bootstrap

function Publish-HealthSuiteFunctions {
    <#
    .SYNOPSIS
        Promote all Common.*.ps1 functions into global scope.
    
    .DESCRIPTION
        Called once by Core.Checkup.ps1 after dot-sourcing all helpers.
        Ensures spoke runspaces have access to pack helpers even if they
        only dot-source Helper.Shared.ps1.
        
        Used by: Checkup.Engine.ps1
    
    .EXAMPLE
        Publish-HealthSuiteFunctions
    
    .NOTES
        This is necessary because PowerShell runspaces don't inherit script
        scope from the parent runspace. By promoting to global scope, we ensure
        all helpers are available in spoke scriptblocks.
    #>
    [CmdletBinding()]
    param()
    
    $names = Get-Command -CommandType Function |
        Where-Object {
            $_.ScriptBlock -and
            $_.ScriptBlock.File -and
            ($_.ScriptBlock.File -match '[\\/]+Helpers[\\/]+Common\..*\.ps1$')
        } |
        Select-Object -ExpandProperty Name -Unique

    foreach ($n in $names) {
        if (Get-Command -Name $n -ErrorAction SilentlyContinue) {
            Set-Item ("Function:\global:$n") (Get-Item "Function:\$n").ScriptBlock `
                -Force -ErrorAction SilentlyContinue
        }
    }
}

#endregion