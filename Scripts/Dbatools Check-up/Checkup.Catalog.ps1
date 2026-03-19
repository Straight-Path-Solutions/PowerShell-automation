<# ============================================================================
  CheckCatalog.ps1
  Central catalog of New-Finding base splats, organized by spoke.

  VERSION: 1.0.0
  LAST UPDATED: 2025-03-03

  STRUCTURE:
    $global:CheckCat_<Spoke> = @{
        '<dbatools cmdlet>' = @{
            <CheckKey> = @{ Label; Category; Priority; Source }
        }
    }

  USAGE:
    Pass a CheckKey's splat directly to New-Finding:
        $entrySplat = $global:CheckCat_Database['Get-DbaDatabase']['AutoShrinkEntry']
        New-Finding @entrySplat -Status 'fail' -Details '...' -SpokeFile $spoke

  CONVENTIONS:
    Rollup Keys  - Summarize all findings for a check (one per instance)
    Entry Keys   - Individual findings per object (database, file, job, etc.)
                   Named <RollupKey>Entry by convention
                   Labels end with " - Entry"

  CATEGORIES:
    - Availability    : Service state, connectivity, AG/mirroring health
    - Compliance      : Policy adherence, build compliance, audit presence
    - Configuration   : Settings, defaults, inventory
    - Maintenance     : CHECKDB, indexes, statistics, growth events
    - Performance     : Resource config, MAXDOP, wait stats, I/O
    - Recoverability  : Backups, recovery model, default paths
    - Reliability     : AutoShrink, page verify, VLF, pending reboot
    - Security        : Logins, permissions, encryption, linked servers

  PRIORITIES:
    - High   : Critical issues (security, data loss, outages)
    - Medium : Important issues (performance, best practices)
    - Low    : Nice-to-have (info, minor optimizations)
============================================================================ #>

