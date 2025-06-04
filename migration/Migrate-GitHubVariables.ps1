param(
    [Parameter(Mandatory)] [string]$SourceOrg,
    [Parameter(Mandatory)] [string]$SourceRepo,
    [Parameter(Mandatory)] [string]$TargetOrg,
    [Parameter(Mandatory)] [string]$TargetRepo,
    [Parameter(Mandatory)] [string]$SourcePAT,
    [Parameter(Mandatory)] [string]$TargetPAT,
    [string]$Scope = "actionsreposecrets",
    [string]$TempSecretDir,
    [switch]$Force
)

# Trim spaces from organization and repository names
$SourceOrg = $SourceOrg.Trim()
$SourceRepo = $SourceRepo.Trim()
$TargetOrg = $TargetOrg.Trim()
$TargetRepo = $TargetRepo.Trim()

Write-Host "Source Organization: '$SourceOrg'"
Write-Host "Source Repository: '$SourceRepo'"
Write-Host "Target Organization: '$TargetOrg'"
Write-Host "Target Repository: '$TargetRepo'"

function Invoke-GitHubApi {
    param($Method, $Uri, $Token, $Body = $null)
    $Headers = @{ Authorization = "Bearer $Token"; Accept = "application/vnd.github+json" }
    $BodyJson = if ($Body) { $Body | ConvertTo-Json -Depth 10 } else { $null }
    try {
        Invoke-RestMethod -Method $Method -Uri $Uri -Headers $Headers -ContentType "application/json" -Body $BodyJson
    } catch {
        # Suppress 404 for existence checks; warn otherwise
        if ($_.Exception.Response.StatusCode.value__ -ne 404) {
            Write-Warning "API call failed: $($_.Exception.Message) [$Method $Uri]"
            Write-Warning "Response: $($_.ErrorDetails.Message)"
        }
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
        if ($exists -and -not $Force) { Write-Host "Skipping existing repo-action secret $n"; continue }
        Write-Host "Copying repo-action secret $n"
        
        # Use TARGET_PAT for GitHub CLI operations
        $env:GH_TOKEN = $TargetPAT
        echo "PLACEHOLDER_VALUE" | gh secret set $n --repo "$TargetOrg/$TargetRepo"
    }
}

function Migrate-ActionsRepoVariables {
    Write-Host "== Migrating ACTIONS REPOSITORY VARIABLES =="
    $sUri = "https://api.github.com/repos/$SourceOrg/$SourceRepo/actions/variables"
    $tUri = "https://api.github.com/repos/$TargetOrg/$TargetRepo/actions/variables"
    $src = Invoke-GitHubApi GET $sUri $SourcePAT
    if (-not $src) { return }
    foreach ($var in $src.variables) {
        $n = $var.name
        $exists = Invoke-GitHubApi GET "$tUri/$n" $TargetPAT
        if ($exists -and -not $Force) { Write-Host "Skipping existing repo-action variable $n"; continue }
        Write-Host "Copying repo-action variable $n"
        
        # Use TARGET_PAT for GitHub CLI operations
        $env:GH_TOKEN = $TargetPAT
        echo "PLACEHOLDER_VALUE" | gh variable set $n --repo "$TargetOrg/$TargetRepo"
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
        if ($exists -and -not $Force) { Write-Host "Skipping existing repo-dependabot secret $n"; continue }
        Write-Host "Copying repo-dependabot secret $n"
        
        # Use TARGET_PAT for GitHub CLI operations
        $env:GH_TOKEN = $TargetPAT
        echo "PLACEHOLDER_VALUE" | gh secret set $n --repo "$TargetOrg/$TargetRepo" --app dependabot
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
        if ($exists -and -not $Force) { Write-Host "Skipping existing repo-codespaces secret $n"; continue }
        Write-Host "Copying repo-codespaces secret $n"
        
        # Use TARGET_PAT for GitHub CLI operations
        $env:GH_TOKEN = $TargetPAT
        echo "PLACEHOLDER_VALUE" | gh secret set $n --repo "$TargetOrg/$TargetRepo" --app codespaces
    }
}

