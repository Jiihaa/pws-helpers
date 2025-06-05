# Script to check NSG assignments for all subnets in all virtual networks in an Azure subscription

# Login to Azure if not already logged in
(az account show --query id 2>&1) -match "az login" -and (az login) | Out-Null

# Get all virtual networks in the subscription
$vnetList = az network vnet list --query "[].{VNetName:name, ResourceGroup:resourceGroup}" -o json | ConvertFrom-Json

# Initialize an array to store results
$subnetResults = @()

# Iterate over each VNet to get its subnets and check NSG assignments
foreach ($vnet in $vnetList) {
    $subnetList = az network vnet subnet list --vnet-name $vnet.VNetName --resource-group $vnet.ResourceGroup --query "[].{SubnetName:name, NSG:networkSecurityGroup}" -o json | ConvertFrom-Json
    
    foreach ($subnet in $subnetList) {
        # Create a custom object to store the results
        $result = [pscustomobject]@{
            VNetName     = $vnet.VNetName
            SubnetName   = $subnet.SubnetName
            ResourceGroup = $vnet.ResourceGroup
            NSGAssigned  = if ($subnet.NSG) { $subnet.NSG.id } else { "No NSG Assigned" }
        }
        
        # Add the result to the array
        $subnetResults += $result
    }
}

# Display the results
if ($subnetResults.Count -eq 0) {
    Write-Host "No virtual networks or subnets found." -ForegroundColor Yellow
} else {
    if ($IsWindows) {
        $subnetResults | Out-GridView -Title "Virtual Networks and Subnet NSG Assignments"
    } else {
        $subnetResults | Format-Table -AutoSize
    }
}
