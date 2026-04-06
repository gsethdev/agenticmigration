"""PowerShell subprocess executor for the IIS Migration MCP server.

Provides a shared helper to invoke the bundled PowerShell migration scripts
and return their output as parsed JSON or structured error information.
"""

import json
import os
import re
import subprocess
import tempfile
import zipfile
from dataclasses import dataclass
from urllib.request import urlopen

SCRIPTS_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "scripts")
POWERSHELL_EXE = "powershell.exe"

SCRIPTS_DOWNLOAD_URL = (
    "https://appmigration.microsoft.com/api/download/psscripts/"
    "AppServiceMigrationScripts.zip"
)

# Mutable scripts directory — set by configure_scripts_path.
_custom_scripts_dir: str | None = None

# PowerShell metacharacters that must not appear in parameter values.
_PS_DANGEROUS_CHARS = re.compile(r"[;|`$\(\){}<>]")

# Scripts expected by the migration tools.
_REQUIRED_SCRIPTS = [
    "Get-SiteReadiness.ps1",
    "Get-SitePackage.ps1",
    "Generate-MigrationSettings.ps1",
    "Invoke-SiteMigration.ps1",
    "MigrationHelperFunctions.psm1",
]


@dataclass
class PsResult:
    stdout: str
    stderr: str
    exit_code: int


class PsError(Exception):
    """Raised when a PowerShell script fails."""

    def __init__(self, error_type: str, message: str, details: str = ""):
        self.error_type = error_type
        self.message = message
        self.details = details
        super().__init__(message)

    def to_json(self) -> str:
        return json.dumps(
            {
                "error": True,
                "error_type": self.error_type,
                "message": self.message,
                "details": self.details,
            },
            indent=2,
        )


def _decode_ps_output(raw: bytes) -> str:
    """Decode raw PowerShell output, handling UTF-16 LE and UTF-8 BOMs."""
    if not raw:
        return ""
    # UTF-16 LE BOM
    if raw[:2] == b"\xff\xfe":
        return raw.decode("utf-16-le", errors="replace").lstrip("\ufeff")
    # UTF-8 BOM
    if raw[:3] == b"\xef\xbb\xbf":
        return raw[3:].decode("utf-8", errors="replace")
    # Fall back to UTF-8
    return raw.decode("utf-8", errors="replace")


def _sanitize_param_value(key: str, value: str) -> str:
    """Reject parameter values containing PowerShell injection characters."""
    if _PS_DANGEROUS_CHARS.search(value):
        raise PsError(
            "INVALID_PARAMETER",
            f"Parameter '-{key}' contains disallowed characters: {value!r}",
            "Values must not contain ; | ` $ ( ) {{ }} < > characters.",
        )
    return value


def get_scripts_dir() -> str:
    """Return the active scripts directory (custom or default)."""
    return _custom_scripts_dir or SCRIPTS_DIR


def validate_path(path: str, *, must_exist: bool = True, label: str = "path") -> str:
    """Validate a user-supplied file path against traversal attacks.

    Resolves symlinks and relative components, then checks the path is under
    an allowed directory (temp, scripts, or the workspace).

    Args:
        path: The raw user-supplied path.
        must_exist: If True, raise when the resolved path doesn't exist.
        label: Human-readable name for error messages.

    Returns:
        The resolved, normalised absolute path.

    Raises:
        PsError: If the path is empty, escapes allowed directories, or
                 (when must_exist is True) doesn't point to a real file.
    """
    if not path or not path.strip():
        raise PsError("INVALID_PATH", f"{label} cannot be empty.")

    resolved = os.path.realpath(path)

    # Allowed roots: temp dir, the active scripts dir, workspace root
    allowed_roots = [
        os.path.realpath(tempfile.gettempdir()),
        os.path.realpath(get_scripts_dir()),
        os.path.realpath(os.path.dirname(os.path.abspath(__file__))),
    ]
    # Also allow the custom scripts dir if set
    if _custom_scripts_dir:
        allowed_roots.append(os.path.realpath(_custom_scripts_dir))

    if not any(resolved.lower().startswith(root.lower()) for root in allowed_roots):
        raise PsError(
            "PATH_TRAVERSAL",
            f"{label} resolves outside allowed directories: {resolved}",
            f"Allowed roots: {allowed_roots}",
        )

    if must_exist and not os.path.exists(resolved):
        raise PsError("OUTPUT_NOT_FOUND", f"{label} not found: {resolved}")

    return resolved


def set_scripts_dir(folder_path: str) -> list[str]:
    """Validate and set a custom migration scripts directory.

    Returns a list of missing expected scripts (empty if all present).
    """
    global _custom_scripts_dir
    resolved = os.path.realpath(folder_path)
    if not os.path.isdir(resolved):
        raise PsError(
            "SCRIPT_NOT_FOUND",
            f"Scripts folder not found: {folder_path}",
            f"Resolved to: {resolved}",
        )
    _custom_scripts_dir = resolved
    missing = [s for s in _REQUIRED_SCRIPTS if not os.path.isfile(os.path.join(resolved, s))]
    return missing


def scripts_status() -> dict:
    """Return the current scripts configuration status."""
    sdir = get_scripts_dir()
    present = [s for s in _REQUIRED_SCRIPTS if os.path.isfile(os.path.join(sdir, s))]
    missing = [s for s in _REQUIRED_SCRIPTS if s not in present]
    return {
        "configured": _custom_scripts_dir is not None,
        "scripts_path": sdir,
        "required_scripts": _REQUIRED_SCRIPTS,
        "present": present,
        "missing": missing,
        "ready": len(missing) == 0,
        "download_url": SCRIPTS_DOWNLOAD_URL,
    }