function Migrate-ActionsEnvSecrets {
    Write-Host "== Migrating ACTIONS ENVIRONMENT SECRETS =="
    $repoInfo = Invoke-GitHubApi GET "https://api.github.com/repos/$SourceOrg/$SourceRepo" $SourcePAT
    if (-not $repoInfo) { return }
    $repoId = $repoInfo.id
    $envs = Invoke-GitHubApi GET "https://api.github.com/repos/$SourceOrg/$SourceRepo/environments" $SourcePAT
    if (-not $envs) { 
        Write-Host "No environments found in source repository"
        return 
    }
    
    foreach ($env in $envs.environments) {
        $e = $env.name
        Write-Host " Environment: $e"
        
        # Check if environment exists in target repo, create if not
        $targetEnvCheck = Invoke-GitHubApi GET "https://api.github.com/repos/$TargetOrg/$TargetRepo/environments/$e" $TargetPAT
        if (-not $targetEnvCheck) {
            Write-Host "  Environment $e doesn't exist in target repo, creating it first"
            # Creating environment via API isn't straightforward, we'll need to create a secret to implicitly create the environment
            $tempSecretName = "TEMP_ENV_CREATION_SECRET_$(Get-Random)"
            
            # Use TARGET_PAT for GitHub CLI operations
            $env:GH_TOKEN = $TargetPAT
            echo "delete_me" | gh secret set $tempSecretName --repo "$TargetOrg/$TargetRepo" --env $e
            Write-Host "  Created environment $e in target repo"
            
            # Delete the temporary secret
            gh secret delete $tempSecretName --repo "$TargetOrg/$TargetRepo" --env $e
            Write-Host "  Removed temporary secret from environment"
        }
        
        $sUri = "https://api.github.com/repos/$SourceOrg/$SourceRepo/environments/$e/secrets"
        $tUri = "https://api.github.com/repos/$TargetOrg/$TargetRepo/environments/$e/secrets"
        $src = Invoke-GitHubApi GET $sUri $SourcePAT
        if (-not $src) { continue }
        foreach ($sec in $src.secrets) {
            $n = $sec.name
            $exists = Invoke-GitHubApi GET "$tUri/$n" $TargetPAT
            if ($exists -and -not $Force) { Write-Host "  Skipping existing env secret $n"; continue }
            Write-Host "  Copying env secret $n"
            
            # Use TARGET_PAT for GitHub CLI operations
            $env:GH_TOKEN = $TargetPAT
            echo "PLACEHOLDER_VALUE" | gh secret set $n --repo "$TargetOrg/$TargetRepo" --env $e
        }
    }
}

function Migrate-ActionsEnvVariables {
    Write-Host "== Migrating ACTIONS ENVIRONMENT VARIABLES =="
    $repoInfo = Invoke-GitHubApi GET "https://api.github.com/repos/$SourceOrg/$SourceRepo" $SourcePAT
    if (-not $repoInfo) { return }
    $repoId = $repoInfo.id
    $envs = Invoke-GitHubApi GET "https://api.github.com/repos/$SourceOrg/$SourceRepo/environments" $SourcePAT
    if (-not $envs) { 
        Write-Host "No environments found in source repository"
        return 
    }
    
    foreach ($env in $envs.environments) {
        $e = $env.name
        Write-Host " Environment: $e"
        
        # Check if environment exists in target repo, create if not
        $targetEnvCheck = Invoke-GitHubApi GET "https://api.github.com/repos/$TargetOrg/$TargetRepo/environments/$e" $TargetPAT
        if (-not $targetEnvCheck) {
            Write-Host "  Environment $e doesn't exist in target repo, creating it first"
            # Creating environment via API isn't straightforward, we'll need to create a secret to implicitly create the environment
            $tempSecretName = "TEMP_ENV_CREATION_SECRET_$(Get-Random)"
            
            # Use TARGET_PAT for GitHub CLI operations
            $env:GH_TOKEN = $TargetPAT
            echo "delete_me" | gh secret set $tempSecretName --repo "$TargetOrg/$TargetRepo" --env $e
            Write-Host "  Created environment $e in target repo"
            
            # Delete the temporary secret
            gh secret delete $tempSecretName --repo "$TargetOrg/$TargetRepo" --env $e
            Write-Host "  Removed temporary secret from environment"
        }
        
        $sUri = "https://api.github.com/repos/$SourceOrg/$SourceRepo/environments/$e/variables"
        $tUri = "https://api.github.com/repos/$TargetOrg/$TargetRepo/environments/$e/variables"
        $src = Invoke-GitHubApi GET $sUri $SourcePAT
        if (-not $src) { continue }
        foreach ($var in $src.variables) {
            $n = $var.name
            $exists = Invoke-GitHubApi GET "$tUri/$n" $TargetPAT
            if ($exists -and -not $Force) { Write-Host "  Skipping existing env var $n"; continue }
            Write-Host "  Copying env var $n"
            
            # Use TARGET_PAT for GitHub CLI operations
            $env:GH_TOKEN = $TargetPAT
            echo "PLACEHOLDER_VALUE" | gh variable set $n --repo "$TargetOrg/$TargetRepo" --env $e
        }
    }
}

