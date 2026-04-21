# Creating a Custom Spoke

This guide walks through every step required to add a new check pack (spoke) to the SQL Health Suite. By the end you will have a working spoke that is automatically discovered, run against every target, and rendered in the HTML report.

---

## How Spokes Fit the Architecture

The engine discovers all files matching `Spoke.*.ps1` in the `2. Spokes\` folder, sorts them alphabetically, and calls each one in turn for every target. A spoke is an isolated PowerShell script that receives a target, a config hashtable, and a reference to a findings list. It appends findings and exits — it never calls the engine back, never writes files, and never modifies SQL Server.

```
Start-Checkup.ps1
    └── Checkup.Engine.ps1
            └── Spoke.YourName.ps1   ← Your new file
                    └── New-Finding  → appended to $Findings [ref]
```

---

## Overview of Steps

1. Add a settings block to `Start-Checkup.ps1`
2. Add check metadata entries to `Checkup.Catalog.ps1`
3. Create `2. Spokes\Spoke.YourName.ps1`
4. *(Optional)* Create `3. Helpers\Helpers.YourName.ps1` for reusable logic
5. Validate the spoke runs cleanly

---

## Step 1 — Add Settings to Start-Checkup.ps1

Open `Start-Checkup.ps1` and add a new key inside the `$Settings` hashtable. Name the key to match your spoke (e.g. `Security`, `TempDB`). Every key you define here must be consumed inside the spoke — the config validation loop will emit a skip finding and abort if a key is missing.

```powershell
Security = @{
    Enabled = $true

    # Describe each setting inline so operators know what to tune
    RequireSaDisabled       = $true   # $true = flag if the 'sa' login is enabled
    RequireAuditSpec        = $true   # $true = flag instances with no server audit spec
    AllowedLinkedServers    = @()     # Linked server names that are expected / approved
}
```

**Rules:**
- Always include an `Enabled` key so the pack can be toggled without removing config.
- Boolean escalation flags (`XyzIsFail`) let operators choose between `attention` and `fail` without changing spoke code.
- Use `@()` for list-type values; the cast loop handles the array conversion.
- Document every key inline — settings are the only user-facing API for the spoke.

---

## Step 2 — Add Entries to Checkup.Catalog.ps1

The catalog decouples finding metadata (label, category, priority) from check logic. Add a new top-level hashtable for your spoke and one entry per check you plan to write.

```powershell
# ===========================================================================
# SECURITY SPOKE
# ===========================================================================
$global:CheckCat_Security = @{
    'Get-DbaLogin' = @{
        SaLoginStatus     = @{ Label = 'SA Login Status';            Category = 'Security';      Priority = 'High';   Source = 'Get-DbaLogin' }
    }

    'Get-DbaServerAuditSpecification' = @{
        AuditSpec         = @{ Label = 'Server Audit Specification';  Category = 'Compliance';    Priority = 'Medium'; Source = 'Get-DbaServerAuditSpecification' }
    }

    'Get-DbaLinkedServer' = @{
        LinkedServers     = @{ Label = 'Linked Server Inventory';     Category = 'Security';      Priority = 'Low';    Source = 'Get-DbaLinkedServer' }
        LinkedServerEntry = @{ Label = 'Linked Server - Entry';       Category = 'Security';      Priority = 'Low';    Source = 'Get-DbaLinkedServer' }
    }
}
```

### Catalog Conventions

| Rule | Detail |
|------|--------|
| Variable name | `$global:CheckCat_<SpokeName>` — must match the `$spoke` variable in your spoke file |
| Outer key | The dbatools function that produces the data for this group of checks |
| Inner key | A short PascalCase name — this is the `-Key` you pass to `Invoke-Check` |
| Rollup vs Entry | Rollup summarises all objects for a check (one per run). Entry is one finding per object. Name entry keys `<RollupKey>Entry` and append ` - Entry` to the label |
| Categories | `Availability`, `Compliance`, `Configuration`, `Maintenance`, `Performance`, `Recoverability`, `Reliability`, `Security` |
| Priorities | `High`, `Medium`, `Low` |

Higher category base weight + higher priority multiplier = higher report score impact. See the weight table at the bottom of this document.

---

## Step 3 — Create the Spoke File

Create `2. Spokes\Spoke.YourName.ps1`. The sections below describe each region in order. A complete minimal example is in `1. Documentation\Spoke template.ps1`.

### 3.1 Param Block (Contract A)

Every spoke must declare exactly these three parameters — no more, no less.

```powershell
#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)][object]   $Target,
    [Parameter(Mandatory)][hashtable]$Config,
    [Parameter(Mandatory)][ref]      $Findings
)
```

`$Target` — the current SQL Server instance (`.SqlInstance`, `.Description`, `.Credential`).  
`$Config` — all settings from `Start-Checkup.ps1`, keyed by pack name.  
`$Findings` — a by-reference list; append findings with `$Findings.Value +=`.

### 3.2 Bootstrap

```powershell
$root    = Split-Path -Parent $PSScriptRoot
$spoke   = 'Security'   # Must match $global:CheckCat_<this value>

