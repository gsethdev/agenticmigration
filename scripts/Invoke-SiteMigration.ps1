<#
  .SYNOPSIS
  Migrates sites to Azure App Service on Azure Cloud

  .DESCRIPTION
  Deploys, configures, and migrates sites
  to Azure App Service.

  .PARAMETER MigrationSettingsFilePath
  Specifies the path to the migration settings JSON file.
  
  .PARAMETER MigrationResultsFilePath
  Specifies a custom path for the summary file of the migration results
  
  .PARAMETER Force
  Overwrites pre-existing migration results output file
  
  .OUTPUTS
  Returns an object containing the summary migration results for all sites and related Azure resources created during migration

  .EXAMPLE
  C:\PS> .\Invoke-SiteMigration -MigrationSettingsFilePath "TemplateMigrationSettings.json"

  .EXAMPLE
  C:\PS> $MigrationOutput = .\Invoke-SiteMigration -MigrationSettingsFilePath "TemplateMigrationSettings.json"
#>

#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$MigrationSettingsFilePath,
    
    [Parameter()]
    [string]$MigrationResultsFilePath,
    
    [Parameter()]
    [switch]$Force
)
Import-Module (Join-Path $PSScriptRoot "MigrationHelperFunctions.psm1")

$ScriptConfig = Get-ScriptConfig
$ScriptsVersion = $ScriptConfig.ScriptsVersion
$ResourcesCreated = @()
Add-Type -Assembly "System.IO.Compression.FileSystem" #Used to read files in .zip

Send-TelemetryEventIfEnabled -TelemetryTitle "Invoke-SiteMigration.ps1" -EventName "Started script" -EventType "action" -ErrorAction SilentlyContinue

if  (!$MigrationResultsFilePath) {
    $MigrationResultsFilePath = $ScriptConfig.DefaultMigrationResultsFilePath
}
if ((Test-Path $MigrationResultsFilePath) -and !$Force) {
    Write-HostError -Message  "$MigrationResultsFilePath already exists. Use -Force to overwrite $MigrationResultsFilePath"
    exit 1
}  

#Begin migration steps through Azure PowerShell - Login
Initialize-LoginToAzure
Test-InternetConnectivity

#Multiple sites can be migrated sequentially using migration settings file
try {
    $MigrationSettings = Get-Content $MigrationSettingsFilePath -Raw | ConvertFrom-Json
}
catch {
    Write-HostError "Error reading migration settings file: $($_.Exception.Message)"
    $ExceptionData = Get-ExceptionData -Exception $_.Exception
    Send-TelemetryEventIfEnabled -TelemetryTitle "Invoke-SiteMigration.ps1" -EventName "Error reading migration settings file" -ExceptionData $ExceptionData -EventType "error" -ErrorAction SilentlyContinue
    exit 1
}

if ($MigrationSettings -eq "") {
    Write-HostError "Migration settings file '$MigrationSettingsFilePath' is empty"
    Write-HostError "Use Generate-MigrationSettings.ps1 to generate migration settings"
    $ExceptionData = Get-ExceptionData -Exception $_.Exception
    Send-TelemetryEventIfEnabled -TelemetryTitle "Invoke-SiteMigration.ps1" -EventName "Migration settings file is empty" -ExceptionData $ExceptionData -EventType "error" -ErrorAction SilentlyContinue
    exit 1
}

function Get-SiteMigrationResult {
    param(
        [Parameter()]
        [string]$IISSiteName,

        [Parameter()]
        $MigrationStatus
    )
    $SiteMigrationResult = New-Object PSObject
    if ($IISSiteName) {
        Add-Member -InputObject $SiteMigrationResult -MemberType NoteProperty -Name IISSiteName -Value $IISSiteName
    }
    if ($MigrationStatus) {
        Add-Member -InputObject $SiteMigrationResult -MemberType NoteProperty -Name MigrationStatus -Value $MigrationStatus
    }

    return $SiteMigrationResult;
}

function Get-ResourceCreationResult {
    param(
        [Parameter()]
        [string]$ResourceName,

        [Parameter()]
        [string]$ResourceType,

        [Parameter()]
        [bool]$Created,
        
        [Parameter()]
        [string]$Error,
        
        [Parameter()]
        [string]$IISSiteName,
        
        [Parameter()]
        [string]$ManagementLink,
        
        [Parameter()]
        [string]$SiteBrowseLink
    )
    $ResourceCreationResult = New-Object PSObject
    if ($ResourceName) {
        Add-Member -InputObject $ResourceCreationResult -MemberType NoteProperty -Name ResourceName -Value $ResourceName
    }
    if ($ResourceType) {
        Add-Member -InputObject $ResourceCreationResult -MemberType NoteProperty -Name ResourceType -Value $ResourceType
    }
    Add-Member -InputObject $ResourceCreationResult -MemberType NoteProperty -Name Created -Value $Created  
    if ($Error) {
        Add-Member -InputObject $ResourceCreationResult -MemberType NoteProperty -Name Error -Value $Error
    }
    if ($IISSiteName) {
        Add-Member -InputObject $ResourceCreationResult -MemberType NoteProperty -Name IISSiteName -Value $IISSiteName
    }
    if ($ManagementLink) {
        Add-Member -InputObject $ResourceCreationResult -MemberType NoteProperty -Name ManagementLink -Value $ManagementLink
    }
    if ($SiteBrowseLink) {
        Add-Member -InputObject $ResourceCreationResult -MemberType NoteProperty -Name SiteBrowseLink -Value $SiteBrowseLink
    }    

    return $ResourceCreationResult;
}

function Add-ResourceResultError {
    param(
        [Parameter(Mandatory)]
        [object]$ResourceCreationResult,

        [Parameter(Mandatory)]
        [string]$Error
    )
   
    if($ResourceCreationResult.PSObject.Properties.Name -contains "Error") {
        $newError = "$($ResourceCreationResult.Error); $Error"
        $ResourceCreationResult.Error = $newError
    } else {
        Add-Member -InputObject $ResourceCreationResult -MemberType NoteProperty -Name Error -Value $Error
    }
}