function Migrate-ActionsOrgSecrets {
    Write-Host "== Migrating ACTIONS ORGANIZATION SECRETS =="
    $sUri = "https://api.github.com/orgs/$SourceOrg/actions/secrets"
    $tUri = "https://api.github.com/orgs/$TargetOrg/actions/secrets"
    $src = Invoke-GitHubApi GET $sUri $SourcePAT
    if (-not $src) { return }
    foreach ($sec in $src.secrets) {
        $n = $sec.name
        $exists = Invoke-GitHubApi GET "$tUri/$n" $TargetPAT
        if ($exists -and -not $Force) { Write-Host "Skipping existing org-action secret $n"; continue }
        Write-Host "Copying org-action secret $n"
        
        # Use TARGET_PAT for GitHub CLI operations
        $env:GH_TOKEN = $TargetPAT
        echo "PLACEHOLDER_VALUE" | gh secret set $n --org "$TargetOrg"
    }
}

function Migrate-ActionsOrgVariables {
    Write-Host "== Migrating ACTIONS ORGANIZATION VARIABLES =="
    $sUri = "https://api.github.com/orgs/$SourceOrg/actions/variables"
    $tUri = "https://api.github.com/orgs/$TargetOrg/actions/variables"
    $src = Invoke-GitHubApi GET $sUri $SourcePAT
    if (-not $src) { return }
    foreach ($var in $src.variables) {
        $n = $var.name
        $exists = Invoke-GitHubApi GET "$tUri/$n" $TargetPAT
        if ($exists -and -not $Force) { Write-Host "Skipping existing org-action variable $n"; continue }
        Write-Host "Copying org-action variable $n"
        
        # Use TARGET_PAT for GitHub CLI operations
        $env:GH_TOKEN = $TargetPAT
        echo "PLACEHOLDER_VALUE" | gh variable set $n --org "$TargetOrg"
    }
}

function Migrate-DependabotOrgSecrets {
    Write-Host "== Migrating DEPENDABOT ORGANIZATION SECRETS =="
    $sUri = "https://api.github.com/orgs/$SourceOrg/dependabot/secrets"
    $tUri = "https://api.github.com/orgs/$TargetOrg/dependabot/secrets"
    $src = Invoke-GitHubApi GET $sUri $SourcePAT
    if (-not $src) { return }
    foreach ($sec in $src.secrets) {
        $n = $sec.name
        $exists = Invoke-GitHubApi GET "$tUri/$n" $TargetPAT
        if ($exists -and -not $Force) { Write-Host "Skipping existing org-dependabot secret $n"; continue }
        Write-Host "Copying org-dependabot secret $n"
        
        # Use TARGET_PAT for GitHub CLI operations
        $env:GH_TOKEN = $TargetPAT
        echo "PLACEHOLDER_VALUE" | gh secret set $n --org "$TargetOrg" --app dependabot
    }
}

