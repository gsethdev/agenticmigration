"""generate_adapter_arm - Generate ARM template for MI adapter provisioning.

Generates an ARM template to configure registry adapters and/or storage
adapters (Azure Files mounts, local attached storage, custom storage over
VNET) on a Managed Instance App Service Plan.

Registry and storage dependencies should NOT be handled via install.ps1.
Instead they use the MI platform's built-in adapter support, configured
either through the Azure Portal or by deploying this ARM template.
"""

import json
import os
import textwrap

from tools import server


# ---------------------------------------------------------------------------
# RBAC permissions required for MI adapter setup
# ---------------------------------------------------------------------------

_RBAC_PERMISSIONS = {
    "managed_identity": {
        "description": "User-Assigned Managed Identity for the App Service Plan",
        "required_roles": [
            {
                "role": "Key Vault Secrets User",
                "role_id": "4633458b-17de-408a-b874-0445c86b69e6",
                "scope": "Key Vault resource",
                "reason": "Allows the MI instance to read secrets from Key Vault at runtime for registry adapters and storage mount credentials.",
            },
        ],
    },
    "deploying_user": {
        "description": "User or service principal deploying the ARM template",
        "required_roles": [
            {
                "role": "Contributor",
                "role_id": "b24988ac-6180-42a0-ab88-20f7382dd24c",
                "scope": "Resource Group",
                "reason": "Create/update App Service Plan, assign managed identity.",
            },
            {
                "role": "Managed Identity Operator",
                "role_id": "f1a07417-d97a-45cb-824c-7a7467783830",
                "scope": "Managed Identity resource",
                "reason": "Assign the user-assigned managed identity to the App Service Plan.",
            },
            {
                "role": "Key Vault Administrator",
                "role_id": "00482a5a-887f-4fb3-b363-3b7fe8e74483",
                "scope": "Key Vault resource",
                "reason": "Create secrets in Key Vault for registry adapter values and storage credentials (one-time setup).",
            },
        ],
    },
    "storage_account": {
        "description": "Azure Files storage account (for AzureFiles and Custom mounts)",
        "required_roles": [
            {
                "role": "Storage File Data SMB Share Contributor",
                "role_id": "0c867c2a-1d8c-454a-a3db-ab2ea1bdc8bb",
                "scope": "Storage Account or File Share",
                "reason": "Allows read/write access to Azure File Shares mounted on the MI instance.",
            },
        ],
        "note": "The storage account access key or SAS token must be stored as a Key Vault secret and referenced via credentialsKeyVaultReference.",
    },
    "vnet_integration": {
        "description": "VNET integration for Custom storage over VNET",
        "required_roles": [
            {
                "role": "Network Contributor",
                "role_id": "4d97b98b-1d4f-4787-a291-c67834d212e7",
                "scope": "VNET/Subnet resource",
                "reason": "Required for VNET integration to access storage over private endpoints.",
            },
        ],
        "note": "The subnet must be delegated to Microsoft.Web/serverfarms. The storage account must have a private endpoint or service endpoint on the same VNET.",
    },
}


# ---------------------------------------------------------------------------
# ARM template skeleton based on the official MI ARM template schema
# (Microsoft.Web/serverfarms, apiVersion 2024-11-01)
# ---------------------------------------------------------------------------

_ARM_SCHEMA = "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#"


def _build_rbac_guidance(
    registry_adapters: list,
    storage_mounts: list,
    has_identity: bool,
    has_vnet: bool,
    features: set,
) -> dict:
    """Build RBAC permissions guidance based on what adapters are configured."""
    guidance: dict = {}

    # Always need deploying_user permissions
    guidance["deploying_user"] = _RBAC_PERMISSIONS["deploying_user"]

    # Managed identity is required when we have registry adapters or non-local storage
    needs_kv = bool(registry_adapters) or any(
        m.get("type") != "LocalStorage" for m in storage_mounts
    )
    if needs_kv:
        guidance["managed_identity"] = _RBAC_PERMISSIONS["managed_identity"]
        if not has_identity:
            guidance["managed_identity_warning"] = (
                "WARNING: A user-assigned managed identity is required for Key Vault access "
                "but was not provided. Create one and pass user_assigned_identity_id, or "
                "assign it later in Azure Portal before deploying."
            )

    # Storage account permissions for AzureFiles/Custom mounts
    has_file_mounts = any(m.get("type") == "AzureFiles" for m in storage_mounts)
    if has_file_mounts or "AzureFiles" in features or "Custom" in features:
        guidance["storage_account"] = _RBAC_PERMISSIONS["storage_account"]

    # VNET permissions for Custom mounts
    if has_vnet or "Custom" in features:
        guidance["vnet_integration"] = _RBAC_PERMISSIONS["vnet_integration"]

    return guidance


