<#
.SYNOPSIS
    Removes AD group access for users who are inactive in a source-of-truth system.

.DESCRIPTION
    Some access is tied to a status in another system (in my case a project
    resource tool) rather than to employment itself. People go inactive there
    but keep their AD group access, and nobody notices until an audit.

    This script compares a status export against one or more AD groups and
    removes anyone who is:
      - marked Inactive / Terminated in the export, or
      - disabled in AD, or
      - in the group but missing from the export entirely (optional)

    Every removal (or would-be removal, with -WhatIf) is written to an audit CSV.

    Expected CSV columns:
        SamAccountName, Status

.PARAMETER StatusExportPath
    Path to the status CSV from the source system.

.PARAMETER GroupName
    One or more AD groups to reconcile.

.PARAMETER RemoveIfMissing
    Also remove group members who don't appear in the export at all.

.EXAMPLE
    .\Sync-GroupAccessFromStatus.ps1 -StatusExportPath ..\sample-data\status-export.csv -GroupName 'APP-ProjectTool-Users' -WhatIf
#>

#Requires -Modules ActiveDirectory

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [string] $StatusExportPath,
    [Parameter(Mandatory)] [string[]] $GroupName,
    [switch] $RemoveIfMissing,
    [string[]] $InactiveStatuses = @('Inactive', 'Terminated', 'Disabled'),
    [string] $AuditLogPath = (Join-Path $PSScriptRoot '..\logs\access-sync-audit.csv')
)

. (Join-Path $PSScriptRoot 'lib\AuditLog.ps1')

if (-not (Test-Path -Path $StatusExportPath)) {
    throw "Status export not found at $StatusExportPath"
}

# Build a quick lookup: username -> status
$statusByUser = @{}
foreach ($row in Import-Csv -Path $StatusExportPath) {
    $statusByUser[$row.SamAccountName.Trim().ToLower()] = $row.Status.Trim()
}

$summary = @()

foreach ($group in $GroupName) {
    $members = Get-ADGroupMember -Identity $group | Where-Object objectClass -eq 'user'

    foreach ($member in $members) {
        $adUser = Get-ADUser -Identity $member.SamAccountName -Properties Enabled
        $key = $adUser.SamAccountName.ToLower()
        $status = $statusByUser[$key]

        $reason = $null
        if (-not $adUser.Enabled) {
            $reason = 'Disabled in AD'
        }
        elseif ($status -and ($InactiveStatuses -contains $status)) {
            $reason = "Status is '$status' in source system"
        }
        elseif (-not $status -and $RemoveIfMissing) {
            $reason = 'Not present in status export'
        }

        if (-not $reason) { continue }

        if ($PSCmdlet.ShouldProcess($group, "Remove $($adUser.SamAccountName) ($reason)")) {
            try {
                Remove-ADGroupMember -Identity $group -Members $adUser -Confirm:$false
                $outcome = 'Success'
                $detail = $reason
            }
            catch {
                $outcome = 'Failed'
                $detail = "$reason | $($_.Exception.Message)"
            }
        }
        else {
            $outcome = 'WhatIf'
            $detail = $reason
        }

        Write-AuditRecord -LogPath $AuditLogPath -User $adUser.SamAccountName -Action 'RemoveGroup' -Target $group -Result $outcome -Detail $detail
        $summary += [PSCustomObject]@{ Group = $group; User = $adUser.SamAccountName; Reason = $reason; Result = $outcome }
    }
}

if ($summary.Count -eq 0) {
    Write-Host 'Nothing to remove. All group members are active.' -ForegroundColor Green
}
else {
    $summary | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
    Write-Host "Audit log: $AuditLogPath" -ForegroundColor Green
}