function Migrate-CodespacesOrgSecrets {
    Write-Host "== Migrating CODESPACES ORGANIZATION SECRETS =="
    $sUri = "https://api.github.com/orgs/$SourceOrg/codespaces/secrets"
    $tUri = "https://api.github.com/orgs/$TargetOrg/codespaces/secrets"
    $src = Invoke-GitHubApi GET $sUri $SourcePAT
    if (-not $src) { return }
    foreach ($sec in $src.secrets) {
        $n = $sec.name
        $exists = Invoke-GitHubApi GET "$tUri/$n" $TargetPAT
        if ($exists -and -not $Force) { Write-Host "Skipping existing org-codespaces secret $n"; continue }
        Write-Host "Copying org-codespaces secret $n"
        
        # Use TARGET_PAT for GitHub CLI operations
        $env:GH_TOKEN = $TargetPAT
        echo "PLACEHOLDER_VALUE" | gh secret set $n --org "$TargetOrg" --app codespaces
    }
}

function Migrate-ActionsEnvironments {
    Write-Host "== Creating Environments =="
    $envs = Invoke-GitHubApi GET "https://api.github.com/repos/$SourceOrg/$SourceRepo/environments" $SourcePAT
    if (-not $envs) { 
        Write-Host "No environments found in source repository"
        return 
    }
    
    foreach ($env in $envs.environments) {
        $e = $env.name
        Write-Host " Creating Environment: $e"
        
        # Check if environment exists in target repo, create if not
        $targetEnvCheck = Invoke-GitHubApi GET "https://api.github.com/repos/$TargetOrg/$TargetRepo/environments/$e" $TargetPAT
        if (-not $targetEnvCheck) {
            Write-Host "  Environment $e doesn't exist in target repo, creating it"
            # Creating environment via API isn't straightforward, we'll need to create a secret to implicitly create the environment
            $tempSecretName = "TEMP_ENV_CREATION_SECRET_$(Get-Random)"
            
            # Use TARGET_PAT for GitHub CLI operations
            $env:GH_TOKEN = $TargetPAT
            echo "delete_me" | gh secret set $tempSecretName --repo "$TargetOrg/$TargetRepo" --env $e
            Write-Host "  Created environment $e in target repo"
            
            # Delete the temporary secret
            gh secret delete $tempSecretName --repo "$TargetOrg/$TargetRepo" --env $e
            Write-Host "  Removed temporary secret from environment"
        } else {
            Write-Host "  Environment $e already exists in target repo"
        }
    }
}

# Make sure GitHub CLI is authenticated initially with SOURCE_PAT
Write-Host "Authenticating GitHub CLI with SOURCE_PAT..."
$env:GH_TOKEN = $SourcePAT
gh auth status

foreach ($t in $Scope.Split(',')) {
    $trimmedType = $t.Trim().ToLower()
    Write-Host "Processing scope: $trimmedType"
    
    switch ($trimmedType) {
        'actionsreposecrets'    { Migrate-ActionsRepoSecrets }
        'actionsrepovariables'  { Migrate-ActionsRepoVariables }
        'dependabotreposecrets' { Migrate-DependabotRepoSecrets }
        'codespacesreposecrets' { Migrate-CodespacesRepoSecrets }
        'actionsenvsecrets'     { Migrate-ActionsEnvSecrets }
        'actionsenvvariables'   { Migrate-ActionsEnvVariables }
        'actionsorgsecrets'     { Migrate-ActionsOrgSecrets }
        'actionsorgvariables'   { Migrate-ActionsOrgVariables }
        'dependabotorgsecrets'  { Migrate-DependabotOrgSecrets }
        'codespacesorgsecrets'  { Migrate-CodespacesOrgSecrets }
        'actionsenvironments'   { Migrate-ActionsEnvironments }
        default                 { Write-Warning "Unknown type: $t" }
    }
}

# Reset to SOURCE_PAT at end
$env:GH_TOKEN = $SourcePAT
