param (
    [string]$Region = "westeurope",
    [ValidateSet("min", "exact")]
    [string]$Mode = "exact",
    [int]$Cores,
    [int]$Memory,
    [int]$IOPS,
    [int]$NICs,
    [bool]$AcceleratedNetworking,
    [bool]$EphemeralOSDisk,
    [bool]$PremiumIO,
    [bool]$CapacityReservation,
    [string]$Family,
    [switch]$Latest

)


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
    -not $Latest) {
    Write-Error "At least one filter parameter must be provided."
    exit 1
}


Write-Output "Fetching VM SKUs for region '$Region'..."

# Fetch VM SKUs
$rawSkus = az vm list-skus --location $Region --resource-type "virtualMachines" --output json | ConvertFrom-Json

# Process SKUs
$vmSkus = $rawSkus | Where-Object { $_.locations -contains $Region } | ForEach-Object {
    $capabilities = $_.capabilities

    $skuCores     = ($capabilities | Where-Object { $_.name -eq "vCPUs" }).value
    $skuMemory    = ($capabilities | Where-Object { $_.name -eq "MemoryGB" }).value
    $skuIOPS      = ($capabilities | Where-Object { $_.name -eq "UncachedDiskIOPS" }).value
    $accelNet     = ($capabilities | Where-Object { $_.name -eq "AcceleratedNetworkingEnabled" }).value
    $ephemeral    = ($capabilities | Where-Object { $_.name -eq "EphemeralOSDiskSupported" }).value
    $premiumIO    = ($capabilities | Where-Object { $_.name -eq "PremiumIO" }).value
    $reservation  = ($capabilities | Where-Object { $_.name -eq "CapacityReservationSupported" }).value
    $maxNics      = ($capabilities | Where-Object { $_.name -eq "MaxNetworkInterfaces" }).value

    [PSCustomObject]@{
        Name                   = $_.name
        Size                   = $_.size  # ← add this line
        Cores                  = [int]$skuCores
        Memory                 = [double]$skuMemory
        IOPS                   = if ($skuIOPS) { [int]$skuIOPS } else { $null }
        AcceleratedNetworking  = if (![string]::IsNullOrWhiteSpace($accelNet)) { [bool]::Parse($accelNet) } else { $false }
        EphemeralOSDisk        = if (![string]::IsNullOrWhiteSpace($ephemeral)) { [bool]::Parse($ephemeral) } else { $false }
        PremiumIO              = if (![string]::IsNullOrWhiteSpace($premiumIO)) { [bool]::Parse($premiumIO) } else { $false }
        CapacityReservation    = if (![string]::IsNullOrWhiteSpace($reservation)) { [bool]::Parse($reservation) } else { $false }
        MaxNICs                = if ($maxNics) { [int]$maxNics } else { $null }
        Family                 = $_.family
    }

}

$filtered = $vmSkus | Where-Object {
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
        $familyName = $_.Name
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
    if ($IsWindows) {
        $sorted | Out-GridView -Title "Matching Azure VM Sizes in $Region"
    } else {
        $sorted | Select-Object Name,
            @{Name="ParsedFamily"; Expression={($_.Name -replace '^Standard_', '') -replace '^([A-Za-z]{1,2}).*', '$1'}},
            Cores,
            @{Name="MemoryGB"; Expression = { ($_.Memory.ToString("0.###")) }},
            IOPS, AcceleratedNetworking, EphemeralOSDisk, PremiumIO, CapacityReservation, MaxNICs, Family |
        Format-Table -AutoSize
    }
}
