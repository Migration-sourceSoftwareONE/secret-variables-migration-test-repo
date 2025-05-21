# GitHub Actions Secrets Migration Script

This repository contains a PowerShell script and GitHub Actions workflow to migrate **GitHub Actions repository secrets** from one repository (source) to another repository (target), possibly across different organizations.

---

## What does this do?

- Migrates **GitHub Actions secrets** by name (only the secret names are copied).
- **Secret values are NOT transferred** due to GitHub API limitations.
- Currently supports migrating only **Actions secrets** (`actions` scope).
- Designed to be run as a GitHub Actions workflow or locally with PowerShell.
- Supports migrating between repositories in different organizations.

---

## How it works

- The script reads all **Actions secrets** from the source repository using the provided **Source PAT**.
- For each secret found, it creates a placeholder secret with the same name (but empty value) in the target repository using the **Target PAT**.
- This allows you to replicate the secret names and set their values manually afterward in the target repo.

---

## Prerequisites

### 1. Generate Fine-Grained Personal Access Tokens (PATs)

You need **two PATs**: one for the source repository (Source PAT) and one for the target repository (Target PAT).

#### Fine-Grained PAT scopes required:

- **Repository Access**: Select the specific repository or organization scope (depending on use case).
- **Permissions**:
  - **Actions secrets**: `Read and write` access
  - **Metadata**: `Read` access

> Note: Do **NOT** use classic PATs for this script, only fine-grained PATs are supported and recommended.

---

### 2. Add PATs to GitHub Organization Secrets

Store your PATs as **organization secrets** in both source and target organizations, so the GitHub Actions workflow can access them securely:

- **Source PAT** secret name: `SOURCE_PAT`
- **Target PAT** secret name: `TARGET_PAT`

Make sure both secrets have access to **all repositories** in their respective organizations.

---

## Usage

### GitHub Actions Workflow

Example workflow snippet to run the migration:

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
            -Scope "actions"
