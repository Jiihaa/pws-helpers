# Show the latest API version for a given resource type and find outdated API versions in Bicep files

param (
    [string]$resourceType  # Example: 'Microsoft.Storage/storageAccounts'
)

if (-not $resourceType) {
    Write-Error "Please provide a valid resource type (e.g., Microsoft.Storage/storageAccounts)."
    exit
}

# Split resourceType into namespace and resource type
$namespace = $resourceType.Split('/')[0]
$resource = $resourceType.Split('/')[1]

# Get all API versions for the specified resource type
$apiVersions = az provider show --namespace $namespace --query "resourceTypes[?resourceType=='$resource'].apiVersions" | ConvertFrom-Json

if (-not $apiVersions) {
    Write-Error "Could not retrieve API versions for $resourceType."
    exit
}

# Sort API versions in descending order and select the latest one
$apiVersionList = $apiVersions | Sort-Object -Descending
$latestApiVersion = $apiVersionList[0]

if (-not $latestApiVersion) {
    Write-Error "Could not determine the latest API version for $resourceType."
    exit
}

Write-Host "Latest API version for $resourceType : $latestApiVersion"

# Get all *.bicep files in the current directory and subdirectories
$files = Get-ChildItem -Path . -Recurse -Filter "*.bicep"

# Initialize an array to store the results for Out-GridView
$results = @()

# Loop through each Bicep file
foreach ($file in $files) {
    $fileContent = Get-Content $file.FullName

    # Track line number for better reference in the output
    $lineNumber = 0

    # Look for the resource definition that matches the provided resourceType
    foreach ($line in $fileContent) {
        $lineNumber++

        if ($line -match $resourceType) {
            # Extract the API version from the resource definition
            if ($line -match "@(\d{4}-\d{2}-\d{2})(\S*)") {
                $foundApiVersion = $matches[1]

                # Store the file, line, and found API version in an object
                $result = [pscustomobject]@{
                    FileName       = $file.FullName
                    LineNumber     = $lineNumber
                    ApiVersionUsed = $foundApiVersion
                    LineContent    = $line
                }

                # Add result to the array
                $results += $result
            }
        }
    }
}

# Output to GridView if any outdated API versions are found
if ($results.Count -eq 0) {
    Write-Host "No API versions found in the Bicep files matching $resourceType." -ForegroundColor Yellow
} else {
    $results | Out-GridView -Title "API Versions Used for $resourceType (Latest: $latestApiVersion)"
}
