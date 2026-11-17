# PowerShell equivalent of 5_variables-migration.sh
# ============================================================
# GHEC -> GHEC: COMPLETE SYNC
# (ORG VARIABLES, REPO VARIABLES, ENV VARIABLES)
# Enterprise Version
# ============================================================
$ErrorActionPreference='Stop'
$CSV_FILE=if($env:CSV_FILE){$env:CSV_FILE}else{'repos_with_status.csv'}
if(-not $env:SOURCE_PAT){throw 'Set SOURCE_PAT'}
if(-not $env:TARGET_PAT){throw 'Set TARGET_PAT'}
$env:GH_PAT=$env:TARGET_PAT
$SOURCE_API_URL=if($env:SOURCE_API_URL){$env:SOURCE_API_URL.TrimEnd('/')}else{'https://api.github.com'}
$TARGET_API_URL=if($env:TARGET_API_URL){$env:TARGET_API_URL.TrimEnd('/')}else{'https://api.github.com'}
function timestamp {(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')}
function log_info([string]$m){Write-Host "[$(timestamp)] [INFO]    $m"}
function log_warn([string]$m){Write-Host "[$(timestamp)] [WARN]    $m"}
function log_error([string]$m){[Console]::Error.WriteLine("[$(timestamp)] [ERROR]   $m")}
function log_success([string]$m){Write-Host "[$(timestamp)] [SUCCESS] $m"}
function log([string]$m){log_info $m}
function urlencode([string]$s){[uri]::EscapeDataString($s)}
function api_call([string]$side,[string]$context,[string]$method,[string]$path,[hashtable]$fields=@{}){
    $api=if($side -eq 'source'){$SOURCE_API_URL}else{$TARGET_API_URL}
    $token=if($side -eq 'source'){$env:SOURCE_PAT}else{$env:TARGET_PAT}
    $headers=@{Accept='application/vnd.github+json';'X-GitHub-Api-Version'='2022-11-28';Authorization="Bearer $token"}
    $url="$api$path"
    try{
        $parameters=@{Uri=$url;Headers=$headers;Method=$method;ErrorAction='Stop'}
        if($fields.Count){
            $parameters.Body = ConvertTo-Json -InputObject $fields -Compress -Depth 10
            $parameters.ContentType = 'application/json'
        }
        return Invoke-RestMethod @parameters
    }catch{
        if($side -eq 'source'){log_error "Source API failed [$context] :: $($_.Exception.Message)"}
        else{log_error "Target API failed [$context] :: $($_.Exception.Message)"}
        throw
    }
}
function api_source([string]$context,[string]$path){api_call 'source' $context 'GET' $path}
function api_target([string]$context,[string]$method,[string]$path,[hashtable]$fields=@{}){api_call 'target' $context $method $path $fields}
function repo_exists_source([string]$full){try{$null=api_source "check source repo exists: $full" "/repos/$full";return $true}catch{return $false}}
function repo_exists_target([string]$full){try{$null=api_target "check target repo exists: $full" 'GET' "/repos/$full";return $true}catch{return $false}}
$TOTAL_REPOS=0;$SUCCESS_REPOS=0;$FAILED_REPOS=0;$SKIPPED_REPOS=0
$TOTAL_ORG_VARS_SYNCED=0;$TOTAL_REPO_VARS_SYNCED=0;$TOTAL_ENVS_SYNCED=0;$TOTAL_ENV_VARS_SYNCED=0;$TOTAL_ENV_RULES_SYNCED=0
function sync_environment_data([string]$src_full,[string]$tgt_full,[string]$env_name){
    $env_enc=urlencode $env_name
    log_info "Creating environment: $env_name"
    try{$null=api_target "create environment: $tgt_full / $env_name" 'PUT' "/repos/$tgt_full/environments/$env_enc";log_success "Environment created/validated: $env_name"}
    catch{log_warn "Failed to create environment: $env_name";return $false}
    $repo_env_rules_synced=0;$repo_env_vars_synced=0
    # Environment protection-rule synchronization is intentionally disabled in the Bash source.
    try{$src_repo=api_source "get source repo id: $src_full" "/repos/$src_full"}
    catch{log_warn "Unable to resolve source repo id for '$src_full'. Skipping env vars for '$env_name'.";$src_repo=$null}
    if($src_repo){
        try{$tgt_repo=api_target "get target repo id: $tgt_full" 'GET' "/repos/$tgt_full"}
        catch{log_warn "Unable to resolve target repo id for '$tgt_full'. Skipping env vars for '$env_name'.";$tgt_repo=$null}
        if($tgt_repo){
            try{$env_vars=api_source "fetch source env vars: $src_full / $env_name" "/repositories/$($src_repo.id)/environments/$env_enc/variables"}
            catch{$env_vars=$null}
            foreach($v in @($env_vars.variables)){
                if(-not $v.name){continue}
                $path="/repositories/$($tgt_repo.id)/environments/$env_enc/variables"
                try{$null=api_target "create env var: $tgt_full / $env_name / $($v.name)" 'POST' $path @{name=$v.name;value=$v.value};log_success "Env Var synced: $env_name / $($v.name)";$repo_env_vars_synced++}
                catch{
                    try{$null=api_target "update env var: $tgt_full / $env_name / $($v.name)" 'PATCH' "$path/$($v.name)" @{name=$v.name;value=$v.value};log_success "Env Var synced: $env_name / $($v.name)";$repo_env_vars_synced++}
                    catch{log_warn "Failed to sync env var: $env_name / $($v.name)"}
                }
            }
        }
    }
    $script:TOTAL_ENV_VARS_SYNCED+=$repo_env_vars_synced
    $script:TOTAL_ENVS_SYNCED++
    log_info "Environment summary [$env_name] :: rules_synced=$repo_env_rules_synced env_vars_synced=$repo_env_vars_synced"
    return $true
}
function main{
    log_info 'Starting GHEC -> GHEC Variables Migration'
    log_info "Source API: $SOURCE_API_URL"
    log_info "Target API: $TARGET_API_URL"
    if($TARGET_API_URL -like '*ghe.com*'){log_info 'Target Data Residency environment detected'}else{log_info 'Target GitHub.com environment detected'}
    $seen_orgs=@{}
    if(-not(Test-Path $CSV_FILE)){log_error "CSV file not found: $CSV_FILE";exit 1}
    # The Bash implementation reads the status CSV positionally, skipping its header.
    foreach($line in @(Get-Content -LiteralPath $CSV_FILE | Select-Object -Skip 1)){
        $f=@($line -split ',' | ForEach-Object {$_.Replace('"','').Trim()})
        if($f.Count -lt 7){continue}
        $s_org,$s_repo,$t_org,$t_repo,$t_vis,$migration_status,$log_file=$f[0..6]
        if(-not $migration_status){log_warn "Skipping $s_org/$s_repo because migration status is empty";$script:SKIPPED_REPOS++;continue}
        if($migration_status.ToLowerInvariant() -notin 'success','succeeded'){log_error "Skipping $s_org/$s_repo because repository migration status is $migration_status";$script:FAILED_REPOS++;continue}
        if(-not $s_org -or -not $s_repo){continue}
        $script:TOTAL_REPOS++
        $local_repo_org_vars=0;$local_repo_repo_vars=0;$local_repo_envs=0;$local_failed=0
        $src_full="$s_org/$s_repo";$tgt_full="$t_org/$t_repo"
        log_info "Processing: $src_full -> $tgt_full"
        if(-not(repo_exists_source $src_full)){log_error "Source repository not found or inaccessible: $src_full";$script:FAILED_REPOS++;continue}
        if(-not(repo_exists_target $tgt_full)){log_error "Target repository not found or inaccessible: $tgt_full";$script:FAILED_REPOS++;continue}
        if(-not $seen_orgs.ContainsKey($s_org)){
            log_info "Syncing Org Vars for $t_org"
            $org_var_count=0
            try{$org_vars=api_source "fetch source org vars: $s_org" "/orgs/$s_org/actions/variables"}catch{$org_vars=$null}
            foreach($v in @($org_vars.variables)){
                if(-not $v.name){continue}
                try{$null=api_target "create org var: $t_org / $($v.name)" 'POST' "/orgs/$t_org/actions/variables" @{name=$v.name;value=$v.value;visibility='all'};$org_var_count++}
                catch{
                    try{$null=api_target "update org var: $t_org / $($v.name)" 'PATCH' "/orgs/$t_org/actions/variables/$($v.name)" @{name=$v.name;value=$v.value};$org_var_count++}
                    catch{log_warn "Failed to sync org var: $t_org / $($v.name)";$local_failed++}
                }
            }
            $seen_orgs[$s_org]=1;$script:TOTAL_ORG_VARS_SYNCED+=$org_var_count;$local_repo_org_vars=$org_var_count
            log_success "Org vars sync completed for $t_org (count=$org_var_count)"
        }else{log_info "Org vars already processed for source org '$s_org'; skipping duplicate org sync."}
        log_info 'Syncing Repo Vars'
        $repo_var_count=0
        try{$repo_vars=api_source "fetch source repo vars: $src_full" "/repos/$src_full/actions/variables"}catch{$repo_vars=$null}
        foreach($v in @($repo_vars.variables)){
            if(-not $v.name){continue}
            try{$null=api_target "create repo var: $tgt_full / $($v.name)" 'POST' "/repos/$tgt_full/actions/variables" @{name=$v.name;value=$v.value};$repo_var_count++}
            catch{
                try{$null=api_target "update repo var: $tgt_full / $($v.name)" 'PATCH' "/repos/$tgt_full/actions/variables/$($v.name)" @{name=$v.name;value=$v.value};$repo_var_count++}
                catch{log_warn "Failed to sync repo var: $tgt_full / $($v.name)";$local_failed++}
            }
        }
        $script:TOTAL_REPO_VARS_SYNCED+=$repo_var_count;$local_repo_repo_vars=$repo_var_count
        log_success "Repo vars sync completed for $tgt_full (count=$repo_var_count)"
        log_info 'Syncing Environments (Environment creation + Variables only)'
        try{$environments=api_source "fetch source environments: $src_full" "/repos/$src_full/environments"}catch{$environments=$null}
        $envs=@($environments.environments | ForEach-Object {$_.name})
        if(-not $envs.Count){log_info "No environments found for $src_full"}
        else{foreach($env_name in $envs){$env_name=([string]$env_name).Trim();if(-not $env_name){continue};$null=sync_environment_data $src_full $tgt_full $env_name;$local_repo_envs++}}
        if($local_failed -eq 0){$script:SUCCESS_REPOS++;log_success "Repository summary [$src_full -> $tgt_full] :: org_vars=$local_repo_org_vars repo_vars=$local_repo_repo_vars envs=$local_repo_envs failures=0"}
        else{$script:FAILED_REPOS++;log_warn "Repository summary [$src_full -> $tgt_full] :: org_vars=$local_repo_org_vars repo_vars=$local_repo_repo_vars envs=$local_repo_envs failures=$local_failed"}
    }
    log_success 'Migration Complete.'
    log_info "Final Summary :: repos_processed=$TOTAL_REPOS repos_succeeded=$SUCCESS_REPOS repos_failed=$FAILED_REPOS repos_skipped=$SKIPPED_REPOS org_vars_synced=$TOTAL_ORG_VARS_SYNCED repo_vars_synced=$TOTAL_REPO_VARS_SYNCED envs_processed=$TOTAL_ENVS_SYNCED env_rules_synced=$TOTAL_ENV_RULES_SYNCED env_vars_synced=$TOTAL_ENV_VARS_SYNCED"
}
main
