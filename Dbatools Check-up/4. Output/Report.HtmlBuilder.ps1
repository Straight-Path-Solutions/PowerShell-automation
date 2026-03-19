#Requires -Version 5.1
# =============================================================================
# Report.HtmlBuilder.ps1  -  Generate timestamped HTML health reports
# =============================================================================
#
# WHAT THIS DOES:
#   - Loads the HTML template and JSON findings
#   - Injects JSON safely into the template's <script> tag
#   - Writes timestamped HTML report to OutputFolder
#   - Manages report retention (KeepLast N reports)
#   - Optionally opens the report in default browser
#
# DEPENDENCIES:
#   - Report.Template.html (HTML/CSS/JS template)
#   - Instances.json (findings data from Core.Checkup.ps1)
#
# CONTRACT REFERENCES:
#   - Contract F 3: Report generation and JSON embedding
#
# USAGE:
#   Called by Core.Checkup.ps1 after JSON write completes.
#   Not intended for direct user invocation.
#
# REGION MAP:
#   1. Parameter Validation & Setup
#   2. File Loading & JSON Processing
#   3. JSON Safety & Embedding
#   4. Report Rotation
#   5. Output & Completion
# =============================================================================

<#
.SYNOPSIS
    Generate a timestamped HTML health report with embedded JSON data.

.DESCRIPTION
    Loads the HTML template, injects the findings JSON into the data placeholder,
    and writes a timestamped report to the output folder. Optionally rotates old
    reports to maintain only the N most recent files.
    
    The JSON is sanitized to prevent script injection and HTML comment interference:
    - </script> is escaped to prevent early tag closure
    - <!-- is escaped to prevent HTML comment start
    - Unicode line/paragraph separators (U+2028/U+2029) are escaped
    
    Called by: Core.Checkup.ps1

.PARAMETER JsonPath
    Path to the Instances.json file containing findings data.

.PARAMETER TemplatePath
    Path to the Report.Template.html file.

.PARAMETER OutputFolder
    Directory where timestamped HTML reports will be written.

.PARAMETER KeepLast
    Number of recent reports to retain. Older reports are deleted.
    Set to 0 to keep all reports (no rotation).
    Default: 0

.PARAMETER OpenAfter
    If $true, opens the generated report in the default browser.
    Default: $true

.PARAMETER ReportTitle
    Custom title for the report. Injected into <title> tag if template supports it.
    Default: 'SQL Server Health Report'

.EXAMPLE
    .\Report.HtmlBuilder.ps1 -JsonPath '.\Output\Instances.json' `
                              -TemplatePath '.\Report.Template.html' `
                              -OutputFolder '.\Output\Reports' `
                              -KeepLast 10

    Generates Report_20260303_143022.html and keeps only the 10 most recent reports.

.EXAMPLE
    .\Report.HtmlBuilder.ps1 -JsonPath $jsonPath `
                              -TemplatePath $templatePath `
                              -OutputFolder $outFolder `
                              -OpenAfter $false

    Generates report but does not open it automatically.

.NOTES
    Contract: F 3
    
    Design Notes:
    - Timestamp format is yyyyMMdd_HHmmss for sortable filenames
    - JSON is pretty-printed (non-compressed) for debuggability
    - Regex injection uses Singleline mode to handle multi-line data declarations
    - Report rotation is file-count based, not date/size based
    
    Known Limitations:
    - ReportTitle injection assumes template has a placeholder (currently hardcoded in template)
    - No suite version stamp in output (tracked in pre-release gaps #6)
    
    Performance:
    - Regex replacement is O(n) on template size (~500KB typical)
    - JSON pretty-print depth of 100 handles deeply nested findings
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [ValidateScript({ Test-Path $_ })]
    [string]$JsonPath,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [ValidateScript({ Test-Path $_ })]
    [string]$TemplatePath,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$OutputFolder,

    [ValidateRange(0, 1000)]
    [int]$KeepLast = 0,

    [bool]$OpenAfter = $true,

    [ValidateNotNullOrEmpty()]
    [string]$ReportTitle = 'SQL Server Health Report',

    [string]$EngineVersion = ''
)

