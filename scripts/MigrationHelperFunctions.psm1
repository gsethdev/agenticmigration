#App Service Migration Assistant Scripts - Helper functions module

#Get the script configuration info
function Get-ScriptConfig() {
    $ScriptConfigPath = Join-Path $PSScriptRoot "ScriptConfig.json"
    if (!(Test-Path -Path $ScriptConfigPath)) {
        Write-Host "Script configuration file not found!" -ForegroundColor Red -BackgroundColor Black
        exit
    }

    return (Get-Content -Path $ScriptConfigPath -Raw | ConvertFrom-Json)
}

function Send-TelemetryEventIfEnabled() {
#Logs an anonymized event in App Insights
param(
    [Parameter(Mandatory)]
    [string]$TelemetryTitle,

    [Parameter(Mandatory)]
    [string]$EventName,

    [Parameter(Mandatory)]
    [ValidateSet("info", "warn", "action", "error")]
    [string]$EventType,

    [Parameter()]
    [string]$EventMessage,

    [Parameter()]
    [Hashtable]$ExceptionData,

    [Parameter()]
    [string]$Subscription,

    [Parameter()]
    [string]$ResourceGroup,

    [Parameter()]
    [string]$AzureSite
)

    try {       
        $ScriptConfig = Get-ScriptConfig
        if ($ScriptConfig.EnableTelemetry) {
            Add-Type -Path (Join-Path $PSScriptRoot "Microsoft.ApplicationInsights.dll")
            $EventData =  New-Object "System.Collections.Generic.Dictionary[string,string]"
        
            if (!$MigrationScriptsTelemetryClient) {
                $InstrumentKey = $ScriptConfig.TelemetryInstrumentKey
        
                #Gets the machine's crypto GUID, hashes it (SHA256), and reformats it
                $MachineGUID = (Get-ItemProperty "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Cryptography").MachineGuid
                $StringAsStream = [System.IO.MemoryStream]::new()
                $Writer = [System.IO.StreamWriter]::new($StringAsStream)
                $Writer.write($MachineGUID)
                $Writer.Flush()
                $StringAsStream.Position = 0
                $MachineGUID = (Get-FileHash -InputStream $StringAsStream).Hash
                $MachineGUID = ($MachineGUID.Substring(0, 8) + '-' + $MachineGUID.Substring(8, 4) + '-4' + $MachineGUID.Substring(13, 3) + '-' + $MachineGUID.Substring(16, 4) + '-' + $MachineGUID.Substring(20, 12))
        
                #Gets the hashed MachineGUID and appends PS Session/Instance ID to it ($PID)
                $SessionGUID = New-Guid
        
                #Create new TelemetryClient from Microsoft.ApplicationInsights.dll library
                $Global:MigrationScriptsTelemetryClient = New-Object Microsoft.ApplicationInsights.TelemetryClient
                $MigrationScriptsTelemetryClient.InstrumentationKey = $InstrumentKey
        
                #Set allowed tags and zero out those that aren't
                $TagAllowList = @(
                    'Location.Ip',
                    'Component.Version',
                    'User.Id',
                    'Session.Id',
                    'Operation.ParentId',
                    'Operation.Name',
                    'Device.OperatingSystem',
                    'Device.Type'
                );
        
                #Remove unnecessary/unwanted telemetry info
                foreach ($Section in $MigrationScriptsTelemetryClient.Context) {
                    foreach ($Tag in $Section) {
                        if (!$TagAllowList.Contains("$Section.$Tag")) {
                            $Tag = ""
                        }
                    }
                }
        
                #Set various information for the event to be logged
                $MigrationScriptsTelemetryClient.Context.Location.Ip = "127.0.0.1"
                $MigrationScriptsTelemetryClient.Context.Component.Version = $ScriptConfig.ScriptsVersion
                $MigrationScriptsTelemetryClient.Context.User.Id = $MachineGUID
                $MigrationScriptsTelemetryClient.Context.Session.Id = $SessionGUID
            }
        
            $MigrationScriptsTelemetryClient.Context.Operation.ParentId = $TelemetryTitle
            $MigrationScriptsTelemetryClient.Context.Operation.Name = $EventType
        
            #Add Azure info to the event if it was passed
            if ($Subscription) {
                $EventData["subscriptionId"] = $Subscription
            }
        
            if ($ResourceGroup) {
                $EventData["resourceGroupName"] = $ResourceGroup
            }
        
            if ($AzureSite) {
                $EventData["siteName"] = $AzureSite
            }
        
            if ($EventMessage) {
                $EventData["message"] = $EventMessage
            }
        
            if ($ExceptionData) {
                $EventData["HResult"] = $ExceptionData["HResult"]
                $EventData["ExceptionMessage"] = $ExceptionData["ExceptionMessage"]
                $EventData["StackTrace"] = $ExceptionData["StackTrace"]
            }
        
            $MigrationScriptsTelemetryClient.TrackEvent($EventName, $EventData, $null)
        }
    }
    catch {
        #fail without blocking. Logging is best-effort and should never block local functionality
        #Write-HostInfo -Message "Error logging telemetry : $($_.Exception.Message)"  
    }
}


