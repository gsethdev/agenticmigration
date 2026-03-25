<#
  .SYNOPSIS
  Packages sites for migration

  .DESCRIPTION
  Packages the specified site(s) for migration using the Invoke-SiteMigration script to Azure App Service.
  If packages for the same site name already exist in OutputDirectory they will be overwritten.

  .PARAMETER ReadinessResultsFilePath
  Specifies the path of a readiness results file from which sites and their details are picked for packaging

  .PARAMETER SiteName
  Specifies the name of a site to package. If not used, all the
  sites in the ReadinessResultsFilePath will be packaged
  
  .PARAMETER OutputDirectory
  Specifies a custom directory for the generated site .zip files and package results file instead of the default PackagedSitesFolder specified in ScriptConfig.json. 

  .PARAMETER PackageResultsFileName
  Specifies a custom name for the generated packaged sites results file
  
  .PARAMETER MigrateSitesWithIssues
  If passed, warns user and packages sites that passed all checks,
  and those that failed one or more checks if there wasn't a fatal error

  .PARAMETER Force
  Overwrites pre-existing package results output file as well as any pre-existing site package files in OutputDirectory with matching site names

  .OUTPUTS
  Get-SitePackage.ps1 outputs the path to a file containing site names and their resulting package location or error message if packaging failed

  .EXAMPLE
  C:\PS> $PackageResults = .\Get-SitePackage -ReadinessResultsFilePath ReadinessResults.json

  .EXAMPLE
  C:\PS> .\Get-SitePackage -ReadinessResultsFilePath ReadinessResults.json -SiteName MySitesName -PackageResultsFileName "ServerAPackageResults.json" -Force

  .EXAMPLE
  C:\PS> .\Get-SitePackage -ReadinessResultsFilePath ReadinessResults.json -OutputDirectory C:\SitePackages -MigrateSitesWithIssues
#>

#Requires -Version 4.0
#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ReadinessResultsFilePath,

    [Parameter()]
    [string]$SiteName,

    [Parameter()]
    [string]$OutputDirectory,

    [Parameter()]
    [string]$PackageResultsFileName,

    [Parameter()]
    [switch]$MigrateSitesWithIssues,

    [Parameter()]
    [switch]$Force
)
Import-Module (Join-Path $PSScriptRoot "MigrationHelperFunctions.psm1")

$ScriptConfig = Get-ScriptConfig

$PackagedSitesFilePath = $ScriptConfig.PackagedSitesFolder
$PackagedSitesFilePostFix = $ScriptConfig.PackagedSiteFilePostFix
$PackageResults = New-Object System.Collections.ArrayList

Send-TelemetryEventIfEnabled -TelemetryTitle "Get-SitePackage.ps1" -EventName "Started script" -EventType "action" -ErrorAction SilentlyContinue

function Get-SitePackageResult {
    param(
        [Parameter()]
        [string]$SiteName,

        [Parameter()]
        [string]$SitePackagePath,

        [Parameter()]
        [string]$ErrorMessage
    )
    $SitePackageResult = New-Object PSObject
    if ($SiteName) {
        Add-Member -InputObject $SitePackageResult -MemberType NoteProperty -Name SiteName -Value $SiteName
    }
    if ($SitePackagePath) {
        Add-Member -InputObject $SitePackageResult -MemberType NoteProperty -Name SitePackagePath -Value $SitePackagePath
    }
    if ($ErrorMessage) {
        Add-Member -InputObject $SitePackageResult -MemberType NoteProperty -Name Error -Value $ErrorMessage
    }

    return $SitePackageResult;
}

