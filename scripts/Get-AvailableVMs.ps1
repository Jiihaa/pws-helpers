#!/usr/bin/env pwsh
param (
    [string]$Region = "westeurope",
    [string]$Mode = "exact",
    [int]$Cores,
    [int]$Memory,
    [int]$IOPS,
    [int]$NICs,
    $AcceleratedNetworking,
    $EphemeralOSDisk,
    $PremiumIO,
    $CapacityReservation,
    $Available,
    [string]$Family,
    [switch]$Latest

)

# Normalize and validate parameters
$Region = $Region.ToLower()
$Mode = $Mode.ToLower()

# Convert boolean-like parameters to actual booleans
function ConvertTo-Boolean($value) {
    if ($null -eq $value) { return $null }
    if ($value -is [bool]) { return $value }
    if ($value -is [int]) { return [bool]$value }
    if ($value -is [string]) {
        switch ($value.ToLower()) {
            "true" { return $true }
            "false" { return $false }
            "1" { return $true }
            "0" { return $false }
            "`$true" { return $true }
            "`$false" { return $false }
            default { 
                Write-Error "Invalid boolean value: '$value'. Use true/false, 1/0, or `$true/`$false"
                exit 1
            }
        }
    }
    Write-Error "Cannot convert value '$value' to boolean"
    exit 1
}

# Convert boolean parameters
if ($PSBoundParameters.ContainsKey("AcceleratedNetworking")) {
    $AcceleratedNetworking = ConvertTo-Boolean $AcceleratedNetworking
}
if ($PSBoundParameters.ContainsKey("EphemeralOSDisk")) {
    $EphemeralOSDisk = ConvertTo-Boolean $EphemeralOSDisk
}
if ($PSBoundParameters.ContainsKey("PremiumIO")) {
    $PremiumIO = ConvertTo-Boolean $PremiumIO
}
if ($PSBoundParameters.ContainsKey("CapacityReservation")) {
    $CapacityReservation = ConvertTo-Boolean $CapacityReservation
}
if ($PSBoundParameters.ContainsKey("Available")) {
    $Available = ConvertTo-Boolean $Available
}

# Validate Mode parameter
if ($Mode -notin @("min", "exact")) {
    Write-Error "Mode must be 'min' or 'exact' (case-insensitive). Provided value: '$Mode'"
    exit 1
}

# Check Azure CLI
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Write-Error "Azure CLI (az) not found. Please install and log in using 'az login'."
    exit 1
}

if (-not $PSBoundParameters.ContainsKey("Cores") -and -not $PSBoundParameters.ContainsKey("Memory") -and
    -not $PSBoundParameters.ContainsKey("IOPS") -and -not $PSBoundParameters.ContainsKey("NICs") -and
    -not $PSBoundParameters.ContainsKey("AcceleratedNetworking") -and
    -not $PSBoundParameters.ContainsKey("EphemeralOSDisk") -and
    -not $PSBoundParameters.ContainsKey("PremiumIO") -and
    -not $PSBoundParameters.ContainsKey("CapacityReservation") -and
    -not $PSBoundParameters.ContainsKey("Available") -and
    -not $PSBoundParameters.ContainsKey("Family") -and
    -not $Latest) {
    Write-Error "At least one filter parameter must be provided."
    exit 1
}

Write-Output "Fetching VM SKUs for region '$Region'..."

# Fetch VM SKUs with better error handling for cross-platform compatibility
$rawSkusJson = az vm list-skus --location $Region --resource-type "virtualMachines" --output json
if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to fetch VM SKUs from Azure CLI. Please ensure you are logged in with 'az login'."
    exit 1
}

# Handle JSON conversion with better cross-platform support
try {
    $rawSkus = $rawSkusJson | ConvertFrom-Json -Depth 10
} catch {
    Write-Error "Failed to parse VM SKU data. Error: $($_.Exception.Message)"
    exit 1
}

