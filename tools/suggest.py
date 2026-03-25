"""suggest_migration_approach - Route users to the right migration tool.

Pure Python tool with no PowerShell dependency.
"""

import json

from tools import server


@server.tool(
    name="suggest_migration_approach",
    description=(
        "Recommend the appropriate migration tool based on the scenario. "
        "Helps users choose between:\n"
        "- This IIS Migration MCP server (binaries-only, no source code, web.config analysis)\n"
        "- @microsoft/github-copilot-app-modernization-mcp-server (source code available, code transformation)\n"
        "Both target Azure App Service (including Managed Instance)."
    ),
)
async def suggest_migration_approach(
    has_source_code: bool,
    needs_os_customization: bool = False,
    description: str = "",
) -> str:
    """Suggest the right migration approach.

    Args:
        has_source_code: Whether .sln/.csproj/.cs source code is available.
        needs_os_customization: Whether the app needs registry, COM, MSI, or Windows Services.
        description: Brief description of the application.
    """
    if has_source_code:
        approach = {
            "recommended_tool": "@microsoft/github-copilot-app-modernization-mcp-server",
            "approach": "source-code-modernization",
            "reason": (
                "Source code is available. The GitHub Copilot App Modernization MCP server "
                "can analyze the code, identify migration patterns, and apply code transformations "
                "(e.g., replace SMTP with Azure Communication Services, add Managed Identity, "
                "upgrade .NET Framework to .NET 8)."
            ),
            "setup": {
                "mcp_json": {
                    "servers": {
                        "ghcp-appmod-mcp-server": {
                            "command": "npx",
                            "args": [
                                "-y",
                                "@microsoft/github-copilot-app-modernization-mcp-server@latest",
                            ],
                        }
                    }
                },
                "usage": "In Copilot Chat: 'Assess this .NET project for Azure migration'",
            },
            "available_tasks": [
                "Migrate to Managed Identity based Database (Azure SQL, PostgreSQL)",
                "Migrate to Azure File Storage",
                "Migrate to Azure Blob Storage",
                "Migrate to Microsoft Entra ID",
                "Migrate to Azure Key Vault with Managed Identity",
                "Migrate to Azure Service Bus",
                "Migrate to Azure Communication Service email",
                "Migrate to OpenTelemetry on Azure",
                "Migrate to Azure Cache for Redis",
            ],
        }

        if needs_os_customization:
            approach["note"] = (
                "Even though source code is available, the app needs OS-level customization "
                "(registry, COM, MSI). Consider deploying to App Service Managed Instance "
                "first using the IIS Migration MCP server (lift-and-shift), then modernizing "
                "the code with the App Modernization MCP server."
            )
            approach["complementary_tool"] = "iis-migration MCP server (this server)"

    else:
        approach = {
            "recommended_tool": "iis-migration MCP server (this server)",
            "approach": "config-based-lift-and-shift",
            "reason": (
                "Source code is not available. This MCP server discovers IIS sites, "
                "assesses web.config for migration readiness, packages the deployed binaries, "
                "and deploys to Azure App Service without needing source code."
            ),
            "workflow": [
                "1. discover_iis_sites - Find all sites and run readiness checks",
                "2. assess_site_readiness - Review detailed findings for each site",
                "3. package_site - Create ZIP deployment packages",
                "4. generate_migration_settings - Configure Azure target",
                "5. migrate_sites - Deploy to Azure App Service",
            ],
            "target": "Azure App Service (supports Managed Instance for complex dependencies)",
        }

        if needs_os_customization:
            approach["managed_instance_note"] = (
                "Azure App Service Managed Instance supports OS customization via Install.ps1 "
                "(registry keys, COM components, MSI installers, Windows Services). "
                "Create the Managed Instance App Service Plan first, then reference it "
                "in MigrationSettings.json."
            )

        approach["future_modernization"] = (
            "After migrating, if source code is later obtained, use "
            "@microsoft/github-copilot-app-modernization-mcp-server to incrementally "
            "modernize: upgrade framework, replace legacy patterns, add managed identity."
        )

    return json.dumps(approach, indent=2)
