param(
    [Parameter(Mandatory)] [string]$SourceOrg,
    [Parameter(Mandatory)] [string]$SourceRepo,
    [Parameter(Mandatory)] [string]$TargetOrg,
    [Parameter(Mandatory)] [string]$TargetRepo,
    [Parameter(Mandatory)] [string]$SourcePAT,
    [Parameter(Mandatory)] [string]$TargetPAT,
    [string]$Scope = "secrets",
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

function Migrate-ActionsSecrets {
    param(
        [string]$SourceOrg,
        [string]$SourceRepo,
        [string]$TargetOrg,
        [string]$TargetRepo,
        [string]$SourcePAT,
        [string]$TargetPAT,
        [switch]$Force,
        [switch]$DryRun
    )

    Write-Host "== Migrating ACTIONS SECRETS =="

    $sourceUri = "https://api.github.com/repos/$SourceOrg/$SourceRepo/actions/secrets"
    $targetUri = "https://api.github.com/repos/$TargetOrg/$TargetRepo/actions/secrets"


    $sourceSecrets = Invoke-GitHubApi -Method GET -Uri $sourceUri -Token $SourcePAT
    if (-not $sourceSecrets) {
        Write-Warning "Failed to fetch secrets from source repo."
        return
    }


    $targetKeyInfo = Invoke-GitHubApi -Method GET -Uri "$targetUri/public-key" -Token $TargetPAT
    if (-not $targetKeyInfo) {
        Write-Warning "Failed to get public key from target repo."
        return
    }
    $keyId = $targetKeyInfo.key_id
    $publicKey = $targetKeyInfo.key

    foreach ($secret in $sourceSecrets.secrets) {
        $name = $secret.name

        # Sprawdź czy sekret istnieje już w target
        $exists = $false
        $check = Invoke-GitHubApi -Method GET -Uri "$targetUri/$name" -Token $TargetPAT
        if ($check) { $exists = $true }

        if ($exists -and -not $Force) {
            Write-Host "Secret '$name' already exists in target. Skipping."
            continue
        }

        if ($DryRun) {
            Write-Host "[DryRun] Would copy secret '$name' with empty value."
            continue
        }

        Write-Host "Copying secret '$name' with empty placeholder value..."


        $repoFullName = "$TargetOrg/$TargetRepo"

        $setSecretCmd = "gh secret set $name --repo $repoFullName --body ''"
        Invoke-Expression $setSecretCmd
    }
}

# Główna logika wywołania wg Scope:
foreach ($type in $Scope.Split(',')) {
    switch ($type.Trim()) {
        'secrets' {
            Migrate-ActionsSecrets -SourceOrg $SourceOrg -SourceRepo $SourceRepo -TargetOrg $TargetOrg -TargetRepo $TargetRepo -SourcePAT $SourcePAT -TargetPAT $TargetPAT -Force:$Force -DryRun:$DryRun
        }
        default {
            Write-Warning "Type '$type' migration not implemented in this version."
        }
    }
}
