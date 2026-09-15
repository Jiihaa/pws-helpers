#Requires -Version 7.0
<#
.SYNOPSIS
    Reports the most recent activity ("last touched") date for every project in an
    Azure DevOps organization, and which kind of artifact produced that date.

.DESCRIPTION
    For each project the script probes every service that can show activity:

        PipelineRun         latest build / YAML pipeline run (queue|start|finish time)
        ReleaseDeployment   latest classic release deployment
        WorkItemUpdated     System.ChangedDate of the most recently changed work item
        PullRequest         most recent PR creation or close (project-wide, 1 call)
        RepoCommit          latest commit on the default branch of any Git repo
        WikiEdit            latest commit in a project/code wiki
        TfvcChangeset       latest TFVC changeset (optional, -IncludeTfvc)
        ProjectMetadata     fallback: project.lastUpdateTime (see note below)

    Services that are disabled or that the PAT cannot read return 401/403/404 and are
    skipped silently; the project is still reported using whatever else was found.

    NOTE ON "CREATED": Azure DevOps does not expose a project creation date through the
    REST API. When nothing else is found the script falls back to project.lastUpdateTime,
    reported as type 'ProjectMetadata'. Treat that as "no activity found at or before
    this date", not as a creation timestamp.

.PARAMETER Organization
    Organization name ("contoso") or full URL ("https://dev.azure.com/contoso").

.PARAMETER Pat
    Personal access token. Defaults to $env:AZURE_DEVOPS_EXT_PAT.
    Required scopes (read-only): Project and Team (Read), Code (Read), Build (Read),
    Release (Read), Work Items (Read), Wiki (Read).

.PARAMETER SkipRepoCommits
    Skips the per-repository commit lookup. This is by far the most expensive probe
    (one call per repo). Pull requests and pipeline runs usually cover active repos;
    use this for a fast first pass over a large org.

.EXAMPLE
    $env:AZURE_DEVOPS_EXT_PAT = 'xxxx'
    ./Get-AdoProjectLastTouched.ps1 -Organization contoso -OutputCsv ./activity.csv -Verbose

.EXAMPLE
    ./Get-AdoProjectLastTouched.ps1 -Organization contoso |
        Where-Object DaysSinceTouched -gt 365 |
        Select-Object ProjectName, LastTouchedUtc, LastTouchedType
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Organization,

    [string]$Pat = $env:AZURE_DEVOPS_EXT_PAT,

    [string]$OutputCsv,

    [ValidateRange(1, 32)]
    [int]$ThrottleLimit = 8,

    [switch]$IncludeTfvc,

    [switch]$SkipRepoCommits,

    [string]$ApiVersion = '7.1'
)

$ErrorActionPreference = 'Stop'
Update-TypeData -TypeName 'Ado.ProjectLastActivity' `
    -DefaultDisplayPropertySet 'ProjectName', 'LastTouchedUtc', 'LastTouchedType', 'DaysSinceTouched' `
    -Force

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

# Accept either a bare org name or a full URL.
$orgName = $Organization.Trim().TrimEnd('/')
if ($orgName -match '^https?://') {
    $orgName = ($orgName -split '/')[-1]
}

Write-Verbose "Starting script for organization $orgName"

if ([string]::IsNullOrWhiteSpace($Pat)) {
    throw "No PAT supplied. Pass -Pat or set `$env:AZURE_DEVOPS_EXT_PAT."
}

$coreUrl = "https://dev.azure.com/$orgName"
$vsrmUrl = "https://vsrm.dev.azure.com/$orgName"

$authValue = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$Pat"))
$headers = @{
    Authorization = "Basic $authValue"
    Accept        = 'application/json'
}

# ---------------------------------------------------------------------------
# Helper functions. Defined as text so they can be re-imported inside the
# parallel runspaces created by ForEach-Object -Parallel.
# ---------------------------------------------------------------------------

