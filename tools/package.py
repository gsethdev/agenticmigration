"""package_site - Package an IIS site into a ZIP for Azure migration."""

import json
import os
import tempfile

from mcp.server.fastmcp import Context

from tools import server
from ps_runner import run_powershell, read_json_file, PsError, SCRIPTS_DIR


@server.tool(
    name="package_site",
    description=(
        "Package an IIS web site into a ZIP file for deployment to Azure App Service. "
        "Requires the ReadinessResults.json from a previous discover_iis_sites call. "
        "Optionally package a single site by name, or all sites if site_name is omitted. "
        "Sites that failed readiness checks are skipped unless include_sites_with_issues is true. "
        "Requires Administrator privileges. "
        "Output: PackageResults.json with per-site package paths."
    ),
)
async def package_site(
    readiness_results_path: str,
    site_name: str = "",
    output_directory: str = "",
    include_sites_with_issues: bool = False,
    install_script_path: str = "",
    ctx: Context | None = None,
) -> str:
    """Package one or all IIS sites.

    Args:
        readiness_results_path: Path to ReadinessResults.json from discover_iis_sites.
        site_name: Specific site to package. If empty, packages all eligible sites.
        output_directory: Where to write ZIP files. Defaults to scripts/packagedsites/.
        include_sites_with_issues: Also package sites that have non-fatal failed checks.
        install_script_path: Optional path to install.ps1 to include in the package.
    """
    if ctx:
        await ctx.report_progress(0, 100)
        ctx.info(f"Packaging site{'s' if not site_name else ' ' + site_name}...")

    try:
        params: dict[str, str | bool | None] = {
            "ReadinessResultsFilePath": readiness_results_path,
            "Force": True,
        }
        if site_name:
            params["SiteName"] = site_name
        if output_directory:
            params["OutputDirectory"] = output_directory
        if include_sites_with_issues:
            params["MigrateSitesWithIssues"] = True

        run_powershell("Get-SitePackage.ps1", params, timeout_seconds=600)

        if ctx:
            await ctx.report_progress(80, 100)

        # Find the PackageResults.json output
        search_dir = output_directory if output_directory else os.path.join(SCRIPTS_DIR, "packagedsites")
        results_file = os.path.join(search_dir, "PackageResults.json")

        # Also check the scripts CWD
        if not os.path.isfile(results_file):
            results_file = os.path.join(SCRIPTS_DIR, "PackageResults.json")
        if not os.path.isfile(results_file):
            # Search more broadly
            for root, _dirs, files in os.walk(SCRIPTS_DIR):
                for f in files:
                    if f == "PackageResults.json":
                        results_file = os.path.join(root, f)
                        break

        results = read_json_file(results_file)

        output = {
            "package_results_path": results_file,
            "sites": results if isinstance(results, list) else [results],
            "install_script_included": False,
        }

        # Inject install.ps1 into each site package if provided
        if install_script_path and os.path.isfile(install_script_path):
            import zipfile
            for site_result in output["sites"]:
                pkg_path = site_result.get("SitePackagePath", "")
                if pkg_path and os.path.isfile(pkg_path):
                    with zipfile.ZipFile(pkg_path, "a") as zf:
                        zf.write(install_script_path, "install.ps1")
            output["install_script_included"] = True

        if ctx:
            await ctx.report_progress(100, 100)
            sites = output["sites"]
            packaged = sum(1 for s in sites if s.get("SitePackagePath"))
            ctx.info(f"Packaging complete: {packaged}/{len(sites)} sites packaged")

        return json.dumps(output, indent=2)

    except PsError as e:
        return e.to_json()
