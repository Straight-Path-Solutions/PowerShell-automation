# SQL Server DBA PowerShell Scripts

A collection of **PowerShell scripts** to assist SQL Server DBAs with automation, configuration, and day-to-day management tasks. These scripts are designed to save time, reduce human error, and streamline SQL Server administration.

## 📂 Scripts Included


### 1. [Dbatools SQL Deployment](./Scripts/DBatools%20SQL%20Deployment/)
Automates the installation and initial configuration of SQL Server, including setup of service accounts, features, maintenance, community tools, and other important settings.  
📁 [Script Folder](./Scripts/DBatools%20SQL%20Deployment/)  
📝 [Blog Post](https://straightpathsql.com/archives/2025/09/deploy-sql-server-with-this-one-script-dbatools/)



### 2. [Dbatools Check-Up](./Scripts/Dbatools%20Check-up/)
Performs a comprehensive health check of SQL Server instances, covering configuration, performance, security, and best practices. A great way to quickly assess the state of your SQL Servers.
- 📁 [Script Folder](./Scripts/Dbatools%20Check-up/)  
- 📝 [Blog Post](https://straightpathsql.com/archives/author/davidseis/)

---
<!--
### 2. [Backup-Databases.ps1](./Backup-Databases)
Performs full, differential, or log backups across all databases on an instance. Includes retention options for cleanup.  
📁 [Script Folder](./Backup-Databases)  
📝 [Blog Post](https://straightpathsql.com/archives/author/davidseis/)

---

### 3. [Check-SQLJobs.ps1](./Check-SQLJobs)
Checks SQL Agent job history for failures and sends alerts/reports. Helps stay on top of failed jobs without digging into SSMS.  
📁 [Script Folder](./Check-SQLJobs)  
📝 [Blog Post](https://straightpathsql.com/archives/author/davidseis/)

---

### 4. [Monitor-DiskUsage.ps1](./Monitor-DiskUsage)
Monitors disk space and database file growth to prevent outages caused by unexpected space issues.  
📁 [Script Folder](./Monitor-DiskUsage)  
📝 [Blog Post](https://straightpathsql.com/archives/author/davidseis/)

-->



## 🛠 Usage

Unblock downloaded scripts (Windows typically blocks files from the internet) before running. You can unblock all scripts in a folder with this command:

``` PowerShell
Get-ChildItem -Path "C:\path\to\scripts" -Recurse -Filter *.ps1 | Unblock-File
```

Review each script’s parameters and examples before running in production.
 
## 📜 License

This repository is licensed under the [MIT License](https://mit-license.org/)