$helperDefinitions = @'
function Invoke-AdoApi {
    <#
        Returns the deserialized response, or $null when the resource is absent,
        forbidden, or the service is disabled for the project. Retries throttling
        and transient server errors.
    #>
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][hashtable]$Headers,
        [string]$Method = 'GET',
        $Body,
        [int]$MaxAttempts = 5
    )

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            $params = @{
                Uri             = $Uri
                Headers         = $Headers
                Method          = $Method
                ErrorAction     = 'Stop'
                MaximumRedirection = 0
            }
            if ($null -ne $Body) {
                $params.Body        = $Body
                $params.ContentType = 'application/json'
            }

            $response = Invoke-RestMethod @params

            # A bad/expired PAT makes Azure DevOps return the HTML sign-in page
            # with HTTP 200 instead of a 401. Treat that as an auth failure.
            if ($response -is [string] -and $response -match '<html') {
                throw 'Received an HTML sign-in page instead of JSON. The PAT is likely invalid, expired, or lacks the required scope.'
            }

            return $response
        }
        catch {
            $status = $null
            if ($_.Exception.PSObject.Properties.Name -contains 'Response' -and $_.Exception.Response) {
                $status = [int]$_.Exception.Response.StatusCode
            }

            switch ($status) {
                { $_ -in 401, 403, 404 } {
                    # Service disabled for the project, or no permission. Not an error.
                    return $null
                }
                { $_ -in 429, 500, 502, 503, 504 } {
                    if ($attempt -eq $MaxAttempts) { return $null }
                    $wait = [Math]::Pow(2, $attempt)
                    try {
                        $retryAfter = $_.Exception.Response.Headers.GetValues('Retry-After')[0]
                        if ($retryAfter) { $wait = [int]$retryAfter }
                    } catch { }
                    Start-Sleep -Seconds $wait
                    continue
                }
                default {
                    if ($null -eq $status) { throw }   # DNS, TLS, invalid PAT
                    return $null
                }
            }
        }
    }
    return $null
}

function ConvertTo-UtcDate {
    param($Value)
    if ($null -eq $Value -or "$Value" -eq '') { return $null }
    try { return ([datetime]$Value).ToUniversalTime() } catch { return $null }
}

function New-Touch {
    param([string]$Type, $Date, [string]$Detail)
    $d = ConvertTo-UtcDate $Date
    if ($null -eq $d) { return $null }
    [pscustomobject]@{ Type = $Type; Date = $d; Detail = $Detail }
}

