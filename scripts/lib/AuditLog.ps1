<#
.SYNOPSIS
    Shared helper for writing audit records to a CSV file.

.DESCRIPTION
    Every change the scripts make (or would make, in -WhatIf mode) gets a row
    in an audit CSV: who, what, when, and whether it worked. This is what you
    hand to auditors instead of digging through ticket history.

    Logging always happens, even in -WhatIf mode, so a preview run leaves a
    record of what it would have done.
#>

function Write-AuditRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $LogPath,
        [Parameter(Mandatory)] [string] $User,
        [Parameter(Mandatory)] [string] $Action,
        [string] $Target = '',
        [ValidateSet('Success', 'Failed', 'Skipped', 'WhatIf')]
        [string] $Result = 'Success',
        [string] $Detail = ''
    )

    $logDir = Split-Path -Path $LogPath -Parent
    if ($logDir -and -not (Test-Path -Path $logDir)) {
        New-Item -Path $logDir -ItemType Directory -Force -WhatIf:$false | Out-Null
    }

    [PSCustomObject]@{
        Timestamp  = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        RunBy      = $env:USERNAME
        User       = $User
        Action     = $Action
        Target     = $Target
        Result     = $Result
        Detail     = $Detail
    } | Export-Csv -Path $LogPath -Append -NoTypeInformation -WhatIf:$false -Confirm:$false
}

function Write-RemovedGroupRecord {
    <#
        Keeps a dedicated record of every AD group taken away from a user,
        with the group's full DN, so access can be put back exactly if an
        offboarding was a mistake or someone is rehired. Like the audit log,
        it's written even in -WhatIf mode.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $LogPath,
        [Parameter(Mandatory)] [string] $User,
        [string] $EmployeeId = '',
        [Parameter(Mandatory)] [string] $GroupName,
        [Parameter(Mandatory)] [string] $GroupDN,
        [ValidateSet('Removed', 'Failed', 'WhatIf')]
        [string] $Result = 'Removed',
        [string] $Detail = ''
    )

    $logDir = Split-Path -Path $LogPath -Parent
    if ($logDir -and -not (Test-Path -Path $logDir)) {
        New-Item -Path $logDir -ItemType Directory -Force -WhatIf:$false | Out-Null
    }

    [PSCustomObject]@{
        Timestamp  = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        User       = $User
        EmployeeId = $EmployeeId
        GroupName  = $GroupName
        GroupDN    = $GroupDN
        Result     = $Result
        Detail     = $Detail
    } | Export-Csv -Path $LogPath -Append -NoTypeInformation -WhatIf:$false -Confirm:$false
}
