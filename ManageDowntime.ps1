#  SCRIPT - Manage Downtime
#  Stop or start a bunch of that need stopping/starting before/after a deploy - to be used before and after and deploy that needs windows services, IIS sites/services or Scheduld tasks stopping and starting
#  Accepts a start or stop parameter 

#  AUTHOR:  Ian Manning
#  All alterations by Ian Manning unless specified.
#  2016-10-27:  INITIAL version just does Windows services
#  2016-11-01:  Updated version reads from an xml config file which defines which services and scheduled tasks need to be stopped/starter (IIS sites not yet implemented).
#  2016-11-05:  Added scheduled tasks, IIS websites
#  2016-11-08:  Added VM VSphere snapshots (only taking them)
#  2017-01-24:  initial release candidate for testing
#  2017-08-04:  correct logic so that doesn't attempt vsphere connection if there are no snapshots specified
#  2017-08-08:  fixed service/iis site names not showing in log file; made service stop/start messages less verbose (Out-Null)
#  2017-08-09:  implemented a test mode;  folder backup/copying on stop if defined in config file;  fixed vmname not appearing in log file when taking snapshots
#  2017-08-10:  MAJOR update - made the config file a parameter, added in stop/start of app pools - added <managedowntime> tags to config file and check for this tag in script.
#  2017-08-15:  fixed false positive with error checking for WinWM connection
#  2017-09-12:  Now connects to all vcentre servers and when taking the snapshot first retrives only the powered on VM:  this is to avoid errors when trying to snapshot machines managed by Site Recovery Manager
#  2017-09-14:  warns about needing an account with rights on vsphere for snapshots;  hanldes com+ via Enter-PSSession;  folder copies use /e /s with robocopy
#  2018-01-04:  added option for removal of vm snapshots via new parameter "removevmsnapshots"
#  2018-01-05:  if the remove snap shot mode is run and the config entries have a blank entry for snapshot name (.ssname) then the script will remove ALL snapshots from the specified server
#  2018-01-08:  mino bug in above fixed:  error message if the server had no snapshots
#  2018-01-19:  bug - remote sessions weren't terminating so any config that calls Enter-PSSession more than 5 times errors as this it the deault user limit for concurrent remote sessions - hence kill all remote sessions after exiting
#  2018-03-13:  added revertvmsnapshots mode - if snapshot name for a server is left blank, it will revert to most recent snapshot
#  2018-03-22:  fixed bug in removing specified snapshot - had called .ToLower() on $RemoveAllSnapshtios when it was $null
#  2018-03-23:  Changed IIS stop website code to use Invoke-Command
#  2018-03-26:  changed service stop/start to display computer name back to console; added check of scheduled task names to test mode
#  2018-03-28:  changed app pool & com+ code to use Invoke-Command;  added a powershell transcript for test mode
#  2018-04-25:  transcript introduced a bug where some of the validation steps that quit out the script didn't stop the transcript - fixed by adding if loops for test mode around each Exit statement
#  2018-05-08:  changed output of check for services so it displays the service on computername and changed the formatting so it's on different lines (reg from Keith G)
#  2018-04-10:  added rollback mode for the folder copy:  copies the entire backup folder back to the original folder location (uses robocopy /MIR)
#  2018-05-11:  for vmsnapshots added the snapshot name to the log file when taking them
#  2018-06-01:  added machine script run from and location (folder) to log file header
#  2018-07-25:  added millisecond timestamp to name of folder copy log file as quick running copies over wrote the log file
#  2018-07-31:  bug fix for Terminate-RemoteSessions - if it found no sessions it throws an error
#  2018-08-09:  corrected 'fodler' typo on line 1015
#  2018-08-13:  fixed not writing snapshot name & completed message to log when reverting;  added extra host write to explain connections to vcentre servers
#  2018-08-14:  Supressed server certifcate warnings when connecting to the VCenter using the -wa 0 paramater - Dan K
#  2018-12-21:  added new node to xml "BannerMessage" and code to print out additional message to screen and log file if this is included and a valuie added to it
#  2019-03-25:  Upgrade to using PowerCli 6.5. THis is now a module. so changed the Import/Remove-PSSnapin lines to Import/Remove-Module.
#  2019-04-06:  removed prompt for reference, and put the managedowntime node into that variable, added email alert script has been used to me, added config file
#  2019-04-18:  swapped lines 1092 & 1093 around (addingg a banner message meant no end message in log file)
#  2019-05-10:  added /R:2 /W:2 to all the robocopies
#  2019-05-10:  added new copylevel node to xml file, and functionality to all robocopies to use it to specify depth of directories to backup/revert to. allows for much faster deployment of single files at top level by putting 1 in xml. not present or blank defaults to 99999
#  2019-05-20:  added console out saying what the folder copy/rollback is doing at each stage
#  2019-07-03:  added new option in config file section for filecopies for backupOn with values of true or false - to turn off backups where its believed we dont need them
#  2020-01-06:  F5 pool member management added for revertvmsnapshots, start and stop modes.
#  2020-01-14:  further tweaks, to include managing individal F5 pool member nodes.
#  2020-01-27:	in folder copy, added .TrimEnd('\') to current folder - fixes a robocopy bug where copy fails when called for a script with a trailing \
#  2020-03-03:  Improvement to F5 management: you must now specify a * in the poolmember name to disable all nodes (rather than omitting or leaving blank)
#  2020-06-02:  Bug found see Incident 770745. Added Import-Module F5-LTM to line 723; Added new lines 838-850 to only try enabling pools if there are any defined....
#  2020-06-16:  Fixed bug in code to check for multiple backup names; lins 420 and 421 changed

Param(
	[Parameter(Mandatory=$true,Position=1)]
	[string]$strConfigFilePath,
	[Parameter(Mandatory=$True,Position=2)]
	[ValidateSet("start","stop","test","removevmsnapshots","revertvmsnapshots","rollbackcopy")]
	[string]$mode
)

Function Terminate-RemoteSessions($TargetServer) {
	$ErrorActionPreference = "SilentlyContinue"
	$RemoteSessions = gwmi WIn32_Process -ComputerName $TargetServer | ? { $_.Name -eq "wsmprovhost.exe" }
	If (!$RemoteSessions) {
	}
	Else {
		$RemoteSessions | % {$_.Terminate() | Out-Null }
	}
	$ErrorActionPreference = "Continue"
}


Function Write-ToLogFile($message) {
	$dts = Get-Date -Format HHmm
	$computername = $_.vmname
	Add-Content -Path $strLogFilePath -Value "$dts $message" 
}

# Function to enable or disable all member nodes of an F5 load balancer pool

Function Change-LoadbalancerPoolAllMembers($loadbalancername,$poolname,$changetype,$F5DeviceGroupName,$F5cred){
	# Check there are F5 nodes in the pool and then enable or disable

			$F5Sesh = New-F5Session -LTMName $loadbalancername -LTMCredentials $F5cred -TokenLifespan 36000 -PassThru
			$poolmembers = Get-Pool -F5Session $F5Sesh -Name $poolname | Get-PoolMember
			# Disable all pool members
			If ($changetype -eq "disable") {
				$poolmembers | % { Disable-PoolMember -F5Session $F5Sesh -PoolName $poolname -Name $_.Name | Out-Null }
				Write-Host "All members in pool $poolname disabled" -BackgroundColor Red -ForegroundColor White
				Write-ToLogFile -message "All members in pool $poolname disabled"
				Sync-DeviceToGroup -F5Session $F5Sesh -GroupName $F5DeviceGroupName
			}
			Else {}
			If ($changetype -eq "enable") {
				$poolmembers | % { Enable-PoolMember -F5Session $F5Sesh -PoolName $poolname -Name $_.Name | Out-Null }
				Write-Host "All members in pool $poolname enabled" -BackgroundColor Red -ForegroundColor White
				Write-ToLogFile -message "All members in pool $poolname enabled"
				Sync-DeviceToGroup -F5Session $F5Sesh -GroupName $F5DeviceGroupName
			}
			Else {}
}

# Function to disable just a specified member node of a load balancer pool

Function Change-LoadBalancerIndividualPoolMember ($loadbalancername,$poolname,$poolmembername,$changetype,$F5DeviceGroupName,$F5cred){
	$F5Sesh = New-F5Session -LTMName $loadbalancername -LTMCredentials $F5cred -TokenLifespan 36000 -PassThru
	Switch ($changetype)
	{
		"disable" { 
			Disable-PoolMember -F5Session $f5sesh -PoolName $poolname -Name $poolmembername | Out-Null 
			Write-Host "Member disabled in pool: $poolmembername" -BackgroundColor Red -ForegroundColor White
			Write-ToLogFile -message "Member disabled in pool: $poolmembername"
			Sync-DeviceToGroup -F5Session $F5Sesh -GroupName $F5DeviceGroupName
			}
		"enable" { 
			Enable-PoolMember -F5Session $f5sesh -PoolName $poolname -Name $poolmembername | Out-Null 
			Write-Host "Member enabled in pool: $poolmembername" -BackgroundColor Red -ForegroundColor White
			Write-ToLogFile -message "Member enabled in pool: $poolmembername"
			Sync-DeviceToGroup -F5Session $F5Sesh -GroupName $F5DeviceGroupName
			}
	}
}


