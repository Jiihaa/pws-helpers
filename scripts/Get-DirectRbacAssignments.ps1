# Script to go through all subscriptions and find all direct RBAC assignments for users and groups
# Ensure you are logged into Azure CLI. Use -UseManagementGroups only when you need management-group traversal.

param(
    [switch]$IncludePrincipalId,
    [switch]$UseManagementGroups
)

# Login to Azure if not already logged in
(az account show --query id 2>&1) -match "az login" -and (az login) | Out-Null

# Initialize an empty array to store results
$roleAssignmentsList = @()
$subscriptions = @()
$processedSubscriptions = @{}

$roleAssignmentQuery = '[?principalType==`"User`" || principalType==`"Group`"].{PrincipalName:principalName, Role:roleDefinitionName, PrincipalType:principalType, Scope:scope, PrincipalId:principalId}'

if ($UseManagementGroups) {
    Write-Host "Getting all management groups..."
    $managementGroups = az account management-group list --query '[].{name:name}' -o tsv

    # Iterate through each management group
    foreach ($mg in $managementGroups) {
        Write-Host "`nChecking management group: $mg"

        # Get all subscriptions under the management group
        $subscriptions += az account management-group subscription show-sub-under-mg --name $mg --query '[].{displayName:displayName, subscriptionId:name, state:state}' -o tsv
    }
} else {
    Write-Host "Getting subscriptions from current account context..."
    $subscriptions = az account list --all --query '[].{displayName:name, subscriptionId:id, state:state}' -o tsv
}

foreach ($subscription in $subscriptions) {
    if ([string]::IsNullOrWhiteSpace($subscription)) {
        continue
    }

    $subscriptionDetails = $subscription -split "`t"
    if ($subscriptionDetails.Count -lt 3) {
        continue
    }

    $subscriptionName = $subscriptionDetails[0]
    $subscriptionId = $subscriptionDetails[1]
    $subscriptionState = $subscriptionDetails[2]

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

# Output to grid view
if ($IsWindows) {
    $roleAssignmentsList | Out-GridView -Title "Direct User and Group Role Assignments"
} else {
    $roleAssignmentsList | Format-Table -AutoSize
}
