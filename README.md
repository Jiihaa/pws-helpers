# pws-helpers
Collection of PowerShell Core helper scripts for Azure

| Script Name | Purpose | Parameters |
|-------------|---------|------------|
| groupRbacRights.ps1 | Find out recursively all the rights assigned to a RBAC group traversing from top management group | `GroupName`, `RootId` |
| directRbacAssigments.ps1 | Find out recursively all the direct rights assigned to a RBAC group traversing from top management group |  |
| getAllBudgets.ps1 | Find out all budgets set to management groups |  |
| createRoleBicep.ps1 | Create a bicep file with Role variable that gives readable name to every Azure RBAC role, which you can then import to your bicep, and instead of writing a guid, you can write for example Role.AcrPush instead of '8311e382-0749-4cb8-b61a-304f252e45ec' |  |