function Write-HostError() {
    param(
        [Parameter()]
        [string]$Message
    )
    Write-Host "[ERROR] $Message" -ForegroundColor Red -BackgroundColor Black
}

function Write-HostInfo() {
    param(
        [Parameter()]
        [string]$Message,

        [Parameter()]
        [switch] $MakeTextGreen
    )

    if ($MakeTextGreen) {
        Write-Host "[INFO] $Message" -ForegroundColor Green
    } else {
        Write-Host "[INFO] $Message" 
    }
    
}

function Write-HostWarn() {
    param(
        [Parameter()]
        [string]$Message
    )
    Write-Host "[WARN] $Message" -ForegroundColor Yellow -BackgroundColor Black
}


#Used to read assessment data and site config from the site .zip
function Get-ZippedFileContents() {
    param(
        [Parameter()]
        [string]$ZipPath,

        [Parameter()]
        [string]$NameOfFile
    )

    $ZipFile = [IO.Compression.ZipFile]::OpenRead((Convert-Path $ZipPath))
    $File = $ZipFile.Entries | Where-Object {$_.Name -eq $NameOfFile}
    if ($File) {
        $Stream = $File.Open()
    
        $Reader = New-Object IO.StreamReader($Stream)
        $Content = $Reader.ReadToEnd()
    
        $Reader.Close()
        $Stream.Close()
        $ZipFile.Dispose()
    
        return $Content
    }
 
}

function Initialize-LoginToAzure {
    try {
        if (!((Get-AzContext).Account)) {
            $ScriptConfig = Get-ScriptConfig
            if ($ScriptConfig.Environment) {
                $LoginToAzure = Connect-AzAccount -Environment $ScriptConfig.Environment
            }
            else {
                $LoginToAzure = Connect-AzAccount
            }        
        }
    }
    catch {
        Write-HostError $_.Exception.Message 
        Write-HostError "You must have Azure PowerShell to run this script, more information on installing Azure PowerShell at this link: https://go.microsoft.com/fwlink/?linkid=2218757"
		Write-HostError "Migration setting generation and migration may be completed on an alternate server."
        Send-TelemetryEventIfEnabled -TelemetryTitle "MigrationHelperFunctions.psm1" -EventName "Azure PowerShell wasn't installed" -EventType "error" -ErrorAction SilentlyContinue
        exit 1
    }
}

function Test-InternetConnectivity {
    try {
        [void] (Get-AzureAccessToken -ErrorAction Stop)
    }
    catch {
        if(Test-Connection bing.com -Quiet) {
            return;
        }
        else {
            Write-HostError "Outgoing connections may be limited. Please connect to an internet network and try again. May also try running Get-AzContext in same session before running script."
            exit 1
        }
    }
}

#Below is the current method of obtaining an ARM access token through a logged-in Azure PS session
function Get-AzureAccessToken() {
    $AzureProfile = [Microsoft.Azure.Commands.Common.Authentication.Abstractions.AzureRmProfileProvider]::Instance.Profile
    $AzureContext = Get-AzContext
    $ProfileClient = New-Object Microsoft.Azure.Commands.ResourceManager.Common.RMProfileClient($AzureProfile)
    return ($ProfileClient.AcquireAccessToken($AzureContext.Tenant.TenantId)).AccessToken
}

function Get-AzureSiteNameAvailability() {
    param(
        [Parameter()]
        [string]$SiteName,

        [Parameter()]
        [string]$AzureSubscriptionId
    )

    $AzContext = Get-AzContext 
    $AccessToken = Get-AzureAccessToken
    $Uri = "$($AzContext.Environment.ResourceManagerUrl)/subscriptions/$AzureSubscriptionId/providers/microsoft.web/checknameavailability?api-version=2019-08-01"
    $ReqHeader = @{
        'Content-Type' = 'application/json'
        'Authorization' = "Bearer $AccessToken"
    }

    $ReqBody = "{ ""name"": ""$SiteName"", ""type"": ""Microsoft.Web/sites""}"

    $ARMNameAvailabilityResponse = Invoke-RestMethod -Uri $Uri -Headers $ReqHeader -Body $ReqBody -Method "POST"
    
    return $ARMNameAvailabilityResponse
}

function Get-ExceptionData() {
    param(
        [Parameter()]
        $Exception
    )

    $ExceptionData = @{}
    if ($Exception.StackTrace) {
        $ExceptionData.Add("StackTrace" , $Exception.StackTrace)
    }
    if ($Exception.HResult) {
        $ExceptionData.Add("HResult", $Exception.HResult.ToString('X'))
    } 
   
    return $ExceptionData
}

function Get-AzExceptionMessage() {
    param(
        [Parameter()]
        $Exception
    )

    if ($Exception.Response -and $Exception.Response.Content) {
        $ExceptionMsg = ($Exception.Response.Content | ConvertFrom-Json).error.message
        if (!$ExceptionMsg) {
            $ExceptionMsg = ($Exception.Response.Content | ConvertFrom-Json).message
        }
    }
    else {
        $ExceptionMsg = $Exception.Message
    }
   
    return $ExceptionMsg
}

