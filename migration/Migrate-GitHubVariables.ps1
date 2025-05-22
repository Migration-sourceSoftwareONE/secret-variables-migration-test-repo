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
    $BodyJson = if ($Body) { $Body | ConvertTo-Json -Depth 10 } else { $null }

    try {
        Invoke-RestMethod -Method $Method -Uri $Uri -Headers $Headers -ContentType "application/json" -Body $BodyJson
    } catch {
        Write-Warning "API call failed: $($_.Exception.Message) [$Method $Uri]"
        return $null
    }
}

function Migrate-Secrets {
    param($type, $apiPath)

    Write-Host "== Migrating $type =="
    $sourceUri = "https://api.github.com/repos/$SourceOrg/$SourceRepo/$apiPath"
    $targetUri = "https://api.github.com/repos/$TargetOrg/$TargetRepo/$apiPath"

    $secrets = Invoke-GitHubApi -Method GET -Uri $sourceUri -Token $SourcePAT
    if (-not $secrets) { Write-Warning "Failed to fetch secrets from source."; return }

    $targetKeyInfo = Invoke-GitHubApi -Method GET -Uri "$targetUri/public-key" -Token $TargetPAT
    if (-not $targetKeyInfo) { Write-Warning "Failed to get public key from target."; return }

    $keyId = $targetKeyInfo.key_id
    $publicKey = $targetKeyInfo.key
    $repoFullName = "$TargetOrg/$TargetRepo"

    foreach ($secret in $secrets.secrets) {
        $name = $secret.name
        $check = Invoke-GitHubApi -Method GET -Uri "$targetUri/$name" -Token $TargetPAT
        if ($check -and -not $Force) {
            Write-Host "Secret '$name' already exists in target. Skipping."
            continue
        }

        if ($DryRun) {
            Write-Host "[DryRun] Would copy secret '$name'."
            continue
        }

        Write-Host "Copying secret '$name' with empty placeholder value..."
        $cmd = "gh secret set $name --repo $repoFullName --body ''"
        Invoke-Expression $cmd
    }
}

function Migrate-Variables {
    param($type, $apiPath)

    Write-Host "== Migrating $type =="
    $sourceUri = "https://api.github.com/repos/$SourceOrg/$SourceRepo/$apiPath"
    $targetUri = "https://api.github.com/repos/$TargetOrg/$TargetRepo/$apiPath"

    $variables = Invoke-GitHubApi -Method GET -Uri $sourceUri -Token $SourcePAT
    if (-not $variables) { Write-Warning "Failed to fetch variables from source."; return }

    foreach ($variable in $variables.variables) {
        $name = $variable.name
        $check = Invoke-GitHubApi -Method GET -Uri "$targetUri/$name" -Token $TargetPAT
        if ($check -and -not $Force) {
            Write-Host "Variable '$name' already exists in target. Skipping."
            continue
        }

        if ($DryRun) {
            Write-Host "[DryRun] Would copy variable '$name'."
            continue
        }

        Write-Host "Copying variable '$name' with empty value..."
        $body = @{ name = $name; value = "" }
        Invoke-GitHubApi -Method PATCH -Uri "$targetUri/$name" -Token $TargetPAT -Body $body
    }
}

foreach ($type in $Scope.Split(',')) {
    switch ($type.Trim()) {
        'actionsreposecrets'       { Migrate-Secrets -type "ACTIONS REPO SECRETS" -apiPath "actions/secrets" }
        'actionsrepovariables'     { Migrate-Variables -type "ACTIONS REPO VARIABLES" -apiPath "actions/variables" }
        'dependabotreposecrets'    { Migrate-Secrets -type "DEPENDABOT REPO SECRETS" -apiPath "dependabot/secrets" }
        'dependabotrepovariables'  { Migrate-Variables -type "DEPENDABOT REPO VARIABLES" -apiPath "dependabot/variables" }
        'codespacesreposecrets'    { Migrate-Secrets -type "CODESPACES REPO SECRETS" -apiPath "codespaces/secrets" }
        'codespacesrepovariables'  { Migrate-Variables -type "CODESPACES REPO VARIABLES" -apiPath "codespaces/variables" }
        default {
            Write-Warning "Type '$type' migration not implemented or invalid."
        }
    }
}
