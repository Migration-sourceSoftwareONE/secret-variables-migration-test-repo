# GitHub Actions Secrets Migration Script

This repository contains a PowerShell script and GitHub Actions workflow to migrate GitHub secrets and variables between repositories, possibly across different organizations.

---

## What does this do?

- Migrates GitHub secrets and variables across various scopes:
  - Actions repository secrets and variables
  - Environment secrets and variables
  - Organization secrets and variables
  - Dependabot secrets (repository and organization level)
  - Codespaces secrets (repository and organization level)
- Preserves secret values through a secure extraction process
- Designed to be run with a self-hosted runner for secure extraction of secret values
- Supports migrating between repositories in different organizations

---

## How it works

### Two-phase process:

1. **Secret Extraction Phase**:
   - A workflow runs on a self-hosted runner in the source repository
   - Extracts secret values to secure temporary files on the runner
   
2. **Migration Phase**:
   - The PowerShell script reads extracted secret values
   - Recreates identical secrets and variables in the target repository
   - Handles different scopes (repository, environment, organization)
   - Maintains visibility settings for organization secrets

---

## Prerequisites

### 1. Generate Fine-Grained Personal Access Tokens (PATs)

You need **two PATs**: one for the source repository (Source PAT) and one for the target repository (Target PAT).

#### Fine-Grained PAT scopes required:

- **Repository Access**: Select the specific repository or organization scope (depending on use case).
- **Permissions**:
  - **Actions secrets**: `Read and write` access
  - **Dependabot secrets**: `Read and write` access (if migrating Dependabot secrets)
  - **Codespaces secrets**: `Read and write` access (if migrating Codespaces secrets)
  - **Metadata**: `Read` access

> Note: Do **NOT** use classic PATs for this script, only fine-grained PATs are supported and recommended.

### 2. Add PATs to GitHub Organization Secrets

Store your PATs as **organization secrets** in both source and target organizations:

- **Source PAT** secret name: `SOURCE_PAT`
- **Target PAT** secret name: `TARGET_PAT`

Make sure both secrets have access to **all repositories** in their respective organizations.

### 3. Set up a Self-Hosted Runner

A self-hosted runner is required to securely extract secret values:

1. **Set up a Windows self-hosted runner**:
   - Go to your source repository > Settings > Actions > Runners
   - Click "New self-hosted runner" and select Windows
   - Follow the instructions to download and configure the runner
   - Make sure the runner has the "self-hosted", "Windows", and "X64" labels

2. **Runner security recommendations**:
   - Set up the runner in a secure environment with limited access
   - Clean up the `C:\temp\secrets` directory after migration completes
   - Consider using a temporary runner that can be decommissioned after migration

---

## Usage

### Step 1: Extract Secrets (Source Repository)

1. **Create the Secret Extraction Workflow**:
   - Run the PowerShell script to generate the extraction workflow
   - The workflow file will be created at a temporary location
   - Create a new file in your source repository at `.github/workflows/extract_secrets.yml`
   - Copy the generated content to this file

2. **Example extraction workflow**:

```yaml
name: Extract Secrets

on:
  workflow_dispatch:

jobs:
  extract:
    runs-on: [self-hosted, Windows, X64]
    steps:
      - name: Export Secrets
        shell: powershell
        run: |
          New-Item -ItemType Directory -Path "C:\temp\secrets" -Force
          
          # Repository secrets
          echo "${{ secrets.SECRETC }}" > "C:\temp\secrets\repo_SECRETC.txt"
          echo "${{ secrets.SECRETC2 }}" > "C:\temp\secrets\repo_SECRETC2.txt"
          echo "${{ secrets.SOURCE_PAT }}" > "C:\temp\secrets\repo_SOURCE_PAT.txt"
          
          # Environment secrets
          echo "${{ secrets.ACTIONS_ENV_SECRET }}" > "C:\temp\secrets\env_test_ACTIONS_ENV_SECRET.txt"
          
          # Organization secrets
          echo "${{ secrets.ORG_SECRET }}" > "C:\temp\secrets\org_ORG_SECRET.txt"
          
          # Dependabot secrets (repo and org level)
          echo "${{ secrets.SECRET_DEPENDABOT }}" > "C:\temp\secrets\repo_SECRET_DEPENDABOT.txt"
          echo "${{ secrets.ORG_DEPENDABOT_SECRET }}" > "C:\temp\secrets\org_ORG_DEPENDABOT_SECRET.txt"
          
          # Codespaces secrets (repo and org level)
          echo "${{ secrets.SECRET_CODESPACES }}" > "C:\temp\secrets\repo_SECRET_CODESPACES.txt"
          echo "${{ secrets.ORG_CODESPACES_SECRET }}" > "C:\temp\secrets\org_ORG_CODESPACES_SECRET.txt"
          
          # List all files created
```

3. **Run the workflow**:
   - Go to the Actions tab in your source repository
   - Select the "Extract Secrets" workflow
   - Run the workflow manually

### Step 2: Run the Migration Script

Run the PowerShell script to migrate secrets from source to target repository:

```yaml
jobs:
  migrate-secrets:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - name: Run Migration Script
        env:
          GH_TOKEN: ${{ secrets.TARGET_PAT }}
        run: |
          pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File migration/Migrate-GitHubVariables.ps1 \
            -SourceOrg "${{ github.event.inputs.source_org }}" \
            -SourceRepo "${{ github.event.inputs.source_repo }}" \
            -TargetOrg "${{ github.event.inputs.target_org }}" \
            -TargetRepo "${{ github.event.inputs.target_repo }}" \
            -SourcePAT "${{ secrets.SOURCE_PAT }}" \
            -TargetPAT "${{ secrets.TARGET_PAT }}" \
            -Scope "all"
```

## Understanding the PowerShell Script

The PowerShell script (`Migrate-GitHubVariables.ps1`) performs several key functions:

1. **Secret Extraction Workflow Generation**:
   - Creates a template workflow file for extracting secrets
   - Dynamically identifies secrets and variables to extract
   - Generates the appropriate export commands for each secret type

2. **Secret Migration Process**:
   - Authenticates with GitHub using the provided PATs
   - Creates environments in the target repository (if needed)
   - Reads secret values from the extracted files
   - Creates corresponding secrets and variables in the target repository
   - Maintains proper visibility settings for organization-level secrets

3. **Scoped Migration**:
   - Supports selective migration of specific secret types
   - Available scopes include:
     - `actionsreposecrets`: Repository-level Actions secrets
     - `actionsrepovariables`: Repository-level Actions variables
     - `actionsenvsecrets`: Environment-level Actions secrets
     - `actionsenvvariables`: Environment-level Actions variables
     - `actionsorgsecrets`: Organization-level Actions secrets
     - `actionsorgvariables`: Organization-level Actions variables
     - `dependabotreposecrets`: Repository-level Dependabot secrets
     - `dependabotorgsecrets`: Organization-level Dependabot secrets
     - `codespacesreposecrets`: Repository-level Codespaces secrets
     - `codespacesorgsecrets`: Organization-level Codespaces secrets
     - `all`: All scopes (default)

4. **Error Handling and Reporting**:
   - Provides detailed progress information during migration
   - Reports success/failure for each secret/variable migration
   - Identifies missing secrets and provides appropriate warnings



