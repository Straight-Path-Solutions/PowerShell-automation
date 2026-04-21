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
# HOST SPOKE
# Operating system, hardware, OS-level privileges
# ===========================================================================
$global:CheckCat_Host = @{
    'Test-DbaPowerPlan' = @{
        # Power plan compliance
        PowerPlan           = @{ Label = 'Power Plan Compliance';                   Category = 'Performance';   Priority = 'High';   Source = 'Test-DbaPowerPlan' }
    }
    
    'Get-DbaComputerSystem' = @{
        # Data prefetch marker
        DataPrefetch        = @{ Label = 'Host - Data Prefetch';                    Category = 'Configuration'; Priority = 'Low';    Source = 'Get-DbaComputerSystem' }
        
        # System state and configuration
        PendingReboot       = @{ Label = 'Pending Reboot';                          Category = 'Reliability';   Priority = 'Medium'; Source = 'Get-DbaComputerSystem' }
        VirtualMachine      = @{ Label = 'Virtual Machine Detection';               Category = 'Configuration'; Priority = 'Low';    Source = 'Get-DbaComputerSystem' }
        HyperthreadingRatio = @{ Label = 'HyperThreading Ratio';                    Category = 'Performance';   Priority = 'Low';    Source = 'Get-DbaComputerSystem' }
        NUMANodes           = @{ Label = 'NUMA Topology';                           Category = 'Performance';   Priority = 'Low';    Source = 'Get-DbaComputerSystem' }
    }
    
    'Get-CimInstance' = @{
        # Domain membership
        DomainMember        = @{ Label = 'Domain Membership';                       Category = 'Configuration'; Priority = 'Medium'; Source = 'Get-CimInstance' }
    }
    
    'Get-DbaOperatingSystem' = @{
        # OS version and inventory
        OsVersionBuild      = @{ Label = 'OS Version / Build Compliance';           Category = 'Compliance';    Priority = 'Medium'; Source = 'Get-DbaOperatingSystem' }
        OsInventory         = @{ Label = 'OS Inventory';                            Category = 'Configuration'; Priority = 'Low';    Source = 'Get-DbaOperatingSystem' }
    }
    
    'Get-DbaPrivilege' = @{
        # Instant File Initialization - rollup + entries
        InstantFileInit      = @{ Label = 'Instant File Initialization (IFI)';      Category = 'Performance';   Priority = 'Medium'; Source = 'Get-DbaPrivilege' }
        InstantFileInitEntry = @{ Label = 'Instant File Initialization (IFI) - Entry'; Category = 'Performance'; Priority = 'Medium'; Source = 'Get-DbaPrivilege' }
        
        # Lock Pages In Memory
        LockPagesInMemory    = @{ Label = 'Lock Pages In Memory (LPIM)';            Category = 'Performance';   Priority = 'Medium'; Source = 'Get-DbaPrivilege' }
        
        # Server privileges inventory - rollup + entries
        ServerPrivileges     = @{ Label = 'OS Privilege Inventory';                 Category = 'Configuration'; Priority = 'Low';    Source = 'Get-DbaPrivilege' }
        ServerPrivilegesEntry = @{ Label = 'OS Privilege Inventory - Entry';        Category = 'Configuration'; Priority = 'Low';    Source = 'Get-DbaPrivilege' }
    }
    
    'Get-DbaFirewallRule' = @{
        # Firewall rules inventory
        FirewallRules       = @{ Label = 'SQL Firewall Rules Inventory (dbatools-managed)'; Category = 'Configuration'; Priority = 'Low'; Source = 'Get-DbaFirewallRule' }
    }
}

