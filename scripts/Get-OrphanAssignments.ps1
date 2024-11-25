# Script to find all RBAC assignments to deleted identities in management groups and subscriptions

param(
    [string]$RootId  # ID of the Root Management Group (e.g., "/providers/Microsoft.Management/managementGroups/root")
)

# Login to Azure if not already logged in
(az account show --query id 2>&1) -match "az login" -and (az login) | Out-Null

Write-Host "Fetching all role assignments for deleted identities..."

$allRoleAssignments = @()

# Check role assignments for the root management group using the passed RootId
if (-not $RootId) {
    Write-Host "Root management group ID was not provided." -ForegroundColor Red
} else {
    Write-Host "Checking role assignments for root management group: $RootId"
    
    try {
        $rootMgmtGroupRoleAssignments = az role assignment list --scope $RootId --output json | ConvertFrom-Json
        $allRoleAssignments += $rootMgmtGroupRoleAssignments
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
    
    $mgmtGroupScope = "/providers/Microsoft.Management/managementGroups/$mg"
    $mgmtGroupRoleAssignments = az role assignment list --scope $mgmtGroupScope --output json | ConvertFrom-Json
    $allRoleAssignments += $mgmtGroupRoleAssignments

    # Fetch all subscriptions under the current management group
    $subscriptions = az account management-group subscription show-sub-under-mg --name $mg --query '[].{id:id}' -o tsv

    # Loop through each subscription and fetch role assignments
    foreach ($subscriptionPath in $subscriptions) {
        $subscriptionId = $subscriptionPath -replace '.*/subscriptions/([^/]+)', '$1'

        Write-Host "Fetching role assignments for subscription '$subscriptionId'..."
        $subscriptionScope = "/subscriptions/$subscriptionId"
        
        try {
            $subscriptionRoleAssignments = az role assignment list --scope $subscriptionScope --output json | ConvertFrom-Json
            $allRoleAssignments += $subscriptionRoleAssignments
        }
        catch {
            Write-Host "Error fetching role assignments for subscription '$subscriptionId'. Continuing to the next subscription..." -ForegroundColor Yellow
        }
    }
}

# Filter results to find deleted identities
$deletedAssignments = $allRoleAssignments | Where-Object {
    ($_ | Test-Path -Path 'principalId' -ErrorAction SilentlyContinue) -and
    (
        ($_ | Test-Path -Path 'principalName' -eq $null) -or
        ($_ | Test-Path -Path 'principalType' -and ($_.principalType -eq "Unknown" -or $_.principalType -eq "Deleted"))
    )
}

# Output results to Out-GridView with specific fields
if ($deletedAssignments.Count -eq 0) {
    Write-Host "No role assignments found for deleted identities in the root management group, other management groups, or subscriptions." -ForegroundColor Yellow
} else {
    $filteredAssignments = $deletedAssignments | Select-Object principalId, principalType, roleDefinitionId, roleDefinitionName, scope
    $filteredAssignments | Out-GridView -Title "Role Assignments for Deleted Identities"
}