# ===================================================
# Define/Get some 'global' variables

# The XML Config file location
#$strConfigFilePath = ".\ManageDowntime.config" - Now a parameter fed to the script
# List of current vcentre servers
$vcentreServers =@(
        "upinfvc002.ucles.internal"
        "upinfvc003.ucles.internal"
        "spinfvc004.ucles.internal"
       "upinfvc009.ucles.internal"
        "upinfvc010.ucles.internal"
          )

# Who is running this script?
$userRunningThisScript = Get-Content env:username
#Where are they running it from?
$machineScriptRunFrom = Get-Content env:computername
$locationOfScript = $PWD

# Log file.  No trees involved.
$date = Get-Date -Format yyyyMMdd
$time = Get-Date -Format HHmmss
$datetimestamp = "$date-$time"
$strLogFilePath = ".\ManageDowntimeDeploy$datetimestamp.log"
#Transcript file for test mode path
$transcriptFile = ".\ManageDowntime_TestMode_transcript_$datetimestamp.log"

# ===================================================

# Reference text/number.  Used eg in description of the VMSnapshot.  DOn't need if running in test mode.
If ($mode -eq "test") {
	Start-Transcript -Path $transcriptFile | Out-Null
	Write-Host "                                      " -BackgroundColor Yellow -ForegroundColor Black
	Write-Host "                                      " -BackgroundColor Yellow -ForegroundColor Black
	Write-Host "Running in test mode.................." -BackgroundColor Yellow -ForegroundColor Black
	Start-Sleep -Seconds 2
	Write-Host "                                      " -BackgroundColor Yellow -ForegroundColor Black
	Write-Host "                                      " -BackgroundColor Yellow -ForegroundColor Black
}
Else {
	$deployReference = $config.targets.managedowntime
	}

# Check this is managedowntime config file by checking for the <managedowntime> node:

[xml]$config=Get-Content $strConfigFilePath
$WhatsThisFor = $config.targets.managedowntime
If (!$WhatsThisFor) {
	Write-Host "There appears to be no ManageDowntime node in the xml file, or it's blank, so it looks like you are using the wrong sort of, or the wrong config file, quitting" -ForegroundColor Red -BackgroundColor White
	Start-Sleep -Seconds 2
	Exit
	}
Else {}


# Work out what is in the config file in terms of what will need stopping/starting.
If (!$config.targets.windowsservice) {$AreThereWindowsServices = $false} Else { $AreThereWindowsServices = $true }
If (!$config.targets.scheduledtasks) {$AreThereScheduledTasks = $false} Else { $AreThereScheduledTasks = $true }
If (!$config.targets.iiswebsites) {$AreThereIISWebsites = $false} Else { $AreThereIISWebsites = $true }
If (!$config.targets.vmsnapshots) {$AreThereVMSnapshots = $false} Else { $AreThereVMSnapshots = $true }
If (!$config.targets.folders) {$AreThereFolders = $false} Else { $AreThereFolders = $true }
If (!$config.targets.iisapppools) {$AreThereIISAppPools = $false} Else { $AreThereIISAppPools = $true }
If (!$config.targets.comapps) {$AreThereCOMApps = $false} Else { $AreThereCOMApps = $true }
If (!$config.targets.bannermessages) {$AreThereBannerMessages = $false} Else { $AreThereBannerMessages = $true }
If (!$config.targets.F5LoadBalancerPools) {$AreThereF5LoadBalancerPools = $false} Else { $AreThereF5LoadBalancerPools = $true }

# ===================================================
# ///////////////////////////////////////////////////
# Config file validation
# ///////////////////////////////////////////////////
# ===================================================

$Error.Clear()

If ($AreThereBannerMessages -eq $true ) {
	$config.targets.bannermessages.target | % {
		If ( !$_.bannermessage) { $bannermessageblank++ } Else {}	
	}
}
Else {}
$bannermessageblank

If ( !$bannermessageblank -eq $false ) {
	Write-Host "Banner message section included in config file, but left blank.  Either remove the bannermessage section or add a banner message!  Quitting...." -BackgroundColor Black -ForegroundColor Red
	Start-Sleep -Seconds 2
	Exit
}
Else {}

# If running in vmsnapshot removal mode, jump over all the validation apart from that bit (just before main processing starts below)