# ===========================================================================
# INSTANCE SPOKE
# Instance-level configuration, build, sp_configure settings
# ===========================================================================
$global:CheckCat_Instance = @{
    'Test-DbaBuild' = @{
        # Data prefetch marker
        DataPrefetch      = @{ Label = 'Instance - Data prefetch';                  Category = 'Configuration'; Priority = 'Low';    Source = 'Test-DbaBuild' }
        
        # Build and version compliance
        BuildCompliance   = @{ Label = 'Build Compliance';                          Category = 'Compliance';    Priority = 'High';   Source = 'Test-DbaBuild' }
        VersionSupport    = @{ Label = 'Version / Support Status';                  Category = 'Compliance';    Priority = 'High';   Source = 'Test-DbaBuild' }
    }
    
    'Test-DbaMaxMemory' = @{
        # Max server memory
        MaxServerMemory   = @{ Label = 'Max Server Memory';                         Category = 'Performance';   Priority = 'High';   Source = 'Test-DbaMaxMemory' }
    }
    
    'Test-DbaMaxDop' = @{
        # Instance MAXDOP
        InstanceMaxDop    = @{ Label = 'Max Degree of Parallelism (DOP)';           Category = 'Performance';   Priority = 'High';   Source = 'Test-DbaMaxDop' }
    }
    
    'Test-DbaOptimizeForAdHoc' = @{
        # Optimize for ad-hoc workloads
        OptimizeForAdHoc  = @{ Label = 'Optimize for Ad-hoc Workloads';             Category = 'Performance';   Priority = 'Medium'; Source = 'Test-DbaOptimizeForAdHoc' }
    }
    
    'Get-DbaSpConfigure' = @{
        # Security-related sp_configure options
        XpCmdShell        = @{ Label = 'xp_cmdshell (Disabled)';                    Category = 'Security';      Priority = 'Medium'; Source = 'Get-DbaSpConfigure' }
        AdHocDistributed  = @{ Label = 'Ad Hoc Distributed Queries';                Category = 'Security';      Priority = 'Medium'; Source = 'Get-DbaSpConfigure' }
        OleAutomation     = @{ Label = 'OLE Automation Procedures';                 Category = 'Security';      Priority = 'Medium'; Source = 'Get-DbaSpConfigure' }
        ClrEnabled        = @{ Label = 'CLR Integration Enabled';                   Category = 'Security';      Priority = 'Medium'; Source = 'Get-DbaSpConfigure' }
        ContainedDbAuth   = @{ Label = 'Contained Database Authentication';         Category = 'Security';      Priority = 'Low';    Source = 'Get-DbaSpConfigure' }
        
        # Performance and reliability sp_configure options
        RemoteDAC         = @{ Label = 'Remote DAC Enabled';                        Category = 'Reliability';   Priority = 'Medium'; Source = 'Get-DbaSpConfigure' }
        CostThreshold     = @{ Label = 'Cost Threshold for Parallelism';            Category = 'Performance';   Priority = 'Medium'; Source = 'Get-DbaSpConfigure' }
        MaxWorkerThreads  = @{ Label = 'Max Worker Threads';                        Category = 'Performance';   Priority = 'Low';    Source = 'Get-DbaSpConfigure' }
        NetworkPacketSize = @{ Label = 'Network Packet Size';                       Category = 'Performance';   Priority = 'Low';    Source = 'Get-DbaSpConfigure' }
        FillFactor        = @{ Label = 'Fill Factor Setting';                       Category = 'Performance';   Priority = 'Low';    Source = 'Get-DbaSpConfigure' }
        BackupCompression = @{ Label = 'Backup Compression Default';                Category = 'Recoverability'; Priority = 'Medium'; Source = 'Get-DbaSpConfigure' }
        
        # sp_configure inventory - rollup + entries
        SpCfgInventory      = @{ Label = 'sp_configure Full Inventory';             Category = 'Configuration';      Priority = 'Low';    Source = 'Get-DbaSpConfigure' }
        SpCfgInventoryEntry = @{ Label = 'sp_configure Setting - Entry';            Category = 'Configuration';      Priority = 'Low';    Source = 'Get-DbaSpConfigure' }
        
        # Pending configuration changes - rollup + entries
        SpCfgPending        = @{ Label = 'sp_configure Pending Changes';            Category = 'Configuration';      Priority = 'Medium'; Source = 'Get-DbaSpConfigure' }
        SpCfgPendingEntry   = @{ Label = 'sp_configure Pending - Entry';            Category = 'Configuration';      Priority = 'Medium'; Source = 'Get-DbaSpConfigure' }
    }
    
    'Get-DbaFeature' = @{
        # Feature discovery - rollup + entries
        FeatureDiscovery      = @{ Label = 'SQL Feature Discovery';                 Category = 'Configuration'; Priority = 'Low';    Source = 'Get-DbaFeature' }
        FeatureDiscoveryEntry = @{ Label = 'SQL Feature Discovery - Entry';         Category = 'Configuration'; Priority = 'Low';    Source = 'Get-DbaFeature' }
    }
    
    'Get-DbaErrorLog' = @{
        # Error log scan - rollup + entries
        ErrorLogScan  = @{ Label = 'Error Log Scan';                                Category = 'Reliability';   Priority = 'High';   Source = 'Get-DbaErrorLog' }
        ErrorLogEntry = @{ Label = 'Error Log Entry';                               Category = 'Reliability';   Priority = 'High';   Source = 'Get-DbaErrorLog' }
    }
    
    'Get-DbaTraceFlag' = @{
        # Active trace flags
        TraceFlags        = @{ Label = 'Active Global Trace Flags';                 Category = 'Configuration'; Priority = 'Low';    Source = 'Get-DbaTraceFlag' }
    }
    
    'Get-DbaStartupParameter' = @{
        # Startup parameters (requires WMI/PowerShell Remoting, not available on Linux)
        StartupParams     = @{ Label = 'SQL Server Startup Parameters';             Category = 'Configuration'; Priority = 'Low';    Source = 'Get-DbaStartupParameter' }
    }
}

