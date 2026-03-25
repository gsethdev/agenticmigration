"""discover_iis_sites - Discover all IIS web sites and run readiness checks."""

import json
import os
import tempfile

from mcp.server.fastmcp import Context

from tools import server
from ps_runner import run_powershell, read_json_file, PsError, SCRIPTS_DIR


_SOURCE_EXTENSIONS = {".sln", ".csproj", ".vbproj", ".cs", ".vb"}


def _detect_source_code(sites: list[dict]) -> None:
    """Scan each site's physical path for source code artifacts."""
    for site in sites:
        physical_path = site.get("PhysicalPath", site.get("physicalPath", ""))
        site["SourceCodeDetected"] = False
        site["SourcePath"] = ""
        if not physical_path or not os.path.isdir(physical_path):
            continue
        # Check site root and one level of parent directories for .sln/.csproj
        search_dirs = [physical_path]
        parent = os.path.dirname(physical_path)
        if parent and parent != physical_path:
            search_dirs.append(parent)
        for search_dir in search_dirs:
            try:
                for entry in os.scandir(search_dir):
                    if entry.is_file() and os.path.splitext(entry.name)[1].lower() in _SOURCE_EXTENSIONS:
                        site["SourceCodeDetected"] = True
                        site["SourcePath"] = search_dir
                        break
            except OSError:
                continue
            if site["SourceCodeDetected"]:
                break


@server.tool(
    name="discover_iis_sites",
    description=(
        "Discover all web sites on the local IIS server and run migration readiness checks. "
        "Returns a list of sites with their readiness status, failed checks, warnings, "
        "framework versions, and app pool configuration. "
        "Requires Administrator privileges and IIS to be installed. "
        "The output is saved to a ReadinessResults.json file that is used by subsequent tools."
    ),
)
async def discover_iis_sites(
    output_path: str = "",
    ctx: Context | None = None,
) -> str:
    """Discover IIS sites and assess readiness.

    Args:
        output_path: Directory to write ReadinessResults.json. Defaults to a temp directory.
    """
    if ctx:
        await ctx.report_progress(0, 100)
        ctx.info("Starting IIS site discovery and readiness assessment...")

    try:
        if not output_path:
            output_path = os.path.join(tempfile.gettempdir(), "iis-migration")
            os.makedirs(output_path, exist_ok=True)

        results_file = os.path.join(output_path, "ReadinessResults.json")

        run_powershell(
            "Get-SiteReadiness.ps1",
            {
                "ReadinessResultsOutputPath": results_file,
                "OverwriteReadinessResults": True,
            },
            timeout_seconds=300,
        )

        if ctx:
            await ctx.report_progress(80, 100)
            ctx.info("Parsing readiness results...")

        results = read_json_file(results_file)

        # Scan for source code artifacts per site
        sites = results if isinstance(results, list) else [results]
        _detect_source_code(sites)

        # Build a summary
        total = len(sites)
        ready = sum(
            1
            for s in sites
            if not s.get("FatalErrorFound", False)
            and not s.get("FailedChecks")
        )
        with_issues = sum(
            1
            for s in sites
            if not s.get("FatalErrorFound", False)
            and s.get("FailedChecks")
        )
        blocked = sum(1 for s in sites if s.get("FatalErrorFound", False))

        output = {
            "readiness_results_path": results_file,
            "summary": {
                "total_sites": total,
                "ready": ready,
                "ready_with_issues": with_issues,
                "blocked": blocked,
            },
            "sites": sites,
        }

        if ctx:
            await ctx.report_progress(100, 100)
            ctx.info(
                f"Discovery complete: {total} sites found "
                f"({ready} ready, {with_issues} with issues, {blocked} blocked)"
            )

        return json.dumps(output, indent=2)

    except PsError as e:
        return e.to_json()