If ($mode -eq "removevmsnapshots" -or $mode -eq "revertvmsnapshots") {
	# If run in removevmsnapshots mode, are there are snapshots in the config file?


	If ($AreThereVMSnapshots -eq $true ) {}
	Else {
		Write-Host "You've run this in the mode to remove vmsnapshots, but there are none found in the config file you specified..quitting" -ForegroundColor Cyan -BackgroundColor DarkGreen
		Start-Sleep -Seconds 2
		Exit
		}
}
	Else {

# Are there any windows services defined in the config file?
# Check for any services we can't find/reach, read them into one variable if we do find any
# Note this also checks whether any null values are present

If ( $AreThereWindowsServices -eq $true ) {

$config.targets.windowsservice.target | % { 
	$computername = $_.computername
	$servicename = $_.servicename
	$ErrorActionPreference = "SilentlyContinue"
	$service = Get-WmiObject Win32_Service -ComputerName $computername | ? { $_.Name -eq $servicename }
		If (!$service -eq $true) {
			$unknownServices = $unknownServices + $_.servicename + " on " + $computername + ","
		} Else {
	}
} 
$ErrorActionPreference = "Continue"
#  If we found any unknown/unreachable services, quit before processing with a warning

If (!$unknownServices) {} Else {
	
	Write-Host "==================================================================================================================" -ForegroundColor Black -BackgroundColor White
	Write-Host "Could not find some of the services specified in the config file, or could not contact the servers, please check spellings and service names!  If these are fine there could be a firewall block, or an issue with WMI on the remote machine." -ForegroundColor Black -BackgroundColor White
	Write-host "Script will quit in 5 seconds unless you are running in test mode.  They were:  " -ForegroundColor Black -BackgroundColor White
	Write-Host ""
	$unknownServices = $unknownServices.Split(",") 
	$unknownServices | % {
		Write-Host $_ -ForegroundColor Black -BackgroundColor White
		Write-Host ""
	}
	Write-Host "==================================================================================================================" -ForegroundColor Black -BackgroundColor White
	If ($mode -eq "test" ) {} Else {
	Start-Sleep -Seconds 5
	Exit
	}
	}
	
} # If for windows services.

# CHeck for blanks in the scheduled task section
# Check the task names specified are valid

If ( $AreThereScheduledTasks -eq $true ) {
	
	$config.targets.scheduledtasks.target | % {
		If ( !$_.computername) { $stblank++ } Else {}
		If ( !$_.scheduledtaskname) { $stblank++ } Else {}
		$queryTask = schtasks.exe /S $_.computername /QUERY /TN $_.scheduledtaskname
			If ( !$queryTask ) {
				$wrongTaskNames = $wrongTaskNames + $_.scheduledtaskname + " on " + $_.computername
			}
			Else {}
		}
}
# If there were any blanks (null values) then warn and quit

If (!$stblank) {} Else {
	Write-Host "==================================================================================================================" -ForegroundColor Black -BackgroundColor White
	Write-Host "There are some blank values in the scheduled task section of the config file.  Please correct this." -ForegroundColor Black -BackgroundColor White
	Write-host "Script will quit in 5 seconds unless you are running in test mode." -ForegroundColor Black -BackgroundColor White
	Write-Host "==================================================================================================================" -ForegroundColor Black -BackgroundColor White
	If ($mode -eq "test" ) {} Else {
	Start-Sleep -Seconds 5
	Exit
	}
	}

If (!$wrongTaskNames) {} Else {
	Write-Host "Some Scheduled Task names couldn't be found, they were: $wrongTaskNames" -ForegroundColor Black -BackgroundColor White
}

# We'll use the IIS cmdlets so will reply on WinRM to connect to remote servers
# This is for both IIS websites and app pools & com+ apps
# So need to check if we can make the connection...

# Clear errors for both checks below

$Error.Clear()

If ( $AreThereIISWebsites -eq $true -or $AreThereIISAppPools -eq $true -or $AreThereCOMApps -eq $true ) {
	$ErrorActionPreference = "SilentlyContinue"
	}
Else {}

If ( $AreThereIISWebsites -eq $true ) {
		$config.targets.iiswebsites.target | % {
			Enter-PSSession $_.computername	
			Exit-PSSession
			Terminate-RemoteSessions -TargetServer $_.computername
		} # config loop
	}
Else {}

If ( $AreThereIISAppPools -eq $true ) {
		$config.targets.iisapppools.target | % {
			Enter-PSSession $_.computername	
			Exit-PSSession
			Terminate-RemoteSessions -TargetServer $_.computername
		} # config loop
	}
	
Else {}

If ( $AreThereCOMApps -eq $true ) {
		$config.targets.comapps.target | % {
			Enter-PSSession $_.computername	
			Exit-PSSession
			Terminate-RemoteSessions -TargetServer $_.computername
		} # config loop
	}
Else {}

#  If there were errors, assume generated by Enter-PSSession so raise alert but allow to optiionally continue
$ErrorActionPreference = "Continue"

If (!$Error ) { } Else { 
	# Flag that we can't use WinWM for later
	$WinRMDoesNotConnect++
	Do {
		Write-Host "Errors encountered trying to use WinRM to connect to a server to modify IIS.  Do you wish to continue, any changes to IIS & com+ apps won't work? Y/N " -ForegroundColor Green -BackgroundColor DarkRed
		$noIISContinue = Read-Host 
		}
	Until ( $noIISContinue.ToLower() -eq "y" -or $noIISContinue -eq "n" ) 
	}
# Dont continue with the rest of the script if they choose not too

If ( $noIISContinue -eq "n" ) {
	Write-Host "Stopping script before we start..... unless you are running in test mode" -BackgroundColor Black -ForegroundColor Yellow
	If ($mode -eq "test" ) {} Else {
	Start-Sleep -Seconds 1 
	Exit
	}
	}
Else {}

#  If there are VMSnapshots specified...check for blanks in the computername or snapshot name
#  Note later on we append the date to the description so it never ends up blank

If ( $AreThereVMSnapshots -eq $true ) {
	
	Write-Host "Detected vmsnapshots specified in config file.  PLEASE Make sure the account running this has rights to logon to Vcentre AND rights to take snapshots" -ForegroundColor White -BackgroundColor Magenta
		
	$config.targets.vmsnapshots.target | % {
		If ( !$_.vmname) { $vmblank++ } Else {}
		If ( !$_.ssname) { $vmblank++ } Else {}
		}
}
# If there were any blanks (null values) then warn and quit

If (!$vmblank) {} Else {
	Write-Host "==================================================================================================================" -ForegroundColor Black -BackgroundColor White
	Write-Host "There are some blank values in the vms snapshot section of the config file.  Please correct this." -ForegroundColor Black -BackgroundColor White
	Write-host "Script will quit in 5 seconds unless you are running in test mode." -ForegroundColor Black -BackgroundColor White
	Write-Host "==================================================================================================================" -ForegroundColor Black -BackgroundColor White
	If ($mode -eq "test" ) {} Else {
	Start-Sleep -Seconds 5
	Exit
	}
	}

#  If there are folders specified, check the paths, warn and quit if any missing/can't be reached

If ( $AreThereFolders -eq $true ) {
	$config.targets.folders.target | % {
		If ( Test-Path $_.newfolder ) { } Else  {$newfolderror++ }
		If ( Test-Path $_.currentfolder ) { } Else {$currentfolderror++}
		If ( !$newfolderror ) {} Else {
			$WrongNewFolders = $WrongNewFolders + $_.newfolder
			}
		If ( !$currentfolderror ) {} Else {
			$WrongCurrentFolders = $WrongCurrentFolders + $_.currentfolder
			}
}
}

If ( $newfolderror -or $currentfolderror -ne $null ) {
	Write-Host "==================================================================================================================" -ForegroundColor Black -BackgroundColor White
	Write-Host "Some of the specified folder paths couldn't be found, they were:  "  -ForegroundColor Black -BackgroundColor White
	Write-Host "Sources:  $WrongNewFolders  "  -ForegroundColor Black -BackgroundColor White
	Write-Host "Destinations:  $WrongCurrentFolders "  -ForegroundColor Black -BackgroundColor White
	Write-Host "Script will quit in 5 seconds unless you are running in test mode."  -ForegroundColor Black -BackgroundColor White
	If ($mode -eq "test" ) {} Else {
	Start-Sleep -Seconds 5
	Exit
	}
}
Else {
	If ($mode -eq "test"){
	# Check that no backup folders have been named the same	
	$backupnamecheck = $config.targets.folders.target.backupname | Group-Object
	$backupnamecheck | % {
		If ( $_.Count -gt 1 ) { $duplicatebackupNames++ } Else {}
	}
		If ( !$duplicatebackupNames -eq $false ) {
			Write-Host "You have used the same name for two or more backup locations - this means rollbacks will overwrite. Please ensure every backupname tag is different." -ForegroundColor White -BackgroundColor Black
		}
		Else {}
	}
	Else {}
}



#  Make some checks if we've got F5 Load balancer pool references

If ( $AreThereF5LoadBalancerPools -eq $true ) {
	Import-Module F5-LTM 
	$ErrorActionPreference = "SilentlyContinue"
	
	$F5cred = Get-Credential -Message "Enter credentials with Admin rights on your F5 LBs"
	
	$config.targets.F5LoadBalancerPools.target | % {
	
	$TestSesh = New-F5Session -LTMName $_.loadbalancername -LTMCredentials $F5cred -TokenLifespan 36000 -PassThru
	
	If ( (Get-F5Status $TestSesh) -ne "ACTIVE") {
		$F5NotActiveNames = $F5NotActiveNames + $_.loadbalancername
	}
	Else {}

	If (!$TestSesh) {
		$WrongLoadBalancerNames = $WrongLoadBalancerNames + $_.loadbalancername
		}
	Else {
		$testPool = Get-Pool -F5Session $TestSesh -Name $_.poolname
		If (!$testPool) {
			$WrongPoolNames = $WrongPoolNames + $_.poolname
		}
		Else {}
	}
	# If pool members have been defined, check they exist/are named correctly
	If (!$_.poolmembername) {
	}
	Else {
		$testpoolmember = Get-Pool -F5Session $TestSesh -Name $_.poolname | Get-PoolMember -Name $_.poolmembername
		If (!$testpoolmember) {
			$WrongPoolMemberName = $WrongPoolMemberName + $_.poolmembername
		}
		Else {}
	}
}

If ( $F5NotActiveNames -ne $null ) {
	Write-Host "Some of the F5 load balancer names specified aren't the ACTIVE nodes, script will now quit. Problem nodes specified are:" -ForegroundColor Red -BackgroundColor Green
	Write-Host $F5NotActiveNames -ForegroundColor Red -BackgroundColor Green
	Exit
}

If ($WrongLoadBalancerNames -ne $null ) {
	Write-Host "Some of the F5 load balancer names couldn't be found, they are:" -ForegroundColor Red -BackgroundColor Green
	Write-Host $WrongLoadBalancerNames -ForegroundColor Red -BackgroundColor Green
}
Else {}

If ($WrongPoolNames -ne $null ) {
	Write-Host "Some of the F5 load balancer pool names couldn't be found, they are:" -ForegroundColor Red -BackgroundColor Green
	Write-Host $WrongPoolNames -ForegroundColor Red -BackgroundColor Green
}
Else {}

If ($WrongPoolMemberName -ne $null ) {
	Write-Host "Some of the F5 load balancer pool MEMBER names couldn't be found, they are:" -ForegroundColor Red -BackgroundColor Green
	Write-Host $WrongPoolMemberName -ForegroundColor Red -BackgroundColor Green
}
Else {}

$ErrorActionPreference = "Continue"
}

#  VMSNAPSHOT REMOVAL JUMP =======================
} # From whether we're running in vmsnapshot removal mode, having jumped over all the other validation

#  THIS SECTION REPEATED FROM ABOVE
#  If there are VMSnapshots specified...check for blanks in the computername or snapshot name
#  Note later on we append the date to the description so it never ends up blank

If ( $AreThereVMSnapshots -eq $true ) {
	
	Write-Host "Detected vmsnapshots specified in config file.  PLEASE Make sure the account running this has rights to logon to Vcentre AND rights to take snapshots" -ForegroundColor White -BackgroundColor Magenta
		
	$config.targets.vmsnapshots.target | % {
		If ( !$_.vmname) { $vmblank++ } Else {}
		}
}
# If there were any blanks (null values) then warn and quit

If (!$vmblank) {} Else {
	Write-Host "==================================================================================================================" -ForegroundColor Black -BackgroundColor White
	Write-Host "There are some blank SERVERNAME values in the vms snapshot section of the config file.  Please correct this." -ForegroundColor Black -BackgroundColor White
	Write-host "Script will quit in 5 seconds unless you are running in test mode." -ForegroundColor Black -BackgroundColor White
	Write-Host "==================================================================================================================" -ForegroundColor Black -BackgroundColor White
	If ($mode -eq "test" ) {} Else {
	Start-Sleep -Seconds 5
	Exit
	}
	}
