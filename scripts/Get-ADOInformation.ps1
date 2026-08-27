[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$InputCsv,

    [Parameter()]
    [string]$Out = "azure-devops-org-summary.csv",

    [Parameter()]
    [string]$Pat
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-OrganizationUrls {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -Path $Path)) {
        throw "Input CSV file not found: $Path"
    }

    $rawContent = Get-Content -Path $Path -Raw
    if ([string]::IsNullOrWhiteSpace($rawContent)) {
        return @()
    }

    $urls = [System.Collections.Generic.List[string]]::new()

    try {
        $records = Import-Csv -Path $Path
        foreach ($record in $records) {
            foreach ($property in $record.PSObject.Properties) {
                $value = [string]$property.Value
                if ([string]::IsNullOrWhiteSpace($value)) {
                    continue
                }

                foreach ($part in ($value -split ',')) {
                    $trimmed = $part.Trim().Trim('"').Trim("'")
                    if ($trimmed -match '^https?://') {
                        [void]$urls.Add($trimmed)
                    }
                }
            }
        }
    }
    catch {
        foreach ($line in ($rawContent -split "`r?`n")) {
            foreach ($part in ($line -split ',')) {
                $trimmed = $part.Trim().Trim('"').Trim("'")
                if ($trimmed -match '^https?://') {
                    [void]$urls.Add($trimmed)
                }
            }
        }
    }

    return @($urls | Select-Object -Unique)
}

function Get-AdoOrganizationName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$OrganizationUrl
    )

    $uri = [System.Uri]$OrganizationUrl
    $orgDomain = $uri.Host.ToLowerInvariant()

    if ($orgDomain -eq 'dev.azure.com') {
        return $uri.AbsolutePath.Trim('/')
    }

    if ($orgDomain.EndsWith('.visualstudio.com')) {
        return $orgDomain.Substring(0, $orgDomain.IndexOf('.'))
    }

    throw "Unsupported Azure DevOps organization URL format: $OrganizationUrl"
}

function Test-AdoCliAvailable {
    $az = Get-Command az -ErrorAction SilentlyContinue
    if (-not $az) {
        throw "Azure CLI (az) is required. Install Azure CLI and run 'az login' before running this script."
    }

    $extension = az extension show --name azure-devops 2>$null
    if (-not $extension) {
        throw "The Azure DevOps CLI extension is not installed. Run 'az extension add --name azure-devops' and then 'az login'."
    }
}

function Invoke-AdoCliJson {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$CommandArgs,

        [Parameter(Mandatory = $true)]
        [string]$ErrorContext
    )

    $rawOutput = & az @CommandArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI returned exit code $LASTEXITCODE for ${ErrorContext}. Output: $($rawOutput | Out-String)"
    }

    $content = ($rawOutput | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($content)) {
        return $null
    }

    # Some az commands can emit warning lines into the merged output stream.
    # Strip them before JSON parsing so valid payloads are not treated as failures.
    $cleanContent = (
        $content -split "`r?`n" |
        Where-Object { $_ -notmatch '^\s*WARNING:' }
    ) -join "`n"

    $cleanContent = $cleanContent.Trim()
    if ([string]::IsNullOrWhiteSpace($cleanContent)) {
        return $null
    }

    try {
        return $cleanContent | ConvertFrom-Json
    }
    catch {
        # Recover from additional non-JSON lines by trimming to the outer JSON block.
        $objectStart = $cleanContent.IndexOf('{')
        $arrayStart = $cleanContent.IndexOf('[')

        $start = -1
        if ($objectStart -ge 0 -and $arrayStart -ge 0) {
            $start = [Math]::Min($objectStart, $arrayStart)
        }
        elseif ($objectStart -ge 0) {
            $start = $objectStart
        }
        elseif ($arrayStart -ge 0) {
            $start = $arrayStart
        }

        $objectEnd = $cleanContent.LastIndexOf('}')
        $arrayEnd = $cleanContent.LastIndexOf(']')
        $end = [Math]::Max($objectEnd, $arrayEnd)

        if ($start -ge 0 -and $end -gt $start) {
            $jsonSlice = $cleanContent.Substring($start, $end - $start + 1)
            try {
                return $jsonSlice | ConvertFrom-Json
            }
            catch {
                throw "Failed to parse Azure CLI JSON for ${ErrorContext}. Raw output: $content"
            }
        }

        throw "Failed to parse Azure CLI JSON for ${ErrorContext}. Raw output: $content"
    }
}

