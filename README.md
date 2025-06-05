# pws-helpers
Collection of PowerShell Core helper scripts for Azure

| Script Name | Purpose | Parameters |
|-------------|---------|------------|
| Get-ActualCostsForMonth.ps1 | Get current Azure costs for the current month so far for all subscriptions |  |
| Get-AvailableVMs.ps1 | Filter and list available Azure VM sizes in a region based on CPU, memory, IOPS, NICs, features (like ephemeral disk, accelerated networking), and VM family | `Region`, `Mode`, `Cores`, `Memory`, `IOPS`, `NICs`, `AcceleratedNetworking`, `EphemeralOSDisk`, `CapacityReservation`, `Family` |
| Get-DirectRbacAssignments.ps1 | Find out recursively all the direct rights assigned to a RBAC group traversing from top management group |  |
| Get-GroupRbacRightsRecursively.ps1 | Find out recursively all the rights assigned to a RBAC group traversing from top management group | `GroupName`, `RootId` |
| Get-ManagementGroupBudgets.ps1 | Find out all budgets set to management groups |  |
| Get-NsgAssignments.ps1 | List all subnets and show if they have NSG assigned or not |  |
| Get-OrphanAssignments.ps1 | Find all RBAC assignments to deleted identities in management groups and subscriptions |  |
| Get-RoleAssigments.ps1 | Fetch role assignments for a resource group/all resource groups in subscription | |
| Get-SubnetServiceEndpoint.ps1 | List all service endpoints defined in all subnets |  |
| New-RoleDefinitionBicepMap.ps1 | Create a bicep file with Role variable that gives readable name to every Azure RBAC role, which you can then import to your bicep, and instead of writing a guid, you can write for example Role.AcrPush instead of '8311e382-0749-4cb8-b61a-304f252e45ec' |  |
| Test-BicepApiVersion.ps1 | Find out which of your Bicep files are not using the latest API version for a certain resource provider. Be aware, that latest API isn't always the best, but this will give you list you can check yourself | `resourceType` (Example: `Microsoft.Storage/storageAccounts`) |
