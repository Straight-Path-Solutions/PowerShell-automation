#Requires -Version 5.1
# =============================================================================
# Helpers\Helpers.Database.ps1  -  Shared helpers for Database spoke checks
# =============================================================================
#
# WHAT BELONGS HERE:
#   - Database collection filtering and scoping
#   - Cross-version property accessors (SMO/dbatools compatibility)
#   - Database status/health mapping
#   - Pattern matching for database names
#   - Backup age calculations and formatting
#   - Data structure transformations for database objects
#
# WHAT DOES NOT BELONG HERE:
#   - Actual check logic (belongs in Spoke.Database.ps1)
#   - Instance-level helpers (belongs in Helpers.Shared.ps1)
#   - Generic utilities (e.g., string formatting -> Helpers.Shared.ps1)
#   - TempDB-specific logic (has dedicated spoke)
#
# DEPENDENCIES:
#   - Helpers.Shared.ps1 (Summarize-Examples, New-Finding, etc.)
#   - dbatools module (Get-DbaDatabase, Get-DbaDbBackupHistory)
#
# CONTRACT REFERENCES:
#   - Contract D: Database scope filtering
#   - Contract D: Backup age calculations
#   - Contract D: Multi-version property access patterns
#
# LOADING:
#   Dot-source this file in Spoke.Database.ps1.
#   The engine's Publish-HealthSuiteFunctions promotes all functions to global scope.
#
# REGION MAP:
#   1. Private Helpers - Internal utilities (double-underscore prefix)
#   2. Scope Filtering - Database collection filtering and pattern matching
#   3. Property Accessors - Safe cross-version property getters
#   4. Status Mapping - Database health/status determination
#   5. Backup Helpers - Backup age calculation and formatting
#   6. Data Structures - Lookups and transformations
# =============================================================================

# =============================================================================
#  1. PRIVATE HELPERS
# =============================================================================
#region Private Helpers

function Get-DbProperty {
    <#
    .SYNOPSIS
        Safely retrieves a property value by trying multiple property names.
    
    .DESCRIPTION
        Iterates through a list of property names and returns the first
        non-null value found. Handles differences between dbatools versions
        and SMO property naming.
        
        Internal helper - not intended for spoke use.
    
    .PARAMETER Object
        The object to query (typically a database or SMO object).
    
    .PARAMETER PropertyNames
        Array of property names to try in order.
    
    .EXAMPLE
        Get-DbProperty -Object $db -PropertyNames @('IsAccessible', 'Accessible')
        
        Returns the first property value found, or $null if none exist.
    
    .NOTES
        Used internally by Get-DbIsAccessible, Get-DbOwnerName, and other
        cross-version property accessors.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Object,
        [Parameter(Mandatory)][string[]]$PropertyNames
    )
    foreach ($name in $PropertyNames) {
        if ($Object -and $Object.PSObject -and $Object.PSObject.Properties[$name]) { 
            return $Object.$name 
        }
    }
    return $null
}

function Get-DbBooleanProperty {
    <#
    .SYNOPSIS
        Safely retrieves a boolean property value by trying multiple names.
    
    .DESCRIPTION
        Wraps Get-DbProperty with boolean type coercion and default value support.
        
        Internal helper - not intended for spoke use.
    
    .PARAMETER Object
        The object to query (typically a database or SMO object).
    
    .PARAMETER PropertyNames
        Array of property names to try in order.
    
    .PARAMETER DefaultValue
        Value to return if property is not found or cannot be converted to boolean.
    
    .EXAMPLE
        Get-DbBooleanProperty -Object $db -PropertyNames @('IsSystemObject', 'IsSystem') -DefaultValue $false
        
        Returns the first boolean property found, or $false if none exist.
    
    .NOTES
        Used internally by Select-DatabaseScope for filtering system databases.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Object,
        [Parameter(Mandatory)][string[]]$PropertyNames,
        [bool]$DefaultValue = $false
    )
    $value = Get-DbProperty -Object $Object -PropertyNames $PropertyNames
    if ($null -eq $value) { return $DefaultValue }
    try { return [bool]$value } catch { return $DefaultValue }
}