function Get-AdoObjectCount {
    param(
        [Parameter(Mandatory = $true)]
        [string]$OrganizationUrl,

        [Parameter(Mandatory = $true)]
        [ValidateSet('project', 'user')]
        [string]$Resource
    )

    $commandArgs = @(
        'devops', $Resource, 'list',
        '--organization', $OrganizationUrl,
        '--output', 'json'
    )

    $parsed = Invoke-AdoCliJson -CommandArgs $commandArgs -ErrorContext "$Resource on $OrganizationUrl"
    if (-not $parsed) {
        return 0
    }

    if ($parsed -is [System.Array]) {
        return @($parsed).Count
    }

    foreach ($propertyName in @('totalCount', 'count')) {
        if ($parsed.PSObject.Properties.Name -contains $propertyName -and $null -ne $parsed.$propertyName) {
            return [int]$parsed.$propertyName
        }
    }

    foreach ($propertyName in @('items', 'value', 'members')) {
        if ($parsed.PSObject.Properties.Name -contains $propertyName -and $null -ne $parsed.$propertyName) {
            return @($parsed.$propertyName).Count
        }
    }

    return 1
}

function Get-AdoCustomBuildAgentCount {
    param(
        [Parameter(Mandatory = $true)]
        [string]$OrganizationUrl
    )

    $pools = Invoke-AdoCliJson -CommandArgs @(
        'pipelines', 'pool', 'list',
        '--organization', $OrganizationUrl,
        '--output', 'json'
    ) -ErrorContext "pipeline pools on $OrganizationUrl"

    if (-not $pools) {
        return 0
    }

    $poolItems = @()
    if ($pools -is [System.Array]) {
        $poolItems = @($pools)
    }
    elseif ($pools.PSObject.Properties.Name -contains 'value') {
        $poolItems = @($pools.value)
    }

    $customAgentCount = 0
    foreach ($pool in $poolItems) {
        if (($pool.PSObject.Properties.Name -contains 'isHosted') -and $pool.isHosted) {
            continue
        }

        if (-not ($pool.PSObject.Properties.Name -contains 'id')) {
            continue
        }

        try {
            $agents = Invoke-AdoCliJson -CommandArgs @(
                'pipelines', 'agent', 'list',
                '--pool-id', [string]$pool.id,
                '--organization', $OrganizationUrl,
                '--output', 'json'
            ) -ErrorContext "pipeline agents for pool $($pool.id) on $OrganizationUrl"
        }
        catch {
            continue
        }

        if (-not $agents) {
            continue
        }

        $agentItems = @()
        if ($agents -is [System.Array]) {
            $agentItems = @($agents)
        }
        elseif ($agents.PSObject.Properties.Name -contains 'value') {
            $agentItems = @($agents.value)
        }

        $enabledCount = @(
            $agentItems | Where-Object {
                -not ($_.PSObject.Properties.Name -contains 'enabled') -or $_.enabled
            }
        ).Count

        $customAgentCount += $enabledCount
    }

    return $customAgentCount
}