#Main function that creates zip for single site
function Get-ZippedSite {
    param(
        [Parameter()]
        [string]$SiteToZip,

        [Parameter()]
        $SiteReadinessData
    )
    try {
        #basic attempt to avoid special characters in file names by replacing any with underscores  
        #possible collision risk with multiple sites using special chars (example: site\a\, site(a) )   
        # TODO: add randomizer/increment to avoid collisions
        $invalidFileNameChars = [System.IO.Path]::GetInvalidFileNameChars() -join ''
        $invalidCharsEscapedForRE =  '[{0}]' -f [RegEx]::Escape($invalidFileNameChars)
        $simplifiedSiteName = $SiteToZip -replace $invalidCharsEscapedForRE,'_'
        
        $SiteContentFileName = $simplifiedSiteName + $PackagedSitesFilePostFix        
        #Temporarily create a SiteConfig file to be included in the site's zip, won't work with parallelization
        $SiteConfigFile = "SiteConfig.json"

        $SitePackagePath = Join-Path -Path $OutputDirectory -ChildPath  $SiteContentFileName
   
        #save site metadata used during migration in SiteConfig.json to place in root of package
        $SiteConfigData = New-Object PSObject
        Add-Member -InputObject $SiteConfigData -MemberType NoteProperty -Name Is32Bit -Value $SiteReadinessData.Is32Bit
        Add-Member -InputObject $SiteConfigData -MemberType NoteProperty -Name VirtualApplications -Value $SiteReadinessData.VirtualApplications
        Add-Member -InputObject $SiteConfigData -MemberType NoteProperty -Name ManagedPipelineMode -Value $SiteReadinessData.ManagedPipelineMode
        Add-Member -InputObject $SiteConfigData -MemberType NoteProperty -Name NetFrameworkVersion -Value $SiteReadinessData.NetFrameworkVersion    
        $SiteConfigData | ConvertTo-Json -Depth 10 | Out-File -FilePath $SiteConfigFile

        if ((Test-Path -Path $SitePackagePath) -and !$Force) {
            $ErrorMessage = "$SitePackagePath already exists. Use -Force to overwrite existing packages or specify alternate -OutputDirectory location."
            Write-HostWarn -Message $ErrorMessage
            $SitePackageResult = Get-SitePackageResult -SiteName $SiteToZip -ErrorMessage $ErrorMessage
            return $SitePackageResult
        } elseif ((Test-Path -Path $SitePackagePath) -and $Force) {
            try {
                Remove-Item -Path $SitePackagePath
            } catch {
                $msg = "Error cleaning up pre-existing package $SitePackagePath : $($_.Exception.Message)"
                Write-HostWarn -Message $msg            
                $SitePackageResult = Get-SitePackageResult -SiteName $SiteToZip -ErrorMessage $msg
                return $SitePackageResult
            }
        }
        
        if(-not ([System.IO.Path]::IsPathRooted($SiteConfigFile))) {
            $pathInfo1 = Resolve-Path $SiteConfigFile
            $SiteConfigFile = $pathInfo1.Path
        }
        
        $p = &(Join-Path $PSScriptRoot "IISMigration.ps1") -targetSiteName $SiteToZip -zipOutputFilePath $SitePackagePath -localSiteConfigFile $SiteConfigFile  
        $overallJsonResult = $p[$p.Count - 1]
        $ZipSiteResult = $overallJsonResult | ConvertFrom-Json
                
        # Write-HostInfo -Message $overallJsonResult 
        
        #  example: during IISMigration.ps1 if site isn't found will return error of : IISWebAppNotFoundOnServer
        if ($ZipSiteResult.PSobject.Properties.Name.Contains("error")) {            
            $ErrorMessage = "Site packaging Error: $($ZipSiteResult.error.code) $($ZipSiteResult.error.message)"
            Write-HostWarn -Message $ErrorMessage            
            Send-TelemetryEventIfEnabled -TelemetryTitle "Get-SitePackage.ps1" -EventName "Site Package Error $($ZipSiteResult.error.code)" -EventType "error" -ErrorAction SilentlyContinue

            $SitePackageResult = Get-SitePackageResult -SiteName $SiteToZip -ErrorMessage $ErrorMessage
        } else {
            Write-HostInfo -Message "$SiteToZip has been packaged at $SitePackagePath." -MakeTextGreen
            Send-TelemetryEventIfEnabled -TelemetryTitle "Get-SitePackage.ps1" -EventName "Site Packaged" -EventType "action" -ErrorAction SilentlyContinue
            $SitePackageResult = Get-SitePackageResult -SiteName $SiteToZip -SitePackagePath $SiteContentFileName
        }       
    } catch {
        $ExceptionData = Get-ExceptionData -Exception $_.Exception
        Write-HostWarn -Message "Site packaging Error: $($_.Exception.Message)"
        Send-TelemetryEventIfEnabled -TelemetryTitle "Get-SitePackage.ps1" -EventName "Site Package Error" -ExceptionData $ExceptionData -EventType "error" -ErrorAction SilentlyContinue
        $SitePackageResult = Get-SitePackageResult -SiteName $SiteToZip -ErrorMessage $_.Exception.Message
    } finally {   
        #removing temperory files created
        if (Test-Path $SiteConfigFile) 
        {
            Remove-Item $SiteConfigFile
        }        
    }
    return $SitePackageResult 
}

