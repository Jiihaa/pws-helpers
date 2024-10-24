# Fetch all management groups
$managementGroups = az account management-group entities list | ConvertFrom-Json

# Initialize an empty array to store budget information
$allBudgets = @()

# Loop through each management group
foreach ($mg in $managementGroups) {
    # Fetch budgets for the current management group
    try {
        Write-Host "Fetching budgets for management group: $($mg.id)"
        
        $budgets = az rest --method get --url "$($mg.id)/providers/Microsoft.Consumption/budgets?api-version=2023-05-01" | ConvertFrom-Json
        
        if ($budgets.value) {
            # Process each budget item
            foreach ($budget in $budgets.value) {
                # Create a custom object for the cleaned-up result
                $budgetObj = [pscustomobject]@{
                    Name      = $budget.name
                    Amount    = $budget.properties.amount
                    TimeGrain = $budget.properties.timeGrain
                    Scope     = $budget.id
                }
                # Append the cleaned object to the $allBudgets array
                $allBudgets += $budgetObj
            }
        }
    }
    catch {
        Write-Host "Error fetching budgets for management group: $($mg.id). Continuing to the next management group..." -ForegroundColor Yellow
    }
}

# Check if any budgets were fetched
if ($allBudgets.Count -eq 0) {
    Write-Host "No budgets found for any management groups." -ForegroundColor Yellow
} else {
    # Display the cleaned-up budgets in Out-GridView
    $allBudgets | Out-GridView -Title "Budgets for Management Groups"
}
