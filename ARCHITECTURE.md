# IIS Migration MCP Server — Architecture

A comprehensive guide to the IIS-to-Azure App Service migration system.
This document covers every component, the end-to-end pipeline, agent orchestration,
data flow, and the critical MI (Managed Instance) constraints.

---

## Table of Contents

- [End-to-End System Map](#end-to-end-system-map) ← start here for the full picture
1. [System Overview](#1-system-overview)
2. [Component Inventory](#2-component-inventory)
3. [6-Phase Pipeline Flow](#3-6-phase-pipeline-flow)
4. [Agent Orchestration](#4-agent-orchestration)
5. [Data Flow & Artifacts](#5-data-flow--artifacts)
6. [MI Provisioning Split](#6-mi-provisioning-split)
7. [Prerequisites & Setup](#7-prerequisites--setup)
8. [MI Constraints & Rules](#8-mi-constraints--rules)

---

## End-to-End System Map

A single diagram showing every component, tool, script, agent, and artifact —
from user interaction through to Azure deployment. Readable in any text editor.

```
╔══════════════════════════════════════════════════════════════════════════════════════════════════╗
║                                    DEVELOPER  (VS Code)                                        ║
║                                         │                                                      ║
║                                    @iis-migrate                                                ║
║                                         │                                                      ║
║  ┌──────────────────────────────────────┼──────────────────────────────────────────┐            ║
║  │           VS CODE COPILOT AGENTS (.github/agents/)                             │            ║
║  │                                      │                                         │            ║
║  │                         ┌────────────┤ iis-migrate (Orchestrator)              │            ║
║  │                         │            │            │            │                │            ║
║  │                    Phase 1      Phase 2      Phase 3     Phase 4    Phase 5    │            ║
║  │                         │            │            │            │         │      │            ║
║  │                   iis-discover  iis-assess  iis-recommend  iis-deploy  iis-    │            ║
║  │                                                             -plan     execute  │            ║
║  └─────────────────────────┬────────────┬────────────┬───────────┬─────────┬──────┘            ║
║                            │            │            │           │         │                    ║
║  ══════════════════════════╪════════════╪════════════╪═══════════╪═════════╪══════════════════  ║
║                     stdio JSON-RPC (MCP Transport)                                             ║
║  ══════════════════════════╪════════════╪════════════╪═══════════╪═════════╪══════════════════  ║
║                            │            │            │           │         │                    ║
║  ┌─────────────────────────┴────────────┴────────────┴───────────┴─────────┴──────────────────┐ ║
║  │                       FastMCP SERVER  (server.py)                                         │ ║
║  │                                                                                           │ ║
║  │  ┌─ Phase 1 ──────────┐ ┌─ Phase 2 ──────────┐ ┌─ Phase 3 ──────────────────────────┐   │ ║
║  │  │ discover_iis_sites  │ │ assess_site_       │ │ suggest_migration_approach          │   │ ║
║  │  │ choose_assessment_  │ │   readiness        │ │ recommend_target                    │   │ ║
║  │  │   mode              │ │ assess_source_code │ │ generate_install_script             │   │ ║
║  │  │                     │ │                    │ │ generate_adapter_arm_template        │   │ ║
║  │  └────────┬────────────┘ └────────────────────┘ └─────────────┬──────────┬────────────┘   │ ║
║  │           │                                                   │          │                 │ ║
║  │  ┌─ Phase 4 ──────────────────┐  ┌─ Phase 5 ──────────────────────────────────┐          │ ║
║  │  │ plan_deployment             │  │ confirm_migration ──(HUMAN GATE)──> User   │          │ ║
║  │  │ package_site                │  │ migrate_sites                              │          │ ║
║  │  │ generate_migration_settings │  │                                            │          │ ║
║  │  └──────────┬──────────────────┘  └───────────────────────────┬────────────────┘          │ ║
║  │             │                                                 │                            │ ║
║  │  ┌──────────┴─────────────────────────────────────────────────┴───────────────────┐       │ ║
║  │  │                    ps_runner.py  (Python-to-PowerShell bridge)                  │       │ ║
║  │  │                    Auto-detects UTF-16 LE BOM / UTF-8 BOM encoding             │       │ ║
║  │  └──────────┬─────────────┬──────────────┬──────────────┬─────────────┬───────────┘       │ ║
║  └─────────────┼─────────────┼──────────────┼──────────────┼─────────────┼───────────────────┘ ║
║                │             │              │              │             │                      ║
║  ┌─────────────┴─────────────┴──────────────┴──────────────┴─────────────┴───────────────────┐ ║
║  │            POWERSHELL SCRIPTS  (downloaded from Microsoft, path set at runtime)            │ ║
║  │                                                                                           │ ║
║  │  IISDiscovery.ps1          Get-SitePackage.ps1         Invoke-SiteMigration.ps1           │ ║
║  │  Get-SiteReadiness.ps1     Generate-MigrationSettings  Get-MIAppServicePlan.ps1           │ ║
║  │  IISMigration.ps1          MigrationHelperFunctions.psm1                                  │ ║
║  └───────┬──────────────────────────┬────────────────────────────────┬────────────────────────┘ ║
║          │                          │                                │                          ║
║          ▼                          ▼                                ▼                          ║
║  ┌───────────────┐   ┌──────────────────────────┐   ┌──────────────────────────────────────┐   ║
║  │   LOCAL IIS   │   │       AppCat CLI          │   │            AZURE                     │   ║
║  │               │   │  (source code analysis)   │   │                                      │   ║
║  │  Web Sites    │   │                           │   │  ARM API ─┬─ App Service Plans+Apps  │   ║
║  │  App Pools    │   │  appcat analyze ...        │   │           ├─ Key Vault (secrets)     │   ║
║  │  Web.config   │   │    --non-interactive      │   │           └─ Storage Accounts        │   ║
║  └───────────────┘   └──────────────────────────┘   └──────────────────────────────────────┘   ║
║                                                                                                ║
║  ┌──────────────────────────── ARTIFACTS  (%TEMP%\iis-migration\) ─────────────────────────┐   ║
║  │                                                                                         │   ║
║  │  Phase 1 output:    ReadinessResults.json  (UTF-16 LE)                                  │   ║
║  │  Phase 3 outputs:   install.ps1   |   mi-adapters-template.json                         │   ║
║  │  Phase 4 outputs:   PackageResults.json (UTF-16 LE)  |  site ZIPs  |  MigrationSettings │   ║
║  │  Phase 5 output:    MigrationResults.json                                               │   ║
║  └─────────────────────────────────────────────────────────────────────────────────────────┘   ║
╚══════════════════════════════════════════════════════════════════════════════════════════════════╝
```

---

## 1. System Overview

The system is a **Model Context Protocol (MCP) server** that exposes
IIS migration capabilities as tools callable by VS Code Copilot agents.
It bridges Python business logic, PowerShell IIS/Azure scripts, and
external CLIs into a unified, agent-driven migration workflow.

```
                          ┌─────────────────────────────────────────┐
                          │          SYSTEM CONTEXT                 │
                          └─────────────────┬───────────────────────┘
                                            │
         ┌──────────────────────────────────┼──────────────────────────────────┐
         │                                  │                                  │
         ▼                                  ▼                                  ▼
┌─────────────────┐            ┌──────────────────────┐           ┌────────────────────┐
│  DEVELOPER      │            │   VS CODE            │           │  EXTERNAL SYSTEMS  │
│  (User)         │───────────>│                      │           │                    │
│                 │  Copilot   │  6 Custom Agents     │           │  Local IIS         │
│  Runs migration │  Chat      │  (.agent.md files)   │           │  Azure (ARM, App   │
│  from VS Code   │            │         │            │           │    Service, KV,    │
└─────────────────┘            │         ▼            │           │    Storage)        │
                               │  MCP Client (stdio)  │           │  AppCat CLI        │
                               └──────────┬───────────┘           └─────────┬──────────┘
                                          │                                 │
                                   stdio JSON-RPC                           │
                                          │                                 │
                               ┌──────────┴───────────┐                    │
                               │  MCP SERVER PROCESS   │                    │
                               │                       │                    │
                               │  server.py (FastMCP)  │                    │
                               │     │                 │                    │
                               │  13 Tool Modules      │                    │
                               │  (tools/*.py)         │                    │
                               │     │                 │                    │
                               │  ps_runner.py         │────────────────────┘
                               │  (Python→PS bridge)   │     subprocess calls
                               │                       │     to downloaded *.ps1
                               └──────────────────────┘
```

### Layered Architecture

```
┌──────────────────────────────────────────────────────────┐
│  VS Code + Copilot Agents  (.github/agents/*.agent.md)  │  User interface
├──────────────────────────────────────────────────────────┤
│  MCP Transport  (stdio JSON-RPC)                        │  Protocol layer
├──────────────────────────────────────────────────────────┤
│  FastMCP Server  (server.py)                            │  Routing
├──────────────────────────────────────────────────────────┤
│  Python Tool Modules  (tools/*.py)   ← 13 tools        │  Business logic
├──────────────────────────────────────────────────────────┤
│  ps_runner.py           ← UTF-16 LE / UTF-8 decoding   │  Python ↔ PS bridge
├──────────────────────────────────────────────────────────┤
│  PowerShell Scripts  (downloaded, user-configured path) │  IIS & Azure operations
├──────────────────────────────────────────────────────────┤
│  IIS  │  Azure (ARM / App Service / KV / Storage)       │  External systems
└──────────────────────────────────────────────────────────┘
```

---

## 2. Component Inventory

### 2.1 MCP Tools (13)

| # | Phase | Tool Name | Type | Description | PS Script |
|---|-------|-----------|------|-------------|-----------|
| 1 | Discovery | `discover_iis_sites` | PS | Scan local IIS, run readiness checks, save ReadinessResults.json | IISDiscovery.ps1 |
| 2 | Discovery | `choose_assessment_mode` | Python | Route sites to config-only, config+source, or skip-to-packaging | — |
| 3 | Assessment | `assess_site_readiness` | Python | Detailed per-site readiness from ReadinessResults.json with remediation links | — |
| 4 | Assessment | `assess_source_code` | Python | Parse AppCat JSON report for MI-relevant findings; splits adapter vs install features | — |
| 5 | Recommendation | `suggest_migration_approach` | Python | Route to IIS Migration MCP (binaries) vs App Modernization MCP (source code) | — |
| 6 | Recommendation | `recommend_target` | Python | MI on App Service (PV4) vs standard App Service vs Container Apps | — |
| 7 | Recommendation | `generate_install_script` | Python | Create install.ps1 for OS-level features (SMTP, MSMQ, COM, fonts, Crystal Reports) | — |
| 8 | Recommendation | `generate_adapter_arm_template` | Python | ARM template for registry adapters (→ Key Vault) and storage adapters | — |
| 9 | Deployment | `plan_deployment` | Python | Plan App Service Plans; enforce PV4 + IsCustomMode for MI; query existing plans | Get-MIAppServicePlan.ps1 |
| 10 | Deployment | `package_site` | PS | ZIP site content from IIS physical path; optionally inject install.ps1 | Get-SitePackage.ps1 |
| 11 | Deployment | `generate_migration_settings` | PS | Build MigrationSettings.json from PackageResults.json | Generate-MigrationSettings.ps1 |
| 12 | Execution | `confirm_migration` | Python | Present human-readable summary; require explicit confirmation before deploy | — |
| 13 | Execution | `migrate_sites` | PS | Deploy ZIPs to Azure App Service; create billable resources | Invoke-SiteMigration.ps1 |

### 2.2 VS Code Custom Agents (6)

| Agent | Role | Tool Scope |
|-------|------|------------|
| **iis-migrate** | Orchestrator — delegates to subagents per phase | All 13 tools |
| **iis-discover** | Discovery & readiness scanning | `discover_iis_sites`, `choose_assessment_mode`, `assess_site_readiness` |
| **iis-assess** | Config + source assessment | `assess_site_readiness`, `assess_source_code` |
| **iis-recommend** | Target recommendation & provisioning artifact generation | `recommend_target`, `generate_install_script`, `generate_adapter_arm_template` |
| **iis-deploy-plan** | Packaging & MigrationSettings creation | `plan_deployment`, `package_site`, `generate_migration_settings` |
| **iis-execute** | Final confirmation & deployment (human gate) | `confirm_migration`, `migrate_sites` |

### 2.3 PowerShell Scripts (7) — Downloaded from Microsoft

> **These scripts are NOT included in this repository.** Users must download them from
> [Microsoft](https://appmigration.microsoft.com/api/download/psscripts/AppServiceMigrationScripts.zip)
> and configure the path using `configure_scripts_path` or `download_migration_scripts`.

| Script | Purpose | Requires Admin | Requires Azure |
|--------|---------|:-:|:-:|
| IISDiscovery.ps1 | Enumerate IIS sites, run 15 readiness checks | Yes | No |
| Get-SiteReadiness.ps1 | Compile assessment data; supports remote servers | Yes | No |
| Get-SitePackage.ps1 | Package sites into ZIPs; produce PackageResults.json | Yes | No |
| Generate-MigrationSettings.ps1 | Build MigrationSettings.json from packages | No | No |
| Invoke-SiteMigration.ps1 | Deploy to Azure App Service, create resources | No | Yes |
| IISMigration.ps1 | Main packaging/migration entry point | Yes | Varies |
| MigrationHelperFunctions.psm1 | Shared utility functions (imported by other scripts) | — | — |

### 2.4 Supporting Files

| File | Purpose |
|------|---------|
| `server.py` | FastMCP entry point — imports all tool modules, starts stdio transport |
| `ps_runner.py` | Python→PowerShell bridge — subprocess exec, UTF-16 LE/UTF-8 BOM decode, error categorization |
| `tools/__init__.py` | Shared `FastMCP` server instance |
| `requirements.txt` | `mcp[cli]>=1.0.0` |
| `ScriptConfig.json` | PowerShell configuration (included in downloaded scripts) |
| `TemplateMigrationSettings.json` | MigrationSettings.json template (included in downloaded scripts) |
| `WebAppCheckResources.resx` | Readiness check descriptions (included in downloaded scripts) |

---

## 3. 6-Phase Pipeline Flow

```
  PHASE 1: DISCOVERY          PHASE 2: ASSESSMENT         PHASE 3: RECOMMENDATION
 ┌──────────────────────┐    ┌──────────────────────┐    ┌──────────────────────────────┐
 │ discover_iis_sites   │    │ assess_site_readiness │    │ suggest_migration_approach   │
 │        │             │    │                       │    │         │                    │
 │        ▼             │    │ assess_source_code    │    │ recommend_target             │
 │ choose_assessment_   │    │ (needs AppCat JSON)   │    │    │              │          │
 │   mode               │    │                       │    │    ▼ (if MI)     ▼ (if std) │
 └────────┬─────────────┘    └───────────┬───────────┘    │ generate_     skip to       │
          │                              │                │  install_     Phase 4        │
          │  ReadinessResults.json       │                │  script                      │
          ▼                              ▼                │ generate_adapter_            │
   ┌──────────┐                   ┌──────────┐           │  arm_template                │
   │config    │                   │config +  │           └──────────┬──┬────────────────┘
   │only?     │                   │source?   │                      │  │
   └──────┬───┘                   └────┬─────┘             install  │  │ ARM
          │                            │                   .ps1     │  │ template
          ▼                            ▼                            │  │
 ═══════════════════════════════════════════════════════════════════╪══╪═════════
                                                                    │  │
  PHASE 4: DEPLOYMENT PLANNING       PHASE 5: EXECUTION            │  │
 ┌─────────────────────────────┐    ┌─────────────────────────┐    │  │
 │ plan_deployment        <────┼────┼──────────────────────── │ ───┘  │
 │       │                     │    │                         │       │
 │       ▼                     │    │                         │  <────┘
 │ package_site                │    │ confirm_migration       │
 │       │                     │    │       │                 │
 │       ▼  PackageResults     │    │   [HUMAN GATE]         │
 │ generate_migration_settings │    │   User must confirm     │
 │       │                     │    │       │                 │
 │       ▼  MigrationSettings  │    │       ▼                │
 └───────┼─────────────────────┘    │ migrate_sites ──> Azure│
         │                          │       │                 │
         └─────────────────────────>│       ▼                │
                                    │ MigrationResults.json  │
                                    └─────────────────────────┘
```

### Phase Details

| Phase | Gate | Key Artifacts Produced |
|-------|------|----------------------|
| 1. Discovery | Admin + IIS required | `ReadinessResults.json` |
| 2. Assessment | AppCat CLI for source mode | Enriched assessment per site |
| 3. Recommendation | Source assessment for MI features | `install.ps1`, `mi-adapters-template.json` |
| 4. Deployment Planning | Azure login for existing plan query | `PackageResults.json`, `MigrationSettings.json` |
| 5. Execution | Explicit human confirmation | `MigrationResults.json` |

---

## 4. Agent Orchestration

The `iis-migrate` orchestrator delegates to specialized subagents,
each scoped to a subset of tools. This enforces workflow phases and
prevents agents from calling tools outside their responsibility.

```
                              ┌─────────────────────────────────┐
                              │        DEVELOPER (User)         │
                              │         @iis-migrate            │
                              └───────────────┬─────────────────┘
                                              │
                              ┌───────────────┴─────────────────┐
                              │     iis-migrate (Orchestrator)  │
                              │        All 13 tools access      │
                              └──┬──────┬──────┬──────┬──────┬──┘
                                 │      │      │      │      │
                 ┌───────────────┘      │      │      │      └───────────────┐
                 │              ┌───────┘      │      └───────┐              │
                 ▼              ▼              ▼              ▼              ▼
  ┌──────────────────┐ ┌───────────────┐ ┌──────────────┐ ┌──────────────┐ ┌──────────────┐
  │   iis-discover   │ │  iis-assess   │ │ iis-recommend│ │iis-deploy-   │ │ iis-execute   │
  │   Phase 1        │ │  Phase 2      │ │ Phase 3      │ │  plan        │ │ Phase 5       │
  ├──────────────────┤ ├───────────────┤ ├──────────────┤ │Phase 4       │ ├──────────────┤
  │ discover_iis_    │ │ assess_site_  │ │ recommend_   │ ├──────────────┤ │ confirm_     │
  │   sites          │ │   readiness   │ │   target     │ │ plan_        │ │   migration  │
  │ choose_          │ │ assess_source_│ │ generate_    │ │   deployment │ │ migrate_sites│
  │   assessment_    │ │   code        │ │   install_   │ │ package_site │ │              │
  │   mode           │ │               │ │   script     │ │ generate_    │ │  !! HUMAN    │
  │ assess_site_     │ │               │ │ generate_    │ │   migration_ │ │  !! GATE     │
  │   readiness      │ │               │ │   adapter_   │ │   settings   │ │  !! REQUIRED │
  │                  │ │               │ │   arm_tpl    │ │              │ │              │
  └──────────────────┘ └───────────────┘ └──────────────┘ └──────────────┘ └──────────────┘
```

### Agent Handoff Rules

1. **iis-migrate** never calls tools directly for migration — it delegates to the appropriate subagent.
2. Each subagent has a **fixed tool scope** enforced by the `.agent.md` `tools:` frontmatter.
3. **iis-execute** requires explicit user confirmation via `confirm_migration` before `migrate_sites` can run.
4. Agents can access read/search tools for context gathering alongside their migration-specific tools.

---

## 5. Data Flow & Artifacts

```
  LOCAL IIS            MCP SERVER              FILE SYSTEM                  AppCat CLI        AZURE
     │                     │                 (%TEMP%\iis-migration\)            │               │
     │                     │                        │                          │               │
     │  ── Phase 1: Discovery ──────────────────────│──────────────────────────│───────────────│──
     │                     │                        │                          │               │
     │<──discover_iis_sites│                        │                          │               │
     │   (Admin + IIS)     │                        │                          │               │
     │────site list───────>│                        │                          │               │
     │                     │──ReadinessResults.json─>                          │               │
     │                     │                        │                          │               │
     │  ── Phase 2: Assessment ─────────────────────│──────────────────────────│───────────────│──
     │                     │                        │                          │               │
     │                     │<─assess_site_readiness─│                          │               │
     │                     │  (reads Readiness JSON) │                          │               │
     │                     │                        │     appcat analyze ...   │               │
     │                     │                        │<──appcat-report.json─────│               │
     │                     │<──assess_source_code───│                          │               │
     │                     │   (parses AppCat JSON)  │                          │               │
     │                     │                        │                          │               │
     │  ── Phase 3: Recommendation ─────────────────│──────────────────────────│───────────────│──
     │                     │                        │                          │               │
     │                     │──recommend_target──>   │                          │               │
     │                     │   (MI or Standard?)    │                          │               │
     │                     │──install.ps1──────────>│                          │               │
     │                     │──mi-adapters-template─>│                          │               │
     │                     │                        │                          │               │
     │  ── Phase 4: Deployment Planning ────────────│──────────────────────────│───────────────│──
     │                     │                        │                          │               │
     │<──package_site──────│                        │                          │               │
     │───ZIP content──────>│                        │                          │               │
     │                     │──PackageResults.json──>│                          │               │
     │                     │──site ZIPs────────────>│                          │               │
     │                     │──MigrationSettings───->│                          │               │
     │                     │                        │                          │               │
     │  ── Phase 5: Execution ──────────────────────│──────────────────────────│───────────────│──
     │                     │                        │                          │               │
     │                     │──confirm_migration────>│ DEVELOPER                │               │
     │                     │   [STOP: User must     │  must type               │               │
     │                     │    confirm to proceed] │  "yes" / "confirm"       │               │
     │                     │                        │                          │               │
     │                     │──migrate_sites─────────│──────────────────────────│──────────────>│
     │                     │                        │                          │   ARM deploy  │
     │                     │                        │                          │   App Service │
     │                     │<──MigrationResults─────│──────────────────────────│<──────────────│
     │                     │                        │                          │               │
```

### Artifact Chain

```
ReadinessResults.json
  ├── assess_site_readiness (enriched per-site details)
  ├── assess_source_code (adapter_features + install_script_features)
  │     ├── generate_adapter_arm_template → mi-adapters-template.json
  │     └── generate_install_script → install.ps1
  ├── package_site → PackageResults.json + *.zip
  │     └── generate_migration_settings → MigrationSettings.json
  │           └── confirm_migration → migrate_sites → MigrationResults.json
```

### Key File Locations

All artifacts are written to `%TEMP%\iis-migration\`:

| Artifact | Path | Encoding |
|----------|------|----------|
| ReadinessResults.json | `%TEMP%\iis-migration\ReadinessResults.json` | UTF-16 LE |
| PackageResults.json | `%TEMP%\iis-migration\PackageResults.json` | UTF-16 LE |
| MigrationSettings.json | `%TEMP%\iis-migration\MigrationSettings.json` | UTF-8 |
| Site ZIP packages | `%TEMP%\iis-migration\PackagedSites\<SiteName>.zip` | Binary |
| MI ARM template | `%TEMP%\iis-migration\<plan-name>\mi-adapters-template.json` | UTF-8 |
| Install scripts | `%TEMP%\iis-migration\<SiteName>\install.ps1` | UTF-8 |

> **Encoding note:** PowerShell 5.1 outputs UTF-16 LE with BOM (`FF FE`).
> `ps_runner.py` auto-detects and decodes both UTF-16 LE and UTF-8 BOM transparently.

---

## 6. MI Provisioning Split

Managed Instance on App Service has two distinct dependency tracks.
The system separates them because they have different provisioning
mechanisms — one uses Azure platform features (ARM API), the other
uses OS-level installation during site startup.

```
                        ┌─────────────────────────┐
                        │    assess_source_code    │
                        │  (parses AppCat JSON)    │
                        └─────┬───────────┬────────┘
                              │           │
                   adapter_features    install_script_features
                              │           │
              ┌───────────────┘           └───────────────┐
              ▼                                           ▼
┌──────────────────────────────────┐    ┌──────────────────────────────────┐
│   ADAPTER TRACK (ARM Template)   │    │   INSTALL SCRIPT TRACK (.ps1)    │
│   Platform-level, no app changes │    │   OS-level, runs at MI startup   │
│                                  │    │                                  │
│  ┌────────────────────────────┐  │    │  ┌────────────────────────────┐  │
│  │ Registry Adapters          │  │    │  │ SMTP Server               │  │
│  │   Registry key → KV secret │  │    │  │   Install-WindowsFeature  │  │
│  └────────────────────────────┘  │    │  └────────────────────────────┘  │
│  ┌────────────────────────────┐  │    │  ┌────────────────────────────┐  │
│  │ Storage Adapters           │  │    │  │ MSMQ Client               │  │
│  │   AzureFiles (SMB share)   │  │    │  │   Install-WindowsFeature  │  │
│  │   Custom (VNET endpoint)   │  │    │  └────────────────────────────┘  │
│  │   LocalStorage (local SSD) │  │    │  ┌────────────────────────────┐  │
│  └────────────────────────────┘  │    │  │ COM/MSI Components        │  │
│                                  │    │  │   regsvr32 /s <dll>       │  │
│         │                        │    │  └────────────────────────────┘  │
│         ▼                        │    │  ┌────────────────────────────┐  │
│  generate_adapter_arm_template   │    │  │ Custom Fonts              │  │
│         │                        │    │  └────────────────────────────┘  │
│         ▼                        │    │  ┌────────────────────────────┐  │
│  mi-adapters-template.json       │    │  │ Crystal Reports Runtime   │  │
│                                  │    │  └────────────────────────────┘  │
│         │                        │    │                                  │
│         ▼                        │    │         │                        │
│  Deploy via:                     │    │         ▼                        │
│    az deployment group create    │    │  generate_install_script         │
│    or Azure Portal               │    │         │                        │
│                                  │    │         ▼                        │
└──────────────┬───────────────────┘    │  install.ps1                     │
               │                        │         │                        │
               │                        └─────────┼────────────────────────┘
               │                                  │
               ▼                                  ▼
         plan_deployment                   package_site
         (ARM plan config)                 (inject install.ps1 into ZIP)
               │                                  │
               └──────────────┬───────────────────┘
                              ▼
                    MigrationSettings.json
```

### Feature Classification Rules

| Source Assessment Rule | Feature | Track | Provisioning |
|----------------------|---------|-------|-------------|
| Local.0001 (Registry access) | Registry | Adapter | ARM template → Key Vault secret mapping |
| Local.0003/0004 (File I/O) | Storage | Adapter | ARM template → Azure Files / LocalStorage mount |
| SMTP.0001 | SMTP | Install Script | `Install-WindowsFeature Web-SMTP-Service` |
| Identity.0001+ (MSMQ) | MSMQ | Install Script | `Install-WindowsFeature MSMQ-Client` |
| COM interop detected | Component | Install Script | `regsvr32 /s <dll>` |
| Custom fonts detected | Font | Install Script | `Install-Font` |
| Crystal Reports refs | CrystalReports | Install Script | Crystal runtime installer |

### Why Two Tracks?

- **Adapters** are Azure platform features configured via ARM API (`Microsoft.Web/serverfarms` properties). They map local resources (registry keys, file paths) to cloud equivalents (Key Vault secrets, Azure File shares) without modifying the application.
- **Install scripts** run during MI site startup to install Windows components that have no platform adapter equivalent. They execute `Install-WindowsFeature` and similar OS-level commands inside the MI sandbox.

---

## 7. Prerequisites & Setup

### Dependencies

| Dependency | Version | Purpose | Required For |
|-----------|---------|---------|-------------|
| Python | 3.10+ | MCP server runtime | All |
| `mcp[cli]` | ≥ 1.0.0 | FastMCP framework | All |
| Windows PowerShell | 5.1 | IIS & Azure script execution | Discovery, packaging, migration |
| IIS (WebAdministration module) | — | Local site enumeration | Discovery |
| Azure PowerShell (Az module) | — | Azure resource deployment | Migration, plan query |
| AppCat CLI (`appcat`) | ≥ 1.0.878 | Source code analysis | Source assessment |
| VS Code + GitHub Copilot | — | Agent UI | Agent orchestration |
| Administrator privileges | — | IIS access | Discovery, packaging |

### Environment Setup

```bash
# 1. Install Python dependencies
pip install -r requirements.txt

# 2. Start the MCP server (manual)
python server.py
```

### VS Code MCP Registration

Add to `.vscode/mcp.json` in your workspace:

```json
{
    "servers": {
        "iis-migration": {
            "command": "python",
            "args": ["server.py"],
            "cwd": "G:\\My Drive\\AILearning\\Migration"
        }
    }
}
```

### Agent Registration

The 6 agent files in `.github/agents/` are automatically discovered by
VS Code when the Copilot Chat extension is installed. No additional
configuration is needed — open the workspace and invoke `@iis-migrate`.

### AppCat CLI Setup

AppCat is invoked **externally** (not through the MCP server). The
`assess_source_code` tool parses pre-generated AppCat JSON reports.

```powershell
# Install AppCat as a .NET global tool
dotnet tool install --global Microsoft.AppCat.CLI

# Run analysis (example)
appcat analyze "path\to\project.csproj" `
    --source Solution `
    --target AppService.Windows `
    --serializer json `
    --report "path\to\output.json" `
    --code `
    --privacyMode Unrestricted `
    --non-interactive
```

> **Important flags:** `--non-interactive` (avoids Spectre.Console handle errors),
> `--report` (not `--output`), `--privacyMode Unrestricted` (includes code snippets).

---

## 8. MI Constraints & Rules

These constraints are the #1 source of deployment errors.
Every component in the system enforces them.

### Hard Requirements

| Constraint | Value | Enforced By |
|-----------|-------|-------------|
| App Service Plan SKU | **PV4 only** | `plan_deployment`, `generate_adapter_arm_template` |
| IsCustomMode | **true** | `plan_deployment`, ARM template |
| Custom container | Not supported | Site runs natively in MI sandbox |

### RBAC Roles Required

| Role | Scope | Assigned To | Purpose |
|------|-------|-------------|---------|
| Contributor | Resource Group | Deployer identity | Create App Service Plan + Apps |
| Managed Identity Operator | MI User-Assigned Identity | Deployer identity | Assign MI identity to plan |
| Key Vault Administrator | Key Vault | Deployer identity | Create KV secrets for registry adapters |
| Key Vault Secrets User | Key Vault | MI plan identity | Read registry adapter values at runtime |
| Storage File Data SMB Share Contributor | Storage Account | MI plan identity | Mount Azure File shares |
| Network Contributor | VNET/Subnet | MI plan identity | Custom (private endpoint) storage mounts |

### Adapter vs Install Script Decision Matrix

```
Does the feature have a platform adapter?
  ├── YES (Registry, Storage) → ARM template (generate_adapter_arm_template)
  │     • Registry keys → Key Vault secrets
  │     • File paths → Azure Files / LocalStorage mounts
  │     • Deploy via: az deployment group create / Azure Portal
  │
  └── NO (SMTP, MSMQ, COM, Fonts, Crystal) → install.ps1 (generate_install_script)
        • Windows features installed at MI startup
        • Injected into site ZIP during package_site
        • Runs inside MI sandbox with limited permissions
```

### Storage Mount Types

| Type | Use Case | Requires |
|------|----------|----------|
| `AzureFiles` | SMB file share for persistent storage | Storage Account + File Share |
| `Custom` | VNET-integrated private endpoint storage | VNET + Private DNS + Storage |
| `LocalStorage` | Ephemeral local SSD (fast, not persistent) | Nothing (built-in) |

### ARM Template API

```
Resource Type:  Microsoft.Web/serverfarms
API Version:    2024-11-01
Key Properties:
  sku.name:           "PV4"
  properties.isCustomMode: true
  properties.registryAdapters: [...]
  properties.storageMounts: [...]
  properties.installScripts: [...]
  identity.type:      "UserAssigned"
```

---

## File Structure

```
Migration/
├── server.py                              # FastMCP entry point
├── ps_runner.py                           # Python → PowerShell bridge
├── requirements.txt                       # mcp[cli]>=1.0.0
├── ARCHITECTURE.md                        # This document
│
├── tools/
│   ├── __init__.py                        # Shared FastMCP server instance
│   ├── discover.py                        # discover_iis_sites
│   ├── assessment_router.py               # choose_assessment_mode
│   ├── assess.py                          # assess_site_readiness
│   ├── assess_source.py                   # assess_source_code
│   ├── suggest.py                         # suggest_migration_approach
│   ├── recommend.py                       # recommend_target
│   ├── install_script.py                  # generate_install_script
│   ├── generate_adapter_arm.py            # generate_adapter_arm_template
│   ├── plan_deployment.py                 # plan_deployment
│   ├── package.py                         # package_site
│   ├── generate_settings.py               # generate_migration_settings
│   ├── confirm_migration.py               # confirm_migration
│   └── migrate.py                         # migrate_sites
│
│
│   # NOTE: scripts/ directory is NOT in this repo.
│   # Users download PowerShell scripts from Microsoft:
│   # https://appmigration.microsoft.com/api/download/psscripts/AppServiceMigrationScripts.zip
│   # Then configure the path via configure_scripts_path tool.
│
└── .github/agents/
    ├── iis-migrate.agent.md               # Orchestrator agent
    ├── iis-discover.agent.md              # Discovery subagent
    ├── iis-assess.agent.md                # Assessment subagent
    ├── iis-recommend.agent.md             # Recommendation subagent
    ├── iis-deploy-plan.agent.md           # Deployment planning subagent
    └── iis-execute.agent.md               # Execution subagent
```
