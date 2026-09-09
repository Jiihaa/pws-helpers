param(
  [string]$SubscriptionId,            # optional; current sub if omitted
  [string]$Region,                    # optional filter, e.g. "swedencentral"
  [string]$ModelContains,             # optional substring, e.g. "gpt-4o"
  [string]$OutFile,                   # optional CSV export (per-deployment)
  [int]$SinceDays = 30,  
  [int]$SinceMinutes = 60,            # NEW: metrics lookback window (minutes)
  [switch]$Verbose                    # -Verbose to see discovery steps
)

# ---- Guards ----
if (-not (Get-Command az -ErrorAction SilentlyContinue)) { throw "Azure CLI not found. Install and 'az login'." }
try { az account show | Out-Null } catch { throw "Please run 'az login' first." }
Add-Type -AssemblyName 'System.Globalization' | Out-Null
$Invariant = [System.Globalization.CultureInfo]::InvariantCulture

# ---- Subscription ----
$subInfo = if ($SubscriptionId) { az account show --subscription $SubscriptionId -o json | ConvertFrom-Json } else { az account show -o json | ConvertFrom-Json }
$subId   = $subInfo.id
$subName = $subInfo.name

Write-Host "Enumerating Azure OpenAI deployments..." -ForegroundColor Cyan
Write-Host "Subscription: $subName ($subId)"
if ($Region)        { Write-Host "Filter Region: $Region" }
if ($ModelContains) { Write-Host "Filter ModelContains: $ModelContains" }
Write-Host ("Metrics lookback: last {0} day(s)" -f $SinceDays)
Write-Host ""

# ---- Find all OpenAI accounts ----
$allAccts = az cognitiveservices account list --subscription $subId -o json | ConvertFrom-Json
if (-not $allAccts) { Write-Host "No Cognitive Services accounts in subscription." -ForegroundColor Yellow; return }

$openaiAccts = $allAccts | Where-Object { $_.kind -eq 'OpenAI' }
if ($Region) { $openaiAccts = $openaiAccts | Where-Object { $_.location -eq $Region } }
Write-Verbose ("Found {0} OpenAI account(s) after region filter." -f (($openaiAccts|Measure-Object).Count))

if (-not $openaiAccts) { Write-Host "No OpenAI accounts matched your filters." -ForegroundColor Yellow; return }

# ---- Helper: get resource ID for metrics calls ----
function Get-AccountResourceId {
  param([string]$ResourceGroup,[string]$AccountName)
  $rid = az cognitiveservices account show -g $ResourceGroup -n $AccountName --subscription $subId --query id -o tsv
  return $rid
}

# ---- Helper: get deployment metrics totals in the last X minutes ----
function Get-DeploymentMetricsTotals {
  param(
    [string]$ResourceId,
    [string]$DeploymentName,
    [int]$Days
  )

  # Build UTC start/end for the window
  $endDto   = [DateTimeOffset]::UtcNow
  $startDto = $endDto.AddDays(-$Days)

  # Interval: finer granularity for short windows, daily for long windows
  if     ($Days -le 1) { $interval = 'PT5M' }
  elseif ($Days -le 7) { $interval = 'PT1H' }
  else                 { $interval = 'P1D' }

  # ISO 8601 with offset +00:00 (locale-safe)
  $fmt = 'yyyy-MM-ddTHH:mm:sszzz'
  $startIso = $startDto.ToString($fmt, [System.Globalization.CultureInfo]::InvariantCulture)
  $endIso   = $endDto.ToString($fmt,   [System.Globalization.CultureInfo]::InvariantCulture)

  $metricsToFetch = @(
    @{ Name = "AzureOpenAIRequests"; Key = "Requests" }
    @{ Name = "InputTokens";         Key = "PromptTokens" }
    @{ Name = "OutputTokens";        Key = "InferenceTokens" }
  )

  $totals = @{
    Requests        = 0
    PromptTokens    = 0
    InferenceTokens = 0
  }

  foreach ($m in $metricsToFetch) {
    try {
      $res = az monitor metrics list `
        --resource $ResourceId `
        --metric $($m.Name) `
        --interval $interval `
        --aggregation Total `
        --start-time $startIso `
        --end-time   $endIso `
        --filter "ModelDeploymentName eq '$DeploymentName'" `
        -o json | ConvertFrom-Json

      if ($res -and $res.value -and $res.value[0].timeseries -and $res.value[0].timeseries[0].data) {
        $points = $res.value[0].timeseries[0].data
        $sum = 0
        foreach ($p in $points) {
          if ($p.total -ne $null) { $sum += [decimal]$p.total }
        }
        $totals[$m.Key] = [int]$sum
      }
    } catch {
      # leave zeros if metric not available
    }
  }

  return $totals
}

