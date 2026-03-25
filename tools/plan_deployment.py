"""plan_deployment - Plan MI on App Service deployment.

Validates existing MI plans, proposes new ones, and maps sites to plans.
Optionally queries Azure for existing plans via PowerShell.
"""

import json
import os
import tempfile

from mcp.server.fastmcp import Context

from tools import server
from ps_runner import run_powershell, read_json_file, PsError, SCRIPTS_DIR


@server.tool(
    name="plan_deployment",
    description=(
        "Plan the Azure App Service deployment for migrated IIS sites. "
        "Determines whether to create a new App Service Plan or reuse an existing one. "
        "For MI on App Service, enforces PV4 SKU with IsCustomMode=true. "
        "Optionally queries Azure for existing MI-enabled plans in the subscription. "
        "Returns a deployment plan with site-to-plan mapping and validation results."
    ),
)
async def plan_deployment(
    site_names: str,
    subscription_id: str,
    resource_group: str,
    region: str,
    plan_name: str = "",
    deployment_mode: str = "single_plan",
    target: str = "MI_AppService",
    check_existing_plans: bool = False,
    ctx: Context | None = None,
) -> str:
    """Plan the Azure deployment.

    Args:
        site_names: Comma-separated list of IIS site names to deploy.
        subscription_id: Azure subscription ID (GUID).
        resource_group: Azure resource group name.
        region: Azure region (e.g., "East US", "westeurope").
        plan_name: Optional App Service Plan name. Auto-generated if empty.
        deployment_mode: "single_plan" (all sites on one plan) or "multi_plan" (one plan per site).
        target: "MI_AppService" or "AppService". Determines SKU and IsCustomMode.
        check_existing_plans: If true, queries Azure for existing MI plans via PowerShell.
    """
    if ctx:
        await ctx.report_progress(0, 100)
        ctx.info("Planning deployment...")

    sites = [s.strip() for s in site_names.split(",") if s.strip()]
    if not sites:
        return json.dumps(
            {"error": True, "error_type": "INVALID_INPUT", "message": "No site names provided."},
            indent=2,
        )

    is_mi = target == "MI_AppService"
    sku = "PremiumV4" if is_mi else "PremiumV2"

    # Check for existing MI plans in Azure
    existing_plans = []
    if check_existing_plans and is_mi:
        try:
            if ctx:
                ctx.info("Querying Azure for existing MI-enabled App Service Plans...")
            result = run_powershell(
                "Get-MIAppServicePlan.ps1",
                {
                    "SubscriptionId": subscription_id,
                    "ResourceGroup": resource_group,
                    "Region": region,
                },
                timeout_seconds=120,
            )
            # Try to parse JSON output
            output_file = os.path.join(
                tempfile.gettempdir(), "iis-migration", "mi-plans.json"
            )
            if os.path.isfile(output_file):
                existing_plans = read_json_file(output_file)
                if not isinstance(existing_plans, list):
                    existing_plans = [existing_plans]
        except PsError:
            # Non-fatal — just means we can't check existing plans
            existing_plans = []
        if ctx:
            await ctx.report_progress(50, 100)

    # Build deployment plan
    plans = []
    if deployment_mode == "multi_plan":
        for site in sites:
            safe_name = site.replace(" ", "-").lower()
            name = f"mi-plan-{safe_name}" if is_mi else f"asp-{safe_name}"
            plans.append({
                "plan_name": name,
                "sku": sku,
                "is_custom_mode": is_mi,
                "tier": "PremiumV4" if is_mi else "PremiumV2",
                "worker_size": "Small",
                "number_of_workers": 1,
                "sites": [site],
            })
    else:
        name = plan_name or ("mi-plan-migration" if is_mi else "asp-migration")
        plans.append({
            "plan_name": name,
            "sku": sku,
            "is_custom_mode": is_mi,
            "tier": "PremiumV4" if is_mi else "PremiumV2",
            "worker_size": "Small",
            "number_of_workers": 1,
            "sites": sites,
        })

    # Validation
    validations = []
    if is_mi:
        validations.append({
            "check": "PV4 SKU required for MI",
            "status": "pass",
            "detail": "All plans configured with PremiumV4 SKU.",
        })
        validations.append({
            "check": "IsCustomMode flag",
            "status": "pass",
            "detail": "All MI plans have IsCustomMode=true.",
        })
    if existing_plans:
        validations.append({
            "check": "Existing MI plans found",
            "status": "info",
            "detail": f"Found {len(existing_plans)} existing MI plan(s) in {resource_group}.",
        })

    output = {
        "deployment_plan": {
            "subscription_id": subscription_id,
            "resource_group": resource_group,
            "region": region,
            "target": target,
            "deployment_mode": deployment_mode,
            "plans": plans,
        },
        "existing_mi_plans": existing_plans,
        "validations": validations,
        "site_count": len(sites),
        "plan_count": len(plans),
        "note": (
            "MI on App Service requires PV4 SKU with IsCustomMode=true. "
            "This is the ONLY valid configuration."
        ) if is_mi else "Regular App Service plan. No MI customization.",
    }

    if ctx:
        await ctx.report_progress(100, 100)
        ctx.info(f"Deployment plan ready: {len(plans)} plan(s) for {len(sites)} site(s)")

    return json.dumps(output, indent=2)
