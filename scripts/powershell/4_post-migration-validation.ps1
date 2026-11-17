# PowerShell equivalent of 4_post-migration-validation.sh
$ErrorActionPreference='Stop'
if (-not $env:SOURCE_PAT) { throw 'SOURCE_PAT not set' }
if (-not $env:TARGET_PAT) { throw 'TARGET_PAT not set' }
$env:GH_PAT=$env:TARGET_PAT
$SOURCE_API_URL=if($env:SOURCE_API_URL){$env:SOURCE_API_URL.TrimEnd('/')}else{'https://api.github.com'}
$TARGET_API_URL=if($env:TARGET_API_URL){$env:TARGET_API_URL.TrimEnd('/')}else{'https://api.github.com'}
$LOG_FILE='validation-log-'+(Get-Date -Format 'yyyyMMdd')+'.txt'
function write_log([string]$s) { Write-Host $s; Add-Content -LiteralPath $LOG_FILE -Value $s -Encoding utf8 }
function urlencode([string]$s) { [uri]::EscapeDataString($s) }
function api_get([string]$api_url,[string]$token,[string]$path) {
    try { return Invoke-RestMethod -Uri "$api_url$path" -Headers @{Accept='application/vnd.github+json';Authorization="token $token"} -ErrorAction Stop }
    catch { return $null }
}
function get_source_branches_json([string]$org,[string]$repo) {
    $page=1;$per_page=100;$all=[System.Collections.Generic.List[object]]::new()
    while($true){
        $enc_org=urlencode $org;$enc_repo=urlencode $repo
        $path="/repos/$enc_org/$enc_repo/branches?page=$page&per_page=$per_page"
        $resp=api_get $SOURCE_API_URL $env:SOURCE_PAT $path
        if($null -eq $resp){write_log "❌ Invalid JSON response from source branches API for $org/$repo";break}
        if($resp -isnot [array]){write_log "❌ Source branch API failed for ${org}/${repo}: $($resp.message)";break}
        foreach($r in $resp){$all.Add($r)}
        if($resp.Count -lt $per_page){break};$page++
    }
    return ,$all.ToArray()
}
function get_target_branches_json([string]$org,[string]$repo) {
    $page=1;$per_page=100;$all=[System.Collections.Generic.List[object]]::new()
    while($true){
        $path="/repos/$(urlencode $org)/$(urlencode $repo)/branches?page=$page&per_page=$per_page"
        $resp=api_get $TARGET_API_URL $env:TARGET_PAT $path
        if($null -eq $resp){write_log "❌ Failed to fetch Target branches for $org/$repo";break}
        if($resp -isnot [array]){write_log "❌ Target branch API failed for ${org}/${repo}: $($resp.message)";break}
        foreach($r in $resp){$all.Add($r)}
        if($resp.Count -lt $per_page){break};$page++
    }
    return ,$all.ToArray()
}
function get_latest_commit_sha([string]$api_url,[string]$token,[string]$org,[string]$repo,[string]$branch){
    $path="/repos/$(urlencode $org)/$(urlencode $repo)/commits?sha=$(urlencode $branch)&per_page=1"
    $resp=api_get $api_url $token $path
    if($null -eq $resp){return ''}
    return [string]@($resp)[0].sha
}
function validate_migration([string]$source_org,[string]$source_repo,[string]$target_org,[string]$target_repo){
    write_log ''
    write_log '============================================================'
    write_log "ℹ️  [$((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))] Validating: $source_org/$source_repo -> $target_org/$target_repo"
    write_log '============================================================'
    $target_array=@(get_target_branches_json $target_org $target_repo | ForEach-Object {$_.name})
    $source_array=@(get_source_branches_json $source_org $source_repo | ForEach-Object {$_.name})
    $target_map=@{};$source_map=@{}
    foreach($b in $target_array){$target_map[[string]$b]=1}
    foreach($b in $source_array){$source_map[[string]$b]=1}
    $missing_in_target=@($source_array | Where-Object {-not $target_map.ContainsKey([string]$_)})
    $missing_in_source=@($target_array | Where-Object {-not $source_map.ContainsKey([string]$_)})
    if($source_array.Count -eq $target_array.Count){write_log "✅ Branch Count MATCHED | source=$($source_array.Count) Target=$($target_array.Count)"}
    else{write_log "❌ Branch Count NOT MATCHED | source=$($source_array.Count) Target=$($target_array.Count)"}
    if($missing_in_target.Count){write_log "⚠️ Missing in Target: $($missing_in_target -join ' ')"}else{write_log '✅ No branches missing in Target'}
    if($missing_in_source.Count){write_log "⚠️ Extra in Target / Missing in Source: $($missing_in_source -join ' ')"}else{write_log '✅ No extra branches found'}
    $repo_info=api_get $TARGET_API_URL $env:TARGET_PAT "/repos/$(urlencode $target_org)/$(urlencode $target_repo)"
    $default_branch=[string]$repo_info.default_branch
    $target_limited_array=[System.Collections.Generic.List[string]]::new()
    $target_limited_array.Add($default_branch)
    foreach($b in $target_array){if($b -eq $default_branch){continue};$target_limited_array.Add([string]$b);if($target_limited_array.Count -eq 10){break}}
    write_log 'ℹ️ SHA validation running for default branch + maximum 9 additional branches'
    foreach($branch in $target_limited_array){
        if(-not $source_map.ContainsKey($branch)){continue}
        $target_sha=get_latest_commit_sha $TARGET_API_URL $env:TARGET_PAT $target_org $target_repo $branch
        $source_sha=get_latest_commit_sha $SOURCE_API_URL $env:SOURCE_PAT $source_org $source_repo $branch
        if($source_sha -and $source_sha -eq $target_sha){write_log "Branch '$branch': Source SHA=$source_sha | Target SHA=$target_sha | ✅ Matching"}
        else{write_log "Branch '$branch': Source SHA=$source_sha | Target SHA=$target_sha | ❌ NOT Matching"}
    }
    write_log "✅ Validation completed for: $target_org/$target_repo"
}
$csv='repos_with_status.csv'
if(-not(Test-Path $csv)){write_log "❌ CSV file not found: $csv";exit 1}
foreach($line in @(Get-Content $csv | Select-Object -Skip 1)){
    $f=@($line -split ',' | ForEach-Object {$_.Trim('"')})
    if($f.Count -lt 7){write_log '⚠️ Skipping invalid row';continue}
    $source_org,$source_repo,$target_org,$target_repo,$target_repo_visibility,$migration_status,$log_file=$f[0..6]
    if(-not $source_org -or -not $source_repo -or -not $target_org -or -not $target_repo){write_log '⚠️ Skipping invalid row';continue}
    if($migration_status.ToLowerInvariant() -notin 'success','succeeded'){write_log "⏭️ Skipping $source_org/$source_repo because migration status is $migration_status";continue}
    validate_migration $source_org $source_repo $target_org $target_repo
}