function Get-StatusRank {
    <#
    .SYNOPSIS
        Returns a numeric rank for a status string for worst-status comparison.
    
    .DESCRIPTION
        Rank order (worst to best):
          2 = fail (worst)
          1 = attention
          0 = pass, info (best)
        
        Used by Get-WorstDatabaseStatus to compare status values.
        
        Internal helper - not intended for spoke use.
    
    .PARAMETER Status
        Status string ('pass', 'fail', 'attention', 'info').
    
    .EXAMPLE
        Get-StatusRank -Status 'fail'
        # Returns: 2

    .EXAMPLE
        Get-StatusRank -Status 'pass'
        # Returns: 0

    .NOTES
        Unrecognized status values default to rank 2 (fail) for safety.
        Null input is treated as an empty string and also returns rank 2.
    #>
    [CmdletBinding()]
    param([string]$Status)
    
    $s = if ($null -eq $Status) { '' } else { [string]$Status }
    switch ($s.Trim().ToLowerInvariant()) {
        'pass'      { 0 }
        'info'      { 0 }
        'attention' { 1 }
        'fail'      { 2 }
        default     { 2 }
    }
}

#endregion

# =============================================================================
#  2. SCOPE FILTERING
# =============================================================================
#region Scope Filtering

function Select-DatabaseScope {
    <#
    .SYNOPSIS
        Filters a raw Get-DbaDatabase result set into the scope for this spoke.
    
    .DESCRIPTION
        Applies standard database filtering rules:
        - tempdb is always excluded (has dedicated instance-level checks)
        - Database snapshots are excluded (property name varies by version)
        - System databases excluded unless IncludeSystem is $true
        
        Used by: Spoke.Database.ps1 to establish the in-scope database list.
    
    .PARAMETER Databases
        Array of database objects from Get-DbaDatabase.
    
    .PARAMETER IncludeSystem
        If $true, includes system databases (master, model, msdb).
        If $false (default), only user databases are returned.
    
    .EXAMPLE
        $dbs = Get-DbaDatabase -SqlInstance $Target.SqlInstance
        $scopedDbs = Select-DatabaseScope -Databases $dbs -IncludeSystem $false
        
        Returns only user databases (no tempdb, no system dbs, no snapshots).
    
    .NOTES
        Contract D: Database scope filtering
        
        This function handles differences in property names across dbatools
        and SMO versions (IsSystemObject vs IsSystem, IsDatabaseSnapshot vs IsSnapshot).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Databases,
        [Parameter(Mandatory)][bool]    $IncludeSystem
    )

    $dbs = @($Databases)

    # Always exclude tempdb (has dedicated TempDB spoke)
    $dbs = @($dbs | Where-Object { $_.Name -ne 'tempdb' })

    # Exclude snapshots
    $dbs = @($dbs | Where-Object {
        -not (Get-DbBooleanProperty -Object $_ -PropertyNames @('IsDatabaseSnapshot', 'IsSnapshot') -DefaultValue:$false)
    })

    # Exclude system databases unless explicitly included
    if (-not $IncludeSystem) {
        $dbs = @($dbs | Where-Object {
            -not (Get-DbBooleanProperty -Object $_ -PropertyNames @('IsSystemObject', 'IsSystemDatabase', 'IsSystem') -DefaultValue:$false)
        })
    }

    return , $dbs
}

