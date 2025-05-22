param(
    [Parameter(Mandatory)] [string]$SourceOrg,
    [Parameter(Mandatory)] [string]$SourceRepo,
    [Parameter(Mandatory)] [string]$TargetOrg,
    [Parameter(Mandatory)] [string]$TargetRepo,
    [Parameter(Mandatory)] [string]$SourcePAT,
    [Parameter(Mandatory)] [string]$TargetPAT,
    [string]$Scope = "actionreposecrets,dependabotreposecrets,codespacesreposecrets",
    [switch]$Force
)

function Invoke-GitHubApi {
    param(
        [string]$Method,
        [string]$Uri,
        [string]$Token,
        [hashtable]$Body = $null
    )
    $Headers = @{ Authorization = "Bearer $Token" }
    if ($Body) {
        $BodyJson = $Body | ConvertTo-Json -Depth 10
    } else {
        $BodyJson = $null
    }
    try {
        Invoke-RestMethod -Method $Method -Uri $Uri -Headers $Headers -ContentType "application/json" -Body $BodyJson
    } catch {
        Write-Warning "API call failed: $($_.Exception.Message) [$Method $Uri]"
        return $null
    }
}

function Migrate-ActionsRepoSecrets {
    param(
        [string]$SourceOrg, [string]$SourceRepo,
        [string]$TargetOrg, [string]$TargetRepo,
        [string]$SourcePAT, [string]$TargetPAT,
        [switch]$Force
    )

    Write-Host "== Migrating ACTIONS REPOSITORY SECRETS =="

    $sourceUri = "https://api.github.com/repos/$SourceOrg/$SourceRepo/actions/secrets"
    $targetUri = "https://api.github.com/repos/$TargetOrg/$TargetRepo/actions/secrets"

    $sourceSecrets = Invoke-GitHubApi -Method GET -Uri $sourceUri -Token $SourcePAT
    if (-not $sourceSecrets) {
        Write-Warning "Failed to fetch secrets from source repo."
        return
    }

    foreach ($secret in $sourceSecrets.secrets) {
        $name = $secret.name

        # Check if secret exists in target
        $exists = $false
        $check = Invoke-GitHubApi -Method GET -Uri "$targetUri/$name" -Token $TargetPAT
        if ($check) { $exists = $true }

        if ($exists -and -not $Force) {
            Write-Host "Secret '$name' already exists on target. Skipping."
            continue
        }

        Write-Host "Copying secret '$name' with empty placeholder value..."

        $repoFullName = "$TargetOrg/$TargetRepo"

        # Note: value cannot be retrieved, so empty placeholder is used
        $cmd = "gh secret set $name --repo $repoFullName --body ''"
        Invoke-Expression $cmd
    }
}

function Migrate-DependabotRepoSecrets {
    param(
        [string]$SourceOrg, [string]$SourceRepo,
        [string]$TargetOrg, [string]$TargetRepo,
        [string]$SourcePAT, [string]$TargetPAT,
        [switch]$Force
    )

    Write-Host "== Migrating DEPENDABOT REPOSITORY SECRETS =="

    $sourceUri = "https://api.github.com/repos/$SourceOrg/$SourceRepo/dependabot/secrets"
    $targetUri = "https://api.github.com/repos/$TargetOrg/$TargetRepo/dependabot/secrets"

    $sourceSecrets = Invoke-GitHubApi -Method GET -Uri $sourceUri -Token $SourcePAT
    if (-not $sourceSecrets) {
        Write-Warning "Failed to fetch dependabot secrets from source repo or none exist."
        return
    }

    foreach ($secret in $sourceSecrets.secrets) {
        $name = $secret.name

        # Check if secret exists in target
        $exists = $false
        $check = Invoke-GitHubApi -Method GET -Uri "$targetUri/$name" -Token $TargetPAT
        if ($check) { $exists = $true }

        if ($exists -and -not $Force) {
            Write-Host "Dependabot secret '$name' already exists on target. Skipping."
            continue
        }

        Write-Host "Copying dependabot secret '$name' with empty placeholder value..."

        $repoFullName = "$TargetOrg/$TargetRepo"

        $cmd = "gh secret set $name --repo $repoFullName --app dependabot --body ''"
        Invoke-Expression $cmd
    }
}

function Migrate-CodespacesRepoSecrets {
    param(
        [string]$SourceOrg, [string]$SourceRepo,
        [string]$TargetOrg, [string]$TargetRepo,
        [string]$SourcePAT, [string]$TargetPAT,
        [switch]$Force
    )

    Write-Host "== Migrating CODESPACES REPOSITORY SECRETS =="

    $sourceUri = "https://api.github.com/repos/$SourceOrg/$SourceRepo/codespaces/secrets"
    $targetUri = "https://api.github.com/repos/$TargetOrg/$TargetRepo/codespaces/secrets"

    $sourceSecrets = Invoke-GitHubApi -Method GET -Uri $sourceUri -Token $SourcePAT
    if (-not $sourceSecrets) {
        Write-Warning "Failed to fetch codespaces secrets from source repo or none exist."
        return
    }

    foreach ($secret in $sourceSecrets.secrets) {
        $name = $secret.name

        # Check if secret exists in target
        $exists = $false
        $check = Invoke-GitHubApi -Method GET -Uri "$targetUri/$name" -Token $TargetPAT
        if ($check) { $exists = $true }

        if ($exists -and -not $Force) {
            Write-Host "Codespaces secret '$name' already exists on target. Skipping."
            continue
        }

        Write-Host "Copying codespaces secret '$name' with empty placeholder value..."

        $repoFullName = "$TargetOrg/$TargetRepo"

        $cmd = "gh secret set $name --repo $repoFullName --app codespaces --body ''"
        Invoke-Expression $cmd
    }
}

# Repository Variables migration is skipped due to lack of public API
function Migrate-RepoVariables {
    Write-Warning "Repository variables migration is not supported by the GitHub API and will be skipped."
}

# Main logic depending on Scope input (comma-separated list)
foreach ($type in $Scope.Split(',')) {
    switch ($type.Trim().ToLower()) {
        'actionreposecrets' {
            Migrate-ActionsRepoSecrets -SourceOrg $SourceOrg -SourceRepo $SourceRepo -TargetOrg $TargetOrg -TargetRepo $TargetRepo -SourcePAT $SourcePAT -TargetPAT $TargetPAT -Force:$Force
        }
        'dependabotreposecrets' {
            Migrate-DependabotRepoSecrets -SourceOrg $SourceOrg -SourceRepo $SourceRepo -TargetOrg $TargetOrg -TargetRepo $TargetRepo -SourcePAT $SourcePAT -TargetPAT $TargetPAT -Force:$Force
        }
        'codespacesreposecrets' {
            Migrate-CodespacesRepoSecrets -SourceOrg $SourceOrg -SourceRepo $SourceRepo -TargetOrg $TargetOrg -TargetRepo $TargetRepo -SourcePAT $SourcePAT -TargetPAT $TargetPAT -Force:$Force
        }
        'actionrepovariables' {
            Migrate-RepoVariables
        }
        default {
            Write-Warning "Migration type '$type' is not implemented."
        }
    }
}
