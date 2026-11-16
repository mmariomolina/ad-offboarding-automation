<#
.SYNOPSIS
    Pulls the Workday offboarding report and turns off access at 5 PM local
    time on each person's last day.

.DESCRIPTION
    This is the scheduler-driven "trigger" side. It's meant to run every
    15 minutes from Task Scheduler (see setup/Register-OffboardingTask.ps1).

    Each run it:
      1. Pulls a Workday custom report exposed as a web service (RaaS) in JSON.
      2. For each worker, reads their offboarding date and work location.
      3. Maps the location to a time zone (config/location-timezones.csv) and
         works out 5:00 PM on their last day, in their local time.
      4. If that moment has passed and their AD account is still enabled,
         it calls Invoke-UserOffboarding.ps1 for them.

    Running every 15 minutes means access is cut between 5:00 and 5:15 PM
    local time. If the server was down, the next run catches up anyone missed.

    Safety checks:
      - Unknown location: the worker is skipped and logged as Failed, rather
        than guessing a time zone and cutting someone off at the wrong hour.
      - Too many people due in one run (default 25): the run stops before
        changing anything. A broken or misconfigured report should never
        mass-disable the company.

    Expected report fields (rename them in $FieldMap below to match your report):
        Employee_ID, Username, Offboarding_Date, Location, Legal_Hold (optional)

.PARAMETER ReportUrl
    The Workday RaaS URL for the custom report. ?format=json is added if missing.

.PARAMETER ReportPath
    Read the report from a local JSON file instead (testing / demo).

.PARAMETER CredentialPath
    Path to the Workday integration (ISU) credential, saved with Export-Clixml.
    It's DPAPI-encrypted, so only the account that created it, on the machine
    it was created on, can read it.

.PARAMETER CutoffHour
    Local hour of the day to turn access off. Default 17 (5 PM).

.PARAMETER MaxPerRun
    Stop without changing anything if more than this many people are due at once.

.PARAMETER AsOfUtc
    Pretend it's this time (UTC). Used for testing the time zone logic.

.EXAMPLE
    # Preview against the sample report, as if it were 6 PM Pacific on Nov 14
    .\Invoke-OffboardingFromWorkday.ps1 -ReportPath ..\sample-data\workday-offboarding-report.json -AsOfUtc '2026-11-15 02:00' -WhatIf

.EXAMPLE
    # What the scheduled task runs
    .\Invoke-OffboardingFromWorkday.ps1 -ReportUrl 'https://wd5-services1.myworkday.com/ccx/service/customreport2/contoso/ISU_Offboarding/Offboarding_Report'
#>

#Requires -Modules ActiveDirectory

[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Url')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Url')]  [string] $ReportUrl,
    [Parameter(Mandatory, ParameterSetName = 'File')] [string] $ReportPath,
    [Parameter(ParameterSetName = 'Url')]
    [string] $CredentialPath = (Join-Path $PSScriptRoot '..\config\workday-isu.cred.xml'),
    [string] $LocationMapPath = (Join-Path $PSScriptRoot '..\config\location-timezones.csv'),
    [ValidateRange(0, 23)] [int] $CutoffHour = 17,
    [int] $MaxPerRun = 25,
    [string] $DisabledOU = 'OU=Disabled Users,DC=contoso,DC=local',
    [string] $AuditLogPath = (Join-Path $PSScriptRoot '..\logs\offboarding-audit.csv'),
    [string] $GroupLogPath = (Join-Path $PSScriptRoot '..\logs\removed-groups.csv'),
    [datetime] $AsOfUtc = [datetime]::UtcNow
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\AuditLog.ps1')

# Workday report field names. Custom reports name things differently, so map them here.
$FieldMap = @{
    EmployeeId = 'Employee_ID'
    Username   = 'Username'
    LastDay    = 'Offboarding_Date'
    Location   = 'Location'
    LegalHold  = 'Legal_Hold'
}

function Get-WorkdayReport {
    if ($PSCmdlet.ParameterSetName -eq 'File') {
        return (Get-Content -Path $ReportPath -Raw | ConvertFrom-Json).Report_Entry
    }

    if ($ReportUrl -notmatch 'format=json') {
        $ReportUrl += $(if ($ReportUrl -match '\?') { '&' } else { '?' }) + 'format=json'
    }

    # Integration System User credential, encrypted with DPAPI for the service account.
    $cred = Import-Clixml -Path $CredentialPath
    $pair = '{0}:{1}' -f $cred.UserName, $cred.GetNetworkCredential().Password
    $headers = @{ Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($pair)) }

    (Invoke-RestMethod -Uri $ReportUrl -Headers $headers -Method Get).Report_Entry
}