# ===========================================================================
# DATABASE SPOKE
# Per-database configuration, health, files, compliance
# ===========================================================================
$global:CheckCat_Database = @{
    'Get-DbaDatabase' = @{
        # Database scope summary
        DbScope             = @{ Label = '[DB] Scope';                              Category = 'Configuration'; Priority = 'Low';    Source = 'Get-DbaDatabase' }
        
        # Database accessibility - rollup + entries
        DbAccessible        = @{ Label = '[DB] Accessible';                         Category = 'Availability';  Priority = 'High';   Source = 'Get-DbaDatabase' }
        DbAccessibleEntry   = @{ Label = '[DB] Inaccessible - Entry';               Category = 'Availability';  Priority = 'High';   Source = 'Get-DbaDatabase' }
        
        # Database status - rollup + entries
        DbStatus            = @{ Label = '[DB] Status';                             Category = 'Availability';  Priority = 'Medium'; Source = 'Get-DbaDatabase' }
        DbStatusEntry       = @{ Label = '[DB] Non-Online Status - Entry';          Category = 'Availability';  Priority = 'Medium'; Source = 'Get-DbaDatabase' }
        
        # Database owner inventory - rollup + entries
        DbOwner             = @{ Label = '[DB] Owner (Inventory)';                  Category = 'Configuration'; Priority = 'Low';    Source = 'Get-DbaDatabase' }
        DbOwnerEntry        = @{ Label = '[DB] Owner (Inventory) - Entry';          Category = 'Configuration'; Priority = 'Low';    Source = 'Get-DbaDatabase' }
        
        # AutoShrink - rollup + entries
        AutoShrink          = @{ Label = 'Auto Shrink Setting';                     Category = 'Reliability';   Priority = 'High';   Source = 'Get-DbaDatabase' }
        AutoShrinkEntry     = @{ Label = 'Auto Shrink ON - Entry';                  Category = 'Reliability';   Priority = 'High';   Source = 'Get-DbaDatabase' }
        
        # Page verify - rollup + entries
        PageVerify          = @{ Label = 'Page Verify (CHECKSUM)';                  Category = 'Reliability';   Priority = 'High';   Source = 'Get-DbaDatabase' }
        PageVerifyEntry     = @{ Label = 'Page Verify Non-CHECKSUM - Entry';        Category = 'Reliability';   Priority = 'High';   Source = 'Get-DbaDatabase' }
        
        # Trustworthy - rollup + entries
        Trustworthy         = @{ Label = 'TRUSTWORTHY Setting';                     Category = 'Security';      Priority = 'Medium'; Source = 'Get-DbaDatabase' }
        TrustworthyEntry    = @{ Label = 'TRUSTWORTHY ON - Entry';                  Category = 'Security';      Priority = 'Medium'; Source = 'Get-DbaDatabase' }
        
        # AutoClose - rollup + entries
        AutoClose           = @{ Label = 'Auto Close Setting';                      Category = 'Reliability';   Priority = 'High';   Source = 'Get-DbaDatabase' }
        AutoCloseEntry      = @{ Label = 'Auto Close ON - Entry';                   Category = 'Reliability';   Priority = 'High';   Source = 'Get-DbaDatabase' }
        
        # TDE encryption - rollup + entries
        TdeEnabled          = @{ Label = 'TDE / Encryption Status';                 Category = 'Security';      Priority = 'Low';    Source = 'Get-DbaDatabase' }
        TdeEnabledEntry     = @{ Label = 'TDE Not Enabled - Entry';                 Category = 'Security';      Priority = 'Low';    Source = 'Get-DbaDatabase' }
        
        # Auto update statistics - rollup + entries
        AutoUpdateStats     = @{ Label = 'Auto Update Statistics';                  Category = 'Performance';   Priority = 'Medium'; Source = 'Get-DbaDatabase' }
        AutoUpdateStatsEntry = @{ Label = 'Auto Update Stats OFF - Entry';          Category = 'Performance';   Priority = 'Medium'; Source = 'Get-DbaDatabase' }
        
        # Auto create statistics - rollup + entries
        AutoCreateStats     = @{ Label = 'Auto Create Statistics';                  Category = 'Performance';   Priority = 'Low';    Source = 'Get-DbaDatabase' }
        AutoCreateStatsEntry = @{ Label = 'Auto Create Stats OFF - Entry';          Category = 'Performance';   Priority = 'Low';    Source = 'Get-DbaDatabase' }
        
        # Service Broker - rollup + entries
        BrokerEnabled       = @{ Label = 'Service Broker State';                    Category = 'Configuration'; Priority = 'Low';    Source = 'Get-DbaDatabase' }
        BrokerEnabledEntry  = @{ Label = 'Service Broker State - Entry';            Category = 'Configuration'; Priority = 'Low';    Source = 'Get-DbaDatabase' }
        
        # Contained databases - rollup + entries
        ContainmentType     = @{ Label = 'Contained Databases';                     Category = 'Security';      Priority = 'Low';    Source = 'Get-DbaDatabase' }
        ContainmentEntry    = @{ Label = 'Contained Database - Entry';              Category = 'Security';      Priority = 'Low';    Source = 'Get-DbaDatabase' }
    }
    
    'Get-DbaLastBackup' = @{
        # Backup currency - rollup + entries for Full, Diff, Log
        BackupFull          = @{ Label = '[DB] Backups (Full)';                     Category = 'Recoverability'; Priority = 'High';  Source = 'Get-DbaLastBackup' }
        BackupFullEntry     = @{ Label = '[DB] Full Backup - Database';             Category = 'Recoverability'; Priority = 'High';  Source = 'Get-DbaLastBackup' }
        BackupDiff          = @{ Label = '[DB] Backups (Diff)';                     Category = 'Recoverability'; Priority = 'High';  Source = 'Get-DbaLastBackup' }
        BackupDiffEntry     = @{ Label = '[DB] Diff Backup - Database';             Category = 'Recoverability'; Priority = 'High';  Source = 'Get-DbaLastBackup' }
        BackupLog           = @{ Label = '[DB] Backups (Log)';                      Category = 'Recoverability'; Priority = 'High';  Source = 'Get-DbaLastBackup' }
        BackupLogEntry      = @{ Label = '[DB] Log Backup - Database';              Category = 'Recoverability'; Priority = 'High';  Source = 'Get-DbaLastBackup' }
    }
    
    'Test-DbaDbRecoveryModel' = @{
        # Recovery model compliance - rollup + entries
        RecoveryModel       = @{ Label = '[DB] Recovery Model';                     Category = 'Recoverability'; Priority = 'Medium'; Source = 'Test-DbaDbRecoveryModel' }
        RecoveryModelEntry  = @{ Label = '[DB] Recovery Model - Entry';             Category = 'Recoverability'; Priority = 'Medium'; Source = 'Test-DbaDbRecoveryModel' }
    }
    
    'Measure-DbaDbVirtualLogFile' = @{
        # VLF count - rollup + entries
        VlfCount            = @{ Label = '[DB] VLF Count';                          Category = 'Performance';   Priority = 'High';   Source = 'Measure-DbaDbVirtualLogFile' }
        VlfCountEntry       = @{ Label = '[DB] VLF Count - Entry';                  Category = 'Performance';   Priority = 'High';   Source = 'Measure-DbaDbVirtualLogFile' }
    }
    
    'Test-DbaDbCollation' = @{
        # Collation match - rollup + entries
        CollationMatch      = @{ Label = '[DB] Collation Match';                    Category = 'Reliability';   Priority = 'Low';    Source = 'Test-DbaDbCollation' }
        CollationMatchEntry = @{ Label = '[DB] Collation Mismatch - Entry';         Category = 'Reliability';   Priority = 'Low';    Source = 'Test-DbaDbCollation' }
    }
    
    'Get-DbaDbFile' = @{
        # File growth type - rollup + entries
        FileGrowthType      = @{ Label = '[DB] File Growth Type';                   Category = 'Reliability';   Priority = 'Medium'; Source = 'Get-DbaDbFile' }
        FileGrowthTypeEntry = @{ Label = '[DB] File Percent Growth - Entry';        Category = 'Reliability';   Priority = 'Medium'; Source = 'Get-DbaDbFile' }
        
        # File placement - rollup + entries
        FilePlacement       = @{ Label = '[DB] File Placement';                     Category = 'Performance';   Priority = 'Medium'; Source = 'Get-DbaDbFile' }
        FilePlacementEntry  = @{ Label = '[DB] File Placement - Entry';             Category = 'Performance';   Priority = 'Medium'; Source = 'Get-DbaDbFile' }
        
        # Multiple log files - rollup + entries
        MultipleLogFiles     = @{ Label = '[DB] Multiple Log Files';                Category = 'Performance';   Priority = 'Medium'; Source = 'Get-DbaDbFile' }
        MultipleLogFilesEntry = @{ Label = '[DB] Multiple Log Files - Entry';       Category = 'Performance';   Priority = 'Medium'; Source = 'Get-DbaDbFile' }
    }
    
    'Test-DbaMaxDop' = @{
        # Database-scoped MAXDOP - rollup + entries
        DbMaxDop            = @{ Label = '[DB] MAXDOP';                             Category = 'Performance';   Priority = 'Low';    Source = 'Test-DbaMaxDop' }
        DbMaxDopEntry       = @{ Label = '[DB] MAXDOP - Entry';                     Category = 'Performance';   Priority = 'Low';    Source = 'Test-DbaMaxDop' }
    }
    
    'Test-DbaDbCompatibility' = @{
        # Compatibility level - rollup + entries
        DbCompatibility     = @{ Label = '[DB] Compatibility Level';                Category = 'Performance';   Priority = 'Medium'; Source = 'Test-DbaDbCompatibility' }
        DbCompatibilityEntry = @{ Label = '[DB] Compatibility Level - Entry';       Category = 'Performance';   Priority = 'Medium'; Source = 'Test-DbaDbCompatibility' }
    }
    
    'Test-DbaDbOwner' = @{
        # Database owner compliance - rollup + entries
        DbOwnerCompliance       = @{ Label = '[DB] Owner Compliance';               Category = 'Security';      Priority = 'Low';    Source = 'Test-DbaDbOwner' }
        DbOwnerComplianceEntry  = @{ Label = '[DB] Owner Compliance - Entry';       Category = 'Security';      Priority = 'Low';    Source = 'Test-DbaDbOwner' }
    }
    
    'Get-DbaDbFeatureUsage' = @{
        # Feature usage - rollup + entries
        FeatureUsage        = @{ Label = '[DB] Feature Usage';                      Category = 'Compliance';    Priority = 'Low';    Source = 'Get-DbaDbFeatureUsage' }
        FeatureUsageEntry   = @{ Label = '[DB] Feature Usage - Entry';              Category = 'Compliance';    Priority = 'Low';    Source = 'Get-DbaDbFeatureUsage' }
    }
    
    'Test-DbaDbQueryStore' = @{
        # Query Store state - rollup + entries
        QueryStoreState      = @{ Label = 'Query Store Enabled / Config';           Category = 'Performance';   Priority = 'Medium'; Source = 'Test-DbaDbQueryStore' }
        QueryStoreStateEntry = @{ Label = 'Query Store Issue - Entry';              Category = 'Performance';   Priority = 'Medium'; Source = 'Test-DbaDbQueryStore' }
    }
    
    'Find-DbaDbGrowthEvent' = @{
        # Auto-growth events - rollup + entries
        GrowthEvents        = @{ Label = 'Recent Auto-Growth Events';               Category = 'Performance';   Priority = 'Low';    Source = 'Find-DbaDbGrowthEvent' }
        GrowthEventEntry    = @{ Label = 'Auto-Growth Event - Entry';               Category = 'Performance';   Priority = 'Low';    Source = 'Find-DbaDbGrowthEvent' }
    }
    
    'Get-DbaDbSpace' = @{
        # Database free space - rollup + entries
        DbFreeSpacePct      = @{ Label = 'DB Data/Log Free Space %';                Category = 'Availability';  Priority = 'Low';    Source = 'Get-DbaDbSpace' }
        DbFreeSpaceEntry    = @{ Label = 'DB Free Space Low - Entry';               Category = 'Availability';  Priority = 'Low';    Source = 'Get-DbaDbSpace' }
    }
}

# ===========================================================================
# END OF CATALOG
# ===========================================================================