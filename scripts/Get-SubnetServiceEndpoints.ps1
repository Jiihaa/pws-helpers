# Script to list all Service Endpoints in all Virtual Networks in the subscription

# Login to Azure if not already logged in
(az account show --query id 2>&1) -match "az login" -and (az login) | Out-Null

Write-Host "Getting all Virtual Networks in the subscriptions.."
$vNets = az network vnet list --query "[].id" -o tsv

# Initialize an array to hold results
$serviceEndpoints = @()

# Iterate through each Virtual Network
foreach ($vNetId in $vNets) {
    $vNetRg = az network vnet show --ids $vNetId --query "resourceGroup" -o tsv
    $vNetName = az network vnet show --ids $vNetId --query "name" -o tsv

    Write-Host "Checking VNet: $vNetName"
    $subnets = az network vnet subnet list --resource-group $vNetRg --vnet-name $vNetName --query "[].id" -o tsv

    # Iterate through each subnet in the VNet
    foreach ($subnetId in $subnets) {
        $subnetName = az network vnet subnet show --ids $subnetId --query "name" -o tsv

        Write-Host " - Subnet: $subnetName"

        $serviceEndpointsInSubnet = az network vnet subnet show --ids $subnetId --query "serviceEndpoints[].service" -o tsv

        if ($serviceEndpointsInSubnet) {
            foreach ($endpoint in $serviceEndpointsInSubnet -split "`n") {
                $serviceEndpoints += [PSCustomObject]@{
                    ResourceGroup    = $vNetRg
                    VNetName         = $vNetName
                    SubnetName       = $subnetName
                    ServiceEndpoint  = $endpoint
                }
            }
        }
    }
}

# Output the results
if ($serviceEndpoints.Count -eq 0) {
    Write-Output "No Service Endpoints found in the subscription."
} else {
    if ($IsWindows) {
        $serviceEndpoints | Out-GridView -Title "Service Endpoints in Virtual Networks"
    } else {
        $serviceEndpoints | Format-Table -AutoSize
    }
}
