param(
    [Parameter(Mandatory)] [string]$SourceOrg,
    [Parameter(Mandatory)] [string]$SourceRepo,
    [Parameter(Mandatory)] [string]$TargetOrg,
    [Parameter(Mandatory)] [string]$TargetRepo,
    [Parameter(Mandatory)] [string]$SourcePAT,
    [Parameter(Mandatory)] [string]$TargetPAT,
    [string]$Scope = "actionsreposecrets",
    [switch]$Force,
    [switch]$DryRun
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
    param($SourceOrg, $SourceRepo, $TargetOrg, $TargetRepo, $SourcePAT, $TargetPAT, $Force, $DryRun)

    Write-Host "== Migrating ACTIONS REPOSITORY SECRETS =="

    $sourceUri = "https://api.github.com/repos/$SourceOrg/$SourceRepo/actions/secrets"
    $targetUri = "https://api.github.com/repos/$TargetOrg/$TargetRepo/actions/secrets"

    $sourceSecrets = Invoke-GitHubApi -Method GET -Uri $sourceUri -Token $SourcePAT
    if (-not $sourceSecrets) {
        Write-Warning "Failed to fetch source actions secrets."
        return
    }

    $targetKeyInfo = Invoke-GitHubApi -Method GET -Uri "$targetUri/public-key" -Token $TargetPAT
    if (-not $targetKeyInfo) {
        Write-Warning "Failed to get target repo public key."
        return
    }
    $keyId = $targetKeyInfo.key_id
    $publicKey = $targetKeyInfo.key

    foreach ($secret in $sourceSecrets.secrets) {
        $name = $secret.name
        # Check if secret exists on target
        $exists = $false
        $check = Invoke-GitHubApi -Method GET -Uri "$targetUri/$name" -Token $TargetPAT
        if ($check) { $exists = $true }

        if ($exists -and -not $Force) {
            Write-Host "Secret '$name' already exists on target. Skipping."
            continue
        }

        if ($DryRun) {
            Write-Host "[DryRun] Would copy secret '$name' with empty value."
            continue
        }

        Write-Host "Copying secret '$name' with empty placeholder..."

        $repoFullName = "$TargetOrg/$TargetRepo"
        $setSecretCmd = "gh secret set $name --repo $repoFullName --body ''"
        Invoke-Expression $setSecretCmd
    }
}

function Migrate-ActionsRepoVariables {
    param($SourceOrg, $SourceRepo, $TargetOrg, $TargetRepo, $SourcePAT, $TargetPAT, $Force, $DryRun)

    Write-Host "== Migrating ACTIONS REPOSITORY VARIABLES =="

    $sourceUri = "https://api.github.com/repos/$SourceOrg/$SourceRepo/actions/variables"
    $targetUri = "https://api.github.com/repos/$TargetOrg/$TargetRepo/actions/variables"

    $sourceVars = Invoke-GitHubApi -Method GET -Uri $sourceUri -Token $SourcePAT
    if (-not $sourceVars) {
        Write-Warning "Failed to fetch source actions variables."
        return
    }

    foreach ($variable in $sourceVars.variables) {
        $name = $variable.name
        $value = $variable.value

        # Check if variable exists on target
        $exists = $false
        $targetVars = Invoke-GitHubApi -Method GET -Uri $targetUri -Token $TargetPAT
        if ($targetVars.variables | Where-Object { $_.name -eq $name }) {
            $exists = $true
        }

        if ($exists -and -not $Force) {
            Write-Host "Variable '$name' already exists on target. Skipping."
            continue
        }

        if ($DryRun) {
            Write-Host "[DryRun] Would copy variable '$name' with value."
            continue
        }

        Write-Host "Copying variable '$name'..."

        $body = @{ name = $name; value = $value }
        Invoke-GitHubApi -Method PUT -Uri "$targetUri/$name" -Token $TargetPAT -Body $body
    }
}

