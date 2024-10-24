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

# Output the results to Out-GridView
if ($serviceEndpoints.Count -eq 0) {
    Write-Output "No Service Endpoints found in the subscription."
} else {
    $serviceEndpoints | Out-GridView -Title "Service Endpoints in Virtual Networks"
}
