"""recommend_target - Recommend Azure deployment target per site.

Pure Python tool — analyzes combined config + source assessment results
and recommends MI on App Service, regular App Service, or Container Apps.
"""

import json

from tools import server


# Indicators that an app needs MI on App Service
_MI_INDICATORS = {
    "Local.0001": "Windows Registry access",
    "SMTP.0001": "SMTP server dependency",
    "Local.0003": "Local/network file I/O beyond web root",
    "Local.0004": "Logging to local paths",
    "Security.0103": "Certificate management (local cert store)",
}

# IIS readiness checks that indicate OS-level dependencies
_MI_CHECK_IDS = {
    "RegistryCheck": "Windows Registry usage detected",
    "GACCheck": "Global Assembly Cache (GAC) dependency",
    "COMCheck": "COM component dependency",
    "MSMQCheck": "MSMQ dependency",
    "WindowsServiceCheck": "Windows Service dependency",
}


def _build_provisioning_guidance(install_features: list, adapter_features: list) -> str:
    """Build human-readable provisioning guidance based on feature split."""
    parts = []
    if adapter_features:
        parts.append(
            f"ADAPTERS ({', '.join(adapter_features)}): Use generate_adapter_arm_template "
            "to create an ARM template for registry adapters and/or storage mounts. "
            "Alternatively, configure these in Azure Portal > App Service Plan > MI settings."
        )
    if install_features:
        parts.append(
            f"INSTALL SCRIPT ({', '.join(install_features)}): Use generate_install_script "
            "to create install.ps1 for OS-level feature enablement (COM/MSI, SMTP, MSMQ, etc.)."
        )
    if not parts:
        parts.append("No special provisioning needed beyond standard MI App Service Plan.")
    return " | ".join(parts)


@server.tool(
    name="recommend_target",
    description=(
        "Recommend the Azure deployment target for an IIS site based on assessment results. "
        "Analyzes config-based checks and optional AppCat source findings to determine "
        "whether the site needs Managed Instance on App Service (PV4), regular App Service, "
        "or Container Apps. Returns a recommendation with confidence level and reasoning."
    ),
)
async def recommend_target(
    site_name: str,
    config_assessment_json: str = "",
    source_assessment_json: str = "",
    framework_version: str = "",
    has_os_dependencies: bool = False,
) -> str:
    """Recommend Azure target for a site.

    Args:
        site_name: The IIS site name.
        config_assessment_json: JSON string of config assessment (from assess_site_readiness).
        source_assessment_json: JSON string of source assessment (from assess_source_code).
        framework_version: .NET Framework version (e.g., "v4.8", "v4.0").
        has_os_dependencies: Whether the app is known to need OS customization.
    """
    mi_reasons = []
    appservice_reasons = []
    blockers = []
    confidence = "high"

    # Parse config assessment
    config = {}
    if config_assessment_json:
        try:
            config = json.loads(config_assessment_json)
        except json.JSONDecodeError:
            pass

    # Parse source assessment
    source = {}
    if source_assessment_json:
        try:
            source = json.loads(source_assessment_json)
        except json.JSONDecodeError:
            pass

    # Check framework version
    fw = framework_version or config.get("framework_version", "")
    is_framework = fw.startswith("v4") or fw.startswith("v3") or fw.startswith("v2")
    is_dotnet_core = any(fw.startswith(p) for p in ["v5", "v6", "v7", "v8", "v9"])

    if is_framework:
        appservice_reasons.append(f".NET Framework {fw} — requires Windows App Service")
    elif is_dotnet_core:
        appservice_reasons.append(f".NET {fw} — can run on regular App Service (Linux or Windows)")

    # Analyze config assessment checks
    failed_checks = config.get("failed_checks", [])
    for check in failed_checks:
        check_id = check.get("check_id", "") if isinstance(check, dict) else str(check)
        if check_id in _MI_CHECK_IDS:
            mi_reasons.append(f"Config check: {_MI_CHECK_IDS[check_id]} ({check_id})")

    # Analyze source assessment findings
    for issue in source.get("mandatory_issues", []):
        rule_id = issue.get("rule_id", "")
        if rule_id in _MI_INDICATORS:
            mi_reasons.append(f"AppCat: {_MI_INDICATORS[rule_id]} ({rule_id})")

    for issue in source.get("optional_issues", []) + source.get("potential_issues", []):
        rule_id = issue.get("rule_id", "")
        if rule_id in _MI_INDICATORS:
            mi_reasons.append(f"AppCat: {_MI_INDICATORS[rule_id]} ({rule_id})")

    # Check install script features from source assessment (OS-level only)
    install_features = source.get("install_script_features", [])
    if install_features:
        mi_reasons.append(f"OS-level features (install.ps1): {', '.join(install_features)}")

    # Check adapter features from source assessment (Registry, Storage)
    adapter_features = source.get("adapter_features", [])
    if adapter_features:
        mi_reasons.append(f"Platform adapters (ARM template): {', '.join(adapter_features)}")

    # Explicit flag
    if has_os_dependencies:
        mi_reasons.append("Customer indicated OS-level dependencies")

    # Determine target
    if mi_reasons:
        target = "MI_AppService"
        reasoning = (
            "Managed Instance on App Service is recommended because the application "
            "has OS-level dependencies that require Windows feature installation or "
            "customization beyond standard App Service capabilities."
        )
        if not is_framework and is_dotnet_core:
            confidence = "medium"
            reasoning += (
                f" Note: The app uses .NET {fw} which could run on regular App Service. "
                "MI is recommended only due to the OS dependencies detected."
            )
    elif is_framework:
        target = "AppService"
        reasoning = (
            f"Regular Windows App Service is sufficient. The app uses .NET Framework {fw} "
            "and no OS-level dependencies were detected."
        )
    elif is_dotnet_core:
        target = "AppService"
        reasoning = (
            f"Regular App Service (Linux or Windows) is sufficient for .NET {fw}. "
            "No OS-level dependencies detected."
        )
        confidence = "high"
    else:
        target = "AppService"
        reasoning = (
            "No specific framework detected. Defaulting to regular Windows App Service. "
            "Consider Container Apps if the app is containerized."
        )
        confidence = "medium"

    # Check for blockers
    if config.get("overall_status") == "BLOCKED":
        blockers.append("Site has fatal readiness errors — resolve before migration.")

    output = {
        "site_name": site_name,
        "target": target,
        "confidence": confidence,
        "reasoning": reasoning,
        "mi_reasons": mi_reasons,
        "appservice_reasons": appservice_reasons,
        "blockers": blockers,
        "sku": "PremiumV4" if target == "MI_AppService" else "PremiumV2",
        "is_custom_mode": target == "MI_AppService",        "install_script_features": install_features,
        "adapter_features": adapter_features,
        "provisioning_guidance": (
            _build_provisioning_guidance(install_features, adapter_features)
            if target == "MI_AppService" else ""
        ),        "note": (
            "MI on App Service requires PV4 SKU with IsCustomMode=true. "
            "This is the ONLY valid configuration for Managed Instance."
        ) if target == "MI_AppService" else "",
    }

    return json.dumps(output, indent=2)
