# PowerShell equivalent of 3_migration.sh
# GHEC -> GHEC parallel migration runner (GitHub Actions optimized)
$ErrorActionPreference='Stop'
$MAX_CONCURRENT=10;$CSV_PATH='repos.csv';$OUTPUT_PATH=''
for($i=0;$i -lt $args.Count;$i++){
    switch($args[$i]){
        '--max-concurrent' { $MAX_CONCURRENT=$args[++$i];break }
        '--csv' { $CSV_PATH=$args[++$i];break }
        '--output' { $OUTPUT_PATH=$args[++$i];break }
        default { if($args[$i].StartsWith('-')){Write-Host "[ERROR] Unknown option: $($args[$i])"}else{Write-Host "[ERROR] Unexpected positional arg: $($args[$i])"};exit 1 }
    }
}
if([string]$MAX_CONCURRENT -notmatch '^\d+$'){Write-Host '[ERROR] --max-concurrent must be an integer';exit 1}
$MAX_CONCURRENT=[int]$MAX_CONCURRENT
if($MAX_CONCURRENT -gt 10){Write-Host "[ERROR] Maximum concurrent migrations ($MAX_CONCURRENT) exceeds the allowed limit of 10.";Write-Host '[ERROR] Please set --max-concurrent to 10 or less.';exit 1}
if($MAX_CONCURRENT -lt 1){Write-Host '[ERROR] --max-concurrent must be at least 1.';exit 1}
if(-not(Test-Path $CSV_PATH)){Write-Host "[ERROR] CSV file not found: $CSV_PATH";exit 1}
$OUTPUT_CSV_PATH=if($OUTPUT_PATH){$OUTPUT_PATH}else{'repos_with_status.csv'}
if(-not $env:SOURCE_PAT){throw 'Environment variable SOURCE_PAT is not set'}
if(-not $env:TARGET_PAT){throw 'Environment variable TARGET_PAT is not set'}
$env:GH_PAT=$env:TARGET_PAT;$env:GH_SOURCE_PAT=$env:SOURCE_PAT
$SOURCE_API_URL=if($env:SOURCE_API_URL){$env:SOURCE_API_URL.TrimEnd('/')}else{'https://api.github.com'}
$TARGET_API_URL=if($env:TARGET_API_URL){$env:TARGET_API_URL.TrimEnd('/')}else{'https://api.github.com'}
$SOURCE_API_ARGS=@();$TARGET_API_ARGS=@()
if($SOURCE_API_URL -ne 'https://api.github.com'){$SOURCE_API_ARGS=@('--github-source-api-url',$SOURCE_API_URL);$env:GH_SOURCE_API_URL=$SOURCE_API_URL}
else{[Environment]::SetEnvironmentVariable('GH_SOURCE_API_URL',$null,'Process')}
if($TARGET_API_URL -ne 'https://api.github.com'){$TARGET_API_ARGS=@('--target-api-url',$TARGET_API_URL)}
$rows=@(Import-Csv -LiteralPath $CSV_PATH)
$REQUIRED_COLUMNS=@('source_org','source_repo','target_org','target_repo','target_repo_visibility')
$headers=if((Get-Content -LiteralPath $CSV_PATH -TotalCount 1)){@((Get-Content -LiteralPath $CSV_PATH -TotalCount 1) -split ',' | ForEach-Object {$_.Trim('"')})}else{@()}
$missing=@($REQUIRED_COLUMNS | Where-Object {$_ -notin $headers})
if($missing.Count){Write-Host "[ERROR] CSV missing required columns: $($missing -join ' ')";Write-Host "[ERROR] Required: $($REQUIRED_COLUMNS -join ' ')";exit 1}
$queue=[System.Collections.Generic.Queue[object]]::new();$lineNum=1
foreach($r in $rows){
    $lineNum++
    if(-not $r.source_org -or -not $r.source_repo -or -not $r.target_org -or -not $r.target_repo -or -not $r.target_repo_visibility){
        Write-Host "[WARNING] Skipping malformed line ${lineNum}: missing required columns"
        Write-Host 'Migration will be skipped. Please ensure source_org, source_repo, target_org, target_repo and target_repo_visibility are populated.';exit 1
    }
    $queue.Enqueue($r)
}
$statuses=[System.Collections.Generic.List[object]]::new()
foreach($r in $rows){$statuses.Add([pscustomobject]@{source_org=$r.source_org;source_repo=$r.source_repo;target_org=$r.target_org;target_repo=$r.target_repo;target_repo_visibility=$r.target_repo_visibility;Migration_Status='Pending';Log_File=''})}
function save_status {
    # Preserve the exact seven-column output header and column order.
    $lines=[System.Collections.Generic.List[string]]::new()
    $lines.Add('source_org,source_repo,target_org,target_repo,target_repo_visibility,Migration_Status,Log_File')
    foreach($r in $statuses){
        $values=@($r.source_org,$r.source_repo,$r.target_org,$r.target_repo,$r.target_repo_visibility,$r.Migration_Status,$r.Log_File)
        $lines.Add((($values | ForEach-Object {'"'+([string]$_).Replace('"','""')+'"'}) -join ','))
    }
    [System.IO.File]::WriteAllLines((Join-Path (Get-Location) $OUTPUT_CSV_PATH),$lines,[System.Text.UTF8Encoding]::new($false))
}
function update_repo_status_in_csv([string]$target_repo,[string]$status,[string]$log_file){
    foreach($r in $statuses){if($r.target_repo -ceq $target_repo){$r.Migration_Status=$status;$r.Log_File=$log_file}}
    save_status
}
save_status
Write-Host "[INFO] Starting migration with $MAX_CONCURRENT concurrent jobs..."
Write-Host "[INFO] Processing $($queue.Count) repositories from: $CSV_PATH"
Write-Host "[INFO] Initialized migration status output: $OUTPUT_CSV_PATH"
$running=[System.Collections.Generic.List[object]]::new();$migrated=0;$failed=0
function show_status_bar {Write-Host "QUEUE: $($queue.Count) IN PROGRESS: $($running.Count) MIGRATED: $migrated MIGRATION FAILED: $failed"}
while($queue.Count -gt 0 -or $running.Count -gt 0){
    while($running.Count -lt $MAX_CONCURRENT -and $queue.Count -gt 0){
        $r=$queue.Dequeue();$log_file='migration-'+$r.target_repo+'-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'.txt'
        update_repo_status_in_csv $r.target_repo 'In Progress' $log_file
        $arguments=@('gei','migrate-repo','--github-source-org',$r.source_org,'--source-repo',$r.source_repo,'--github-target-org',$r.target_org,'--target-repo',$r.target_repo,'--target-repo-visibility',$r.target_repo_visibility,'--github-source-pat',$env:SOURCE_PAT,'--github-target-pat',$env:TARGET_PAT)+$SOURCE_API_ARGS+$TARGET_API_ARGS
        $start="[$(Get-Date)] [START] Migration: $($r.source_org)/$($r.source_repo) -> $($r.target_org)/$($r.target_repo) (visibility: $($r.target_repo_visibility))"
        $debug="[$(Get-Date)] [DEBUG] Running migration: $($r.source_org)/$($r.source_repo) -> $($r.target_org)/$($r.target_repo)"
        [IO.File]::WriteAllLines((Join-Path (Get-Location) $log_file),@($start,$debug),[Text.UTF8Encoding]::new($false))
        $job=Start-ThreadJob -ArgumentList (,$arguments),$log_file,$r -ScriptBlock {
            param($arguments,$log_file,$r)
            $ErrorActionPreference='Continue'
            $output= & gh @arguments 2>&1 | Out-String
            $code=$LASTEXITCODE
            Add-Content -LiteralPath $log_file -Value $output
            if($output -match 'No operation will be performed'){Add-Content $log_file "[$(Get-Date)] [FAILED] No operation performed - repository may already exist or migration was skipped";return 'FAILED'}
            if($code -ne 0 -or $output -notmatch 'State: SUCCEEDED|SUCCEEDED'){Add-Content $log_file "[$(Get-Date)] [FAILED] Migration did not reach SUCCEEDED state";return 'FAILED'}
            Add-Content $log_file "[$(Get-Date)] [SUCCESS] Migration: $($r.source_org)/$($r.source_repo) -> $($r.target_org)/$($r.target_repo)"
            return 'SUCCESS'
        }
        $running.Add([pscustomobject]@{Job=$job;Repo=$r;Log=$log_file;Printed=0})
        show_status_bar
    }
    foreach($item in @($running.ToArray())){
        if(Test-Path $item.Log){
            $content=[IO.File]::ReadAllText((Join-Path (Get-Location) $item.Log))
            if($content.Length -gt $item.Printed){$delta=$content.Substring($item.Printed).Replace("`r",'');foreach($l in ($delta -split "`n")){if($l){Write-Host $l}};$item.Printed=$content.Length;show_status_bar}
        }
        if($item.Job.State -in 'Completed','Failed','Stopped'){
            $result=@(Receive-Job $item.Job -ErrorAction SilentlyContinue) -join ''
            if($result -eq 'SUCCESS'){$migrated++;update_repo_status_in_csv $item.Repo.target_repo 'Success' $item.Log}
            else{$failed++;update_repo_status_in_csv $item.Repo.target_repo 'Failure' $item.Log}
            Remove-Job $item.Job -Force;[void]$running.Remove($item);show_status_bar
        }
    }
    if($running.Count -gt 0 -or $queue.Count -gt 0){Start-Sleep -Seconds 2}
}
Write-Host '[INFO] All migrations completed.'
Write-Host "[SUMMARY] Total: $($rows.Count) Migrated: $migrated Failed: $failed"
Write-Host "[INFO] Wrote migration results with Migration_Status column: $OUTPUT_CSV_PATH"
if($failed -gt 0){Write-Host "[WARNING] Migration completed with $failed failures"}
