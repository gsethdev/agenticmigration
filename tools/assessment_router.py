"""choose_assessment_mode - Route sites to assessment or direct packaging.

Pure Python tool — reads discovery results and returns per-site assessment plan.
"""

import json
import os
from enum import Enum

from tools import server
from ps_runner import PsError, read_json_file


class AssessmentMode(str, Enum):
    ASSESS_ALL = "assess_all"
    PACKAGE_AND_MIGRATE = "package_and_migrate"


@server.tool(
    name="choose_assessment_mode",
    description=(
        "Route discovered IIS sites to either detailed assessment or direct packaging. "
        "Takes the discovery results and a customer-chosen mode, then returns a per-site "
        "assessment plan indicating whether each site should get config-only assessment, "
        "config+source assessment, or skip straight to packaging."
    ),
)
async def choose_assessment_mode(
    readiness_results_path: str,
    mode: str = "assess_all",
    sites_to_assess: str = "",
) -> str:
    """Route sites based on customer preference.

    Args:
        readiness_results_path: Path to ReadinessResults.json from discover_iis_sites.
        mode: "assess_all" to assess every site, or "package_and_migrate" to skip assessment.
        sites_to_assess: Comma-separated site names to assess (only used when mode is assess_all).
                         If empty, all sites are assessed.
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

        # Parse site filter
        filter_names = set()
        if sites_to_assess:
            filter_names = {n.strip().lower() for n in sites_to_assess.split(",") if n.strip()}

        plan = []
        for site in sites:
            site_name = site.get("SiteName", "Unknown")
            fatal = site.get("FatalErrorFound", False)
            source_detected = site.get("SourceCodeDetected", False)
            source_path = site.get("SourcePath", "")

            # Determine action
            if fatal:
                action = "blocked"
                reason = "Site has fatal readiness errors and cannot be migrated."
            elif mode == "package_and_migrate":
                action = "package"
                reason = "Customer chose to skip assessment and proceed to packaging."
            elif filter_names and site_name.lower() not in filter_names:
                action = "skip"
                reason = "Site not in the selected assessment list."
            else:
                if source_detected and source_path:
                    action = "assess_config_and_source"
                    reason = (
                        f"Source code detected at {source_path}. "
                        "Will run config + source code assessment."
                    )
                else:
                    action = "assess_config_only"
                    reason = "No source code detected. Will run config-based assessment only."

            plan.append({
                "site_name": site_name,
                "action": action,
                "reason": reason,
                "source_code_detected": source_detected,
                "source_path": source_path,
            })

        output = {
            "mode": mode,
            "readiness_results_path": readiness_results_path,
            "site_plans": plan,
            "summary": {
                "total": len(plan),
                "assess_config_and_source": sum(1 for p in plan if p["action"] == "assess_config_and_source"),
                "assess_config_only": sum(1 for p in plan if p["action"] == "assess_config_only"),
                "package": sum(1 for p in plan if p["action"] == "package"),
                "blocked": sum(1 for p in plan if p["action"] == "blocked"),
                "skip": sum(1 for p in plan if p["action"] == "skip"),
            },
        }

        return json.dumps(output, indent=2)

    except PsError as e:
        return e.to_json()
    except Exception as e:
        return json.dumps(
            {"error": True, "error_type": "ROUTING_ERROR", "message": str(e)},
            indent=2,
        )
