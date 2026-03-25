"""assess_site_readiness - Drill into a specific site's readiness details.

Pure Python tool — reads ReadinessResults.json and enriches check IDs
with human-readable descriptions from WebAppCheckResources.resx.
"""

import json
import os
import xml.etree.ElementTree as ET

from tools import server
from ps_runner import SCRIPTS_DIR, PsError, read_json_file

# Parse the .resx file once at import time to build a check-description lookup.
_CHECK_RESOURCES: dict[str, dict[str, str]] = {}


def _load_resx() -> None:
    resx_path = os.path.join(SCRIPTS_DIR, "WebAppCheckResources.resx")
    if not os.path.isfile(resx_path):
        return
    tree = ET.parse(resx_path)
    root = tree.getroot()
    raw: dict[str, str] = {}
    for data in root.findall("data"):
        name = data.get("name", "")
        value_el = data.find("value")
        if value_el is not None and value_el.text:
            raw[name] = value_el.text

    # Group by check prefix: e.g. "AuthCheck" -> {Title, Description, Recommendation, ...}
    prefixes: set[str] = set()
    suffixes = [
        "Title",
        "Description",
        "Recommendation",
        "Category",
        "MoreInformation",
        "MoreInformationLink",
    ]
    for key in raw:
        for suffix in suffixes:
            if key.endswith(suffix):
                prefix = key[: -len(suffix)]
                prefixes.add(prefix)
                break

    for prefix in prefixes:
        entry: dict[str, str] = {}
        for suffix in suffixes:
            full_key = prefix + suffix
            if full_key in raw:
                entry[suffix.lower()] = raw[full_key]
        _CHECK_RESOURCES[prefix] = entry


_load_resx()


def _enrich_check(check_id: str, check_data: dict) -> dict:
    """Add human-readable fields to a check from the .resx resources."""
    enriched = dict(check_data)
    enriched["check_id"] = check_id

    # Try exact match first, then strip "Check" variations
    resources = _CHECK_RESOURCES.get(check_id)
    if not resources:
        # Try appending "Check" if not present
        resources = _CHECK_RESOURCES.get(check_id + "Check")
    if resources:
        enriched["title"] = resources.get("title", "")
        enriched["description_template"] = resources.get("description", "")
        enriched["recommendation"] = resources.get("recommendation", "")
        enriched["category"] = resources.get("category", "")
        enriched["more_info_link"] = resources.get("moreinformationlink", "")
    return enriched


@server.tool(
    name="assess_site_readiness",
    description=(
        "Get detailed readiness assessment for a specific IIS site. "
        "Reads the ReadinessResults.json from a previous discover_iis_sites call "
        "and returns enriched check details with human-readable descriptions, "
        "recommendations, and documentation links for the named site. "
        "Does NOT require Administrator privileges or re-run discovery."
    ),
)
async def assess_site_readiness(
    readiness_results_path: str,
    site_name: str,
    appcat_results_path: str = "",
) -> str:
    """Get detailed assessment for one site.

    Args:
        readiness_results_path: Path to ReadinessResults.json from discover_iis_sites.
        site_name: The IIS site name to assess.
        appcat_results_path: Optional path to AppCat JSON to merge into the assessment.
    """
    try:
        if not os.path.isfile(readiness_results_path):
            raise PsError(
                "FILE_NOT_FOUND",
                f"Readiness results file not found: {readiness_results_path}. "
                "Run discover_iis_sites first.",
            )

        results = read_json_file(readiness_results_path)

        sites = results if isinstance(results, list) else [results]

        site = None
        for s in sites:
            if s.get("SiteName", "").lower() == site_name.lower():
                site = s
                break

        if site is None:
            available = [s.get("SiteName", "?") for s in sites]
            return json.dumps(
                {
                    "error": True,
                    "error_type": "SITE_NOT_FOUND",
                    "message": f"Site '{site_name}' not found in readiness results.",
                    "available_sites": available,
                },
                indent=2,
            )

        # Determine overall status
        fatal = site.get("FatalErrorFound", False)
        failed_checks = site.get("FailedChecks", [])
        warning_checks = site.get("WarningChecks", [])

        if fatal:
            overall_status = "BLOCKED"
        elif failed_checks:
            overall_status = "READY_WITH_ISSUES"
        elif warning_checks:
            overall_status = "READY_WITH_WARNINGS"
        else:
            overall_status = "READY"

        # Enrich checks
        enriched_failed = []
        for check in failed_checks:
            if isinstance(check, dict):
                check_id = check.get("CheckId", check.get("checkId", "Unknown"))
                enriched_failed.append(_enrich_check(check_id, check))
            elif isinstance(check, str):
                enriched_failed.append(_enrich_check(check, {"raw": check}))

        enriched_warnings = []
        for check in warning_checks:
            if isinstance(check, dict):
                check_id = check.get("CheckId", check.get("checkId", "Unknown"))
                enriched_warnings.append(_enrich_check(check_id, check))
            elif isinstance(check, str):
                enriched_warnings.append(_enrich_check(check, {"raw": check}))

        assessment = {
            "site_name": site.get("SiteName", site_name),
            "overall_status": overall_status,
            "framework_version": site.get("NetFrameworkVersion", "Unknown"),
            "managed_pipeline_mode": site.get("ManagedPipelineMode", "Unknown"),
            "is_32_bit": site.get("Is32Bit", False),
            "virtual_applications": site.get("VirtualApplications", []),
            "bindings": site.get("Bindings", []),
            "failed_checks": enriched_failed,
            "warning_checks": enriched_warnings,
            "failed_check_count": len(enriched_failed),
            "warning_check_count": len(enriched_warnings),
        }

        # Merge AppCat results if provided
        if appcat_results_path and os.path.isfile(appcat_results_path):
            try:
                appcat = read_json_file(appcat_results_path)
                appcat_rules = appcat if isinstance(appcat, list) else appcat.get("rules", [appcat])
                assessment["appcat_summary"] = {
                    "total_rules": len(appcat_rules),
                    "total_incidents": sum(
                        len(r.get("incidents", r.get("Incidents", [])))
                        for r in appcat_rules
                    ),
                    "source": appcat_results_path,
                }
            except Exception:
                assessment["appcat_summary"] = {"error": "Failed to parse AppCat JSON"}

        return json.dumps(assessment, indent=2)

    except PsError as e:
        return e.to_json()
    except Exception as e:
        return json.dumps(
            {
                "error": True,
                "error_type": "PARSE_ERROR",
                "message": f"Failed to parse readiness results: {e}",
            },
            indent=2,
        )