#  END THIS SECTION REPEATED FROM ABOVE

# ===================================================
# ///////////////////////////////////////////////////
# Config file validation completed.....
# ///////////////////////////////////////////////////
# ===================================================

#  Are we running in test mode?  Stop here if so

If ( $mode -eq "test" ) {
	
	Write-Host "                                      " -BackgroundColor Yellow -ForegroundColor Black
	Write-Host "                                      " -BackgroundColor Yellow -ForegroundColor Black
	Write-Host "Running in test mode so stopping here.  Were there any errors?" -BackgroundColor Yellow -ForegroundColor Black
	Write-Host "If there weren't, and you got to this point everything is ok for a real run." -BackgroundColor Yellow -ForegroundColor Black
	Write-Host "A transcript was written to $transcriptFile                                      " -BackgroundColor Yellow -ForegroundColor Black
	Write-Host "                                      " -BackgroundColor Yellow -ForegroundColor Black
	Stop-Transcript | Out-Null
	Start-Sleep -Seconds 2
	Exit
}
Else {}


# ========================================================================================================================
# ------------------------------------------------------------------------------------------------------------------------
#  MAIN PROCESSING STARTS
# ------------------------------------------------------------------------------------------------------------------------
# ========================================================================================================================

# Generate log file and header

New-Item -ItemType File -Path $strLogFilePath -Value ( "Deploy started at $datetimestamp by $userRunningThisScript.  Reference given is: $deployReference") | Out-Null
Write-Host "Created log file $strLogFilePath" -BackgroundColor Yellow -ForegroundColor Black
Add-Content -Path $strLogFilePath -Value "Script was run from machine $machineScriptRunFrom in directory $locationOfScript"
Add-Content -Path $strLogFilePath -Value ""
Add-Content -Path $strLogFilePath -Value "Script was run in mode: $mode"
Add-Content -Path $strLogFilePath -Value "/\/\/\/\/\/\/\/\/\/\/\"

# ===================================================
# Check if we're running in snapshot removal mode, and remove snapshots if so
# This isn't really in the optimal place in the code, but this is because it was a very late addition and as of 2018-01-04 a full rewrite is pending
# ie I didn't think it was worth the effort changing the main body of the  processing;) - Ian Manning
# ===================================================

If ( $mode -eq "removevmsnapshots")
	{
	Write-Host "                                                                                     " -ForegroundColor Green -BackgroundColor Black
	Write-Host "                                                                                     " -ForegroundColor Green -BackgroundColor Black
	Write-Host "Running in vmsnapshot removal mode.                                                  " -ForegroundColor Green -BackgroundColor Black
	Write-Host "Note anything other than vmsnapshots in the config file will be ignored in this mode." -ForegroundColor Green -BackgroundColor Black
	Write-Host "                                                                                     " -ForegroundColor Green -BackgroundColor Black
	# Connect to vsphere...first checking for the cmdlets are installed

$ErrorActionPreference = "SilentlyContinue"
$Error.Clear()
Import-Module VMware.VimAutomation.Core
If (!$Error) {
	Write-Host "                                                                                                   " -BackgroundColor Yellow -ForegroundColor Black
	Write-Host "                                                                                                   " -BackgroundColor Yellow -ForegroundColor Black
	Write-Host "About to connect to vSphere - you'll be prompted for a username/password that has access to vSphere" -BackgroundColor Yellow -ForegroundColor Black
	Write-Host "Please disregard SSL warnings and answer 'Y' when prompted.                                        " -BackgroundColor Yellow -ForegroundColor Black
	Write-Host "                                                                                                   " -BackgroundColor Yellow -ForegroundColor Black
	Write-Host "                                                                                                   " -BackgroundColor Yellow -ForegroundColor Black
	Start-Sleep -Seconds 2 # just here so the message above is seen before the vsphere prompt appears
#	Connect-VIServer $vSphereServer | Out-Null
#   Connect to all the vcentres
	$username = Read-Host -Prompt "Enter log-in name"
	$password = Read-Host -assecurestring "Please enter your password"
	Write-Host "I'm about to connect to all the vcentre servers one by one, please be patient." -BackgroundColor Yellow -ForegroundColor Black
	$password = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($password)) 
		ForEach ($item in $vcentreServers){
			Write-Host "Connecting to $item" -BackgroundColor Magenta -ForegroundColor Black
		    Connect-VIServer -Server $item -User $username -Password $password -wa 0 | Out-Null
	    }
Clear-Variable -Name "password"
	#  Remove snapshots
	# If a config element has no snapshot name specified, this is assume to be "remove all snapshots" for that servername
	# So, in this case, warn and prompt to go ahead
	$ErrorActionPreference = "Continue"
	$config.targets.vmsnapshots.target | % {
			$vmToRemoveSnapshotFrom = Get-VM -Name $_.vmname | ? { $_.PowerState -eq "PoweredOn" }
			# if the snapshot name was left blank, warn this will mean all SSs deleted, and then set boolean of $RemoveAllSnapshots accordingly
			If ( $_.ssname -eq "" ) {
				#remove all
				Write-Host "--------------------------------------------------------------------------------------------------------------" -ForegroundColor Black -BackgroundColor DarkRed
				Write-Host "--------------------------------------------------------------------------------------------------------------" -ForegroundColor Black -BackgroundColor DarkRed
				Write-Host "--------------------------------------------------------------------------------------------------------------" -ForegroundColor Black -BackgroundColor DarkRed
				Write-Host "-------------------------------------------------------------------                                           " -ForegroundColor Black -BackgroundColor DarkRed
				Write-Host "WARNING:  about to remove ALL snapshots from $vmToRemoveSnapshotFrom :            do you want to continue Y/N?" -ForegroundColor White -BackgroundColor DarkRed
				Write-Host "--------------------------------------------------------------------------------------------------------------" -ForegroundColor Black -BackgroundColor DarkRed
				Write-Host "--------------------------------------------------------------------------------------------------------------" -ForegroundColor Black -BackgroundColor DarkRed
				Write-Host "--------------------------------------------------------------------------------------------------------------" -ForegroundColor Black -BackgroundColor DarkRed
				Write-Host "--------------------------------------------------------------------------------------------------------------" -ForegroundColor Black -BackgroundColor DarkRed
				Do {
					$RemoveAllSnapshots = Read-Host 
				}
				Until ( $RemoveAllSnapshots.ToLower() -eq "y" -or $RemoveAllSnapshots.ToLower() -eq "n" ) 
				# QUIT script if the user doesn't want to go ahead
				If ( $RemoveAllSnapshots.ToLower() -eq "n") { 
					Remove-Module VMware.VimAutomation.Core
					Write-ToLogFile -message "Script quit as user responded n to being asked whether or not to remove ALL snapshots"
					Exit
				} Else {}
			
			
			
			}
			Else {
				$snapshottoremove = Get-Snapshot -VM $vmToRemoveSnapshotFrom -Name $_.ssname
			}
			
				
			Write-Host "-------------------------------------------------------------------" -ForegroundColor Black -BackgroundColor Green
			Write-Host "-------------------------------------------------------------------" -ForegroundColor Black -BackgroundColor Green
			Write-Host "Removing VM snapshot $snapshottoremove from $vmToRemoveSnapshotFrom" -ForegroundColor Black -BackgroundColor Green
			Write-Host "-------------------------------------------------------------------" -ForegroundColor Black -BackgroundColor Green
			Write-Host "-------------------------------------------------------------------" -ForegroundColor Black -BackgroundColor Green
			If ($RemoveAllSnapshots -eq $null) {
			
				Try {
					Remove-Snapshot -Snapshot $snapshottoremove -Confirm:$false
					}
				Catch {
				$dts = Get-Date -Format HHmm
				$computername = $_.vmname
				$snapshottoremove = $_.ssname
				Write-Host "No snapshot found on $computername with name $snapshottoremove"
				Add-Content -Path $strLogFilePath -Value  "$dts No snapshot found on $_.vmname with name $snapshottoremove" 
				}
				Finally {}
			}	
			Else {
				$ErrorActionPreference="SilentlyContinue"
					$allsnapshots = Get-Snapshot -VM $vmToRemoveSnapshotFrom -Name *
					If (!$allsnapshots) {
						$dts = Get-Date -Format HHmm
						Write-Host "No snapshots were found on this server - disregard the next log message" -ForegroundColor Black -BackgroundColor Green
						Add-Content -Path $strLogFilePath -Value "$dts No snapshots were found on this server disregard the next log line"
					}
					Else {
						$allsnapshots | % { Remove-Snapshot -Snapshot $_ -Confirm:$false }
					}
			}
			
			$dts = Get-Date -Format HHmm
			$computername = $_.vmname
			$snapshottoremove = $_.ssname
			If ( $snapshottoremove -eq "" ) {
				$SSRemovalMessage = "$dts ALL VM Snapshots removed from $computername"
			}
			Else {
				$SSRemovalMessage = "$dts VM Snapshot $snapshottoremove removed from $computername"
				}
			Add-Content -Path $strLogFilePath -Value $SSRemovalMessage
			#}
		}
		#Because getting to here means we're a) running in snapshot removal mode and b) we've tried to remove some, quit before the script moves on
		Write-Host "                                      " -BackgroundColor Yellow -ForegroundColor Black
		Write-Host "                                      " -BackgroundColor Yellow -ForegroundColor Black
		Write-Host "Finished trying to remove VMSnapshots." -BackgroundColor Yellow -ForegroundColor Black
		Write-Host "                                      " -BackgroundColor Yellow -ForegroundColor Black
		Write-Host "                                      " -BackgroundColor Yellow -ForegroundColor Black
		Remove-Module VMware.VimAutomation.Core
		Exit
}
Else {
	Write-Host "Error trying to add the VSphere cmdlets to the console, please check they are installed....." -ForegroundColor Black -BackgroundColor White
	$Error
	Add-Content -Path $strLogFilePath -Value  "$dts Error trying to add the VSphere cmdlets to the console, please check they are installed.....script quit"
	Write-Host "Script will quit in 5 seconds" -ForegroundColor Black -BackgroundColor White
	Start-Sleep -Seconds 5
	Exit
}
	}