function Migrate-DependabotRepoSecrets {
    param($SourceOrg, $SourceRepo, $TargetOrg, $TargetRepo, $SourcePAT, $TargetPAT, $Force, $DryRun)

    Write-Host "== Migrating DEPENDABOT REPOSITORY SECRETS =="

    $sourceUri = "https://api.github.com/repos/$SourceOrg/$SourceRepo/dependabot/secrets"
    $targetUri = "https://api.github.com/repos/$TargetOrg/$TargetRepo/dependabot/secrets"

    $sourceSecrets = Invoke-GitHubApi -Method GET -Uri $sourceUri -Token $SourcePAT
    if (-not $sourceSecrets) {
        Write-Warning "Failed to fetch source dependabot secrets."
        return
    }

    foreach ($secret in $sourceSecrets.secrets) {
        $name = $secret.name
        # Check if secret exists on target
        $exists = $false
        $check = Invoke-GitHubApi -Method GET -Uri "$targetUri/$name" -Token $TargetPAT
        if ($check) { $exists = $true }

        if ($exists -and -not $Force) {
            Write-Host "Secret '$name' already exists on target. Skipping."
            continue
        }

        if ($DryRun) {
            Write-Host "[DryRun] Would copy dependabot secret '$name'."
            continue
        }

        Write-Host "Copying dependabot secret '$name' with empty placeholder..."

        $repoFullName = "$TargetOrg/$TargetRepo"
        $setSecretCmd = "gh secret set $name --repo $repoFullName --body '' --visibility repository --app dependabot"
        Invoke-Expression $setSecretCmd
    }
}

function Migrate-CodespacesRepoSecrets {
    param($SourceOrg, $SourceRepo, $TargetOrg, $TargetRepo, $SourcePAT, $TargetPAT, $Force, $DryRun)

    Write-Host "== Migrating CODESPACES REPOSITORY SECRETS =="

    $sourceUri = "https://api.github.com/repos/$SourceOrg/$SourceRepo/codespaces/secrets"
    $targetUri = "https://api.github.com/repos/$TargetOrg/$TargetRepo/codespaces/secrets"

    $sourceSecrets = Invoke-GitHubApi -Method GET -Uri $sourceUri -Token $SourcePAT
    if (-not $sourceSecrets) {
        Write-Warning "Failed to fetch source codespaces secrets."
        return
    }

    foreach ($secret in $sourceSecrets.secrets) {
        $name = $secret.name
        # Check if secret exists on target
        $exists = $false
        $check = Invoke-GitHubApi -Method GET -Uri "$targetUri/$name" -Token $TargetPAT
        if ($check) { $exists = $true }

        if ($exists -and -not $Force) {
            Write-Host "Secret '$name' already exists on target. Skipping."
            continue
        }

        if ($DryRun) {
            Write-Host "[DryRun] Would copy codespaces secret '$name'."
            continue
        }

        Write-Host "Copying codespaces secret '$name' with empty placeholder..."

        $repoFullName = "$TargetOrg/$TargetRepo"
        $setSecretCmd = "gh secret set $name --repo $repoFullName --body '' --visibility repository --app codespaces"
        Invoke-Expression $setSecretCmd
    }
}

# Main scope dispatch
foreach ($type in $Scope.Split(',')) {
    switch ($type.Trim().ToLower()) {
        'actionsreposecrets' {
            Migrate-ActionsRepoSecrets -SourceOrg $SourceOrg -SourceRepo $SourceRepo -TargetOrg $TargetOrg -TargetRepo $TargetRepo -SourcePAT $SourcePAT -TargetPAT $TargetPAT -Force:$Force -DryRun:$DryRun
        }
        'actionsrepovariables' {
            Migrate-ActionsRepoVariables -SourceOrg $SourceOrg -SourceRepo $SourceRepo -TargetOrg $TargetOrg -TargetRepo $TargetRepo -SourcePAT $SourcePAT -TargetPAT $TargetPAT -Force:$Force -DryRun:$DryRun
        }
        'dependabotreposecrets' {
            Migrate-DependabotRepoSecrets -SourceOrg $SourceOrg -SourceRepo $SourceRepo -TargetOrg $TargetOrg -TargetRepo $TargetRepo -SourcePAT $SourcePAT -TargetPAT $TargetPAT -Force:$Force -DryRun:$DryRun
        }
        'codespacesreposecrets' {
            Migrate-CodespacesRepoSecrets -SourceOrg $SourceOrg -SourceRepo $SourceRepo -TargetOrg $TargetOrg -TargetRepo $TargetRepo -SourcePAT $SourcePAT -TargetPAT $TargetPAT -Force:$Force -DryRun:$DryRun
        }
        default {
            Write-Warning "Unknown scope type: $type"
        }
    }
}
