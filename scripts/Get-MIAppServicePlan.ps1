<#
.SYNOPSIS
    Query existing MI-enabled App Service Plans in Azure.

.DESCRIPTION
    Finds App Service Plans with IsCustomMode=true (Managed Instance)
    and PV4 SKU in the specified subscription and resource group.

.PARAMETER SubscriptionId
    Azure subscription ID.

.PARAMETER ResourceGroup
    Azure resource group name.

.PARAMETER Region
    Azure region (optional filter).

.OUTPUTS
    JSON file at $env:TEMP\iis-migration\mi-plans.json
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $true)]
    [string]$ResourceGroup,

    [Parameter(Mandatory = $false)]
    [string]$Region = ""
)

$ErrorActionPreference = "Stop"

# Ensure Az module is available
if (-not (Get-Module -ListAvailable Az.Websites)) {
    Write-Error "Az.Websites module is not installed. Run: Install-Module Az -Scope CurrentUser"
    exit 1
}

# Set subscription context
Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop | Out-Null

# Get all App Service Plans in the resource group
$plans = Get-AzAppServicePlan -ResourceGroupName $ResourceGroup -ErrorAction Stop

# Filter for MI-enabled plans (IsCustomMode=true and PV4 SKU)
$miPlans = @()
foreach ($plan in $plans) {
    $sku = $plan.Sku
    $isPV4 = $sku.Tier -eq "PremiumV4" -or $sku.Name -like "P*v4"

    # Check IsCustomMode via the properties — MI plans have this flag
    $isCustomMode = $false
    if ($plan.Properties -and $plan.Properties.ContainsKey("IsCustomMode")) {
        $isCustomMode = $plan.Properties["IsCustomMode"] -eq $true
    }

    # Also check via direct property access (newer Az module versions)
    if (-not $isCustomMode) {
        try {
            $resource = Get-AzResource -ResourceId $plan.Id -ExpandProperties -ErrorAction SilentlyContinue
            if ($resource.Properties.isCustomMode -eq $true) {
                $isCustomMode = $true
            }
        }
        catch {
            # Ignore — property may not exist
        }
    }

    if ($isCustomMode -and $isPV4) {
        $entry = @{
            PlanName      = $plan.Name
            ResourceGroup = $plan.ResourceGroup
            Location      = $plan.Location
            Sku           = $sku.Name
            Tier          = $sku.Tier
            IsCustomMode  = $true
            WorkerCount   = $plan.NumberOfWorkers
            Status        = $plan.Status
        }

        # Apply region filter if specified
        if ($Region -and $plan.Location -ne $Region) {
            continue
        }

        $miPlans += $entry
    }
}

# Write output
$outputDir = Join-Path $env:TEMP "iis-migration"
if (-not (Test-Path $outputDir)) {
    New-Item -Path $outputDir -ItemType Directory -Force | Out-Null
}
$outputFile = Join-Path $outputDir "mi-plans.json"
$miPlans | ConvertTo-Json -Depth 5 | Out-File -FilePath $outputFile -Encoding utf8 -Force

Write-Host "Found $($miPlans.Count) MI-enabled App Service Plan(s)."
Write-Host "Results written to: $outputFile"
