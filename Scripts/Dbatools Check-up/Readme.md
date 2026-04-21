# SQL Health Suite — dbatools Powered Healthcheck

A read-only SQL Server health check suite built on [dbatools](https://dbatools.io). It discovers, evaluates, and reports on your SQL Server instances across a wide range of categories — producing a fully self-contained HTML report with no external dependencies.

> **This project is actively evolving.** Four spokes are now available: Database, Host, Instance, and Maintenance. Additional spokes are being released incrementally — check back for updates or watch the repo.

---

## Table of Contents

- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Architecture](#architecture)
- [Configuration](#configuration)
  - [Targets](#targets)
  - [Settings & Thresholds](#settings--thresholds)
- [What Gets Checked](#what-gets-checked)
- [The Report](#the-report)
- [Operational Modes](#operational-modes)
- [Credential Options](#credential-options)
- [FAQ](#faq)
- [Contributing & Bugs](#contributing--bugs)

---

## Prerequisites

| Requirement | Minimum Version | Notes |
|---|---|---|
| PowerShell | 5.1 | Windows PowerShell or PowerShell 7+ |
| dbatools | 2.7.25 | `Install-Module dbatools` |

No other dependencies. No SQL agent jobs. No schema changes. This suite is **read-only by design** — it will never modify your SQL Server configuration.

Install dbatools if you haven't already:

```powershell
Install-Module dbatools -Scope CurrentUser
```

---

## Quick Start

```powershell
# 1. Clone the repo
git clone https://github.com/<your-repo>/sql-health-suite.git
cd sql-health-suite

# 2. Generate example configuration files
.\Start-Checkup.ps1 -GenerateExampleTargets

# 3. Edit targets.json to point at your SQL Server instances
#    (see the Targets section below)

# 4. Run the suite
.\Start-Checkup.ps1

# The HTML report will open automatically when complete.
# Reports are saved to: .\4. Output\Reports\
```

---

## Architecture

The suite follows a **hub-and-spoke** model with four layers:

```
Start-Checkup.ps1        (Menu)     → You configure everything here
    └── Checkup.Engine.ps1          → Orchestrator; runs targets × spokes
            └── Spoke.*.ps1         → Individual check packs (one per domain)
                    └── JSON + HTML → Findings_<timestamp>.json → Report_<timestamp>.html
```

- **`Start-Checkup.ps1`** — The single entry point. All thresholds, toggles, and paths live here. Nothing is buried elsewhere.
- **`Checkup.Engine.ps1`** — The orchestrator. Loads targets, discovers spokes, runs each check pack, and produces output. Contains zero check logic.
- **`Spoke.*.ps1`** — Self-contained check packs, one per domain. Each spoke receives a target, config, and findings list — nothing else.
- **`Checkup.Catalog.ps1`** — Central catalog for check metadata (label, category, priority). Edit this to customize how checks appear in the report without touching spoke logic.
- **`4. Output\`** — All output lands here: JSON findings, HTML reports, transcripts.

---

## Configuration

### Targets

Edit `targets.json` in the repo root to define your SQL Server instances:

```json
[
    {
        "ComputerName": "localhost",
        "InstanceName": "mssqlserver",
        "Description": "Local Default Instance",
        "CredKey": null
    },
    {
        "ComputerName": "sqlprod01",
        "InstanceName": "mssqlserver",
        "Description": "Production Primary",
        "CredKey": "prod"
    },
    {
        "ComputerName": "sqlprod01",
        "InstanceName": "reporting",
        "Description": "Named Instance",
        "CredKey": null
    }
]
```

| Field | Required | Notes |
|---|---|---|
| `ComputerName` | Yes | Hostname or IP of the SQL Server host |
| `InstanceName` | Yes | Use `mssqlserver` for the default instance |
| `Description` | No | Friendly label shown in the report |
| `CredKey` | No | Credential key for SQL auth; `null` = Windows integrated auth |

### Settings & Thresholds

**All configuration lives in `Start-Checkup.ps1`** inside the `$Settings` hashtable. There are no hidden config files or registry keys. Every threshold is documented inline.

Key settings for the **Database** check pack:

```powershell
Database = @{
    Enabled                   = $true

    # Scope
    IncludeSystem             = $true       # Include system databases
    ExcludeDatabases          = @()         # Glob patterns to exclude, e.g. @('ReportServer*')

    # Backup recency (hours)
    MinBackupFullHours        = 168         # Full backup alert threshold (7 days)
    MinBackupDiffHours        = 24          # Differential backup alert threshold
    MinBackupLogHours         = 2           # Log backup alert threshold

    # VLF count
    VlfCountWarn              = 150
    VlfCountFail              = 300

    # Free space
    FreeSpacePctAttention     = 15.0        # Percent free before Attention
    FreeSpacePctFail          = 5.0         # Percent free before Fail

    # Anti-patterns (set $true to escalate to Fail)
    RequireAutoShrinkOff      = $true
    RequireAutoCloseOff       = $true
    RequirePageVerifyChecksum = $true

    # Security
    RequireTrustworthyOff     = $true
    TrustworthyAllowList      = @('msdb')   # Expected TRUSTWORTHY ON exceptions
    RequireTde                = $false       # $false = inventory only

    # ...and more — see Start-Checkup.ps1 for the full list
}
```

Key settings for the **Host** check pack:

```powershell
Host = @{
    Enabled                        = $true

    PowerPlanName                  = ''      # '' = accept Test-DbaPowerPlan recommendation
    PowerPlanNonCompliantIsFail    = $true

    PendingRebootIsFail            = $false  # $true → fail; $false → attention

    RequireDomainMember            = $true   # $false = skip domain check
    DomainNonMemberIsFail          = $false

    MinOsBuild                     = 0       # 0 = disabled; 2019 = 17763; 2022 = 20348
    OsBuildNonCompliantIsFail      = $false

    WarnIfVirtualMachine           = $false  # $true → attention when VM detected

    RequireLpim                    = $false  # Lock Pages In Memory
    LpimNonCompliantIsFail         = $false

    RequireIfi                     = $true   # Instant File Initialization
    IfiNonCompliantIsFail          = $false
}
```

Key settings for the **Instance** check pack:

```powershell
Instance = @{
    Enabled                   = $true

    MinCostThreshold          = 50      # Flag if Cost Threshold for Parallelism is below this
    RequireOptimizeForAdHoc   = $true
    RequireRemoteDAC          = $true
    RequireAdHocDistQOff      = $true
    RequireOleAutomationOff   = $true
    AllowCLR                  = $false
    RequireBackupCompression  = $true
    AllowContainedDbAuth      = $false

    CheckInstanceFillFactor   = $true
    ExpectedFillFactor        = 100     # 0 and 100 are treated as equivalent defaults

    ErrorLogScanDays          = 7       # Days back to scan for Sev 17+ errors
    ErrorLogExclusions        = @(...)  # Strings to suppress from error log findings

    CheckStartupParams        = $true   # Requires WMI / PS Remoting

    BuildMode                 = 'Latest'   # 'Latest' | 'MaxBehind' | 'MinimumBuild'
    BuildMaxBehind            = 1
    BuildMinimum              = $null      # e.g. '15.0.4153.1'
}
```

Key settings for the **Maintenance** check pack:

```powershell
Maintenance = @{
    Enabled                   = $true

    IncludeSystemDatabases    = $false

    CheckDuplicateIndexes     = $true
    CheckUnusedIndexes        = $true
    UnusedIndexIgnoreUptime   = $false  # $true = bypass 7-day uptime guard
    CheckDisabledIndexes      = $true

    CheckStatsStaleness       = $true
    StatsStaleDays            = 7

    CheckWaitStats            = $true
    WaitStatsThreshold        = 100     # Min WaitSeconds for a wait type to appear
    WaitStatsTopN             = 10      # Number of top waits to surface

    CheckLastGoodCheckDb      = $true
    CheckDbMaxDays            = 7

    IdentityUsageWarnPercent  = 80
    IdentityUsageFailPercent  = 95

    CheckErrorLogConfig       = $true
    ErrorLogMinFiles          = 52      # Attention if fewer log files retained
}
```

---

## What Gets Checked

Each finding is assigned one of four statuses: **Pass**, **Attention**, **Fail**, or **Informational**.

### Available Now

| Spoke | Checks |
|---|---|
| **Database** | Backup currency (Full/Diff/Log), VLF counts, auto-growth events, free space, auto-shrink, auto-close, page verify, TRUSTWORTHY, TDE inventory, Query Store status, recovery model, compatibility level, owner compliance, collation match, file growth type, multiple log files, statistics settings, Service Broker inventory, contained databases, feature usage |
| **Host** | Power plan compliance, pending reboot, VM detection, HyperThreading ratio, NUMA topology, domain membership, OS version/build compliance, OS inventory, Instant File Initialization (IFI), Lock Pages In Memory (LPIM), OS privilege inventory, SQL firewall rules inventory |
| **Instance** | Build/patch compliance, version support status, max server memory, MAXDOP, optimize for ad-hoc workloads, xp_cmdshell, ad hoc distributed queries, OLE automation, CLR integration, contained DB auth, remote DAC, cost threshold for parallelism, fill factor, backup compression, sp_configure full inventory, pending configuration changes, SQL feature discovery, error log scan, global trace flags, startup parameters |
| **Maintenance** | Last good CHECKDB age, statistics staleness, duplicate/overlapping indexes, unused indexes, disabled indexes, top wait statistics, identity column capacity, error log retention configuration |

### Coming Soon

| Spoke | Planned Checks |
|---|---|
| **HADR** | Availability Group health, replica connectivity, log shipping, database mirroring |
| **Security & Audit** | Server/database audit specs, SA account status, surface area exposure |
| **TempDB** | File count, equal sizing, growth config, space utilization |
| **Networking** | TCP/IP config, named pipes, SPN compliance, static vs. dynamic port, round-trip latency |
| **Misc** | Database Mail health, Extended Events sessions, notable trace flags |

---

## The Report

The HTML report is **fully self-contained** — no server, no internet connection, no external stylesheets required. Open it in any browser or email it directly.

The report includes:

- **Overview dashboard** — all instances, category breakdowns, and aggregate health scores visualized as a gauge
- **Per-instance drill-down** — full findings table with status, category, and details
- **All-findings view** — filterable by status and category across all instances
- **Sortable, color-coded tables** — red → amber → green heat cells
- **Import/Export** — export to JSON or Excel workbook; import a previous JSON run to review historical results
- **User guide** — click the **?** icon (top-right) for an in-report navigation guide

Reports are saved to `4. Output\Reports\` and the suite retains the last 5 by default (configurable via `-KeepLastReports`).

---

## Operational Modes

### Normal Run

```powershell
.\Start-Checkup.ps1
```

### Dry Run (validate config without running checks)

```powershell
.\Start-Checkup.ps1 -DryRun
```

Validates your targets file, output paths, and enabled packs — no SQL connections made.

### Generate Example Files

```powershell
.\Start-Checkup.ps1 -GenerateExampleTargets
```

Creates `targets.example.json` and `settings.example.json` as starting point templates.

### Force-Rebuild Targets

```powershell
.\Start-Checkup.ps1 -ReplaceTargetConfig $true
```

### Overwrite Saved Settings

```powershell
.\Start-Checkup.ps1 -OverwriteSettings $true
```

On first run, `settings.json` is created from your `$Settings` block and reused on subsequent runs. Pass `-OverwriteSettings $true` to apply changes from `Start-Checkup.ps1` to the saved file.

---

## Credential Options

| Parameter | Behavior |
|---|---|
| `-UseNoCredential $true` | Windows integrated authentication (default) |
| `-UseSingleCredential $true` | Prompts once for SQL credentials, reused across all targets |
| Per-target `CredKey` in targets.json | Assign different credentials per instance |

---

## Folder Structure

```
sql-health-suite\
├── Start-Checkup.ps1          ← Entry point; all configuration lives here
├── Checkup.Engine.ps1         ← Orchestrator
├── Checkup.Catalog.ps1        ← Check metadata (labels, categories, priorities)
├── targets.json               ← Your target instances
├── 2. Spokes\
│   ├── Spoke.Database.ps1     ← Database check pack
│   ├── Spoke.Host.ps1         ← Host / OS check pack
│   ├── Spoke.Instance.ps1     ← Instance-level check pack
│   └── Spoke.Maintenance.ps1  ← Maintenance check pack
├── 3. Helpers\
│   ├── Helpers.Shared.ps1
│   ├── Helpers.Engine.ps1
│   ├── Helpers.Targets.ps1
│   ├── Helpers.Database.ps1
│   └── Helpers.Host.ps1
└── 4. Output\
    ├── Report.Template.html
    ├── Report.HtmlBuilder.ps1
    ├── Reports\               ← HTML reports
    ├── Json-Findings\         ← JSON findings (system of record)
    └── Run-Transcripts\       ← PowerShell transcripts
```

---

## FAQ

**Will this change anything on my SQL Server?**
No. The suite uses only `Get-*`, `Test-*`, and diagnostic `Invoke-*` dbatools cmdlets. It is read-only by design and never modifies configuration.

**Can I add my own checks?**
Yes. Create a new `Spoke.MyCheck.ps1` in the `2. Spokes\` folder. The engine auto-discovers all `Spoke.*.ps1` files on each run. Add your check metadata to `Checkup.Catalog.ps1` to keep it organized. More guidance on the spoke contract will be added to the repo wiki.

**How do I exclude certain databases?**
Set `ExcludeDatabases` in the Database settings block using glob patterns:
```powershell
ExcludeDatabases = @('ReportServer*', 'DBAtools*')
```

**The report says a check "Attention" but I expect it to be fine. How do I tune it?**
Adjust the relevant threshold in the `$Settings` block in `Start-Checkup.ps1`. Each threshold is documented inline with a comment explaining its intent.

**Can I schedule this?**
Yes — `Start-Checkup.ps1` is designed to run unattended. Use `-UseNoCredential $true` (Windows auth) or pre-configure SQL credentials via `targets.json`. Set `-OpenReportAfterRun $false` to suppress the browser launch.

---

## Contributing & Bugs

This project is in active development and built to be customized. Feedback is very welcome.

- **Bug reports** — Please open a GitHub Issue with the spoke name, check label, and any relevant output from the transcript.
- **Feature requests** — Open an Issue describing the check and the dbatools command that would power it.
- **Pull requests** — Welcome. Please keep check logic inside spoke files and metadata in `Checkup.Catalog.ps1`.

---

*Built on [dbatools](https://dbatools.io) — the community's Swiss Army knife for SQL Server administration.*