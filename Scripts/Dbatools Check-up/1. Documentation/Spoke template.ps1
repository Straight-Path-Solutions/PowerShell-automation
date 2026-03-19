#Requires -Version 5.1
<#
.SYNOPSIS
    Template.Spoke - Reference implementation for new spokes.

.DESCRIPTION
    Copy this file to create a new spoke. Follow the patterns shown here for:
    - Initialization and config validation
    - Data fetching with progress indicators
    - Check execution via Invoke-Check
    - Error handling and graceful degradation

.CONTRACT
    A (Engine-Spoke): -Target, -Config, -Findings parameters required.
    B (Check Execution): All checks via Invoke-Check.
    I (Configuration): Use Cfg() for all config access.
    
.EXAMPLE
    & .\Spoke.Template.ps1 -Target $target -Config $config -Findings ([ref]$findings)
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNull()]
    [object]$Target,

    [Parameter(Mandatory)]
    [ValidateNotNull()]
    [hashtable]$Config,

    [Parameter(Mandatory)]
    [ref]$Findings
)

# ==============================================================================
# BOOTSTRAP
# ==============================================================================
$ErrorActionPreference = 'Stop'
$spokeFile = Split-Path -Leaf $MyInvocation.MyCommand.Path

# Load shared helpers
$helpersPath = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) '3. Helpers'
. "$helpersPath\Helpers.Shared.ps1"

# Assert read-only posture (Contract A)
if (-not ($Config['ReadOnly'] -eq $true)) {
    throw "Config.ReadOnly must be true. This spoke makes no writes."
}

# ==============================================================================
# CONFIGURATION VALIDATION
# ==============================================================================
$packName = 'Template'  # Change to your pack name

# Load pack config (returns MissingConfigKey if absent)
$requiredKeys = @('SomeRequiredSetting', 'AnotherRequiredSetting')
$missingKeys = @()

foreach ($key in $requiredKeys) {
    $val = Cfg $Config "${packName}.${key}"
    if ($val -is [MissingConfigKey]) {
        $missingKeys += $key
    }
}

# Skip entire spoke if required config is missing
if ($missingKeys) {
    foreach ($key in $missingKeys) {
        $Findings.Value += New-SkipFinding `
            -Key "$packName.$key" `
            -CheckLabel "[$packName] Configuration" `
            -SpokeFile $spokeFile
    }
    return
}

# Extract config values with defaults
$someSetting = Cfg $Config "${packName}.SomeRequiredSetting"
$optionalSetting = Cfg $Config "${packName}.OptionalSetting" -Default 100

# ==============================================================================
# DATA FETCH
# ==============================================================================
$sql = Get-SqlConnectionSplat -Target $Target
$pfToken = Write-FetchProgress -Spoke $packName -Start

try {
    # Fetch data with dbatools wrapper
    Update-FetchProgress -Token $pfToken -Label 'Loading primary data'
    $primaryData = Invoke-DBATools {
        Get-Dba* @sql -EnableException
    }
    
    if ($null -eq $primaryData) {
        throw "Failed to retrieve primary data from $($Target.SqlInstance)"
    }
    
    Update-FetchProgress -Token $pfToken -Label 'Loading secondary data'
    $secondaryData = Invoke-DBATools {
        Get-Dba* @sql -EnableException
    }
    
} catch {
    # Data fetch failure - emit finding and exit spoke
    $Findings.Value += New-Finding `
        -Label    "[$packName] Data Retrieval" `
        -Category 'Availability' `
        -Priority 'High' `
        -Status   'fail' `
        -Details  "Failed to retrieve spoke data: $($_.Exception.Message)" `
        -Source   'Get-Dba*' `
        -SpokeFile $spokeFile
    return
} finally {
    Write-FetchProgress -Token $pfToken -End
}

# ==============================================================================
# CHECKS
# ==============================================================================

# Register this check section (Contract G)
Register-CheckSection -File $spokeFile -Number 1 `
    -Title 'Example Check' -Function 'Get-Dba*' -Key 'ExampleCheck'

Invoke-Check `
    -CatalogName  $packName `
    -Function     'Get-Dba*' `
    -Key          'ExampleCheck' `
    -Target       $Target `
    -Config       $Config `
    -Findings     $Findings `
    -SpokeFile    $spokeFile `
    -Run {
        param($sql, $t, $cfg)
        
        # Your check logic here
        # Return @{ Status='pass'|'attention'|'fail'; Details='...' }
        
        if ($primaryData.SomeProperty -eq 'ExpectedValue') {
            return @{
                Status  = 'pass'
                Details = 'Configuration meets expectations.'
            }
        }
        
        return @{
            Status  = 'attention'
            Details = "Found unexpected value: $($primaryData.SomeProperty)"
        }
    }

# Additional checks follow same pattern...