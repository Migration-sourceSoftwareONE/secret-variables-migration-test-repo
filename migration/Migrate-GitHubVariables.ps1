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

# Create a temporary directory for storing secret and variable values if not provided
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
    
    $secretFile = Join-Path $TempSecretDir "$SourceType-$EnvName-$SecretName.secret"
    
    try {
        # Create a very small workflow that outputs the secret to a file (using cat)
        $workflowId = [Guid]::NewGuid().ToString()
        $workflowName = "temp-secret-export-$workflowId"
        $workflowPath = ".github/workflows/$workflowName.yml"
        $secretEnvVar = ""
        $secretCommand = ""
        
        # Different workflow content based on secret type
        switch ($SourceType) {
            "repo" {
                $secretEnvVar = "env:\$SecretName = \${{ secrets.$SecretName }}"
                $secretCommand = "echo \${{ secrets.$SecretName }} > `"$secretFile`""
            }
            "repo-dependabot" {
                $secretEnvVar = "env:\$SecretName = \${{ secrets.$SecretName }}"
                $secretCommand = "echo \${{ secrets.$SecretName }} > `"$secretFile`""
            } 
            "repo-codespaces" {
                $secretEnvVar = "env:\$SecretName = \${{ secrets.$SecretName }}"
                $secretCommand = "echo \${{ secrets.$SecretName }} > `"$secretFile`""
            }
            "env" {
                $secretEnvVar = "env:\$SecretName = \${{ secrets.$SecretName }}"
                $secretCommand = "echo \${{ secrets.$SecretName }} > `"$secretFile`""
            }
            "org" {
                $secretEnvVar = "env:\$SecretName = \${{ secrets.$SecretName }}"
                $secretCommand = "echo \${{ secrets.$SecretName }} > `"$secretFile`""
            }
            "org-dependabot" {
                $secretEnvVar = "env:\$SecretName = \${{ secrets.$SecretName }}"
                $secretCommand = "echo \${{ secrets.$SecretName }} > `"$secretFile`""
            }
            "org-codespaces" {
                $secretEnvVar = "env:\$SecretName = \${{ secrets.$SecretName }}"
                $secretCommand = "echo \${{ secrets.$SecretName }} > `"$secretFile`""
            }
        }
        
        # Create temporary workflow file to output the secret value
        $workflowContent = @"
name: Temporary Secret Export

on:
  workflow_dispatch:

jobs:
  export-secret:
    runs-on: [self-hosted, Windows, X64]
    steps:
      - name: Export Secret to File
        shell: powershell
        run: |
          # Set secret to environment variable
          $secretEnvVar
          # Export to file
          $secretCommand
"@

        # Write the workflow to a local file
        $tempDir = New-Item -ItemType Directory -Path (Join-Path $TempSecretDir ".github\workflows") -Force
        $tempWorkflow = Join-Path $tempDir $workflowName
        Set-Content -Path "$tempWorkflow.yml" -Value $workflowContent
        
        # Commit and push the workflow to the repo
        $env:GH_TOKEN = $SourcePAT
        
        # Use a direct REST API call instead of git commands
        $workflowContent64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($workflowContent))
        $commitBody = @{
            message = "temp: Add workflow to export secret $SecretName"
            content = $workflowContent64
            branch = "main"  # Adjust this if your default branch is different
        }
        
        $apiUrl = "https://api.github.com/repos/$SourceOrg/$SourceRepo/contents/$workflowPath"
        $response = Invoke-GitHubApi PUT $apiUrl $SourcePAT $commitBody
        
        if (-not $response) {
            Write-Warning "Failed to create temporary workflow for secret extraction"
            return "PLACEHOLDER_VALUE"
        }
        
        # Trigger the workflow
        $runUrl = "https://api.github.com/repos/$SourceOrg/$SourceRepo/actions/workflows/$workflowName.yml/dispatches"
        $runBody = @{
            ref = "main"  # Adjust this if your default branch is different
        }
        
        $runResponse = Invoke-GitHubApi POST $runUrl $SourcePAT $runBody
        
        # Wait for the workflow to complete (up to 60 seconds)
        Write-Host "  Waiting for secret extraction workflow to complete..."
        $maxWait = 60
        $waited = 0
        $completed = $false
        $secretValue = "PLACEHOLDER_VALUE"
        
        while ($waited -lt $maxWait -and -not $completed) {
            Start-Sleep -Seconds 2
            $waited += 2
            
            # Check if the secret file exists
            if (Test-Path $secretFile) {
                $secretValue = Get-Content $secretFile -Raw
                $completed = $true
                Write-Host "  Secret value obtained successfully"
            }
        }
        
        if (-not $completed) {
            Write-Warning "  Timed out waiting for secret extraction"
        }
        
        # Clean up the workflow file from the repo
        $deleteUrl = "https://api.github.com/repos/$SourceOrg/$SourceRepo/contents/$workflowPath"
        $shaResponse = Invoke-GitHubApi GET $deleteUrl $SourcePAT
        
        if ($shaResponse -and $shaResponse.sha) {
            $deleteBody = @{
                message = "temp: Remove workflow to export secret $SecretName"
                sha = $shaResponse.sha
                branch = "main"  # Adjust this if your default branch is different
            }
            
            Invoke-GitHubApi DELETE $deleteUrl $SourcePAT $deleteBody | Out-Null
        }
        
        # Clean up the temporary file
        if (Test-Path $secretFile) {
            Remove-Item $secretFile -Force
        }
        
        return $secretValue
    } catch {
        Write-Warning "  Error retrieving secret value for ${SecretName}: $($_.Exception.Message)"
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
        Write-Warning "  Error retrieving variable value for ${VariableName}: $($_.Exception.Message)"
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
            
            # Try to delete the temporary secret
            try {
                gh secret delete $tempSecretName --repo "$TargetOrg/$TargetRepo" --env $e
                Write-Host "  Removed temporary secret from environment"
            } catch {
                Write-Warning "  Failed to remove temporary secret, but environment should be created: $($_.Exception.Message)"
            }
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
            
            # Try to delete the temporary secret
            try {
                gh secret delete $tempSecretName --repo "$TargetOrg/$TargetRepo" --env $e
                Write-Host "  Removed temporary secret from environment"
            } catch {
                Write-Warning "  Failed to remove temporary secret, but environment should be created: $($_.Exception.Message)"
            }
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
            
            # Try to delete the temporary secret
            try {
                gh secret delete $tempSecretName --repo "$TargetOrg/$TargetRepo" --env $e
                Write-Host "  Removed temporary secret from environment"
            } catch {
                Write-Warning "  Failed to remove temporary secret, but environment should be created: $($_.Exception.Message)"
            }
        } else {
            Write-Host "  Environment $e already exists in target repo"
        }
    }
}

# Make sure GitHub CLI is authenticated initially with SOURCE_PAT
Write-Host "Authenticating GitHub CLI with SOURCE_PAT..."
$env:GH_TOKEN = $SourcePAT
gh auth status

# Test ability to create and run workflows
Write-Host "Testing ability to create and run workflows..."
try {
    $env:GH_TOKEN = $SourcePAT
    
    # List repositories to ensure the token has repo access
    $repoCheck = gh repo list $SourceOrg --limit 1 --json name
    if ($repoCheck) {
        Write-Host "✅ Successfully verified repository access via GitHub CLI"
    } else {
        Write-Warning "❌ Could not verify repository access - check PAT permissions"
    }
    
    Write-Host "This script will use a temporary GitHub workflow to extract secret values"
    Write-Host "The PAT needs 'repo' and 'workflow' permissions for this to work"
} catch {
    Write-Warning "❌ Issues with GitHub CLI or permissions: $($_.Exception.Message)"
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
        default                 { Write-Warning "Unknown type: $trimmedType" }
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