try {
    if ($OutputDirectory) {
        if (!(Test-Path -Path $OutputDirectory)) {
            [void] (New-Item -ItemType Directory -Path $OutputDirectory)
        } 
    } else {
        if (!(Test-Path -Path $PackagedSitesFilePath)) {
            [void] (New-Item -ItemType Directory -Path $PackagedSitesFilePath)
        }
        $OutputDirectory = $PackagedSitesFilePath
    }
} catch {
    Write-HostError -Message "Error creating packaging destination directory : $($_.Exception.Message)"
    $ExceptionData = Get-ExceptionData -Exception $_.Exception
    Send-TelemetryEventIfEnabled -TelemetryTitle "Get-SitePackage.ps1" -EventName "Error creating package destination dir" -EventMessage $ReadinessResultsFile -ExceptionData $ExceptionData -EventType "error" -ErrorAction SilentlyContinue
    exit 1
}

if(-not ([System.IO.Path]::IsPathRooted($OutputDirectory))) {
    $pathInfo = Resolve-Path $OutputDirectory
    $OutputDirectory = $pathInfo.Path
}

if ($PackageResultsFileName) {
    $PackageResultsPath = Join-Path -Path $OutputDirectory -ChildPath $PackageResultsFileName
} else {
    $PackageResultsPath = Join-Path -Path $OutputDirectory -ChildPath $ScriptConfig.DefaultPackageResultsFileName
}

if ((Test-Path $PackageResultsPath) -and !$Force) {
    Write-HostError -Message  "Package results file $PackageResultsPath already exists. Use -Force to overwrite or specify alternate -OutputDirectory location."
    Write-HostWarn -Message  "Using -Force will overwrite zipped content at $OutputDirectory of all the sites present in $ReadinessResultsFilePath"
    exit 1
}  

try {
    $ReadinessResults = @(Get-Content $ReadinessResultsFilePath -Raw -ErrorAction Stop | ConvertFrom-Json)
}
catch {
    Write-HostError -Message "Error found in $ReadinessResultsFilePath : $($_.Exception.Message)"
    $ExceptionData = Get-ExceptionData -Exception $_.Exception
    Send-TelemetryEventIfEnabled -TelemetryTitle "Get-SitePackage.ps1" -EventName "Error with assessment results file" -EventMessage $ReadinessResultsFile -ExceptionData $ExceptionData -EventType "error" -ErrorAction SilentlyContinue
    exit 1
}
Send-TelemetryEventIfEnabled -TelemetryTitle "Get-SitePackage.ps1" -EventName "Package site input" -EventType "info" -EventMessage "File" -ErrorAction SilentlyContinue

if (!$ReadinessResults -or $ReadinessResults.Count -eq 0) {
    Write-HostError -Message "No sites found in $ReadinessResultsFilePath"
    Send-TelemetryEventIfEnabled -TelemetryTitle "Get-SitePackage.ps1" -EventName "Error with readiness data" -ExceptionData $ExceptionData -EventType "error" -ErrorAction SilentlyContinue
    exit 1
}

