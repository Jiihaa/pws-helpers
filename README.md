# pws-helpers
Collection of PowerShell Core helper scripts for Azure

| Script Name | Purpose | Parameters |
|-------------|---------|------------|
| Get-ActualCostsForMonth.ps1 | Get current Azure costs for the current month so far for all subscriptions |  |
| Get-AvailableVMs.ps1 | Filter and list available Azure VM sizes in a region based on CPU, memory, IOPS, NICs, features (like ephemeral disk, accelerated networking), and VM family | See detailed parameter descriptions below |
| Get-DirectRbacAssignments.ps1 | List direct RBAC assignments for users and groups across accessible subscriptions, including resource group and resource scopes | IncludePrincipalId (optional), ManagementGroupId (optional), BillingCsv (optional), Out (optional) |
| Get-GroupRbacRightsRecursively.ps1 | Find out recursively all the rights assigned to a RBAC group traversing from top management group | `GroupName`, `RootId` |
| Get-ManagementGroupBudgets.ps1 | Find out all budgets set to management groups |  |
| Get-NsgAssignments.ps1 | List all subnets and show if they have NSG assigned or not |  |
| Get-OpenAIQuota.ps1 | Check Azure OpenAI quota usage and limits for a specific model in a given region | `Region`, `Model`, `SubscriptionId` (optional) |
| Get-OrphanAssignments.ps1 | Find all RBAC assignments to deleted identities in management groups and subscriptions |  |
| Get-RoleAssigments.ps1 | Fetch role assignments for a resource group/all resource groups in subscription | |
| Get-SubnetServiceEndpoints.ps1 | List all service endpoints defined in all subnets |  |
| Get-TenantId.ps1 | Retrieve Azure AD tenant ID for a given domain name | `Domain` (Example: `contoso.com`) |
| Test-BicepApiVersion.ps1 | Find out which of your Bicep files are not using the latest API version for a certain resource provider. Be aware, that latest API isn't always the best, but this will give you list you can check yourself | `resourceType` (Example: `Microsoft.Storage/storageAccounts`) |

## Get-DirectRbacAssignments.ps1 Parameters

This script lists direct RBAC assignments for principal types User and Group across subscriptions. It includes assignments at subscription, resource group, and resource scope by using Azure CLI with the all option.

By default, subscriptions are discovered from your current account context, which avoids requiring Microsoft.Management provider access.

### Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `IncludePrincipalId` | switch | No | Adds PrincipalId to output for audit-safe identity matching |
| `ManagementGroupId` | string | No | Limits discovery to one management group and all of its child management groups recursively |
| `BillingCsv` | string | No | Reads subscription IDs from a billing export CSV and checks only subscriptions in the `ID` column |
| `Out` | string | No | Writes results to a CSV file in the current working directory using the provided file name |

### Prerequisites

- Azure CLI installed and available in PATH
- Logged in with `az login`
- Permission to read role assignments in target subscriptions
- If using `ManagementGroupId`, permission to read that management group subtree and its subscriptions (this mode may require Microsoft.Management provider registration/rights in some environments)
- If using `BillingCsv`, a billing export CSV with an `ID` column containing subscription IDs

### Behavior Notes

- Disabled subscriptions are skipped automatically
- Duplicate subscriptions discovered through multiple management groups are processed only once
- Output includes: SubscriptionName, SubscriptionId, Scope, PrincipalName, Role, PrincipalType, and optionally PrincipalId
- When `BillingCsv` is used, the script only checks subscriptions from the CSV `ID` column and ignores the other discovery modes
- When `Out` is used, the script also exports results to CSV in the current working directory

### Usage Examples

```powershell
# Default mode: discover accessible subscriptions from current account context
.\Get-DirectRbacAssignments.ps1

# Include principalId for more reliable audit correlation
.\Get-DirectRbacAssignments.ps1 -IncludePrincipalId

# Optional: discover subscriptions from a specific management group subtree
.\Get-DirectRbacAssignments.ps1 -ManagementGroupId "contoso-platform"

# Optional: use subscription IDs from a billing export CSV
.\Get-DirectRbacAssignments.ps1 -BillingCsv "..\..\Subscriptions.csv"

# Combine both options
.\Get-DirectRbacAssignments.ps1 -ManagementGroupId "contoso-platform" -IncludePrincipalId

# Billing CSV with principalId included
.\Get-DirectRbacAssignments.ps1 -BillingCsv "..\..\Subscriptions.csv" -IncludePrincipalId

# Export to CSV in the current folder
.\Get-DirectRbacAssignments.ps1 -Out "direct-rbac.csv"

# Combine billing CSV and export file output
.\Get-DirectRbacAssignments.ps1 -BillingCsv "..\..\Subscriptions.csv" -Out "direct-rbac.csv"
```

### Output

- Windows: results are shown in GridView
- macOS/Linux: results are shown as a formatted table