$ErrorActionPreference = 'Stop'

# =============================================================================
#  1. PARAMETER VALIDATION & SETUP
# =============================================================================
#region Validation

Write-Host "`n=== Building HTML Health Report ===" -ForegroundColor Cyan

# Ensure output folder exists
if (-not (Test-Path $OutputFolder)) {
    Write-Verbose "Creating output folder: $OutputFolder"
    New-Item -ItemType Directory -Force -Path $OutputFolder | Out-Null
}

# Generate timestamped output path
$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$reportFileName = "Report_$timestamp.html"
$htmlOutputPath = Join-Path $OutputFolder $reportFileName

Write-Host "Template:   $TemplatePath"
Write-Host "JSON Data:  $JsonPath"
Write-Host "Output:     $htmlOutputPath"
if ($KeepLast -gt 0) {
    Write-Host "Retention:  Keep last $KeepLast report(s)"
}
Write-Host ""

#endregion

# =============================================================================
#  2. FILE LOADING & JSON PROCESSING
# =============================================================================
#region File Loading

Write-Verbose "Loading HTML template..."
$htmlTemplate = Get-Content -Path $TemplatePath -Raw -Encoding UTF8

Write-Verbose "Loading JSON findings..."
$jsonRaw = Get-Content -Path $JsonPath -Raw -Encoding UTF8

# Validate JSON structure and pretty-print for readability
Write-Verbose "Validating and formatting JSON..."
try {
    $jsonObject = $jsonRaw | ConvertFrom-Json -ErrorAction Stop
    $prettyJson = $jsonObject | ConvertTo-Json -Depth 100 -Compress:$false
} catch {
    throw "Invalid JSON format in ${JsonPath}: $($_.Exception.Message)"
}

Write-Verbose "JSON validated successfully. Size: $($prettyJson.Length) characters"

#endregion

# =============================================================================
#  3. JSON SAFETY & EMBEDDING
# =============================================================================
#region JSON Injection

<#
    Make JSON safe for embedding inside <script> tags.
    
    Three transformations are required:
    
    1. Escape </script> to prevent early script tag closure
       Without this, the browser would interpret </script> inside the JSON
       as the end of the script block, breaking the page.
       
    2. Escape <!-- to prevent HTML comment start
       Older browsers may interpret <!-- inside <script> as a comment start,
       hiding subsequent code.
       
    3. Escape Unicode line/paragraph separators (U+2028, U+2029)
       These are valid JSON whitespace but invalid JavaScript string literals.
       Without escaping, they cause syntax errors in some browsers.
#>

Write-Verbose "Sanitizing JSON for safe script injection..."

$sanitizedJson = $prettyJson
$sanitizedJson = [regex]::Replace($sanitizedJson, '</script', '<\/script', 'IgnoreCase')
$sanitizedJson = $sanitizedJson -replace '<!--', '\u003C!--'
$sanitizedJson = $sanitizedJson -replace [char]0x2028, '\u2028'
$sanitizedJson = $sanitizedJson -replace [char]0x2029, '\u2029'

<#
    Inject JSON into template's data placeholder.
    
    The template contains a declaration like:
        const data = { ... };
    or
        let data = [];
    
    We replace the entire declaration (including RHS) with our JSON.
    
    Regex explanation:
    - (?is)              - Case-insensitive, Singleline mode (dot matches newlines)
    - \b(const|let|var)  - Match variable declaration keyword
    - \s+data\s*=\s*     - Match 'data' identifier with flexible whitespace
    - [^;]*;             - Match everything until semicolon (the original RHS)
#>

Write-Verbose "Injecting JSON into template..."

