# Script to go through all subscriptions and find all direct RBAC assignments for users and groups
# Ensure you are logged into Azure CLI

# Login to Azure if not already logged in
(az account show --query id 2>&1) -match "az login" -and (az login) | Out-Null

# Initialize an empty array to store results
$roleAssignmentsList = @()

Write-Host "Getting all management groups..."
$managementGroups = az account management-group list --query '[].{name:name}' -o tsv

# Iterate through each management group
foreach ($mg in $managementGroups) {
    Write-Host "`nChecking management group: $mg"

    # Get all subscriptions under the management group
    $subscriptions = az account management-group subscription show-sub-under-mg --name $mg --query '[].{displayName:displayName, id:id, subscriptionId:name}' -o tsv

    foreach ($subscription in $subscriptions) {
        $subscriptionDetails = $subscription -split "`t"
        $subscriptionName = $subscriptionDetails[0]
        $subscriptionId = $subscriptionDetails[2]

        Write-Host "`nChecking subscription: $subscriptionName ($subscriptionId)"

        # Set the current subscription context
        az account set --subscription $subscriptionId

        # Get all role assignments for the subscription and filter out service principals and managed identities
        $roleAssignments = az role assignment list --scope "/subscriptions/$subscriptionId" --query '[?principalType==`"User"` || principalType==`"Group"`].{PrincipalName:principalName, Role:roleDefinitionName, PrincipalType:principalType}' -o tsv

        # Add the role assignments to the array with subscription info
        foreach ($role in $roleAssignments) {
            $roleDetails = $role -split "`t"
            $principalName = $roleDetails[0]
            $roleName = $roleDetails[1]
            $principalType = $roleDetails[2]

            # Add a custom object with subscription name, user/group name, role, and principal type
            $roleAssignmentsList += [pscustomobject]@{
                SubscriptionName = $subscriptionName
                SubscriptionId = $subscriptionId
                PrincipalName = $principalName
                Role = $roleName
                PrincipalType = $principalType
            }
        }
    }
}

# Output to grid view
if ($IsWindows) {
    $roleAssignmentsList | Out-GridView -Title "Direct User and Group Role Assignments at Subscription Level"
} else {
    $roleAssignmentsList | Format-Table -AutoSize
}
