# 🔁 GitHub Repository Migration Tool

This project provides a GitHub Actions-based workflow and PowerShell script to migrate secrets and variables between repositories and organizations.

---

## 🔐 Required Personal Access Tokens (PATs)

Both `SOURCE_PAT` and `TARGET_PAT` must be added as **Repository Secrets** in the target repository and require the following permissions:

### ✅ Repository Permissions
| Category             | Access       |
|----------------------|--------------|
| Actions              | Read and write |
| Codespaces           | Read and write |
| Codespaces metadata  | Read-only     |
| Codespaces secrets   | Read and write |
| Dependabot secrets   | Read and write |
| Environments         | Read and write |
| Metadata             | Read-only     |
| Secrets              | Read and write |
| Variables            | Read and write |

### ✅ Organization Permissions
| Category                        | Access         |
|----------------------------------|----------------|
| Organization codespaces          | Read and write |
| Organization codespaces secrets  | Read and write |
| Organization codespaces settings | Read and write |
| Organization dependabot secrets  | Read and write |
| Organization private registries  | Read and write |
| Secrets                          | Read and write |
| Variables                        | Read and write |

---

## 🧪 Supported Scope Types

Use the following scope strings (case-sensitive) in a comma-separated list to define what should be migrated:

| Scope                    | Description                                                   |
|--------------------------|---------------------------------------------------------------|
| `actionsreposecrets`     | GitHub Actions repository-level secrets                       |
| `actionsrepovariables`   | GitHub Actions repository-level variables                     |
| `dependabotreposecrets`  | Dependabot repository-level secrets                           |
| `dependabotrepovariables`| Dependabot repository-level variables                         |
| `codespacesreposecrets`  | GitHub Codespaces repository-level secrets                    |
| `codespacesrepovariables`| GitHub Codespaces repository-level variables                  |
| `actionsenvsecrets`      | GitHub Actions environment-level secrets                      |
| `actionsenvvariables`    | GitHub Actions environment-level variables                    |
| `actionsorgsecrets`      | GitHub Actions organization-level secrets                     |
| `actionsorgvariables`    | GitHub Actions organization-level variables                   |

---

## 🚀 How to Run the Migration

1. Navigate to the repository in GitHub
2. Go to the **Actions** tab
3. Select the workflow named **`Migrate Variables & Secrets`**
4. Click **Run workflow**
5. Fill in the required inputs:

### Inputs
| Input Name     | Required | Description                                                                 |
|----------------|----------|-----------------------------------------------------------------------------|
| `source_org`   | ✅       | Source GitHub organization name (e.g., `contoso-src`)                        |
| `source_repo`  | ❌       | (Optional) Source repository name. Leave empty to migrate all               |
| `target_org`   | ✅       | Target GitHub organization name (e.g., `contoso-dest`)                      |
| `target_repo`  | ✅       | Target repository name where data will be copied                           |
| `scope`        | ✅       | Comma-separated list of scopes to migrate (see scope table above)           |
| `force`        | ❌       | Optional: set to `true` to overwrite existing values in the target repo/org |

---

### 📁 Structure

- `.github/workflows/migrate.yml`: GitHub Actions workflow
- `migration/Migrate-GitHubVariables.ps1`: Main migration logic script

---

## 🛑 Limitations

- **Environment secrets/variables** require the target environment to exist. Creation may fail without `workflow` permission or when restricted by org policy.
- **PATs must be stored as repository secrets**, not passed as inputs.

---

## 📌 Example Scope Usage

```text
actionsreposecrets,actionsrepovariables,dependabotreposecrets,actionsenvsecrets,actionsorgvariables
