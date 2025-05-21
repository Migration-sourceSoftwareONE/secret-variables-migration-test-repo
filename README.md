# GitHub Repository Secrets Migration Script

## Overview

This PowerShell script automates the migration of **GitHub Actions repository secrets** from a source repository to a target repository or organization. It helps transfer secret **names** (keys) to the new target, but **does not transfer the secret values** due to GitHub API limitations.

> **Important:**  
> Currently, the script only supports migrating **GitHub Actions secrets** scoped to repositories. Other types of secrets or variables (such as organization secrets, environment secrets, Codespaces secrets, or Dependabot secrets) are not yet supported.

## What the script does

- Connects to the **source repository** using a Personal Access Token (PAT) with access rights.
- Retrieves the **list of secret names** configured for GitHub Actions in the source repository.
- Connects to the **target repository or organization** using a separate PAT.
- For each secret name found in the source repo, attempts to **create a secret with the same name in the target repo**.
- Since secret **values cannot be read or copied by the GitHub API**, the script creates each secret in the target repository with an **empty placeholder value**.
- Includes options for **force overwriting existing secrets** and for **dry-run mode** (to simulate the process without making changes).

## Limitations

- **Secret values are not transferred.** This is a security restriction enforced by GitHub API — secret values are write-only.
- You will need to **manually set or update secret values** in the target repository after running the script.
- The script only supports **repository-level GitHub Actions secrets** (`actions` scope).
- No support yet for other secret types or organization-level secrets.
- The script requires two separate PATs: one with access to the source repo, and one with access to the target repo.
- The script uses the GitHub CLI internally and requires the environment variable `GH_TOKEN` to be set to the **target repository PAT** during execution.

## Usage in GitHub Actions workflow

```yaml
- name: Run Secrets Migration Script
  env:
    GH_TOKEN: ${{ secrets.TARGET_PAT }}  # Target repo PAT for GitHub CLI authentication
  run: |
    pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File migration/Migrate-GitHubVariables.ps1 \
    -SourceOrg "${{ github.event.inputs.source_org }}" \
    -SourceRepo "${{ github.event.inputs.source_repo }}" \
    -TargetOrg "${{ github.event.inputs.target_org }}" \
    -TargetRepo "${{ github.event.inputs.target_repo }}" \
    -SourcePAT "${{ secrets.SOURCE_PAT }}" \
    -TargetPAT "${{ secrets.TARGET_PAT }}" \
    -Scope "actions"  # Currently only "actions" scope (GitHub Actions secrets) is supported


## Setup — Fine-Grained Personal Access Tokens (FG PATs) and Permissions

GitHub now recommends using **Fine-Grained Personal Access Tokens (FG PATs)**, which allow for more precise permission control compared to classic tokens.

### How to create a Fine-Grained PAT

1. Go to: https://github.com/settings/tokens
2. Click **Generate new token** → **Fine-grained token**
3. Set **Repository access** to **Only select repositories**
   - Add the appropriate repositories (source repo for `SOURCE_PAT` and target repo for `TARGET_PAT`)
4. Under **Permissions**, assign the following permissions:

| For `SOURCE_PAT` (read access)            | For `TARGET_PAT` (write access)               |
|-------------------------------------------|-----------------------------------------------|
| **Repository permissions**                 | **Repository permissions**                     |
| - Actions secrets: Read                    | - Actions secrets: Write                       |
| - Contents: Read (may be required)        | - Contents: Read (may be required)             |

> **Note:** If your repositories are private or use environments or other features, adjust permissions accordingly.

5. Generate the token and **copy it immediately** — you will not be able to see it again.

### Where to set FG PATs

Store the tokens as **Secrets** in the repository that runs the workflow:

- `SOURCE_PAT` — with token granting access to the source repository
- `TARGET_PAT` — with token granting access to the target repository

### How the workflow uses these tokens

The workflow sets the environment variable `GH_TOKEN` to `TARGET_PAT` to enable writing secrets to the target repository:

```yaml
env:
  GH_TOKEN: ${{ secrets.TARGET_PAT }}
