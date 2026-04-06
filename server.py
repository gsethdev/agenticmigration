#!/usr/bin/env python3
"""IIS Migration MCP Server — entry point.

Exposes PowerShell-based IIS migration scripts as MCP tools for
GitHub Copilot (and any MCP-compatible client) via stdio transport.

Usage:
    python server.py

VS Code integration (.vscode/mcp.json):
    {
        "servers": {
            "iis-migration": {
                "command": "python",
                "args": ["server.py"],
                "cwd": "${workspaceFolder}"
            }
        }
    }
"""

# Import the shared server instance, then import each tool module
# so the @server.tool() decorators register the tools.
from tools import server

import tools.discover
import tools.assess
import tools.package
import tools.generate_settings
import tools.migrate
import tools.suggest
import tools.assessment_router
import tools.assess_source
import tools.recommend
import tools.install_script
import tools.generate_adapter_arm
import tools.plan_deployment
import tools.confirm_migration
import tools.configure


def main() -> None:
    server.run(transport="stdio")


if __name__ == "__main__":
    main()
