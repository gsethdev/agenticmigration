"""generate_migration_settings - Create Azure deployment configuration."""

import json
import os

from mcp.server.fastmcp import Context

from tools import server
from ps_runner import run_powershell, read_json_file, PsError, SCRIPTS_DIR


@server.tool(
    name="generate_migration_settings",
    description=(
        "Generate Azure migration settings from packaged sites. "
        "Creates a MigrationSettings.json file containing App Service Plan configuration, "
        "Azure site names, subscription, resource group, and region. "
        "Requires the PackageResults.json from a previous package_site call. "
        "The output file can be reviewed and edited before running migrate_sites."
    ),
)
async def generate_migration_settings(
    package_results_path: str,
    region: str,
    subscription_id: str,
    resource_group: str,
    app_service_environment: str = "",
    output_path: str = "",
    is_managed_instance: bool = False,
    plan_name: str = "",
    install_script_path: str = "",
    ctx: Context | None = None,
) -> str:
    """Generate migration settings JSON.

    Args:
        package_results_path: Path to PackageResults.json from package_site.
        region: Azure region (e.g. "East US", "westeurope").
        subscription_id: Azure subscription ID (GUID).
        resource_group: Azure resource group name.
        app_service_environment: Optional App Service Environment name.
        output_path: Optional custom path for MigrationSettings.json.
        is_managed_instance: If true, sets PV4 SKU and IsCustomMode=true for Managed Instance.
        plan_name: Optional App Service Plan name override.
        install_script_path: Optional path to install.ps1 for Managed Instance deployments.
    """
    if ctx:
        await ctx.report_progress(0, 100)
        ctx.info("Generating migration settings...")

    try:
        params: dict[str, str | bool | None] = {
            "SitePackageResultsPath": package_results_path,
            "Region": region,
            "SubscriptionId": subscription_id,
            "ResourceGroup": resource_group,
            "Force": True,
        }
        if app_service_environment:
            params["AppServiceEnvironment"] = app_service_environment
        if output_path:
            params["MigrationSettingsFilePath"] = output_path

        run_powershell("Generate-MigrationSettings.ps1", params, timeout_seconds=120)

        # Post-process for Managed Instance: inject PV4 tier, IsCustomMode, InstallScriptPath
        if is_managed_instance:
            settings_file = output_path if output_path else os.path.join(
                SCRIPTS_DIR, "MigrationSettings.json"
            )
            if os.path.isfile(settings_file):
                mi_settings = read_json_file(settings_file)
                plans_list = mi_settings if isinstance(mi_settings, list) else [mi_settings]
                for plan_entry in plans_list:
                    plan_entry["Tier"] = "PremiumV4"
                    plan_entry["IsCustomMode"] = True
                    if plan_name:
                        plan_entry["AppServicePlan"] = plan_name
                    if install_script_path:
                        plan_entry["InstallScriptPath"] = install_script_path
                with open(settings_file, "w", encoding="utf-8") as f:
                    json.dump(plans_list, f, indent=2)

        if ctx:
            await ctx.report_progress(80, 100)

        # Find the output file
        settings_file = output_path if output_path else os.path.join(
            SCRIPTS_DIR, "MigrationSettings.json"
        )

        settings = read_json_file(settings_file)

        output = {
            "migration_settings_path": settings_file,
            "settings": settings,
            "note": (
                "Review the settings above. You can edit the MigrationSettings.json file "
                "to change Azure site names, App Service Plan tier, or worker configuration "
                "before running migrate_sites."
            ),
        }

        if ctx:
            await ctx.report_progress(100, 100)
            ctx.info(f"Migration settings generated at: {settings_file}")

        return json.dumps(output, indent=2)

    except PsError as e:
        return e.to_json()
