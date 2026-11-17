[CmdletBinding()]
param(
    [Parameter()]
    [string[]]$Organizations
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$AzureDevOpsResourceId = '499b84ac-1321-427f-aa17-267ca6975798'

function Get-AzureDevOpsAccessToken {
    $token = & az account get-access-token `
        --resource $AzureDevOpsResourceId `
        --query accessToken `
        --output tsv 2>$null

    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($token)) {
        throw "Unable to obtain an Azure DevOps access token. Run 'az login' first."
    }

    return $token
}

function Get-AccessibleOrganizations {
    param(
        [Parameter(Mandatory)]
        [string]$Token
    )

    $headers = @{
        Authorization = "Bearer $Token"
        Accept        = 'application/json'
    }

    $profile = Invoke-RestMethod -Method GET -Uri 'https://app.vssps.visualstudio.com/_apis/profile/profiles/me?api-version=7.1' -Headers $headers
    if (-not $profile.id) {
        throw 'Unable to determine the Azure DevOps profile ID.'
    }

    $accountsUri = "https://app.vssps.visualstudio.com/_apis/accounts?memberId=$($profile.id)&api-version=7.1"
    $accounts = Invoke-RestMethod -Method GET -Uri $accountsUri -Headers $headers

    return @(
        $accounts.value |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_.accountName) } |
            Select-Object -ExpandProperty accountName |
            Sort-Object -Unique
    )
}

function Get-ProjectCountForOrganization {
    param(
        [Parameter(Mandatory)]
        [string]$Organization,

        [Parameter(Mandatory)]
        [string]$Token
    )

    $orgName = $Organization.Trim().Trim('/')
    if ([string]::IsNullOrWhiteSpace($orgName)) {
        throw 'Organization name cannot be empty.'
    }

    $headers = @{
        Authorization = "Bearer $Token"
        Accept        = 'application/json'
    }

    $baseUri = "https://dev.azure.com/$orgName/_apis/projects?api-version=7.1-preview.4&`$top=1000"
    $total = 0
    $continuationToken = $null

    do {
        $requestUri = $baseUri
        if ($null -ne $continuationToken) {
            $requestUri = "$baseUri&continuationToken=$([System.Uri]::EscapeDataString([string]$continuationToken))"
        }

        $result = Invoke-RestMethod -Method GET -Uri $requestUri -Headers $headers
        if ($null -ne $result.value) {
            $total += @($result.value).Count
        }

        if ($result.PSObject.Properties.Name -contains 'continuationToken' -and $null -ne $result.continuationToken) {
            $continuationToken = [string]$result.continuationToken
        }
        else {
            $continuationToken = $null
        }
    } while ($null -ne $continuationToken)

    return $total
}

Write-Host 'Checking Azure CLI login...'
$azureContextJson = & az account show --output json 2>$null
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($azureContextJson)) {
    throw "Not logged in to Azure CLI. Run 'az login' first."
}

$azureContext = $azureContextJson | ConvertFrom-Json
Write-Host "Tenant: $($azureContext.tenantId)"
Write-Host "Signed in as: $($azureContext.user.name)"
Write-Host ""

$token = Get-AzureDevOpsAccessToken

$accessibleOrganizations = if ($Organizations -and $Organizations.Count -gt 0) {
    $Organizations |
        ForEach-Object { $_.Trim().Trim('/') } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Sort-Object -Unique
}
else {
    Get-AccessibleOrganizations -Token $token
}

if (-not $accessibleOrganizations -or $accessibleOrganizations.Count -eq 0) {
    throw 'No Azure DevOps organizations were found for the current tenant or signed-in user.'
}

$results = [System.Collections.Generic.List[psobject]]::new()
$totalProjects = 0

foreach ($organization in $accessibleOrganizations) {
    $orgName = $organization.Trim().Trim('/')
    if ([string]::IsNullOrWhiteSpace($orgName)) {
        continue
    }

    Write-Host "Checking organization: $orgName"

    try {
        $projectCount = Get-ProjectCountForOrganization -Organization $orgName -Token $token
        [void]$results.Add([pscustomobject]@{
                Organization = $orgName
                Projects    = $projectCount
            })

        $totalProjects += $projectCount
        Write-Host "  Project count: $projectCount"
    }
    catch {
        Write-Warning "Failed to query projects for '$orgName': $($_.Exception.Message)"
        [void]$results.Add([pscustomobject]@{
                Organization = $orgName
                Projects    = 0
            })
    }

    Write-Host ''
}

$results = $results | Sort-Object Organization
$results | Format-Table -AutoSize

Write-Host "Organizations checked: $($results.Count)"
Write-Host "Total projects in all organizations: $totalProjects"

return $results
