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

# Create a temporary directory for storing variable values if not provided
if (-not $TempSecretDir) {
    $TempSecretDir = Join-Path $env:TEMP "GHSecretsMigration_$([DateTime]::Now.ToString('yyyyMMddHHmmss'))"
}
New-Item -ItemType Directory -Path $TempSecretDir -Force | Out-Null
Write-Host "Using temporary directory for value storage: $TempSecretDir"

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
            if ($_.ErrorDetails) {
                Write-Warning "Response: $($_.ErrorDetails.Message)"
            }
        }
        return $null
    }
}

function Get-Secret-Value {
    param($SecretName, $SourceType, $EnvName = "")
    
    # Set SOURCE_PAT for GitHub CLI operations
    $env:GH_TOKEN = $SourcePAT
    
    try {
        $secretValue = ""
        switch ($SourceType) {
            "repo" {
                $secretValue = gh secret get $SecretName --repo "$SourceOrg/$SourceRepo"
            }
            "repo-dependabot" {
                $secretValue = gh secret get $SecretName --repo "$SourceOrg/$SourceRepo" --app dependabot
            }
            "repo-codespaces" {
                $secretValue = gh secret get $SecretName --repo "$SourceOrg/$SourceRepo" --app codespaces
            }
            "env" {
                $secretValue = gh secret get $SecretName --repo "$SourceOrg/$SourceRepo" --env $EnvName
            }
            "org" {
                $secretValue = gh secret get $SecretName --org "$SourceOrg"
            }
            "org-dependabot" {
                $secretValue = gh secret get $SecretName --org "$SourceOrg" --app dependabot
            }
            "org-codespaces" {
                $secretValue = gh secret get $SecretName --org "$SourceOrg" --app codespaces
            }
        }
        
        if ($secretValue) {
            Write-Host "  Retrieved value for secret $SecretName"
            return $secretValue
        } else {
            Write-Warning "  Could not retrieve value for secret $SecretName"
            return "PLACEHOLDER_VALUE"
        }
    } catch {
        Write-Warning "  Error retrieving secret value for $SecretName: $_"
        return "PLACEHOLDER_VALUE"
    }
}