def download_and_extract_scripts(target_directory: str = "") -> dict:
    """Download the migration scripts ZIP and extract to *target_directory*."""
    if not target_directory:
        target_directory = os.path.join(tempfile.gettempdir(), "iis-migration-scripts")
    os.makedirs(target_directory, exist_ok=True)

    zip_path = os.path.join(target_directory, "AppServiceMigrationScripts.zip")
    try:
        with urlopen(SCRIPTS_DOWNLOAD_URL) as resp, open(zip_path, "wb") as out:  # noqa: S310
            out.write(resp.read())
    except Exception as exc:
        raise PsError(
            "DOWNLOAD_FAILED",
            f"Failed to download migration scripts: {exc}",
            SCRIPTS_DOWNLOAD_URL,
        )

    try:
        with zipfile.ZipFile(zip_path, "r") as zf:
            zf.extractall(target_directory)
    except Exception as exc:
        raise PsError(
            "EXTRACT_FAILED",
            f"Failed to extract migration scripts: {exc}",
            zip_path,
        )

    missing = set_scripts_dir(target_directory)
    return {
        "downloaded": True,
        "extracted_to": target_directory,
        "missing_scripts": missing,
        "ready": len(missing) == 0,
    }


def run_powershell(
    script_name: str,
    params: dict[str, str | bool | None] | None = None,
    timeout_seconds: int = 300,
) -> PsResult:
    """Execute a bundled PowerShell script and return the result.

    Args:
        script_name: Name of the script file in the scripts/ directory.
        params: Dictionary of parameter names to values. Bool True adds a
                switch flag, None values are skipped.
        timeout_seconds: Maximum execution time (default 5 minutes).

    Returns:
        PsResult with stdout, stderr, and exit_code.

    Raises:
        PsError: On script failure with a categorised error type.
    """
    script_path = os.path.join(get_scripts_dir(), script_name)
    if not os.path.isfile(script_path):
        raise PsError(
            "SCRIPT_NOT_FOUND",
            f"Script not found: {script_name}",
            f"Expected at: {script_path}",
        )

    args = [
        POWERSHELL_EXE,
        "-NoProfile",
        "-NonInteractive",
        "-ExecutionPolicy",
        "Bypass",   # Required: migration scripts are unsigned
        "-File",
        script_path,
    ]

    for key, value in (params or {}).items():
        if value is None:
            continue
        if isinstance(value, bool):
            if value:
                args.append(f"-{key}")
        else:
            _sanitize_param_value(key, str(value))
            args.append(f"-{key}")
            args.append(str(value))

    try:
        result = subprocess.run(
            args,
            capture_output=True,
            timeout=timeout_seconds,
            cwd=get_scripts_dir(),
        )
    except FileNotFoundError:
        raise PsError(
            "POWERSHELL_NOT_FOUND",
            "powershell.exe not found. Ensure Windows PowerShell 5.1 is installed.",
        )
    except subprocess.TimeoutExpired:
        raise PsError(
            "SCRIPT_TIMEOUT",
            f"Script timed out after {timeout_seconds} seconds: {script_name}",
        )

    # PowerShell 5.1 may emit UTF-16 LE (BOM FF FE) or UTF-8 (BOM EF BB BF).
    # Detect and decode accordingly.
    stdout_text = _decode_ps_output(result.stdout)
    stderr_text = _decode_ps_output(result.stderr)

    ps_result = PsResult(
        stdout=stdout_text, stderr=stderr_text, exit_code=result.returncode
    )

    if result.returncode != 0:
        stderr_lower = stderr_text.lower() if stderr_text else ""
        if "requires -runasadministrator" in stderr_lower or "administrator" in stderr_lower:
            raise PsError(
                "ELEVATION_REQUIRED",
                "This operation requires Administrator privileges. Run VS Code (or your terminal) as Administrator.",
                stderr_text.strip(),
            )
        if "webadministration" in stderr_lower or "servermanager" in stderr_lower:
            raise PsError(
                "IIS_NOT_FOUND",
                "IIS is not installed or the WebAdministration module is not available on this machine.",
                stderr_text.strip(),
            )
        if "connect-azaccount" in stderr_lower or "login-azaccount" in stderr_lower:
            raise PsError(
                "AZURE_NOT_AUTHENTICATED",
                "Azure PowerShell is not authenticated. Run Connect-AzAccount first.",
                stderr_text.strip(),
            )
        raise PsError(
            "SCRIPT_ERROR",
            f"PowerShell script failed with exit code {result.returncode}: {script_name}",
            stderr_text.strip(),
        )

    return ps_result


def read_json_file(path: str) -> dict | list:
    """Read and parse a JSON file produced by a PowerShell script."""
    validated = validate_path(path, must_exist=True, label="JSON file")
    # PowerShell 5.1 may write JSON in UTF-16 LE; detect BOM and decode accordingly.
    with open(validated, "rb") as f:
        raw = f.read()
    if raw[:2] == b"\xff\xfe":
        text = raw.decode("utf-16-le").lstrip("\ufeff")
    elif raw[:3] == b"\xef\xbb\xbf":
        text = raw[3:].decode("utf-8")
    else:
        text = raw.decode("utf-8")
    return json.loads(text)