def _build_registry_adapter(
    registry_key: str,
    value_type: str = "String",
    keyvault_secret_uri: str = "",
) -> dict:
    """Build a single registryAdapters entry."""
    adapter = {
        "registryKey": registry_key,
        "type": value_type,
    }
    if keyvault_secret_uri:
        adapter["keyVaultSecretReference"] = {"secretUri": keyvault_secret_uri}
    return adapter


def _build_storage_mount(
    name: str,
    mount_type: str = "AzureFiles",
    source: str = "",
    drive_letter: str = "",
    mount_path: str = "",
    keyvault_secret_uri: str = "",
) -> dict:
    """Build a single storageMounts entry.

    mount_type: AzureFiles | LocalStorage | Custom
        - AzureFiles: Azure File Share mounted via SMB. Requires source UNC path
          and Key Vault secret with storage account key.
        - Custom: Storage accessible over VNET (private endpoint). Requires source
          UNC path, Key Vault secret, and VNET integration on the plan.
        - LocalStorage: Local attached SSD storage on the MI instance. No source
          or credentials needed — just a drive letter.

    drive_letter: Single letter (e.g. "k", "l", "h"). Used as the root of
        destinationPath (e.g. drive_letter="k" → destinationPath="k:\\").
        If mount_path is also provided, it becomes "k:\\mount_path".
    """
    mount: dict = {
        "name": name,
        "type": mount_type,
    }
    if source:
        mount["source"] = source

    # Build destinationPath from drive_letter + optional mount_path
    if drive_letter:
        letter = drive_letter.strip().rstrip(":").upper()
        if mount_path:
            dest = f"{letter}:\\{mount_path.lstrip(chr(92))}"
        else:
            dest = f"{letter}:\\"
        mount["destinationPath"] = dest

    if keyvault_secret_uri:
        mount["credentialsKeyVaultReference"] = {"secretUri": keyvault_secret_uri}
    return mount


