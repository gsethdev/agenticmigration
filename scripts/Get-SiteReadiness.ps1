<#
  .SYNOPSIS
  Compiles assessment data and runs readiness checks for IIS sites

  .DESCRIPTION
  Compiles assessment data and runs readiness checks on the specified sites from 
  the local IIS configuration.

  For applications requiring Managed Instance on Azure App Service (complex dependencies, Windows Services, etc.):
  1. Create the Managed Instance App Service Plan separately using Azure Portal or CLI
  2. Modify MigrationSettings.json to reference your existing Managed Instance ASP
  For more information: https://aka.ms/managedinstanceonappservicedocs

  .PARAMETER ServerName
  The name or IP of the target web server if not running locally.
  Target web server must be configured to allow remote remote PowerShell.
  More information on setting up remote powershell: https://docs.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_remote_requirements?view=powershell-7.1

  .PARAMETER ServerCreds
  PSCredentials for the connection to target web server if not running locally, such as
  created using Get-Credential. The user must have administrator access on target machine.

  .PARAMETER ReadinessResultsOutputPath
  Specifies the path to output the assessment results

  .PARAMETER OverwriteReadinessResults
  Overwrites existing readiness results file with the same name
  without notifying the user.

  .OUTPUTS
  Get-SiteReadiness.ps1 will output the json string readiness results which are saved to ReadinessResultsOutputPath

  .EXAMPLE
  C:\PS> $ReadinessResultsPath = .\Get-SiteReadiness 

  .EXAMPLE
  C:\PS> .\Get-SiteReadiness -ReadinessResultsOutputPath .\CustomPath_ReadinessResults.json

  .EXAMPLE
  C:\PS> .\Get-SiteReadiness -ServerName MyWebServer -ServerCreds $credForMyWebServer
#>

#Requires -Version 4.0
#Requires -RunAsAdministrator
[CmdletBinding(DefaultParameterSetName = "Local")]
param(
    [Parameter(Mandatory, ParameterSetName = "Remote")]
    [string]$ServerName,

    [Parameter(Mandatory, ParameterSetName = "Remote")]
    [PSCredential]$ServerCreds,

    [Parameter()]
    [string]$ReadinessResultsOutputPath,

    [Parameter()]
    [switch]$OverwriteReadinessResults
)
Import-Module (Join-Path $PSScriptRoot "MigrationHelperFunctions.psm1")

$ScriptConfig = Get-ScriptConfig
$ReadinessResultsPath = $ScriptConfig.DefaultReadinessResultsFilePath
$AssessedSites = New-Object System.Collections.ArrayList 

Send-TelemetryEventIfEnabled -TelemetryTitle "Get-SiteReadiness.ps1" -EventName "Started script" -EventType "action" -ErrorAction SilentlyContinue
#storing results at the path given by user
if ($ReadinessResultsOutputPath) {
    $ReadinessResultsPath = $ReadinessResultsOutputPath
}

if ((Test-Path $ReadinessResultsPath) -and !$OverwriteReadinessResults) {
    Write-HostError -Message  "$ReadinessResultsPath already exists. Use -OverwriteReadinessResults to overwrite $ReadinessResultsPath"
    exit 1
}  

$SiteList = New-Object System.Collections.ArrayList

try {   
    [System.Reflection.Assembly]::LoadWithPartialName('System.Windows.Forms') | Out-Null
    $CheckResxFile = (Join-Path $PSScriptRoot "WebAppCheckResources.resx")
    $CheckResourceSet = New-Object -TypeName 'System.Resources.ResXResourceSet' -ArgumentList $CheckResxFile
} catch {
    $ExceptionData = Get-ExceptionData -Exception $_.Exception
    Send-TelemetryEventIfEnabled -TelemetryTitle "Get-SiteReadiness.ps1" -EventName "Exception getting ResXResourceSet" -ExceptionData $ExceptionData -EventType "error" -ErrorAction SilentlyContinue
    Write-HostError -Message "Error in getting check description strings : $($_.Exception.Message)"    
}