function Get-AdoOrganizationOwnerEmail {
    param(
        [Parameter(Mandatory = $true)]
        [string]$OrganizationUrl,

        [Parameter(Mandatory = $true)]
        [string]$Pat
    )

    $organizationName = try { Get-AdoOrganizationName -OrganizationUrl $OrganizationUrl } catch { $null }

    if (-not [string]::IsNullOrWhiteSpace($organizationName)) {
        try {
            $trimmedPat = $Pat.Trim()
            if (-not [string]::IsNullOrWhiteSpace($trimmedPat)) {
                $basicAuth = [Convert]::ToBase64String(
                    [Text.Encoding]::ASCII.GetBytes(":$trimmedPat")
                )

                $headers = @{
                    Authorization = "Basic $basicAuth"
                    Accept = 'application/json'
                    'Content-Type' = 'application/json'
                }

                $body = @{
                    contributionIds = @(
                        'ms.vss-admin-web.organization-admin-overview-delay-load-data-provider'
                    )
                    dataProviderContext = @{
                        properties = @{}
                    }
                } | ConvertTo-Json -Depth 10

                $uri = "https://dev.azure.com/$organizationName/_apis/Contribution/HierarchyQuery?api-version=7.1-preview.1"
                $result = Invoke-RestMethod -Method Post -Uri $uri -Headers $headers -Body $body

                $provider = $result.dataProviders.'ms.vss-admin-web.organization-admin-overview-delay-load-data-provider'
                if ($provider -and $provider.currentOwner -and -not [string]::IsNullOrWhiteSpace($provider.currentOwner.email)) {
                    return $provider.currentOwner.email
                }
            }
        }
        catch {
            # Fall back to security-group based lookup when hierarchy query is unavailable.
        }
    }

    $groups = Invoke-AdoCliJson -CommandArgs @(
        'devops', 'security', 'group', 'list',
        '--organization', $OrganizationUrl,
        '--scope', 'organization',
        '--output', 'json'
    ) -ErrorContext "security groups on $OrganizationUrl"

    if (-not $groups) {
        return 'Unknown'
    }

    $groupItems = @()
    if ($groups -is [System.Array]) {
        $groupItems = @($groups)
    }
    elseif ($groups.PSObject.Properties.Name -contains 'value') {
        $groupItems = @($groups.value)
    }

    $adminGroup = $groupItems | Where-Object {
        ($_.displayName -eq 'Project Collection Administrators') -or
        ($_.principalName -like '*Project Collection Administrators*')
    } | Select-Object -First 1

    if (-not $adminGroup) {
        return 'Unknown'
    }

    $groupId = $adminGroup.descriptor
    if ([string]::IsNullOrWhiteSpace($groupId)) {
        return 'Unknown'
    }

    $memberships = Invoke-AdoCliJson -CommandArgs @(
        'devops', 'security', 'group', 'membership', 'list',
        '--id', $groupId,
        '--organization', $OrganizationUrl,
        '--output', 'json'
    ) -ErrorContext "admin group memberships on $OrganizationUrl"

    if (-not $memberships) {
        return 'Unknown'
    }

    $membershipItems = @()
    if ($memberships -is [System.Array]) {
        $membershipItems = @($memberships)
    }
    elseif ($memberships.PSObject.Properties.Name -contains 'value') {
        $membershipItems = @($memberships.value)
    }

    foreach ($membership in $membershipItems) {
        $descriptor = [string]$membership
        if ([string]::IsNullOrWhiteSpace($descriptor)) {
            continue
        }

        # Membership listing returns descriptors (aad.*, vssgp.*, etc.).
        # Only aad.* can be resolved directly as user identities.
        if (-not ($descriptor -like 'aad.*')) {
            continue
        }

        try {
            $user = Invoke-AdoCliJson -CommandArgs @(
                'devops', 'invoke',
                '--organization', $OrganizationUrl,
                '--area', 'graph',
                '--resource', 'users',
                '--route-parameters', "userDescriptor=$descriptor",
                '--api-version', '5.0-preview',
                '--output', 'json'
            ) -ErrorContext "graph user $descriptor on $OrganizationUrl"
        }
        catch {
            continue
        }

        if ($user -and -not [string]::IsNullOrWhiteSpace($user.mailAddress)) {
            return $user.mailAddress
        }

        if ($user -and -not [string]::IsNullOrWhiteSpace($user.principalName) -and ($user.principalName -match '@')) {
            return $user.principalName
        }
    }

    return 'Unknown'
}

$orgUrls = Get-OrganizationUrls -Path $InputCsv
if (-not $orgUrls -or $orgUrls.Count -eq 0) {
    throw "No valid Azure DevOps organization URLs were found in the input CSV file."
}

Test-AdoCliAvailable

$summary = foreach ($organizationUrl in $orgUrls) {
    $normalizedUrl = $organizationUrl.Trim().Trim('"').Trim("'")
    if (-not ($normalizedUrl -match '^https?://')) {
        continue
    }

    $organizationName = try { Get-AdoOrganizationName -OrganizationUrl $normalizedUrl } catch { $normalizedUrl }

    Write-Host -NoNewline "$organizationName"

    $projectCount = "No access"
    $userCount = "No access"
    $customBuildAgentCount = "No access"
    $ownerEmail = "No access"

    try {
        $projectCount = Get-AdoObjectCount -OrganizationUrl $normalizedUrl -Resource 'project'
    }
    catch { }

    Write-Host -NoNewline "`t$projectCount"

    try {
        $userCount = Get-AdoObjectCount -OrganizationUrl $normalizedUrl -Resource 'user'
    }
    catch { }

    Write-Host -NoNewline "`t$userCount"

    try {
        $customBuildAgentCount = Get-AdoCustomBuildAgentCount -OrganizationUrl $normalizedUrl
    }
    catch { }

    Write-Host -NoNewline "`t$customBuildAgentCount"

    if ([string]::IsNullOrWhiteSpace($Pat)) {
        $ownerEmail = "PAT required"
    }
    else {
        try {
            $ownerEmail = Get-AdoOrganizationOwnerEmail -OrganizationUrl $normalizedUrl -Pat $Pat
        }
        catch { }
    }

    Write-Host -NoNewline "`t$ownerEmail"
    Write-Host ""

    [PSCustomObject]@{
        OrganizationUrl = $normalizedUrl
        OrganizationName = $organizationName
        ProjectCount = $projectCount
        UserCount = $userCount
        CustomBuildAgentCount = $customBuildAgentCount
        OwnerEmail = $ownerEmail
    }
}

if ($summary) {
    $outputPath = if ([string]::IsNullOrWhiteSpace($Out)) { "azure-devops-org-summary.csv" } else { $Out }
    $summary | Sort-Object OrganizationUrl | Export-Csv -Path $outputPath -NoTypeInformation
    $summary | Sort-Object OrganizationUrl | Format-Table -AutoSize
    Write-Host "Summary written to $outputPath" -ForegroundColor Green
}
else {
    Write-Warning "No organization data was produced."
}
