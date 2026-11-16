<#
.SYNOPSIS
    Offboards a single user in Active Directory and logs every step.

.DESCRIPTION
    Runs the standard offboarding steps for one departing user:

      1. Disables the AD account
      2. Resets the password to a random value
      3. Records and removes group memberships (except Domain Users)
      4. Stamps the account description with the offboarding date and ticket
      5. Moves the account to the Disabled Users OU
      6. Optionally flags the user for a Box legal hold (stub, see below)

    Every step writes a row to an audit CSV. Supports -WhatIf so you can
    preview exactly what would change before running it for real.

.PARAMETER Identity
    sAMAccountName of the user to offboard.

.PARAMETER DisabledOU
    Distinguished name of the OU that disabled accounts get moved to.

.PARAMETER TicketNumber
    Ticket or HR case number, stamped on the account for traceability.

.PARAMETER LegalHold
    If set, the user is flagged for a Box legal hold before anything else.

.PARAMETER AuditLogPath
    Where to write the audit CSV. Defaults to .\logs\offboarding-audit.csv

.EXAMPLE
    .\Invoke-UserOffboarding.ps1 -Identity jdoe -TicketNumber HR-1042 -WhatIf

.EXAMPLE
    .\Invoke-UserOffboarding.ps1 -Identity jdoe -TicketNumber HR-1042 -LegalHold
#>

#Requires -Modules ActiveDirectory

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [string] $Identity,
    [string] $DisabledOU = 'OU=Disabled Users,DC=contoso,DC=local',
    [string] $TicketNumber = 'N/A',
    [switch] $LegalHold,
    [string] $AuditLogPath = (Join-Path $PSScriptRoot '..\logs\offboarding-audit.csv')
)

$ErrorActionPreference = 'Stop'   # if a step fails, stop instead of logging it as a success

. (Join-Path $PSScriptRoot 'lib\AuditLog.ps1')

function New-RandomPassword {
    # 24 random characters; nobody needs to know it, it just has to be unguessable.
    $chars = [char[]](33..126)
    -join (1..24 | ForEach-Object { $chars | Get-Random })
}

function Request-BoxLegalHold {
    <#
        Stub. In production this called the Box API to add the user to a
        legal hold policy before their account was touched, so nothing could
        be deleted. Box credentials and policy IDs are environment-specific,
        so this version just logs the request for a human to action.
    #>
    param([string] $User)
    Write-Warning "Legal hold requested for $User. Apply the Box legal hold policy before deprovisioning Box."
}

$result = if ($WhatIfPreference) { 'WhatIf' } else { 'Success' }

try {
    $user = Get-ADUser -Identity $Identity -Properties MemberOf, Description, Enabled
}
catch {
    Write-AuditRecord -LogPath $AuditLogPath -User $Identity -Action 'Lookup' -Result 'Failed' -Detail $_.Exception.Message
    throw "Could not find user '$Identity' in AD: $($_.Exception.Message)"
}

Write-Host "Offboarding $($user.SamAccountName) ($($user.Name)), ticket $TicketNumber" -ForegroundColor Cyan

# 1. Legal hold comes first, before anything is changed or removed.
if ($LegalHold) {
    Request-BoxLegalHold -User $user.SamAccountName
    Write-AuditRecord -LogPath $AuditLogPath -User $user.SamAccountName -Action 'LegalHoldRequested' -Target 'Box' -Result $result
}

# 2. Disable the account.
if ($PSCmdlet.ShouldProcess($user.SamAccountName, 'Disable AD account')) {
    Disable-ADAccount -Identity $user
}
Write-AuditRecord -LogPath $AuditLogPath -User $user.SamAccountName -Action 'DisableAccount' -Result $result

# 3. Scramble the password so cached credentials stop working.
if ($PSCmdlet.ShouldProcess($user.SamAccountName, 'Reset password to random value')) {
    $newPassword = ConvertTo-SecureString (New-RandomPassword) -AsPlainText -Force
    Set-ADAccountPassword -Identity $user -NewPassword $newPassword -Reset
}
Write-AuditRecord -LogPath $AuditLogPath -User $user.SamAccountName -Action 'ResetPassword' -Result $result

# 4. Remove group memberships, recording each one so access can be restored if needed.
foreach ($groupDN in $user.MemberOf) {
    $group = Get-ADGroup -Identity $groupDN
    if ($group.Name -eq 'Domain Users') { continue }

    if ($PSCmdlet.ShouldProcess($group.Name, "Remove $($user.SamAccountName)")) {
        try {
            Remove-ADGroupMember -Identity $group -Members $user -Confirm:$false
            Write-AuditRecord -LogPath $AuditLogPath -User $user.SamAccountName -Action 'RemoveGroup' -Target $group.Name -Result 'Success'
        }
        catch {
            Write-AuditRecord -LogPath $AuditLogPath -User $user.SamAccountName -Action 'RemoveGroup' -Target $group.Name -Result 'Failed' -Detail $_.Exception.Message
        }
    }
    else {
        Write-AuditRecord -LogPath $AuditLogPath -User $user.SamAccountName -Action 'RemoveGroup' -Target $group.Name -Result 'WhatIf'
    }
}

# 5. Stamp the description so anyone looking at the account knows what happened.
$stamp = "Offboarded $(Get-Date -Format 'yyyy-MM-dd') | Ticket $TicketNumber | Was: $($user.Description)"
if ($PSCmdlet.ShouldProcess($user.SamAccountName, "Set description to '$stamp'")) {
    Set-ADUser -Identity $user -Description $stamp
}
Write-AuditRecord -LogPath $AuditLogPath -User $user.SamAccountName -Action 'StampDescription' -Detail $stamp -Result $result

# 6. Move to the disabled OU last, so the steps above still find the account where they expect it.
if ($PSCmdlet.ShouldProcess($user.SamAccountName, "Move to $DisabledOU")) {
    Move-ADObject -Identity $user.DistinguishedName -TargetPath $DisabledOU
}
Write-AuditRecord -LogPath $AuditLogPath -User $user.SamAccountName -Action 'MoveToDisabledOU' -Target $DisabledOU -Result $result

Write-Host "Done. Audit log: $AuditLogPath" -ForegroundColor Green
