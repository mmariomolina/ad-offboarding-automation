<#
.SYNOPSIS
    Registers the Windows scheduled task that runs the Workday offboarding
    check every 15 minutes.

.DESCRIPTION
    Run this once, as an admin, on the server that will host the automation
    (a domain-joined member server with the RSAT AD module, not a domain
    controller).

    The task runs as a dedicated service account. A group Managed Service
    Account (gMSA) is the best choice: no password to store or rotate, and it
    can only be used on the servers you allow. A regular service account works
    too; you'll be prompted for its password.

    The service account needs:
      - Delegated rights on the user OUs: disable accounts, reset passwords,
        write the description attribute, and move objects into the Disabled OU
      - Rights to manage membership of the groups it removes people from
      - "Log on as a batch job" on this server
      - Read access to the script folder, write access to the logs folder
      - Nothing more. Don't make it a Domain Admin.

.EXAMPLE
    # gMSA (note the trailing $)
    .\Register-OffboardingTask.ps1 -ServiceAccount 'CONTOSO\svc-offboard$' -ReportUrl 'https://wd5-services1.myworkday.com/ccx/service/customreport2/contoso/ISU_Offboarding/Offboarding_Report'

.EXAMPLE
    # Regular service account; prompts for the password
    .\Register-OffboardingTask.ps1 -ServiceAccount 'CONTOSO\svc-offboard' -ReportUrl '...'
#>

#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $ServiceAccount,
    [Parameter(Mandatory)] [string] $ReportUrl,
    [string] $InstallPath = 'C:\Scripts\ad-offboarding-automation',
    [string] $TaskName = 'AD Offboarding - Workday',
    [int] $IntervalMinutes = 15
)

$script = Join-Path $InstallPath 'scripts\Invoke-OffboardingFromWorkday.ps1'
if (-not (Test-Path $script)) {
    throw "Couldn't find $script. Copy the repo to $InstallPath first."
}

$action = New-ScheduledTaskAction `
    -Execute 'powershell.exe' `
    -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$script`" -ReportUrl `"$ReportUrl`"" `
    -WorkingDirectory (Join-Path $InstallPath 'scripts')

# Starts at midnight today and repeats every N minutes, indefinitely.
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).Date -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes)

$settings = New-ScheduledTaskSettingsSet `
    -MultipleInstances IgnoreNew `
    -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 30)

if ($ServiceAccount.EndsWith('$')) {
    # gMSA: Windows fetches the password from AD, so there's nothing to type in.
    $principal = New-ScheduledTaskPrincipal -UserId $ServiceAccount -LogonType Password -RunLevel Highest
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force
}
else {
    $cred = Get-Credential -UserName $ServiceAccount -Message 'Service account password'
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings `
        -User $cred.UserName -Password $cred.GetNetworkCredential().Password -RunLevel Highest -Force
}

Write-Host "Registered '$TaskName' to run every $IntervalMinutes minutes as $ServiceAccount." -ForegroundColor Green
Write-Host 'Next: create the Workday credential file as that account (see setup\New-WorkdayCredential.ps1).'
