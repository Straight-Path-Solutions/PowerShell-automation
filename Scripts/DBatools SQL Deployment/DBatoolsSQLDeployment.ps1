#########################################
#   Script Name: DBatools SQL Deployment
#   Purpose: Complete SQL Server host configuration, 
#            installation, update, and maintenance setup.
#
#   Created By : David Seis
#   Created On : 08/27/2025
#   Company    : Straight Path IT Solutions, LLC
#
#   Description:
#       This script automates:
#         - Windows host optimization for SQL Server
#         - SQL Server installation with predefined settings
#         - Applying the latest cumulative updates
#         - Instance-level configuration (perfomance, reliability, troubleshooting, settings, etc.)
#         - Scheduling standard ola maintenance (backups, integrity checks, index optimization)
#         - Deploying other community tools (SP_Check..., Whoisactive, First Responder toolkit)
#
#   Requirements:
#       - Administrator privileges on local and target hosts
#       - SQL Server installation media or network share
#       - dbatools PowerShell module 2.5.x+
#
#   Version    : 1.0
#########################################

$sw0 = [system.diagnostics.stopwatch]::startNew()
Clear-Host

#Region - Variables
    $ComputerName               = 'labsql3'
    $instancename               = '' <#Leave blank for a default instance, only put the name of the named instance here - NOT the Hostname\Instancename. 
        Note -                      This process assumes you aren't naming a named instance "DEFAULT", if you do plan on naming your instance 'Default' you will need to do
                                    some surgery on your side. The main issue this would cause with this process is that folder naming of a default instance is 'X:\DEFAULT\SQLdata' 
                                    etc. The named instance with the name of 'DEFAULT' would attempt to use the same paths. Avoid it if you can, fix it if you must. #>

    <# ================ DRIVE ALLOCATION WARNING - READ CAREFULLY =====================#>
    $CheckdriveAllocation       = 1 <# 1 means the process will check the allocation of the drives on the target comupter, 0 will ignore drive allocations.
                                    This process will check the drive allocation of the drives using the drive letter at the beginning of the path values in the $datapath, $logpath, and 
                                    $Temppath variables unless it is C. #>
                                    <# The variable "AutoReformatDrives" will do exactly its name - if the check drive allocation process finds disks using the drive letters from the three 
                                    variables described above that do not have an allocation size of 65536 it will attempt to REFORMAT them remotely. Drive formatting is a destructive process, 
                                    so please ensure the target is either a brand new host without any important data on it, or you are 100% certain there is nothing important on the drives.#>
    $AutoReformatDrives         = 1 # IF THIS IS "1" IT WILL ATTEMPT TO REFORMAT ANY FOUND DRIVES NOT AT 64KB ALLOCATION - THIS IS A DESTRUCTIVE PROCESS OF ANY DATA CURRENTLY ON THOSE DRIVES - BE CERTAIN!
    <# ================================================================================ #>

    $InstallSQL                 = 1
                                # These are the default paths in the instance, they will be created if they don't exist, and the backup path will be used for Ola backup jobs if you choose to install Ola.
        $Datapath               = "D:\$instancename\SQLData\"
        $Logpath                = "L:\$instancename\SQLLogs\"
        $Temppath               = "T:\$instancename\Tempdb\"
        $BackupPath             = '\\Labshare\SQLBackups\' 
        $AdminAccounts          = 'LAB\DA', "LAB\Administrator", 'LAB\SQLService' #accounts that will be added to the SQL Sysadmin role
        $SQLversion             = 2022 # changing this will do nothing unless you also change the install media.
    
    <# ================ Autoclear Directories WARNING - READ CAREFULLY =====================#>
    $AutoClearDirectories       = 1 <#  This process will use the paths above to pre-clear ALL files that exist in the data, log, tempdb and instance root directories recursively. 
                                    Instance root will be the same as the data path except SQLDATA will be replaced by SQLROOT. This was useful for my testing this script where 
                                    uninstalling sql does not get rid of mdf and ldf files for all databases, and helps reduce confusion on repeated installs. BE CERTAIN BEFORE USING 
                                    THIS AS IT IS DESTRUCTIVE! #>
    <# ================================================================================ #>


    $AutoCreateShare            = 1 <# The folder you downloaded with this script as well as the sql 2022 developer install media needs to be a network share so that the target computer 
                                    can access it. if this Variabel is set to 1, this process will automatically create a share using the folder this script is in with read access for everyone, enabling the process to be a bit 
                                    quicker. Set this variable to 0 if you want to create or use an existing share and move/ use the files already there.#>
        $ManualPathtoInstall    = '' <#leave blank unless you are creating the share manually. If so, this needs to be the network path to the setup.exe 
                                    (ex: '\\sharename\sqlextracted\setup.exe') for 2022 unless you also changed the sql version variable above. #>
        $ManualPathtoUpdate     = '' #leave blank unless you are creating the share manually. If so, this just needs to be the network path where the update files are loacated or can be downloaded to.

    $UpdateSQL                  = 1 # Set to 1 to update the instance after install, 0 to skip updating.

