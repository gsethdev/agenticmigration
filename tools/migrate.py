"""migrate_sites - Deploy packaged sites to Azure App Service."""

import json
import os

from mcp.server.fastmcp import Context

from tools import server
from ps_runner import run_powershell, read_json_file, PsError, SCRIPTS_DIR


@server.tool(
    name="migrate_sites",
    description=(
        "Deploy packaged web sites to Azure App Service using the migration settings. "
        "This creates Azure resources (App Service Plan, App Services) and deploys the site packages. "
        "IMPORTANT: This creates billable Azure resources. Confirm with the user before proceeding. "
        "Requires Azure PowerShell to be authenticated (Connect-AzAccount). "
        "Requires the MigrationSettings.json from generate_migration_settings."
    ),
)
async def migrate_sites(
    migration_settings_path: str,
    output_path: str = "",
    ctx: Context | None = None,
) -> str:
    """Deploy sites to Azure App Service.

    Args:
        migration_settings_path: Path to MigrationSettings.json from generate_migration_settings.
        output_path: Optional custom path for MigrationResults.json.
    """
    if ctx:
        await ctx.report_progress(0, 100)
        ctx.info("Starting migration to Azure App Service...")

    try:
        params: dict[str, str | bool | None] = {
            "MigrationSettingsFilePath": migration_settings_path,
            "Force": True,
        }
        if output_path:
            params["MigrationResultsFilePath"] = output_path

        run_powershell("Invoke-SiteMigration.ps1", params, timeout_seconds=600)

        if ctx:
            await ctx.report_progress(80, 100)

        # Find the results file
        results_file = output_path if output_path else os.path.join(
            SCRIPTS_DIR, "MigrationResults.json"
        )

        results = read_json_file(results_file)

        output = {
            "migration_results_path": results_file,
            "results": results,
        }

        if ctx:
            await ctx.report_progress(100, 100)
            ctx.info("Migration complete. Check results for deployed site URLs.")

        return json.dumps(output, indent=2)

    except PsError as e:
        return e.to_json()