function Get-ProjectTouches {
    <#
        Probes every service for one project and emits zero or more touch candidates.
    #>
    param(
        [Parameter(Mandatory)]$Project,
        [Parameter(Mandatory)][hashtable]$Headers,
        [Parameter(Mandatory)][string]$CoreUrl,
        [Parameter(Mandatory)][string]$VsrmUrl,
        [Parameter(Mandatory)][string]$ApiVersion,
        [bool]$IncludeTfvc = $false,
        [bool]$SkipRepoCommits = $false,
        [System.Collections.Generic.List[string]]$Problems
    )

    $touches = [System.Collections.Generic.List[object]]::new()
    $pid_    = $Project.id
    $base    = "$CoreUrl/$pid_"

    function Add-Touch { param($t) if ($t) { $touches.Add($t) } }

    # --- Builds / YAML pipeline runs -----------------------------------------
    try {
        $uri = "$base/_apis/build/builds?api-version=$ApiVersion" + '&$top=1&queryOrder=queueTimeDescending'
        $r = Invoke-AdoApi -Uri $uri -Headers $Headers
        if ($r.value -and $r.value.Count -gt 0) {
            $b = $r.value[0]
            $best = @($b.finishTime, $b.startTime, $b.queueTime) |
                    ForEach-Object { ConvertTo-UtcDate $_ } |
                    Where-Object { $_ } | Sort-Object -Descending | Select-Object -First 1
            Add-Touch (New-Touch -Type 'PipelineRun' -Date $best -Detail "$($b.definition.name) #$($b.buildNumber)")
        }
    } catch { $Problems.Add("builds: $($_.Exception.Message)") }

    # --- Classic release deployments -----------------------------------------
    try {
        $uri = "$VsrmUrl/$pid_/_apis/release/deployments?api-version=$ApiVersion" + '&$top=1&queryOrder=descending'
        $r = Invoke-AdoApi -Uri $uri -Headers $Headers
        if ($r.value -and $r.value.Count -gt 0) {
            $d = $r.value[0]
            $best = @($d.completedOn, $d.startedOn, $d.queuedOn, $d.lastModifiedOn) |
                    ForEach-Object { ConvertTo-UtcDate $_ } |
                    Where-Object { $_ } | Sort-Object -Descending | Select-Object -First 1
            Add-Touch (New-Touch -Type 'ReleaseDeployment' -Date $best -Detail $d.releaseDefinition.name)
        }
    } catch { $Problems.Add("releases: $($_.Exception.Message)") }

    # --- Work items (WIQL, then read ChangedDate off the winning item) --------
    try {
        $escapedProjectName = $Project.name.Replace("'", "''")
        $wiql = @{ query = "SELECT [System.Id] FROM WorkItems WHERE [System.TeamProject] = '$escapedProjectName' ORDER BY [System.ChangedDate] DESC" } | ConvertTo-Json
        $uri  = "$base/_apis/wit/wiql?api-version=$ApiVersion" + '&$top=1'
        $r = Invoke-AdoApi -Uri $uri -Headers $Headers -Method POST -Body $wiql
        if ($r.workItems -and $r.workItems.Count -gt 0) {
            $id  = $r.workItems[0].id
            $wi  = Invoke-AdoApi -Uri "$base/_apis/wit/workitems/$id`?api-version=$ApiVersion&fields=System.ChangedDate,System.WorkItemType" -Headers $Headers
            if ($wi) {
                Add-Touch (New-Touch -Type 'WorkItemUpdated' `
                                     -Date $wi.fields.'System.ChangedDate' `
                                     -Detail "$($wi.fields.'System.WorkItemType') #$id")
            }
        }
    } catch { $Problems.Add("workitems: $($_.Exception.Message)") }

    # --- Pull requests (project-wide, one call, catches most repo activity) ---
    try {
        $uri = "$base/_apis/git/pullrequests?api-version=$ApiVersion" + '&searchCriteria.status=all&$top=1'
        $r = Invoke-AdoApi -Uri $uri -Headers $Headers
        if ($r.value -and $r.value.Count -gt 0) {
            $pr = $r.value[0]
            $best = @($pr.closedDate, $pr.creationDate) |
                    ForEach-Object { ConvertTo-UtcDate $_ } |
                    Where-Object { $_ } | Sort-Object -Descending | Select-Object -First 1
            Add-Touch (New-Touch -Type 'PullRequest' -Date $best -Detail "$($pr.repository.name) !$($pr.pullRequestId)")
        }
    } catch { $Problems.Add("pullrequests: $($_.Exception.Message)") }

    # --- Git commits, per repository -----------------------------------------
    if (-not $SkipRepoCommits) {
        try {
            $repos = Invoke-AdoApi -Uri "$base/_apis/git/repositories?api-version=$ApiVersion" -Headers $Headers
            foreach ($repo in @($repos.value)) {
                if ($repo.isDisabled) { continue }
                if ($null -eq $repo.defaultBranch) { continue }   # empty repo, never pushed to
                $uri = "$base/_apis/git/repositories/$($repo.id)/commits?api-version=$ApiVersion" + '&searchCriteria.$top=1'
                $c = Invoke-AdoApi -Uri $uri -Headers $Headers
                if ($c.value -and $c.value.Count -gt 0) {
                    $commit = $c.value[0]
                    $best = @($commit.committer.date, $commit.author.date) |
                            ForEach-Object { ConvertTo-UtcDate $_ } |
                            Where-Object { $_ } | Sort-Object -Descending | Select-Object -First 1
                    Add-Touch (New-Touch -Type 'RepoCommit' -Date $best -Detail $repo.name)
                }
            }
        } catch { $Problems.Add("repos: $($_.Exception.Message)") }
    }

    # --- Wikis (project wikis are Git repos not listed under /repositories) ---
    try {
        $wikis = Invoke-AdoApi -Uri "$base/_apis/wiki/wikis?api-version=$ApiVersion" -Headers $Headers
        foreach ($wiki in @($wikis.value)) {
            if (-not $wiki.repositoryId) { continue }
            $uri = "$base/_apis/git/repositories/$($wiki.repositoryId)/commits?api-version=$ApiVersion" + '&searchCriteria.$top=1'
            $c = Invoke-AdoApi -Uri $uri -Headers $Headers
            if ($c.value -and $c.value.Count -gt 0) {
                Add-Touch (New-Touch -Type 'WikiEdit' -Date $c.value[0].committer.date -Detail $wiki.name)
            }
        }
    } catch { $Problems.Add("wiki: $($_.Exception.Message)") }

    # --- TFVC ----------------------------------------------------------------
    if ($IncludeTfvc) {
        try {
            $uri = "$base/_apis/tfvc/changesets?api-version=$ApiVersion" + '&$top=1&$orderby=id desc'
            $r = Invoke-AdoApi -Uri $uri -Headers $Headers
            if ($r.value -and $r.value.Count -gt 0) {
                Add-Touch (New-Touch -Type 'TfvcChangeset' -Date $r.value[0].createdDate -Detail "C$($r.value[0].changesetId)")
            }
        } catch { $Problems.Add("tfvc: $($_.Exception.Message)") }
    }

    # --- Fallback: project metadata timestamp --------------------------------
    Add-Touch (New-Touch -Type 'ProjectMetadata' -Date $Project.lastUpdateTime -Detail 'no activity found; project metadata timestamp')

    return $touches
}
'@

# Load helpers into the current session too (used for the connectivity check).
. ([scriptblock]::Create($helperDefinitions))

# ---------------------------------------------------------------------------
# Enumerate projects (paged)
# ---------------------------------------------------------------------------

Write-Verbose "Enumerating projects in '$orgName'..."

$projects = [System.Collections.Generic.List[object]]::new()
$continuationToken = $null