Else {} # Else from if mode -eq removevmsnapshot

# Ensure errors are back on
$Error.Clear()
$ErrorActionPreference = "Continue"

# Revert snapshots mode code

If ( $mode -eq "revertvmsnapshots")
	{
	Write-Host "                                                                                     " -ForegroundColor Green -BackgroundColor Black
	Write-Host "                                                                                     " -ForegroundColor Green -BackgroundColor Black
	Write-Host "Running in vmsnapshot REVERT mode.                                                  " -ForegroundColor Green -BackgroundColor Black
	Write-Host "Note anything other than vmsnapshots and F5 Load Balancer pools in the config file will be ignored in this mode." -ForegroundColor Green -BackgroundColor Black
	Write-Host "                                                                                     " -ForegroundColor Green -BackgroundColor Black

	# If there are load balancer pools in the config file do stuff..
	If ( $AreThereF5LoadBalancerPools -eq $true ) {
		Import-Module F5-LTM
		$config.targets.F5LoadBalancerPools.target | % {
			$PoolName = $_.poolname
			$LBName = $_.loadbalancername
			$PoolMemberName = $_.poolmembername
			$DeviceGroupName = $_.devicegroupname
			Switch ($_.poolmembername){
				"*" { Change-LoadbalancerPoolAllMembers -loadbalancername $LBName -poolname $PoolName -changetype disable -F5DeviceGroupName $DeviceGroupName -F5cred $F5cred }
				"" { Write-Host "Null value in the PoolMemberName attribute, or it wasn't included at all. If you want to disable all nodes you must put a * (star) character in the attribute. Please check the config file and try again" -ForegroundColor Red -BackgroundColor White }
				default { Change-LoadBalancerIndividualPoolMember -loadbalancername $LBName -poolname $PoolName -poolmembername $PoolMemberName -changetype disable -F5DeviceGroupName $DeviceGroupName -F5cred $F5cred}
			}
		}
	}
	Else {}
	
	# Connect to vsphere...first checking for the cmdlets are installed

$ErrorActionPreference = "SilentlyContinue"
$Error.Clear()
Import-Module VMware.VimAutomation.Core
If (!$Error) {
	Write-Host "                                                                                                   " -BackgroundColor Yellow -ForegroundColor Black
	Write-Host "                                                                                                   " -BackgroundColor Yellow -ForegroundColor Black
	Write-Host "About to connect to vSphere - you'll be prompted for a username/password that has access to vSphere" -BackgroundColor Yellow -ForegroundColor Black
	Write-Host "Please disregard SSL warnings and answer 'Y' when prompted.                                        " -BackgroundColor Yellow -ForegroundColor Black
	Write-Host "                                                                                                   " -BackgroundColor Yellow -ForegroundColor Black
	Write-Host "                                                                                                   " -BackgroundColor Yellow -ForegroundColor Black
	Start-Sleep -Seconds 2 # just here so the message above is seen before the vsphere prompt appears
#	Connect-VIServer $vSphereServer | Out-Null
#   Connect to all the vcentres
	$username = Read-Host -Prompt "Enter log-in name"
	$password = Read-Host -assecurestring "Please enter your password"
	Write-Host "I'm about to connect to all the vcentre servers one by one, please be patient." -BackgroundColor Yellow -ForegroundColor Black
	$password = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($password)) 
		ForEach ($item in $vcentreServers){
			Write-Host "Connecting to $item" -BackgroundColor Magenta -ForegroundColor Black
		    Connect-VIServer -Server $item -User $username -Password $password -wa 0 | Out-Null
	    }
Clear-Variable -Name "password"
	#  Revert snapshots
	# If a config element has no snapshot name specified, this is assume to be "revert to most recent snapshot" for that servername
	# So, in this case, warn and prompt to go ahead
	$ErrorActionPreference = "Continue"
	$config.targets.vmsnapshots.target | % {
			$vmToRevertSnapshotTo = Get-VM -Name $_.vmname | ? { $_.PowerState -eq "PoweredOn" }
			# if the snapshot name was left blank, warn this will mean revert to latest snapshot, and then set boolean of $RevertToLatestVMSnapshot accordingly
			If ( $_.ssname -eq "" ) {
				#remove all
				Write-Host "--------------------------------------------------------------------------------------------------------------" -ForegroundColor Black -BackgroundColor DarkRed
				Write-Host "--------------------------------------------------------------------------------------------------------------" -ForegroundColor Black -BackgroundColor DarkRed
				Write-Host "--------------------------------------------------------------------------------------------------------------" -ForegroundColor Black -BackgroundColor DarkRed
				Write-Host "-------------------------------------------------------------------                                           " -ForegroundColor Black -BackgroundColor DarkRed
				Write-Host "WARNING:  about to REVERT to latest snapshot of $vmToRevertSnapshotTo :            do you want to continue Y/N?" -ForegroundColor White -BackgroundColor DarkRed
				Write-Host "--------------------------------------------------------------------------------------------------------------" -ForegroundColor Black -BackgroundColor DarkRed
				Write-Host "--------------------------------------------------------------------------------------------------------------" -ForegroundColor Black -BackgroundColor DarkRed
				Write-Host "--------------------------------------------------------------------------------------------------------------" -ForegroundColor Black -BackgroundColor DarkRed
				Write-Host "--------------------------------------------------------------------------------------------------------------" -ForegroundColor Black -BackgroundColor DarkRed
				Do {
					$RevertToLatestVMSnapshot = Read-Host 
				}
				Until ( $RevertToLatestVMSnapshot.ToLower() -eq "y" -or $RevertToLatestVMSnapshot.ToLower() -eq "n" ) 
				# QUIT script if the user doesn't want to go ahead
				If ( $RevertToLatestVMSnapshot.ToLower() -eq "n") { 
					Remove-Module VMware.VimAutomation.Core
					Write-ToLogFile -message "Quit script in response to being asked whether to revert to most recent snapshot ALL snapshots"
					Write-ToLogFile -message "Script completed"
					Exit
				} Else {}
				
				If ( $RevertToLatestVMSnapshot.ToLower() -eq "y") {
					#Work out most recent snapshot, revert to that
					$MostRecentSnapshot = Get-Snapshot -VM $vmToRevertSnapshotTo | Sort-Object Created | Select-Object -Last 1
					Set-VM -VM $vmToRevertSnapshotTo -Snapshot $MostRecentSnapshot -Confirm:$false
					Write-ToLogFile -message "Reverted VM $vmToRevertSnapshotTo to snapshot $MostRecentSnapshot"
					Start-VM -VM $vmToRevertSnapshotTo -Confirm:$false
					Write-ToLogFile -message "Started up VM $vmToRevertSnapshotTo"
					Write-ToLogFile -message "Script completed"
				}
			
			
			
			} 
			Else {
				Set-VM -VM $vmToRevertSnapshotTo -Snapshot $_.ssname -Confirm:$false
				$snapshotname = $_.ssname
				Write-ToLogFile -message "Reverted VM $vmToRevertSnapshotTo to snapshot $snapshotname"
				Start-VM -VM $vmToRevertSnapshotTo -Confirm:$false
				Write-ToLogFile -message "Started up VM $vmToRevertSnapshotTo"
				Write-ToLogFile -message "Script completed"
			}
			
			$snapshotname = $_.ssname	
			Write-Host "-------------------------------------------------------------------" -ForegroundColor Black -BackgroundColor Green
			Write-Host "-------------------------------------------------------------------" -ForegroundColor Black -BackgroundColor Green
			Write-Host "Reverting VM $vmToRevertSnapshotTo to snapshot $snapshotname" -ForegroundColor Black -BackgroundColor Green
			Write-Host "-------------------------------------------------------------------" -ForegroundColor Black -BackgroundColor Green
			Write-Host "-------------------------------------------------------------------" -ForegroundColor Black -BackgroundColor Green
			
			$dts = Get-Date -Format HHmm
			$computername = $_.vmname
			$snapshottoremove = $_.ssname

			Add-Content -Path $strLogFilePath -Value $SSRemovalMessage
			#}
		}
		#Because getting to here means we're a) running in snapshot reverting mode and b) we've tried to revert some, quit before the script moves on
		Write-Host "                                      " -BackgroundColor Yellow -ForegroundColor Black
		Write-Host "                                      " -BackgroundColor Yellow -ForegroundColor Black
		Write-Host "Finished trying to revert VMSnapshots." -BackgroundColor Yellow -ForegroundColor Black
		Write-Host "                                      " -BackgroundColor Yellow -ForegroundColor Black
		Write-Host "                                      " -BackgroundColor Yellow -ForegroundColor Black
		Remove-Module VMware.VimAutomation.Core
		
		#Re-enable the load balancer nodes
	If ( $AreThereF5LoadBalancerPools -eq $true ) {
		Import-Module F5-LTM
		$config.targets.F5LoadBalancerPools.target | % {
		
			$PoolName = $_.poolname
			$LBName = $_.loadbalancername
			$PoolMemberName = $_.poolmembername
			$DeviceGroupName = $_.devicegroupname
			
			Switch ($_.poolmembername){
				"*" { Change-LoadbalancerPoolAllMembers -loadbalancername $LBName -poolname $PoolName -changetype enable -F5DeviceGroupName $DeviceGroupName -F5cred $F5cred }
				"" { Write-Host "Null value in the PoolMemberName attribute, or it wasn't included at all. If you want to disable all nodes you must put a * (star) character in the attribute. Please check the config file and try again" -ForegroundColor Red -BackgroundColor White }
				default { Change-LoadBalancerIndividualPoolMember -loadbalancername $LBName -poolname $PoolName -poolmembername $PoolMemberName -changetype enable -F5DeviceGroupName $DeviceGroupName -F5cred $F5cred}
			}
		}
	}
		#Quit as we don't want to process anything else in the config file in revertsnapshot mode
		Exit
}
Else {
	Write-Host "Error trying to add the VSphere cmdlets to the console, please check they are installed....." -ForegroundColor Black -BackgroundColor White
	$Error
	Add-Content -Path $strLogFilePath -Value  "$dts Error trying to add the VSphere cmdlets to the console, please check they are installed.....script quit"
	Write-Host "Script will quit in 5 seconds" -ForegroundColor Black -BackgroundColor White
	Start-Sleep -Seconds 5
	Exit
}
	}
