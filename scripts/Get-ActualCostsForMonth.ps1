# First, get an access token
$token = az account get-access-token --resource "https://management.azure.com" | ConvertFrom-Json

# Set headers for REST calls
$headers = @{
    'Authorization' = "Bearer $($token.accessToken)"
    'Content-Type'  = 'application/json'
}

# Get current date range
$today = Get-Date
$firstDayOfMonth = Get-Date -Year $today.Year -Month $today.Month -Day 1
$startDate = $firstDayOfMonth.ToString("yyyy-MM-dd")
$endDate = $today.ToString("yyyy-MM-dd")

# Get all subscriptions
$subsUrl = "https://management.azure.com/subscriptions?api-version=2020-01-01"
$subscriptions = Invoke-RestMethod -Uri $subsUrl -Headers $headers -Method Get | Select-Object -ExpandProperty value

Write-Host "Fetching cost data for $($subscriptions.Count) subscriptions: " -NoNewline

$totalCost = 0
$results = @()

foreach ($sub in $subscriptions) {
    # Build the cost analysis query
    $costQueryBody = @{
        type       = "Usage"
        timeframe  = "Custom"
        timePeriod = @{
            from = $startDate
            to   = $endDate
        }
        dataSet    = @{
            granularity = "None"
            aggregation = @{
                totalCost = @{
                    name     = "Cost"
                    function = "Sum"
                }
            }
        }
    } | ConvertTo-Json -Depth 10

    # Make the cost analysis REST call
    $costUrl = "https://management.azure.com/subscriptions/$($sub.subscriptionId)/providers/Microsoft.CostManagement/query?api-version=2024-08-01"

    try {
        $costData = Invoke-RestMethod -Uri $costUrl -Headers $headers -Method Post -Body $costQueryBody

        $subscriptionCost = 0  # Default to 0

        # Check if we have any cost data
        if ($costData.properties.rows -and $costData.properties.rows.Count -gt 0) {
            $subscriptionCost = $costData.properties.rows[0][0]
        }

        # Add to results array
        $results += [PSCustomObject]@{
            'Subscription Name' = $sub.displayName
            'Subscription ID'   = $sub.subscriptionId
            'Cost'              = [math]::Round($subscriptionCost, 2)
        }

        $totalCost += $subscriptionCost
        Write-Host "." -NoNewline
    }
    catch {
        Write-Host "x" -NoNewline
        Write-Host "`nError getting cost for subscription $($sub.displayName): $($_.Exception.Message)" -ForegroundColor Red
    }
}

Write-Host "`n"  # Add a newline after the dots

# Add total row
$results += [PSCustomObject]@{
    'Subscription Name' = "TOTAL"
    'Subscription ID'   = ""
    'Cost'              = [math]::Round($totalCost, 2)
}

# Output to console
$results | Format-Table -AutoSize

# Output to GridView (Windows only)
if ($IsWindows) {
    $results | Out-GridView -Title "Azure Costs ($startDate to $endDate)"
}
