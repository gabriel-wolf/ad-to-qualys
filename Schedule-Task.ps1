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

$Action = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$ScriptPath`" -TargetMode $TargetMode" `
    -WorkingDirectory $ScriptDirectory

$Trigger = New-ScheduledTaskTrigger `
    -Daily `
    -At $RunTime

$Settings = New-ScheduledTaskSettingsSet `
    -StartWhenAvailable `
    -RunOnlyIfNetworkAvailable `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit ([TimeSpan]::Zero)

$Creds = Get-Credential `
    -UserName $TaskUser `
    -Message "Enter the service account password"

Register-ScheduledTask `
    -TaskName $TaskName `
    -Action $Action `
    -Trigger $Trigger `
    -Settings $Settings `
    -User $Creds.UserName `
    -Password $Creds.GetNetworkCredential().Password `
    -RunLevel Highest `
    -Force