# ---- Enumerate deployments, collect rows ----
$rows = @()
foreach ($acct in $openaiAccts) {
  $acctName = $acct.name; $rg = $acct.resourceGroup; $loc = $acct.location
  Write-Verbose ("Querying deployments for {0} (RG: {1}, Loc: {2})..." -f $acctName,$rg,$loc)
  $deploys = az cognitiveservices account deployment list -g $rg -n $acctName --subscription $subId -o json | ConvertFrom-Json
  Write-Verbose ("  -> Found {0} deployment(s)." -f (($deploys|Measure-Object).Count))
  if (-not $deploys) { continue }

  # Metrics resource id
  $rid = Get-AccountResourceId -ResourceGroup $rg -AccountName $acctName

  foreach ($d in $deploys) {
    $props = $d.properties
    $depModel = $null; $depSku = $null; $depCapRaw = $null

    if ($d.model) { $depModel = $d.model.name }
    if (-not $depModel -and $props -and $props.model) { $depModel = $props.model.name }
    if (-not $depModel) { $depModel = ($d.modelName, $props.modelName | Where-Object { $_ })[0] }
    if (-not $depModel) { $depModel = "<unknown-model>" }

    if ($d.sku) { $depSku = $d.sku.name }
    if (-not $depSku -and $props -and $props.sku) { $depSku = $props.sku.name }
    if (-not $depSku) { $depSku = "<unknown-sku>" }

    if ($d.sku) { $depCapRaw = $d.sku.capacity }
    if (-not $depCapRaw -and $props -and $props.sku) { $depCapRaw = $props.sku.capacity }
    if (-not $depCapRaw) { $depCapRaw = $d.capacity }
    $cap = [int]($depCapRaw ?? 0)

    if ($ModelContains -and ($depModel -notlike "*$ModelContains*")) { continue }

    $quotaKey = if ($depModel -and $depModel -ne "<unknown-model>") { "OpenAI.$depSku.$depModel" } else { "OpenAI.$depSku" }

    # NEW: per-deployment recent activity
    $m = Get-DeploymentMetricsTotals -ResourceId $rid -DeploymentName $d.name -Days $SinceDays

    $active = (($m.Requests + $m.PromptTokens + $m.InferenceTokens) -gt 0)

    $rows += [pscustomobject]@{
      SubscriptionId   = $subId
      SubscriptionName = $subName
      Account          = $acctName
      ResourceGroup    = $rg
      Location         = $loc
      Deployment       = $d.name
      Model            = $depModel
      SKU              = $depSku
      Capacity         = [int]$cap
      QuotaKey         = $quotaKey
      Requests         = [int]$m.Requests
      PromptTokens     = [int]$m.PromptTokens
      InferenceTokens  = [int]$m.InferenceTokens
      Active           = $active
    }
  }
}

if (-not $rows) {
  Write-Host "No deployments matched your filters." -ForegroundColor Yellow
  Write-Host "Tip: Try without -Region/-ModelContains or use -Verbose." -ForegroundColor Yellow
  return
}