## Get-AvailableVMs.ps1 Parameters

This script helps you find Azure VM sizes that match your specific requirements. At least one filter parameter must be provided.

### Basic Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `Region` | string | "westeurope" | Azure region to search for VM sizes (e.g., "northeurope", "eastus"). **Case-insensitive** |
| `Mode` | string | "exact" | Filtering mode: **"exact"** (match exactly) or **"min"** (minimum requirements). **Case-insensitive** |

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
| `Available` | bool | Filter by deployment availability: `$true` (only deployable VMs), `$false` (only restricted VMs) |

### VM Family and Version Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `Family` | string | VM family prefix (e.g., "D", "F", "E") to filter by specific VM series |
| `Latest` | switch | Show only the latest version of each VM family (e.g., from D4_v3, D4_v4, D4_v5 show only D4_v5) |

### Usage Examples

```powershell
# Find VMs with exactly 4 cores and Premium IO support
.\Get-AvailableVMs.ps1 -Cores 4 -PremiumIO $true

# Find VMs with at least 8 cores and 16GB memory in North Europe (case-insensitive)
.\Get-AvailableVMs.ps1 -Region "NorthEurope" -Mode "MIN" -Cores 8 -Memory 16

# Find latest versions of D-series VMs with accelerated networking
.\Get-AvailableVMs.ps1 -Family D -AcceleratedNetworking $true -Latest

# Find VMs that support ephemeral OS disks with at least 2 NICs
.\Get-AvailableVMs.ps1 -EphemeralOSDisk $true -Mode min -NICs 2

# Show only VMs that are available for deployment in West Europe
.\Get-AvailableVMs.ps1 -Region "westeurope" -Available $true

# Show only the latest VM versions across all families
.\Get-AvailableVMs.ps1 -Latest
```

### Output

- **Windows**: Results displayed in interactive GridView with availability counter in title
- **macOS/Linux**: Results displayed as formatted table in terminal
- **Availability Counter**: Shows "Available x/y VM sizes matching criteria" before results

The output includes VM name, cores, memory, IOPS, feature support columns, and deployment availability status to help you make informed decisions about VM sizing.

## Get-OpenAIQuota.ps1 Parameters

This script checks Azure OpenAI quota usage and limits for a specific model in a given region using Azure CLI.

### Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `Region` | string | Yes | Azure region to check (e.g., "eastus", "westeurope"). Alias: `-r` |
| `Model` | string | Yes | OpenAI model name (e.g., "OpenAI.GlobalStandard.gpt-4o"). Alias: `-m` |
| `SubscriptionId` | string | No | Azure subscription ID. Uses current subscription if omitted |

### Prerequisites

- Azure CLI installed and available in PATH
- User must be logged in via `az login`
- Appropriate permissions to read Cognitive Services usage data

### Usage Examples

```powershell
# Check GPT-4o quota in East US region
.\Get-OpenAIQuota.ps1 -Region "eastus" -Model "OpenAI.GlobalStandard.gpt-4o"

# Using aliases for shorter syntax
.\Get-OpenAIQuota.ps1 -r "westeurope" -m "OpenAI.GlobalStandard.gpt-35-turbo"

# Specify a different subscription
.\Get-OpenAIQuota.ps1 -Region "eastus" -Model "OpenAI.GlobalStandard.gpt-4o" -SubscriptionId "12345678-1234-1234-1234-123456789012"
```

### Output

The script displays:
- Subscription information (name and ID)
- Region and model details
- Total quota limit
- Current usage
- Remaining quota available

### Troubleshooting

- If no usage data is found, verify the region name and ensure you have appropriate permissions
- To see all available model names, run: `az cognitiveservices usage list --location <region> -o table`
- Common model names include:
  - `OpenAI.GlobalStandard.gpt-4o`
  - `OpenAI.GlobalStandard.gpt-35-turbo`
  - `OpenAI.GlobalStandard.gpt-4`

## Get-TenantId.ps1 Parameters

This script retrieves the Azure AD tenant ID for a given domain name using Microsoft's OpenID Connect discovery endpoint.

### Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `Domain` | string | Yes | The domain name to look up (e.g., "contoso.com", "microsoft.com") |

### Usage Examples

```powershell
# Get tenant ID for a domain
.\Get-TenantId.ps1 -Domain "contoso.com"

# Get tenant ID for Microsoft's domain
.\Get-TenantId.ps1 -Domain "microsoft.com"

# Store tenant ID in a variable
$tenantId = .\Get-TenantId.ps1 -Domain "yourdomain.com"
```

### Output

The script outputs:
- Success message with the domain and tenant ID
- The tenant ID is returned as a GUID string
- Error messages for invalid domains or network issues

This is useful for:
- Finding tenant IDs for Azure AD authentication
- Validating that a domain is associated with an Azure AD tenant
- Automating Azure AD configuration scripts