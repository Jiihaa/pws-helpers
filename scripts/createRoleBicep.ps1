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
