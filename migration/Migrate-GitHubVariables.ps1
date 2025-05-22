param(
    [Parameter(Mandatory)] [string]$SourceOrg,
    [Parameter(Mandatory)] [string]$SourceRepo,
    [Parameter(Mandatory)] [string]$TargetOrg,
    [Parameter(Mandatory)] [string]$TargetRepo,
    [Parameter(Mandatory)] [string]$SourcePAT,
    [Parameter(Mandatory)] [string]$TargetPAT,
    [string]$Scope = "actionsreposecrets",
    [switch]$Force
)

function Invoke-GitHubApi {
    param($Method, $Uri, $Token, $Body=$null)
    $Headers = @{ Authorization = "Bearer $Token"; Accept = "application/vnd.github+json" }
    $BodyJson = if ($Body) { $Body | ConvertTo-Json -Depth 10 } else { $null }
    try {
        Invoke-RestMethod -Method $Method -Uri $Uri -Headers $Headers -ContentType "application/json" -Body $BodyJson
    } catch {
        Write-Warning "API call failed: $($_.Exception.Message) [$Method $Uri]"
        return $null
    }
}

function Migrate-ActionsRepoSecrets {
    Write-Host "== Migrating ACTIONS REPOSITORY SECRETS =="
    $sUri = "https://api.github.com/repos/$SourceOrg/$SourceRepo/actions/secrets"
    $tUri = "https://api.github.com/repos/$TargetOrg/$TargetRepo/actions/secrets"
    $src = Invoke-GitHubApi GET $sUri $SourcePAT
    if (-not $src) { return }
    foreach ($sec in $src.secrets) {
        $n = $sec.name
        $exists = Invoke-GitHubApi GET "$tUri/$n" $TargetPAT
        if ($exists -and -not $Force) { Write-Host "Skipping existing secret $n"; continue }
        Write-Host "Copying secret $n"
        gh secret set $n --repo "$TargetOrg/$TargetRepo" --body ''
    }
}

function Migrate-ActionsRepoVariables {
    Write-Host "== Migrating ACTIONS REPOSITORY VARIABLES =="
    $sUri = "https://api.github.com/repos/$SourceOrg/$SourceRepo/actions/variables"
    $tUri = "https://api.github.com/repos/$TargetOrg/$TargetRepo/actions/variables"
    $src = Invoke-GitHubApi GET $sUri $SourcePAT
    if (-not $src) { return }
    $tgt = Invoke-GitHubApi GET $tUri $TargetPAT
    foreach ($var in $src.variables) {
        $n = $var.name; $v = $var.value
        if (($tgt.variables | where name -eq $n) -and -not $Force) { Write-Host "Skipping existing var $n"; continue }
        Write-Host "Copying var $n"
        gh variable set $n --repo "$TargetOrg/$TargetRepo" --body $v
    }
}

function Migrate-DependabotRepoSecrets {
    Write-Host "== Migrating DEPENDABOT REPOSITORY SECRETS =="
    $sUri = "https://api.github.com/repos/$SourceOrg/$SourceRepo/dependabot/secrets"
    $tUri = "https://api.github.com/repos/$TargetOrg/$TargetRepo/dependabot/secrets"
    $src = Invoke-GitHubApi GET $sUri $SourcePAT
    if (-not $src) { return }
    foreach ($sec in $src.secrets) {
        $n = $sec.name
        $exists = Invoke-GitHubApi GET "$tUri/$n" $TargetPAT
        if ($exists -and -not $Force) { Write-Host "Skipping exist secret $n"; continue }
        Write-Host "Copying dependabot secret $n"
        gh secret set $n --repo "$TargetOrg/$TargetRepo" --app dependabot --body ''
    }
}

function Migrate-CodespacesRepoSecrets {
    Write-Host "== Migrating CODESPACES REPOSITORY SECRETS =="
    $sUri = "https://api.github.com/repos/$SourceOrg/$SourceRepo/codespaces/secrets"
    $tUri = "https://api.github.com/repos/$TargetOrg/$TargetRepo/codespaces/secrets"
    $src = Invoke-GitHubApi GET $sUri $SourcePAT
    if (-not $src) { return }
    foreach ($sec in $src.secrets) {
        $n = $sec.name
        $exists = Invoke-GitHubApi GET "$tUri/$n" $TargetPAT
        if ($exists -and -not $Force) { Write-Host "Skipping exist secret $n"; continue }
        Write-Host "Copying codespaces secret $n"
        gh secret set $n --repo "$TargetOrg/$TargetRepo" --app codespaces --body ''
    }
}

function Migrate-ActionsEnvVariables {
    Write-Host "== Migrating ACTIONS ENVIRONMENT VARIABLES =="
    # 1) Get repo ID
    $repoInfo = Invoke-GitHubApi GET "https://api.github.com/repos/$SourceOrg/$SourceRepo" $SourcePAT
    if (-not $repoInfo) { return }
    $repoId = $repoInfo.id
    # 2) List environments
    $envs = Invoke-GitHubApi GET "https://api.github.com/repos/$SourceOrg/$SourceRepo/environments" $SourcePAT
    foreach ($env in $envs.environments) {
        $envName = $env.name
        Write-Host " Environment: $envName"
        # 3) List variables
        $vars = Invoke-GitHubApi GET "https://api.github.com/repositories/$repoId/environments/$envName/variables" $SourcePAT
        if (-not $vars) { continue }
        foreach ($v in $vars.variables) {
            $n = $v.name; $val = $v.value
            # Check existence
            $check = Invoke-GitHubApi GET "https://api.github.com/repositories/$repoId/environments/$envName/variables/$n" $TargetPAT
            if ($check -and -not $Force) { Write-Host "  Skipping var $n"; continue }
            Write-Host "  Copying var $n"
            # Create/update
            $body = @{ name=$n; value=$val }
            Invoke-GitHubApi PUT "https://api.github.com/repositories/$repoId/environments/$envName/variables/$n" $TargetPAT $body
        }
    }
}

foreach ($t in $Scope.Split(',')) {
    switch ($t.Trim().ToLower()) {
        'actionsreposecrets'        { Migrate-ActionsRepoSecrets @PSBoundParameters }
        'actionsrepovariables'      { Migrate-ActionsRepoVariables @PSBoundParameters }
        'dependabotreposecrets'     { Migrate-DependabotRepoSecrets @PSBoundParameters }
        'codespacesreposecrets'     { Migrate-CodespacesRepoSecrets @PSBoundParameters }
        'actionsenvvariables'       { Migrate-ActionsEnvVariables @PSBoundParameters }
        default { Write-Warning "Unknown type: $t" }
    }
}