function ConvertTo-StringArray {
    <#
    .SYNOPSIS
        Normalizes a scalar or array input into a trimmed string array.
    
    .DESCRIPTION
        Handles scalar strings, arrays, null values, and empty strings.
        Trims whitespace and filters out null/empty entries.
        
        Used by: Select-DatabaseByExcludePattern for normalizing exclude patterns.
    
    .PARAMETER Value
        Scalar string, array of strings, or null.
    
    .EXAMPLE
        ConvertTo-StringArray -Value 'Test*'
        
        Returns: @('Test*')
    
    .EXAMPLE
        ConvertTo-StringArray -Value @('  Test*  ', '', $null, 'Prod*')
        
        Returns: @('Test*', 'Prod*')
    
    .EXAMPLE
        ConvertTo-StringArray -Value $null
        
        Returns: @()
    
    .NOTES
        This is a database-agnostic helper that could potentially be moved
        to Helpers.Shared.ps1 if other spokes need it. Currently only used by
        Spoke.Database.ps1.
    #>
    [CmdletBinding()]
    param([object]$Value)

    if ($null -eq $Value) { return @() }

    # Scalar string
    if ($Value -is [string]) {
        $s = $Value.Trim()
        if ($s.Length -eq 0) { return @() }
        return @($s)
    }

    # Array or collection
    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
        $out = @()
        foreach ($v in $Value) {
            if ($null -eq $v) { continue }
            $s = ([string]$v).Trim()
            if ($s.Length -gt 0) { $out += $s }
        }
        return $out
    }

    # Fallback: coerce to string
    return @(([string]$Value).Trim())
}

function Test-DatabaseNamePattern {
    <#
    .SYNOPSIS
        Returns $true if Name matches ANY wildcard pattern (PowerShell -like).
    
    .DESCRIPTION
        Tests a database name against multiple wildcard patterns.
        Case-insensitive by default (PowerShell -like behavior).
        
        Used by: Select-DatabaseByExcludePattern
    
    .PARAMETER Name
        The database name to test.
    
    .PARAMETER Patterns
        Array of wildcard patterns (*, ?, [abc] syntax supported).
    
    .EXAMPLE
        Test-DatabaseNamePattern -Name 'MyDB' -Patterns @('My*', 'Test*')
        
        Returns: $true
    
    .EXAMPLE
        Test-DatabaseNamePattern -Name 'ProdDB' -Patterns @('Dev*', 'Test*')
        
        Returns: $false
    
    .NOTES
        Empty or null patterns always return $false.
        Whitespace-only patterns are ignored.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [string[]]$Patterns = @()
    )

    foreach ($pattern in @($Patterns)) {
        if ([string]::IsNullOrWhiteSpace($pattern)) { continue }
        if ($Name -like $pattern) { return $true }
    }
    return $false
}

function Select-DatabaseByExcludePattern {
    <#
    .SYNOPSIS
        Removes databases whose Name matches any exclude wildcard patterns.
    
    .DESCRIPTION
        Filters a database collection by exclude patterns. Databases matching
        any pattern are removed from the result set.
        
        Used by: Spoke.Database.ps1 to apply user-configured ExcludeDatabases patterns.
    
    .PARAMETER Databases
        Array of database objects from Get-DbaDatabase.
    
    .PARAMETER ExcludePatterns
        Array of wildcard patterns for database names to exclude.
    
    .EXAMPLE
        Select-DatabaseByExcludePattern -Databases $dbs -ExcludePatterns @('Dev*', 'Test*')
        
        Returns all databases except those starting with 'Dev' or 'Test'.
    
    .EXAMPLE
        Select-DatabaseByExcludePattern -Databases $dbs -ExcludePatterns @()
        
        Returns all databases (no exclusions).
    
    .NOTES
        Contract D: Database scope filtering
        
        If ExcludePatterns is empty or null, all databases are returned unchanged.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Databases,
        [string[]]$ExcludePatterns = @()
    )

    $patterns = ConvertTo-StringArray -Value $ExcludePatterns
    if ($patterns.Count -eq 0) { return , @($Databases) }

    $out = @()
    foreach ($db in @($Databases)) {
        if (-not $db) { continue }
        $name = [string]$db.Name
        if (-not (Test-DatabaseNamePattern -Name $name -Patterns $patterns)) { 
            $out += $db 
        }
    }
    return , $out
}

