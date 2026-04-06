# IIS Migration MCP Server

AI-powered migration of ASP.NET Framework web applications from IIS to Azure App Service, including Managed Instance on App Service support for apps with OS-level dependencies.

## What It Does

This MCP server exposes 13 tools that guide the end-to-end migration workflow:

1. **Discovery** — Scan IIS for all web sites and run readiness checks
2. **Assessment** — Config-based (IIS/web.config) and source-code-based (AppCat) analysis
3. **Recommendation** — Determine Managed Instance vs standard App Service, identify adapter and install script needs
4. **Deployment Planning** — Package sites, generate ARM templates for Managed Instance adapters, create install.ps1
5. **Execution** — Deploy to Azure App Service with confirmation gate

## Why Use This Over Raw PowerShell Scripts?

The underlying migration scripts are freely available from Microsoft — you can run them directly from the command line. So why wrap them in an MCP server with AI agents?

**Guided intelligence, not just automation.** The PowerShell scripts are powerful but dumb — they package, configure, and deploy exactly what you tell them to. They don't tell you *what* to do. This system adds a decision-making layer: it analyzes your apps, detects OS-level dependencies (COM, Registry, SMTP, local file I/O), recommends Managed Instance vs standard App Service, generates the right adapter ARM templates and install scripts, and validates every step before execution. With raw scripts, you need to know all of this upfront and wire it together yourself.

**Agentic workflow with human-in-the-loop.** The agent orchestration (`@iis-migrate`) breaks the migration into phases with explicit decision points. It won't skip assessment, won't deploy without confirmation, and won't let you misconfigure Managed Instance (PV4 + IsCustomMode=true is enforced). Each phase hands off to a specialist subagent that knows exactly which tools to call and what questions to ask. The result is a guided conversation — not a 200-line script you have to read, understand, and hope you parameterized correctly.

**Practical benefits:**

- **Reduced risk** — Automated readiness checks, source code analysis (via AppCat), and Managed Instance constraint validation catch issues before they become failed deployments
- **Faster time-to-migrate** — Discovery through deployment in a single conversation, with the AI handling script orchestration, JSON wiring between phases, and Azure authentication
- **No migration expertise required** — The system knows which sites need Managed Instance, which need adapters, which need install scripts, and which can go to standard App Service. You don't need to memorize the Managed Instance provisioning split (adapters via ARM vs OS features via install.ps1)
- **Audit trail** — Every phase produces artifacts (ReadinessResults.json, ARM templates, MigrationSettings.json) that document exactly what was assessed, recommended, and deployed
- **Works with any MCP client** — VS Code Copilot, Claude Desktop, Cursor, or any MCP-compatible tool. The intelligence travels with the server, not the client

## End-to-End Migration Flow

The complete journey from IIS discovery to a running app on Managed Instance on App Service:

