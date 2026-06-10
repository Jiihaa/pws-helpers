# Script to go through all subscriptions and find all direct RBAC assignments for users and groups
# Ensure you are logged into Azure CLI. Use -ManagementGroupId when you want to limit discovery to one management group subtree.

param(
    # Include Azure AD principal object IDs in the output.
    [switch]$IncludePrincipalId,
    # Limit subscription discovery to this management group subtree.
    [string]$ManagementGroupId,
    # Optional billing export CSV used as the subscription source.
    [string]$BillingCsv,
    # Optional output CSV file name written to the current working directory.
    [string]$Out
)

# Login to Azure if not already logged in
(az account show --query id 2>&1) -match "az login" -and (az login) | Out-Null

# Initialize an empty array to store results
$roleAssignmentsList = @()
$subscriptions = @()
$processedSubscriptions = @{}

$roleAssignmentQuery = '[?principalType==`"User`" || principalType==`"Group`"].{PrincipalName:principalName, Role:roleDefinitionName, PrincipalType:principalType, Scope:scope, PrincipalId:principalId}'

function Import-BillingSubscriptions {
    param(
        # Path to a billing CSV file that contains subscription IDs.
        [Parameter(Mandatory = $true)]
        [string]$CsvPath
    )

    $allLines = Get-Content -LiteralPath $CsvPath
    if (-not $allLines -or $allLines.Count -eq 0) {
        return @()
    }

    $firstLine = $allLines[0]
    $delimiter = ','
    $startIndex = 0

    # Excel exports can include a delimiter hint in the first line, like "sep=;".
    if ($firstLine -match '^sep=(.)$') {
        $delimiter = $Matches[1]
        $startIndex = 1
        if ($allLines.Count -le 1) {
            return @()
        }
        $firstLine = $allLines[1]
    }

    if ($startIndex -eq 0 -and $firstLine -match ';') {
        $delimiter = ';'
    } elseif ($startIndex -eq 0 -and $firstLine -match "`t") {
        $delimiter = "`t"
    }

    $rows = if ($startIndex -eq 0) {
        Import-Csv -LiteralPath $CsvPath -Delimiter $delimiter
    } else {
        $allLines[$startIndex..($allLines.Count - 1)] | ConvertFrom-Csv -Delimiter $delimiter
    }
    if (-not $rows) {
        return @()
    }

    $idColumnCandidates = @('ID', 'Id', 'id', 'SubscriptionId', 'Subscription ID', 'subscriptionId')
    $nameColumnCandidates = @('Name', 'NAME', 'name', 'SubscriptionName', 'Subscription Name', 'subscriptionName')

    $columns = @($rows[0].PSObject.Properties.Name)
    $idColumn = $idColumnCandidates | Where-Object { $columns -contains $_ } | Select-Object -First 1
    $nameColumn = $nameColumnCandidates | Where-Object { $columns -contains $_ } | Select-Object -First 1

    if (-not $idColumn) {
        throw "Could not find a subscription ID column in billing CSV. Available columns: $($columns -join ', ')"
    }

    return $rows |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_.$idColumn) } |
        ForEach-Object {
            $subscriptionId = $_.$idColumn
            $displayName = $subscriptionId
            if ($nameColumn -and -not [string]::IsNullOrWhiteSpace($_.$nameColumn)) {
                $displayName = $_.$nameColumn
            }

            [pscustomobject]@{
                displayName = $displayName
                subscriptionId = $subscriptionId
                state = 'Enabled'
            }
        }
}

function Get-ManagementGroupIdsRecursively {
    param(
        # Root management group ID to walk recursively.
        [Parameter(Mandatory = $true)]
        [string]$RootManagementGroupId
    )

    $tree = az account management-group show --name $RootManagementGroupId --expand --recurse -o json | ConvertFrom-Json
    $discoveredManagementGroups = @()
    $processedManagementGroups = @{}
    $queue = [System.Collections.Queue]::new()
    $queue.Enqueue($tree)

    while ($queue.Count -gt 0) {
        $current = $queue.Dequeue()
        if (-not $current) {
            continue
        }

        $isManagementGroupNode = $current.type -match "/managementGroups$"
        if ($isManagementGroupNode -and $current.name -and -not $processedManagementGroups.ContainsKey($current.name)) {
            $processedManagementGroups[$current.name] = $true
            $discoveredManagementGroups += $current.name
        }

        $children = @()
        if ($current.children) {
            $children += $current.children
        }

        if ($current.properties -and $current.properties.children) {
            $children += $current.properties.children
        }

        foreach ($child in $children) {
            if ($child.type -match "/managementGroups$" -or ($child.properties -and $child.properties.children)) {
                $queue.Enqueue($child)
            }
        }
    }

    return $discoveredManagementGroups
}

