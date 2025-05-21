param(
    [Parameter(Mandatory)] [string]$SourceOrg,
    [string]$SourceRepo,
    [Parameter()] [string]$TargetOrg,
    [string]$TargetRepo,
    [Parameter(Mandatory)] [string]$SourcePAT,
    [Parameter(Mandatory)] [string]$TargetPAT,
    [string]$Scope = "repo,env,codespaces,dependabot",
    [switch]$Force,
    [switch]$DryRun
)

# Validate parameters
if (-not $TargetOrg -and -not $TargetRepo) {
    Write-Error "Specify either -TargetOrg (for org migration) or -TargetRepo (same org migration)."
    exit 1
}

# Configure GH CLI contexts
function Set-GhContext {
    param($PAT)
    gh auth logout -h github.com -q
    $PAT | gh auth login --with-token
}

# Fetch list of repos
function Get-Repos {
    param($Org)
    gh repo list $Org --limit 1000 --json name -q '.[].name'
}

# Fetch items by type
function Get-Items {
    param($Org, $Repo, $Type)
    switch ($Type) {
        'repo'        { gh variable list --repo "$Org/$Repo" --json name -q '.[].name' }
        'env'         { gh environment list --repo "$Org/$Repo" --json name -q '.[].name' }
        'codespaces'  { gh codespace variable list --repo "$Org/$Repo" --json name -q '.[].name' }
        'dependabot'  { gh dependabot variable list --repo "$Org/$Repo" --json name -q '.[].name' }
        'secrets'     { gh secret list --repo "$Org/$Repo" --json name -q '.[].name' }
    }
}

# Copy single item
function Copy-Item {
    param($Type, $SourceOrg, $SourceRepo, $Name, $TargetOrg, $TargetRepo)
    $dest = if ($TargetRepo) {"$TargetOrg/$TargetRepo"} else {$TargetOrg}
    $cmd = switch ($Type) {
        'repo'        {"gh variable set $Name --repo $dest --body ''"}
        'env'         {"gh environment variable set $Name --repo $dest --body ''"}
        'codespaces'  {"gh codespace variable set $Name --repo $dest --body ''"}
        'dependabot'  {"gh dependabot variable set $Name --repo $dest --body ''"}
        'secrets'     {"gh secret set $Name --repo $dest --body ''"}
    }
    if ($DryRun) {
        Write-Host "[DryRun] $cmd"
    } else {
        Invoke-Expression $cmd
    }
}

# Main migration
Set-GhContext $SourcePAT
$sourceRepos = if ($SourceRepo) { @($SourceRepo) } else { Get-Repos -Org $SourceOrg }

Set-GhContext $TargetPAT
$targetRepos = if ($TargetRepo) { @($TargetRepo) } else { Get-Repos -Org $TargetOrg }

foreach ($repo in $sourceRepos) {
    if ($SourceRepo -and -not $targetRepos.Contains($TargetRepo)) {
        Write-Warning "Target repo $TargetRepo does not exist in $TargetOrg. Skipping."
        continue
    }
    if ($SourceRepo -eq $null -and -not $targetRepos.Contains($repo)) {
        Write-Warning "Repo $repo missing in target. Skipping."
        continue
    }
    $destRepo = $TargetRepo ? $TargetRepo : $repo
    foreach ($type in $Scope.Split(',')) {
        $items = Get-Items -Org $SourceOrg -Repo $repo -Type $type
        foreach ($name in $items) {
            $exists = Get-Items -Org $TargetOrg -Repo $destRepo -Type $type | Where-Object { $_ -eq $name }
            if ($exists -and -not $Force) {
                Write-Host "$type '$name' exists in $destRepo. Skipping."
                continue
            }
            Copy-Item -Type $type -SourceOrg $SourceOrg -SourceRepo $repo -Name $name -TargetOrg $TargetOrg -TargetRepo $destRepo
            Write-Host "Copied $type '$name' to $TargetOrg/$destRepo"
        }
    }
}
