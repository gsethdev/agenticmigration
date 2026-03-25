"""confirm_migration - Present final summary and require explicit confirmation.

Pure Python tool — reads MigrationSettings.json and produces a human-readable
summary for customer review before migration execution.
"""

import json
import os

from tools import server
from ps_runner import PsError, read_json_file


@server.tool(
    name="confirm_migration",
    description=(
        "Present a human-readable migration summary for customer review before execution. "
        "Reads the MigrationSettings.json and produces a clear summary of all Azure resources "
        "that will be created, including App Service Plans, sites, SKU, region, and cost tier. "
        "The customer must explicitly confirm before proceeding to migrate_sites."
    ),
)
async def confirm_migration(
    migration_settings_path: str,
) -> str:
    """Generate a migration confirmation summary.

    Args:
        migration_settings_path: Path to MigrationSettings.json from generate_migration_settings.
    """
    try:
        if not os.path.isfile(migration_settings_path):
            raise PsError(
                "FILE_NOT_FOUND",
                f"Migration settings file not found: {migration_settings_path}. "
                "Run generate_migration_settings first.",
            )

        settings = read_json_file(migration_settings_path)
        plans = settings if isinstance(settings, list) else [settings]

        summaries = []
        total_sites = 0

        for plan in plans:
            plan_name = plan.get("AppServicePlan", "Unknown")
            tier = plan.get("Tier", "Unknown")
            region = plan.get("Region", "Unknown")
            rg = plan.get("ResourceGroup", "Unknown")
            sub = plan.get("SubscriptionId", "Unknown")
            workers = plan.get("NumberOfWorkers", 1)
            worker_size = plan.get("WorkerSize", "Small")
            is_mi = plan.get("IsCustomMode", False)
            install_script = plan.get("InstallScriptPath", "")

            sites = plan.get("Sites", [])
            total_sites += len(sites)

            site_lines = []
            for site in sites:
                iis_name = site.get("IISSiteName", "?")
                azure_name = site.get("AzureSiteName", "?")
                package = site.get("SitePackagePath", "?")
                site_lines.append({
                    "iis_name": iis_name,
                    "azure_name": azure_name,
                    "package": package,
                })

            summaries.append({
                "plan_name": plan_name,
                "tier": tier,
                "is_managed_instance": is_mi,
                "region": region,
                "resource_group": rg,
                "subscription_id": sub,
                "workers": workers,
                "worker_size": worker_size,
                "install_script": install_script or "None",
                "sites": site_lines,
            })

        # Build cost warning
        has_mi = any(s["is_managed_instance"] for s in summaries)
        cost_note = (
            "PV4 is a premium tier. Costs apply immediately upon creation. "
            "See https://azure.microsoft.com/pricing/details/app-service/ for pricing."
        ) if has_mi else (
            "Standard App Service pricing applies. "
            "See https://azure.microsoft.com/pricing/details/app-service/ for pricing."
        )

        output = {
            "migration_settings_path": migration_settings_path,
            "summary": {
                "total_plans": len(summaries),
                "total_sites": total_sites,
                "has_managed_instance": has_mi,
            },
            "plans": summaries,
            "cost_warning": cost_note,
            "confirmation_required": True,
            "message": (
                "IMPORTANT: This migration will create billable Azure resources. "
                "Review the plan above carefully. "
                "To proceed, the customer must explicitly confirm with 'yes'."
            ),
        }

        return json.dumps(output, indent=2)

    except PsError as e:
        return e.to_json()
    except Exception as e:
        return json.dumps(
            {"error": True, "error_type": "CONFIRMATION_ERROR", "message": str(e)},
            indent=2,
        )
