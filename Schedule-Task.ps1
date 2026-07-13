# ==============================================================================
# Variables
# ==============================================================================
$TaskName   = "<Qualys_Automation_Workstation>"
$ScriptPath   = "<path>\Automation.ps1"
$TargetMode   = "<Workstation>"  
$RunTime      = "<2:00AM>"
$TargetDomain = "<CONTOSO>"
$ServiceUser  = "<user>"
# ==============================================================================

$Action = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File '$ScriptPath' -TargetMode $TargetMode"

$Trigger = New-ScheduledTaskTrigger -Daily -At $RunTime

$Settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -RunOnlyIfNetworkAvailable

$DefaultDomainUser = "$TargetDomain\$ServiceUser"
$Creds = Get-Credential -UserName $DefaultDomainUser -Message "Enter the service account password to authorize the task registration"

Register-ScheduledTask -TaskName $TaskName `
    -Action $Action `
    -Trigger $Trigger `
    -Settings $Settings `
    -User $Creds.UserName `
    -Password ($Creds.GetNetworkCredential().Password) `
    -RunLevel Highest