#endregion

# =============================================================================
#  3. PROPERTY ACCESSORS
# =============================================================================
#region Property Accessors

function Get-DatabaseAccessibility {
    <#
    .SYNOPSIS
        Safe accessor for database accessibility across SMO/dbatools variations.
    
    .DESCRIPTION
        Checks multiple property names to determine if a database is accessible:
        - IsInaccessible (inverted sense, some dbatools versions)
        - IsAccessible (standard SMO)
        - Accessible (some dbatools versions)
        - Falls back to Status string match (Normal/Online -> accessible)
        
        Used by: Spoke.Database.ps1 to filter accessible databases for checks.
    
    .PARAMETER Database
        Database object from Get-DbaDatabase.
    
    .EXAMPLE
        if (Get-DatabaseAccessibility -Database $db) {
            # Safe to query database properties
        }
    
    .NOTES
        Contract D: Multi-version property access patterns
        
        Always returns $true or $false (never null or throws).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Database)

    # IsInaccessible is present in some dbatools versions (inverted sense)
    if ($Database.PSObject.Properties.Name -contains 'IsInaccessible') {
        return (-not [bool]$Database.IsInaccessible)
    }

    # Standard SMO / newer dbatools
    foreach ($prop in @('IsAccessible', 'Accessible')) {
        if ($Database.PSObject.Properties.Name -contains $prop) {
            return [bool]($Database.$prop)
        }
    }

    # Fallback: treat Normal/Online as accessible
    $status = [string]($Database.Status)
    return ($status -match '(?i)^(Normal|Online)$')
}

function Get-DatabaseOwnerName {
    <#
    .SYNOPSIS
        Safe accessor for the database owner name across SMO/dbatools variations.
    
    .DESCRIPTION
        Checks multiple property names to retrieve the database owner:
        - Owner (standard SMO)
        - OwnerName (some dbatools versions)
        - DatabaseOwner, DatabaseOwnerName (older versions)
        
        Returns '(unknown)' when no owner can be determined.
        
        Used by: Spoke.Database.ps1 ownership checks.
    
    .PARAMETER Database
        Database object from Get-DbaDatabase.
    
    .EXAMPLE
        $owner = Get-DatabaseOwnerName -Database $db
        if ($owner -eq 'sa') {
            # Flag as potential security issue
        }
    
    .NOTES
        Contract D: Multi-version property access patterns
        
        Always returns a string (never null or throws).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Database)

    foreach ($prop in @('Owner', 'OwnerName', 'DatabaseOwner', 'DatabaseOwnerName')) {
        if ($Database.PSObject.Properties.Name -contains $prop) {
            $value = [string]($Database.$prop)
            if (-not [string]::IsNullOrWhiteSpace($value)) { return $value }
        }
    }
    return '(unknown)'
}