```
┌─────────────────────────────────────────────────────────────────────────┐
│                     PHASE 0: SETUP                                      │
│                                                                         │
│  ► configure_scripts_path  OR  download_migration_scripts               │
│    Points the server to Microsoft's migration PowerShell scripts        │
│                                                                         │
│  Output: Scripts ready ✓                                                │
└────────────────────────────────┬────────────────────────────────────────┘
                                 │
                                 ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                     PHASE 1: DISCOVERY                                  │
│                                                                         │
│  ► discover_iis_sites                                                   │
│    Scans local IIS → enumerates all web sites, app pools, bindings,     │
│    framework versions, virtual directories                              │
│    Runs 15 readiness checks per site (config errors, HTTPS, ports,      │
│    content size, auth, ISAPI, app pool identity, etc.)                  │
│    Detects source code (.sln, .csproj, .cs, .vb) near site paths        │
│                                                                         │
│  Output: ReadinessResults.json                                          │
│          Per-site: READY / READY_WITH_WARNINGS / READY_WITH_ISSUES /    │
│                    BLOCKED                                              │
│                                                                         │
│  ► choose_assessment_mode                                               │
│    Routes each site to: assess (config-only or config+source),          │
│    skip to packaging, or mark blocked                                   │
└────────────────────────────────┬────────────────────────────────────────┘
                                 │
                                 ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                     PHASE 2: ASSESSMENT                                 │
│                                                                         │
│  ► assess_site_readiness  (per site)                                    │
│    Enriches readiness checks with human-readable descriptions,          │
│    recommendations, and documentation links from .resx metadata         │
│    Reports: overall status, failed checks, warning checks,              │
│    framework version, pipeline mode, virtual apps                       │
│                                                                         │
│  ► assess_source_code  (if source/AppCat report available)              │
│    Parses AppCat JSON → finds Managed Instance-relevant dependencies:   │
│      • Registry access (Local.0001) → needs Registry adapter            │
│      • Local file I/O (Local.0003/0004) → needs Storage adapter         │
│      • SMTP (SMTP.0001) → needs install.ps1                            │
│      • COM/GAC/MSMQ → needs install.ps1                                │
│      • Certificates (Security.0103) → needs Key Vault                   │
│    Categorizes: mandatory / optional / potential issues                  │
│    Maps to: install_script_features + adapter_features                  │
│                                                                         │
│  Output: Per-site assessment with Managed Instance dependency mapping   │
└────────────────────────────────┬────────────────────────────────────────┘
                                 │
                                 ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                     PHASE 3: RECOMMENDATION & PROVISIONING              │
│                                                                         │
│  ► recommend_target  (per site)                                         │
│    Analyzes config + source assessments →                               │
│    Recommends: MI_AppService (PV4) / AppService (PV2) / ContainerApps   │
│    Returns: confidence, reasoning, Managed Instance reasons, blockers,  │
│    required adapters, required install script features                   │
│                                                                         │
│  ► generate_install_script  (Managed Instance, OS-level dependencies)   │
│    Generates install.ps1 for: SMTP, MSMQ, COM/MSI, Crystal Reports,    │
│    custom fonts. Runs at app startup on the Managed Instance.           │
│                                                                         │
│  ► generate_adapter_arm_template  (Managed Instance, platform-level)    │
│    Generates ARM template for:                                          │
│      • Registry adapters (Key Vault-backed)                             │
│      • Storage mounts (AzureFiles / LocalStorage / Custom VNET)         │
│    Includes: managed identity config, RBAC guidance, deployment cmds    │
│                                                                         │
│  Output: install.ps1 + ARM template (customized per site)               │
│                                                                         │
│  ┌─────────────────────────────────────────────────────────────┐        │
│  │  MANAGED INSTANCE PROVISIONING SPLIT (critical concept):    │        │
│  │                                                             │        │
│  │  ARM Template (platform-level):                             │        │
│  │    • Registry adapters → Key Vault secrets                  │        │
│  │    • Storage mounts → Azure Files / local / VNET            │        │
│  │                                                             │        │
│  │  install.ps1 (OS-level):                                    │        │
│  │    • COM/MSI registration (regsvr32, RegAsm, msiexec)       │        │
│  │    • SMTP Server feature                                    │        │
│  │    • MSMQ                                                   │        │
│  │    • Crystal Reports runtime                                │        │
│  │    • Custom fonts                                           │        │
│  │    • File/folder permissions (ACLs)                         │        │
│  └─────────────────────────────────────────────────────────────┘        │
└────────────────────────────────┬────────────────────────────────────────┘
                                 │
                                 ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                     PHASE 4: DEPLOYMENT PLANNING & PACKAGING            │
│                                                                         │
│  ► plan_deployment                                                      │
│    Collects: subscription, resource group, region, plan name            │
│    Validates: PV4 SKU for Managed Instance, IsCustomMode=true enforced  │
│    Optionally queries Azure for existing Managed Instance plans to reuse│
│                                                                         │
│  ► package_site                                                         │
│    Creates ZIP packages from IIS site binaries + web.config             │
│    Optionally injects install.ps1 into the package                      │
│                                                                         │
│  ► generate_migration_settings                                          │
│    Creates MigrationSettings.json with:                                 │
│      • App Service Plan config (name, SKU, workers)                     │
│      • Per-site: IIS name → Azure name, package path                   │
│      • Managed Instance fields: Tier=PremiumV4, IsCustomMode=true       │
│                                                                         │
│  Output: Site ZIPs + MigrationSettings.json                             │
└────────────────────────────────┬────────────────────────────────────────┘
                                 │
                                 ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                     PHASE 5: EXECUTION  ⚠️ CREATES BILLABLE RESOURCES   │
│                                                                         │
│  ► confirm_migration                                                    │
│    Presents full summary: plans, sites, SKUs, costs                     │
│    REQUIRES explicit "yes" before proceeding                            │
│                                                                         │
│  ► migrate_sites                                                        │
│    For each plan:                                                       │
│      1. Set Azure subscription context                                  │
│      2. Create/validate Resource Group                                  │
│      3. Create/validate App Service Plan (PV4 for Managed Instance)     │
│    For each site:                                                       │
│      4. Create Web App                                                  │
│      5. Configure: .NET version, 32-bit mode, pipeline mode             │
│      6. Configure virtual directories/applications                      │
│      7. Disable basic auth (FTP + SCM)                                  │
│      8. Deploy ZIP package via REST API                                 │
│                                                                         │
│  Output: MigrationResults.json                                          │
│          Per-site: Azure URL, Resource ID, status                       │
│                                                                         │
│  ► Deploy adapter ARM template (post-migration)                         │
│    Configures registry/storage adapters on the Managed Instance plan    │
│    Assigns managed identity for Key Vault access                        │
└─────────────────────────────────────────────────────────────────────────┘
                                 │
                                 ▼
                    ┌──────────────────────────────────────┐
                    │   APP RUNNING ON MANAGED INSTANCE    │
                    │   *.azurewebsites.net                │
                    │                                      │
                    │   ✓ Registry → KV                    │
                    │   ✓ Storage → AzFiles                │
                    │   ✓ COM registered                   │
                    │   ✓ SMTP enabled                     │
                    └──────────────────────────────────────┘
```

