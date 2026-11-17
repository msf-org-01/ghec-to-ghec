# PowerShell equivalent of 2_migration-readiness.sh
$ErrorActionPreference = 'Stop'
if (-not $env:SOURCE_PAT -and $args.Count -ge 2) { $env:SOURCE_PAT = $args[1] }
if (-not $env:SOURCE_API_URL) { $env:SOURCE_API_URL = 'https://api.github.com' }
if (-not $env:SOURCE_PAT) { Write-Host '[ERROR] SOURCE_PAT environment variable is not set. Please set your GitHub Source Personal Access Token.'; exit 1 }
if (-not $env:TARGET_PAT) { Write-Host '[ERROR] TARGET_PAT environment variable is not set. Please set your GitHub Target Personal Access Token.'; exit 1 }
$total_repos=0; $repos_with_active_prs=0; $repos_with_workflows=0; $repos_with_open_issues=0
$repo_results=[ordered]@{}
$csv_path=Join-Path $PSScriptRoot 'repos.csv'
if (-not (Test-Path $csv_path)) { Write-Host "CSV file $csv_path not found. Exiting..."; exit 1 }
Write-Host "`nReading input from file: '$csv_path'"
function urlencode([string]$s) { return [uri]::EscapeDataString($s) }
function api_get([string]$url) {
    try { return Invoke-RestMethod -Uri $url -Headers @{ Authorization="token $env:SOURCE_PAT" } -Method Get -ErrorAction Stop }
    catch { return $null }
}
$lines=Get-Content -LiteralPath $csv_path
foreach ($line in @($lines | Select-Object -Skip 1)) {
    $parts=$line -split ',',3
    $source_org=if ($parts.Count -gt 0) { $parts[0].Trim('"') } else { '' }
    $source_repo=if ($parts.Count -gt 1) { $parts[1].Trim('"') } else { '' }
    if (-not $source_org -or -not $source_repo) { Write-Host '[ERROR] Organization or repository name is empty. Skipping...'; continue }
    Write-Host "Processing Organization: '$source_org', Repository: '$source_repo'"
    $enc_gh_org=urlencode $source_org; $enc_selected_repo_name=urlencode $source_repo
    $pr_uri="$env:SOURCE_API_URL/repos/$enc_gh_org/$enc_selected_repo_name/pulls?state=open"
    $pr_response=api_get $pr_uri
    $repo_results[$source_repo]=''
    if ($null -ne $pr_response) {
        $pr_count=if ($pr_response.message -eq 'Not Found') { 0 } else { @($pr_response).Count }
        $total_repos++
        if ($pr_count -gt 0) { $repos_with_active_prs++; $repo_results[$source_repo]='Active PR' }
        $workflows_uri="$env:SOURCE_API_URL/repos/$enc_gh_org/$enc_selected_repo_name/actions/runs"
        $workflows_response=api_get $workflows_uri
        $running_or_queued_workflows_count=@($workflows_response.workflow_runs | Where-Object { $_.status -in 'in_progress','queued' }).Count
        if ($running_or_queued_workflows_count -gt 0) {
            $repos_with_workflows++
            if (-not $repo_results[$source_repo]) { $repo_results[$source_repo]='Workflow (Running or Queued)' }
            else { $repo_results[$source_repo]+=', Workflow (Running or Queued)' }
        }
        $open_issues_uri="$env:SOURCE_API_URL/repos/$enc_gh_org/$enc_selected_repo_name/issues?state=open"
        $open_issues_response=api_get $open_issues_uri
        $open_issues_count=@($open_issues_response | Where-Object { $null -eq $_.pull_request }).Count
        if ($open_issues_count -gt 0) {
            $repos_with_open_issues++
            if (-not $repo_results[$source_repo]) { $repo_results[$source_repo]='Open Issues' }
            else { $repo_results[$source_repo]+=', Open Issues' }
        }
    } else { Write-Host "[ERROR] Failed to process PRs for repository '$source_repo'." }
    if (-not $repo_results[$source_repo]) { $repo_results[$source_repo]='No Active/Open Items' }
}
Write-Host "`nPre-Migration Consolidated Summary"
Write-Host '====================================='
Write-Host "Total Repositories Processed: $total_repos"
Write-Host "Repositories with Active Pull Requests: $repos_with_active_prs"
Write-Host "Repositories with Workflows (Running or Queued): $repos_with_workflows"
Write-Host "Repositories with Open Issues: $repos_with_open_issues"
if ($repos_with_active_prs -gt 0) { Write-Host 'Warning: Some repositories have active pull requests. Please review them before proceeding.' }
if ($repos_with_open_issues -gt 0) { Write-Host 'Warning: Some repositories have open issues. Please review them before proceeding.' }
if ($total_repos -eq 0) { Write-Host '[ERROR] No repositories were processed. Please check your CSV file.'; exit 1 }
Write-Host "`nRepository-Specific Results:"
Write-Host '============================='
foreach ($repo in $repo_results.Keys) { Write-Host "${repo}: $($repo_results[$repo])" }
Write-Host '============================='
Write-Host "`nMigration validation complete. You can now proceed with migration if the necessary checks are met."