. (Join-Path $root '3. Helpers\Helpers.Shared.ps1')
. (Join-Path $root 'Checkup.Catalog.ps1')
# Dot-source your own helpers file here if you created one:
# . (Join-Path $root '3. Helpers\Helpers.Security.ps1')

$global:__checkFile = Split-Path -Leaf $PSCommandPath
$sql = Get-SqlConnectionSplat -Target $Target
```

### 3.3 Pack-Enabled Guard

```powershell
$packEnabled = Cfg $Config 'Security.Enabled' -Default $true
if (-not [bool]$packEnabled) {
    $Findings.Value += New-Finding `
        -Label    'Security Pack (disabled)' `
        -Category 'Configuration' -Priority 'Low' -Status 'info' `
        -Details  'Security pack disabled by config (Security.Enabled = false).' `
        -Source   'Config' `
        -SpokeFile $spoke
    return
}
```

### 3.4 Config Key Validation

Declare every key your spoke reads. The cast loop below validates each one, casts it to the right type, and surfaces a skip finding if any key is absent — then aborts the spoke so checks never run against incomplete config.

```powershell
$configSpec = @{
    RequireSaDisabled    = @{ Type = [bool];   Var = 'requireSaDisabled' }
    RequireAuditSpec     = @{ Type = [bool];   Var = 'requireAuditSpec'  }
    AllowedLinkedServers = @{ Type = [array];  Var = 'allowedLinkedRaw'  }
}

foreach ($key in @($configSpec.Keys)) {
    $value = Cfg $Config "Security.$key"
    if ($value -is [MissingConfigKey]) {
        $Findings.Value += New-SkipFinding `
            -Key          "Security.$key" `
            -CheckLabel   "Security pack (missing: Security.$key)" `
            -SpokeFile    $spoke
        return
    }
    $spec = $configSpec[$key]
    if ($spec.Type -eq [array]) {
        Set-Variable -Name $spec.Var -Value @($value) -Scope Script
    } else {
        Set-Variable -Name $spec.Var -Value ($value -as $spec.Type) -Scope Script
    }
}
```

After the loop, apply any further normalization (lower-case lists, etc.):

```powershell
$allowedLinkedServers = @($allowedLinkedRaw | ForEach-Object { $_.ToLowerInvariant() })
```

### 3.5 Data Fetch

Fetch all the raw data you need upfront, before any check runs. This keeps check logic clean and avoids redundant queries.

```powershell
$pfToken = Write-FetchProgress -Spoke $spoke -Start

