# Requires PowerShell 7+
# Install once if needed:
# Install-Module Microsoft.Graph.Users -Scope CurrentUser
# Install-Module Microsoft.Graph.Authentication -Scope CurrentUser

param(
    [Parameter(Mandatory = $true)]
    [string]$InputCsv,

    [string]$ExistingOutputCsv = ".\existing-users-with-managers.csv",
    [string]$MissingOutputCsv  = ".\missing-users.csv"
)

Import-Module Microsoft.Graph.Authentication
Import-Module Microsoft.Graph.Users

function Get-InputEmailColumnName {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$CsvRows
    )

    if (-not $CsvRows -or $CsvRows.Count -eq 0) {
        throw "Input CSV does not contain any rows: $InputCsv"
    }

    $availableColumns = @($CsvRows[0].PSObject.Properties.Name)
    $emailColumnCandidates = @('Email', 'email', 'Mail', 'mail', 'UserPrincipalName', 'userPrincipalName', 'UPN', 'upn')
    $emailColumn = $emailColumnCandidates | Where-Object { $availableColumns -contains $_ } | Select-Object -First 1

    if (-not $emailColumn) {
        throw "Input CSV must contain one of these columns: $($emailColumnCandidates -join ', '). Available columns: $($availableColumns -join ', ')"
    }

    return $emailColumn
}

function Test-IsGraphNotFoundError {
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    $statusCode = $null
    if ($ErrorRecord.Exception.PSObject.Properties.Name -contains 'ResponseStatusCode') {
        $statusCode = [int]$ErrorRecord.Exception.ResponseStatusCode
    } elseif ($ErrorRecord.Exception.PSObject.Properties.Name -contains 'StatusCode') {
        try {
            $statusCode = [int]$ErrorRecord.Exception.StatusCode
        }
        catch {
            $statusCode = $null
        }
    }

    return $statusCode -eq 404 -or $ErrorRecord.Exception.Message -match 'Request_ResourceNotFound|ResourceNotFound|does not exist|No manager'
}

# Directory.Read.All is useful because manager lookup is a directory relationship.
Connect-MgGraph -Scopes "User.Read.All", "Directory.Read.All"

try {
    $rows = Import-Csv -LiteralPath $InputCsv
    $emailColumn = Get-InputEmailColumnName -CsvRows $rows

    $existingUsers = New-Object System.Collections.Generic.List[object]
    $missingUsers  = New-Object System.Collections.Generic.List[object]

    foreach ($row in $rows) {
        $email = [string]$row.$emailColumn

        if ([string]::IsNullOrWhiteSpace($email)) {
            continue
        }

        $email = $email.Trim()

        Write-Host "Checking $email"

        try {
            # First try direct lookup by UPN. In many tenants, UPN equals email.
            $user = Get-MgUser -UserId $email -Property Id,DisplayName,Mail,UserPrincipalName -ErrorAction Stop
        }
        catch {
            # Fallback: search by mail or userPrincipalName.
            # Escape single quotes for OData.
            $escapedEmail = $email.Replace("'", "''")

            $matches = Get-MgUser `
                -Filter "mail eq '$escapedEmail' or userPrincipalName eq '$escapedEmail'" `
                -Property Id,DisplayName,Mail,UserPrincipalName `
                -ConsistencyLevel eventual `
                -ErrorAction SilentlyContinue

            $user = $matches | Select-Object -First 1
        }

        if (-not $user) {
            $missingUsers.Add([pscustomobject]@{
                Email = $email
                Reason = "User not found"
            })
            continue
        }

        $managerName = $null
        $managerEmail = $null
        $managerUpn = $null

        try {
            $manager = Get-MgUserManager -UserId $user.Id -ErrorAction Stop

            # Get-MgUserManager returns a directory object.
            # For user managers, useful fields are usually in AdditionalProperties.
            $managerName = $manager.AdditionalProperties["displayName"]
            $managerEmail = $manager.AdditionalProperties["mail"]
            $managerUpn = $manager.AdditionalProperties["userPrincipalName"]
        }
        catch {
            if (Test-IsGraphNotFoundError -ErrorRecord $_) {
                $managerName = ""
                $managerEmail = ""
                $managerUpn = ""
            } else {
                throw
            }
        }

        $existingUsers.Add([pscustomobject]@{
            Email             = $email
            UserDisplayName   = $user.DisplayName
            UserPrincipalName = $user.UserPrincipalName
            UserMail          = $user.Mail
            ManagerName       = $managerName
            ManagerEmail      = $managerEmail
            ManagerUPN        = $managerUpn
        })
    }

    $existingUsers | Export-Csv -LiteralPath $ExistingOutputCsv -NoTypeInformation -Encoding UTF8
    $missingUsers  | Export-Csv -LiteralPath $MissingOutputCsv  -NoTypeInformation -Encoding UTF8

    Write-Host ""
    Write-Host "Done."
    Write-Host "Existing users exported to: $ExistingOutputCsv"
    Write-Host "Missing users exported to:  $MissingOutputCsv"
}
finally {
    Disconnect-MgGraph | Out-Null
}