function Get-DatabaseBackupDate {
    <#
    .SYNOPSIS
        Safely extract a [datetime] value from either a plain DateTime or a
        DbaDateTime wrapper object returned by Get-DbaDbBackupHistory.

    .DESCRIPTION
        dbatools returns backup timestamps as DbaDateTime objects, not plain
        [datetime] values. This function unwraps either type reliably:

          - Plain [datetime]    → returned as-is (do NOT call .Date; that
                                  truncates to midnight)
          - DbaDateTime wrapper → .Date property extracts the underlying
                                  [datetime] (this .Date is the correct
                                  unwrap accessor, not a truncation)
          - Null input          → returns $null (never throws)
          - Unknown type        → attempts [datetime] cast, returns $null on
                                  failure

    .PARAMETER DbaDateTimeObject
        A DbaDateTime object from Get-DbaDbBackupHistory, a plain [datetime],
        or $null.

    .OUTPUTS
        [datetime] or $null.

    .EXAMPLE
        $dt = Get-DatabaseBackupDate -DbaDateTimeObject $db.LastFullBackup
        if ($null -eq $dt) { 'never' } else { $dt.ToString('s') }

    .EXAMPLE
        # Null-safe: no error when backup history is absent
        $dt = Get-DatabaseBackupDate -DbaDateTimeObject $null
        # $dt -> $null

    .NOTES
        Used by: ConvertTo-BackupAge (Helpers.Database.ps1)

        The .Date asymmetry is intentional:
          - On a plain [datetime], .Date truncates to midnight — WRONG for age math.
          - On DbaDateTime, .Date is the property that exposes the inner [datetime]
            — correct and required.

        Never throws. Returns $null for any unresolvable input.
    #>
    [CmdletBinding()]
    param([object]$DbaDateTimeObject)

    if ($null -eq $DbaDateTimeObject) { return $null }

    # Plain DateTime -- return directly; do NOT touch .Date (that strips the time component to midnight)
    if ($DbaDateTimeObject -is [datetime]) {
        return $DbaDateTimeObject
    }

    # DbaDateTime wrapper (from Get-DbaDbBackupHistory) -- unwrap via .Date
    if ($DbaDateTimeObject.PSObject.Properties['Date']) {
        $date = $DbaDateTimeObject.Date
        if ($null -eq $date) { return $null }
        try { return [datetime]$date } catch { return $null }
    }

    # Fallback
    try { return [datetime]$DbaDateTimeObject } catch { return $null }
}

#endregion

# =============================================================================
#  4. STATUS MAPPING
# =============================================================================
#region Status Mapping

function Get-DatabaseHealthStatus {
    <#
    .SYNOPSIS
        Maps a database status/state string to a check status value.
    
    .DESCRIPTION
        Maps common database status values to check statuses:
        - Normal/Online -> pass
        - Restoring/Recovering/RecoveryPending/Suspect/Emergency -> fail
        - Offline/Shutdown/Inaccessible -> fail
        - Unknown states -> attention (conservative)
        
        Used by: Spoke.Database.ps1 health checks.
    
    .PARAMETER DatabaseStatus
        Database status string from Get-DbaDatabase (e.g., $db.Status).
    
    .EXAMPLE
        $status = Get-DatabaseHealthStatus -DatabaseStatus $db.Status
        
        Returns: 'pass', 'fail', or 'attention'
    
    .NOTES
        Conservative mapping: unknown states default to 'attention' rather than 'pass'.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DatabaseStatus)

    $status = $DatabaseStatus.Trim()

    switch -Regex ($status) {
        '^(?i)(Normal|Online)$'                                             { return 'pass'      }
        '^(?i)(Restoring|Recovering|RecoveryPending|Suspect|Emergency)$'   { return 'fail'      }
        '^(?i)(Offline|Shutdown|Inaccessible)$'                            { return 'fail'      }
        default                                                             { return 'attention' }
    }
}

function Get-WorstDatabaseStatus {
    <#
    .SYNOPSIS
        Returns the worst status from a collection of status strings.
    
    .DESCRIPTION
        Compares status values using this rank order:
          fail (worst) > attention > pass > info (best)
        
        Returns 'info' when the input is empty or contains only 
        unrecognized values.
        
        Used by: Spoke.Database.ps1 for aggregating per-database findings
        into drive-level or instance-level summaries.
    
    .PARAMETER Statuses
        Array of status strings ('pass', 'fail', 'attention', 'info').
    
    .EXAMPLE
        Get-WorstDatabaseStatus -Statuses @('pass', 'pass', 'attention')
        
        Returns: 'attention'
    
    .EXAMPLE
        Get-WorstDatabaseStatus -Statuses @('pass', 'fail', 'pass')
        
        Returns: 'fail'
    
    .EXAMPLE
        Get-WorstDatabaseStatus -Statuses @()
        
        Returns: 'info'
    
    .NOTES
        Status rank order is defined by Get-StatusRank (private helper).
        
        If you need instance-level worst status across all checks,
        use Measure-Findings from Helpers.Engine.ps1 instead.
    #>
    [CmdletBinding()]
    param([string[]]$Statuses)

    $worst = 'info'
    foreach ($status in @($Statuses)) {
        if ((Get-StatusRank $status) -gt (Get-StatusRank $worst)) { 
            $worst = $status 
        }
    }
    return $worst
}