function Disable-BasicAuthentication {
    param(
        [Parameter(Mandatory)]
        [string]$SubscriptionId,

        [Parameter(Mandatory)]
        [string]$ResourceGroup,

        [Parameter(Mandatory)]
        [string]$AzureSiteName,

        [Parameter(Mandatory)]
        [string]$Location,

        [Parameter(Mandatory)]
        [string]$AtName # ftp or scm
    )
   
    $disableAuthParams = @{
        SubscriptionId = $SubscriptionId
        ResourceGroupName = $ResourceGroup
        Name = @($AzureSiteName, $AtName)
        ResourceProviderName = "Microsoft.Web"
        ResourceType = @("sites", "basicPublishingCredentialsPolicies")
        ApiVersion = "2022-03-01"
        Payload = "{ `"location`": `"$Location`", `"properties`": { `"allow`": false } }"
        Method = "PUT"
    }

    $result = Invoke-AzRestMethod @disableAuthParams
    if ($result.StatusCode -ne "200")
    {
        $ErrorMsg = "Error status code disabling basic auth ($AtName) : $($result.StatusCode)"
        Write-HostWarn $ErrorMsg
        Send-TelemetryEventIfEnabled -TelemetryTitle "Invoke-SiteMigration.ps1" -EventName "Error disabling basic auth" -EventMessage $ErrorMsg -EventType "warn" -ErrorAction SilentlyContinue -Subscription $SubscriptionId -ResourceGroup $ResourceGroup -AzureSite $AzureSiteName              
    }
}

function Invoke-SiteCreationAndDeployment() {
    param(
        [Parameter()]
        [string]$Region,
        
        [Parameter()]
        [string]$SubscriptionId,

        [Parameter()]
        [string]$ResourceGroup,

        [Parameter()]
        [string]$AppServicePlan,
        
        [Parameter()]
        [string]$AppServiceEnvironment,
        
        [Parameter()]
        [string]$IISSiteName,

        [Parameter()]
        [string]$SitePackagePath,
        
        [Parameter()]
        [string]$AzureSiteName
    )       
    
    $AzurePortalLink = "$($ScriptConfig.PortalEndpoint)/#resource/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Web/sites/$AzureSiteName/appServices"
    $siteResource = Get-ResourceCreationResult -ResourceName $AzureSiteName -ResourceType "Site" -Created $False -IISSiteName $IISSiteName -ManagementLink $AzurePortalLink
    
    #Create and deploy site (new Web App) to Azure (if ASE was provided, create it in that ASE)
    try {
        $InASELog = "";
        if ($AppServiceEnvironment) {
            $ASEDetails = Get-AzResource -Name $AppServiceEnvironment -ResourceType Microsoft.Web/hostingEnvironments
            $InASELog = " in ASE $AppServiceEnvironment"
            $AspId = (Get-AzAppServicePlan -ResourceGroupName $ResourceGroup -Name $AppServicePlan).Id
            $NewAzureApp = New-AzWebApp -Name $AzureSiteName -ResourceGroupName $ResourceGroup -AppServicePlan $AspId -Location $ASEDetails.Location -AseName $AppServiceEnvironment -AseResourceGroupName $ASEDetails.ResourceGroupName  -ErrorAction Stop
        } else {
            $AspId = (Get-AzAppServicePlan -ResourceGroupName $ResourceGroup -Name $AppServicePlan).Id
            $NewAzureApp = New-AzWebApp -Name $AzureSiteName -ResourceGroupName $ResourceGroup -AppServicePlan $AspId -Location $Region -ErrorAction Stop
        }
                
        $siteResource.Created = $True 
    }
    catch {
        $ExceptionMsg = Get-AzExceptionMessage -Exception $_.Exception
        $ErrorMsg = "Error creating Web App$InASELog for site '$IISSiteName' : $ExceptionMsg"
        Write-HostError $ErrorMsg
        $ExceptionData = Get-ExceptionData -Exception $ExceptionMsg
        Send-TelemetryEventIfEnabled -TelemetryTitle "Invoke-SiteMigration.ps1" -EventName "Error creating web app" -EventMessage "Error creating web app" -ExceptionData $ExceptionData -EventType "error" -ErrorAction SilentlyContinue -Subscription $SubscriptionId -ResourceGroup $ResourceGroup -AzureSite $AzureSiteName              
        Add-ResourceResultError -ResourceCreationResult $siteResource -Error $ErrorMsg
        return $siteResource
    }

    Write-HostInfo "Created Web App $($NewAzureApp.Name)$InASELog for the site '$IISSiteName'"
    Send-TelemetryEventIfEnabled -TelemetryTitle "Invoke-SiteMigration.ps1" -EventName "Successfully created web app" -EventMessage "Successfully created web app" -EventType "info" -Subscription $SubscriptionId -ResourceGroup $ResourceGroup -AzureSite $AzureSiteName -ErrorAction SilentlyContinue
    
    # Explicitly disable basic authentication for the site
    try {
        Disable-BasicAuthentication -SubscriptionId $SubscriptionId -ResourceGroup $NewAzureApp.ResourceGroup -AzureSiteName $NewAzureApp.Name -Location $NewAzureApp.Location -AtName "ftp"
        Disable-BasicAuthentication -SubscriptionId $SubscriptionId -ResourceGroup $NewAzureApp.ResourceGroup -AzureSiteName $NewAzureApp.Name -Location $NewAzureApp.Location -AtName "scm"
    }
    catch {
        $ExceptionMsg = Get-AzExceptionMessage -Exception $_.Exception
        $ErrorMsg = "Error explicitly disabling basic auth for site '$AzureSiteName' : $ExceptionMsg"
        Write-HostError $ErrorMsg
        $ExceptionData = Get-ExceptionData -Exception $ExceptionMsg        
        Send-TelemetryEventIfEnabled -TelemetryTitle "Invoke-SiteMigration.ps1" -EventName "Error disabling basic auth" -EventMessage "Error disabling basic auth" -ExceptionData $ExceptionData -EventType "error" -ErrorAction SilentlyContinue -Subscription $SubscriptionId -ResourceGroup $ResourceGroup -AzureSite $AzureSiteName              
    }

    #Use the SiteConfig file to push site settings to Azure
    $SiteConfig = (Get-ZippedFileContents -ZipPath $SitePackagePath -NameOfFile "SiteConfig.json") | ConvertFrom-Json

    if (!$SiteConfig) {
        Write-HostError "Site configuration file (SiteConfig.json) was not found or was empty! Unable to configure site settings."      
        Add-ResourceResultError -ResourceCreationResult $siteResource -Error "Missing SiteConfig.json in package .zip, site settings may not be configured or content may not be in correct format."
    }
    else {
        Write-HostInfo "Configuring Azure settings for Azure site $($SetAzureSiteSettings.Name)"

        $SetAzureSiteSettings = Set-AzWebApp -ResourceGroupName $ResourceGroup -Name $AzureSiteName -Use32BitWorkerProcess $SiteConfig.Is32Bit -ManagedPipelineMode $SiteConfig.ManagedPipelineMode -NetFrameworkVersion $SiteConfig.NetFrameworkVersion -ErrorVariable SetSettingsError #-ErrorAction SilentlyContinue
        
        if($SetSettingsError) {
            $settingsErrorMsg = "Error setting App Service configuration settings: $($SetSettingsError.Exception)"
            Write-HostError $settingsErrorMsg
            Add-ResourceResultError -ResourceCreationResult $siteResource -Error $settingsErrorMsg
        }
        
        #Set the site's virtual applications
        Write-HostInfo "Configuring any virtual directories..."
        if ($SiteConfig.VirtualApplications) {
            $SiteConfigResource = Get-AzResource -ResourceType "Microsoft.Web/sites" -ResourceGroupName $ResourceGroup -ResourceName $AzureSiteName

            $SiteConfigResource.properties.siteConfig.virtualApplications = $SiteConfig.VirtualApplications.clone()

            $SetVirtualDirectories = $SiteConfigResource | Set-AzResource -ErrorVariable ErrorConfiguringSite -Force
            if ($ErrorConfiguringSite) {
                Write-HostError $ErrorConfiguringSite.Exception
                Add-ResourceResultError -ResourceCreationResult $siteResource -Error $ErrorConfiguringSite.Exception                
            }
            else {
                Write-HostInfo "Virtual directories/applications have been configured on Azure for $($SetVirtualDirectories.Name)"
            }
        }
    }

    #Deploy/Publish the site and check for errors
    Write-HostInfo "Beginning zip deployment..."
    
    #Get site scm hostname
    try {       
        if($NewAzureApp.EnabledHostNames.Count -gt 0) {         
            $scmHostname = $NewAzureApp.EnabledHostNames -match ".scm."
            $SiteURI = $NewAzureApp.EnabledHostNames -notmatch ".scm."
        }
    } catch {       
        $hostnameErrorMsg = "$Error getting site scm endpoint hostname from EnabledHostnames information: ($_.Exception.Message)"
        Write-HostError $hostnameErrorMsg
        $ExceptionData = Get-ExceptionData -Exception $_.Exception
        Send-TelemetryEventIfEnabled -TelemetryTitle "Invoke-SiteMigration.ps1" -EventName "Error getting scm hostname from EnabledHostnames" -ExceptionData $ExceptionData -EventType "error" -ErrorAction SilentlyContinue -Subscription $SubscriptionId -ResourceGroup $ResourceGroup -AzureSite $AzureSiteName        
    }
    
    if(!$scmHostname) {
        #Did not find or set expected scm hostname from created site info
        $scmHostname = "$AzureSiteName.scm.azurewebsites.net"
        Write-HostWarn "Using default constructed site scm hostname ($scmHostname)"     
    }
    if(!$SiteURI) {
        #Did not find or set expected default hostname from created site info
        $SiteURI = "$AzureSiteName.azurewebsites.net"
        Write-HostWarn "Using default constructed site browse link ($SiteURI)"      
    }

    try {
        $token = (Get-AzAccessToken).Token
        $Headers = @{
            authorization = "Bearer $token"
        }
        $DeploymentURI = "https://$scmHostname/api/zip"

        [void](Invoke-RestMethod -Uri $DeploymentURI -Method 'PUT' -ContentType "multipart/form-data" -Headers $Headers -InFile $SitePackagePath -UserAgent "migrationps/v$ScriptsVersion")

        Write-HostInfo "Succesfully migrated site '$IISSiteName' to $SiteURI"
    }
    catch {
        $AdditionalNote = ""
        $DeploymentErrorEventMessage = ""
        if($_.CategoryInfo -and $_.CategoryInfo.TargetName -eq 'Get-AzAccessToken' -and $_.CategoryInfo.Reason -eq 'CommandNotFoundException') {
            $AdditionalNote = " Please try updating the Az.Account module to a later version, more information on updating Azure PowerShell: https://go.microsoft.com/fwlink/?linkid=2250167"
            $DeploymentErrorEventMessage = "Get-AzAccessToken CommandNotFoundException"
        }
        Write-HostError "Error deploying site zip $SitePackagePath for the site '$IISSiteName': $($_.Exception.Message)$AdditionalNote"
        
        $ExceptionData = Get-ExceptionData -Exception $_.Exception
        Send-TelemetryEventIfEnabled -TelemetryTitle "Invoke-SiteMigration.ps1" -EventName "Error deploying site" -EventMessage $DeploymentErrorEventMessage -ExceptionData $ExceptionData -EventType "error" -ErrorAction SilentlyContinue -Subscription $SubscriptionId -ResourceGroup $ResourceGroup -AzureSite $AzureSiteName
        Add-ResourceResultError -ResourceCreationResult $siteResource -Error "Error deploying site content: $($_.Exception.Message)$AdditionalNote"
        return $siteResource
    }
    Send-TelemetryEventIfEnabled -TelemetryTitle "Invoke-SiteMigration.ps1" -EventName "Successfully deployed site" -EventType "info" -Subscription $SubscriptionId -ResourceGroup $ResourceGroup -AzureSite $AzureSiteName -ErrorAction SilentlyContinue
    
    Add-Member -InputObject $siteResource -MemberType NoteProperty -Name SiteBrowseLink -Value "http://$SiteURI"    
    return $siteResource
}

function Test-AzureSiteNames() {
    $AzureSites = New-Object System.Collections.ArrayList
    $UnavailableSites = New-Object System.Collections.ArrayList
    foreach ($SettingsObject in $MigrationSettings) {
        $Sites = $SettingsObject.Sites; 
        $SubscriptionId = $SettingsObject.SubscriptionId; 
        foreach ($Site in $Sites) {
            $AzureSiteName = $Site.AzureSiteName
            if ($AzureSites -contains $AzureSiteName) {
                Write-HostError "All the sites in $MigrationSettingsFilePath should have a unique AzureSiteName"
                Write-HostError "AzureSiteName '$AzureSiteName' is used for more than one site in $MigrationSettingsFilePath"
                exit 1
            }
            [void]$AzureSites.Add($AzureSiteName)
        } 
    }

    foreach ($SiteName in $AzureSites) {
        $SiteAvailabilityResponse = AzureSiteNameAvailability -SiteName $SiteName -AzureSubscriptionId $SubscriptionId
        if (!$SiteAvailabilityResponse.nameAvailable) {
            Write-HostError "AzureSiteName '$SiteName' $($SiteAvailabilityResponse.reason). $($SiteAvailabilityResponse.message)"
            [void] $UnavailableSites.Add($SiteName)
        }
    }

    if ($UnavailableSites.Count -ne 0) {
        Write-HostError "Certain Azure site names in $MigrationSettingsFilePath are not available on Azure cloud"
        Write-HostError "Site names not available are: $($UnavailableSites -join ', ')"
        Send-TelemetryEventIfEnabled -TelemetryTitle "Invoke-SiteMigration.ps1" -EventName "Azure site name not available" -EventType "error" -ErrorAction SilentlyContinue
        exit 1
    }
}

function Test-SettingFailIfMissing() {
    param(
        [Parameter(Mandatory)]
        [string]$SettingToCheck,

        [Parameter(Mandatory)]
        [string]$ItemName,

        [Parameter(Mandatory)]
        [string]$AppServicePlan,

        [Parameter(Mandatory)]
        [string]$MigrationSettingsFilePath
    )
    if (!$SettingToCheck) {
        Write-HostError "$ItemName value missing for AppServicePlan '$AppServicePlan' in $MigrationSettingsFilePath"
        exit 1
    }        
}

function Write-AzureResourceResults() {
    param(
        [Parameter(Mandatory)]
        [object[]]$ResourceSummaryInfo,

        [Parameter(Mandatory)]
        [string]$MigrationResultsFilePath
    )
    if ($ResourceSummaryInfo) {
        Write-HostInfo "Resources created during migration"
        Write-HostInfo ($ResourceSummaryInfo | Format-Table -Property ResourceName,ResourceType,Created,Error | Out-String)  
        
        try {
            ConvertTo-Json $ResourceSummaryInfo -Depth 10 | Out-File (New-Item -Path $MigrationResultsFilePath -ItemType "file" -ErrorAction Stop -Force)
            Write-HostInfo "Migration resource creation results saved to $MigrationResultsFilePath"
        }
        catch {
            Write-HostError -Message "Error creating migration results file: $($_.Exception.Message)" 
            Send-TelemetryEventIfEnabled -TelemetryTitle "Generate-MigrationSettings.ps1" -EventName "Error in creating migration results file" -EventType "error" -ErrorAction SilentlyContinue    
        } 
    } else {
        Write-HostInfo "$MigrationResultsFilePath was not created as Azure resources were not created."
    }       
}


#validating all the settings in the migration settings file
try {
    foreach ($SettingsObject in $MigrationSettings) {
        $AppServicePlan = $SettingsObject.AppServicePlan
        $Region = $SettingsObject.Region
        $SubscriptionId = $SettingsObject.SubscriptionId
        $ResourceGroup = $SettingsObject.ResourceGroup
        $Tier = $SettingsObject.Tier
        $NumberOfWorkers = $SettingsObject.NumberOfWorkers
        $WorkerSize = $SettingsObject.WorkerSize
        $AppServiceEnvironment = $SettingsObject.AppServiceEnvironment

        $Sites = $SettingsObject.Sites;  

        if (!$AppServicePlan) {
            Write-HostError "AppServicePlan value not found for some sites in $MigrationSettingsFilePath"
            exit 1
        }
    
        if (!$Sites -or $Sites.count -lt 1) {
            Write-HostError "No sites present for AppServicePlan '$AppServicePlan' in $MigrationSettingsFilePath, all App Service Plans should contain at least one site"
            exit 1
        }
            
        Test-SettingFailIfMissing -SettingToCheck $SubscriptionId -ItemName "SubscriptionId" -AppServicePlan $AppServicePlan -MigrationSettingsFilePath $MigrationSettingsFilePath
        Test-SettingFailIfMissing -SettingToCheck $ResourceGroup -ItemName "ResourceGroup" -AppServicePlan $AppServicePlan -MigrationSettingsFilePath $MigrationSettingsFilePath   
    
        Test-AzureResources -SubscriptionId $SubscriptionId -Region $Region -AppServiceEnvironment $AppServiceEnvironment -ResourceGroup $ResourceGroup -SkipWarnOnRGNotExists
       
        if($AppServiceEnvironment) {
            if($Tier -and !$Tier.StartsWith("Isolated")) {
                Write-HostError "Isolated SKUs must be specified for App Service Plans on App Service Environments. Please update Tier value on AppServicePlan 'AppServicePlan' to the appropriate Isolated SKU ('Isolated'|'IsolatedV2')"
                exit 1
            }
        } else {
            if($Tier -and $Tier.StartsWith("Isolated")) {
                Write-HostError "Isolated SKUs may only be used for App Service Plans on App Service Environments. Please update Tier value on AppServicePlan 'AppServicePlan' to a non-Isolated SKU"
                exit 1
            }
        }                

        #validating asp 
        $ExistingAppServicePlan = Get-AzAppServicePlan -ResourceGroupName $ResourceGroup -Name $AppServicePlan -ErrorAction Stop
       
        if ($ExistingAppServicePlan) {
            Write-HostInfo "Found App Service Plan $AppServicePlan in Resource Group $ResourceGroup"                    
            
            if($AppServiceEnvironment -and (!$ExistingAppServicePlan.HostingEnvironmentProfile -or $ExistingAppServicePlan.HostingEnvironmentProfile.Name -ne $AppServiceEnvironment)) {
                $ASEMisMatchExplainClause = "which is not on an App Service Environment"
                if($ExistingAppServicePlan.HostingEnvironmentProfile -and $ExistingAppServicePlan.HostingEnvironmentProfile.Name -ne $AppServiceEnvironment) {
                    $ASEMisMatchExplainClause = "which is on App Service Environment '$($ExistingAppServicePlan.HostingEnvironmentProfile.Name)'"
                }
                Write-HostError "Specified App Service Environment setting ($AppServiceEnvironment) does not match pre-existing App Service Plan '$AppServicePlan' $ASEMisMatchExplainClause"
                exit 1
            }
            # warn if ASP settings were specified but don't match existing ASP properties
            if($Region) {
                Write-HostWarn "Specified Region setting ($Region) will be ignored for pre-existing App Service Plan '$AppServicePlan' (current location: $($ExistingAppServicePlan.Location))"
            }
            if($Tier -and $ExistingAppServicePlan.Sku.Tier -ne $Tier) {               
                Write-HostWarn "Specified Tier setting ($Tier) will be ignored for pre-existing App Service Plan '$AppServicePlan' (current Tier: $($ExistingAppServicePlan.Sku.Tier))"
            }
            if($NumberOfWorkers -and $ExistingAppServicePlan.Sku.Capacity) {
                Write-HostWarn "Specified NumberOfWorkers setting ($NumberOfWorkers) will be ignored for pre-existing App Service Plan '$AppServicePlan' (current capacity: $($ExistingAppServicePlan.Sku.Capacity))"
            }
            if($WorkerSize) {
                Write-HostWarn "Sepecified WorkerSize setting ($WorkerSize) will be ignored for pre-existing App Service Plan $AppServicePlan"
            }   
        } else {
            Write-HostInfo "App Service Plan $AppServicePlan not found in Resource Group $ResourceGroup, it will be created"  
            Test-SettingFailIfMissing -SettingToCheck $Region -ItemName "Region" -AppServicePlan $AppServicePlan -MigrationSettingsFilePath $MigrationSettingsFilePath
            Test-SettingFailIfMissing -SettingToCheck $Tier -ItemName "Tier" -AppServicePlan $AppServicePlan -MigrationSettingsFilePath $MigrationSettingsFilePath        
            Test-SettingFailIfMissing -SettingToCheck $NumberOfWorkers -ItemName "NumberOfWorkers" -AppServicePlan $AppServicePlan -MigrationSettingsFilePath $MigrationSettingsFilePath        
            Test-SettingFailIfMissing -SettingToCheck $WorkerSize -ItemName "WorkerSize" -AppServicePlan $AppServicePlan -MigrationSettingsFilePath $MigrationSettingsFilePath              
        }                    
        
        foreach ($Site in $Sites) {
            $IISSiteName = $Site.IISSiteName
            $SitePackagePath = $Site.SitePackagePath
            if (!$SitePackagePath) {
                Write-HostError "Path to site zip setting 'SitePackagePath' missing for the site '$IISSiteName' in $MigrationSettingsFilePath"
                exit 1
            }               
            # get full path to package files: if relative, should be relative to migration settings file
            if(-not ([System.IO.Path]::IsPathRooted($SitePackagePath))) {
                $migrationFileFullPath = $MigrationSettingsFilePath
                if(-not ([System.IO.Path]::IsPathRooted($migrationFileFullPath))) {
                    $migrationFileFullPath = Join-Path (Get-Location).Path $MigrationSettingsFilePath
                }
                $fullPkgPath = Join-Path (Split-Path -Path $migrationFileFullPath) $Site.SitePackagePath
                $SitePackagePath = $fullPkgPath
            }
            $AzureSiteName = $Site.AzureSiteName
    
            if (!$IISSiteName) {
                Write-HostError "IISSiteName value missing for site under AppServicePlan '$AppServicePlan' in $MigrationSettingsFilePath"
                exit 1
            }
    
            if (!$SitePackagePath -or !(Test-Path $SitePackagePath)) {
                Write-HostError "SitePackagePath value missing or zip not found for IISSiteName '$IISSiteName' under AppServicePlan '$AppServicePlan' in $MigrationSettingsFilePath"
                exit 1
            }
    
            if (!$AzureSiteName) {
                Write-HostError "AzureSiteName value missing for IISSiteName '$IISSiteName' under AppServicePlan '$AppServicePlan' in $MigrationSettingsFilePath"
                exit 1
            }
        }
    }
    #Testing if all the Azure site names in migration settings file are available
    Test-AzureSiteNames
} catch {
    Write-HostError "Error in validating settings in $MigrationSettingsFilePath : $($_.Exception.Message)"
    Write-HostError "Can't proceed to migration without validating settings, please test your internet connection and regenerate migration settings file and retry"
    Write-HostError "Migrations settings file can be generated by running Generate-MigrationSettings.ps1"
    exit 1
} 

# Only start creating resources after basic setting validation above completes successfully
foreach ($SettingsObject in $MigrationSettings) {
    $AppServicePlan = $SettingsObject.AppServicePlan
    $Region = $SettingsObject.Region
    $SubscriptionId = $SettingsObject.SubscriptionId
    $ResourceGroup = $SettingsObject.ResourceGroup
    $Tier = $SettingsObject.Tier
    $NumberOfWorkers = $SettingsObject.NumberOfWorkers
    $WorkerSize = $SettingsObject.WorkerSize
    $AppServiceEnvironment = $SettingsObject.AppServiceEnvironment

    $Sites = $SettingsObject.Sites;  

    Write-HostInfo "Creating App Service Plan '$AppServicePlan' resources"
    #Creates App service plan and other resources    
    try {
        #Set Azure account subscription
        $SetSubscription = Set-AzContext -SubscriptionId $SubscriptionId
    }
    catch {
        Write-HostError "Error setting subscription from Id: $($_.Exception.Message)"
        $ExceptionData = Get-ExceptionData -Exception $_.Exception
        Send-TelemetryEventIfEnabled -TelemetryTitle "Invoke-SiteMigration.ps1" -EventName "Error setting subscription" -ExceptionData $ExceptionData -EventType "error" -ErrorAction SilentlyContinue
        Write-AzureResourceResults -ResourceSummaryInfo $script:ResourcesCreated -MigrationResultsFilePath $MigrationResultsFilePath 
        exit 1
    }

    Write-HostInfo "Azure subscription has been set to $($SetSubscription.Subscription.Id) (Name: $($SetSubscription.Subscription.Name))"
    Send-TelemetryEventIfEnabled -TelemetryTitle "Invoke-SiteMigration.ps1" -EventName "Subscription was successfully set" -EventType "info" -Subscription $SubscriptionId -ErrorAction SilentlyContinue

    #Create Azure resource group if it doesn't already exist
    $GetResourceGroup = Get-AzResourceGroup -Name $ResourceGroup -ErrorVariable RscGrpNotFound -ErrorAction SilentlyContinue
    if ($RscGrpNotFound) {
        try {
            $NewResourceGroup = New-AzResourceGroup -Name $ResourceGroup -Location $Region -ErrorAction Stop
            $script:ResourcesCreated += Get-ResourceCreationResult -ResourceName $ResourceGroup -ResourceType "ResourceGroup" -Created $True
        }
        catch {
            Write-HostError "Error creating Resource Group: $($_.Exception.Message)"
            $ExceptionData = Get-ExceptionData -Exception $_.Exception
            Send-TelemetryEventIfEnabled -TelemetryTitle "Invoke-SiteMigration.ps1" -EventName "Resource Group creation failed" -EventMessage "Resource Group $ResourceGroup creation failed" -ExceptionData $ExceptionData -EventType "info" -Subscription $SubscriptionId -ResourceGroup $ResourceGroup -ErrorAction SilentlyContinue
            $script:ResourcesCreated += Get-ResourceCreationResult -ResourceName $ResourceGroup -ResourceType "ResourceGroup" -Created $False
            Write-AzureResourceResults -ResourceSummaryInfo $script:ResourcesCreated -MigrationResultsFilePath $MigrationResultsFilePath  
            exit 1
        }
        
        Write-HostInfo "Resource Group $($ResourceGroup) has been created in $($NewResourceGroup.Location)"
        Send-TelemetryEventIfEnabled -TelemetryTitle "Invoke-SiteMigration.ps1" -EventName "Resource Group created" -EventType "info" -Subscription $SubscriptionId -ResourceGroup $ResourceGroup -ErrorAction SilentlyContinue
    }
    else {
        Write-HostInfo "Resource Group $ResourceGroup found in $($GetResourceGroup.Location)"
        Send-TelemetryEventIfEnabled -TelemetryTitle "Invoke-SiteMigration.ps1" -EventName "Resource Group already existed" -EventType "info" -Subscription $SubscriptionId -ResourceGroup $ResourceGroup -ErrorAction SilentlyContinue
    }

    #Create Azure App Service Plan if it doesn't already exist
    $ExistingAppServicePlan = Get-AzAppServicePlan -ResourceGroupName $ResourceGroup -Name $AppServicePlan -ErrorAction Stop
        
    if ($ExistingAppServicePlan) {                       
        # don't need to create one
        Write-HostInfo "App Service Plan $($ExistingAppServicePlan.Name) found in resource group $($ExistingAppServicePlan.ResourceGroup)"
        Send-TelemetryEventIfEnabled -TelemetryTitle "Invoke-SiteMigration.ps1" -EventName "ASP pre-existing" -EventMessage "$($ExistingAppServicePlan.Name)" -EventType "info" -Subscription $SubscriptionId -ResourceGroup $ResourceGroup -ErrorAction SilentlyContinue 
        $Region = $ExistingAppServicePlan.Location
    }
    else {
        #ASP not found, creating new one in specifed region
        try {
            $InASELog = "";
            if ($AppServiceEnvironment) {      
                Send-TelemetryEventIfEnabled -TelemetryTitle "Invoke-SiteMigration.ps1" -EventName "ASE used" -EventMessage "$AppServiceEnvironment" -EventType "info" -ErrorAction SilentlyContinue      
                $InASELog = " in App Service Environment $AppServiceEnvironment"
                $ASEDetails = Get-AzResource -Name $AppServiceEnvironment -ResourceType Microsoft.Web/hostingEnvironments
                if($Region -and $AseDetails.Location -ne $Region) {
                    Write-HostWarn "Region '$Region' provided is different from App Service Environment '$AppServiceEnvironment' region $AseDetails.Location"
                    Write-HostWarn "Sites within '$AppServicePlan' will be migrated to  $AseDetails.Location"
                }           
                $ASEDetailsWithVer = Get-AzAppServiceEnvironment -Name $AppServiceEnvironment -ResourceGroupName $ASEDetails.ResourceGroupName
                if($ASEDetailsWithVer.Kind) {
                    if($ASEDetailsWithVer.Kind -eq "ASEV3" -and $Tier -ne "IsolatedV2") {
                        Write-HostWarn "ASE is v3 version which uses IsolatedV2 but Tier $Tier was specified - App Service Plan will be created using IsolatedV2 SKU"                    
                        $Tier = "IsolatedV2"
                    }
                    if($ASEDetailsWithVer.Kind -eq "ASEV2" -and $Tier -ne "Isolated") {
                        Write-HostWarn "ASE is v2 version which uses Isolated but Tier $Tier was specified - App Service Plan will be created using Isolated SKU"                    
                        $Tier = "Isolated"
                    }
                } else {
                    Write-HostWarn "Unable to get ASE version information, App Service Plan will be created using specified Tier of $Tier"                
                }
                Write-HostInfo "Creating App Service Plan $AppServicePlan in App Service Environment $AppServiceEnvironment ...."
                Write-HostInfo "This might take a while, especially if this is the first App service plan being created$InASELog"
                $NewAppServicePlan = New-AzAppServicePlan -Name $AppServicePlan -ResourceGroupName $ResourceGroup -Location $ASEDetails.Location -Tier $Tier -NumberofWorkers $NumberOfWorkers -WorkerSize $WorkerSize -AseName $AppServiceEnvironment -AseResourceGroupName $ASEDetails.ResourceGroupName -ErrorAction Stop 
            } else {
                Write-HostInfo "Creating App Service Plan $AppServicePlan ...."
                $NewAppServicePlan = New-AzAppServicePlan -ResourceGroupName $ResourceGroup -Name $AppServicePlan  -Location $Region -Tier $Tier -NumberofWorkers $NumberOfWorkers -WorkerSize $WorkerSize -ErrorAction Stop
            }
            $script:ResourcesCreated += Get-ResourceCreationResult -ResourceName $AppServicePlan -ResourceType "App Service Plan" -Created $True
        }
        catch {
            $ExceptionMsg = Get-AzExceptionMessage -Exception $_.Exception
            Write-HostError "Error creating $AppServicePlan$InASELog : $ExceptionMsg"
            $ExceptionData = Get-ExceptionData -Exception $ExceptionMsg  
            Send-TelemetryEventIfEnabled -TelemetryTitle "Invoke-SiteMigration.ps1" -EventName "Error creating ASP" -EventMessage "$AppServicePlan" -ExceptionData $ExceptionData -EventType "error" -ErrorAction SilentlyContinue -Subscription $SubscriptionId -ResourceGroup $ResourceGroup
            $script:ResourcesCreated += Get-ResourceCreationResult -ResourceName $AppServicePlan -ResourceType "App Service Plan" -Created $False -Error $ExceptionMsg
            Write-AzureResourceResults -ResourceSummaryInfo $script:ResourcesCreated -MigrationResultsFilePath $MigrationResultsFilePath 
            exit 1
        }
       
        Write-HostInfo "App Service Plan $($NewAppServicePlan.Name) has been created in resource group $($NewAppServicePlan.ResourceGroup)$InASELog"
        Send-TelemetryEventIfEnabled -TelemetryTitle "Invoke-SiteMigration.ps1" -EventName "ASP created" -EventMessage "$($NewAppServicePlan.Name)" -EventType "info" -Subscription $SubscriptionId -ResourceGroup $ResourceGroup -ErrorAction SilentlyContinue         
    }
	
    #Create sites within ASP
    foreach ($Site in $Sites) {
        $IISSiteName = $Site.IISSiteName
        $SitePackagePath = $Site.SitePackagePath
        # get full path to package files if relative to package results file
        if(-not ([System.IO.Path]::IsPathRooted($SitePackagePath))) {
            $fullPkgPath = Join-Path (Split-Path -Path $MigrationSettingsFilePath) $Site.SitePackagePath
            $SitePackagePath = $fullPkgPath
        }
        $AzureSiteName = $Site.AzureSiteName

        Send-TelemetryEventIfEnabled -TelemetryTitle "Invoke-SiteMigration.ps1" -EventName "Starting site migration" -EventType "info" -ErrorAction SilentlyContinue -Subscription $SubscriptionId -ResourceGroup $ResourceGroup -AzureSite $AzureSiteName
        Write-HostInfo "Migrating site '$IISSiteName' to Azure...."
        $SiteMigrationData = Invoke-SiteCreationAndDeployment -Region $Region -SubscriptionId $SubscriptionId -ResourceGroup $ResourceGroup -AppServicePlan $AppServicePlan -AppServiceEnvironment $AppServiceEnvironment -IISSiteName $IISSiteName -SitePackagePath $SitePackagePath -AzureSiteName $AzureSiteName        
        $script:ResourcesCreated += $SiteMigrationData
        Write-Host("") #cosmetic spacing
    }   
}


Write-AzureResourceResults -ResourceSummaryInfo $script:ResourcesCreated -MigrationResultsFilePath $MigrationResultsFilePath

Send-TelemetryEventIfEnabled -TelemetryTitle "Invoke-SiteMigration.ps1" -EventName "Script end" -EventType "action" -ErrorAction SilentlyContinue
return $script:ResourcesCreated



# SIG # Begin signature block
# MIIoVQYJKoZIhvcNAQcCoIIoRjCCKEICAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCCw8iWFkrE+ijtk
# 0B8itRtgs3w6/FAJecu0EOWQr3r+IaCCDYUwggYDMIID66ADAgECAhMzAAAEhJji
# EuB4ozFdAAAAAASEMA0GCSqGSIb3DQEBCwUAMH4xCzAJBgNVBAYTAlVTMRMwEQYD
# VQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNy
# b3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMTH01pY3Jvc29mdCBDb2RlIFNpZ25p
# bmcgUENBIDIwMTEwHhcNMjUwNjE5MTgyMTM1WhcNMjYwNjE3MTgyMTM1WjB0MQsw
# CQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9u
# ZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMR4wHAYDVQQDExVNaWNy
# b3NvZnQgQ29ycG9yYXRpb24wggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIB
# AQDtekqMKDnzfsyc1T1QpHfFtr+rkir8ldzLPKmMXbRDouVXAsvBfd6E82tPj4Yz
# aSluGDQoX3NpMKooKeVFjjNRq37yyT/h1QTLMB8dpmsZ/70UM+U/sYxvt1PWWxLj
# MNIXqzB8PjG6i7H2YFgk4YOhfGSekvnzW13dLAtfjD0wiwREPvCNlilRz7XoFde5
# KO01eFiWeteh48qUOqUaAkIznC4XB3sFd1LWUmupXHK05QfJSmnei9qZJBYTt8Zh
# ArGDh7nQn+Y1jOA3oBiCUJ4n1CMaWdDhrgdMuu026oWAbfC3prqkUn8LWp28H+2S
# LetNG5KQZZwvy3Zcn7+PQGl5AgMBAAGjggGCMIIBfjAfBgNVHSUEGDAWBgorBgEE
# AYI3TAgBBggrBgEFBQcDAzAdBgNVHQ4EFgQUBN/0b6Fh6nMdE4FAxYG9kWCpbYUw
# VAYDVR0RBE0wS6RJMEcxLTArBgNVBAsTJE1pY3Jvc29mdCBJcmVsYW5kIE9wZXJh
# dGlvbnMgTGltaXRlZDEWMBQGA1UEBRMNMjMwMDEyKzUwNTM2MjAfBgNVHSMEGDAW
# gBRIbmTlUAXTgqoXNzcitW2oynUClTBUBgNVHR8ETTBLMEmgR6BFhkNodHRwOi8v
# d3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NybC9NaWNDb2RTaWdQQ0EyMDExXzIw
# MTEtMDctMDguY3JsMGEGCCsGAQUFBwEBBFUwUzBRBggrBgEFBQcwAoZFaHR0cDov
# L3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9jZXJ0cy9NaWNDb2RTaWdQQ0EyMDEx
# XzIwMTEtMDctMDguY3J0MAwGA1UdEwEB/wQCMAAwDQYJKoZIhvcNAQELBQADggIB
# AGLQps1XU4RTcoDIDLP6QG3NnRE3p/WSMp61Cs8Z+JUv3xJWGtBzYmCINmHVFv6i
# 8pYF/e79FNK6P1oKjduxqHSicBdg8Mj0k8kDFA/0eU26bPBRQUIaiWrhsDOrXWdL
# m7Zmu516oQoUWcINs4jBfjDEVV4bmgQYfe+4/MUJwQJ9h6mfE+kcCP4HlP4ChIQB
# UHoSymakcTBvZw+Qst7sbdt5KnQKkSEN01CzPG1awClCI6zLKf/vKIwnqHw/+Wvc
# Ar7gwKlWNmLwTNi807r9rWsXQep1Q8YMkIuGmZ0a1qCd3GuOkSRznz2/0ojeZVYh
# ZyohCQi1Bs+xfRkv/fy0HfV3mNyO22dFUvHzBZgqE5FbGjmUnrSr1x8lCrK+s4A+
# bOGp2IejOphWoZEPGOco/HEznZ5Lk6w6W+E2Jy3PHoFE0Y8TtkSE4/80Y2lBJhLj
# 27d8ueJ8IdQhSpL/WzTjjnuYH7Dx5o9pWdIGSaFNYuSqOYxrVW7N4AEQVRDZeqDc
# fqPG3O6r5SNsxXbd71DCIQURtUKss53ON+vrlV0rjiKBIdwvMNLQ9zK0jy77owDy
# XXoYkQxakN2uFIBO1UNAvCYXjs4rw3SRmBX9qiZ5ENxcn/pLMkiyb68QdwHUXz+1
# fI6ea3/jjpNPz6Dlc/RMcXIWeMMkhup/XEbwu73U+uz/MIIHejCCBWKgAwIBAgIK
# YQ6Q0gAAAAAAAzANBgkqhkiG9w0BAQsFADCBiDELMAkGA1UEBhMCVVMxEzARBgNV
# BAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jv
# c29mdCBDb3Jwb3JhdGlvbjEyMDAGA1UEAxMpTWljcm9zb2Z0IFJvb3QgQ2VydGlm
# aWNhdGUgQXV0aG9yaXR5IDIwMTEwHhcNMTEwNzA4MjA1OTA5WhcNMjYwNzA4MjEw
# OTA5WjB+MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UE
# BxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSgwJgYD
# VQQDEx9NaWNyb3NvZnQgQ29kZSBTaWduaW5nIFBDQSAyMDExMIICIjANBgkqhkiG
# 9w0BAQEFAAOCAg8AMIICCgKCAgEAq/D6chAcLq3YbqqCEE00uvK2WCGfQhsqa+la
# UKq4BjgaBEm6f8MMHt03a8YS2AvwOMKZBrDIOdUBFDFC04kNeWSHfpRgJGyvnkmc
# 6Whe0t+bU7IKLMOv2akrrnoJr9eWWcpgGgXpZnboMlImEi/nqwhQz7NEt13YxC4D
# dato88tt8zpcoRb0RrrgOGSsbmQ1eKagYw8t00CT+OPeBw3VXHmlSSnnDb6gE3e+
# lD3v++MrWhAfTVYoonpy4BI6t0le2O3tQ5GD2Xuye4Yb2T6xjF3oiU+EGvKhL1nk
# kDstrjNYxbc+/jLTswM9sbKvkjh+0p2ALPVOVpEhNSXDOW5kf1O6nA+tGSOEy/S6
# A4aN91/w0FK/jJSHvMAhdCVfGCi2zCcoOCWYOUo2z3yxkq4cI6epZuxhH2rhKEmd
# X4jiJV3TIUs+UsS1Vz8kA/DRelsv1SPjcF0PUUZ3s/gA4bysAoJf28AVs70b1FVL
# 5zmhD+kjSbwYuER8ReTBw3J64HLnJN+/RpnF78IcV9uDjexNSTCnq47f7Fufr/zd
# sGbiwZeBe+3W7UvnSSmnEyimp31ngOaKYnhfsi+E11ecXL93KCjx7W3DKI8sj0A3
# T8HhhUSJxAlMxdSlQy90lfdu+HggWCwTXWCVmj5PM4TasIgX3p5O9JawvEagbJjS
# 4NaIjAsCAwEAAaOCAe0wggHpMBAGCSsGAQQBgjcVAQQDAgEAMB0GA1UdDgQWBBRI
# bmTlUAXTgqoXNzcitW2oynUClTAZBgkrBgEEAYI3FAIEDB4KAFMAdQBiAEMAQTAL
# BgNVHQ8EBAMCAYYwDwYDVR0TAQH/BAUwAwEB/zAfBgNVHSMEGDAWgBRyLToCMZBD
# uRQFTuHqp8cx0SOJNDBaBgNVHR8EUzBRME+gTaBLhklodHRwOi8vY3JsLm1pY3Jv
# c29mdC5jb20vcGtpL2NybC9wcm9kdWN0cy9NaWNSb29DZXJBdXQyMDExXzIwMTFf
# MDNfMjIuY3JsMF4GCCsGAQUFBwEBBFIwUDBOBggrBgEFBQcwAoZCaHR0cDovL3d3
# dy5taWNyb3NvZnQuY29tL3BraS9jZXJ0cy9NaWNSb29DZXJBdXQyMDExXzIwMTFf
# MDNfMjIuY3J0MIGfBgNVHSAEgZcwgZQwgZEGCSsGAQQBgjcuAzCBgzA/BggrBgEF
# BQcCARYzaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9kb2NzL3ByaW1h
# cnljcHMuaHRtMEAGCCsGAQUFBwICMDQeMiAdAEwAZQBnAGEAbABfAHAAbwBsAGkA
# YwB5AF8AcwB0AGEAdABlAG0AZQBuAHQALiAdMA0GCSqGSIb3DQEBCwUAA4ICAQBn
# 8oalmOBUeRou09h0ZyKbC5YR4WOSmUKWfdJ5DJDBZV8uLD74w3LRbYP+vj/oCso7
# v0epo/Np22O/IjWll11lhJB9i0ZQVdgMknzSGksc8zxCi1LQsP1r4z4HLimb5j0b
# pdS1HXeUOeLpZMlEPXh6I/MTfaaQdION9MsmAkYqwooQu6SpBQyb7Wj6aC6VoCo/
# KmtYSWMfCWluWpiW5IP0wI/zRive/DvQvTXvbiWu5a8n7dDd8w6vmSiXmE0OPQvy
# CInWH8MyGOLwxS3OW560STkKxgrCxq2u5bLZ2xWIUUVYODJxJxp/sfQn+N4sOiBp
# mLJZiWhub6e3dMNABQamASooPoI/E01mC8CzTfXhj38cbxV9Rad25UAqZaPDXVJi
# hsMdYzaXht/a8/jyFqGaJ+HNpZfQ7l1jQeNbB5yHPgZ3BtEGsXUfFL5hYbXw3MYb
# BL7fQccOKO7eZS/sl/ahXJbYANahRr1Z85elCUtIEJmAH9AAKcWxm6U/RXceNcbS
# oqKfenoi+kiVH6v7RyOA9Z74v2u3S5fi63V4GuzqN5l5GEv/1rMjaHXmr/r8i+sL
# gOppO6/8MO0ETI7f33VtY5E90Z1WTk+/gFcioXgRMiF670EKsT/7qMykXcGhiJtX
# cVZOSEXAQsmbdlsKgEhr/Xmfwb1tbWrJUnMTDXpQzTGCGiYwghoiAgEBMIGVMH4x
# CzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRt
# b25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMTH01p
# Y3Jvc29mdCBDb2RlIFNpZ25pbmcgUENBIDIwMTECEzMAAASEmOIS4HijMV0AAAAA
# BIQwDQYJYIZIAWUDBAIBBQCgga4wGQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQw
# HAYKKwYBBAGCNwIBCzEOMAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEIOD7
# xpZ9r0CzpMT5Ph/yyUnIzDb28Ws6e5rd5qpie542MEIGCisGAQQBgjcCAQwxNDAy
# oBSAEgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8vd3d3Lm1pY3Jvc29mdC5j
# b20wDQYJKoZIhvcNAQEBBQAEggEArKyENGvt7GLcIxfu5z1OTNyDOL/e4Mu+lzlC
# WPYyJ1dj4n9JzDDq+BmO58/f+aJt5CObt84NJ+/87NBT4NCuD5YdF1XRVKYF2TyZ
# OlnegRVZdp1YAechOvuTsqiXNYbVqn/ESXmmJHrHDnaNazjvULtTxBtrfAjSJeXL
# wrgCG0ifE0yvnTzTDeydJeNOxkqTZqOvThGDDTcVOj9O/DokfWvTas114DrkBF0g
# i7YaeggFameMwPJ5QIYmf/ZmmSKAPqRRHLwi0rE0z9VhP73b+Crr+Z+aq0pORJLx
# OCFh8/mWi2oziDvX8ANUo/hcAOUs5wNXAhjI0Cg6xESkzBSqBKGCF7AwghesBgor
# BgEEAYI3AwMBMYIXnDCCF5gGCSqGSIb3DQEHAqCCF4kwgheFAgEDMQ8wDQYJYIZI
# AWUDBAIBBQAwggFaBgsqhkiG9w0BCRABBKCCAUkEggFFMIIBQQIBAQYKKwYBBAGE
# WQoDATAxMA0GCWCGSAFlAwQCAQUABCDvhaDB3JLsCMVH5TyKEMTh9hqVwZmgNecL
# FfoihTJ1gwIGaR4BnI4PGBMyMDI1MTEyNTAwMjEwOS44MzRaMASAAgH0oIHZpIHW
# MIHTMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMH
# UmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMS0wKwYDVQQL
# EyRNaWNyb3NvZnQgSXJlbGFuZCBPcGVyYXRpb25zIExpbWl0ZWQxJzAlBgNVBAsT
# Hm5TaGllbGQgVFNTIEVTTjo2NTFBLTA1RTAtRDk0NzElMCMGA1UEAxMcTWljcm9z
# b2Z0IFRpbWUtU3RhbXAgU2VydmljZaCCEf4wggcoMIIFEKADAgECAhMzAAACFRgD
# 04EHJnxTAAEAAAIVMA0GCSqGSIb3DQEBCwUAMHwxCzAJBgNVBAYTAlVTMRMwEQYD
# VQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNy
# b3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1w
# IFBDQSAyMDEwMB4XDTI1MDgxNDE4NDgyMFoXDTI2MTExMzE4NDgyMFowgdMxCzAJ
# BgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25k
# MR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xLTArBgNVBAsTJE1pY3Jv
# c29mdCBJcmVsYW5kIE9wZXJhdGlvbnMgTGltaXRlZDEnMCUGA1UECxMeblNoaWVs
# ZCBUU1MgRVNOOjY1MUEtMDVFMC1EOTQ3MSUwIwYDVQQDExxNaWNyb3NvZnQgVGlt
# ZS1TdGFtcCBTZXJ2aWNlMIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEA
# w3HV3hVxL0lEYPV03XeNKZ517VIbgexhlDPdpXwDS0BYtxPwi4XYpZR1ld0u6cr2
# Xjuugdg50DUx5WHL0QhY2d9vkJSk02rE/75hcKt91m2Ih287QRxRMmFu3BF6466k
# 8qp5uXtfe6uciq49YaS8p+dzv3uTarD4hQ8UT7La95pOJiRqxxd0qOGLECvHLEXP
# XioNSx9pyhzhm6lt7ezLxJeFVYtxShkavPoZN0dOCiYeh4KgoKoyagzMuSiLCiMU
# W4Ue4Qsm658FJNGTNh7V5qXYVA6k5xjw5WeWdKOz0i9A5jBcbY9fVOo/cA8i1byt
# zcDTxb3nctcly8/OYeNstkab/Isq3Cxe1vq96fIHE1+ZGmJjka1sodwqPycVp/2t
# b+BjulPL5D6rgUXTPF84U82RLKHV57bB8fHRpgnjcWBQuXPgVeSXpERWimt0NF2l
# COLzqgrvS/vYqde5Ln9YlKKhAZ/xDE0TLIIr6+I/2JTtXP34nfjTENVqMBISWcak
# IxAwGb3RB5yHCxynIFNVLcfKAsEdC5U2em0fAvmVv0sonqnv17cuaYi2eCLWhoK1
# Ic85Dw7s/lhcXrBpY4n/Rl5l3wHzs4vOIhu87DIy5QUaEupEsyY0NWqgI4BWl6v1
# wgse+l8DWFeUXofhUuCgVTuTHN3K8idoMbn8Q3edUIECAwEAAaOCAUkwggFFMB0G
# A1UdDgQWBBSJIXfxcqAwFqGj9jdwQtdSqadj1zAfBgNVHSMEGDAWgBSfpxVdAF5i
# XYP05dJlpxtTNRnpcjBfBgNVHR8EWDBWMFSgUqBQhk5odHRwOi8vd3d3Lm1pY3Jv
# c29mdC5jb20vcGtpb3BzL2NybC9NaWNyb3NvZnQlMjBUaW1lLVN0YW1wJTIwUENB
# JTIwMjAxMCgxKS5jcmwwbAYIKwYBBQUHAQEEYDBeMFwGCCsGAQUFBzAChlBodHRw
# Oi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NlcnRzL01pY3Jvc29mdCUyMFRp
# bWUtU3RhbXAlMjBQQ0ElMjAyMDEwKDEpLmNydDAMBgNVHRMBAf8EAjAAMBYGA1Ud
# JQEB/wQMMAoGCCsGAQUFBwMIMA4GA1UdDwEB/wQEAwIHgDANBgkqhkiG9w0BAQsF
# AAOCAgEAd42HtV+kGbvxzLBTC5O7vkCIBPy/BwpjCzeL53hAiEOebp+VdNnwm9GV
# CfYq3KMfrj4UvKQTUAaS5Zkwe1gvZ3ljSSnCOyS5OwNu9dpg3ww+QW2eOcSLkyVA
# WFrLn6Iig3TC/zWMvVhqXtdFhG2KJ1lSbN222csY3E3/BrGluAlvET9gmxVyyxNy
# 59/7JF5zIGcJibydxs94JL1BtPgXJOfZzQ+/3iTc6eDtmaWT6DKdnJocp8wkXKWP
# IsBEfkD6k1Qitwvt0mHrORah75SjecOKt4oWayVLkPTho12e0ongEg1cje5fxSZG
# thrMrWKvI4R7HEC7k8maH9ePA3ViH0CVSSOefaPTGMzIhHCo5p3jG5SMcyO3eA9u
# EaYQJITJlLG3BwwGmypY7C/8/nj1SOhgx1HgJ0ywOJL9xfP4AOcWmCfbsqgGbCaC
# 7WH5sINdzfMar8V7YNFqkbCGUKhc8GpIyE+MKnyVn33jsuaGAlNRg7dVRUSoYLJx
# vUsw9GOwyBpBwbE9sqOLm+HsO00oF23PMio7WFXcFTZAjp3ujihBAfLrXICgGOHP
# dkZ042u1LZqOcnlr3XzvgMe+mPPyasW8f0rtzJj3V5E/EKiyQlPxj9Mfq2x9himn
# lXWGZCVPeEBROrNbDYBfazTyLNCOTsRtksOSV3FBtPnpQtLN754wggdxMIIFWaAD
# AgECAhMzAAAAFcXna54Cm0mZAAAAAAAVMA0GCSqGSIb3DQEBCwUAMIGIMQswCQYD
# VQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEe
# MBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMTIwMAYDVQQDEylNaWNyb3Nv
# ZnQgUm9vdCBDZXJ0aWZpY2F0ZSBBdXRob3JpdHkgMjAxMDAeFw0yMTA5MzAxODIy
# MjVaFw0zMDA5MzAxODMyMjVaMHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNo
# aW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29y
# cG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEw
# MIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEA5OGmTOe0ciELeaLL1yR5
# vQ7VgtP97pwHB9KpbE51yMo1V/YBf2xK4OK9uT4XYDP/XE/HZveVU3Fa4n5KWv64
# NmeFRiMMtY0Tz3cywBAY6GB9alKDRLemjkZrBxTzxXb1hlDcwUTIcVxRMTegCjhu
# je3XD9gmU3w5YQJ6xKr9cmmvHaus9ja+NSZk2pg7uhp7M62AW36MEBydUv626GIl
# 3GoPz130/o5Tz9bshVZN7928jaTjkY+yOSxRnOlwaQ3KNi1wjjHINSi947SHJMPg
# yY9+tVSP3PoFVZhtaDuaRr3tpK56KTesy+uDRedGbsoy1cCGMFxPLOJiss254o2I
# 5JasAUq7vnGpF1tnYN74kpEeHT39IM9zfUGaRnXNxF803RKJ1v2lIH1+/NmeRd+2
# ci/bfV+AutuqfjbsNkz2K26oElHovwUDo9Fzpk03dJQcNIIP8BDyt0cY7afomXw/
# TNuvXsLz1dhzPUNOwTM5TI4CvEJoLhDqhFFG4tG9ahhaYQFzymeiXtcodgLiMxhy
# 16cg8ML6EgrXY28MyTZki1ugpoMhXV8wdJGUlNi5UPkLiWHzNgY1GIRH29wb0f2y
# 1BzFa/ZcUlFdEtsluq9QBXpsxREdcu+N+VLEhReTwDwV2xo3xwgVGD94q0W29R6H
# XtqPnhZyacaue7e3PmriLq0CAwEAAaOCAd0wggHZMBIGCSsGAQQBgjcVAQQFAgMB
# AAEwIwYJKwYBBAGCNxUCBBYEFCqnUv5kxJq+gpE8RjUpzxD/LwTuMB0GA1UdDgQW
# BBSfpxVdAF5iXYP05dJlpxtTNRnpcjBcBgNVHSAEVTBTMFEGDCsGAQQBgjdMg30B
# ATBBMD8GCCsGAQUFBwIBFjNodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3Bz
# L0RvY3MvUmVwb3NpdG9yeS5odG0wEwYDVR0lBAwwCgYIKwYBBQUHAwgwGQYJKwYB
# BAGCNxQCBAweCgBTAHUAYgBDAEEwCwYDVR0PBAQDAgGGMA8GA1UdEwEB/wQFMAMB
# Af8wHwYDVR0jBBgwFoAU1fZWy4/oolxiaNE9lJBb186aGMQwVgYDVR0fBE8wTTBL
# oEmgR4ZFaHR0cDovL2NybC5taWNyb3NvZnQuY29tL3BraS9jcmwvcHJvZHVjdHMv
# TWljUm9vQ2VyQXV0XzIwMTAtMDYtMjMuY3JsMFoGCCsGAQUFBwEBBE4wTDBKBggr
# BgEFBQcwAoY+aHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraS9jZXJ0cy9NaWNS
# b29DZXJBdXRfMjAxMC0wNi0yMy5jcnQwDQYJKoZIhvcNAQELBQADggIBAJ1Vffwq
# reEsH2cBMSRb4Z5yS/ypb+pcFLY+TkdkeLEGk5c9MTO1OdfCcTY/2mRsfNB1OW27
# DzHkwo/7bNGhlBgi7ulmZzpTTd2YurYeeNg2LpypglYAA7AFvonoaeC6Ce5732pv
# vinLbtg/SHUB2RjebYIM9W0jVOR4U3UkV7ndn/OOPcbzaN9l9qRWqveVtihVJ9Ak
# vUCgvxm2EhIRXT0n4ECWOKz3+SmJw7wXsFSFQrP8DJ6LGYnn8AtqgcKBGUIZUnWK
# NsIdw2FzLixre24/LAl4FOmRsqlb30mjdAy87JGA0j3mSj5mO0+7hvoyGtmW9I/2
# kQH2zsZ0/fZMcm8Qq3UwxTSwethQ/gpY3UA8x1RtnWN0SCyxTkctwRQEcb9k+SS+
# c23Kjgm9swFXSVRk2XPXfx5bRAGOWhmRaw2fpCjcZxkoJLo4S5pu+yFUa2pFEUep
# 8beuyOiJXk+d0tBMdrVXVAmxaQFEfnyhYWxz/gq77EFmPWn9y8FBSX5+k77L+Dvk
# txW/tM4+pTFRhLy/AsGConsXHRWJjXD+57XQKBqJC4822rpM+Zv/Cuk0+CQ1Zyvg
# DbjmjJnW4SLq8CdCPSWU5nR0W2rRnj7tfqAxM328y+l7vzhwRNGQ8cirOoo6CGJ/
# 2XBjU02N7oJtpQUQwXEGahC0HVUzWLOhcGbyoYIDWTCCAkECAQEwggEBoYHZpIHW
# MIHTMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMH
# UmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMS0wKwYDVQQL
# EyRNaWNyb3NvZnQgSXJlbGFuZCBPcGVyYXRpb25zIExpbWl0ZWQxJzAlBgNVBAsT
# Hm5TaGllbGQgVFNTIEVTTjo2NTFBLTA1RTAtRDk0NzElMCMGA1UEAxMcTWljcm9z
# b2Z0IFRpbWUtU3RhbXAgU2VydmljZaIjCgEBMAcGBSsOAwIaAxUAj6eTejbuYE1I
# fjbfrt6tXevCUSCggYMwgYCkfjB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2Fz
# aGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENv
# cnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAx
# MDANBgkqhkiG9w0BAQsFAAIFAOzPF0cwIhgPMjAyNTExMjQxNzQxMjdaGA8yMDI1
# MTEyNTE3NDEyN1owdzA9BgorBgEEAYRZCgQBMS8wLTAKAgUA7M8XRwIBADAKAgEA
# AgIe9QIB/zAHAgEAAgISZzAKAgUA7NBoxwIBADA2BgorBgEEAYRZCgQCMSgwJjAM
# BgorBgEEAYRZCgMCoAowCAIBAAIDB6EgoQowCAIBAAIDAYagMA0GCSqGSIb3DQEB
# CwUAA4IBAQB3IEpwWiN2VdcVz3seNc9r8rK88d4KxvWbJwU61XSLFzTBuV4Mujkw
# l72SWAecgH0jcNbdQJMq/voK6hCh5xmwzz7duMT68YPK7toDQjdoosB19kD5MgUR
# dYhfNjvkx2wZksT/50/ezPy/7vE9fcbNKlliKyW19OvdbH2/94reeh243uvraNfj
# J08Jp6XEktL277vo7howqnHS8RJA+Z+m8rIqpb0ivb3Dn0QgpAYGh+P01XwUwO5g
# 5vqUUKs2+lbQfiG5X851mNkRq72jArF1+RoIUx1GVIcVHxdLbib7VMs8yWNp89RE
# 6yMhN3KDBYp14fOfdDOV7hbQtDbdg4L1MYIEDTCCBAkCAQEwgZMwfDELMAkGA1UE
# BhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAc
# BgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0
# IFRpbWUtU3RhbXAgUENBIDIwMTACEzMAAAIVGAPTgQcmfFMAAQAAAhUwDQYJYIZI
# AWUDBAIBBQCgggFKMBoGCSqGSIb3DQEJAzENBgsqhkiG9w0BCRABBDAvBgkqhkiG
# 9w0BCQQxIgQgmITSqqGuSLnq3BlIuP/YA0Zc+1y1jFedl/x7iFMbxIIwgfoGCyqG
# SIb3DQEJEAIvMYHqMIHnMIHkMIG9BCBwEPR2PDrTFLcrtQsKrUi7oz5JNRCF/KRH
# MihSNe7sijCBmDCBgKR+MHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5n
# dG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9y
# YXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwAhMz
# AAACFRgD04EHJnxTAAEAAAIVMCIEIHlIdDyUemndhdf9rE9wyXeWUki/TwVuQt8p
# +duA0V5eMA0GCSqGSIb3DQEBCwUABIICADWBEbc2h6DiyWbopIAx2Nfi4sSvlI2J
# wBw25BD/gS0M+Fl/Im84lLWTOblIFFwS6UojENoI2KnIUNJ2UQ5Gws7KFaZLSe/6
# 74DvsKNZQLU0LAeyZ5qEMpVgleTt32Ewx9eG1Ico113PvyM+Hv2p+B7L+37Wmbx8
# gXhwLN6fx9xkdLDT+PN1y4R75e4ttDtm5kbzaITpqtVSSKttDPccp1fpgYDJMSU6
# pek+IOY5mWRxE9B5H8W4QNInnHFxVJppFHGj9UZAb3y2Wuuu9uz/W6kFbxBxclOE
# Z57EHd7M6D4TkxnEKi0ui91L62Mx7K11VcNcjMqY8W40NvNC6UCzVfQzUQNF2Esm
# D2wo3e9ICeglX8JDmm7oqGsaFou+REVj3B1d9zVHNvadwLbFeF279Jn7M7PwI2SG
# LEKxTHVNjcPTfGzr6VvgtEx0jyPJKd6gVmXb1PzNZfOua6MenraQmDGAWqJiCWPL
# yKE8TWJ7EMvahUtYKN1NoU38+zQElwjd55TMpBRAaE3pOUeup5salX6YQeRIPLqQ
# Y9zshxRP4QNXqPDyQwRDFIaFPrsSQxxp6obaWfeJ2c+Zq/N9orPeP09GsRWfffoc
# Ri6ayQ5j9d1STi0VpEagMqD1m154xztf96UdA9yW2GjAo8VmHULhiXqVLklOkTRX
# WLOvjB7RDwTj
# SIG # End signature block
