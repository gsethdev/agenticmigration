"""PowerShell subprocess executor for the IIS Migration MCP server.

Provides a shared helper to invoke the bundled PowerShell migration scripts
and return their output as parsed JSON or structured error information.
"""

import json
import os
import subprocess
from dataclasses import dataclass

SCRIPTS_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "scripts")
POWERSHELL_EXE = "powershell.exe"


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
    script_path = os.path.join(SCRIPTS_DIR, script_name)
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
        "Bypass",
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
            args.append(f"-{key}")
            args.append(str(value))

    try:
        result = subprocess.run(
            args,
            capture_output=True,
            timeout=timeout_seconds,
            cwd=SCRIPTS_DIR,
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
    if not os.path.isfile(path):
        raise PsError("OUTPUT_NOT_FOUND", f"Expected output file not found: {path}")
    # PowerShell 5.1 may write JSON in UTF-16 LE; detect BOM and decode accordingly.
    with open(path, "rb") as f:
        raw = f.read()
    if raw[:2] == b"\xff\xfe":
        text = raw.decode("utf-16-le").lstrip("\ufeff")
    elif raw[:3] == b"\xef\xbb\xbf":
        text = raw[3:].decode("utf-8")
    else:
        text = raw.decode("utf-8")
    return json.loads(text)