# Configurations
    $SetPowerPlan               = 1 # 1 automatically sets the host to high performance.
    $SetMaxDop                  = 1 # 1 automatically sets the maxdop to the recommended value based on the microsoft recommendations.
    $SetOptimizeForAdHoc        = 1 # 1 automatically sets the optimize for ad hoc workloads option.
    $SetBackupCompression       = 1 # 1 automatically sets the backup compression option.
    $SetBackupChecksum          = 1 # 1 automatically sets the backup checksum option.
    $SetCostThreshold           = 1 # 1 automatically sets the cost threshold for parallelism option to 50.
    $SetRemoteAdmin             = 1 # 1 automatically sets the Remote Admin Connections option.
    $SetMaxMemory               = 1 # 1 automatically sets the max memory option to the recommended value.
    $SetTempDBConfiguration     = 1 # 1 automatically configures the tempdb settings.
    $trace3226                  = 1 # 1 to Enable trace flag 3226 as a startup parameter
    $SetErrorlog                = 1 #set the errorlog to the $ErrorlogCount value
        $ErrorlogCount          = 52 # Set the maximum number of error log files to keep (6-99)
    $EnableAlerts               = 1 #This will enable alerts for errors 823,824,825 and issues with severity 16-25. Putting them in the error log for advanced issue identification and troubleshooting.

#Maintenance and Tools
    $ToolsAdminDatabase         = 'DB_admin'
    $DeployToolsAdminDB         = 1 #"1" Will create the database identified in $ToolsAdminDatabase if it doesn't exist

    $DeployOlaMaintenance       = 1 # 0 = False, 1 = True (set to 1 to update Ola Maintenance Solution)
        $OlaDatabase            = $ToolsAdminDatabase #the database where Ola Maintenance Solution store procedures will stored updated
                                <# Note - Ola Jobs are set to automatically install, with a weekly full, daily diff, 15 minute log backups, backups go to the $BackupPath above, cleanup
                                time of 336 hours (two weeks), logtotable enabled on the $OlaDatabase. If you want to change any of this you will need to go down to that portion 
                                of the script and modify it. #>

    $deployFirstResponder       = 1 #1 will deploy first responder toolkit to the new instance.
        $FirstResponderDatabase = 'Master' # the database where First Responder Kit stored procedures will be installed or updated.
        $RemoveSQLVersionsTable = 1 # 0 = False, 1 = True (set to 1 to drop the dbo.SQLServerVersions that is automatically created in master as part of the update.)

    $deployWhoisactive          = 1 #1 will deploy whoisactive to the new instance.
        $whoIsActiveDatabase    = 'Master' #the database where WhoisActive stored procedures will be installed or updated.

    #StraightPathTools
    $SPtoolsDeploymentDatabase  = 'Master'
    $Deploy_SP_CheckBackup      = 1 # https://github.com/Straight-Path-Solutions/sp_CheckBackup
    $Deploy_SP_CheckSecurity    = 1 # https://github.com/Straight-Path-Solutions/sp_CheckSecurity
    $Deploy_SP_CheckTempDB      = 1 # https://github.com/Straight-Path-Solutions/sp_CheckTempdb


#endregion
    
<# ==================================================================================================================== #>
<# ==================================================================================================================== #>
<# == Nothing more needs to be changed ================================================================================ #>
<# ==================================================================================================================== #>
<# ==================================================================================================================== #>
Set-DbatoolsConfig -FullName sql.connection.trustcert -Value $true -register

