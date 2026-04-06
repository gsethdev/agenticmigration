"""configure_scripts_path - Set the path to the downloaded migration scripts."""

import json

from tools import server
from ps_runner import (
    SCRIPTS_DOWNLOAD_URL,
    set_scripts_dir,
    scripts_status,
    download_and_extract_scripts,
    PsError,
    validate_path,
)


@server.tool(
    name="configure_scripts_path",
    description=(
        "Configure the path to the downloaded App Service Migration PowerShell scripts. "
        "MUST be called before any discovery, packaging, or migration tool. "
        "The user should download the scripts from:\n"
        f"  {SCRIPTS_DOWNLOAD_URL}\n"
        "Then unzip and provide the folder path to this tool."
    ),
)
async def configure_scripts_path(scripts_folder_path: str) -> str:
    """Validate and set the migration scripts directory.

    Args:
        scripts_folder_path: Path to the unzipped AppServiceMigrationScripts folder.
    """
    try:
        missing = set_scripts_dir(scripts_folder_path)
        if missing:
            return json.dumps(
                {
                    "configured": True,
                    "scripts_path": scripts_folder_path,
                    "warning": f"Some expected scripts are missing: {', '.join(missing)}. "
                    "The folder may have a different version or structure. "
                    "Tools that depend on these scripts may fail.",
                },
                indent=2,
            )
        return json.dumps(
            {
                "configured": True,
                "scripts_path": scripts_folder_path,
                "message": "All required migration scripts found. Ready to proceed.",
            },
            indent=2,
        )
    except PsError as e:
        return e.to_json()


@server.tool(
    name="download_migration_scripts",
    description=(
        "Download and extract the App Service Migration PowerShell scripts automatically. "
        "Downloads from:\n"
        f"  {SCRIPTS_DOWNLOAD_URL}\n"
        "Extracts to the specified directory (or a temp folder) and configures the path. "
        "After this, all discovery/assessment/packaging/migration tools are ready to use."
    ),
)
async def download_migration_scripts(target_directory: str = "") -> str:
    """Download, extract, and configure migration scripts.

    Args:
        target_directory: Where to extract the scripts. Defaults to a temp folder.
    """
    result = download_and_extract_scripts(target_directory)
    return json.dumps(result, indent=2)


@server.tool(
    name="check_scripts_status",
    description=(
        "Check whether the migration PowerShell scripts are configured and available. "
        "Returns the current status: path, whether all required scripts are present, "
        "and instructions if scripts need to be downloaded or configured."
    ),
)
async def check_scripts_status() -> str:
    """Return the current status of migration scripts configuration."""
    return json.dumps(scripts_status(), indent=2)
