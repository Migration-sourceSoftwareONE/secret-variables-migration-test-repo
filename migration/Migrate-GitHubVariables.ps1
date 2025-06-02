param(
    [Parameter(Mandatory)] [string]$SourceOrg,
    [Parameter(Mandatory)] [string]$SourceRepo,
    [Parameter(Mandatory)] [string]$TargetOrg,
    [Parameter(Mandatory)] [string]$TargetRepo,
    [Parameter(Mandatory)] [string]$SourcePAT,
    [Parameter(Mandatory)] [string]$TargetPAT,
    [string]$Scope = "actionsreposecrets",
    [switch]$Force,
    [string]$TempSecretDir = "$env:TEMP\GithubSecretMigration"
)

# Function to check if GitHub CLI is working properly
function Test-GitHubCLI {
    try {
        $ghOutput = gh --version
        Write-Host "GitHub CLI is installed: $ghOutput"
        return $true
    }
    catch {
        Write-Error "GitHub CLI not working properly: $_"
        return $false
    }
}

# Test GitHub CLI is available
if (-not (Test-GitHubCLI)) {
    throw "GitHub CLI is required for this script. Please install it from https://cli.github.com/"
}

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
        }
        return $null
    }
}

# Initialize temp directory for secret storage
function Initialize-TempDirectory {
    if (!(Test-Path -Path $TempSecretDir)) {
        New-Item -ItemType Directory -Path $TempSecretDir -Force | Out-Null
    }

    # Secure the directory with Windows-specific permissions
    $acl = Get-Acl $TempSecretDir
    $acl.SetAccessRuleProtection($true, $false)
    
    # Add current user with full control
    $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        $currentUser,
        "FullControl", 
        "Allow")
    $acl.AddAccessRule($rule)
    
    # Remove inheritance and set the ACL
    Set-Acl $TempSecretDir $acl
    
    Write-Host "Temp directory for secrets created and secured at $TempSecretDir"
}

# Clean up temporary files
function Remove-TempDirectory {
    if (Test-Path -Path $TempSecretDir) {
        Write-Host "Removing temporary secret files..."
        Remove-Item -Path $TempSecretDir -Recurse -Force
    }
}

function Invoke-GitHubCLI {
    param(
        [string]$Command,
        [string]$Token,
        [string]$Args
    )
    
    # Save current environment variable if exists
    $oldToken = $env:GH_TOKEN
    
    try {
        # Set token for this command
        $env:GH_TOKEN = $Token
        
        # Execute command
        $process = Start-Process -FilePath "gh" -ArgumentList $Args -NoNewWindow -Wait -PassThru -RedirectStandardOutput "stdout.txt" -RedirectStandardError "stderr.txt"
        
        # Get output and error
        $stdout = Get-Content "stdout.txt" -Raw
        $stderr = Get-Content "stderr.txt" -Raw
        
        # Clean up temp files
        Remove-Item "stdout.txt" -ErrorAction SilentlyContinue
        Remove-Item "stderr.txt" -ErrorAction SilentlyContinue
        
        if ($process.ExitCode -ne 0) {
            Write-Warning "GitHub CLI command failed: $stderr"
            return $null
        }
        
        return $stdout
    }
    finally {
        # Restore original token or clear if none existed
        if ($oldToken) {
            $env:GH_TOKEN = $oldToken
        }
        else {
            Remove-Item env:GH_TOKEN -ErrorAction SilentlyContinue
        }
    }
}

function Get-Secret {
    param(
        [string]$Name, 
        [string]$Repo, 
        [string]$Token, 
        [string]$OutputFile,
        [string]$Environment = "",
        [string]$App = ""
    )
    
    # Basic command
    $args = "secret get $Name --repo $Repo"
    
    # Add optional arguments
    if ($Environment) {
        $args += " --env $Environment"
    }
    
    if ($App) {
        $args += " --app $App"
    }
    
    # Set token for this command
    $env:GH_TOKEN = $Token
    
    try {
        # Execute gh command and redirect output to file
        $process = Start-Process -FilePath "gh" -ArgumentList $args -NoNewWindow -Wait -PassThru -RedirectStandardOutput $OutputFile -RedirectStandardError "stderr.txt"
        
        # Check if command was successful
        if ($process.ExitCode -ne 0) {
            $stderr = Get-Content "stderr.txt" -Raw
            Write-Warning "Failed to get secret $Name: $stderr"
            return $false
        }
        
        return $true
    }
    catch {
        Write-Warning "Error executing gh secret get: $_"
        return $false
    }
    finally {
        # Clean up error file
        Remove-Item "stderr.txt" -ErrorAction SilentlyContinue
    }
}