| Requirement | Purpose | Required? |
|------------|---------|-----------|
| **Windows Server** with IIS | Source server to discover and package sites | Yes |
| **PowerShell 5.1** | Runs migration scripts (ships with Windows) | Yes |
| **Python 3.10+** | MCP server runtime | Yes |
| **Administrator privileges** | IIS discovery, packaging, and migration | Yes |
| **Azure subscription** | Target for migration | Yes (execution phase only) |
| **Azure PowerShell (`Az` module)** | Deploy to Azure | Yes (execution phase only) |
| **Migration Scripts ZIP** | [Download from Microsoft](https://appmigration.microsoft.com/api/download/psscripts/AppServiceMigrationScripts.zip) | Yes |
| **AppCat CLI** | Source code assessment (`appcat analyze`) | Optional |

## Installation

```bash
# 1. Clone the repository
git clone https://github.com/<your-org>/iis-migration-mcp.git
cd iis-migration-mcp

# 2. Create a virtual environment (recommended)
python -m venv .venv
.venv\Scripts\activate

# 3. Install dependencies
pip install -r requirements.txt

# 4. Download the PowerShell migration scripts
#    Download from: https://appmigration.microsoft.com/api/download/psscripts/AppServiceMigrationScripts.zip
#    Unzip to a local folder (e.g., C:\MigrationScripts)
```

## Setup

### Option A: VS Code with GitHub Copilot (Recommended)

1. Copy the example MCP config:
   ```
   copy .vscode\mcp.json.example .vscode\mcp.json
   ```
2. Open the folder in VS Code
3. GitHub Copilot will auto-detect the MCP server via `.vscode/mcp.json`
4. In Copilot Chat, use the **`@iis-migrate`** agent for guided workflow
5. When prompted, provide the path to the unzipped migration scripts folder
6. Or call individual tools directly:
   - *"Configure scripts path to C:\MigrationScripts"*
   - *"Discover all IIS sites on this server"*

### Option B: Any MCP Client (Copilot CLI, Claude Desktop, Cursor, etc.)

Add to your MCP client configuration:

```json
{
  "servers": {
    "iis-migration": {
      "command": "python",
      "args": ["server.py"],
      "cwd": "/path/to/iis-migration-mcp"
    }
  }
}
```

The server uses **stdio transport** and works with any MCP-compatible client.

### Option C: Direct PowerShell (No MCP / No AI)

Download and run the scripts directly without the MCP layer:

```powershell
# 1. Download scripts from:
#    https://appmigration.microsoft.com/api/download/psscripts/AppServiceMigrationScripts.zip
# 2. Unzip and cd into the folder
# 3. Run as Administrator

# Discover IIS sites

# 2. Package sites
.\Get-SitePackage.ps1 -ReadinessResultsFilePath ReadinessResults.json -MigrateSitesWithIssues

# 3. Generate migration settings
.\Generate-MigrationSettings.ps1 `
    -SitePackageResultsPath packagedsites\PackageResults.json `
    -Region "East US" `
    -SubscriptionId "<your-subscription-id>" `
    -ResourceGroup "<your-resource-group>"

# 4. Review MigrationSettings.json, then migrate
.\Invoke-SiteMigration.ps1 -MigrationSettingsFilePath MigrationSettings.json
```

## Configuration

### MCP Server Config (`.vscode/mcp.json`)

The `.vscode/mcp.json.example` file is provided as a template. Copy it to `.vscode/mcp.json` and adjust:

- **`command`**: Path to your Python executable. Use `"python"` if it's on your PATH, or the full path to your virtual environment's Python (e.g., `".venv\\Scripts\\python.exe"`).

### Script Config (`ScriptConfig.json`)

This file is included in the downloaded migration scripts (not in this repository).

| Setting | Default | Description |
|---------|---------|-------------|
| `EnableTelemetry` | `false` | Set to `true` to send anonymous usage telemetry to Microsoft |
| `PackagedSitesFolder` | `packagedsites\` | Output folder for site ZIP packages |
| `FatalChecks` | `ContentSizeCheck,...` | Checks that block migration if failed |

## Workflow Overview

```
 IIS Server                    MCP Server                                Azure
 ┌─────────┐    ┌───────────────────────────────────┐    ┌──────────────────────────────┐
 │ Sites    │───>│ 1. discover_iis_sites             │    │                              │
 │ web.conf │    │ 2. assess_site_readiness           │    │                              │
 │ binaries │    │ 3. assess_source_code (opt)        │    │                              │
 └─────────┘    │ 4. recommend_target                 │    │                              │
                │ 5. generate_install_script           │    │  App Service                 │
                │ 6. generate_adapter_arm_template     │    │  ┌────────────────────────┐  │
                │ 7. package_site                     │───>│  │ Managed Instance (PV4) │  │
                │ 8. generate_migration_settings      │    │  │ Standard               │  │
                │ 9. confirm_migration                │    │  └────────────────────────┘  │
                │10. migrate_sites                    │    │                              │
                └───────────────────────────────────┘    └──────────────────────────────┘
```

## Managed Instance on App Service Support

For apps with OS-level dependencies (Windows Registry, COM components, SMTP, local file I/O), the server recommends **Managed Instance on App Service** with:

- **PV4 SKU** with `IsCustomMode=true` (the only valid Managed Instance configuration)
- **Adapter ARM templates** for Registry and Storage dependencies (platform-level)
- **install.ps1** for OS-level features: COM/MSI installation, SMTP, MSMQ, fonts

## Project Structure

```
├── server.py                  # MCP server entry point
├── ps_runner.py               # Python → PowerShell bridge
├── requirements.txt           # Python dependencies
├── .vscode/
│   └── mcp.json.example       # Template MCP client config
├── .github/agents/            # VS Code Copilot agent definitions
│   ├── iis-migrate.agent.md   # Orchestrator agent
│   ├── iis-discover.agent.md  # Discovery subagent
│   ├── iis-assess.agent.md    # Assessment subagent
│   ├── iis-recommend.agent.md # Recommendation subagent
│   ├── iis-deploy-plan.agent.md # Deployment planning subagent
│   └── iis-execute.agent.md   # Execution subagent
├── tools/                     # MCP tool implementations (Python)
│   ├── configure.py           # Script path configuration
│   ├── discover.py            # IIS site discovery
│   ├── assess.py              # Config-based assessment
│   ├── assess_source.py       # AppCat source code assessment
│   ├── recommend.py           # Target recommendation engine
│   ├── install_script.py      # install.ps1 generator (OS-level)
│   ├── generate_adapter_arm.py# Managed Instance adapter ARM template generator
│   ├── package.py             # Site packaging
│   ├── generate_settings.py   # MigrationSettings.json generator
│   ├── confirm_migration.py   # Pre-execution confirmation gate
│   ├── migrate.py             # Azure deployment execution
│   └── suggest.py             # Migration approach router
└── ARCHITECTURE.md            # Detailed architecture documentation
```

> **Note:** PowerShell migration scripts are NOT bundled. Download them from
> [Microsoft](https://appmigration.microsoft.com/api/download/psscripts/AppServiceMigrationScripts.zip)
> and configure the path using the `configure_scripts_path` tool.

## Azure Authentication

Before the execution phase, authenticate with Azure:

```powershell
# Azure PowerShell
Connect-AzAccount
Set-AzContext -SubscriptionId "<your-subscription-id>"

# Or Azure CLI
az login
az account set --subscription "<your-subscription-id>"
```

## License

MIT License. See [LICENSE](LICENSE) for details.

The PowerShell migration scripts are provided by Microsoft for Azure App Service migration
and must be [downloaded separately](https://appmigration.microsoft.com/api/download/psscripts/AppServiceMigrationScripts.zip).
