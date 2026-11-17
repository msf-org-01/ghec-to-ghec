# PowerShell equivalent of 1_inventory-report.sh
$ErrorActionPreference = 'Stop'
function log_info($m) { Write-Output "[INFO]    $m" }
function log_warn($m) { [Console]::Error.WriteLine("[WARN]    $m") }
function log_error($m) { [Console]::Error.WriteLine("[ERROR]   $m") }
function log_success($m) { Write-Output "[SUCCESS] $m" }
$ORG = (Read-Host 'Enter the ORG name:').Trim('"')
if (-not $env:SOURCE_PAT) { throw 'Environment variable SOURCE_PAT is not set' }
$API_BASE = if ($env:SOURCE_API_URL) { $env:SOURCE_API_URL.TrimEnd('/') } else { 'https://api.github.com' }
$OUT_FILE = 'repos.csv'
function call_api([string]$url) {
    $headers = @{ Accept='application/vnd.github+json'; Authorization="Bearer $env:SOURCE_PAT" }
    try {
        $response = Invoke-WebRequest -Uri $url -Headers $headers -Method Get -SkipHttpErrorCheck
        return @{ status=[int]$response.StatusCode; body=[string]$response.Content; headers=$response.Headers }
    } catch { throw }
}
function validate_org {
    $result = call_api "$API_BASE/orgs/$ORG/repos?per_page=1&type=all"
    if ($result.status -eq 404) { log_error "Org not found: $ORG"; exit 1 }
    if ($result.status -in 401,403) { log_error "Authentication failed or access denied for org: $ORG"; exit 1 }
    if ($result.status -ne 200) { log_error "Failed to validate org: $ORG (HTTP $($result.status))"; exit 1 }
}
log_info "Validating organization '$ORG'..."
validate_org
# Keep old header exactly same
[System.IO.File]::WriteAllText((Join-Path (Get-Location) $OUT_FILE), "source_org,source_repo,repo_url,repo_size_MB`n", [System.Text.UTF8Encoding]::new($false))
$url = "$API_BASE/orgs/$ORG/repos?per_page=100&type=all"
$repo_count = 0
while ($url) {
    $result = call_api $url
    if ($result.status -eq 404) { log_error "Org not found: $ORG"; exit 1 }
    if ($result.status -ne 200) { log_error "Failed while retrieving repositories for org: $ORG (HTTP $($result.status))"; exit 1 }
    $repos = @($result.body | ConvertFrom-Json)
    foreach ($repo in $repos) {
        $size = [math]::Round(([double]$repo.size / 1024),2,[MidpointRounding]::AwayFromZero)
        $line = "$($repo.owner.login),$($repo.name),$($repo.html_url),$size`n"
        [System.IO.File]::AppendAllText((Join-Path (Get-Location) $OUT_FILE),$line,[System.Text.UTF8Encoding]::new($false))
        $repo_count++
    }
    $url = $null
    $links = @($result.headers['Link']) -join ','
    foreach ($link in ($links -split ',')) {
        if ($link -match '<([^>]+)>;\s*rel="next"') { $url = $Matches[1]; break }
    }
}
if ($repo_count -eq 0) { log_warn "Organization '$ORG' is valid, but no repositories were found." }
else { log_success "Inventory report generated successfully. Repositories found: $repo_count" }
log_info "Output file: $OUT_FILE"
