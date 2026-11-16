# AD Offboarding Automation

PowerShell automation that turns off a departing employee's access at **5 PM their local time on their last day**, driven by a Workday report, with a full record of everything it removed.

This is a cleaned-up, generic version of offboarding automation I built and run in my current role supporting a global user base. All names, domains, URLs, and data here are made up (`contoso.local`, fake users). Nothing is copied from a real environment.

## The problem

Offboarding used to look like this:

1. HR sends a termination notice.
2. Someone in IT has to remember to disable the account, pull group access, move it to the right OU, and, if Legal asks, put a hold on the user's files before anything gets deleted.
3. Steps get missed. Access lingers. And with people across time zones, "disable it on their last day" either cuts someone off at lunch or leaves them with access overnight.
4. When audit season comes, nobody can easily prove what was removed and when.

## How it works

```
Workday custom report (RaaS, JSON)
        │   pulled every 15 min by Task Scheduler
        ▼
Invoke-OffboardingFromWorkday.ps1
   • reads each worker's offboarding date + location
   • maps location → time zone (config/location-timezones.csv)
   • works out 5:00 PM on their last day, in their local time
   • if that moment has passed and the AD account is still enabled ──┐
                                                                     ▼
                                              Invoke-UserOffboarding.ps1
                                                 1. legal hold flag (if needed)
                                                 2. disable account
                                                 3. scramble password
                                                 4. log + remove every group
                                                 5. stamp description
                                                 6. move to Disabled Users OU
        │
        ▼
logs/offboarding-audit.csv   every action, who/what/when/result
logs/removed-groups.csv      every group removed, with full DN, for exact restore
```

Because the task runs every 15 minutes, access ends between 5:00 and 5:15 PM local. If the server was down, the next run catches up anyone it missed.

## What's in here

| Path | What it does |
| --- | --- |
| `scripts/Invoke-OffboardingFromWorkday.ps1` | The scheduled entry point. Pulls the Workday report, applies the 5 PM local-time logic, and offboards whoever is due. |
| `scripts/Invoke-UserOffboarding.ps1` | Offboards one user. Also usable by hand for same-day or involuntary terminations. |
| `scripts/Sync-GroupAccessFromStatus.ps1` | Separate cleanup: removes app group access for people marked inactive in another source system, even if they're still employed. |
| `scripts/lib/AuditLog.ps1` | Shared logging helpers for the audit log and the removed-groups log. |
| `config/location-timezones.csv` | Maps Workday location names to Windows time zone IDs. |
| `setup/Register-OffboardingTask.ps1` | Creates the Task Scheduler job (every 15 min, as a service account). |
| `setup/New-WorkdayCredential.ps1` | Saves the Workday integration credential, encrypted for the service account. |
| `sample-data/` | A fake Workday report and status export so you can see the formats. |

## Where it runs

A **domain-joined Windows member server** (not a domain controller) with the RSAT Active Directory module, running a **Task Scheduler** job every 15 minutes.

- **Run it as a group Managed Service Account (gMSA).** There's no password to store or rotate, and it only works on the servers you allow.
- **Least privilege.** The account gets delegated rights on the user OUs (disable, reset password, write description, move to Disabled OU) and on the groups it manages. It is not a Domain Admin.
- **Workday side.** Your Workday admin creates an Integration System User (ISU) that can only see the offboarding report, and exposes the report as a web service (RaaS). The ISU password is stored with `Export-Clixml`, which DPAPI-encrypts it so only the service account on that server can read it. Credential files are git-ignored.

Setup, once:

```powershell
# 1. Copy the repo to C:\Scripts\ad-offboarding-automation on the server
# 2. Save the Workday credential AS the service account (see the script's help for the gMSA trick)
.\setup\New-WorkdayCredential.ps1
# 3. Register the scheduled task
.\setup\Register-OffboardingTask.ps1 -ServiceAccount 'CONTOSO\svc-offboard$' -ReportUrl 'https://<tenant>.myworkday.com/ccx/service/customreport2/<tenant>/<ISU>/<Report_Name>'
```

## Safety rails

- **`-WhatIf` everywhere.** Every script previews exactly what it would change, and preview runs still write to the logs.
- **Mass-disable stop.** If more than 25 people (configurable) are due in a single run, the script stops before touching anything. A broken report should never be able to disable half the company.
- **Unknown location? Don't guess.** If a worker's location isn't in the time zone map, they're skipped and logged as failed instead of being cut off at the wrong hour. Add the location and the next run picks them up.
- **Match on employee ID, not name.** AD accounts are matched on the `employeeID` attribute first, with username as a fallback.
- **Legal hold first, OU move last.** Files get preserved before anything is touched, and the account is moved only after every other step has found it.
- **One failure doesn't stop the rest.** If one person errors out, it's logged and the run continues.

## Try it without AD changes

```powershell
# As if it were 5:05 PM Pacific on Nov 14, preview only
.\scripts\Invoke-OffboardingFromWorkday.ps1 -ReportPath .\sample-data\workday-offboarding-report.json -AsOfUtc '2026-11-15 01:05' -WhatIf -Verbose
```

`-AsOfUtc` lets you test the time zone logic at any moment. In the sample data, the New York user is due at 22:00 UTC, the San Jose user at 01:00 UTC, and the Bangkok user at 10:00 UTC the next day, which is 5 PM local for all three.

## What's stubbed out

The Box legal hold is a stub. In production it called the Box API to add the user to a legal hold policy. That needs real Box credentials and policy IDs, so this version just logs the request and warns you to apply it.

## What I'd add next

- A `Restore-UserGroups.ps1` that reads `removed-groups.csv` and puts a user's access back for rehires or mistakes
- Revoke Entra ID / M365 sessions and convert the mailbox to shared
- Email a summary to the manager and the IT channel after each offboarding
- Pester tests with mocked AD cmdlets

## About me

I'm Mario, a systems engineer in the Bay Area working across identity (PingFederate, PingOne, Entra ID), endpoint support, and automation. [LinkedIn](https://www.linkedin.com/in/mario-molina-it/)