function Test-AzureResources {
    param(
        [Parameter(Mandatory)]
        [string]$SubscriptionId,

        [Parameter()]
        [string]$Region,

        [Parameter()]
        [string]$AppServiceEnvironment,

        [Parameter()]
        [string]$ResourceGroup,
        
        [Parameter()]
        [switch]$SkipWarnOnRGNotExists
    )

    Test-InternetConnectivity

    if ($Region) {
        try {
            $AllRegions = Get-AzLocation -ErrorAction Stop 
            $Regions = $AllRegions | Select-Object Location 
            if (!($Regions | Where-Object {$_.Location -eq $Region})) {
                Write-HostError -Message "Region $Region is not valid. Possible region values may be viewed by running an Az Powershell command :
                Get-AzLocation | select Location"
                exit 1  
            }
        }
        catch {
            Write-HostError -Message "Error verifying if $Region is valid Azure Region : $($_.Exception.Message)"  
            exit 1  
        }
    }
   
    if ($SubscriptionId) {
        try {
            $context = Get-AzSubscription -SubscriptionId $SubscriptionId -ErrorAction Stop | Set-AzContext
        } catch {
            Write-HostError "Error setting subscription Id : $($_.Exception.Message)"
            Write-HostError "Run Get-AzSubscription on powershell to get all valid subscriptions"
            exit 1  
        }
    }   
    
    if ($AppServiceEnvironment) {
        try {
            $ASEDetails = Get-AzResource -Name $AppServiceEnvironment -ResourceType Microsoft.Web/hostingEnvironments -ErrorAction Stop
            if (!$ASEDetails) {
                Write-HostError "App Service Environment $AppServiceEnvironment doesn't exist in Subscription $SubscriptionId"
                Write-HostError "Please provide an existing App Service Environment in Subscription $SubscriptionId"
                exit 1  
            } elseif($Region -and $ASEDetails.location -ne $Region) {               
                Write-HostWarn -Message "Specified Region ($Region) does not match App Service Environment location ($($ASEDetails.location)), App Service Environment location will be used during migration"
                #exit 1  # warn on this only, migration will work with the described behavior
            }
        }
        catch {
            Write-HostError -Message "Error verifying if App Service Environment is valid : $($_.Exception.Message)"
            exit 1  
        }
    }

    if ($ResourceGroup) {
        try {
            [void](Get-AzResourceGroup -Name $ResourceGroup -ErrorVariable RscGrpError -ErrorAction Stop)            
        }
        catch {
            #non terminating error as a Resource group is created if not present during the migration
            if ($RscGrpError -and $RscGrpError.Count -gt 0 -and $RscGrpError[0].ToString().Contains("does not exist")) {
                if(!$SkipWarnOnRGNotExists) {   
                    Write-HostWarn "Resource Group $ResourceGroup not found in Subscription $SubscriptionId"
                    Write-HostWarn "Resource Group $ResourceGroup will be created during migration"
                }                   
            } else {
                Write-HostError -Message "Error verifying Resource Group name : $($_.Exception.Message)"    
                exit 1
            }
        }
    }
}
# SIG # Begin signature block
# MIIoKgYJKoZIhvcNAQcCoIIoGzCCKBcCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCByax7KEAV/YgCT
# KNExq37w9cUKVArDK6IEW9f8npCa/6CCDXYwggX0MIID3KADAgECAhMzAAAEhV6Z
# 7A5ZL83XAAAAAASFMA0GCSqGSIb3DQEBCwUAMH4xCzAJBgNVBAYTAlVTMRMwEQYD
# VQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNy
# b3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMTH01pY3Jvc29mdCBDb2RlIFNpZ25p
# bmcgUENBIDIwMTEwHhcNMjUwNjE5MTgyMTM3WhcNMjYwNjE3MTgyMTM3WjB0MQsw
# CQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9u
# ZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMR4wHAYDVQQDExVNaWNy
# b3NvZnQgQ29ycG9yYXRpb24wggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIB
# AQDASkh1cpvuUqfbqxele7LCSHEamVNBfFE4uY1FkGsAdUF/vnjpE1dnAD9vMOqy
# 5ZO49ILhP4jiP/P2Pn9ao+5TDtKmcQ+pZdzbG7t43yRXJC3nXvTGQroodPi9USQi
# 9rI+0gwuXRKBII7L+k3kMkKLmFrsWUjzgXVCLYa6ZH7BCALAcJWZTwWPoiT4HpqQ
# hJcYLB7pfetAVCeBEVZD8itKQ6QA5/LQR+9X6dlSj4Vxta4JnpxvgSrkjXCz+tlJ
# 67ABZ551lw23RWU1uyfgCfEFhBfiyPR2WSjskPl9ap6qrf8fNQ1sGYun2p4JdXxe
# UAKf1hVa/3TQXjvPTiRXCnJPAgMBAAGjggFzMIIBbzAfBgNVHSUEGDAWBgorBgEE
# AYI3TAgBBggrBgEFBQcDAzAdBgNVHQ4EFgQUuCZyGiCuLYE0aU7j5TFqY05kko0w
# RQYDVR0RBD4wPKQ6MDgxHjAcBgNVBAsTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEW
# MBQGA1UEBRMNMjMwMDEyKzUwNTM1OTAfBgNVHSMEGDAWgBRIbmTlUAXTgqoXNzci
# tW2oynUClTBUBgNVHR8ETTBLMEmgR6BFhkNodHRwOi8vd3d3Lm1pY3Jvc29mdC5j
# b20vcGtpb3BzL2NybC9NaWNDb2RTaWdQQ0EyMDExXzIwMTEtMDctMDguY3JsMGEG
# CCsGAQUFBwEBBFUwUzBRBggrBgEFBQcwAoZFaHR0cDovL3d3dy5taWNyb3NvZnQu
# Y29tL3BraW9wcy9jZXJ0cy9NaWNDb2RTaWdQQ0EyMDExXzIwMTEtMDctMDguY3J0
# MAwGA1UdEwEB/wQCMAAwDQYJKoZIhvcNAQELBQADggIBACjmqAp2Ci4sTHZci+qk
# tEAKsFk5HNVGKyWR2rFGXsd7cggZ04H5U4SV0fAL6fOE9dLvt4I7HBHLhpGdE5Uj
# Ly4NxLTG2bDAkeAVmxmd2uKWVGKym1aarDxXfv3GCN4mRX+Pn4c+py3S/6Kkt5eS
# DAIIsrzKw3Kh2SW1hCwXX/k1v4b+NH1Fjl+i/xPJspXCFuZB4aC5FLT5fgbRKqns
# WeAdn8DsrYQhT3QXLt6Nv3/dMzv7G/Cdpbdcoul8FYl+t3dmXM+SIClC3l2ae0wO
# lNrQ42yQEycuPU5OoqLT85jsZ7+4CaScfFINlO7l7Y7r/xauqHbSPQ1r3oIC+e71
# 5s2G3ClZa3y99aYx2lnXYe1srcrIx8NAXTViiypXVn9ZGmEkfNcfDiqGQwkml5z9
# nm3pWiBZ69adaBBbAFEjyJG4y0a76bel/4sDCVvaZzLM3TFbxVO9BQrjZRtbJZbk
# C3XArpLqZSfx53SuYdddxPX8pvcqFuEu8wcUeD05t9xNbJ4TtdAECJlEi0vvBxlm
# M5tzFXy2qZeqPMXHSQYqPgZ9jvScZ6NwznFD0+33kbzyhOSz/WuGbAu4cHZG8gKn
# lQVT4uA2Diex9DMs2WHiokNknYlLoUeWXW1QrJLpqO82TLyKTbBM/oZHAdIc0kzo
# STro9b3+vjn2809D0+SOOCVZMIIHejCCBWKgAwIBAgIKYQ6Q0gAAAAAAAzANBgkq
# hkiG9w0BAQsFADCBiDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24x
# EDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlv
# bjEyMDAGA1UEAxMpTWljcm9zb2Z0IFJvb3QgQ2VydGlmaWNhdGUgQXV0aG9yaXR5
# IDIwMTEwHhcNMTEwNzA4MjA1OTA5WhcNMjYwNzA4MjEwOTA5WjB+MQswCQYDVQQG
# EwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwG
# A1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSgwJgYDVQQDEx9NaWNyb3NvZnQg
# Q29kZSBTaWduaW5nIFBDQSAyMDExMIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIIC
# CgKCAgEAq/D6chAcLq3YbqqCEE00uvK2WCGfQhsqa+laUKq4BjgaBEm6f8MMHt03
# a8YS2AvwOMKZBrDIOdUBFDFC04kNeWSHfpRgJGyvnkmc6Whe0t+bU7IKLMOv2akr
# rnoJr9eWWcpgGgXpZnboMlImEi/nqwhQz7NEt13YxC4Ddato88tt8zpcoRb0Rrrg
# OGSsbmQ1eKagYw8t00CT+OPeBw3VXHmlSSnnDb6gE3e+lD3v++MrWhAfTVYoonpy
# 4BI6t0le2O3tQ5GD2Xuye4Yb2T6xjF3oiU+EGvKhL1nkkDstrjNYxbc+/jLTswM9
# sbKvkjh+0p2ALPVOVpEhNSXDOW5kf1O6nA+tGSOEy/S6A4aN91/w0FK/jJSHvMAh
# dCVfGCi2zCcoOCWYOUo2z3yxkq4cI6epZuxhH2rhKEmdX4jiJV3TIUs+UsS1Vz8k
# A/DRelsv1SPjcF0PUUZ3s/gA4bysAoJf28AVs70b1FVL5zmhD+kjSbwYuER8ReTB
# w3J64HLnJN+/RpnF78IcV9uDjexNSTCnq47f7Fufr/zdsGbiwZeBe+3W7UvnSSmn
# Eyimp31ngOaKYnhfsi+E11ecXL93KCjx7W3DKI8sj0A3T8HhhUSJxAlMxdSlQy90
# lfdu+HggWCwTXWCVmj5PM4TasIgX3p5O9JawvEagbJjS4NaIjAsCAwEAAaOCAe0w
# ggHpMBAGCSsGAQQBgjcVAQQDAgEAMB0GA1UdDgQWBBRIbmTlUAXTgqoXNzcitW2o
# ynUClTAZBgkrBgEEAYI3FAIEDB4KAFMAdQBiAEMAQTALBgNVHQ8EBAMCAYYwDwYD
# VR0TAQH/BAUwAwEB/zAfBgNVHSMEGDAWgBRyLToCMZBDuRQFTuHqp8cx0SOJNDBa
# BgNVHR8EUzBRME+gTaBLhklodHRwOi8vY3JsLm1pY3Jvc29mdC5jb20vcGtpL2Ny
# bC9wcm9kdWN0cy9NaWNSb29DZXJBdXQyMDExXzIwMTFfMDNfMjIuY3JsMF4GCCsG
# AQUFBwEBBFIwUDBOBggrBgEFBQcwAoZCaHR0cDovL3d3dy5taWNyb3NvZnQuY29t
# L3BraS9jZXJ0cy9NaWNSb29DZXJBdXQyMDExXzIwMTFfMDNfMjIuY3J0MIGfBgNV
# HSAEgZcwgZQwgZEGCSsGAQQBgjcuAzCBgzA/BggrBgEFBQcCARYzaHR0cDovL3d3
# dy5taWNyb3NvZnQuY29tL3BraW9wcy9kb2NzL3ByaW1hcnljcHMuaHRtMEAGCCsG
# AQUFBwICMDQeMiAdAEwAZQBnAGEAbABfAHAAbwBsAGkAYwB5AF8AcwB0AGEAdABl
# AG0AZQBuAHQALiAdMA0GCSqGSIb3DQEBCwUAA4ICAQBn8oalmOBUeRou09h0ZyKb
# C5YR4WOSmUKWfdJ5DJDBZV8uLD74w3LRbYP+vj/oCso7v0epo/Np22O/IjWll11l
# hJB9i0ZQVdgMknzSGksc8zxCi1LQsP1r4z4HLimb5j0bpdS1HXeUOeLpZMlEPXh6
# I/MTfaaQdION9MsmAkYqwooQu6SpBQyb7Wj6aC6VoCo/KmtYSWMfCWluWpiW5IP0
# wI/zRive/DvQvTXvbiWu5a8n7dDd8w6vmSiXmE0OPQvyCInWH8MyGOLwxS3OW560
# STkKxgrCxq2u5bLZ2xWIUUVYODJxJxp/sfQn+N4sOiBpmLJZiWhub6e3dMNABQam
# ASooPoI/E01mC8CzTfXhj38cbxV9Rad25UAqZaPDXVJihsMdYzaXht/a8/jyFqGa
# J+HNpZfQ7l1jQeNbB5yHPgZ3BtEGsXUfFL5hYbXw3MYbBL7fQccOKO7eZS/sl/ah
# XJbYANahRr1Z85elCUtIEJmAH9AAKcWxm6U/RXceNcbSoqKfenoi+kiVH6v7RyOA
# 9Z74v2u3S5fi63V4GuzqN5l5GEv/1rMjaHXmr/r8i+sLgOppO6/8MO0ETI7f33Vt
# Y5E90Z1WTk+/gFcioXgRMiF670EKsT/7qMykXcGhiJtXcVZOSEXAQsmbdlsKgEhr
# /Xmfwb1tbWrJUnMTDXpQzTGCGgowghoGAgEBMIGVMH4xCzAJBgNVBAYTAlVTMRMw
# EQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVN
# aWNyb3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMTH01pY3Jvc29mdCBDb2RlIFNp
# Z25pbmcgUENBIDIwMTECEzMAAASFXpnsDlkvzdcAAAAABIUwDQYJYIZIAWUDBAIB
# BQCgga4wGQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQwHAYKKwYBBAGCNwIBCzEO
# MAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEIAc8u7ZTULP62dgG4svqizO1
# RaDApLvTEJky/4+qZpkeMEIGCisGAQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8A
# cwBvAGYAdKEagBhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEB
# BQAEggEAJd0aqXy+jJXIhNneRn+e2L4dHhIGZYgO8twPWT6fBOwpclUhgwO/v9fv
# kc4VLOhZ2BXlqCU5N7hFn4HYaoCCQq8SQu29ruOv8ih4fgLoT37CL6P2t1BY0aQs
# xbm12+ejMsnxsypVowlPd26sVLlbkiRxnfnZAkrNdzxtaY8xZWxpcphNmpzvrW4T
# 3Ap+lx6D+JLYh+EoxJwK/aP/Rve/Xm90PfvL2roMorgq+M+P0XExisUDPmxMeile
# ptP3NMzlxs9rpSC3V0F5FeKkmW8jS4GCwcF1f02ZzwIlbtUN5gTBVKti5QjmX2it
# GP8iikfktSfZ7Bf7B/fzp8lvUPO0SaGCF5QwgheQBgorBgEEAYI3AwMBMYIXgDCC
# F3wGCSqGSIb3DQEHAqCCF20wghdpAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFSBgsq
# hkiG9w0BCRABBKCCAUEEggE9MIIBOQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFl
# AwQCAQUABCBhAnPJuO5bB49QpnRVovRV0AV99mHNPInuFkk7J+zQSgIGaRYkjibA
# GBMyMDI1MTEyNTAwMjEwOS4zMDlaMASAAgH0oIHRpIHOMIHLMQswCQYDVQQGEwJV
# UzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UE
# ChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1l
# cmljYSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRTUyBFU046REMwMC0w
# NUUwLUQ5NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2Wg
# ghHqMIIHIDCCBQigAwIBAgITMwAAAgO7HlwAOGx0ygABAAACAzANBgkqhkiG9w0B
# AQsFADB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UE
# BxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYD
# VQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMDAeFw0yNTAxMzAxOTQy
# NDZaFw0yNjA0MjIxOTQyNDZaMIHLMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2Fz
# aGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENv
# cnBvcmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25z
# MScwJQYDVQQLEx5uU2hpZWxkIFRTUyBFU046REMwMC0wNUUwLUQ5NDcxJTAjBgNV
# BAMTHE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2UwggIiMA0GCSqGSIb3DQEB
# AQUAA4ICDwAwggIKAoICAQChl0MH5wAnOx8Uh8RtidF0J0yaFDHJYHTpPvRR16X1
# KxGDYfT8PrcGjCLCiaOu3K1DmUIU4Rc5olndjappNuOgzwUoj43VbbJx5PFTY/a1
# Z80tpqVP0OoKJlUkfDPSBLFgXWj6VgayRCINtLsUasy0w5gysD7ILPZuiQjace5K
# xASjKf2MVX1qfEzYBbTGNEijSQCKwwyc0eavr4Fo3X/+sCuuAtkTWissU64k8rK6
# 0jsGRApiESdfuHr0yWAmc7jTOPNeGAx6KCL2ktpnGegLDd1IlE6Bu6BSwAIFHr7z
# OwIlFqyQuCe0SQALCbJhsT9y9iy61RJAXsU0u0TC5YYmTSbEI7g10dYx8Uj+vh9I
# nLoKYC5DpKb311bYVd0bytbzlfTRslRTJgotnfCAIGMLqEqk9/2VRGu9klJi1j9n
# VfqyYHYrMPOBXcrQYW0jmKNjOL47CaEArNzhDBia1wXdJANKqMvJ8pQe2m8/ciby
# DM+1BVZquNAov9N4tJF4ACtjX0jjXNDUMtSZoVFQH+FkWdfPWx1uBIkc97R+xRLu
# PjUypHZ5A3AALSke4TaRBvbvTBYyW2HenOT7nYLKTO4jw5Qq6cw3Z9zTKSPQ6D5l
# yiYpes5RR2MdMvJS4fCcPJFeaVOvuWFSQ/EGtVBShhmLB+5ewzFzdpf1UuJmuOQT
# TwIDAQABo4IBSTCCAUUwHQYDVR0OBBYEFLIpWUB+EeeQ29sWe0VdzxWQGJJ9MB8G
# A1UdIwQYMBaAFJ+nFV0AXmJdg/Tl0mWnG1M1GelyMF8GA1UdHwRYMFYwVKBSoFCG
# Tmh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY3JsL01pY3Jvc29mdCUy
# MFRpbWUtU3RhbXAlMjBQQ0ElMjAyMDEwKDEpLmNybDBsBggrBgEFBQcBAQRgMF4w
# XAYIKwYBBQUHMAKGUGh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY2Vy
# dHMvTWljcm9zb2Z0JTIwVGltZS1TdGFtcCUyMFBDQSUyMDIwMTAoMSkuY3J0MAwG
# A1UdEwEB/wQCMAAwFgYDVR0lAQH/BAwwCgYIKwYBBQUHAwgwDgYDVR0PAQH/BAQD
# AgeAMA0GCSqGSIb3DQEBCwUAA4ICAQCQEMbesD6TC08R0oYCdSC452AQrGf/O89G
# Q54CtgEsbxzwGDVUcmjXFcnaJSTNedBKVXkBgawRonP1LgxH4bzzVj2eWNmzGIwO
# 1FlhldAPOHAzLBEHRoSZ4pddFtaQxoabU/N1vWyICiN60It85gnF5JD4MMXyd6pS
# 8eADIi6TtjfgKPoumWa0BFQ/aEzjUrfPN1r7crK+qkmLztw/ENS7zemfyx4kGRgw
# Y1WBfFqm/nFlJDPQBicqeU3dOp9hj7WqD0Rc+/4VZ6wQjesIyCkv5uhUNy2LhNDi
# 2leYtAiIFpmjfNk4GngLvC2Tj9IrOMv20Srym5J/Fh7yWAiPeGs3yA3QapjZTtfr
# 7NfzpBIJQ4xT/ic4WGWqhGlRlVBI5u6Ojw3ZxSZCLg3vRC4KYypkh8FdIWoKirji
# dEGlXsNOo+UP/YG5KhebiudTBxGecfJCuuUspIdRhStHAQsjv/dAqWBLlhorq2OC
# aP+wFhE3WPgnnx5pflvlujocPgsN24++ddHrl3O1FFabW8m0UkDHSKCh8QTwTkYO
# wu99iExBVWlbYZRz2qOIBjL/ozEhtCB0auKhfTLLeuNGBUaBz+oZZ+X9UAECoMhk
# ETjb6YfNaI1T7vVAaiuhBoV/JCOQT+RYZrgykyPpzpmwMNFBD1vdW/29q9nkTWoE
# hcEOO0L9NzCCB3EwggVZoAMCAQICEzMAAAAVxedrngKbSZkAAAAAABUwDQYJKoZI
# hvcNAQELBQAwgYgxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAw
# DgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# MjAwBgNVBAMTKU1pY3Jvc29mdCBSb290IENlcnRpZmljYXRlIEF1dGhvcml0eSAy
# MDEwMB4XDTIxMDkzMDE4MjIyNVoXDTMwMDkzMDE4MzIyNVowfDELMAkGA1UEBhMC
# VVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNV
# BAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRp
# bWUtU3RhbXAgUENBIDIwMTAwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoIC
# AQDk4aZM57RyIQt5osvXJHm9DtWC0/3unAcH0qlsTnXIyjVX9gF/bErg4r25Phdg
# M/9cT8dm95VTcVrifkpa/rg2Z4VGIwy1jRPPdzLAEBjoYH1qUoNEt6aORmsHFPPF
# dvWGUNzBRMhxXFExN6AKOG6N7dcP2CZTfDlhAnrEqv1yaa8dq6z2Nr41JmTamDu6
# GnszrYBbfowQHJ1S/rboYiXcag/PXfT+jlPP1uyFVk3v3byNpOORj7I5LFGc6XBp
# Dco2LXCOMcg1KL3jtIckw+DJj361VI/c+gVVmG1oO5pGve2krnopN6zL64NF50Zu
# yjLVwIYwXE8s4mKyzbnijYjklqwBSru+cakXW2dg3viSkR4dPf0gz3N9QZpGdc3E
# XzTdEonW/aUgfX782Z5F37ZyL9t9X4C626p+Nuw2TPYrbqgSUei/BQOj0XOmTTd0
# lBw0gg/wEPK3Rxjtp+iZfD9M269ewvPV2HM9Q07BMzlMjgK8QmguEOqEUUbi0b1q
# GFphAXPKZ6Je1yh2AuIzGHLXpyDwwvoSCtdjbwzJNmSLW6CmgyFdXzB0kZSU2LlQ
# +QuJYfM2BjUYhEfb3BvR/bLUHMVr9lxSUV0S2yW6r1AFemzFER1y7435UsSFF5PA
# PBXbGjfHCBUYP3irRbb1Hode2o+eFnJpxq57t7c+auIurQIDAQABo4IB3TCCAdkw
# EgYJKwYBBAGCNxUBBAUCAwEAATAjBgkrBgEEAYI3FQIEFgQUKqdS/mTEmr6CkTxG
# NSnPEP8vBO4wHQYDVR0OBBYEFJ+nFV0AXmJdg/Tl0mWnG1M1GelyMFwGA1UdIARV
# MFMwUQYMKwYBBAGCN0yDfQEBMEEwPwYIKwYBBQUHAgEWM2h0dHA6Ly93d3cubWlj
# cm9zb2Z0LmNvbS9wa2lvcHMvRG9jcy9SZXBvc2l0b3J5Lmh0bTATBgNVHSUEDDAK
# BggrBgEFBQcDCDAZBgkrBgEEAYI3FAIEDB4KAFMAdQBiAEMAQTALBgNVHQ8EBAMC
# AYYwDwYDVR0TAQH/BAUwAwEB/zAfBgNVHSMEGDAWgBTV9lbLj+iiXGJo0T2UkFvX
# zpoYxDBWBgNVHR8ETzBNMEugSaBHhkVodHRwOi8vY3JsLm1pY3Jvc29mdC5jb20v
# cGtpL2NybC9wcm9kdWN0cy9NaWNSb29DZXJBdXRfMjAxMC0wNi0yMy5jcmwwWgYI
# KwYBBQUHAQEETjBMMEoGCCsGAQUFBzAChj5odHRwOi8vd3d3Lm1pY3Jvc29mdC5j
# b20vcGtpL2NlcnRzL01pY1Jvb0NlckF1dF8yMDEwLTA2LTIzLmNydDANBgkqhkiG
# 9w0BAQsFAAOCAgEAnVV9/Cqt4SwfZwExJFvhnnJL/Klv6lwUtj5OR2R4sQaTlz0x
# M7U518JxNj/aZGx80HU5bbsPMeTCj/ts0aGUGCLu6WZnOlNN3Zi6th542DYunKmC
# VgADsAW+iehp4LoJ7nvfam++Kctu2D9IdQHZGN5tggz1bSNU5HhTdSRXud2f8449
# xvNo32X2pFaq95W2KFUn0CS9QKC/GbYSEhFdPSfgQJY4rPf5KYnDvBewVIVCs/wM
# nosZiefwC2qBwoEZQhlSdYo2wh3DYXMuLGt7bj8sCXgU6ZGyqVvfSaN0DLzskYDS
# PeZKPmY7T7uG+jIa2Zb0j/aRAfbOxnT99kxybxCrdTDFNLB62FD+CljdQDzHVG2d
# Y3RILLFORy3BFARxv2T5JL5zbcqOCb2zAVdJVGTZc9d/HltEAY5aGZFrDZ+kKNxn
# GSgkujhLmm77IVRrakURR6nxt67I6IleT53S0Ex2tVdUCbFpAUR+fKFhbHP+Crvs
# QWY9af3LwUFJfn6Tvsv4O+S3Fb+0zj6lMVGEvL8CwYKiexcdFYmNcP7ntdAoGokL
# jzbaukz5m/8K6TT4JDVnK+ANuOaMmdbhIurwJ0I9JZTmdHRbatGePu1+oDEzfbzL
# 6Xu/OHBE0ZDxyKs6ijoIYn/ZcGNTTY3ugm2lBRDBcQZqELQdVTNYs6FwZvKhggNN
# MIICNQIBATCB+aGB0aSBzjCByzELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hp
# bmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jw
# b3JhdGlvbjElMCMGA1UECxMcTWljcm9zb2Z0IEFtZXJpY2EgT3BlcmF0aW9uczEn
# MCUGA1UECxMeblNoaWVsZCBUU1MgRVNOOkRDMDAtMDVFMC1EOTQ3MSUwIwYDVQQD
# ExxNaWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNloiMKAQEwBwYFKw4DAhoDFQDN
# rxRX/iz6ss1lBCXG8P1LFxD0e6CBgzCBgKR+MHwxCzAJBgNVBAYTAlVTMRMwEQYD
# VQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNy
# b3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1w
# IFBDQSAyMDEwMA0GCSqGSIb3DQEBCwUAAgUA7M8iFDAiGA8yMDI1MTEyNDE4Mjcz
# MloYDzIwMjUxMTI1MTgyNzMyWjB0MDoGCisGAQQBhFkKBAExLDAqMAoCBQDszyIU
# AgEAMAcCAQACAhyNMAcCAQACAhS+MAoCBQDs0HOUAgEAMDYGCisGAQQBhFkKBAIx
# KDAmMAwGCisGAQQBhFkKAwKgCjAIAgEAAgMHoSChCjAIAgEAAgMBhqAwDQYJKoZI
# hvcNAQELBQADggEBAKHjRv0tNiQGlgRqGWzajqqOHIlF3BP5e70kPsBNfMGK809G
# MClQ09APwQIvXk9Z5FqOH835vDSM3zqFMdBzu//ol0Of2k6v0r2QeW/XlABryX3m
# WQsZrFbpKe6UVupZqNhpVTOsUW2cC+9RBqnoRO0JRwDP3hYkhSVp+jL+MPEAas7K
# V97lYwpxR+Dykek+albvFCAkx+puaipOhA3kbh9SYNS3RAOPb0MSi5ScO5X+QHa4
# A9oO0s1FqqfEYfi+BEsoHw9NHNh7iIY0M0xEZfvOjpa+CPjZs7ygTTeijCxN7T09
# qLVEOONuSOk1sQvc0mZOYR58DuF3PUSpSejRB7AxggQNMIIECQIBATCBkzB8MQsw
# CQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9u
# ZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNy
# b3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMAITMwAAAgO7HlwAOGx0ygABAAACAzAN
# BglghkgBZQMEAgEFAKCCAUowGgYJKoZIhvcNAQkDMQ0GCyqGSIb3DQEJEAEEMC8G
# CSqGSIb3DQEJBDEiBCDBz4XjfCjrZlc7Ip6s7huxNBu+2+0BroFW9gdwPmULGjCB
# +gYLKoZIhvcNAQkQAi8xgeowgecwgeQwgb0EIEsD3RtxlvaTxFOZZnpQw0DksPmV
# duo5SyK9h9w++hMtMIGYMIGApH4wfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldh
# c2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBD
# b3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIw
# MTACEzMAAAIDux5cADhsdMoAAQAAAgMwIgQgvZHwER0RSD9xRl+toV1VaYLpldke
# Pe6wc9eTgasMhaQwDQYJKoZIhvcNAQELBQAEggIAVlPrXRQegiEM5MjfSgyZxkI+
# fRz8thFE1GEQgxqsibfQUtJ0blAUKCfdZEmBjzUSJjvq8pAeEilQVBS8apfjJXQp
# WRmQ6XB3nJ1yY10J52y+p7GfK5EvLH33Nol8LaaByNjsgcofUS9sAGGHoNKt9txf
# qrSHyHd3IyhuM0KsvORgl9aTTsIx67U9yc+6UTHd0xYHUvhYVdIoubIK5/tiP6WT
# t0KhoGkKybvQXbFvw2OaqCTuE2+/Eqz2LAjvKLW+12M742g49acnsg0KpsxIOnha
# RWkz3MuSmknVojYz8sFe0jAzUju90FmPp/S+6xrTstBk5EnbNkRovS1kEtNCvOxr
# fFHQknAr6GUINLykMTu1jcre1lmJvYhVuu1RawAI23a2tGET+GwYwNRUrAHx/sIu
# Zv9r3zokXY0YpQw2mBIIlSDKR7ApsTtLlDZoHmdLngHGLf0QT0Lk5oKHt0bn1ojw
# E27S1pbvgLX+xRMI4SZP0prlekG+jT1zOXtuNbt2YaMlP1GIgZXc1lX+8oGvuLj5
# Qrf5qAhG1lJC1mITVOitxmiuNDtbycYs6R5M+0XcQo1iOCNDDuLIGI739X5f5vuR
# 3rQmyA0FEN/RmD2uWFxNR7dsikGeJCNNz1ahh2O7vNOVK1MeDj1ozBfbkZhi/id1
# NUt9j6PBNvWloZjeNEM=
# SIG # End signature block
