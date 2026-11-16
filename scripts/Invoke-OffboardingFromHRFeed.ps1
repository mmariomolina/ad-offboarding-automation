<#
.SYNOPSIS
    Reads an HR termination feed and offboards everyone whose last day has passed.

.DESCRIPTION
    This is the "trigger" side. HR drops a CSV of termination notices
    (in real life this came from an HR system export / email-to-file flow),
    and this script works out who is due and calls Invoke-UserOffboarding.ps1
    for each of them.

    Expected CSV columns:
        EmployeeId, SamAccountName, LastDay, TicketNumber, LegalHold

    Rows are skipped if the last day is still in the future or the account is
    already disabled, so it's safe to run on a schedule (e.g. every evening).

.PARAMETER FeedPath
    Path to the HR termination CSV.

.EXAMPLE
    .\Invoke-OffboardingFromHRFeed.ps1 -FeedPath ..\sample-data\hr-terminations.csv -WhatIf
#>

#Requires -Modules ActiveDirectory

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [string] $FeedPath,
    [string] $DisabledOU = 'OU=Disabled Users,DC=contoso,DC=local',
    [string] $AuditLogPath = (Join-Path $PSScriptRoot '..\logs\offboarding-audit.csv')
)

. (Join-Path $PSScriptRoot 'lib\AuditLog.ps1')

if (-not (Test-Path -Path $FeedPath)) {
    throw "HR feed not found at $FeedPath"
}

$today = (Get-Date).Date
$rows = Import-Csv -Path $FeedPath

foreach ($row in $rows) {
    $sam = $row.SamAccountName.Trim()
    $lastDay = [datetime]::Parse($row.LastDay)

    if ($lastDay.Date -gt $today) {
        Write-Verbose "$sam last day is $($lastDay.ToString('yyyy-MM-dd')), not due yet."
        continue
    }

    $adUser = Get-ADUser -Filter "SamAccountName -eq '$sam'" -Properties Enabled
    if (-not $adUser) {
        Write-AuditRecord -LogPath $AuditLogPath -User $sam -Action 'HRFeed' -Result 'Failed' -Detail 'Not found in AD'
        Write-Warning "$sam is in the HR feed but not in AD. Check for a typo or a name change."
        continue
    }
    if (-not $adUser.Enabled) {
        Write-AuditRecord -LogPath $AuditLogPath -User $sam -Action 'HRFeed' -Result 'Skipped' -Detail 'Already disabled'
        continue
    }

    $legalHold = $row.LegalHold -match '^(yes|true|y|1)$'

    & (Join-Path $PSScriptRoot 'Invoke-UserOffboarding.ps1') `
        -Identity $sam `
        -TicketNumber $row.TicketNumber `
        -DisabledOU $DisabledOU `
        -LegalHold:$legalHold `
        -AuditLogPath $AuditLogPath `
        -WhatIf:$WhatIfPreference
}