try {
    Update-FetchProgress -Token $pfToken -Label 'Logins'
    $logins = Invoke-DBATools { Get-DbaLogin @sql -EnableException }

    Update-FetchProgress -Token $pfToken -Label 'Audit specifications'
    $auditSpecs = Invoke-DBATools { Get-DbaServerAuditSpecification @sql -EnableException }

    Update-FetchProgress -Token $pfToken -Label 'Linked servers'
    $linkedServers = Invoke-DBATools { Get-DbaLinkedServer @sql -EnableException }

} catch {
    $Findings.Value += New-Finding `
        -Label    '[Security] Data Retrieval' `
        -Category 'Availability' -Priority 'High' -Status 'fail' `
        -Details  "Failed to retrieve security data: $($_.Exception.Message)" `
        -Source   'Get-DbaLogin' -SpokeFile $spoke
    return
} finally {
    Write-FetchProgress -Token $pfToken -End
}
```

`Invoke-DBATools` catches non-terminating dbatools errors and returns `$null` on failure, so individual failed cmdlets don't crash the whole spoke. A `$null` result is then handled inside each check block.

### 3.6 Check Execution

Each check uses `Invoke-Check`. The `-Run` scriptblock receives `($sql, $Target, $Config)` and must return a hashtable with `Status` and `Details`.

```powershell
# ── SA login status ─────────────────────────────────────────────────────────
Register-CheckSection -File $global:__checkFile -Number 1 `
    -Title 'SA Login' -Function 'Get-DbaLogin' -Key 'SaLoginStatus'

Invoke-Check `
    -CatalogName 'Security' `
    -Function    'Get-DbaLogin' `
    -Key         'SaLoginStatus' `
    -Target      $Target `
    -Config      $Config `
    -Findings    $Findings `
    -SpokeFile   $spoke `
    -Run {
        param($sql, $t, $cfg)

        if ($null -eq $logins) {
            return @{ Status = 'fail'; Details = 'Could not retrieve login list.' }
        }

        $sa = $logins | Where-Object { $_.Name -eq 'sa' -and $_.IsDisabled -eq $false }

        if ($requireSaDisabled -and $sa) {
            return @{ Status = 'fail'; Details = "The 'sa' login is enabled. Disable or rename it." }
        }

        return @{ Status = 'pass'; Details = "sa login is disabled or absent." }
    }
```

**Status values:** `pass`, `attention`, `fail`, `info`  
Use `attention` for best-practice deviations that don't rise to a failure, `info` for inventory findings that carry no weight.

### 3.7 Rollup and Entry Pattern

For checks that span multiple objects (databases, logins, jobs), emit one *entry* finding per problem object and one *rollup* finding summarizing the count. Create entry findings first so the rollup can reference the count, then create the rollup.

```powershell
# ── Linked server inventory ──────────────────────────────────────────────────
Register-CheckSection -File $global:__checkFile -Number 2 `
    -Title 'Linked Servers' -Function 'Get-DbaLinkedServer' -Key 'LinkedServers'

$unexpectedLinked = @()

