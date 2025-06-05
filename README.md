# pws-helpers
Collection of PowerShell Core helper scripts for Azure

| Script Name | Purpose | Parameters |
|-------------|---------|------------|
| Get-ActualCostsForMonth.ps1 | Get current Azure costs for the current month so far for all subscriptions |  |
| Get-AvailableVMs.ps1 | Filter and list available Azure VM sizes in a region based on CPU, memory, IOPS, NICs, features (like ephemeral disk, accelerated networking), and VM family | See detailed parameter descriptions below |
| Get-DirectRbacAssignments.ps1 | Find out recursively all the direct rights assigned to a RBAC group traversing from top management group |  |
| Get-GroupRbacRightsRecursively.ps1 | Find out recursively all the rights assigned to a RBAC group traversing from top management group | `GroupName`, `RootId` |
| Get-ManagementGroupBudgets.ps1 | Find out all budgets set to management groups |  |
| Get-NsgAssignments.ps1 | List all subnets and show if they have NSG assigned or not |  |
| Get-OrphanAssignments.ps1 | Find all RBAC assignments to deleted identities in management groups and subscriptions |  |
| Get-RoleAssigments.ps1 | Fetch role assignments for a resource group/all resource groups in subscription | |
| Get-SubnetServiceEndpoints.ps1 | List all service endpoints defined in all subnets |  |
| New-RoleDefinitionBicepMap.ps1 | Create a bicep file with Role variable that gives readable name to every Azure RBAC role, which you can then import to your bicep, and instead of writing a guid, you can write for example Role.AcrPush instead of '8311e382-0749-4cb8-b61a-304f252e45ec' |  |
| Test-BicepApiVersion.ps1 | Find out which of your Bicep files are not using the latest API version for a certain resource provider. Be aware, that latest API isn't always the best, but this will give you list you can check yourself | `resourceType` (Example: `Microsoft.Storage/storageAccounts`) |

## Get-AvailableVMs.ps1 Parameters

This script helps you find Azure VM sizes that match your specific requirements. At least one filter parameter must be provided.

### Basic Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `Region` | string | "westeurope" | Azure region to search for VM sizes (e.g., "northeurope", "eastus") |
| `Mode` | string | "exact" | Filtering mode: **"exact"** (match exactly) or **"min"** (minimum requirements) |

### Hardware Filtering Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `Cores` | int | Number of CPU cores. In "exact" mode: match exactly. In "min" mode: at least this many cores |
| `Memory` | int | Memory in GB. In "exact" mode: match exactly. In "min" mode: at least this much memory |
| `IOPS` | int | Uncached disk IOPS. In "exact" mode: match exactly. In "min" mode: at least this many IOPS |
| `NICs` | int | Maximum network interfaces. In "exact" mode: match exactly. In "min" mode: at least this many NICs |

### Feature Filtering Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `AcceleratedNetworking` | bool | Filter by accelerated networking support: `$true` (only VMs with support), `$false` (only VMs without support) |
| `EphemeralOSDisk` | bool | Filter by ephemeral OS disk support: `$true` (only VMs with support), `$false` (only VMs without support) |
| `PremiumIO` | bool | Filter by Premium SSD support: `$true` (only VMs with support), `$false` (only VMs without support) |
| `CapacityReservation` | bool | Filter by capacity reservation support: `$true` (only VMs with support), `$false` (only VMs without support) |

### VM Family and Version Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `Family` | string | VM family prefix (e.g., "D", "F", "E") to filter by specific VM series |
| `Latest` | switch | Show only the latest version of each VM family (e.g., from D4_v3, D4_v4, D4_v5 show only D4_v5) |

### Usage Examples

```powershell
# Find VMs with exactly 4 cores and Premium IO support
.\Get-AvailableVMs.ps1 -Cores 4 -PremiumIO $true

# Find VMs with at least 8 cores and 16GB memory in North Europe
.\Get-AvailableVMs.ps1 -Region northeurope -Mode min -Cores 8 -Memory 16

# Find latest versions of D-series VMs with accelerated networking
.\Get-AvailableVMs.ps1 -Family D -AcceleratedNetworking $true -Latest

# Find VMs that support ephemeral OS disks with at least 2 NICs
.\Get-AvailableVMs.ps1 -EphemeralOSDisk $true -Mode min -NICs 2

# Show only the latest VM versions across all families
.\Get-AvailableVMs.ps1 -Latest
```

### Output

- **Windows**: Results displayed in interactive GridView
- **macOS/Linux**: Results displayed as formatted table in terminal

The output includes VM name, cores, memory, IOPS, and feature support columns to help you make informed decisions about VM sizing.