function Get-LocalCutoffUtc {
    # Turns "last day + location" into the exact UTC moment access should end.
    param([string] $LastDayRaw, [string] $TimeZoneId)

    # Workday dates often come back with an offset attached, e.g. 2026-11-14-08:00.
    $lastDay = [datetime]::ParseExact($LastDayRaw.Substring(0, 10), 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
    $tz = [TimeZoneInfo]::FindSystemTimeZoneById($TimeZoneId)
    $localCutoff = [datetime]::SpecifyKind($lastDay.Date.AddHours($CutoffHour), [DateTimeKind]::Unspecified)

    # ConvertTimeToUtc handles daylight saving for that specific date.
    [TimeZoneInfo]::ConvertTimeToUtc($localCutoff, $tz)
}

# --- Load inputs ------------------------------------------------------------

$tzByLocation = @{}
foreach ($row in Import-Csv -Path $LocationMapPath) {
    $tzByLocation[$row.Location.Trim().ToLower()] = $row.TimeZoneId.Trim()
}

try {
    $entries = @(Get-WorkdayReport)
}
catch {
    Write-AuditRecord -LogPath $AuditLogPath -User '-' -Action 'WorkdayPull' -Result 'Failed' -Detail $_.Exception.Message
    throw "Couldn't pull the Workday report: $($_.Exception.Message)"
}

Write-Verbose "Workday report returned $($entries.Count) rows. Evaluating as of $($AsOfUtc.ToString('yyyy-MM-dd HH:mm')) UTC."

# --- Work out who is due ----------------------------------------------------

$due = @()

foreach ($entry in $entries) {
    $empId    = "$($entry.($FieldMap.EmployeeId))".Trim()
    $username = "$($entry.($FieldMap.Username))".Trim()
    $lastRaw  = "$($entry.($FieldMap.LastDay))".Trim()
    $location = "$($entry.($FieldMap.Location))".Trim()
    $label    = if ($username) { $username } else { "EmpID $empId" }

    if (-not $lastRaw) { continue }   # no offboarding date, nothing to do

    $tzId = $tzByLocation[$location.ToLower()]
    if (-not $tzId) {
        Write-AuditRecord -LogPath $AuditLogPath -User $label -Action 'TimeZoneLookup' -Target $location -Result 'Failed' -Detail 'Location not in location-timezones.csv; skipped'
        Write-Warning "$label has location '$location', which isn't in the time zone map. Skipping. Add it to config\location-timezones.csv."
        continue
    }

    $cutoffUtc = Get-LocalCutoffUtc -LastDayRaw $lastRaw -TimeZoneId $tzId
    if ($AsOfUtc -lt $cutoffUtc) {
        Write-Verbose "$label not due yet. Cutoff is $($cutoffUtc.ToString('yyyy-MM-dd HH:mm')) UTC ($CutoffHour`:00 $tzId)."
        continue
    }

    # Match on employeeID first (stable), then fall back to username.
    $adUser = Get-ADUser -Filter "EmployeeID -eq '$empId'" -Properties Enabled, EmployeeID
    if (-not $adUser -and $username) {
        $adUser = Get-ADUser -Filter "SamAccountName -eq '$username'" -Properties Enabled, EmployeeID
    }
    if (-not $adUser) {
        Write-AuditRecord -LogPath $AuditLogPath -User $label -Action 'ADLookup' -Result 'Failed' -Detail "No AD account with EmployeeID $empId or username $username"
        Write-Warning "$label is due for offboarding but wasn't found in AD."
        continue
    }
    if (-not $adUser.Enabled) {
        continue   # already done on an earlier run
    }

    $due += [PSCustomObject]@{
        SamAccountName = $adUser.SamAccountName
        EmployeeId     = $empId
        Location       = $location
        TimeZone       = $tzId
        CutoffUtc      = $cutoffUtc
        LegalHold      = "$($entry.($FieldMap.LegalHold))" -match '^(1|true|yes|y)$'
    }
}

# --- Safety valve -----------------------------------------------------------

if ($due.Count -gt $MaxPerRun) {
    $msg = "$($due.Count) users are due in a single run (limit $MaxPerRun). Stopping without changes. Check the Workday report before re-running."
    Write-AuditRecord -LogPath $AuditLogPath -User '-' -Action 'SafetyStop' -Result 'Failed' -Detail $msg
    throw $msg
}

if ($due.Count -eq 0) {
    Write-Verbose 'Nobody is due right now.'
    return
}

# --- Offboard ---------------------------------------------------------------

foreach ($person in $due) {
    Write-Host "$($person.SamAccountName): last day cutoff $($person.CutoffUtc.ToString('yyyy-MM-dd HH:mm')) UTC ($($person.Location))" -ForegroundColor Cyan

    try {
        & (Join-Path $PSScriptRoot 'Invoke-UserOffboarding.ps1') `
            -Identity $person.SamAccountName `
            -TicketNumber "Workday $($person.EmployeeId)" `
            -DisabledOU $DisabledOU `
            -LegalHold:$person.LegalHold `
            -AuditLogPath $AuditLogPath `
            -GroupLogPath $GroupLogPath `
            -WhatIf:$WhatIfPreference
    }
    catch {
        # One failure shouldn't stop everyone else from being offboarded.
        Write-AuditRecord -LogPath $AuditLogPath -User $person.SamAccountName -Action 'Offboard' -Result 'Failed' -Detail $_.Exception.Message
        Write-Warning "Offboarding failed for $($person.SamAccountName): $($_.Exception.Message)"
    }
}