@server.tool(
    name="generate_adapter_arm_template",
    description=(
        "Generate an ARM template for provisioning MI adapter resources on a Managed "
        "Instance App Service Plan. Adapters include:\n"
        "  - Registry Adapters: Map Windows Registry keys to Key Vault secrets so apps "
        "    reading HKLM/HKCU registry keys receive values from Key Vault at runtime.\n"
        "  - Storage Adapters (3 types):\n"
        "    * AzureFiles: Mount an Azure File Share via SMB to a drive letter.\n"
        "    * Custom: Mount storage over VNET (private endpoint) to a drive letter.\n"
        "    * LocalStorage: Attach local SSD storage to a drive letter.\n\n"
        "For each storage mount, ask the user for:\n"
        "  1. Mount type: AzureFiles, Custom, or Local\n"
        "  2. Drive letter (e.g. K, L, H)\n"
        "  3. Source UNC path (AzureFiles/Custom only): \\\\<account>.file.core.windows.net\\<share>\n"
        "  4. Key Vault secret URI (AzureFiles/Custom only): the secret storing the storage account key\n\n"
        "The output includes RBAC permissions required for the setup to work correctly.\n\n"
        "Use this instead of install.ps1 for registry and storage dependencies. "
        "install.ps1 should only be used for OS-level features like COM/MSI installation, "
        "SMTP server config, MSMQ client config, Crystal Reports, or custom fonts.\n\n"
        "The generated ARM template can be deployed via Azure CLI, PowerShell, or the "
        "Azure Portal. Alternatively, users can configure adapters directly in the "
        "Azure Portal under the App Service Plan > Managed Instance settings."
    ),
)
async def generate_adapter_arm_template(
    plan_name: str,
    region: str,
    sku: str = "P1V4",
    adapter_features: str = "",
    registry_keys_json: str = "",
    storage_mounts_json: str = "",
    subscription_id: str = "",
    resource_group: str = "",
    vnet_subnet_id: str = "",
    user_assigned_identity_id: str = "",
    output_path: str = "",
    install_script_uri: str = "",
) -> str:
    """Generate ARM template for MI adapters.

    Args:
        plan_name: Name of the App Service Plan (MI-enabled, PV4).
        region: Azure region (e.g., "East US").
        sku: SKU name (default P1V4). Must be PV4 tier for MI.
        adapter_features: Comma-separated adapter features to include:
            Registry, AzureFiles, LocalStorage, Custom.
            Used for auto-generating placeholder entries when specific configs aren't provided.
        registry_keys_json: JSON array of registry adapter configs. Each entry:
            {"registryKey": "HKLM/...", "type": "String", "keyVaultSecretUri": "https://..."}.
            If empty and Registry is in adapter_features, placeholder entries are generated.
        storage_mounts_json: JSON array of storage mount configs. Each entry:
            {"name": "...", "type": "AzureFiles|Custom|LocalStorage",
             "driveLetter": "K", "mountPath": "optional-subfolder",
             "source": "\\\\<account>.file.core.windows.net\\<share>" (AzureFiles/Custom only),
             "keyVaultSecretUri": "https://..." (AzureFiles/Custom only)}.
            If empty and storage features are in adapter_features, placeholder entries are generated.
        subscription_id: Azure subscription ID (for template metadata).
        resource_group: Azure resource group (for template metadata).
        vnet_subnet_id: Full resource ID of the VNET subnet for network integration.
        user_assigned_identity_id: Full resource ID of a user-assigned managed identity
            for Key Vault access. Required if using Key Vault-backed adapters.
        output_path: Custom output path for the ARM template JSON file.
        install_script_uri: Optional URI to an install script ZIP in Azure Blob Storage.
            Included in the ARM template if provided (for COM/SMTP/MSMQ features).
    """
    features = set()
    if adapter_features:
        for f in adapter_features.split(","):
            features.add(f.strip())

    # Build registry adapters
    registry_adapters = []
    if registry_keys_json:
        try:
            entries = json.loads(registry_keys_json)
            for entry in entries:
                registry_adapters.append(_build_registry_adapter(
                    registry_key=entry.get("registryKey", ""),
                    value_type=entry.get("type", "String"),
                    keyvault_secret_uri=entry.get("keyVaultSecretUri", ""),
                ))
        except (json.JSONDecodeError, TypeError):
            pass

    if not registry_adapters and "Registry" in features:
        # Generate placeholder entries
        registry_adapters = [
            _build_registry_adapter(
                registry_key="HKEY_LOCAL_MACHINE/SOFTWARE/<YourApp>/<SettingName>",
                value_type="String",
                keyvault_secret_uri="https://<your-keyvault>.vault.azure.net/secrets/<secret-name>/<version>",
            ),
        ]

    # Build storage mounts
    storage_mounts = []
    if storage_mounts_json:
        try:
            entries = json.loads(storage_mounts_json)
            for entry in entries:
                storage_mounts.append(_build_storage_mount(
                    name=entry.get("name", ""),
                    mount_type=entry.get("type", "AzureFiles"),
                    source=entry.get("source", ""),
                    drive_letter=entry.get("driveLetter", ""),
                    mount_path=entry.get("mountPath", ""),
                    keyvault_secret_uri=entry.get("keyVaultSecretUri", ""),
                ))
        except (json.JSONDecodeError, TypeError):
            pass

    if not storage_mounts:
        if "AzureFiles" in features:
            storage_mounts.append(_build_storage_mount(
                name="fileshare1",
                mount_type="AzureFiles",
                source="\\\\<storage-account>.file.core.windows.net\\<share-name>",
                drive_letter="K",
                mount_path="<mount-folder>",
                keyvault_secret_uri="https://<your-keyvault>.vault.azure.net/secrets/<fileshare-secret>/<version>",
            ))
        if "LocalStorage" in features:
            storage_mounts.append(_build_storage_mount(
                name="localstorage1",
                mount_type="LocalStorage",
                drive_letter="H",
            ))
        if "Custom" in features:
            storage_mounts.append(_build_storage_mount(
                name="customstorage1",
                mount_type="AzureFiles",
                source="\\\\<storage-account>.file.core.windows.net\\<share-name>",
                drive_letter="M",
                mount_path="<mount-folder>",
                keyvault_secret_uri="https://<your-keyvault>.vault.azure.net/secrets/<storage-secret>/<version>",
            ))

    # Build ARM template properties
    plan_properties: dict = {
        "reserved": False,
        "zoneRedundant": False,
        "isCustomMode": True,
    }

    if vnet_subnet_id:
        plan_properties["Network"] = {"VirtualNetworkSubnetId": vnet_subnet_id}

    if registry_adapters:
        plan_properties["registryAdapters"] = registry_adapters

    if storage_mounts:
        plan_properties["storageMounts"] = storage_mounts

    if install_script_uri:
        plan_properties["installScripts"] = [
            {
                "name": "InstallScript",
                "source": {
                    "sourceUri": install_script_uri,
                    "type": "RemoteAzureBlob",
                },
            }
        ]

    if user_assigned_identity_id:
        plan_properties["planDefaultIdentity"] = {
            "identityType": "UserAssigned",
            "userAssignedIdentityResourceId": user_assigned_identity_id,
        }

    # Assemble full ARM template
    resource: dict = {
        "location": region or "[resourceGroup().location]",
        "name": plan_name,
        "type": "Microsoft.Web/serverfarms",
        "apiVersion": "2024-11-01",
        "properties": plan_properties,
        "sku": {
            "Name": sku,
            "capacity": 1,
        },
    }

    if user_assigned_identity_id:
        resource["identity"] = {
            "type": "UserAssigned",
            "userAssignedIdentities": {
                user_assigned_identity_id: {},
            },
        }

    arm_template = {
        "$schema": _ARM_SCHEMA,
        "contentVersion": "1.0.0.0",
        "resources": [resource],
    }

    # Write to file
    if not output_path:
        import tempfile
        output_dir = os.path.join(tempfile.gettempdir(), "iis-migration", plan_name)
        os.makedirs(output_dir, exist_ok=True)
        output_path = os.path.join(output_dir, "mi-adapters-template.json")

    os.makedirs(os.path.dirname(output_path), exist_ok=True)
    with open(output_path, "w", encoding="utf-8") as f:
        json.dump(arm_template, f, indent=2)

    # Build summary
    adapter_summary = []
    if registry_adapters:
        adapter_summary.append(f"{len(registry_adapters)} registry adapter(s)")
    if storage_mounts:
        types = set(m.get("type", "") for m in storage_mounts)
        drives = [m.get("destinationPath", "").split(":")[0] for m in storage_mounts if m.get("destinationPath")]
        drive_info = f", drives: {', '.join(d + ':' for d in drives)}" if drives else ""
        adapter_summary.append(f"{len(storage_mounts)} storage mount(s) ({', '.join(sorted(types))}{drive_info})")
    if install_script_uri:
        adapter_summary.append("1 install script reference")

    # Determine which RBAC roles are needed based on configured adapters
    rbac_required = _build_rbac_guidance(registry_adapters, storage_mounts,
                                          bool(user_assigned_identity_id),
                                          bool(vnet_subnet_id),
                                          features)

    output = {
        "arm_template_path": output_path,
        "plan_name": plan_name,
        "region": region,
        "sku": sku,
        "is_custom_mode": True,
        "adapters_configured": adapter_summary,
        "registry_adapter_count": len(registry_adapters),
        "storage_mount_count": len(storage_mounts),
        "storage_mount_details": [
            {
                "name": m.get("name"),
                "type": m.get("type"),
                "destinationPath": m.get("destinationPath", ""),
                "has_source": bool(m.get("source")),
                "has_credentials": "credentialsKeyVaultReference" in m,
            }
            for m in storage_mounts
        ],
        "has_install_script_ref": bool(install_script_uri),
        "has_managed_identity": bool(user_assigned_identity_id),
        "has_vnet_integration": bool(vnet_subnet_id),
        "rbac_permissions_required": rbac_required,
        "deployment_options": [
            "Azure CLI: az deployment group create -g <rg> --template-file " + output_path,
            "PowerShell: New-AzResourceGroupDeployment -ResourceGroupName <rg> -TemplateFile " + output_path,
            "Azure Portal: Upload template via 'Deploy a custom template'",
            "Alternatively: Configure adapters directly in Azure Portal > App Service Plan > Managed Instance settings",
        ],
        "note": (
            "Review the template and replace placeholder values (<your-keyvault>, <storage-account>, etc.) "
            "with your actual Azure resource names. See rbac_permissions_required for the RBAC roles "
            "that must be assigned before deployment."
        ),
    }

    return json.dumps(output, indent=2)
