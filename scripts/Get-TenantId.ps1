param (
    [Parameter(Mandatory=$true)]
    [string]$Domain
)

# Validate domain format (basic validation)
if (-not $Domain.Contains('.') -or $Domain.Contains(' ')) {
    Write-Error "Invalid domain format. Please provide a valid domain name (e.g., 'contoso.com')"
    exit 1
}

try {
    Write-Output "Retrieving tenant ID for domain '$Domain'..."
    
    # Construct the well-known OpenID configuration URL
    $uri = "https://login.microsoftonline.com/$Domain/v2.0/.well-known/openid-configuration"
    
    # Get the OpenID configuration and extract tenant ID from issuer URL
    $response = Invoke-RestMethod -Uri $uri -ErrorAction Stop
    $tenantId = ($response.issuer -split '/' | Select-Object -Index 3)
    
    if ($tenantId -and $tenantId -match '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') {
        Write-Output $tenantId
    } else {
        Write-Error "Failed to extract valid tenant ID from response"
        exit 1
    }
} catch {
    if ($_.Exception.Response.StatusCode -eq 400) {
        Write-Error "Domain '$Domain' not found or is not associated with an Azure AD tenant"
    } elseif ($_.Exception.Response.StatusCode -eq 404) {
        Write-Error "Domain '$Domain' not found"
    } else {
        Write-Error "Failed to retrieve tenant information for domain '$Domain': $($_.Exception.Message)"
    }
    exit 1
}
