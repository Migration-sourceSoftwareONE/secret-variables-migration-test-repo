param(
    [Parameter(Mandatory)] [string]$SourceOrg,
    [Parameter(Mandatory)] [string]$SourceRepo,
    [Parameter(Mandatory)] [string]$TargetOrg,
    [Parameter(Mandatory)] [string]$TargetRepo,
    [Parameter(Mandatory)] [string]$SourcePAT,
    [Parameter(Mandatory)] [string]$TargetPAT,
    [ValidateSet("secrets", "variables", "all")] [string]$Scope = "all",
    [switch]$Force,
    [switch]$DryRun
)

function Invoke-GitHubApi {
    param (
        [string]$Method,
        [string]$Uri,
        [string]$Token,
        $Body = $null
    )
    $headers = @{ Authorization = "Bearer $Token"; Accept = "application/vnd.github+json" }
    if ($Body) {
        $jsonBody = $Body | ConvertTo-Json -Depth 10
        Invoke-RestMethod -Method $Method -Uri $Uri -Headers $headers -Body $jsonBody -ContentType "application/json"
    } else {
        Invoke-RestMethod -Method $Method -Uri $Uri -Headers $headers
    }
}

function Migrate-Secrets {
    Write-Host "`n== Migrating SECRETS =="
    $sourceUri = "https://api.github.com/repos/$SourceOrg/$SourceRepo/actions/secrets"
    $targetUri = "https://api.github.com/repos/$TargetOrg/$TargetRepo/actions/secrets"

    $sourceSecrets = Invoke-GitHubApi -Method GET -Uri $sourceUri -Token $SourcePAT

    foreach ($secret in $sourceSecrets.secrets) {
        $name = $secret.name
        $checkUri = "$targetUri/$name"
        try {
            Invoke-GitHubApi -Method GET -Uri $checkUri -Token $TargetPAT | Out-Null
            if (-not $Force) {
                Write-Host "Secret '$name' already exists in target. Skipping."
                continue
            }
        } catch {}

        if ($DryRun) {
            Write-Host "[DryRun] Would copy secret '$name'"
        } else {
            Write-Host "Copying secret '$name'"

            # Get public key for target
            $keyInfo = Invoke-GitHubApi -Method GET -Uri "$targetUri/public-key" -Token $TargetPAT
            $keyId = $keyInfo.key_id
            $key = $keyInfo.key

            # Get value from source (not possible via GitHub API)
            Write-Warning "Secret '$name' cannot be read from source – skipping (GitHub limitation)."
            continue

            # Uncomment below if you get value by another means
            # $value = "secret_value_here"
            # $bytes = [System.Text.Encoding]::UTF8.GetBytes($value)
            # $keyBytes = [Convert]::FromBase64String($key)
            # $encryptedBytes = ... # encrypt with LibSodium
            # $encryptedValue = [Convert]::ToBase64String($encryptedBytes)

            # Invoke-GitHubApi -Method PUT -Uri "$targetUri/$name" -Token $TargetPAT -Body @{
            #     encrypted_value = $encryptedValue
            #     key_id = $keyId
            # }
        }
    }
}

function Migrate-Variables {
    Write-Host "`n== Migrating VARIABLES =="
    $sourceUri = "https://api.github.com/repos/$SourceOrg/$SourceRepo/actions/variables"
    $targetUri = "https://api.github.com/repos/$TargetOrg/$TargetRepo/actions/variables"

    $sourceVars = Invoke-GitHubApi -Method GET -Uri $sourceUri -Token $SourcePAT

    foreach ($var in $sourceVars.variables) {
        $name = $var.name
        $value = $var.value

        $checkUri = "$targetUri/$name"
        $exists = $false
        try {
            Invoke-GitHubApi -Method GET -Uri $checkUri -Token $TargetPAT | Out-Null
            $exists = $true
        } catch {}

        if ($exists -and -not $Force) {
            Write-Host "Variable '$name' already exists in target. Skipping."
            continue
        }

        if ($DryRun) {
            Write-Host "[DryRun] Would copy variable '$name' = '$value'"
        } else {
            Write-Host "Copying variable '$name'"
            $body = @{ name = $name; value = $value }
            Invoke-GitHubApi -Method PUT -Uri "$targetUri/$name" -Token $TargetPAT -Body $body
        }
    }
}

# Entry
if ($Scope -eq "all" -or $Scope -eq "secrets") {
    Migrate-Secrets
}
if ($Scope -eq "all" -or $Scope -eq "variables") {
    Migrate-Variables
}