# Process SKUs
$vmSkus = $rawSkus | Where-Object { 
    # Case-insensitive region comparison
    $_.locations | ForEach-Object { $_.ToLower() } | Where-Object { $_ -eq $Region }
} | ForEach-Object {
    $capabilities = $_.capabilities

    $skuCores     = ($capabilities | Where-Object { $_.name -eq "vCPUs" }).value
    $skuMemory    = ($capabilities | Where-Object { $_.name -eq "MemoryGB" }).value
    $skuIOPS      = ($capabilities | Where-Object { $_.name -eq "UncachedDiskIOPS" }).value
    $accelNet     = ($capabilities | Where-Object { $_.name -eq "AcceleratedNetworkingEnabled" }).value
    $ephemeral    = ($capabilities | Where-Object { $_.name -eq "EphemeralOSDiskSupported" }).value
    $premiumIOCap = ($capabilities | Where-Object { $_.name -eq "PremiumIO" })
    $premiumIOValue = if ($premiumIOCap) { $premiumIOCap.value } else { $null }
    $reservationCap = ($capabilities | Where-Object { $_.name -eq "CapacityReservationSupported" })
    $reservationValue = if ($reservationCap) { $reservationCap.value } else { $null }
    $maxNics      = ($capabilities | Where-Object { $_.name -eq "MaxNetworkInterfaces" }).value

    # Check if VM is available for deployment (no location restrictions) - case-insensitive
    $isAvailable = -not ($_.restrictions | Where-Object { 
        $_.type -eq "Location" -and 
        ($_.restrictionInfo.locations | ForEach-Object { $_.ToLower() } | Where-Object { $_ -eq $Region }) -and
        ($_.reasonCode -eq "NotAvailableForSubscription" -or $_.reasonCode -eq "NotAvailableForRegion")
    })

    [PSCustomObject]@{
        Name                   = $_.name
        Size                   = $_.size
        Cores                  = [int]$skuCores
        Memory                 = [double]$skuMemory
        IOPS                   = if ($skuIOPS) { [int]$skuIOPS } else { $null }
        AcceleratedNetworking  = if (![string]::IsNullOrWhiteSpace($accelNet)) { [bool]::Parse($accelNet) } else { $false }
        EphemeralOSDisk        = if (![string]::IsNullOrWhiteSpace($ephemeral)) { [bool]::Parse($ephemeral) } else { $false }
        PremiumIO              = if (![string]::IsNullOrWhiteSpace($premiumIOValue)) { [bool]::Parse($premiumIOValue) } else { $false }
        CapacityReservation    = if (![string]::IsNullOrWhiteSpace($reservationValue)) { [bool]::Parse($reservationValue) } else { $false }
        MaxNICs                = if ($maxNics) { [int]$maxNics } else { $null }
        Available              = $isAvailable
        Family                 = $_.family
    }

}