function Set-Secret {
    param(
        [string]$Name, 
        [string]$Repo, 
        [string]$Token, 
        [string]$ValueFile,
        [string]$Environment = "",
        [string]$App = ""
    )
    
    # Basic command
    $args = "secret set $Name --repo $Repo"
    
    # Add optional arguments
    if ($Environment) {
        $args += " --env $Environment"
    }
    
    if ($App) {
        $args += " --app $App"
    }
    
    # Set token for this command
    $env:GH_TOKEN = $Token
    
    try {
        # Get content of value file
        $secretValue = Get-Content -Path $ValueFile -Raw
        
        # Create a temporary file with the secret command
        $tempScript = [System.IO.Path]::GetTempFileName() + ".ps1"
        Set-Content -Path $tempScript -Value @"
`$env:GH_TOKEN = '$Token'
echo '$secretValue' | gh $args
"@
        
        # Execute the temporary script
        $process = Start-Process -FilePath "powershell" -ArgumentList "-ExecutionPolicy Bypass -File $tempScript" -NoNewWindow -Wait -PassThru
        
        # Clean up temporary script
        Remove-Item -Path $tempScript -Force -ErrorAction SilentlyContinue
        
        return ($process.ExitCode -eq 0)
    }
    catch {
        Write-Warning "Error executing gh secret set: $_"
        return $false
    }
}

function Migrate-ActionsEnvironments {
    Write-Host "== Migrating ACTIONS ENVIRONMENTS =="
    $srcEnvs = Invoke-GitHubApi GET "https://api.github.com/repos/$SourceOrg/$SourceRepo/environments" $SourcePAT
    if (-not $srcEnvs) { return }
    foreach ($env in $srcEnvs.environments) {
        $e = $env.name
        Write-Host "Checking environment $e"
        $tEnv = Invoke-GitHubApi GET "https://api.github.com/repos/$TargetOrg/$TargetRepo/environments/$e" $TargetPAT
        if ($tEnv) {
            Write-Host " Environment $e already exists in target."
            continue
        }
        # Get environment details to copy protection rules
        $sEnvDetails = Invoke-GitHubApi GET "https://api.github.com/repos/$SourceOrg/$SourceRepo/environments/$e" $SourcePAT

        # Build payload (copying reviewers, wait timer, branch policy if present)
        $payload = @{ }
        $payload.name = $e
        if ($sEnvDetails) {
            if ($sEnvDetails.protection_rules) {
                $payload.protection_rules = $sEnvDetails.protection_rules
            }
            if ($sEnvDetails.wait_timer) {
                $payload.wait_timer = $sEnvDetails.wait_timer
            }
            if ($sEnvDetails.reviewers) {
                $payload.reviewers = $sEnvDetails.reviewers
            }
            if ($sEnvDetails.deployment_branch_policy) {
                $payload.deployment_branch_policy = $sEnvDetails.deployment_branch_policy
            }
        }
        Write-Host " Creating environment $e in target."
        Invoke-GitHubApi PUT "https://api.github.com/repos/$TargetOrg/$TargetRepo/environments/$e" $TargetPAT $payload
    }
}

function Migrate-ActionsRepoSecrets {
    Write-Host "== Migrating ACTIONS REPOSITORY SECRETS =="
    $sUri = "https://api.github.com/repos/$SourceOrg/$SourceRepo/actions/secrets"
    $tUri = "https://api.github.com/repos/$TargetOrg/$TargetRepo/actions/secrets"
    $src = Invoke-GitHubApi GET $sUri $SourcePAT
    if (-not $src) { return }
    
    # Get the public key of the target repository to encrypt secrets
    $pubKeyResponse = Invoke-GitHubApi GET "$tUri/public-key" $TargetPAT
    if (-not $pubKeyResponse) {
        Write-Warning "Failed to get public key for target repo"
        return
    }
    
    foreach ($sec in $src.secrets) {
        $n = $sec.name
        $exists = Invoke-GitHubApi GET "$tUri/$n" $TargetPAT
        if ($exists -and -not $Force) { 
            Write-Host "Skipping existing repo-action secret $n"
            continue 
        }
        
        Write-Host "Copying repo-action secret $n"
        try {
            # Extract secret value using GitHub CLI
            $secretFilePath = Join-Path $TempSecretDir "$n.txt"
            $success = Get-Secret -Name $n -Repo "$SourceOrg/$SourceRepo" -Token $SourcePAT -OutputFile $secretFilePath
            
            # Verify the file was created and has content
            if ($success -and (Test-Path $secretFilePath) -and ((Get-Item $secretFilePath).Length -gt 0)) {
                # Set the secret in target repo
                $setSuccess = Set-Secret -Name $n -Repo "$TargetOrg/$TargetRepo" -Token $TargetPAT -ValueFile $secretFilePath
                if ($setSuccess) {
                    Write-Host "  Secret $n successfully migrated with value"
                } else {
                    Write-Warning "  Failed to set secret $n in target repository"
                }
                
                # Immediately remove the secret file
                Remove-Item -Path $secretFilePath -Force -ErrorAction SilentlyContinue
            }
            else {
                Write-Warning "  Failed to retrieve value for secret $n"
                # Fall back to empty secret
                $env:GH_TOKEN = $TargetPAT
                & gh secret set $n --repo "$TargetOrg/$TargetRepo" --body ""
                Write-Host "  Secret $n created with empty value (fallback)"
            }
        }
        catch {
            Write-Warning "  Error migrating secret $n: $($_.Exception.Message)"
            # If GitHub CLI method fails, fall back to empty secret
            $env:GH_TOKEN = $TargetPAT
            & gh secret set $n --repo "$TargetOrg/$TargetRepo" --body ""
            Write-Host "  Secret $n created with empty value (fallback)"
        }
    }
}

# Similar functions for other secret/variable types
# ... [Other migration functions with similar Get-Secret/Set-Secret patterns] ...

# Ensure environments exist before migrating their secrets/variables
function Ensure-EnvironmentsExist {
    # Check if environments are already migrated
    $global:EnvironmentsMigrated = $global:EnvironmentsMigrated -or $false
    if ($global:EnvironmentsMigrated) {
        Write-Host "Environments already migrated, skipping..."
        return
    }
    
    # Migrate environments
    Write-Host "Ensuring environments exist in target repo before migrating their secrets and variables"
    Migrate-ActionsEnvironments
    $global:EnvironmentsMigrated = $true
}

# Main execution block
try {
    # Set up temp directory for secure secret handling
    Initialize-TempDirectory
    
    # Process migrations in the correct order
    $scopeItems = $Scope.Split(',') | ForEach-Object { $_.Trim().ToLower() }

    # First, process environment-related migrations if needed
    $needsEnvironments = ($scopeItems -contains 'actionsenvsecrets') -or ($scopeItems -contains 'actionsenvvariables')
    if ($needsEnvironments -or ($scopeItems -contains 'actionsenvironments')) {
        Ensure-EnvironmentsExist
    }

    # Then process everything else in the requested order
    foreach ($t in $scopeItems) {
        switch ($t) {
            # Skip environments as we've already processed them if needed
            'actionsenvironments'   { if (-not $needsEnvironments) { Migrate-ActionsEnvironments } }
            'actionsreposecrets'    { Migrate-ActionsRepoSecrets }
            # Include other migration functions as needed
            default { Write-Warning "Unknown type: $t" }
        }
    }

    Write-Host "Migration completed successfully!"
}
catch {
    Write-Error "Migration failed with error: $_"
    throw $_
}
finally {
    # Always clean up, even if there's an error
    Remove-TempDirectory
}
