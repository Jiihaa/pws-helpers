param(
  [Parameter(Mandatory=$true)][Alias('r')][string]$Region,
  [Parameter(Mandatory=$true)][Alias('m')][string]$Model, # e.g. OpenAI.GlobalStandard.gpt-4o
  [string]$SubscriptionId # optional; uses current if omitted
)

# Ensure Azure CLI is available & logged in
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
  Write-Error "Azure CLI (az) not found. Install from https://aka.ms/azcli."
  exit 1
}
try { az account show | Out-Null } catch {
  Write-Error "Please log in first using 'az login'."
  exit 1
}

# Resolve subscription info
if ($SubscriptionId) {
  $subInfo = az account show --subscription $SubscriptionId -o json | ConvertFrom-Json
} else {
  $subInfo = az account show -o json | ConvertFrom-Json
}
$subId = $subInfo.id
$subName = $subInfo.name

Write-Host "Checking Azure OpenAI quota..." -ForegroundColor Cyan
Write-Host "Subscription: $subName ($subId)"
Write-Host "Region: $Region"
Write-Host "Model: $Model"
Write-Host ""

# Fetch usage/limits for Azure Cognitive Services (OpenAI) in the region
$all = az cognitiveservices usage list `
  --location $Region `
  --subscription $subId `
  -o json | ConvertFrom-Json

if (-not $all) {
  Write-Error "No usage/limit data found for region '$Region' (subscription $subId)."
  exit 1
}

# Try exact match first; fallback to contains
$entry = $all | Where-Object { $_.name.value -eq $Model } | Select-Object -First 1
if (-not $entry) { $entry = $all | Where-Object { $_.name.value -like "*$Model*" } | Select-Object -First 1 }

if (-not $entry) {
  Write-Error "No usage/limit entry matched '$Model' in region '$Region'.
Tip: run 'az cognitiveservices usage list --location $Region -o table' to see available names (e.g. OpenAI.GlobalStandard.gpt-4o)."
  exit 1
}

$limit = [decimal]($entry.limit   ?? 0)
$used  = [decimal]($entry.currentValue ?? 0)
$remaining = [decimal]($limit - $used)

# Output
Write-Host "=== Azure OpenAI Quota ===" -ForegroundColor Cyan
Write-Host "Subscription Name : $subName"
Write-Host "Subscription ID   : $subId"
Write-Host "Region            : $Region"
Write-Host "Model             : $($entry.name.value)"
Write-Host "Total quota       : $limit"
Write-Host "Used quota        : $used"
Write-Host "Remaining quota   : $remaining"