Else {} # Else from if mode -eq revertvmsnapshots

# ===================================================
# Take snapshots if there were any in the config file
# Note there is no matching remove snapshots post deploy as it isbn't always required to remove them right away.
# ===================================================
If ( $AreThereVMSnapshots -eq $true ) {

If ($mode -eq "stop") {

# Connect to vsphere...first checking for the cmdlets are installed
$ErrorActionPreference = "SilentlyContinue"
$Error.Clear()
Import-Module VMware.VimAutomation.Core
If (!$Error) {
	Write-Host "                                                                                                   " -BackgroundColor Yellow -ForegroundColor Black
	Write-Host "                                                                                                   " -BackgroundColor Yellow -ForegroundColor Black
	Write-Host "About to connect to vSphere - you'll be prompted for a username/password that has access to vSphere" -BackgroundColor Yellow -ForegroundColor Black
	Write-Host "Please disregard SSL warnings and answer 'Y' when prompted.                                        " -BackgroundColor Yellow -ForegroundColor Black
	Write-Host "                                                                                                   " -BackgroundColor Yellow -ForegroundColor Black
	Write-Host "                                                                                                   " -BackgroundColor Yellow -ForegroundColor Black
	Start-Sleep -Seconds 2 # just here so the message above is seen before the vsphere prompt appears
#	Connect-VIServer $vSphereServer | Out-Null
#   Connect to all the vcentres
	$username = Read-Host -Prompt "Enter log-in name"
	$password = Read-Host -assecurestring "Please enter your password"
	Write-Host "I'm about to connect to all the vcentre servers one by one, please be patient." -BackgroundColor Yellow -ForegroundColor Black
	$password = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($password)) 
		ForEach ($item in $vcentreServers){
			Write-Host "Connecting to $item" -BackgroundColor Magenta -ForegroundColor Black
		    Connect-VIServer -Server $item -User $username -Password $password -wa 0 | Out-Null
	    }
Clear-Variable -Name "password"
	#  Take snapshots
	$config.targets.vmsnapshots.target | % {
			$vmtoSnapShot = Get-VM -Name $_.vmname | ? { $_.PowerState -eq "PoweredOn" }
			New-Snapshot -VM $vmtoSnapShot -Name $_.ssname -Description ( (Get-Date -Format yyyy-MM-dd ) + " Snapshot created by user $userRunningThisScript reference: " + $deployReference + " " + $_.ssdescription ) | Out-Null
			$dts = Get-Date -Format HHmm
			$computername = $_.vmname
			$ssname = $_.ssname
			Add-Content -Path $strLogFilePath -Value  "$dts VM Snapshot taken of $computername, snapshot called $ssname" 
		}
}
Else {
	Write-Host "Error trying to add the VSphere cmdlets to the console, please check they are installed....." -ForegroundColor Black -BackgroundColor White
	$Error
	Add-Content -Path $strLogFilePath -Value  "$dts Error trying to add the VSphere cmdlets to the console, please check they are installed.....script quit"
	Write-Host "Script will quit in 5 seconds" -ForegroundColor Black -BackgroundColor White
	Start-Sleep -Seconds 5
	Exit
}

If (!$Error) { } Else { 
	Write-Host "General Error encountered either trying to take snapshots, or connect to vsphere" -ForegroundColor Black -BackgroundColor White
	Add-Content -Path $strLogFilePath -Value  "$dts General Error encountered either trying to take snapshots, or connect to vsphere:  regard any success messages about snapshots with suspicion...script quit"
	Start-Sleep -Seconds 5
	Exit
}
	Remove-Module VMware.VimAutomation.Core
}# if for stop mode
Else {
#  WE don't do anything in respecrt of VMSnaphots unless the mode was start, hence nothing in this else.
}
} # If for where there vmsnapshots
Else {}

# ===================================================
# Do F5 pools if there are any in the config file
# ===================================================

If ($mode -eq "stop"){

	If ( $AreThereF5LoadBalancerPools -eq $true ) {
		$config.targets.F5LoadBalancerPools.target | % {
			$PoolName = $_.poolname
			$LBName = $_.loadbalancername
			$PoolMemberName = $_.poolmembername
			$DeviceGroupName = $_.DeviceGroupName
			Switch ($_.poolmembername){
				"*" { Change-LoadbalancerPoolAllMembers -loadbalancername $LBName -poolname $PoolName -changetype disable -F5DeviceGroupName $DeviceGroupName -F5cred $F5cred }
				"" { Write-Host "Null value in the PoolMemberName attribute, or it wasn't included at all. If you want to disable all nodes you must put a * (star) character in the attribute. Please check the config file and try again" -ForegroundColor Red -BackgroundColor White }
				default { Change-LoadBalancerIndividualPoolMember -loadbalancername $LBName -poolname $PoolName -poolmembername $PoolMemberName -changetype disable -F5DeviceGroupName $DeviceGroupName -F5cred $F5cred }
			}
		}
	}
	Else {}
}
Else {}

# ===================================================
# Do services if there were any in the config file
# ===================================================

