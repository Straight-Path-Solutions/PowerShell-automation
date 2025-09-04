# SQL Server DBA PowerShell Scripts

A collection of **PowerShell scripts** to assist SQL Server DBAs with automation, configuration, and day-to-day management tasks.  
These scripts are designed to save time, reduce human error, and streamline SQL Server administration.

## 📂 Scripts Included


### 1. [Dbatools SQL Deployment](./scripts/DBatools%20SQL%20Deployment/)
Automates the installation and initial configuration of SQL Server, including setup of service accounts, features, and basic settings.  
📁 [Script Folder](./scripts/DBatools%20SQL%20Deployment/)  
📝 [Blog Post]()

---
<!--
### 2. [Backup-Databases.ps1](./Backup-Databases)
Performs full, differential, or log backups across all databases on an instance. Includes retention options for cleanup.  
📁 [Script Folder](./Backup-Databases)  
📝 [Blog Post](https://straightpathsql.com/archives/2025/07/sql-server-backup-automation-with-powershell/)

---

### 3. [Check-SQLJobs.ps1](./Check-SQLJobs)
Checks SQL Agent job history for failures and sends alerts/reports. Helps stay on top of failed jobs without digging into SSMS.  
📁 [Script Folder](./Check-SQLJobs)  
📝 [Blog Post](https://straightpathsql.com/archives/2025/06/monitoring-sql-agent-jobs-powershell/)

---

### 4. [Monitor-DiskUsage.ps1](./Monitor-DiskUsage)
Monitors disk space and database file growth to prevent outages caused by unexpected space issues.  
📁 [Script Folder](./Monitor-DiskUsage)  
📝 [Blog Post](https://straightpathsql.com/archives/2025/05/sql-server-disk-monitoring-with-powershell/)

-->


## 🛠 Usage

Unblock downloaded scripts (recommended for security):

``` PowerShell
Get-ChildItem -Path . -Recurse -Filter *.ps1 | Unblock-File
```

Review each script’s parameters and examples before running in production.
 
## 📜 License

This repository is licensed under the [MIT License](https://mit-license.org/)