do {
    $uri = "$coreUrl/_apis/projects?api-version=$ApiVersion" + '&$top=200&stateFilter=all'
    if ($continuationToken) { $uri += "&continuationToken=$continuationToken" }

    try {
        $response = Invoke-WebRequest -Uri $uri -Headers $headers -Method GET -ErrorAction Stop
    }
    catch {
        throw "Failed to list projects for '$orgName'. Check the organization name and PAT. $($_.Exception.Message)"
    }

    $payload = $response.Content | ConvertFrom-Json
    if ($null -eq $payload.value) {
        throw "Unexpected response listing projects. The PAT is probably invalid or lacks 'Project and Team (Read)'."
    }

    foreach ($p in $payload.value) { $projects.Add($p) }

    $continuationToken = $response.Headers['x-ms-continuationtoken']
    if ($continuationToken -is [array]) { $continuationToken = $continuationToken[0] }

} while ($continuationToken)

$total = $projects.Count
if ($total -eq 0) { Write-Warning 'No projects found.'; return }
Write-Host "Found $total project(s). Probing activity with $ThrottleLimit parallel workers..." -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# Probe each project in parallel
# ---------------------------------------------------------------------------

$done = [System.Collections.Concurrent.ConcurrentDictionary[string, byte]]::new()

$results = $projects | ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {
    . ([scriptblock]::Create($using:helperDefinitions))

    $project  = $_
    $problems = [System.Collections.Generic.List[string]]::new()

    try {
        $touches = Get-ProjectTouches -Project $project `
                                      -Headers $using:headers `
                                      -CoreUrl $using:coreUrl `
                                      -VsrmUrl $using:vsrmUrl `
                                      -ApiVersion $using:ApiVersion `
                                      -IncludeTfvc ([bool]$using:IncludeTfvc) `
                                      -SkipRepoCommits ([bool]$using:SkipRepoCommits) `
                                      -Problems $problems
    }
    catch {
        $problems.Add("fatal: $($_.Exception.Message)")
        $touches = @()
    }

    $winner = $touches | Sort-Object -Property Date -Descending | Select-Object -First 1

    # Everything found, for the diagnostics column.
    $all = ($touches | Sort-Object -Property Date -Descending |
            ForEach-Object { '{0}={1:yyyy-MM-dd}' -f $_.Type, $_.Date }) -join '; '

    $result = [pscustomobject]@{
        ProjectName      = $project.name
        LastTouchedUtc   = if ($winner) { $winner.Date } else { $null }
        LastTouchedType  = if ($winner) { $winner.Type } else { 'Unknown' }
        DaysSinceTouched = if ($winner) { [int]([datetime]::UtcNow - $winner.Date).TotalDays } else { $null }
        Detail           = if ($winner) { $winner.Detail } else { '' }
        ProjectState     = $project.state
        Visibility       = $project.visibility
        ProjectId        = $project.id
        AllSignals       = $all
        Problems         = ($problems -join ' | ')
    }

    $result.PSObject.TypeNames.Insert(0, 'Ado.ProjectLastActivity')

    $d = $using:done
    $null = $d.TryAdd($project.id, 1)
    Write-Verbose ("[{0}/{1}] {2,-45} {3:yyyy-MM-dd}  {4}" -f `
        $d.Count, $using:total, $project.name, $result.LastTouchedUtc, $result.LastTouchedType)

    $result
}

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

$sorted = $results | Sort-Object -Property LastTouchedUtc

if ($OutputCsv) {
    $sorted | Export-Csv -Path $OutputCsv -NoTypeInformation -Encoding utf8
    Write-Host "`nWrote $($sorted.Count) row(s) to $OutputCsv" -ForegroundColor Green
}

Write-Host "`nSummary by last-touch source:" -ForegroundColor Cyan
$sorted | Group-Object LastTouchedType | Sort-Object Count -Descending |
    Format-Table Name, Count -AutoSize | Out-Host

Write-Host 'Age distribution:' -ForegroundColor Cyan
$sorted |
    Group-Object { switch ($_.DaysSinceTouched) {
            { $null -eq $_ } { 'unknown';    break }
            { $_ -le 90 }    { '0-90 days';  break }
            { $_ -le 365 }   { '91-365 days';break }
            { $_ -le 730 }   { '1-2 years';  break }
            default          { '2+ years' } } } |
    Sort-Object Name | Format-Table Name, Count -AutoSize | Out-Host

$withProblems = @($sorted | Where-Object { $_.Problems })
if ($withProblems.Count -gt 0) {
    Write-Warning "$($withProblems.Count) project(s) hit errors during probing. See the Problems column."
}

Write-Host '`nProject activity:' -ForegroundColor Cyan
$sorted |
    Format-Table ProjectName, LastTouchedUtc, LastTouchedType, DaysSinceTouched, Detail, ProjectState, Visibility, ProjectId, AllSignals, Problems -Wrap | Out-Host