#endregion

# =============================================================================
#  5. BACKUP HELPERS
# =============================================================================
#region Backup Helpers

function ConvertTo-BackupAge {
    <#
    .SYNOPSIS
        Formats a backup timestamp as a human-readable age string.
    
    .DESCRIPTION
        Converts a DbaDateTime object to a friendly age format:
          - '3d ago' for days
          - '5h ago' for hours
          - '45m ago' for minutes
          - 'never' for null timestamps
          - 'unknown' on parse errors
        
        Database-specific wrapper around backup date handling.
        For general TimeSpan formatting, use Format-Duration from Helpers.Shared.ps1.
        
        Used by: Spoke.Database.ps1 backup checks
    
    .PARAMETER DbaDateTimeObject
        A DbaDateTime object (from Get-DbaDbBackupHistory) or System.DateTime.
    
    .EXAMPLE
        ConvertTo-BackupAge -DbaDateTimeObject $db.LastFullBackup
        
        Returns: '2d ago' (if backup was 2 days ago)
    
    .EXAMPLE
        ConvertTo-BackupAge -DbaDateTimeObject $null
        
        Returns: 'never'
    
    .NOTES
        Contract D: Backup age calculations
        
        Uses Get-DatabaseBackupDate to safely extract DateTime from DbaDateTime wrapper.
        
        Returns 'never' for null input instead of throwing, since null backup
        dates are expected and valid (database has never been backed up).
    #>
    [CmdletBinding()]
    param([object]$DbaDateTimeObject)
    
    $dateTime = Get-DatabaseBackupDate $DbaDateTimeObject
    if ($null -eq $dateTime) { return 'never' }
    
    try {
        $age = (Get-Date) - $dateTime
        if ($age.TotalDays  -ge 1) { return '{0:N0}d ago' -f $age.TotalDays  }
        if ($age.TotalHours -ge 1) { return '{0:N0}h ago' -f $age.TotalHours }
        return '{0:N0}m ago' -f $age.TotalMinutes
    } catch { 
        return 'unknown' 
    }
}

#endregion

# =============================================================================
#  6. DATA STRUCTURES
# =============================================================================
#region Data Structures

function Get-DatabaseDriveTag {
    <#
    .SYNOPSIS
        Returns the uppercase drive letter tag ('C:') for a local path,
        'UNC' for a network path, or $null for empty/unparseable input.
    
    .DESCRIPTION
        Extracts a drive identifier for grouping file paths by drive.
        - Local paths: 'C:', 'D:', etc.
        - UNC paths: 'UNC'
        - Invalid/empty: $null
        
        Use this for grouping files by drive in summaries.
        For the full drive root path, see Get-DatabaseDriveRoot.
        
        Used by: Spoke.Database.ps1 for drive-level file grouping
    
    .PARAMETER Path
        File path (local or UNC).
    
    .EXAMPLE
        Get-DatabaseDriveTag -Path 'C:\Data\MyDB.mdf'
        
        Returns: 'C:'
    
    .EXAMPLE
        Get-DatabaseDriveTag -Path '\\server\share\folder\file.mdf'
        
        Returns: 'UNC'
    
    .EXAMPLE
        Get-DatabaseDriveTag -Path ''
        
        Returns: $null
    
    .NOTES
        For the full UNC share root (e.g. '\\server\share'), use Get-DatabaseDriveRoot.
    #>
    [CmdletBinding()]
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    $trimmedPath = $Path.Trim()
    
    # UNC path
    if ($trimmedPath.StartsWith('\\')) { return 'UNC' }
    
    # Local drive path
    if ($trimmedPath -match '^(?<drv>[A-Za-z]):') { 
        return ($Matches.drv.ToUpperInvariant() + ':') 
    }
    
    return $null
}

