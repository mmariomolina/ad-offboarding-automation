# AD Offboarding Automation

PowerShell scripts for automating the boring-but-important part of IT: making sure that when someone leaves, their access actually goes away, and that there's a record proving it.

This is a cleaned-up, generic version of automation I built and run in my current role supporting a global user base. All names, domains, and data here are made up (`contoso.local`, fake users). Nothing is copied from a real environment.

## The problem

Offboarding used to look like this:

1. HR sends a termination notice.
2. Someone in IT has to remember to disable the account, pull group access, move it to the right OU, and, if Legal asks, put a hold on the user's files before anything gets deleted.
3. Steps get missed. Access lingers. When audit season comes, nobody can easily prove what was removed and when.

There was a second, sneakier version of the problem too: some app access was tied to a person's status in *another* system (a project resource tool), not to their employment. People went inactive there but kept their AD group access for months.

## What's in here

| Script | What it does |
| --- | --- |
| `scripts/Invoke-OffboardingFromHRFeed.ps1` | Reads an HR termination CSV, figures out who's due (last day has passed, account still enabled), and offboards each of them. Safe to run on a schedule. |
| `scripts/Invoke-UserOffboarding.ps1` | Offboards one user: legal hold flag (if needed) → disable → scramble password → remove groups → stamp description → move to Disabled OU. |
| `scripts/Sync-GroupAccessFromStatus.ps1` | Compares a status export from another system against AD groups and removes anyone inactive, terminated, or disabled. |
| `scripts/lib/AuditLog.ps1` | Shared helper. Every change gets a row in a CSV audit log: who, what, when, result. |
| `sample-data/` | Fake HR feed and status export so you can see the expected format. |

## How to run it

You need a Windows machine with the RSAT Active Directory module and an account with rights to manage users and groups.

**Always start with `-WhatIf`.** Every script supports it, and it shows exactly what would change without touching anything.

```powershell
# Preview offboarding everyone due in the HR feed
.\scripts\Invoke-OffboardingFromHRFeed.ps1 -FeedPath .\sample-data\hr-terminations.csv -WhatIf

# Offboard one person for real, with a legal hold
.\scripts\Invoke-UserOffboarding.ps1 -Identity asmith -TicketNumber HR-1047 -LegalHold

# Preview access cleanup for an app group
.\scripts\Sync-GroupAccessFromStatus.ps1 -StatusExportPath .\sample-data\status-export.csv -GroupName 'APP-ProjectTool-Users' -WhatIf
```

Audit logs land in `logs/` (git-ignored).

## A few design choices

- **Legal hold happens first.** If Legal needs a user's files preserved, that has to be in place before anything gets disabled or cleaned up.
- **Group removals are logged one by one.** If someone gets offboarded by mistake (it happens), the audit log tells you exactly which groups to put back.
- **The OU move happens last**, so the earlier steps still find the account where they expect it.
- **Skip, don't fail, on already-disabled accounts.** The HR feed script can run every night without re-processing people.

## What's stubbed out

The Box legal hold is a stub here. In production it called the Box API to add the user to a legal hold policy. That needs real Box credentials and policy IDs, so this version just logs the request and warns you to apply it.

## What I'd add next

- Pull the HR feed straight from the HR system's API instead of a CSV drop
- Revoke Entra ID / M365 sessions and convert the mailbox to shared
- Email a summary to the manager and the IT channel after each run
- Pester tests with mocked AD cmdlets

## About me

I'm Mario, a systems engineer in the Bay Area working across identity (PingFederate, PingOne, Entra ID), endpoint support, and automation. [LinkedIn](https://www.linkedin.com/in/mario-molina-it/)