#Region - Prompted Variables, Derived Variables, Tests, and Prep
    $sw1 = [system.diagnostics.stopwatch]::startNew()
    # Prompted
        IF ($InstallSQL -eq 1) { 
            $serviceAccount      = $Host.UI.PromptForCredential("Engine & Agent Service Account", "Please enter the domain credentials for the SQL Engine and SQL Agent.", "Lab\SQLService", "")
            $Cred                = $Host.UI.PromptForCredential("Domain Account with permissions to run this process", "Please enter the domain credentials this process to run successfully on the remote target and with access to the network share.", "LAB\DA", "")
        }

    # Derived    
        $DerInstancePath         = $Datapath.replace('SQLData','SQLRoot').replace('\\','\DEFAULT\')
        $DerLogPath              = $Logpath.replace('\\','\DEFAULT\')
        $DerTempPath             = $Temppath.replace('\\','\DEFAULT\')
        $DerDatapath             = $Datapath.replace('\\','\DEFAULT\')

        IF ($instancename.length -gt 0 ) { $SqlInstance = "$ComputerName\$instancename"} 
        ELSE {$SqlInstance = $ComputerName }

        #collecting the path for the folder holding this script for referencing other resources in the folder.
            $ScriptPath = Switch ($Host.name){
                "Visual Studio Code Host" { split-path $psEditor.GetEditorContext().CurrentFile.Path }
                "Windows PowerShell ISE Host" {  Split-Path -Path $psISE.CurrentFile.FullPath }
                "ConsoleHost" { $PSScriptRoot }
            }

        $transcriptpath = "$ScriptPath\Transcripts\DeploymentLog_$(get-date -f MM-dd-yy)_$(get-date -f "HH.mm").log"
        Start-Transcript -path $transcriptpath 
        Write-host "PROCESS: Process Start - $(get-date -f 'MM-dd-yyyy HH:mm') sec" -ForegroundColor Green

        IF ($AutoCreateShare -eq 1) {
            # Creating a share that 'Everyone' can read so that the target computer can access the SQL Installer files during the SQL install portion, as well as the update directory during the Instance update.
            $s = New-SmbShare -Name "Automated SQL Deployment Share" -Path $ScriptPath -FullAccess "Administrators" -ReadAccess "Everyone" -Temporary | Select-Object -Property path -ExpandProperty path
            $share = $("\\$($env:COMPUTERNAME)" + $s.Substring(2)) 
            }

    # Tests
        IF ($ENV:COMPUTERNAME -ieq $ComputerName) {
            Write-host "ISSUE: The target computer name cannot be the same as the computer running this script. Please change the `$ComputerName variable to a remote computer and try again." -ForegroundColor DarkRed -BackgroundColor White
            RETURN
        }

        IF ($instancename.IndexOf('\') -ne -1) {
            Write-host "ISSUE: `$instancename variable has a '\' in it. Do not put 'HostName\InstanceName' as the value of that variable, only put Instancename" -ForegroundColor DarkRed -BackgroundColor White
            RETURN
        }

        IF ($null -eq $s -AND $autocreateshare -eq 1 -AND $InstallSQL -eq 1) {
            Write-Host "ISSUE: The share was not automatically created and SQL is set to install - no installation media is referencable and it will fail. Please resolve this before trying again." -ForegroundColor DarkRed -BackgroundColor White
            RETURN
        }

        IF ($ManualPathtoInstall.Length -eq 0 -AND $autocreateshare -eq 0 -AND $InstallSQL -eq 1) {
            Write-Host "ISSUE: The `$ManualPathtoInstall variable is empty and SQL is set to install, and auto create share is disabled. - no installation media is referencable and it will fail. Please resolve this before trying again." -ForegroundColor DarkRed -BackgroundColor White
            RETURN
        }

    #Prep
        IF ($AutoClearDirectories -eq 1) {
            Invoke-Command -ComputerName $ComputerName -ScriptBlock {
                IF(test-path $using:DerInstancePath) { Get-childitem -Path $using:DerInstancePath\*  | Remove-Item -Recurse -Confirm:$false}
                IF(test-path $using:DerLogPath)      { Get-childitem -Path $using:DerLogPath\*       | Remove-Item -Recurse -Confirm:$false}
                IF(test-path $using:DerTempPath)     { Get-childitem -Path $using:DerTempPath\*      | Remove-Item -Recurse -Confirm:$false}
                IF(test-path $using:DerDatapath)     { Get-childitem -Path $using:DerDatapath\*      | Remove-Item -Recurse -Confirm:$false}

            }
        }

    $sw1.stop()
    Write-host "PROCESS: Variables, Derived Variables, Prompted Variables, Tests, and Prep Steps complete. Elapsed Time: $($sw1.Elapsed.minutes)min $($sw1.Elapsed.seconds)sec" -ForegroundColor Green
#endregion

#Region - Drive allocation (Test-DbaDiskAllocation)
    $sw2 = [system.diagnostics.stopwatch]::startNew()

        IF ($CheckdriveAllocation -eq 1) {
        Write-host "PROCESS: Starting Drive Allocation Check - $($sw0.Elapsed.minutes)min $($sw0.Elapsed.seconds)sec" -ForegroundColor Green

            TRY  {
                $d         = "$($Datapath.Substring(0,1)):\", "$($logpath.Substring(0,1)):\", "$($Temppath.Substring(0,1)):\"
                $drives = $d | Select-Object -Unique | Where-Object { $_ -notlike "*C*"}
                
                $DrivesNeedAttn = Test-DbaDiskAllocation -computername $ComputerName | Where-object { $_.name -in $drives -and $_.isbestpractice -eq $False } | Select-Object -Property server, name, isbestpractice

                IF ($DrivesNeedAttn.count -gt 0) {
                    $DrivesNeedAttn | foreach-object {
                        Write-host "FINDING: Drive [$($_.name)] on Host [$($_.Server)] is not currently allocated to 64KB, please reformat this drive with 64KB allocation before installing SQL Server." -ForegroundColor DarkRed -BackgroundColor White
                    }
                    IF($AutoReformatDrives -eq 1) {
                        Write-Host "PROCESS: Drive Auto Reformat is enabled. Reformatting the identified drives before continuing." -ForegroundColor Green
                            $DrivesNeedAttn | Foreach-object {
                            $target = $_.name.replace(":\",'')
                            Invoke-Command -ComputerName $ComputerName -ScriptBlock {
                                Format-Volume -DriveLetter $using:target -FileSystem NTFS -Full -AllocationUnitSize 65536 -Force
                            }
                        }
                    } ELSE { Write-host "PROCESS: Stopping - please resolve the Drive Allocation issue manually or disable the check before trying again." -ForegroundColor DarkRed -BackgroundColor White; RETURN }
                } ELSE { Write-host "FINDING: No drive allocation issues found" -ForegroundColor Green }
            } CATCH { Write-HOST "ISSUE: Check Allocation process had an error - Stopping the process for troubleshooting." -ForegroundColor DarkRed -BackgroundColor White; RETURN }
        } ELSE {Write-host "PROCESS: Drive Allocation check has been disabled." -ForegroundColor DarkYellow } 

    $sw2.stop()
    Write-host "PROCESS: Drive Allocation complete. Elapsed Time: $($sw2.Elapsed.minutes)min $($sw2.Elapsed.seconds)sec" -ForegroundColor Green
#endregion

#Region - SQL Server Installation (Install-Dbainstance)
    $sw3 = [system.diagnostics.stopwatch]::startNew()

        IF ($InstallSQL = 1) {
            Write-host "PROCESS: Starting SQL install - $($sw0.Elapsed.minutes)min $($sw0.Elapsed.seconds)sec" -ForegroundColor Green
            Try {
                # Modify the ISO path based on whether the user is using the auto created share or a custom location.
                IF ($AutoCreateShare = 1) { $isopath = "$share\SQL Files\setup.exe"} 
                ELSE { $isopath = $ManualPathtoInstall }

                $config = @{
                    UpdateEnabled                   = 'False' #auto update sql as part of installation
                    USEMICROSOFTUPDATE              = 'False' #use MS updater to keep SQL Server up to date.
                    AGTSVCSTARTUPTYPE               = "Automatic" #automatic sql agent startup
                    TCPENABLED                      = "1" # Specify 0 to disable or 1 to enable the TCP/IP protocol. 
                    }

                $splat = @{
                    Credential                      = $cred
                    SQLinstance                     = $ComputerName <#  This 'SQLInstance' argument is not clearly named, it is meant to recieve the hostname that sql will 
                                                                        be installed on, not the name of the SQL Server Instance as it is in other Dbatools commands.
                                                                        Instancename handles the name of the instance and I manage it below.#>
                    Version                         = $SQLversion
                    Feature                         = 'Engine'
                    AuthenticationMode              = 'Mixed'
                    Path                            = $isopath
                    InstancePath                    = $DerInstancePath
                    Datapath                        = $DerDataPath
                    Logpath                         = $DerLogPath
                    Temppath                        = $DerTempPath
                    BackupPath                      = $BackupPath
                    AdminAccount                    = $AdminAccounts
                    SQLCollation                    = 'SQL_Latin1_General_CP1_CI_AS'
                    EngineCredential                = $ServiceAccount
                    AgentCredential                 = $ServiceAccount
                    PerformVolumeMaintenanceTasks   = $True
                    Restart                         = $True
                    Configuration                   = $config
                    Confirm                         = $false
                }

                # Modify the run for named instance installs.
                IF ($instancename.length -eq 0) 
                    { $instresult = Install-DbaInstance @Splat} 
                ELSE 
                    { $instresult = Install-DbaInstance @Splat -InstanceName $instancename}

                IF ($instresult.successful -eq $false) {
                    THROW $instresult.exitmessage
                } ELSEIF ($instresult.restarted -eq $False) {
                    Write-host "PROCESS: Install Complete - Restarting Computer." -ForegroundColor Green
                    Restart-Computer -ComputerName $ComputerName -force -wait
                }

            } CATCH { Write-Host "ISSUE: SQL Install had an error - Stopping the process for troubleshooting." -ForegroundColor DarkRed -BackgroundColor White; RETURN}
        } ELSE { Write-Host "PROCESS: SQL Install was disabled." -ForegroundColor DarkYellow }

    $sw3.stop()
    Write-host "PROCESS: SQL Install and restart complete. Elapsed Time: $($sw3.Elapsed.minutes)min $($sw3.Elapsed.seconds)sec" -ForegroundColor Green
#endregion

#Region - Update SQL Server
    $sw4 = [system.diagnostics.stopwatch]::startNew()

    IF ($UpdateSQL -eq 1) {
        Write-host "PROCESS: Starting SQL update - $($sw0.Elapsed.minutes)min $($sw0.Elapsed.seconds)sec" -ForegroundColor Green
        Try {
            IF ($AutoCreateShare = 1) { $updatepath = "$share\SQL Updates\"} 
            ELSE { $updatepath = $ManualPathtoUpdate }

            $splat = @{
                ComputerName = $ComputerName
                Restart      = $true
                Path         = $updatepath
                Confirm      = $false
                Credential   = $cred
                Download     = $True
            }

            $result = Update-DbaInstance @Splat

            If ($result.successful -eq $false) {
                THROW "Update failed"
            } ELSEIF ($result.restarted -eq $false) {
                Write-host "PROCESS: Update Complete - Restarting Computer." -ForegroundColor Green
                Restart-Computer -ComputerName $ComputerName -force -wait
            }

        } CATCH { Write-Host "ISSUE: SQL Update had an error - Stopping the process for troubleshooting." -ForegroundColor DarkRed -BackgroundColor White; RETURN}
    } ELSE { Write-Host "PROCESS: SQL Update was disabled." -ForegroundColor DarkYellow }

    $sw4.stop()
    Write-host "PROCESS: SQL Update complete. Elapsed Time: $($sw4.Elapsed.minutes)min $($sw4.Elapsed.seconds)sec" -ForegroundColor Green
#endregion

Write-host "PROCESS: Pausing processing for 3 minutes post restart before attempting to connect for configurations and maintenance (Post SQL update upgrade mode)." -ForegroundColor Green
Start-sleep -seconds 180


#Region - Configurations
    $sw5 = [system.diagnostics.stopwatch]::startNew()

    Write-host "PROCESS: Starting SQL Configurations - $($sw0.Elapsed.minutes)min $($sw0.Elapsed.seconds)sec" -ForegroundColor Green

        IF($SetPowerPlan -eq 1) {
            TRY{ 
                Set-DbaPowerPlan -ComputerName $ComputerName -Credential $cred -Confirm:$false | Out-Null
                Write-Host "PROCESS: Power Plan has been set to High Performance." -ForegroundColor Green
            } CATCH { Write-Host "ISSUE: Setting Power Plan had an error." -ForegroundColor DarkRed -BackgroundColor White }
        } ELSE { Write-Host "PROCESS: Set Power Plan was disabled." -ForegroundColor DarkYellow }

        IF($SetMaxDop -eq 1) {
            TRY {
                Test-DbaMaxDop -SqlInstance $SqlInstance -SqlCredential $Cred | Set-DbaMaxDop | Out-Null
                Write-Host "PROCESS: MaxDOP has been set to the recommended value." -ForegroundColor Green
            } CATCH { Write-Host "ISSUE: Setting MaxDOP had an error." -ForegroundColor DarkRed -BackgroundColor White }
        } ELSE { Write-Host "PROCESS: Set MaxDOP was disabled." -ForegroundColor DarkYellow }

        IF($SetOptimizeForAdHoc -eq 1) {
            TRY {
                Get-DbaSpConfigure -SqlInstance $SqlInstance -SqlCredential $Cred | Where-Object { $_.displayname -eq 'Optimize For Ad Hoc Workloads'} | Set-DbaSpConfigure -Value 1 | Out-Null
                Write-Host "PROCESS: Optimize for Ad Hoc Workloads has been enabled." -ForegroundColor Green
            } CATCH { Write-Host "ISSUE: Setting Optimize for Ad Hoc Workloads had an error." -ForegroundColor DarkRed -BackgroundColor White }
        } ELSE { Write-Host "PROCESS: Set Optimize for Ad Hoc Workloads was disabled." -ForegroundColor DarkYellow }

        IF($SetBackupCompression -eq 1) {
            TRY {
                Get-DbaSpConfigure -SqlInstance $SqlInstance -SqlCredential $Cred | Where-Object { $_.displayname -eq 'Backup Compression Default'} | Set-DbaSpConfigure -Value 1 | Out-Null
                Write-Host "PROCESS: Backup Compression has been enabled." -ForegroundColor Green
            } CATCH { Write-Host "ISSUE: Setting Backup Compression had an error." -ForegroundColor DarkRed -BackgroundColor White }
        } ELSE { Write-Host "PROCESS: Set Backup Compression was disabled." -ForegroundColor DarkYellow }

        IF($SetBackupChecksum -eq 1) {
            TRY {
                Get-DbaSpConfigure -SqlInstance $SqlInstance -SqlCredential $Cred | Where-Object { $_.displayname -eq 'Backup Checksum Default'} | Set-DbaSpConfigure -Value 1 | Out-Null
                Write-Host "PROCESS: Backup Checksum has been enabled." -ForegroundColor Green
            } CATCH { Write-Host "ISSUE: Setting Backup Checksum had an error." -ForegroundColor DarkRed -BackgroundColor White }
        } ELSE { Write-Host "PROCESS: Set Backup Checksum was disabled." -ForegroundColor DarkYellow }

        IF($SetCostThreshold -eq 1) {
            TRY {
                Get-DbaSpConfigure -SqlInstance $SqlInstance -SqlCredential $Cred | Where-Object { $_.displayname -eq 'Cost Threshold For Parallelism'} | Set-DbaSpConfigure -Value 50 | Out-Null
                Write-Host "PROCESS: Cost Threshold for Parallelism has been set to 50." -ForegroundColor Green
            } CATCH { Write-Host "ISSUE: Setting Cost Threshold for Parallelism had an error." -ForegroundColor DarkRed -BackgroundColor White }
        } ELSE { Write-Host "PROCESS: Set Cost Threshold for Parallelism was disabled." -ForegroundColor DarkYellow }

        IF($SetRemoteAdmin -eq 1) {
            TRY {
                Get-DbaSpConfigure -SqlInstance $SqlInstance -SqlCredential $Cred | Where-Object { $_.displayname -eq 'Remote Admin Connections'} | Set-DbaSpConfigure -Value 1 | Out-Null
                Write-Host "PROCESS: Remote Admin Connections has been enabled." -ForegroundColor Green
            } CATCH { Write-Host "ISSUE: Setting Remote Admin Connections had an error." -ForegroundColor DarkRed -BackgroundColor White }
        } ELSE { Write-Host "PROCESS: Set Remote Admin Connections was disabled." -ForegroundColor DarkYellow }

        IF($SetMaxMemory -eq 1) {
            Try {
                Set-DbaMaxMemory -SqlInstance $SqlInstance -SqlCredential $Cred | Out-Null
                Write-Host "PROCESS: Max Memory has been set to the recommended value." -ForegroundColor Green
            } Catch { Write-Host "ISSUE: Setting Max Memory had an error." -ForegroundColor DarkRed -BackgroundColor White }
        } ELSE { Write-Host "PROCESS: Set Max Memory was disabled." -ForegroundColor DarkYellow }

        IF($SetTempDBConfiguration -eq 1) {
            TRY {
                Set-DbaTempDbConfig -SqlInstance $SqlInstance -SqlCredential $Cred -Datafilesize 1000 | Out-Null
                Write-Host "PROCESS: TempDB configuration has been set to the recommended filecount with a default size." -ForegroundColor Green
            } CATCH { Write-Host "ISSUE: Setting TempDB configuration had an error." -ForegroundColor DarkRed -BackgroundColor White }
        } ELSE { Write-Host "PROCESS: Set TempDB configuration was disabled." -ForegroundColor DarkYellow }

        IF($trace3226 -eq 1) {
            TRY {
                Enable-DbaTraceFlag -SqlInstance $SqlInstance -SqlCredential $Cred -TraceFlag 3226 | Out-Null
                Write-Host "PROCESS: Trace Flag 3226 has been added as a startup parameter." -ForegroundColor Green
            } CATCH { Write-Host "ISSUE: Adding Trace Flag 3226 had an error." -ForegroundColor DarkRed -BackgroundColor White }
        } ELSE { Write-Host "PROCESS: Set Trace Flag 3226 was disabled." -ForegroundColor DarkYellow }

        IF($SetErrorlog -eq 1) {
            TRY {
                Set-DbaErrorLogConfig -SqlInstance $SqlInstance -SqlCredential $Cred -logcount $ErrorlogCount  | Out-Null
                Write-Host "PROCESS: Error log file count has been set to $ErrorlogCount." -ForegroundColor Green
            } CATCH { Write-Host "ISSUE: Setting Error log file count had an error." -ForegroundColor DarkRed -BackgroundColor White }
        } ELSE { Write-Host "PROCESS: Set Error log file count was disabled." -ForegroundColor DarkYellow }

        IF($enableAlerts -eq 1) {
            TRY {
                Invoke-DbaQuery -SqlInstance $SqlInstance -sqlCredential $cred -query "
                    EXEC msdb.dbo.sp_add_alert @name=N'Severity 16 Error', 
                            @message_id=0, 
                            @severity=16, 
                            @enabled=1, 
                            @delay_between_responses=0, 
                            @include_event_description_in=1;

                    EXEC msdb.dbo.sp_add_alert @name=N'Severity 17 Error', 
                            @message_id=0, 
                            @severity=17, 
                            @enabled=1, 
                            @delay_between_responses=0, 
                            @include_event_description_in=1;

                    EXEC msdb.dbo.sp_add_alert @name=N'Severity 18 Error', 
                            @message_id=0, 
                            @severity=18, 
                            @enabled=1, 
                            @delay_between_responses=0, 
                            @include_event_description_in=1;

                    EXEC msdb.dbo.sp_add_alert @name=N'Severity 19 Error', 
                            @message_id=0, 
                            @severity=19, 
                            @enabled=1, 
                            @delay_between_responses=0, 
                            @include_event_description_in=1;

                    EXEC msdb.dbo.sp_add_alert @name=N'Severity 20 Error', 
                            @message_id=0, 
                            @severity=20, 
                            @enabled=1, 
                            @delay_between_responses=0, 
                            @include_event_description_in=1;

                    EXEC msdb.dbo.sp_add_alert @name=N'Severity 21 Error', 
                            @message_id=0, 
                            @severity=21, 
                            @enabled=1, 
                            @delay_between_responses=0, 
                            @include_event_description_in=1;

                    EXEC msdb.dbo.sp_add_alert @name=N'Severity 22 Error', 
                            @message_id=0, 
                            @severity=22, 
                            @enabled=1, 
                            @delay_between_responses=0, 
                            @include_event_description_in=1;

                    EXEC msdb.dbo.sp_add_alert @name=N'Severity 23 Error', 
                            @message_id=0, 
                            @severity=23, 
                            @enabled=1, 
                            @delay_between_responses=0, 
                            @include_event_description_in=1;

                    EXEC msdb.dbo.sp_add_alert @name=N'Severity 24 Error', 
                            @message_id=0, 
                            @severity=24, 
                            @enabled=1, 
                            @delay_between_responses=0, 
                            @include_event_description_in=1;

                    EXEC msdb.dbo.sp_add_alert @name=N'Severity 25 Error', 
                            @message_id=0, 
                            @severity=25, 
                            @enabled=1, 
                            @delay_between_responses=0, 
                            @include_event_description_in=1;

                    EXEC msdb.dbo.sp_add_alert @name=N'Error 823', 
                            @message_id=823, 
                            @severity=0, 
                            @enabled=1, 
                            @delay_between_responses=60, 
                            @include_event_description_in=1,
                            @category_name=N'[Uncategorized]';

                    EXEC msdb.dbo.sp_add_alert @name=N'Error 824', 
                            @message_id=824, 
                            @severity=0, 
                            @enabled=1, 
                            @delay_between_responses=60, 
                            @include_event_description_in=1,
                            @category_name=N'[Uncategorized]'; 

                    EXEC msdb.dbo.sp_add_alert @name=N'Error 825', 
                            @message_id=825, 
                            @severity=0, 
                            @enabled=1, 
                            @delay_between_responses=0, 
                            @include_event_description_in=1;

                    GO
                "
                Write-Host "PROCESS: Alerts for Errors 823, 824, 825 and Severity 16-25 have been enabled." -ForegroundColor Green
            } CATCH { Write-Host "ISSUE: Enabling Alerts had an error." -ForegroundColor DarkRed -BackgroundColor White }
        } ELSE { Write-Host "PROCESS: Enable Alerts was disabled." -ForegroundColor DarkYellow }
        

    $sw5.stop()
    Write-host "PROCESS: Configurations complete. Elapsed Time: $($sw5.Elapsed.minutes)min $($sw5.Elapsed.seconds)sec" -ForegroundColor Green
#endregion

#Region - Maintenance & Tools
    $sw6 = [system.diagnostics.stopwatch]::startNew()

    Write-host "PROCESS: Starting Maintenance and tools - $($sw0.Elapsed.minutes)min $($sw0.Elapsed.seconds)sec" -ForegroundColor Green


        IF ($DeployToolsAdminDB -eq 1) {
            TRY {
                New-DbaDatabase -SqlInstance $SqlInstance -Name $ToolsAdminDatabase -SqlCredential $Cred | Out-Null
                Set-DbaDbOwner -SqlInstance $SqlInstance -SqlCredential $Cred | Out-Null
                Write-Host "PROCESS: [$ToolsAdminDatabase] Database has been deployed." -ForegroundColor Green
            } CATCH { Write-Host "ISSUE: Deploying [$ToolsAdminDatabase] Database had an error." -ForegroundColor DarkRed -BackgroundColor White }
        } ELSE { Write-Host "PROCESS: Deploy [$ToolsAdminDatabase] was disabled." -ForegroundColor DarkYellow }

        IF ($DeployOlaMaintenance -eq 1) {
            TRY {
                $SPLAT = @{
                    Sqlinstance         = $SqlInstance
                    Database            = $OlaDatabase
                    BackupLocation      = $BackupPath
                    Cleanuptime         = 336
                    Logtotable          = $True
                    Installjobs 	    = $True
                    AutoScheduleJobs    = ‘WeeklyFull’
                    SqlCredential       = $cred
                    Force               = $True
                }

                Install-DbaMaintenanceSolution @splat | Out-Null

                Write-Host "PROCESS: Ola Hallengren Maintenance Solution has been deployed in [$OlaDatabase]." -ForegroundColor Green
            } CATCH { Write-Host "ISSUE: Deploying/ Updating Ola Hallengren Maintenance Solution had an error." -ForegroundColor DarkRed -BackgroundColor White }
        } ELSE { Write-Host "PROCESS: Deploy Ola Maintenance was disabled." -ForegroundColor DarkYellow }

        IF ($deployFirstResponder -eq 1) {
            TRY {
                Install-DbaFirstResponderKit -SqlInstance $SqlInstance -Database $FirstResponderDatabase -SqlCredential $Cred -Force | Out-Null
                Write-Host "PROCESS: First Responder Kit has been deployed in [$FirstResponderDatabase]." -ForegroundColor Green
            } CATCH { Write-Host "ISSUE: Deploying/ Updating First Responder Kit had an error." -ForegroundColor DarkRed -BackgroundColor White }

            IF ($RemoveSQLVersionsTable -eq 1) {
                TRY {
                    Invoke-DbaQuery -SqlInstance $SqlInstance -Database $FirstResponderDatabase -SqlCredential $Cred -Query "
                        IF OBJECT_ID('dbo.SQLServerVersions') IS NOT NULL DROP TABLE dbo.SQLServerVersions" | Out-Null
                    Write-Host "PROCESS: dbo.SQLServerVersions table has been removed from Master." -ForegroundColor Green
                } CATCH { Write-Host "ISSUE: Removing dbo.SQLServerVersions table had an error." -ForegroundColor DarkRed -BackgroundColor White }
            } ELSE { Write-Host "PROCESS: Remove dbo.SQLServerVersions From [master] was disabled." -ForegroundColor DarkYellow }
        } ELSE { Write-Host "PROCESS: Deploy First Responder Kit was disabled." -ForegroundColor DarkYellow }

        IF ($deployWhoisactive -eq 1) {
            TRY {
                Install-DbaWhoIsActive -SqlInstance $SqlInstance -Database $whoIsActiveDatabase -SqlCredential $Cred -Force | Out-Null
                Write-Host "PROCESS: WhoIsActive has been deployed in [$whoIsActiveDatabase]." -ForegroundColor Green
            } CATCH { Write-Host "ISSUE: Deploying WhoIsActive had an error." -ForegroundColor DarkRed -BackgroundColor White }
        } ELSE { Write-Host "PROCESS: Deploy WhoIsActive was disabled." -ForegroundColor DarkYellow }

        IF($Deploy_SP_CheckSecurity -eq 1) {
            TRY {
                $path     = "$ScriptPath\Supporting Files\sp_checksecurity.sql"
                Invoke-WebRequest -Uri https://raw.githubusercontent.com/Straight-Path-Solutions/sp_CheckSecurity/main/sp_CheckSecurity.sql -OutFile $path
                IF ((Get-ChildItem $path) -eq 0) {
                    Write-Host "sp_checksecurity failed to download, please manually download it and put it in $path" -ForegroundColor DarkRed -BackgroundColor White
                }
                Invoke-DbaQuery -SqlInstance $SQLInstance -File $path -Database $SPtoolsDeploymentDatabase -SqlCredential $Cred | Out-Null
                Write-Host "PROCESS: SP_CheckSecurity has been deployed in [$SPtoolsDeploymentDatabase]." -ForegroundColor Green
            } CATCH { Write-host "ISSUE: SP_CheckSecurity had an error" -ForegroundColor DarkRed -BackgroundColor White }
        } ELSE { Write-Host "PROCESS: Deploy SP_CheckSecurity was disabled." -ForegroundColor DarkYellow }

        IF($Deploy_SP_CheckBackup   -eq 1) {
            TRY {
                $path     = "$ScriptPath\Supporting Files\sp_checkbackup.sql"
                Invoke-WebRequest -Uri https://raw.githubusercontent.com/Straight-Path-Solutions/sp_CheckBackup/main/sp_CheckBackup.sql -OutFile $path
                IF ((Get-ChildItem $path) -eq 0) {
                    Write-Host "sp_checkbackup failed to download, please manually download it and put it in $path" -ForegroundColor DarkRed -BackgroundColor White
                }
                Invoke-DbaQuery -SqlInstance $SQLInstance -File $path -Database $SPtoolsDeploymentDatabase  -SqlCredential $Cred | Out-Null
                Write-Host "PROCESS: SP_CheckBackup has been deployed in [$SPtoolsDeploymentDatabase]." -ForegroundColor Green
            } CATCH { Write-host "ISSUE: SP_CheckBackup had an error" -ForegroundColor DarkRed -BackgroundColor White }
        } ELSE { Write-Host "PROCESS: Deploy SP_CheckBackup was disabled." -ForegroundColor DarkYellow }

        IF($Deploy_SP_CheckTempDB   -eq 1) {
            TRY {
                $path     = "$ScriptPath\Supporting Files\sp_checktempdb.sql"
                Invoke-WebRequest -Uri https://raw.githubusercontent.com/Straight-Path-Solutions/sp_CheckTempdb/main/sp_CheckTempdb.sql -OutFile $path
                IF ((Get-ChildItem $path) -eq 0) {
                    Write-Host "sp_checktempdb failed to download, please manually download it and put it in $path" -ForegroundColor DarkRed -BackgroundColor White
                }
                Invoke-DbaQuery -SqlInstance $SQLInstance -File $path -Database $SPtoolsDeploymentDatabase -SqlCredential $Cred | Out-Null
                Write-Host "PROCESS: SP_CheckTempDB has been deployed in [$SPtoolsDeploymentDatabase]." -ForegroundColor Green
            } CATCH { Write-host "ISSUE: SP_CheckTempDB had an error" -ForegroundColor DarkRed -BackgroundColor White } 
        } ELSE { Write-Host "PROCESS: Deploy SP_CheckTempDB was disabled." -ForegroundColor DarkYellow }

    $sw6.stop()
    Write-host "PROCESS: Maintenance and Tools complete. Elapsed Time: $($sw6.Elapsed.minutes)min $($sw6.Elapsed.seconds)sec" -ForegroundColor Green
#endregion


#Region - Cleanup
    IF ($AutoCreateShare -eq 1) {
        Remove-SmbShare -Name "Automated SQL Deployment Share" -Confirm:$false
        Write-Host "PROCESS: Automated SQL Deployment Share has been removed." -ForegroundColor Green
    }

#Endregion

$sw0.stop()
Write-host "PROCESS: Deployment Script complete. Elapsed Time: $($sw0.Elapsed.hours)hrs $($sw0.Elapsed.minutes)min $($sw0.Elapsed.seconds)sec" -ForegroundColor Green
Stop-Transcript