$dataPattern = '(?is)\b(?:const|let|var)\s+data\s*=\s*[^;]*;'
$dataReplacement = "const data = $sanitizedJson;"

if ($htmlTemplate -match $dataPattern) {
    $htmlWithData = [regex]::Replace(
        $htmlTemplate,
        $dataPattern,
        $dataReplacement,
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase `
            -bor [System.Text.RegularExpressions.RegexOptions]::Singleline
    )
    Write-Verbose "JSON injected into existing data placeholder."
} else {
    Write-Warning "Could not find 'data' placeholder in template. Injecting new <script> block before </body>."
    
    # Fallback: inject new script block if placeholder is missing
    if ($htmlTemplate -match '(?i)</body>') {
        $htmlWithData = [regex]::Replace(
            $htmlTemplate,
            '(?i)</body>',
            "<script>`n$dataReplacement`n</script>`n</body>"
        )
    } else {
        # Last resort: append to end of file
        $htmlWithData = $htmlTemplate + "`n<script>`n$dataReplacement`n</script>`n"
    }
}

# Inject report title (if template supports it)
# Template should have: <title>{{REPORT_TITLE}}</title>
$titlePattern = '\{\{REPORT_TITLE\}\}'
if ($htmlWithData -match $titlePattern) {
    $htmlWithData = $htmlWithData -replace $titlePattern, [regex]::Escape($ReportTitle)
    Write-Verbose "Injected custom report title: $ReportTitle"
} else {
    Write-Verbose "Template does not support custom title injection (no {{REPORT_TITLE}} placeholder)."
}

#endregion

# =============================================================================
#  4. REPORT ROTATION
# =============================================================================
#region Report Rotation

if ($KeepLast -gt 0) {
    Write-Verbose "Checking for old reports to rotate..."
    
    # Get all reports matching the naming pattern, sorted newest first
    $existingReports = Get-ChildItem -Path $OutputFolder -Filter 'Report_*.html' -File |
        Sort-Object Name -Descending
    
    $reportCount = $existingReports.Count
    Write-Verbose "Found $reportCount existing report(s)."
    
    # After writing the new report, we'll have ($reportCount + 1) total
    # Delete oldest reports if that exceeds KeepLast
    if ($reportCount -ge $KeepLast) {
        $toDelete = $existingReports | Select-Object -Skip ($KeepLast - 1)
        
        foreach ($oldReport in $toDelete) {
            Write-Verbose "Deleting old report: $($oldReport.Name)"
            try {
                Remove-Item -Path $oldReport.FullName -Force -ErrorAction Stop
            } catch {
                Write-Warning "Could not delete old report $($oldReport.Name): $($_.Exception.Message)"
            }
        }
    }
}

#endregion

# =============================================================================
#  5. OUTPUT & COMPLETION
# =============================================================================
#region Output

Write-Verbose "Writing HTML report to disk..."

try {
    $htmlWithData | Out-File -FilePath $htmlOutputPath -Encoding UTF8 -Force -ErrorAction Stop
} catch {
    throw "Failed to write HTML report: $($_.Exception.Message)"
}

$reportSize = (Get-Item $htmlOutputPath).Length
Write-Host "[+] Report generated successfully." -ForegroundColor Green
Write-Host "  Path: $htmlOutputPath"
Write-Host "  Size: $([math]::Round($reportSize / 1KB, 2)) KB"
Write-Host ""

# Auto-open report in browser if requested
if ($OpenAfter) {
    Write-Verbose "Opening report in default browser..."
    try {
        Start-Process $htmlOutputPath -ErrorAction Stop
    } catch {
        Write-Warning "Could not open report automatically: $($_.Exception.Message)"
        Write-Warning "You can open it manually at: $htmlOutputPath"
    }
}

# Return the path for pipeline usage
return $htmlOutputPath

#endregion

# =============================================================================
# End of Report.HtmlBuilder.ps1
# =============================================================================