# ===========================================================================
# MAINTENANCE SPOKE
# Index health, CHECKDB, wait stats, identity usage, error log config
# ===========================================================================
$global:CheckCat_Maintenance = @{
    'Get-DbaDatabase' = @{
        # Data prefetch marker
        DataPrefetch      = @{ Label = 'Maintenance - Data prefetch (database list)'; Category = 'Maintenance'; Priority = 'Low'; Source = 'Get-DbaDatabase' }
    }
    
    'Find-DbaDbDuplicateIndex' = @{
        # Duplicate/overlapping indexes
        DuplicateIndexes  = @{ Label = 'Duplicate / Overlapping Indexes';           Category = 'Maintenance';   Priority = 'Medium'; Source = 'Find-DbaDbDuplicateIndex' }
    }
    
    'Find-DbaDbUnusedIndex' = @{
        # Unused indexes
        UnusedIndexes     = @{ Label = 'Unused Indexes';                            Category = 'Maintenance';   Priority = 'Low';    Source = 'Find-DbaDbUnusedIndex' }
    }
    
    'Find-DbaDbDisabledIndex' = @{
        # Disabled indexes
        DisabledIndexes   = @{ Label = 'Disabled Indexes';                          Category = 'Maintenance';   Priority = 'Medium'; Source = 'Find-DbaDbDisabledIndex' }
    }
    
    'Get-DbaWaitStatistic' = @{
        # Wait statistics - rollup + entries
        WaitStats         = @{ Label = 'Top Wait Statistics';                       Category = 'Performance';   Priority = 'Medium'; Source = 'Get-DbaWaitStatistic' }
        WaitStatsEntry     = @{ Label = 'Wait Statistic Entry';                      Category = 'Performance';   Priority = 'Medium'; Source = 'Get-DbaWaitStatistic' }
    }
    
    'Get-DbaDbStatistic' = @{
        StatsStaleness = @{ Label = 'Statistics Staleness'; Category = 'Maintenance'; Priority = 'Medium'; Source = 'Get-DbaDbStatistic' }
    }

    'Get-DbaLastGoodCheckDb' = @{
        # CHECKDB currency - rollup + entries
        LastGoodCheckDb      = @{ Label = 'Last Good CHECKDB (Instance-wide)';      Category = 'Recoverability'; Priority = 'High';  Source = 'Get-DbaLastGoodCheckDb' }
        LastGoodCheckDbEntry = @{ Label = 'Last Good CHECKDB - Database';           Category = 'Recoverability'; Priority = 'High';  Source = 'Get-DbaLastGoodCheckDb' }
    }
    
    'Get-DbaErrorLogConfig' = @{
        # Error log retention
        ErrorLogConfig    = @{ Label = 'Error Log Retention Configuration';         Category = 'Maintenance';   Priority = 'Low';    Source = 'Get-DbaErrorLogConfig' }
    }
    
    'Test-DbaIdentityUsage' = @{
        # Identity column usage - rollup + entries
        IdentityUsage     = @{ Label = 'Identity Column Usage';                     Category = 'Reliability';   Priority = 'Medium'; Source = 'Test-DbaIdentityUsage' }
        IdentityUsageEntry = @{ Label = 'Identity Column Usage - Entry';            Category = 'Reliability';   Priority = 'Medium'; Source = 'Test-DbaIdentityUsage' }
    }
}

# ===========================================================================
# END OF CATALOG
# ===========================================================================