if (-not [string]::IsNullOrWhiteSpace($BillingCsv)) {
    if (-not (Test-Path -LiteralPath $BillingCsv)) {
        throw "Billing data CSV not found: $BillingCsv"
    }

    Write-Host "Getting subscriptions from billing data CSV: $BillingCsv"
    $subscriptions = Import-BillingSubscriptions -CsvPath $BillingCsv

    if (-not $subscriptions -or $subscriptions.Count -eq 0) {
        throw "No subscriptions were parsed from billing CSV. Verify delimiter and that subscription ID column has values."
    }
} elseif (-not [string]::IsNullOrWhiteSpace($ManagementGroupId)) {
    Write-Host "Getting subscriptions from management group subtree: $ManagementGroupId"
    $managementGroups = Get-ManagementGroupIdsRecursively -RootManagementGroupId $ManagementGroupId

    foreach ($mg in $managementGroups) {
        Write-Host "`nChecking management group: $mg"

        $subscriptions += az account management-group subscription show-sub-under-mg --name $mg --query '[].{displayName:displayName, subscriptionId:name, state:state}' -o tsv
    }
} else {
    Write-Host "Getting subscriptions from current account context..."
    $subscriptions = az account list --all --query '[].{displayName:name, subscriptionId:id, state:state}' -o tsv
}

Write-Host "Found $($subscriptions.Count) subscription(s) to process."

foreach ($subscription in $subscriptions) {
    if ([string]::IsNullOrWhiteSpace($subscription)) {
        continue
    }

    if ($subscription -is [string]) {
        $subscriptionDetails = $subscription -split "`t"
        if ($subscriptionDetails.Count -lt 3) {
            continue
        }

        $subscriptionName = $subscriptionDetails[0]
        $subscriptionId = $subscriptionDetails[1]
        $subscriptionState = $subscriptionDetails[2]
    } else {
        $subscriptionName = $subscription.displayName
        $subscriptionId = $subscription.subscriptionId
        $subscriptionState = $subscription.state
    }

    if ($processedSubscriptions.ContainsKey($subscriptionId)) {
        continue
    }

    $processedSubscriptions[$subscriptionId] = $true

    if ($subscriptionState -eq "Disabled") {
        Write-Host "Skipping disabled subscription: $subscriptionName ($subscriptionId)"
        continue
    }

    Write-Host "`nChecking subscription: $subscriptionName ($subscriptionId)"

    # Set the current subscription context
    az account set --subscription $subscriptionId

    # Get all direct user and group assignments in the current subscription, including resource group and resource scopes.
    $roleAssignments = az role assignment list --all --query $roleAssignmentQuery -o json | ConvertFrom-Json

    # Add the role assignments to the array with subscription info
    foreach ($role in $roleAssignments) {
        # Add a custom object with subscription name, user/group name, role, and principal type
        $roleAssignment = [ordered]@{
            SubscriptionName = $subscriptionName
            SubscriptionId = $subscriptionId
            Scope = $role.Scope
            PrincipalName = $role.PrincipalName
            Role = $role.Role
            PrincipalType = $role.PrincipalType
        }

        if ($IncludePrincipalId) {
            $roleAssignment.PrincipalId = $role.PrincipalId
        }

        $roleAssignmentsList += [pscustomobject]$roleAssignment
    }
}

if (-not [string]::IsNullOrWhiteSpace($Out)) {
    $resolvedFileName = [System.IO.Path]::GetFileName($Out)
    if ([string]::IsNullOrWhiteSpace($resolvedFileName)) {
        throw "Out must be a valid file name, for example direct-rbac.csv"
    }

    if ([System.IO.Path]::GetExtension($resolvedFileName) -ne '.csv') {
        $resolvedFileName = "$resolvedFileName.csv"
    }

    $outputCsvPath = Join-Path -Path (Get-Location) -ChildPath $resolvedFileName
    $roleAssignmentsList | Export-Csv -LiteralPath $outputCsvPath -NoTypeInformation -Encoding UTF8
    Write-Host "CSV file created: $outputCsvPath"
}

# Output to grid view
if ($IsWindows) {
    $roleAssignmentsList | Out-GridView -Title "Direct User and Group Role Assignments"
} else {
    $roleAssignmentsList | Format-Table -AutoSize
}
