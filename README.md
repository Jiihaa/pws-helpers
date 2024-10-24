# pws-helpers
Collection of PowerShell Core helper scripts for Azure

| Script Name | Purpose | Parameters |
|-------------|---------|------------|
| groupRbacRights.ps1 | Find out recursively all the rights assigned to a RBAC group traversing from top management group | `GroupName`, `RootId` |
| directRbacAssigments.ps1 | Find out recursively all the direct rights assigned to a RBAC group traversing from top management group |  |
| getAllBudgets.ps1 | Find out all budgets set to management groups |  |
| createRoleBicep.ps1 | Create a bicep file with Role variable that gives readable name to every Azure RBAC role, which you can then import to your bicep, and instead of writing a guid, you can write for example Role.AcrPush instead of '8311e382-0749-4cb8-b61a-304f252e45ec' |  |
| checkNsgAssignments.ps1 | List all subnets and show if they have NSG assigned or not |  |
| showLatestApi.ps1 | Find out which of your Bicep files are not using the latest API version for a certain resource provider. Be aware, that latest API isn't always the best, but this will give you list you can check yourself | `resourceType` (Example: `Microsoft.Storage/storageAccounts`) |
| showServiceEndpoints.ps1 | List all service endpoints defined in all subnets |  |