function Get-DatabaseDriveRoot {
    <#
    .SYNOPSIS
        Returns the root path for a file path (drive letter or UNC share).
    
    .DESCRIPTION
        Extracts the root path for grouping or validation:
        - Local paths: 'C:\', 'D:\', etc.
        - UNC paths: '\\server\share'
        - Invalid/empty: $null
        
        Companion to Get-DatabaseDriveTag which returns just the drive letter.
        
        Used by: Drive-level file grouping and summaries
    
    .PARAMETER Path
        File path (local or UNC).
    
    .EXAMPLE
        Get-DatabaseDriveRoot -Path 'C:\Data\MyDB.mdf'
        
        Returns: 'C:\'
    
    .EXAMPLE
        Get-DatabaseDriveRoot -Path '\\server\share\folder\file.txt'
        
        Returns: '\\server\share'
    
    .EXAMPLE
        Get-DatabaseDriveRoot -Path ''
        
        Returns: $null
    
    .NOTES
        For just the drive letter tag ('C:'), use Get-DatabaseDriveTag instead.
    #>
    [CmdletBinding()]
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    $trimmedPath = $Path.Trim()
    
    # UNC path: extract \\server\share
    if ($trimmedPath.StartsWith('\\')) {
        if ($trimmedPath -match '^(?<root>\\\\[^\\]+\\[^\\]+)') {
            return $Matches.root
        }
        return $null
    }
    
    # Local path: extract C:\
    if ($trimmedPath -match '^(?<drv>[A-Za-z]):') {
        return ($Matches.drv.ToUpperInvariant() + ':\')
    }
    
    return $null
}

function ConvertTo-DatabaseLookup {
    <#
    .SYNOPSIS
        Builds a hashtable index keyed by a property value.
    
    .DESCRIPTION
        Maps the FIRST matching row for each key value to O(1) hashtable lookup.
        Useful for cross-referencing dbatools result sets (e.g., joining
        database properties with backup history by database name).
        
        Used by: Spoke.Database.ps1 for correlating Get-DbaDatabase results
        with Get-DbaDbBackupHistory results.
    
    .PARAMETER Rows
        Array of objects to index.
    
    .PARAMETER KeyProperty
        The property name to use as the hashtable key.
    
    .EXAMPLE
        $dbLookup = ConvertTo-DatabaseLookup -Rows $dbs -KeyProperty 'Name'
        $myDb = $dbLookup['MyDatabase']
        
        O(1) database lookup by name.
    
    .EXAMPLE
        $backupLookup = ConvertTo-DatabaseLookup -Rows $backups -KeyProperty 'Database'
        
        Index backup history by database name.
    
    .NOTES
        If multiple rows have the same key value, only the FIRST row is kept.
        This is intentional for "latest backup" scenarios where results are
        pre-sorted by date descending.
        
        For multiple values per key, use Group-Object instead.
        
        Rows without the key property are silently skipped (no error thrown).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Rows,
        [Parameter(Mandatory)][string]  $KeyProperty
    )

    $hashtable = @{}
    foreach ($row in @($Rows)) {
        if (-not $row) { continue }
        
        # Skip rows without the key property
        if (-not ($row.PSObject.Properties.Name -contains $KeyProperty)) { 
            continue 
        }
        
        $key = [string]($row.$KeyProperty)
        if ([string]::IsNullOrWhiteSpace($key)) { continue }
        
        # Keep only the first row for each key
        if (-not $hashtable.ContainsKey($key)) { 
            $hashtable[$key] = $row 
        }
    }
    return $hashtable
}

#endregion