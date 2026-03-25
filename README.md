# IIS Migration MCP Server

AI-powered migration of ASP.NET Framework web applications from IIS to Azure App Service, including Managed Instance (MI) support for apps with OS-level dependencies.

## What It Does

This MCP server exposes 13 tools that guide the end-to-end migration workflow:

1. **Discovery** — Scan IIS for all web sites and run readiness checks
2. **Assessment** — Config-based (IIS/web.config) and source-code-based (AppCat) analysis
3. **Recommendation** — Determine MI vs standard App Service, identify adapter and install script needs
4. **Deployment Planning** — Package sites, generate ARM templates for MI adapters, create install.ps1
5. **Execution** — Deploy to Azure App Service with confirmation gate

## Prerequisites

| Requirement | Purpose | Required? |
|------------|---------|-----------|
| **Windows Server** with IIS | Source server to discover and package sites | Yes |
| **PowerShell 5.1** | Runs bundled migration scripts (ships with Windows) | Yes |
| **Python 3.10+** | MCP server runtime | Yes |
| **Administrator privileges** | IIS discovery, packaging, and migration | Yes |
| **Azure subscription** | Target for migration | Yes (execution phase only) |
| **Azure PowerShell (`Az` module)** | Deploy to Azure | Yes (execution phase only) |
| **Node.js 18+ LTS** | Only if using the app-modernization MCP server | Optional |
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
5. Or call individual tools directly:
   - *"Discover all IIS sites on this server"*
   - *"Assess readiness for Default Web Site"*
   - *"Package all sites for migration"*

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

Run the bundled scripts directly without the MCP layer:

```powershell
# Run as Administrator
cd scripts

# 1. Discover IIS sites
.\IISDiscovery.ps1

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

### Script Config (`scripts/ScriptConfig.json`)

| Setting | Default | Description |
|---------|---------|-------------|
| `EnableTelemetry` | `false` | Set to `true` to send anonymous usage telemetry to Microsoft |
| `PackagedSitesFolder` | `packagedsites\` | Output folder for site ZIP packages |
| `FatalChecks` | `ContentSizeCheck,...` | Checks that block migration if failed |

### Optional: App Modernization MCP Server

For source code modernization (upgrading .NET Framework, replacing SMTP with Azure Communication Services, etc.), add the companion MCP server:

```json
{
  "servers": {
    "app-modernization": {
      "command": "npx",
      "args": ["-y", "@microsoft/github-copilot-app-modernization-mcp-server@latest"]
    }
  }
}
```

Requires **Node.js 18+ LTS**. Licensed under MIT — free for commercial use.

## Workflow Overview

```
 IIS Server                    MCP Server                         Azure
 ┌─────────┐    ┌───────────────────────────────────┐    ┌──────────────────┐
 │ Sites    │───>│ 1. discover_iis_sites             │    │                  │
 │ web.conf │    │ 2. assess_site_readiness           │    │                  │
 │ binaries │    │ 3. assess_source_code (opt)        │    │                  │
 └─────────┘    │ 4. recommend_target                 │    │                  │
                │ 5. generate_install_script (MI)     │    │  App Service     │
                │ 6. generate_adapter_arm_template(MI)│    │  ┌────────────┐  │
                │ 7. package_site                     │───>│  │ MI (PV4)   │  │
                │ 8. generate_migration_settings      │    │  │ Standard   │  │
                │ 9. confirm_migration                │    │  └────────────┘  │
                │10. migrate_sites                    │    │                  │
                └───────────────────────────────────┘    └──────────────────┘
```

## Managed Instance (MI) Support

For apps with OS-level dependencies (Windows Registry, COM components, SMTP, local file I/O), the server recommends **MI on App Service** with:

- **PV4 SKU** with `IsCustomMode=true` (the only valid MI configuration)
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
│   ├── discover.py            # IIS site discovery
│   ├── assess.py              # Config-based assessment
│   ├── assess_source.py       # AppCat source code assessment
│   ├── recommend.py           # Target recommendation engine
│   ├── install_script.py      # install.ps1 generator (OS-level)
│   ├── generate_adapter_arm.py# MI adapter ARM template generator
│   ├── package.py             # Site packaging
│   ├── generate_settings.py   # MigrationSettings.json generator
│   ├── confirm_migration.py   # Pre-execution confirmation gate
│   ├── migrate.py             # Azure deployment execution
│   └── suggest.py             # Migration approach router
├── scripts/                   # Bundled PowerShell migration scripts
│   ├── IISDiscovery.ps1
│   ├── Get-SiteReadiness.ps1
│   ├── Get-SitePackage.ps1
│   ├── Generate-MigrationSettings.ps1
│   ├── Invoke-SiteMigration.ps1
│   └── ...
└── ARCHITECTURE.md            # Detailed architecture documentation
```

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

The bundled PowerShell migration scripts are provided by Microsoft for Azure App Service migration.