# ---- Per-deployment detail + recent activity ----
Write-Host "=== Per-Deployment Capacity & Recent Activity (last $SinceMinutes min) ===" -ForegroundColor Cyan
$rows |
  Sort-Object Location, QuotaKey, Account, Deployment |
  Select-Object Location, QuotaKey, Account, ResourceGroup, Deployment, Model, SKU,
                @{n='Capacity';e={[int]$_.Capacity}},
                Requests, PromptTokens, InferenceTokens,
                @{n='Active';e={ if ($_.Active) {'Yes'} else {'No'} }} |
  Format-Table -AutoSize

if ($OutFile) {
  $rows | Export-Csv -Path $OutFile -NoTypeInformation -Encoding UTF8
  Write-Host "`nSaved details to: $OutFile"
}

# ---- Aggregated capacity (Region × QuotaKey) ----
$agg = $rows |
  Group-Object Location, QuotaKey |
  ForEach-Object {
    $sumCap = ($_.Group | Measure-Object Capacity -Sum).Sum
    [pscustomobject]@{
      Region     = $_.Group[0].Location
      QuotaKey   = $_.Group[0].QuotaKey
      TotalCap   = [int]$sumCap
      Deployments= ($_.Group | Select-Object -ExpandProperty Deployment | Measure-Object).Count
      Accounts   = ($_.Group | Select-Object -ExpandProperty Account -Unique) -join ", "
    }
  } | Sort-Object Region, QuotaKey

Write-Host "`n=== Aggregated Capacity (Region × QuotaKey) ===" -ForegroundColor Cyan
$agg | Select-Object Region, QuotaKey, @{n='TotalCap';e={[int]$_.TotalCap}}, Deployments, Accounts | Format-Table -AutoSize

# ---- Capacity vs subscription usage (Status) ----
Write-Host "`n=== Capacity vs Subscription Usage (Status) ===" -ForegroundColor Cyan

# Build usage map per region
$regions = ($agg | Select-Object -ExpandProperty Region -Unique)
$usageByRegion = @{}

foreach ($r in $regions) {
  $usageData = az cognitiveservices usage list --location $r --subscription $subId -o json | ConvertFrom-Json
  $map = @{}
  if ($usageData) {
    foreach ($u in $usageData) {
      $key = $u.name.value
      $map[$key] = [pscustomobject]@{
        Limit = [decimal]($u.limit ?? 0)
        Used  = [decimal]($u.currentValue ?? 0)
      }
    }
  }
  $usageByRegion[$r] = $map
}

# Compute status rows
$statusRows = @()
foreach ($row in $agg) {
  $r = $row.Region; $k = $row.QuotaKey; $cap = [decimal]$row.TotalCap
  $usageMap = $usageByRegion[$r]
  $limit = $null; $used = $null; $remaining = $null; $status = $null

  if ($usageMap -and $usageMap.ContainsKey($k)) {
    $limit = $usageMap[$k].Limit
    $used  = $usageMap[$k].Used
    $remaining = $limit - $used

    $overVsQuota = $cap - $limit
    if ($overVsQuota -gt 0) {
      $status = "Over-provisioned vs quota by $([int]$overVsQuota) (existing OK; growth blocked)"
    } elseif ($remaining -le 0) {
      $status = "No headroom (at/over limit)"
    } else {
      $status = "Headroom $([int]$remaining)"
    }
  } else {
    $status = "No usage row for key (quota unknown at subscription+region)"
  }

  $statusRows += [pscustomobject]@{
    Region     = $r
    QuotaKey   = $k
    Deployed   = [int]$cap
    UsageLimit = if ($limit -ne $null) { [int]$limit } else { $null }
    UsageUsed  = if ($used  -ne $null) { [int]$used  } else { $null }
    Remaining  = if ($remaining -ne $null) { [int]$remaining } else { $null }
    Status     = $status
  }
}

$statusRows | Sort-Object Region, QuotaKey | Format-Table -AutoSize