If ( $AreThereWindowsServices -eq $true ) {

#=======================
#  If stop was specified
#=======================

If ($mode -eq "stop") {

$config.targets.windowsservice.target | % {
	$computername = $_.computername
	$servicename = $_.servicename
	$service = Get-WmiObject Win32_Service -ComputerName $computername | ? { $_.Name -eq $servicename }
	Do {
		Write-Host "Stopping service...." $service.DisplayName "...on..." $computername -ForegroundColor Green -BackgroundColor Blue
		$service.StopService() | Out-Null
		Start-Sleep -Seconds 5
		$s=Get-WmiObject Win32_Service -ComputerName $computername | ? { $_.Name -eq $servicename }
		Write-Host "                                                                                          " -ForegroundColor Green -BackgroundColor Blue
		Write-Host "Status: " $s.State " <---- if this shows anything other than Stopped, I'll keep trying...." -ForegroundColor Green -BackgroundColor Blue
		Write-Host "                                                                                          " -ForegroundColor Green -BackgroundColor Blue
	}
	Until (
		$s.State -eq "Stopped"
		)
		$dts = Get-Date -Format HHmm
		$name = $service.DisplayName
		Add-Content -Path $strLogFilePath -Value  "$dts stopped service $name on $computername"
		
} # $config.targets.windowsservice.target for stop

Clear
Write-Host "Stopped all requested windows services." -ForegroundColor Green -BackgroundColor Blue
}

#=======================
#  If start parameter was specified
#=======================

Else {

#  reverse the array of elements so we start the services up in the opposite order to starting them
$servicesReversed=$config.targets.windowsservice.target | Sort-Object -Descending

$servicesReversed | % {
	$computername = $_.computername
	$servicename = $_.servicename
	$service = Get-WmiObject Win32_Service -ComputerName $computername | ? { $_.Name -eq $servicename }
	Do {
		Write-Host "Starting service...." $service.DisplayName "...on..." $computername -ForegroundColor Green -BackgroundColor Blue
		$service.StartService() | Out-Null
		Start-Sleep -Seconds 5
		$s=Get-WmiObject Win32_Service -ComputerName $computername | ? { $_.Name -eq $servicename }
		Write-Host "                                                                                          " -ForegroundColor Green -BackgroundColor Blue
		Write-Host "Status: " $s.State " <---- if this shows anything other than Running, I'll keep trying...." -ForegroundColor Green -BackgroundColor Blue
		Write-Host "                                                                                          " -ForegroundColor Green -BackgroundColor Blue
	}
	Until (
		$s.State -eq "Running"
		)
	$dts = Get-Date -Format HHmm
	$name = $service.DisplayName
	Add-Content -Path $strLogFilePath -Value  "$dts started $name on $computername"

}
Clear
Write-Host "Started all requested windows services." -ForegroundColor Green -BackgroundColor Blue
}

} # if for whether there were any windows services in the config file
Else {} # no windows services found so continue

# =======================================================
# Do Scheduled Tasks if there were any in the config file
# =======================================================

If ( $AreThereScheduledTasks -eq $true ) {

If ($mode -eq "stop") {

$config.targets.scheduledtasks.target | % {
	
	$computername = $_.computername
	$task = $_.scheduledtaskname
	schtasks.exe /S $computername /Change /TN $task /DISABLE
		# check we got a success code
		If ( $LASTEXITCODE -eq "0" ) {
			$dts = Get-Date -Format HHmm
			Add-Content -Path $strLogFilePath -Value  "$dts disabled scheduled task $task on $computername"
		} 
		Else {
			Write-Host "Warning:  scheduled task DISABLE failed for $task on $computername :  you'll need to manually disable these tasks." -ForegroundColor Blue -BackgroundColor White
			Write-Host "If the above line doesn't give you a task or computername, the entry in the config file is probably blank." -ForegroundColor Blue -BackgroundColor White
			$dts = Get-Date -Format HHmm
			Add-Content -Path $strLogFilePath -Value  "$dts FAILED to disabled scheduled task $task on $computername"
		}
		
} #target loop
} # if for mode = stop

Else {
#
#Write-Host "Entering start scheduled tasks"
$config.targets.scheduledtasks.target | % {
	
	$computername = $_.computername
	$task = $_.scheduledtaskname
	schtasks.exe /S $computername /Change /TN $task /ENABLE
		# check we got a success code
		If ( $LASTEXITCODE -eq "0" ) {
			$dts = Get-Date -Format HHmm
			Add-Content -Path $strLogFilePath -Value  "$dts enabled scheduled task $task on $computername"
		} 
		Else {
			Write-Host "Warning:  scheduled task DISABLE failed for $task on $computername :  you'll need to manually disable these tasks." -ForegroundColor Blue -BackgroundColor White
			Write-Host "If the above line doesn't give you a task or computername, the entry in the config file is probably blank." -ForegroundColor Blue -BackgroundColor White
			$dts = Get-Date -Format HHmm
			Add-Content -Path $strLogFilePath -Value  "$dts FAILED enabling scheduled task $task on $computername"
		}

} # targets loop
} # else for mode = stop
Write-Host "Altered all requested scheduled tasks." -ForegroundColor Green -BackgroundColor Blue
}  #if for whether there were any scheduled tasks in the config file
Else {} #no sched tasks found...

# =======================================================
# Do IIS Websites if there were any in the config file
# =======================================================

If ( !$WinRMDoesNotConnect ) {
	If ( $AreThereIISWebsites -eq $true ) {

	If ( $mode -eq "stop" ) {

		$config.targets.iiswebsites.target | % {
			Invoke-Command -ComputerName $_.ComputerName -ScriptBlock { Import-Module WebAdministration; Stop-WebSite -Name $args[0] } -ArgumentList $_.iiswebsitename
			Terminate-RemoteSessions -TargetServer $_.computername
			#Remove-Module WebAdministration
			$dts = Get-Date -Format HHmm
			$name = $_.iiswebsitename
			$pc = $_.ComputerName
			Write-host "stopped IIS webSite $name on $pc" -ForegroundColor Green -BackgroundColor Blue
			Add-Content -Path $strLogFilePath -Value  "$dts stopped IIS website $name on $pc"
	
		} # loop for IIS websites
		

	} # config loop for stop
	Else {
	
		$config.targets.iiswebsites.target | % {
			Invoke-Command -ComputerName $_.ComputerName -ScriptBlock { Import-Module WebAdministration; Start-WebSite -Name $args[0] } -ArgumentList $_.iiswebsitename
			Terminate-RemoteSessions -TargetServer $_.computername
			$dts = Get-Date -Format HHmm
			$name = $_.iiswebsitename
			$pc = $_.ComputerName
			Write-host "started IIS webSite $name on $pc" -ForegroundColor Green -BackgroundColor Blue
			Add-Content -Path $strLogFilePath -Value  "$dts started IIS website $name on $pc"
		} # loop for IIS websites
		
	} # config loop for not stop (else)

}  #if for whether there were any IIS websites in the config file
Else {} #no IIS WEbsites found...
	}	
Else {
	#Win RM didn't connect so do nothing

} # If statement on whether WinWM would connect

# =======================================================
# DO IIS App pools if there were any in the config file
# =======================================================

If ( !$WinRMDoesNotConnect ) {
	If ( $AreThereIISAppPools -eq $true ) {

	If ( $mode -eq "stop" ) {

		$config.targets.iisapppools.target | % {
			Invoke-Command -ComputerName $_.ComputerName -ScriptBlock { Import-Module WebAdministration; Stop-WebAppPool -Name $args[0] } -ArgumentList $_.iisapppoolname
			Terminate-RemoteSessions -TargetServer $_.computername
			$dts = Get-Date -Format HHmm
			$name = $_.iisapppoolname
			$pc = $_.ComputerName
			Write-host "stopped IIS webAppPool $name on $pc" -ForegroundColor Green -BackgroundColor Blue
			Add-Content -Path $strLogFilePath -Value  "$dts stopped IIS webAppPool $name on $pc"
	
		} # loop for iis web app pools
	
	} # mode is stop
	
	Else {
	
		$config.targets.iisapppools.target | % {
			Invoke-Command -ComputerName $_.ComputerName -ScriptBlock { Import-Module WebAdministration; Start-WebAppPool -Name $args[0] } -ArgumentList $_.iisapppoolname
			Terminate-RemoteSessions -TargetServer $_.computername
			$dts = Get-Date -Format HHmm
			$name = $_.iisapppoolname
			$pc = $_.ComputerName
			Write-host "started IIS webAppPool $name on $pc" -ForegroundColor Green -BackgroundColor Blue
			Add-Content -Path $strLogFilePath -Value  "$dts started IIS webAppPool $name on $pc"
	
		} # loop for iis web app pools
	
	} # if the mode wasn't stop
	
	}  # if 	there were iis app pools
	
} # if for WinRm connecting.
Else {} # winRM didn't connect so do nothing

# =========================================================
# DO COM+ Applications if there were any in the config file
# =========================================================