function Get-Variable-Value {
    param($VariableName, $SourceType, $EnvName = "")
    
    # Set SOURCE_PAT for GitHub CLI operations
    $env:GH_TOKEN = $SourcePAT
    
    try {
        $variableValue = ""
        switch ($SourceType) {
            "repo" {
                $variableValue = gh variable get $VariableName --repo "$SourceOrg/$SourceRepo" 
            }
            "env" {
                $variableValue = gh variable get $VariableName --repo "$SourceOrg/$SourceRepo" --env $EnvName
            }
            "org" {
                $variableValue = gh variable get $VariableName --org "$SourceOrg"
            }
        }
        
        if ($variableValue) {
            Write-Host "  Retrieved value for variable $VariableName"
            return $variableValue
        } else {
            Write-Warning "  Could not retrieve value for variable $VariableName"
            return "PLACEHOLDER_VALUE"
        }
    } catch {
        Write-Warning "  Error retrieving variable value for $VariableName: $_"
        return "PLACEHOLDER_VALUE"
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
        
        # Get secret value from source
        $value = Get-Secret-Value -SecretName $n -SourceType "repo"
        
        # Use TARGET_PAT for GitHub CLI operations
        $env:GH_TOKEN = $TargetPAT
        echo $value | gh secret set $n --repo "$TargetOrg/$TargetRepo"
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
        
        # Get variable value from source
        $value = Get-Variable-Value -VariableName $n -SourceType "repo"
        
        # Use TARGET_PAT for GitHub CLI operations
        $env:GH_TOKEN = $TargetPAT
        echo $value | gh variable set $n --repo "$TargetOrg/$TargetRepo"
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
        
        # Get secret value from source
        $value = Get-Secret-Value -SecretName $n -SourceType "repo-dependabot"
        
        # Use TARGET_PAT for GitHub CLI operations
        $env:GH_TOKEN = $TargetPAT
        echo $value | gh secret set $n --repo "$TargetOrg/$TargetRepo" --app dependabot
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
        
        # Get secret value from source
        $value = Get-Secret-Value -SecretName $n -SourceType "repo-codespaces"
        
        # Use TARGET_PAT for GitHub CLI operations
        $env:GH_TOKEN = $TargetPAT
        echo $value | gh secret set $n --repo "$TargetOrg/$TargetRepo" --app codespaces
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
            
            # Get secret value from source
            $value = Get-Secret-Value -SecretName $n -SourceType "env" -EnvName $e
            
            # Use TARGET_PAT for GitHub CLI operations
            $env:GH_TOKEN = $TargetPAT
            echo $value | gh secret set $n --repo "$TargetOrg/$TargetRepo" --env $e
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
            
            # Get variable value from source
            $value = Get-Variable-Value -VariableName $n -SourceType "env" -EnvName $e
            
            # Use TARGET_PAT for GitHub CLI operations
            $env:GH_TOKEN = $TargetPAT
            echo $value | gh variable set $n --repo "$TargetOrg/$TargetRepo" --env $e
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
        
        # Get secret value from source
        $value = Get-Secret-Value -SecretName $n -SourceType "org"
        
        # Use TARGET_PAT for GitHub CLI operations
        $env:GH_TOKEN = $TargetPAT
        
        # Check if the secret has repository access restrictions
        if ($sec.selected_repositories_url) {
            Write-Host "  Secret $n has repository access restrictions, setting with 'private' visibility"
            echo $value | gh secret set $n --org "$TargetOrg" --visibility "private"
        } else {
            Write-Host "  Secret $n is accessible to all repositories"
            echo $value | gh secret set $n --org "$TargetOrg" --visibility "all"
        }
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
        
        # Get variable value from source
        $value = Get-Variable-Value -VariableName $n -SourceType "org"
        
        # Use TARGET_PAT for GitHub CLI operations
        $env:GH_TOKEN = $TargetPAT
        
        # Check if the variable has repository access restrictions
        if ($var.selected_repositories_url) {
            Write-Host "  Variable $n has repository access restrictions, setting with 'private' visibility"
            echo $value | gh variable set $n --org "$TargetOrg" --visibility "private"
        } else {
            Write-Host "  Variable $n is accessible to all repositories"
            echo $value | gh variable set $n --org "$TargetOrg" --visibility "all"
        }
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
        
        # Get secret value from source
        $value = Get-Secret-Value -SecretName $n -SourceType "org-dependabot"
        
        # Use TARGET_PAT for GitHub CLI operations
        $env:GH_TOKEN = $TargetPAT
        
        # Check if the secret has repository access restrictions
        if ($sec.selected_repositories_url) {
            Write-Host "  Secret $n has repository access restrictions, setting with 'private' visibility"
            echo $value | gh secret set $n --org "$TargetOrg" --app dependabot --visibility "private"
        } else {
            Write-Host "  Secret $n is accessible to all repositories"
            echo $value | gh secret set $n --org "$TargetOrg" --app dependabot --visibility "all"
        }
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
        
        # Get secret value from source
        $value = Get-Secret-Value -SecretName $n -SourceType "org-codespaces"
        
        # Use TARGET_PAT for GitHub CLI operations
        $env:GH_TOKEN = $TargetPAT
        
        # Check if the secret has repository access restrictions
        if ($sec.selected_repositories_url) {
            Write-Host "  Secret $n has repository access restrictions, setting with 'private' visibility"
            echo $value | gh secret set $n --org "$TargetOrg" --app codespaces --visibility "private"
        } else {
            Write-Host "  Secret $n is accessible to all repositories"
            echo $value | gh secret set $n --org "$TargetOrg" --app codespaces --visibility "all"
        }
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

# Test access to secrets using gh CLI
Write-Host "Testing access to secrets via GitHub CLI..."
try {
    $testResult = gh secret list --repo "$SourceOrg/$SourceRepo"
    Write-Host "Successfully accessed secrets via GitHub CLI"
} catch {
    Write-Warning "Warning: Cannot access secrets via GitHub CLI: $_"
    Write-Host "This script requires gh CLI with the ability to read secrets."
    Write-Host "Make sure your PAT has the necessary permissions and you're using a self-hosted runner."
}

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

# Clean up temporary directory if it was created
if (Test-Path $TempSecretDir) {
    Write-Host "Cleaning up temporary directory..."
    Remove-Item -Path $TempSecretDir -Recurse -Force
}

# Reset to SOURCE_PAT at end
$env:GH_TOKEN = $SourcePAT
Write-Host "Migration complete!"