if (!$MigrateSitesWithIssues) {
    Write-HostInfo -Message "Packaging sites that have passed all necessary readiness checks for migration to Azure"
}
else {
    Write-HostWarn -Message  "Packaging all sites, including those that have failed one or more (non-fatal) readiness check (if any)..."
    Write-HostWarn -Message "These sites may experience runtime errors on Azure for which the user is responsible"
    Send-TelemetryEventIfEnabled -TelemetryTitle "Get-SitePackage.ps1" -EventName "Package sites with issues" -EventType "info" -ErrorAction SilentlyContinue
}

if($ReadinessResults.Count -lt 2) #PS versions <= 5 ConvertFrom-Json results in array within top-level object
{
	$ReadinessResults = $ReadinessResults[0]
}

if ($SiteName) {
    $SitesReadinessData = $ReadinessResults | Where-Object {( $_.SiteName -eq $SiteName )}
    if ($null -eq $SitesReadinessData) {
        Write-HostError -Message "Site $SiteName not found in $ReadinessResultsFilePath"
        exit 1
   }
} else {
    $SitesReadinessData = $ReadinessResults | Where-Object {( $_.SiteName -ne $null )}
     if ($null -eq $SitesReadinessData) {
        Write-HostError -Message "No sites found in $ReadinessResultsFilePath"
        exit 1
   }
}

foreach ($Site in $SitesReadinessData) {            
    Write-HostInfo -Message "Packaging site: $($Site.SiteName)" 

    if ($Site.FatalErrorFound) {
        Write-HostWarn -Message "$($Site.SiteName) was not packaged due to a fatal error with the site." 
        Write-HostWarn -Message "This usually indicates site content is greater than 2 GB" 
        Write-HostWarn -Message "For more information, please visit: https://go.microsoft.com/fwlink/?linkid=2100815" 
        $SitePackageResult = Get-SitePackageResult -SiteName $Site.SiteName -ErrorMessage "$Site content size > 2 GB"        
    } else {
        if($Site.WarningChecks.Count -gt 0) {
            Write-HostWarn -Message "Site $($Site.SiteName) had the following warnings: $($Site.WarningChecks.IssueId -join ',')"   
        }           
        if($Site.FailedChecks.Count -gt 0) {
            Write-HostWarn -Message "Site $($Site.SiteName) had the following failed checks: $($Site.FailedChecks.IssueId -join ',')"                   
        }
        if($Site.FailedChecks.Count -gt 0 -and !$MigrateSitesWithIssues) {
            $ErrorMessage = "Site $($Site.SiteName) was not packaged. Use -MigrateSitesWithIssues to package sites with failed checks. Site runtime errors are expected post-migration." 
            Write-HostWarn -Message $ErrorMessage
            $SitePackageResult = Get-SitePackageResult -SiteName $Site.SiteName -ErrorMessage $ErrorMessage
        } else {
            #packaging step
            $SitePackageResult = Get-ZippedSite -SiteReadinessData $Site -SiteToZip $Site.SiteName                  
        }           
    }
    [void]$PackageResults.Add($SitePackageResult)
}