If ( !$WinRMDoesNotConnect ) {
	
	If ( $AreThereCOMApps -eq $true ) {
	
		If ( $mode -eq "stop" ) {
		
			# Connect and shutdown com apps
			$config.targets.comapps.target | % {
			Invoke-Command -ComputerName $_.ComputerName -ScriptBlock { 
				$com = New-Object -ComObject ComAdmin.ComAdminCatalog
				$comapps=$com.GetCollection("Applications")
				$comapps.Populate()
				$comapps
				$com.ShutdownApplication($args[0])				 
			} -ArgumentList $_.comappname
			Terminate-RemoteSessions -TargetServer $_.computername
			$dts = Get-Date -Format HHmm
			$name = $_.comappname
			$pc = $_.computername
			Write-host "stopped COM+ application $name on $pc" -ForegroundColor Green -BackgroundColor Blue
			Add-Content -Path $strLogFilePath -Value  "$dts stopped COM+ application $name on $pc"
			
			} # loop for com+ apps
		
		} # if mode = stop
		
		Else {
		
			# Code for start mode (as test mode would have quit the script before this point
			$config.targets.comapps.target | % {
			Invoke-Command -ComputerName $_.ComputerName -ScriptBlock { 
				$com = New-Object -ComObject ComAdmin.ComAdminCatalog
				$comapps=$com.GetCollection("Applications")
				$comapps.Populate()
				$comapps
				$com.StartApplication($args[0])				 
			} -ArgumentList $_.comappname
			Terminate-RemoteSessions -TargetServer $_.computername
			$dts = Get-Date -Format HHmm
			$name = $_.comappname
			$pc = $_.computername
			Write-host "started COM+ application $name on $pc" -ForegroundColor Green -BackgroundColor Blue
			Add-Content -Path $strLogFilePath -Value  "$dts started COM+ application $name on $pc"
			
			} # loop for com+ apps
		
		} # Else from if mode = stop
	
	
	} # are there com apps?
	Else {} # are there com apps?

} # fromWinRmDoesnotConnect

Else {} # ELse from WinRMDOesNotConnect If
	
# =======================================================
# Do Folders if there were any in the config file
# =======================================================

If ( $AreThereFolders -eq $true ) {

	# Check that no backup folders have been named the same	
	$backupnamecheck = $config.targets.folders.target.backupname | Group-Object
	$backupnamecheck | % {
		If ( $_.Count -gt 1 ) { $duplicatebackupNames++ } Else {}
	}
		If ( !$duplicatebackupNames -eq $false ) {
			Write-Host "You have used the same name for two or more backup locations - this means rollbacks will overwrite. Please ensure every backupname tag is different." -ForegroundColor White -BackgroundColor Black
		}
		Else {}

	If ( $mode -eq "stop" ) {
	
		$config.targets.folders.target | % {
			# backup current folder to deployment folder and specified folder
			$date = Get-Date -Format yyyyMMdd
			$time = Get-Date -Format HHmm
			$milliseconds = ([Math]::Round((Get-Date).ToFileTime()/10000)).ToString()
			$datetimestamp = "$date-$time"
			$backupfolder = $_.backupname
			$backuplogfile = "$backupfolder.log"
			$copylevel = $_.copylevel
			$backupOn = $_.backupOn
			#Copy level is new addition to the config file if it isn't present, default it to 99999
			If ( !$copylevel ) { $copylevel = 99999 } Else {}
			# do a backup if BackupOn is not set to false, skip the backup if it is set to false
			If ( !$backupOn ) { $backupOn = $true } Else { }
			If ( $backupOn -ne $false ) {
				Write-Host "Backing up " $_.currentfolder.TrimEnd('\') " with copylevel $copylevel" -BackgroundColor Green -ForegroundColor Black
				Robocopy.exe $_.currentfolder.TrimEnd('\') $PWD\bu\$backupfolder /E /log:$pwd\$backuplogfile /R:2 /W:2 /LEV:$copylevel
				$dts = Get-Date -Format HHmm
				Add-Content -Path $strLogFilePath -Value  "$dts backup up existing folder - details in $backuplogfile file"
			}
			Else {} # backupOn set to $false so dont' take a backup
			# Copy new folder over the top
			$copylogfile = "copylogfile_$datetimestamp_$milliseconds.log"
			Write-Host "Copying " $_.newfolder " to " $_.currentfolder.TrimEnd('\') " with copylevel $copylevel" -BackgroundColor Green -ForegroundColor Black
			Robocopy.exe $_.newfolder $_.currentfolder.TrimEnd('\') /E /S /log:$PWD\$copylogfile /R:2 /W:2 /LEV:$copylevel
			$dts = Get-Date -Format HHmm
			Add-Content -Path $strLogFilePath -Value  "$dts copied over folder - details in $copylogfile file"
			}
	} #if mode equals stop
	Else {
		}

} # Are there folders true?

# Revert folder copies from backup if in rollbackcopy mode

If ($mode -eq "rollbackcopy" ) {
	If ($AreThereFolders -eq $false ) {
		$noFoldersForRollbackMessage = "You ran in rollbackcopy mode but there were no folders specified in the config file, quitting...."
		Write-Host $noFoldersForRollbackMessage -ForegroundColor Magenta -BackgroundColor Red
	}
	Else {
		# do roll back
			$config.targets.folders.target | % {
				$date = Get-Date -Format yyyyMMdd
				$time = Get-Date -Format HHmm
				$datetimestamp = "$date-$time"
				$rollbackFromfolder = $_.backupname
				$copylevel = $_.copylevel
				#Copy level is new addition to the config file if it isn't present, default it to 99999
				If ( !$copylevel ) { $copylevel = 99999 } Else {}
				$rollbacklogfile = "$rollbackFromfolder.ROLLBACK.log"
				If ( Test-Path "$PWD\bu\$rollbackFromfolder" ) {
				Write-Host "Folder copy rollback:  copying original of " $_.currentfolder.TrimEnd('\') " back to pre change" -BackgroundColor Green -ForegroundColor Black
				Robocopy.exe $PWD\bu\$rollbackFromfolder $_.currentfolder.TrimEnd('\') /MIR /log:$pwd\$rollbacklogfile /R:2 /W:2 /LEV:$copylevel
				$dts = Get-Date -Format HHmm
				Add-Content -Path $strLogFilePath -Value  "$dts rolledback folder copy - details in $rollbacklogfile file"
				}
				Else {
					Write-Host "No backup file found - does $PWD\bu\$rollbackFromfolder exist?"
					Add-Content -Path $strLogFilePath -Value  "$dts No backup file found - does $PWD\bu\$rollbackFromfolder exist?"
				}
			}
	}
}
Else {
	# nothing else to do if in rollbackcopy mode
}

# Enable F5 pool members if any were specified

If ($mode -eq "start"){

	If ( $AreThereF5LoadBalancerPools -eq $true ) {
		$config.targets.F5LoadBalancerPools.target | % {
			$PoolName = $_.poolname
			$LBName = $_.loadbalancername
			$PoolMemberName = $_.poolmembername
			$DeviceGroupName = $_.DeviceGroupName
			Switch ($_.poolmembername){
				"*" { Change-LoadbalancerPoolAllMembers -loadbalancername $LBName -poolname $PoolName -changetype enable -F5DeviceGroupName $DeviceGroupName -F5cred $F5cred }
				"" { Write-Host "Null value in the PoolMemberName attribute, or it wasn't included at all. If you want to disable all nodes you must put a * (star) character in the attribute. Please check the config file and try again" -ForegroundColor Red -BackgroundColor White }
				default { Change-LoadBalancerIndividualPoolMember -loadbalancername $LBName -poolname $PoolName -poolmembername $PoolMemberName -changetype enable -F5DeviceGroupName $DeviceGroupName -F5cred $F5cred }
			}
		}
	}
	Else {}
}
Else {}

	$dts = Get-Date -Format HHmm
	
If ($AreThereBannerMessages -eq $true) {
	$config.targets.bannermessages.target | % {
		$message = $_.bannermessage
		Add-Content -Path $strLogFilePath -Value "$dts $message"
		Write-Host "                                                                                                   " -BackgroundColor Yellow -ForegroundColor Black
		Write-Host "                                                                                                   " -BackgroundColor Yellow -ForegroundColor Black
		Write-Host "                                      SCRIPT HAS FINISHED RUNNING                                  " -BackgroundColor Yellow -ForegroundColor Black
		Write-Host "                                      $message                                  " -BackgroundColor Yellow -ForegroundColor Black
		Write-Host "                                                                                                   " -BackgroundColor Yellow -ForegroundColor Black
	}
}
Else {
	Add-Content -Path $strLogFilePath -Value "$dts Script completed"
	Write-Host "                                                                                                   " -BackgroundColor Yellow -ForegroundColor Black
	Write-Host "                                                                                                   " -BackgroundColor Yellow -ForegroundColor Black
	Write-Host "                                      SCRIPT HAS FINISHED RUNNING                                  " -BackgroundColor Yellow -ForegroundColor Black
	Write-Host "                                                                                                   " -BackgroundColor Yellow -ForegroundColor Black
	Write-Host "                                                                                                   " -BackgroundColor Yellow -ForegroundColor Black
}

Send-MailMessage -From manning.i@ucles.org.uk -To manning.i@ucles.org.uk -Subject "Manage downtime script run" -Attachments $strConfigFilePath,$strLogFilePath -SmtpServer smtp0.ucles.internal