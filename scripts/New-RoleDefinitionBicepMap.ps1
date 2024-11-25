# This script creates a Bicep file with a Roles object that contains all the role definitions in the Azure subscription.

# Login to Azure if not already logged in
(az account show --query id 2>&1) -match "az login" -and (az login) | Out-Null

# Run the Azure CLI command to list role definitions and store the output in a variable
$roleDefinitions = az role definition list | ConvertFrom-Json

# Initialize the output string with the opening of the Roles object
$output = "@export()`nvar Roles = {"

# Loop through each role definition to construct the body of the Roles object
foreach ($role in $roleDefinitions) {
    # Remove characters not allowed in variable names and construct the line
    $roleName = $role.roleName -replace '[()./-]', '' -replace ' ', ''
    $output += "`n    ${roleName}: '$($role.name)'"
}

# Close the Roles object
$output += "`n}"

# Output to a file
$output | Out-File -FilePath roletypes.bicep