if ($linkedServers) {
    foreach ($ls in $linkedServers) {
        $isApproved = $allowedLinkedServers -contains $ls.Name.ToLowerInvariant()
        if (-not $isApproved) {
            $unexpectedLinked += $ls.Name

            # Entry finding — one per unapproved linked server
            $entrySplat = $global:CheckCat_Security['Get-DbaLinkedServer']['LinkedServerEntry']
            $Findings.Value += New-Finding @entrySplat `
                -Status   'attention' `
                -Details  "Linked server '$($ls.Name)' is not in AllowedLinkedServers." `
                -SpokeFile $spoke
        }
    }
}

# Rollup finding — one per instance
$rollupSplat = $global:CheckCat_Security['Get-DbaLinkedServer']['LinkedServers']
if ($unexpectedLinked.Count -eq 0) {
    $Findings.Value += New-Finding @rollupSplat `
        -Status  'pass' `
        -Details "All $($linkedServers.Count) linked server(s) are in the approved list." `
        -SpokeFile $spoke
} else {
    $Findings.Value += New-Finding @rollupSplat `
        -Status  'attention' `
        -Details "$($unexpectedLinked.Count) unapproved linked server(s): $(($unexpectedLinked | Select-Object -First 5) -join ', ')." `
        -SpokeFile $spoke
}
```

When using the catalog splat with `@entrySplat`, Label, Category, Priority, and Source are all supplied automatically. Only Status, Details, and SpokeFile need to be added.

---

## Step 4 — Create a Helpers File (Optional)

If your spoke has significant data-shaping logic or functions shared across checks, extract them into `3. Helpers\Helpers.YourName.ps1`. Follow the naming convention of existing helpers files. Dot-source it in the bootstrap section of your spoke (see 3.2).

---

## Step 5 — Validate

Run the suite with your spoke enabled and a single test target:

```powershell
.\Start-Checkup.ps1
```

**Checklist:**
- The spoke name appears in the console output during the run.
- Your findings appear in the HTML report under the correct categories.
- Running with `Security.Enabled = $false` produces an informational finding and skips all checks.
- Removing a config key from `Start-Checkup.ps1` produces a skip finding rather than an error.
- No PowerShell errors appear in the run transcript (`4. Output\Run-Transcripts\`).

---

## Key Function Reference

### `Cfg` — Safe Config Access

```powershell
$value = Cfg $Config 'PackName.KeyName'
$value = Cfg $Config 'PackName.KeyName' -Default $true
```

Returns the value if present, a `[MissingConfigKey]` sentinel if absent, or the default if supplied. Use dot-notation for nested keys. Never access `$Config` directly.

---

### `New-Finding` — Create a Finding

```powershell
New-Finding `
    -Label    'SA Login Status' `   # Display name in the report
    -Category 'Security' `          # See weight table below
    -Priority 'High' `              # High / Medium / Low
    -Status   'fail' `              # pass / attention / fail / info
    -Details  'The sa login...' `   # One sentence shown in the report
    -Source   'Get-DbaLogin' `      # dbatools function that provided the data
    -SpokeFile $spoke
```

When calling with a catalog splat, Label/Category/Priority/Source are already populated:

```powershell
$Findings.Value += New-Finding @($global:CheckCat_Security['Get-DbaLogin']['SaLoginStatus']) `
    -Status 'fail' -Details '...' -SpokeFile $spoke
```

---

### `Invoke-Check` — Execute a Check with Isolation

```powershell
Invoke-Check `
    -CatalogName 'Security' `           # Must match $global:CheckCat_<this>
    -Function    'Get-DbaLogin' `       # Outer key in the catalog
    -Key         'SaLoginStatus' `      # Inner key in the catalog
    -Target      $Target `
    -Config      $Config `
    -Findings    $Findings `
    -SpokeFile   $spoke `
    -Run {
        param($sql, $t, $cfg)
        # ... check logic ...
        return @{ Status = 'pass'; Details = '...' }
    }
```

Any exception thrown inside `-Run` is caught: a synthetic `fail` finding is appended and the spoke continues with the next check.

---

### `Invoke-DBATools` — Safe dbatools Wrapper

```powershell
$result = Invoke-DBATools { Get-DbaLogin @sql -EnableException }
```

Returns `$null` on error rather than throwing, so a failed query doesn't abort the whole spoke. Always check for `$null` before using the result.

---

### `New-ThresholdStatus` — Map a Value to a Status

```powershell
$status = New-ThresholdStatus -Value 87 -PassMin 0 -AttentionMin 80 -HigherIsBetter $false
# Returns 'attention' (value is above the attention floor but below fail)
```

Useful for numeric thresholds like free space, identity capacity, or wait time.

---

### `Write-FetchProgress` / `Update-FetchProgress`

```powershell
$pfToken = Write-FetchProgress -Spoke $spoke -Start
Update-FetchProgress -Token $pfToken -Label 'Loading logins'
# ... fetch ...
Write-FetchProgress -Token $pfToken -End
```

Displays a live spinner in the console while data is being fetched. Always wrap in `try/finally` so `-End` is called even on error.

---

## Finding Weight Reference

Findings contribute to the instance health score based on category and priority.

| Category | Base Weight |
|---|---|
| Security | 18 |
| Reliability | 16 |
| Recoverability | 16 |
| Availability | 16 |
| Compliance | 14 |
| Performance | 12 |
| Maintenance | 10 |
| Configuration | 10 |

Priority multipliers: **High** ×1.20, **Medium** ×1.00, **Low** ×0.80. Final weight is clamped to [1, 30]. `info` findings always have weight 0.

---

## Common Mistakes

| Mistake | Fix |
|---|---|
| Accessing `$Config['Security']['Enabled']` directly | Use `Cfg $Config 'Security.Enabled'` |
| Returning a string from `-Run` | Return `@{ Status='pass'; Details='...' }` |
| Creating findings without the `SpokeFile` parameter | Always pass `-SpokeFile $spoke` |
| Fetching data inside `-Run` scriptblock | Fetch all data upfront before the check loop |
| Naming the catalog variable incorrectly | `$global:CheckCat_Security` must match the `$spoke` variable exactly |
| Forgetting `[array]` type for list config keys | The cast loop handles this — declare `Type = [array]` and it will wrap the value in `@()` |
| Entry findings created after rollup | Create entry findings first, then the rollup so the count is accurate |
