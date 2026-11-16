<#
.SYNOPSIS
    Saves the Workday Integration System User (ISU) credential for the
    scheduled task to use.

.DESCRIPTION
    The credential is saved with Export-Clixml, which encrypts it with Windows
    DPAPI. Only the account that ran this script, on this machine, can decrypt
    it. That means you must run this AS THE SERVICE ACCOUNT, not as yourself.

    For a regular service account:
        runas /user:CONTOSO\svc-offboard powershell.exe
        then run this script in that window.

    For a gMSA (you can't log in as one), the usual trick is Sysinternals PsExec:
        psexec -i -u CONTOSO\svc-offboard$ -p ~ powershell.exe
        then run this script in that window.

    The Workday side: ask your Workday admin for an ISU with access to just
    the offboarding report, and have them expose the report as a web service.

.EXAMPLE
    .\New-WorkdayCredential.ps1
#>

[CmdletBinding()]
param(
    [string] $Path = 'C:\Scripts\ad-offboarding-automation\config\workday-isu.cred.xml'
)

Write-Host "Running as: $([Security.Principal.WindowsIdentity]::GetCurrent().Name)" -ForegroundColor Yellow
Write-Host 'This must be the scheduled task''s service account, or the task will not be able to read the file.'

$cred = Get-Credential -Message 'Workday ISU username and password'
$cred | Export-Clixml -Path $Path

Write-Host "Saved to $Path" -ForegroundColor Green