try {  
    Write-HostInfo -Message "Scanning for site readiness/compatibility..."      
    $discoveryScript = Join-Path $PSScriptRoot "IISDiscovery.ps1"
    if($ServerName) {
        Send-TelemetryEventIfEnabled -TelemetryTitle "Get-SiteReadiness.ps1" -EventName "Discovery type" -EventMessage "Remote" -EventType "info" -ErrorAction SilentlyContinue
        try {       
            $dataString = Invoke-Command -FilePath $discoveryScript -ArgumentList $true -ComputerName $ServerName -Credential $ServerCreds -ErrorVariable invokeError -ErrorAction SilentlyContinue                         
            if($invokeError) {
                Send-TelemetryEventIfEnabled -TelemetryTitle "Get-SiteReadiness.ps1" -EventName "Error getting remote readiness results" -EventMessage "invoke" -EventType "error" -ErrorAction SilentlyContinue
                Write-HostError -Message "Error getting remote readiness data: $($invokeError[0])" 
                exit 1
            }
        } catch {
            $ExceptionData = Get-ExceptionData -Exception $_.Exception   
            Send-TelemetryEventIfEnabled -TelemetryTitle "Get-SiteReadiness.ps1" -EventName "Error getting remote readiness results" -EventMessage "exception" -ExceptionData $ExceptionData -EventType "error" -ErrorAction SilentlyContinue
            Write-HostError -Message "Error getting remote readiness data: $($_.Exception.Message)"
            exit 1
        }
    } else {    
        Send-TelemetryEventIfEnabled -TelemetryTitle "Get-SiteReadiness.ps1" -EventName "Discovery type" -EventMessage "Local" -EventType "info" -ErrorAction SilentlyContinue      
        $dataString = &($discoveryScript) -aggressiveBlocking $true
    }

    try {
        $discoveryAndAssessmentData = $dataString | ConvertFrom-Json
        if($discoveryAndAssessmentData.error) {
            Send-TelemetryEventIfEnabled -TelemetryTitle "Get-SiteReadiness.ps1" -EventName "Discovery Error" -EventMessage $discoveryAndAssessmentData.error.errorId -EventType "error" -ErrorAction SilentlyContinue
            Write-HostError -Message "Error occurred retrieving IIS server data, issue was: $($discoveryAndAssessmentData.error.errorId): $($discoveryAndAssessmentData.error.detailedMessage)"
            exit 1
        }
    } catch {
        Write-HostError -Message "Error with reading readiness data. Data was in unexpected format. $($_.Exception.Message)"
        exit 1
    }
    
    #Loop through and process each readiness report in the assessment from iisConfigAssistant
    foreach ($Report in $discoveryAndAssessmentData.readinessData.IISSites) {
        $WarningChecks = New-Object System.Collections.ArrayList
        $FailedChecks = New-Object System.Collections.ArrayList
        $FatalErrorFound = $false
        
        
        Write-HostInfo -Message "Report generated for $($Report.webAppName)" 
    
        foreach ($Check in $Report.checks) {            
            $detailsString = ""; 
            if($Check.PSObject.Properties.Name -contains "Details") {
                if($Check.Details.Count -gt 0) { 
                    $detailsString = $Check.Details[0]; 
                }
                $Check.PSObject.Properties.Remove('Details');
            }                           
            if(-not($Check.PSObject.Properties.Name -contains "detailsString")) {                                   
                Add-Member -InputObject $Check -MemberType NoteProperty -Name detailsString -Value $detailsString                               
            }
            
            #rename "result" to "Status"
            $Check | Add-Member -MemberType NoteProperty -Name Status -Value $Check.result
            $Check.PSObject.Properties.Remove('result')
            
            if($CheckResourceSet) {         
                $Check | Add-Member -MemberType NoteProperty -Name Description -Value $CheckResourceSet.GetString("$($Check.IssueId)Title")
                $formattedDetailsMessage = $CheckResourceSet.GetString("$($Check.IssueId)Description") -f $detailsString
                $Check | Add-Member -MemberType NoteProperty -Name Details -Value $formattedDetailsMessage 
                $Check | Add-Member -MemberType NoteProperty -Name Recommendation -Value $CheckResourceSet.GetString("$($Check.IssueId)Recommendation")
                $Check | Add-Member -MemberType NoteProperty -Name MoreInfoLink -Value $CheckResourceSet.GetString("$($Check.IssueId)MoreInformationLink")
            }
                        
            if ($Check.Status -eq "Warn") {
                [void]$WarningChecks.Add($Check)
                Send-TelemetryEventIfEnabled -TelemetryTitle "Get-SiteReadiness.ps1" -EventName "Warning Check" -EventType "info" -EventMessage "$($Check.IssueId)" -ErrorAction SilentlyContinue
            }
            else { # only non-passing checks included in results
                [void]$FailedChecks.Add($Check)
                Send-TelemetryEventIfEnabled -TelemetryTitle "Get-SiteReadiness.ps1" -EventName "Failed Check" -EventType "info" -EventMessage "$($Check.IssueId)" -ErrorAction SilentlyContinue
            }
        }

        if ($WarningChecks) {
            Write-HostWarn -Message "Warnings for $($Report.webAppName): $($WarningChecks.IssueId -join  ',')"
        }    
        if ($FailedChecks.Count -eq 0) {
            Write-HostInfo -Message "$($Report.webAppName): No Blocking issues found and the site is ready for migration to Azure!"
            if($WarningChecks) { 
                Send-TelemetryEventIfEnabled -TelemetryTitle "Get-SiteReadiness.ps1" -EventName "Overall Status" -EventMessage "ConditionallyReady" -EventType "info" -ErrorAction SilentlyContinue
            } else {
                Send-TelemetryEventIfEnabled -TelemetryTitle "Get-SiteReadiness.ps1" -EventName "Overall Status" -EventMessage "Ready" -EventType "info" -ErrorAction SilentlyContinue
            }
        }
        else {
            $FailedFatalChecksString = ""
            $FatalChecks = $ScriptConfig.FatalChecks            

            #finding if any failed checks are fatal 
            # fatal checks are configured in ScriptConfig.json and indicate migration is not possible (i.e. errors will occur during packaging/deploying steps)
            foreach ($FailedCheck in $FailedChecks) {
                if ($FatalChecks.Contains($FailedCheck.IssueId)) {
                    $FailedFatalChecksString += $FailedCheck.IssueId + ", "
                    $FatalErrorFound = $true                    
                }
            }
            
            Write-HostWarn -Message "Failed Checks for $($Report.webAppName) : $($FailedChecks.IssueId -join  ',')"
            
            if ($FatalErrorFound) {
                $FailedFatalChecksString = $FailedFatalChecksString.TrimEnd(',')
                Write-HostWarn -Message "FATAL errors detected in $($Report.webAppName) : $FailedFatalChecksString"
                Write-HostWarn -Message "These failures prevent migration using this tooling. You will not be able to migrate this site until the checks resulting in fatal errors are fixed"   
                Send-TelemetryEventIfEnabled -TelemetryTitle "Get-SiteReadiness.ps1" -EventName "Overall Status" -EventMessage "Blocked" -EventType "info" -ErrorAction SilentlyContinue
            } else {
                Send-TelemetryEventIfEnabled -TelemetryTitle "Get-SiteReadiness.ps1" -EventName "Overall Status" -EventMessage "NotReady" -EventType "info" -ErrorAction SilentlyContinue
            }
        }           
        
        $discoveryData = $discoveryAndAssessmentData.discoveryData.IISSites | Where-Object {$_.webAppName -eq $Report.webAppName} | Select-Object -First 1
        $appPoolInfo = $discoveryData.applications | Where-Object {$_.path -eq "/"} | Select-Object -First 1

        $Site = New-Object PSObject
        Add-Member -InputObject $Site -MemberType NoteProperty -Name SiteName -Value $Report.webAppName
        #check information
        Add-Member -InputObject $Site -MemberType NoteProperty -Name FatalErrorFound -Value $FatalErrorFound
        Add-Member -InputObject $Site -MemberType NoteProperty -Name FailedChecks -Value $FailedChecks
        Add-Member -InputObject $Site -MemberType NoteProperty -Name WarningChecks -Value $WarningChecks
        #app pool settings
        Add-Member -InputObject $Site -MemberType NoteProperty -Name ManagedPipelineMode -Value $appPoolInfo.managedPipelineMode
        Add-Member -InputObject $Site -MemberType NoteProperty -Name Is32Bit -Value $appPoolInfo.enable32BitAppOnWin64
        Add-Member -InputObject $Site -MemberType NoteProperty -Name NetFrameworkVersion -Value $appPoolInfo.managedRuntimeVersion
        #vdir configuration
        Add-Member -InputObject $Site -MemberType NoteProperty -Name VirtualApplications -Value $discoveryData.virtualApplications
        
        [void]$AssessedSites.Add($Site)

        #next line for logical spacing between multiple sites
        Write-Host "" 
    }    

    try
    {
        $AssessedSites | ConvertTo-Json -Depth 10 | Out-File (New-Item -Path $ReadinessResultsPath -ItemType "file" -ErrorAction Stop -Force)
    } catch {
        Write-HostError -Message "Error outputting readiness results files: $($_.Exception.Message)" 
        Send-TelemetryEventIfEnabled -TelemetryTitle "Get-SiteReadiness.ps1" -EventName "Error in creating readiness results file" -EventType "error" -ErrorAction SilentlyContinue
        exit 1
    }
    
Write-HostInfo -Message "Readiness checks complete. Readiness results outputted to $ReadinessResultsPath"
Write-HostInfo -Message "`nFor applications requiring Windows Services or complex dependencies, check out Managed Instance on Azure App Service: https://aka.ms/managedinstanceonappservicedocs"

return $ReadinessResultsPath  

} catch {
    $ExceptionData = Get-ExceptionData -Exception $_.Exception
    Write-HostError -Message "Error in generating Readiness results : $($_.Exception.Message)"
    Send-TelemetryEventIfEnabled -TelemetryTitle "Get-SiteReadiness.ps1" -EventName "Error in generating Readiness results" -ExceptionData $ExceptionData -EventType "error" -ErrorAction SilentlyContinue
}