$filtered = $vmSkus | Where-Object {
    # If only -Latest is specified, include all VMs (no filtering)
    if ($Latest -and -not $PSBoundParameters.ContainsKey("Cores") -and -not $PSBoundParameters.ContainsKey("Memory") -and
        -not $PSBoundParameters.ContainsKey("IOPS") -and -not $PSBoundParameters.ContainsKey("NICs") -and
        -not $PSBoundParameters.ContainsKey("AcceleratedNetworking") -and
        -not $PSBoundParameters.ContainsKey("EphemeralOSDisk") -and
        -not $PSBoundParameters.ContainsKey("PremiumIO") -and
        -not $PSBoundParameters.ContainsKey("CapacityReservation") -and
        -not $PSBoundParameters.ContainsKey("Available") -and
        -not $PSBoundParameters.ContainsKey("Family")) {
        return $true
    }

    $match = $true

    if ($Mode -eq "exact") {
        if ($PSBoundParameters.ContainsKey("Cores")) {
            $match = $match -and ($_.Cores -eq $Cores)
        }
        if ($PSBoundParameters.ContainsKey("Memory")) {
            $match = $match -and ($_.Memory -eq $Memory)
        }
        if ($PSBoundParameters.ContainsKey("IOPS")) {
            $match = $match -and ($_.IOPS -eq $IOPS)
        }
        if ($PSBoundParameters.ContainsKey("NICs")) {
            $match = $match -and ($_.MaxNICs -eq $NICs)
        }
    } else {
        if ($PSBoundParameters.ContainsKey("Cores")) {
            $match = $match -and ($_.Cores -ge $Cores)
        }
        if ($PSBoundParameters.ContainsKey("Memory")) {
            $match = $match -and ($_.Memory -ge $Memory)
        }
        if ($PSBoundParameters.ContainsKey("IOPS")) {
            $match = $match -and ($_.IOPS -ge $IOPS)
        }
        if ($PSBoundParameters.ContainsKey("NICs")) {
            $match = $match -and ($_.MaxNICs -ge $NICs)
        }
    }

    if ($PSBoundParameters.ContainsKey("AcceleratedNetworking")) {
        $match = $match -and ($_.AcceleratedNetworking -eq $AcceleratedNetworking)
    }
    if ($PSBoundParameters.ContainsKey("EphemeralOSDisk")) {
        $match = $match -and ($_.EphemeralOSDisk -eq $EphemeralOSDisk)
    }
    if ($PSBoundParameters.ContainsKey("PremiumIO")) {
        $match = $match -and ($_.PremiumIO -eq $PremiumIO)
    }
    if ($PSBoundParameters.ContainsKey("CapacityReservation")) {
        $match = $match -and ($_.CapacityReservation -eq $CapacityReservation)
    }
    if ($PSBoundParameters.ContainsKey("Available")) {
        $match = $match -and ($_.Available -eq $Available)
    }
    if ($PSBoundParameters.ContainsKey("Family")) {
        $vmFamilyPrefix = ($_.Size -replace '^([A-Za-z]{1,2}).*', '$1')

        $match = $match -and ($vmFamilyPrefix -eq $Family)
    }

    return $match
}

# Filter for latest versions if requested
if ($Latest) {
    
    $filtered = $filtered | Group-Object { 
        # Extract base family name by removing version and promo suffixes
        $name = $_.Name -replace '^Standard_', ''
        $baseName = $name -replace '_v\d+.*$', '' -replace '_Promo$', ''
        return $baseName
    } | ForEach-Object {
        $familyVMs = $_.Group
        
        # Group by version number
        $versionGroups = $familyVMs | Group-Object {
            $name = $_.Name -replace '^Standard_', ''
            if ($name -match '_v(\d+)') {
                [int]$matches[1]
            } else {
                1  # No version suffix means version 1
            }
        }
        
        # Get the highest version number and return all VMs with that version
        $maxVersion = ($versionGroups | Measure-Object Name -Maximum).Maximum
        $selectedVMs = ($versionGroups | Where-Object { [int]$_.Name -eq $maxVersion }).Group
        
        return $selectedVMs
    }
}

$sorted = $filtered | Sort-Object Memory, Cores

if ($sorted.Count -eq 0) {
    Write-Output "No VM sizes match the criteria."
} else {
    # Count available VMs vs total filtered VMs
    $availableCount = ($sorted | Where-Object { $_.Available -eq $true }).Count
    $totalCount = $sorted.Count
    Write-Output "Available $availableCount/$totalCount VM sizes matching criteria in $Region"
    Write-Output ""
    
    if ($IsWindows) {
        $sorted | Out-GridView -Title "Matching Azure VM Sizes in $Region (Available: $availableCount/$totalCount)"
    } else {
        $sorted | Select-Object Name,
            @{Name="MainFamily"; Expression={($_.Name -replace '^Standard_', '') -replace '^([A-Za-z]{1,2}).*', '$1'}},
            Cores,
            @{Name="MemoryGB"; Expression = { ($_.Memory.ToString("0.###")) }},
            IOPS, AcceleratedNetworking, EphemeralOSDisk, PremiumIO, CapacityReservation, Available, MaxNICs, Family |
        Format-Table -AutoSize
    }
}
