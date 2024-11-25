# Script to fetch role assignments for a subscription and resource group/all resource groups in subscription

# Login to Azure if not already logged in
(az account show --query id 2>&1) -match "az login" -and (az login) | Out-Null

# Step 1: Select a Subscription
Write-Host "Fetching subscriptions..." -ForegroundColor Green
$subscriptions = az account list --query "[].{Name:name, Id:id}" | ConvertFrom-Json
$selectedSubscription = $subscriptions | Out-GridView -Title "Select a Subscription" -PassThru

if (-not $selectedSubscription) {
    Write-Host "No subscription selected. Exiting." -ForegroundColor Red
    exit
}

az account set --subscription $selectedSubscription.Id
Write-Host "Selected subscription: $($selectedSubscription.Name)" -ForegroundColor Green

# Step 2: Select a Resource Group (or All)
Write-Host "Fetching resource groups..." -ForegroundColor Green
$resourceGroups = az group list --query "[].{Name:name}" | ConvertFrom-Json

# Add "All Resource Groups" option as the first option
$allOption = [PSCustomObject]@{ Name = "All Resource Groups" }
$resourceGroups = @($allOption) + $resourceGroups

$selectedResourceGroup = $resourceGroups | Out-GridView -Title "Select a Resource Group" -PassThru

if (-not $selectedResourceGroup) {
    Write-Host "No resource group selected. Exiting." -ForegroundColor Red
    exit
}

# Step 3: Fetch Role Assignments
if ($selectedResourceGroup.Name -eq "All Resource Groups") {
    # Create an empty collection to store all role assignments
    $allRoleAssignments = @()

    # Loop through all resource groups
    foreach ($resourceGroup in $resourceGroups) {
        if ($resourceGroup.Name -ne "All Resource Groups") {
            Write-Host "Fetching role assignments for resource group '$($resourceGroup.Name)'..." -ForegroundColor Green
            $roleAssignments = az role assignment list --scope "/subscriptions/$($selectedSubscription.Id)/resourceGroups/$($resourceGroup.Name)" --query "[].{ResourceGroup:'$($resourceGroup.Name)', AssignmentId:id, PrincipalName:principalName, Role:roleDefinitionName, PrincipalId:principalId, Scope:scope}" | ConvertFrom-Json

            if ($null -ne $roleAssignments) {
                # Append role assignments to the aggregated collection
                $allRoleAssignments += $roleAssignments
            } else {
                Write-Host "No role assignments found for resource group '$($resourceGroup.Name)'." -ForegroundColor Yellow
            }
        }
    }

    # Output all role assignments to a single GridView
    if ($allRoleAssignments.Count -gt 0) {
        $allRoleAssignments | Out-GridView -Title "All Role Assignments"
    } else {
        Write-Host "No role assignments found across all resource groups." -ForegroundColor Yellow
    }
}
else {
    # Fetch role assignments for a single resource group
    Write-Host "Selected resource group: $($selectedResourceGroup.Name)" -ForegroundColor Green
    $roleAssignments = az role assignment list --scope "/subscriptions/$($selectedSubscription.Id)/resourceGroups/$($selectedResourceGroup.Name)" --query "[].{AssignmentId:id, PrincipalName:principalName, Role:roleDefinitionName, PrincipalId:principalId, Scope:scope}" | ConvertFrom-Json

    $formattedAssignments = $roleAssignments | Select-Object @{
        Name = 'AssignmentId'
        Expression = { ($_.AssignmentId -split '/')[-1] }
    }, PrincipalName, Role, PrincipalId, Scope

    $host.UI.RawUI.BufferSize = New-Object System.Management.Automation.Host.Size(500, $host.UI.RawUI.BufferSize.Height)
    $formattedAssignments | Format-Table -AutoSize -Wrap
}

Write-Host "Script execution complete." -ForegroundColor Green