Send-TelemetryEventIfEnabled -TelemetryTitle "Get-SiteReadiness.ps1" -EventName "Script end" -EventType "action" -ErrorAction SilentlyContinue
# SIG # Begin signature block
# MIIoLQYJKoZIhvcNAQcCoIIoHjCCKBoCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCAEbPtPUtxawN/Q
# C3Gggm5C/8tKH/ehpjkQ+Cj6O0FQs6CCDXYwggX0MIID3KADAgECAhMzAAAEhV6Z
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
# /Xmfwb1tbWrJUnMTDXpQzTGCGg0wghoJAgEBMIGVMH4xCzAJBgNVBAYTAlVTMRMw
# EQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVN
# aWNyb3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMTH01pY3Jvc29mdCBDb2RlIFNp
# Z25pbmcgUENBIDIwMTECEzMAAASFXpnsDlkvzdcAAAAABIUwDQYJYIZIAWUDBAIB
# BQCgga4wGQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQwHAYKKwYBBAGCNwIBCzEO
# MAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEIP/vrkeLfvaZ7z6AJtN5GMxb
# 1rlJ/3ZrtUaRFjFhtp1gMEIGCisGAQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8A
# cwBvAGYAdKEagBhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEB
# BQAEggEAdq2ysy3nkFWhDlpLWGT/0otO21OXT0Mf0x8Khsd8Pap/EJQRvOHJ9RBV
# 1xwOFHqVVrb+sbzJk+HW5nM9MAVwBBXufBDyxFRUbcMBknjIOLEes4hNA/cwarmS
# OwCZ/WWKA+ch4ygmN9BpRl7qRX9p/8WP1Dz3ACmqP+Mp4hXjaxI+7vRRj4Z4zoua
# jsee6iWtxuQqIrXLhhEUdoS2jhWLb5DLt5ekuq8ro+mA6qCrCfY1xqwPDvFbK8TO
# atK8oBJZQWu6ete8ySi3oOj7kCtz3xgsUsruTmY1gw+yCsZkwWWqNZoDk/BcQXkK
# myxQpbbHVKPwkEeMrhgxZk9EkwV8GaGCF5cwgheTBgorBgEEAYI3AwMBMYIXgzCC
# F38GCSqGSIb3DQEHAqCCF3AwghdsAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFSBgsq
# hkiG9w0BCRABBKCCAUEEggE9MIIBOQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFl
# AwQCAQUABCBz4bgdvp1pbpcXA4+o5EU/aanzFRz6SeYN3R0NbAVVtAIGaSTkQCfW
# GBMyMDI1MTEyNTAwMjEwNy43NzFaMASAAgH0oIHRpIHOMIHLMQswCQYDVQQGEwJV
# UzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UE
# ChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1l
# cmljYSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRTUyBFU046OTIwMC0w
# NUUwLUQ5NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2Wg
# ghHtMIIHIDCCBQigAwIBAgITMwAAAgkIB+D5XIzmVQABAAACCTANBgkqhkiG9w0B
# AQsFADB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UE
# BxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYD
# VQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMDAeFw0yNTAxMzAxOTQy
# NTVaFw0yNjA0MjIxOTQyNTVaMIHLMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2Fz
# aGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENv
# cnBvcmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25z
# MScwJQYDVQQLEx5uU2hpZWxkIFRTUyBFU046OTIwMC0wNUUwLUQ5NDcxJTAjBgNV
# BAMTHE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2UwggIiMA0GCSqGSIb3DQEB
# AQUAA4ICDwAwggIKAoICAQDClEow9y4M3f1S9z1xtNEETwWL1vEiiw0oD7SXEdv4
# sdP0xsVyidv6I2rmEl8PYs9LcZjzsWOHI7dQkRL28GP3CXcvY0Zq6nWsHY2QamCZ
# FLF2IlRH6BHx2RkN7ZRDKms7BOo4IGBRlCMkUv9N9/twOzAkpWNsM3b/BQxcwhVg
# sQqtQ8NEPUuiR+GV5rdQHUT4pjihZTkJwraliz0ZbYpUTH5Oki3d3Bpx9qiPriB6
# hhNfGPjl0PIp23D579rpW6ZmPqPT8j12KX7ySZwNuxs3PYvF/w13GsRXkzIbIyLK
# EPzj9lzmmrF2wjvvUrx9AZw7GLSXk28Dn1XSf62hbkFuUGwPFLp3EbRqIVmBZ42w
# cz5mSIICy3Qs/hwhEYhUndnABgNpD5avALOV7sUfJrHDZXX6f9ggbjIA6j2nhSAS
# Iql8F5LsKBw0RPtDuy3j2CPxtTmZozbLK8TMtxDiMCgxTpfg5iYUvyhV4aqaDLwR
# BsoBRhO/+hwybKnYwXxKeeOrsOwQLnaOE5BmFJYWBOFz3d88LBK9QRBgdEH5CLVh
# 7wkgMIeh96cH5+H0xEvmg6t7uztlXX2SV7xdUYPxA3vjjV3EkV7abSHD5HHQZTrd
# 3FqsD/VOYACUVBPrxF+kUrZGXxYInZTprYMYEq6UIG1DT4pCVP9DcaCLGIOYEJ1g
# 0wIDAQABo4IBSTCCAUUwHQYDVR0OBBYEFEmL6NHEXTjlvfAvQM21dzMWk8rSMB8G
# A1UdIwQYMBaAFJ+nFV0AXmJdg/Tl0mWnG1M1GelyMF8GA1UdHwRYMFYwVKBSoFCG
# Tmh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY3JsL01pY3Jvc29mdCUy
# MFRpbWUtU3RhbXAlMjBQQ0ElMjAyMDEwKDEpLmNybDBsBggrBgEFBQcBAQRgMF4w
# XAYIKwYBBQUHMAKGUGh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY2Vy
# dHMvTWljcm9zb2Z0JTIwVGltZS1TdGFtcCUyMFBDQSUyMDIwMTAoMSkuY3J0MAwG
# A1UdEwEB/wQCMAAwFgYDVR0lAQH/BAwwCgYIKwYBBQUHAwgwDgYDVR0PAQH/BAQD
# AgeAMA0GCSqGSIb3DQEBCwUAA4ICAQBcXnxvODwk4h/jbUBsnFlFtrSuBBZb7wSZ
# fa5lKRMTNfNlmaAC4bd7Wo0I5hMxsEJUyupHwh4kD5qkRZczIc0jIABQQ1xDUBa+
# WTxrp/UAqC17ijFCePZKYVjNrHf/Bmjz7FaOI41kxueRhwLNIcQ2gmBqDR5W4TS2
# htRJYyZAs7jfJmbDtTcUOMhEl1OWlx/FnvcQbot5VPzaUwiT6Nie8l6PZjoQsuxi
# asuSAmxKIQdsHnJ5QokqwdyqXi1FZDtETVvbXfDsofzTta4en2qf48hzEZwUvbkz
# 5smt890nVAK7kz2crrzN3hpnfFuftp/rXLWTvxPQcfWXiEuIUd2Gg7eR8QtyKtJD
# U8+PDwECkzoaJjbGCKqx9ESgFJzzrXNwhhX6Rc8g2EU/+63mmqWeCF/kJOFg2eJw
# 7au/abESgq3EazyD1VlL+HaX+MBHGzQmHtvOm3Ql4wVTN3Wq8X8bCR68qiF5rFas
# m4RxF6zajZeSHC/qS5336/4aMDqsV6O86RlPPCYGJOPtf2MbKO7XJJeL/UQN0c3u
# ix5RMTo66dbATxPUFEG5Ph4PHzGjUbEO7D35LuEBiiG8YrlMROkGl3fBQl9bWbgw
# 9CIUQbwq5cTaExlfEpMdSoydJolUTQD5ELKGz1TJahTidd20wlwi5Bk36XImzsH4
# Ys15iXRfAjCCB3EwggVZoAMCAQICEzMAAAAVxedrngKbSZkAAAAAABUwDQYJKoZI
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
# 6Xu/OHBE0ZDxyKs6ijoIYn/ZcGNTTY3ugm2lBRDBcQZqELQdVTNYs6FwZvKhggNQ
# MIICOAIBATCB+aGB0aSBzjCByzELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hp
# bmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jw
# b3JhdGlvbjElMCMGA1UECxMcTWljcm9zb2Z0IEFtZXJpY2EgT3BlcmF0aW9uczEn
# MCUGA1UECxMeblNoaWVsZCBUU1MgRVNOOjkyMDAtMDVFMC1EOTQ3MSUwIwYDVQQD
# ExxNaWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNloiMKAQEwBwYFKw4DAhoDFQB8
# 762rPTQd7InDCQdb1kgFKQkCRKCBgzCBgKR+MHwxCzAJBgNVBAYTAlVTMRMwEQYD
# VQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNy
# b3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1w
# IFBDQSAyMDEwMA0GCSqGSIb3DQEBCwUAAgUA7M9iwTAiGA8yMDI1MTEyNDIzMDMy
# OVoYDzIwMjUxMTI1MjMwMzI5WjB3MD0GCisGAQQBhFkKBAExLzAtMAoCBQDsz2LB
# AgEAMAoCAQACAgCJAgH/MAcCAQACAhREMAoCBQDs0LRBAgEAMDYGCisGAQQBhFkK
# BAIxKDAmMAwGCisGAQQBhFkKAwKgCjAIAgEAAgMHoSChCjAIAgEAAgMBhqAwDQYJ
# KoZIhvcNAQELBQADggEBAEFyGsO1UW2n3+WZrWz7hCmcX8l7P0aPpiT14gHtxQ/1
# +9FBiWDF+cOmH1BF5whqiqzQuitgCJTcfsxo3taCxoaAuleuNy0bcoth4NdCrUz9
# s8h/1gtslJlwxD7Agi+ACVYNfeVwNtCY/1yn9+mhJnRGBF8CIIzcmmpNzqc9VmGG
# /jxpPBHdRwYJC32A+IvgEfEwl9KR2wWf1PJexUGqA5jULmcE06thG9rGQdsssjg8
# 7kV3L8PbHGaXy41R4Wy07JhKfQK4OpntjJbps6PIkf6gcrO8a8Pq3qeE2nmbQsnt
# uJtmw6BeY+UBELvSU3Q5dexLpQ+ALg2+Xv+IlOYjF6AxggQNMIIECQIBATCBkzB8
# MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVk
# bW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1N
# aWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMAITMwAAAgkIB+D5XIzmVQABAAAC
# CTANBglghkgBZQMEAgEFAKCCAUowGgYJKoZIhvcNAQkDMQ0GCyqGSIb3DQEJEAEE
# MC8GCSqGSIb3DQEJBDEiBCCJoEeMxfs906vxBAKuQvhrxLJRJ/k6YT5LKV9vdR8c
# 4zCB+gYLKoZIhvcNAQkQAi8xgeowgecwgeQwgb0EIGgbLB7IvfQCLmUOUZhjdUqK
# 8bikfB6ZVVdoTjNwhRM+MIGYMIGApH4wfDELMAkGA1UEBhMCVVMxEzARBgNVBAgT
# Cldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29m
# dCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENB
# IDIwMTACEzMAAAIJCAfg+VyM5lUAAQAAAgkwIgQgcAFJblmoRXrEkGhegUwX9zS7
# m+rTFlnqk0Z4S6oqKdwwDQYJKoZIhvcNAQELBQAEggIAOK9BNBqBSKokLQIVjgsZ
# 1QPHcWBtTFBF7BMHgO37UKMEzYn02kxcB7cDVqXNutWJgJKBZj9pmCcenQ0z0P6L
# LsIPlfUgo2VMRo94baDc9MgxUjY5tHg2jQFWFYZpr+13BPa9yVYQ0XmJG/86ytYI
# bQ8qrPc3jG0ptDLpW4b87uMoufv8/6Le+NCq123h6ZPQ7ppl7RqCfOCugnJwflcT
# qFjzIl+rT/2+jaRMOs3iH3Q8+lGwLv8jWwr73dmtUhX9KWQZ6iq2KNZVfdQu9J2i
# PxSW6DLDN1rkp3Exd4nF7XOCVgJO9Jk95GsUuCGHL5FuY1j8f/ygBWGUYeVuvvKQ
# cYM6RjnM8ngS/0IOfyvTbeURAVd9bAo2Jfu5TGArjZqnUdWkT5XnCFX0mecpx+xc
# HrK3u8la5fONg9odputw6PuWoiXA+bGqAYZ0LXU+ApW6Qnh6pORW19rWZQ2mU31o
# i3h7taTV3ISQ5IIeUGbRkfLtJKXl3y4BRq/eMtqSpnRT49o89425sY6zrxfdoEPh
# eufRnmLwn5typqR6NqwQVtFDxveiRWkFfZnut4gC5+ZJETtop0bqR7borj9T4y7I
# J2pv+HRz+11mUH+/1eKzlMZUSHi4Sb5FGMYTfwzsRxrZy2+1G6jYgr58HirIZKuF
# 6jqaU9MyhFDgiuEpbZqe0uM=
# SIG # End signature block
