param(
    [string]$GroupName,  # Name of the Azure AD group
    [string]$RootId      # ID of the Root Management Group (e.g., "/providers/Microsoft.Management/managementGroups/root")
)

# Ensure you are logged in to Azure
az account show 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    az login
}

# Get the group object ID from Azure AD using the group name
$groupId = az ad group show --group $GroupName --query id --output tsv

if (-not $groupId) {
    Write-Host "The group '$GroupName' could not be found." -ForegroundColor Red
    exit 1
}

Write-Host "Fetching role assignments for the group '$GroupName' (Object ID: $groupId)..."

$allRoleAssignments = @()

# Check role assignments for the root management group using the passed RootId
if (-not $RootId) {
    Write-Host "Root management group ID was not provided." -ForegroundColor Red
} else {
    Write-Host "Checking role assignments for root management group: $RootId"
    
    # Capture the CLI command output and suppress the error output using 2>&1 | Out-Null
    try {
        $rootMgmtGroupRoleAssignments = az role assignment list --scope $RootId --query "[?principalId=='$groupId']" --output json 2>&1 | ConvertFrom-Json
        if (-not $rootMgmtGroupRoleAssignments) {
            Write-Host "No subscriptions on root level." -ForegroundColor Yellow
        } else {
            $allRoleAssignments += $rootMgmtGroupRoleAssignments
        }
    }
    catch {
        Write-Host "No subscriptions on root level." -ForegroundColor Yellow
    }
}

# Fetch all other management groups
$managementGroups = az account management-group list --query '[].{name:name}' -o tsv

# Loop through each management group and fetch role assignments
foreach ($mg in $managementGroups) {
    Write-Host "Fetching role assignments for management group '$mg'..."
    
    # Correctly format the scope for the management group
    $mgmtGroupScope = "/providers/Microsoft.Management/managementGroups/$mg"
    $mgmtGroupRoleAssignments = az role assignment list --scope $mgmtGroupScope --query "[?principalId=='$groupId']" --output json | ConvertFrom-Json
    $allRoleAssignments += $mgmtGroupRoleAssignments

    # Fetch all subscriptions under the current management group
    $subscriptions = az account management-group subscription show-sub-under-mg --name $mg --query '[].{id:id}' -o tsv

    # Loop through each subscription and fetch role assignments
    foreach ($subscriptionPath in $subscriptions) {
        # Extract the subscription ID from the path
        $subscriptionId = $subscriptionPath -replace '.*/subscriptions/([^/]+)', '$1'

        Write-Host "Fetching role assignments for subscription '$subscriptionId'..."
        $subscriptionScope = "/subscriptions/$subscriptionId"
        
        try {
            # Fetch role assignments for the subscription
            $subscriptionRoleAssignments = az role assignment list --scope $subscriptionScope --query "[?principalId=='$groupId']" --output json | ConvertFrom-Json
            $allRoleAssignments += $subscriptionRoleAssignments
        }
        catch {
            Write-Host "Error fetching role assignments for subscription '$subscriptionId'. Continuing to the next subscription..." -ForegroundColor Yellow
        }
    }
}

# Output results to Out-GridView with specific fields
if ($allRoleAssignments.Count -eq 0) {
    Write-Host "No role assignments found for the group '$GroupName' in the root management group, other management groups, or subscriptions." -ForegroundColor Yellow
} else {
    $filteredAssignments = $allRoleAssignments | Select-Object principalId, principalName, roleDefinitionId, roleDefinitionName, scope
    $filteredAssignments | Out-GridView -Title "Role Assignments for Group: $GroupName"
}