try {
     ConvertTo-Json $PackageResults -Depth 10 | Out-File (New-Item -Path $PackageResultsPath -ItemType "file" -ErrorAction Stop -Force)
}
catch {
    Write-HostError -Message "Error outputting package results files: $($_.Exception.Message)" 
    Send-TelemetryEventIfEnabled -TelemetryTitle "Get-SitePackage.ps1" -EventName "Error in creating package results file" -EventType "error" -ErrorAction SilentlyContinue
    exit 1
}
Write-Host ""
Send-TelemetryEventIfEnabled -TelemetryTitle "Get-SitePackage.ps1" -EventName "Script end" -EventType "action" -ErrorAction SilentlyContinue
return  $PackageResultsPath
# SIG # Begin signature block
# MIIoLQYJKoZIhvcNAQcCoIIoHjCCKBoCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDiTx2NkH1onGDk
# MMu32b3JYs12er7YwA6+6IVYvyG08qCCDXYwggX0MIID3KADAgECAhMzAAAEhV6Z
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
# MAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEIN5gMzqrVienuKbtH95sLcDQ
# MpHvcRr3LfmeKvW/krjgMEIGCisGAQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8A
# cwBvAGYAdKEagBhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEB
# BQAEggEAh0ALgix2Fg2C7D25JCqrVhdO9AacQiYt1UUiYhgd8UsrqQyXxm8wUXB5
# 4AMmHH+02/l2NZ8TK8YkgGarWsyAB4F0aNpwcL0VgwAQIMqDXvItcefXbiOKwhoU
# 3X5ubJH3CS6+nN7Wy0DsvE7iv8/F3vyVTVW0Z4q5a7XRdn8HixfLu0KEPi6F1y2S
# XebUS440GdmSiORuHHvDipDmoo9y6rBmofcjjbN9tJpUgZUdBhuc7Kt/IgFucwb6
# pIHRDPaiAl+7z5JZDC5RWcg8dm/x6CqIykFbn1ADzXdE8R4p1QZcZVrKGcpFV/ty
# fNa5CWP/zJM4BV7tIX6hG07iUzmg7aGCF5cwgheTBgorBgEEAYI3AwMBMYIXgzCC
# F38GCSqGSIb3DQEHAqCCF3AwghdsAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFSBgsq
# hkiG9w0BCRABBKCCAUEEggE9MIIBOQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFl
# AwQCAQUABCDClsIPRvfG+3+XkRzXTeNkMvr9unXvZdfb/56JGA9g+wIGaRYWGPsF
# GBMyMDI1MTEyNTAwMjEwOC41OThaMASAAgH0oIHRpIHOMIHLMQswCQYDVQQGEwJV
# UzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UE
# ChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1l
# cmljYSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRTUyBFU046ODYwMy0w
# NUUwLUQ5NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2Wg
# ghHtMIIHIDCCBQigAwIBAgITMwAAAgcsETmJzYX7xQABAAACBzANBgkqhkiG9w0B
# AQsFADB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UE
# BxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYD
# VQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMDAeFw0yNTAxMzAxOTQy
# NTJaFw0yNjA0MjIxOTQyNTJaMIHLMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2Fz
# aGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENv
# cnBvcmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25z
# MScwJQYDVQQLEx5uU2hpZWxkIFRTUyBFU046ODYwMy0wNUUwLUQ5NDcxJTAjBgNV
# BAMTHE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2UwggIiMA0GCSqGSIb3DQEB
# AQUAA4ICDwAwggIKAoICAQDFP/96dPmcfgODe3/nuFveuBst/JmSxSkOn89ZFytH
# Qm344iLoPqkVws+CiUejQabKf+/c7KU1nqwAmmtiPnG8zm4Sl9+RJZaQ4Dx3qtA9
# mdQdS7Chf6YUbP4Z++8laNbTQigJoXCmzlV34vmC4zpFrET4KAATjXSPK0sQuFhK
# r7ltNaMFGclXSnIhcnScj9QUDVLQpAsJtsKHyHN7cN74aEXLpFGc1I+WYFRxaTgq
# SPqGRfEfuQ2yGrAbWjJYOXueeTA1MVKhW8zzSEpfjKeK/t2XuKykpCUaKn5s8sqN
# bI3bHt/rE/pNzwWnAKz+POBRbJxIkmL+n/EMVir5u8uyWPl1t88MK551AGVh+2H4
# ziR14YDxzyCG924gaonKjicYnWUBOtXrnPK6AS/LN6Y+8Kxh26a6vKbFbzaqWXAj
# zEiQ8EY9K9pYI/KCygixjDwHfUgVSWCyT8Kw7mGByUZmRPPxXONluMe/P8CtBJMp
# uh8CBWyjvFfFmOSNRK8ETkUmlTUAR1CIOaeBqLGwscShFfyvDQrbChmhXib4nRMX
# 5U9Yr9d7VcYHn6eZJsgyzh5QKlIbCQC/YvhFK42ceCBDMbc+Ot5R6T/Mwce5jVyV
# CmqXVxWOaQc4rA2nV7onMOZC6UvCG8LGFSZBnj1loDDLWo/I+RuRok2j/Q4zcMnw
# kQIDAQABo4IBSTCCAUUwHQYDVR0OBBYEFHK1UmLCvXrQCvR98JBq18/4zo0eMB8G
# A1UdIwQYMBaAFJ+nFV0AXmJdg/Tl0mWnG1M1GelyMF8GA1UdHwRYMFYwVKBSoFCG
# Tmh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY3JsL01pY3Jvc29mdCUy
# MFRpbWUtU3RhbXAlMjBQQ0ElMjAyMDEwKDEpLmNybDBsBggrBgEFBQcBAQRgMF4w
# XAYIKwYBBQUHMAKGUGh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY2Vy
# dHMvTWljcm9zb2Z0JTIwVGltZS1TdGFtcCUyMFBDQSUyMDIwMTAoMSkuY3J0MAwG
# A1UdEwEB/wQCMAAwFgYDVR0lAQH/BAwwCgYIKwYBBQUHAwgwDgYDVR0PAQH/BAQD
# AgeAMA0GCSqGSIb3DQEBCwUAA4ICAQDju0quPbnix0slEjD7j2224pYOPGTmdDvO
# 0+bNRCNkZqUv07P04nf1If3Y/iJEmUaU7w12Fm582ImpD/Kw2ClXrNKLPTBO6nfx
# vOPGtalpAl4wqoGgZxvpxb2yEunG4yZQ6EQOpg1dE9uOXoze3gD4Hjtcc75kca8y
# ivowEI+rhXuVUWB7vog4TGUxKdnDvpk5GSGXnOhPDhdId+g6hRyXdZiwgEa+q9M9
# Xctz4TGhDgOKFsYxFhXNJZo9KRuGq6evhtyNduYrkzjDtWS6gW8akR59UhuLGsVq
# +4AgqEY8WlXjQGM2OTkyBnlQLpB8qD7x9jRpY2Cq0OWWlK0wfH/1zefrWN5+be87
# Sw2TPcIudIJn39bbDG7awKMVYDHfsPJ8ZvxgWkZuf6ZZAkph0eYGh3IV845taLkd
# LOCvw49Wxqha5Dmi2Ojh8Gja5v9kyY3KTFyX3T4C2scxfgp/6xRd+DGOhNVPvVPa
# /3yRUqY5s5UYpy8DnbppV7nQO2se3HvCSbrb+yPyeob1kUfMYa9fE2bEsoMbOaHR
# gGji8ZPt/Jd2bPfdQoBHcUOqPwjHBUIcSc7xdJZYjRb4m81qxjma3DLjuOFljMZT
# YovRiGvEML9xZj2pHRUyv+s5v7VGwcM6rjNYM4qzZQM6A2RGYJGU780GQG0QO98w
# +sucuTVrfTCCB3EwggVZoAMCAQICEzMAAAAVxedrngKbSZkAAAAAABUwDQYJKoZI
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
# MCUGA1UECxMeblNoaWVsZCBUU1MgRVNOOjg2MDMtMDVFMC1EOTQ3MSUwIwYDVQQD
# ExxNaWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNloiMKAQEwBwYFKw4DAhoDFQDT
# vVU/Yj9lUSyeDCaiJ2Da5hUiS6CBgzCBgKR+MHwxCzAJBgNVBAYTAlVTMRMwEQYD
# VQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNy
# b3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1w
# IFBDQSAyMDEwMA0GCSqGSIb3DQEBCwUAAgUA7M8TmjAiGA8yMDI1MTEyNDE3MjU0
# NloYDzIwMjUxMTI1MTcyNTQ2WjB3MD0GCisGAQQBhFkKBAExLzAtMAoCBQDszxOa
# AgEAMAoCAQACAij8AgH/MAcCAQACAhP0MAoCBQDs0GUaAgEAMDYGCisGAQQBhFkK
# BAIxKDAmMAwGCisGAQQBhFkKAwKgCjAIAgEAAgMHoSChCjAIAgEAAgMBhqAwDQYJ
# KoZIhvcNAQELBQADggEBABSsiN2+G9da6oWdFnpts3Y5nHn2JN9JDLwfY5RiQzBv
# Uwd8/t3NSdKeLQkJkqDRd87ApHzT2KotSlxvER9NFkq+AHnSGR214fDJORMRsYXr
# 90+a4yftZfIssJc0rgr514aiOD3yUyShA3PIoG9bY4uWRHYGahf8ciSwAuZ5N9aU
# Z0VNUl7pGbIIH4VisYQI0Q+1DaKKby8LYLdGB+wCJnyja8/+t2JAIs8UDRMFbcal
# aS/ZFcCs928NKsGfItN7UaOYGW4dmuSBD4KJKrpf4fzDuFlqvnskn75WJiw7kLfW
# ObOmLsjwYVZNLUFuR3hUZ63Hyd+aKuMhbDIzm0Lf2EQxggQNMIIECQIBATCBkzB8
# MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVk
# bW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1N
# aWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMAITMwAAAgcsETmJzYX7xQABAAAC
# BzANBglghkgBZQMEAgEFAKCCAUowGgYJKoZIhvcNAQkDMQ0GCyqGSIb3DQEJEAEE
# MC8GCSqGSIb3DQEJBDEiBCCMorXmuDloesHJt7XW3DJhwrtVMjSlwme0sW6O1QWu
# rTCB+gYLKoZIhvcNAQkQAi8xgeowgecwgeQwgb0EIC/31NHQds1IZ5sPnv59p+v6
# BjBDgoDPIwiAmn0PHqezMIGYMIGApH4wfDELMAkGA1UEBhMCVVMxEzARBgNVBAgT
# Cldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29m
# dCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENB
# IDIwMTACEzMAAAIHLBE5ic2F+8UAAQAAAgcwIgQgH0IRrlcNkYj6vzPhgItrdj3+
# 5oV4X/gBnTD9/pvfTukwDQYJKoZIhvcNAQELBQAEggIAI/jS0yewtxQbbUtvs3hU
# p87ei+ngiPAxMeSj93b74/UznkNPnIdhOthdS9f1jQ7UEb2EgLcnC4mOc9n6lg9y
# Pj+nVLj4gEgWTWoDVFrLtnx9ECjuRCMNg5+TcbAKLCMRKhY6QhTttfQxj0CMUSWv
# EHTQ2+dVh8RrLV+VPJmPa/olPTagcixxa8JRmg4iU32tqQzZIrCZYNwsAbpen85R
# Y7+M7kXkTk3zXtNIlxOtQccTkTO59CTxPuiy9RFyYBgGhBiDnLp8xI2R3Uqu4mvl
# hjPdDwL8OHKdp1KejKJyWL407vSno6EIxgMcGTNoar7kn128Cb+RqrFAkJhlImlt
# boEsEsfG3NMrMCm/JUMg9HFOVZMT1wln+RbaxeJRDY1wyyit3TSiyzhZ6bCV7ajT
# RFYpZ7BqO0EdbuB2uPygoXoUGGHpPoBQueNK1BxBm1sEO9oVeeuRXtjlsRZgIsGl
# DN93M0mtAb6g3Ru27w6Cq5r05QFB7+tHxVq1mrv2wdfH7hHEZig5kZHYGYubU0fv
# ppthbtSjujbiOvgs6tytJnpBldnZWYUtH5GhJTfr28gKrXSqfloEoikrcd99dYSZ
# f3pn3dhI+pT6pdIZZVuJ5qFV4AHrrIUpN59pegKYPVhNAxblzgt0TE4F/Fx4yZGa
# 1wezQ7G7wJ4s4R5aZgEGxlA=
# SIG # End signature block
