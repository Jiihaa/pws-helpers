Connect-MgGraph -Scopes "User.Read.All","AuditLog.Read.All"

$cutoff = (Get-Date).ToUniversalTime().AddYears(-1)

$users = Get-MgUser -All `
    -Property "id,displayName,userPrincipalName,accountEnabled,userType,createdDateTime,signInActivity"

$report = $users | ForEach-Object {

    $lastSuccessful = $_.SignInActivity.LastSuccessfulSignInDateTime

    [PSCustomObject]@{
        UserPrincipalName    = $_.UserPrincipalName
        UserType             = $_.UserType
        AccountEnabled       = $_.AccountEnabled
        LastSuccessfulSignIn = $lastSuccessful

        ActivityStatus = if (-not $lastSuccessful) {
            "No successful sign-in recorded"
        }
        elseif ($lastSuccessful -lt $cutoff) {
            "Inactive > 1 year"
        }
        else {
            "Active within 1 year"
        }
    }
}

$report |
    Sort-Object ActivityStatus, LastSuccessfulSignIn |
    Format-Table -AutoSize