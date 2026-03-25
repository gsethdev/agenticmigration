param(
	[Parameter()]
	[string]$targetSiteName,

    [Parameter()]
    [string]$zipOutputFilePath,

	[Parameter()]
    [string]$localSiteConfigFile
)

if(-not $targetSiteName) { $targetSiteName = "%%SITENAME%%" }
Write-Output "targetSiteName value is: $targetSiteName" 
Write-Output "Process Is64BitProcess: $([Environment]::Is64BitProcess)"
#Test-WSMan -ErrorVariable errorvar -ErrorAction SilentlyContinue
#if(!$errorvar) {
#    $maxMemoryInMBValue = (Get-Item WSMan:\localhost\Shell\MaxMemoryPerShellMB).Value
#    Write-Output "Max memory (MB): $maxMemoryInMBValue"
#}
Write-Output "PS version is: $($PSVersionTable.PSVersion)"

function GetZipRelativePath {
	param($fullPhysicalPath, $siteHomeDirectory)

	$relativePath = "";

	if($fullPhysicalPath.ToLower() -eq $siteHomeDirectory.ToLower()) {
		return "site\wwwroot";
	} elseif ($fullPhysicalPath.ToLower().StartsWith($siteHomeDirectory.ToLower())) {
		$relativePath = "site\wwwroot\$($fullPhysicalPath.Substring($siteHomeDirectory.Length + 1))";
	} else {
		$relativePath = "site\";
		$PathRoot = [System.IO.path]::GetPathRoot($fullPhysicalPath).ToUpper().TrimEnd('\');
		foreach($char in $PathRoot.toCharArray()) {
			if($char -eq ':') {
				$relativePath += "_C";
			} elseif($char -eq '\') {
				$relativePath += "_S";
			} elseif($char -eq '_') {
				$relativePath += "_N";
			} else {
				$relativePath += $char;
			}
		}
		$relativePath += $fullPhysicalPath.Substring($PathRoot.Length);
	}
	return $relativePath;
}       

function GetContentPathsAndZip {
	$sm = New-Object Microsoft.Web.Administration.ServerManager; 
    $Config = $sm.GetApplicationHostConfiguration();	     
    $SitesSection = $Config.GetSection("system.applicationHost/sites"); 	 	

	$foundUNCPath = $false;
	$errorId = "";
	$errorMsg = "";
	$siteMatchFound = $false;    
 
 	$maxBytesSize = 2 * 1024 * 1024 * 1024; # 2GB		
 	$targetSiteInfo = $null;

    foreach($siteSection in $SitesSection.GetCollection()) {          
 		$siteName = $siteSection['name'];
 		if($siteName -ne $targetSiteName) {
 			continue;
 		}       
 		Write-Output "Found site on server";
		$siteMatchFound = $true; 		 				 		
 		$runningContentSize = 0; 
		$dirPathsToZip = @{} 

		# Each site must have a root application, otherwise various other things will fail due to this invalid config
		if( @($siteSection.GetCollection()| Where-Object {$_['path'] -eq '/'}).Count -lt 1) {				
			$errorId = "IISWebServerInvalidSiteConfig" 
			$errorMsg = "Invalid IIS configuration encountered, the site has no root application defined."
 			Write-Output "Site is missing root application."						
			break;
		}

 		$siteRootVDir = ($siteSection.GetCollection() | Where-Object {$_['path'] -eq '/'}).GetCollection() | Where-Object {$_['path'] -eq '/'}
 		$siteRootPhysicalPath = [System.Environment]::ExpandEnvironmentVariables($siteRootVDir['physicalPath'])		

 		foreach($appPool in $siteSection.GetCollection()) {		
		
 			foreach($vdir in $appPool.GetCollection()) {							
 				$expandedFullPath = [System.Environment]::ExpandEnvironmentVariables($vdir['physicalPath']);
 				
 				if($vdir['physicalPath'].StartsWith("\\") -and (-not($vdir['physicalPath'].StartsWith("\\?\")) -or $vdir['physicalPath'].StartsWith("\\?\UNC\"))){	
					$foundUNCPath = $true 		
					continue;					
 				} else {
					$isSubPathOfExistingZipPath = $false;
					$removePaths = @{};
 					# check if vdirs already has parent of path or is a parent or a path in vdirs, add or not accordingly
					# ex: could have vdirs like /photos = c:\foo\photos, /app2/photos = c:\foo\photos, /icons = c:\foo\photos\bar\icons, should end up with single c:\foo\photos in vdirs 
					foreach($dirPath in $dirPathsToZip.Keys) {
						if($expandedFullPath.ToLower().StartsWith($dirPath.ToLower())) {
							$isSubPathOfExistingZipPath = $true;
							break;
						} elseif($dirPath.ToLower().StartsWith($expandedFullPath.ToLower())){
							$removePaths.Add($dirPath, "");
						}
					}
					#only add unique directories to .zip package
					if(-not($dirPathsToZip.ContainsKey($expandedFullPath)) -and -not($isSubPathOfExistingZipPath)) {
						$dirPathsToZip.Add($expandedFullPath, "");
					}
					if($removePaths.Count > 0) {
						foreach($k in $removePaths.Keys) {
							$dirPathsToZip.Remove($k);
						}
					}			
 				}
 			}
			
 		}		


		# if no UNC issues, start iterating through vdirs to create .zip - do running content size check and stop if exceeds 2GB with error
		if($foundUNCPath -and $dirPathsToZip.Count -lt 1) {
			$errorId = "IISWebAppUNCContentDirectory" 
			$errorMsg = "Web app contains only UNC directory content. UNC directories are not currently supported for migration."			 		
 		} else {
			if($zipOutputFilePath) {				
				# no validation of directory pre-existing or accessible
				$targetZipPath = $zipOutputFilePath
			} else {
				$timeId = (Get-Date).ToString("yyyyMMddhhmmss")
				$targetZipPath = "$($Env:temp)\$($timeId)_tempZipFile.zip"
			}
 			Write-Output "Target zip path: $targetZipPath" 
						
			$sm = $null
			$Config = $null     
			$SitesSection = $null
			[GC]::Collect()
			Write-Output "memory use: $([System.GC]::GetTotalMemory($false))"
			 			
			try {	
				# System.Io.Compression.ZipFile is .NET Fx 4.5+, this likely requires PSv4 minimum version
 				[System.Reflection.Assembly]::LoadWithPartialName('System.IO.Compression.ZipArchive') | Out-Null
 				[System.Reflection.Assembly]::LoadWithPartialName('System.IO.Compression.ZipFile') | Out-Null
 				[System.Reflection.Assembly]::LoadWithPartialName('System.IO.Compression.FileSystem') | Out-Null
 				[System.Reflection.Assembly]::LoadWithPartialName('System.IO.Compression.ZipFileExtensions') | Out-Null
 				$zipArch = [System.IO.Compression.ZipFile]::Open($targetZipPath,1) 	
 										
				foreach($vdir in $dirPathsToZip.Keys) {							
 					$expandedFullPath = $vdir
 					$zipPath = GetZipRelativePath -fullPhysicalPath $expandedFullPath -siteHomeDirectory $siteRootPhysicalPath					
					if($runningContentSize -gt $maxBytesSize) {
						Write-Output "Running content size exceeded limit";
						break;
					}
					
					# piping ForEach uses significantly less memory than foreach with index, which will hit max memory limits for large number of files
					Get-ChildItem $expandedFullPath -recurse | ForEach {
						if($_.PSIsContainer) {
							# Currently completely empty directories will be lost during the copy as they never have a CreateEntryFromFile occur							
 						} else { 
 							$runningContentSize += $_.Length	
 							if( $runningContentSize -le $maxBytesSize) {								
 								$fileRelativePath = $zipPath + $_.FullName.Substring($expandedFullPath.Length); 									
 								$a = [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($ziparch, $_.FullName, $fileRelativePath)			
 							} else {
								break;
							}
 						}
					}
 				}
				
				if($localSiteConfigFile -and (Test-Path -Path $localSiteConfigFile)) {
					[System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($ziparch, $localSiteConfigFile, "SiteConfig.json")
				}
					
 				$zipArch.Dispose()
			} catch {
				$errorId = "IISWebAppFailureCompressingSiteContent" 
				$errorMsg = "Exception occurred compressing site content: $($_.Exception)"
 				Write-Output "Exception zipping content: $($_.Exception)"						
				break;
 			}
 		
		} 	
 
 		if($runningContentSize -gt $maxBytesSize) { 			
			$errorId = "IISWebAppExceededMaxContentSize"
			$errorMsg = "Content size exceeded max content size (2 GB) for migration using this tool."
 		} 
 		       
 		break;
    }        

	if(-not $siteMatchFound) {
		$errorId = "IISWebAppNotFoundOnServer"
		$errorMsg = "Web application with name '$targetSiteName' not found on web server"
	}
  	
	Write-Output "targetZipPath: '$targetZipPath', ErrorId: '$errorId', ErrorOccurred: '$errorMsg'"

	$ServerInfo = New-Object -TypeName PSObject 
	$ServerInfo | Add-Member -MemberType NoteProperty -Name appContentZipPath -Value $targetZipPath		
 	 
 	if($errorId) {
		$errorObj = New-Object -TypeName PSObject
 		$errorObj | Add-Member -MemberType NoteProperty -Name code -Value $errorId
		if($errorMsg){
			$errorObj | Add-Member -MemberType NoteProperty -Name message -Value $errorMsg
		}		
		$ServerInfo | Add-Member -MemberType NoteProperty -Name error -Value $errorObj 	
	}  

	$ServerInfo | ConvertTo-Json -depth 5 | Write-Output
 }

 function GetErrorInfoObjFromException {
	param($errorId, $exception )
	
	$hresultString = "";
	if($exception.HResult) {
		$hresultString = $exception.HResult.ToString("X");
	}	
	$errorObject = New-Object -TypeName PSObject
	$errorObject | Add-Member -MemberType NoteProperty -Name code -Value $errorId
    $errorObject | Add-Member -MemberType NoteProperty -Name message -Value "$($exception.Message), HResult: $hresultString"	
	return $errorObject
}


$ErrorActionPreference = "Stop"; #Make all errors terminating
$ServerInfo = New-Object -TypeName PSObject
$errorObj = $null
try {
	# first confirm this is PS4.0+ version 
	if($PSVersionTable.PSVersion.Major -lt 4) {
	    Write-Output "PowerShell version too low!"
		Write-Output '{"appContentZipPath": "","error": {"code": "IISWebServerPowerShellVersionLessThan4","message":"PowerShell version on IIS web server was less than minimum required PowerShell version 4"} }'
		exit
	} else {
		#LoadMWH
		$iisInstallPath = [System.Environment]::ExpandEnvironmentVariables("%windir%\system32\inetsrv\Microsoft.Web.Administration.dll");
		[System.Reflection.Assembly]::LoadFrom($iisInstallPath) | Out-Null; 	

		try {
			GetContentPathsAndZip  				
		}  catch [System.Security.SecurityException] {    
			$errorObj = GetErrorInfoObjFromException -errorId "IISWebServerAccessFailedError" -exception $_.Exception			    
		} catch [System.Management.Automation.MethodInvocationException] {    		
			$errorObj = GetErrorInfoObjFromException -errorId "IISWebAppMigrationError" -exception $_.Exception		
		}
	}
}
catch [System.IO.FileNotFoundException] {    
	$errorObj = GetErrorInfoObjFromException -errorId "IISWebServerIISNotFoundError" -exception $_.Exception	
} catch [System.Security.SecurityException] {    
	$errorObj = GetErrorInfoObjFromException -errorId "IISWebServerAccessFailedError" -exception $_.Exception 	
} catch [System.Management.Automation.MethodInvocationException] {    
	# this can occur due to file access issues, including on apphost or redirection config
	$errorObj = GetErrorInfoObjFromException -errorId "IISWebServerAccessFailedError" -exception $_.Exception	
} catch {	
	$errorObj = GetErrorInfoObjFromException -errorId "IISWebServerPowerShellError" -exception $_.Exception	
}finally{
	if($errorObj){		  
		$ServerInfo | Add-Member -MemberType NoteProperty -Name error -Value $errorObj 
		$ServerInfo | ConvertTo-Json -depth 5 | Write-Output				
	} 

   $ErrorActionPreference = "Continue"; #Reset the error action pref to default
}


# SIG # Begin signature block
# MIIoLQYJKoZIhvcNAQcCoIIoHjCCKBoCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCCJNoJWJfiPMOec
# INjcM62YmmI8GHVilLrpaviA35t5CqCCDXYwggX0MIID3KADAgECAhMzAAAEhV6Z
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
# MAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEIEUyOrxID1kop8QMy8w5Hpb6
# EN4vaXFsOrOgdxc/nqN2MEIGCisGAQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8A
# cwBvAGYAdKEagBhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEB
# BQAEggEAD0m+bJi6MtGp56TjlDLCDTZT9Lb74m5MlxJna+74cjwbQVriM4Fs8sm6
# sTpLofEeGJGoBvC63/XXpGck8VFGUQZnROPffYRXVQK12++fyIFS7Djba7/zxGDn
# nAtnMyQEQuRHiDl1OWueXZrpk1HpWb4yi2tUkRXTZp4y3H/SafSeBGbn3sAwmr8b
# 1Tcge88v+FDR29fNISTePCr3crPYSPbbx8O0NNnM1ir4rwMIBWtMpjGJ9gHfFyLL
# QLnN2wyKbZ9plFetSatQ+jXIEm06M8/+ZlEwOrYZGTtzZgi5u5QCZOe50m8waGEm
# NLPY9axVDKJRTQM6XpjMttPSI6FAeaGCF5cwgheTBgorBgEEAYI3AwMBMYIXgzCC
# F38GCSqGSIb3DQEHAqCCF3AwghdsAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFSBgsq
# hkiG9w0BCRABBKCCAUEEggE9MIIBOQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFl
# AwQCAQUABCBYU6jQIKZPzEcDqK/s0yscy7dTXrNEns6WCQMUysK3zAIGaSTkQCf2
# GBMyMDI1MTEyNTAwMjEwOC44NTZaMASAAgH0oIHRpIHOMIHLMQswCQYDVQQGEwJV
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
# MC8GCSqGSIb3DQEJBDEiBCBGTIv6BypfaLPnoJbKXa2eqiKQvjF4uGWRBfpLR0eR
# 1DCB+gYLKoZIhvcNAQkQAi8xgeowgecwgeQwgb0EIGgbLB7IvfQCLmUOUZhjdUqK
# 8bikfB6ZVVdoTjNwhRM+MIGYMIGApH4wfDELMAkGA1UEBhMCVVMxEzARBgNVBAgT
# Cldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29m
# dCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENB
# IDIwMTACEzMAAAIJCAfg+VyM5lUAAQAAAgkwIgQgcAFJblmoRXrEkGhegUwX9zS7
# m+rTFlnqk0Z4S6oqKdwwDQYJKoZIhvcNAQELBQAEggIAM28UrlUQaxXn0hwT2Jhe
# U/3rp/j1kNfCdcAOUCci2w4ArxHG7j6gdAbiMV19E4gZoAoupJL0IFo/lUIuDMBU
# DALKtyqvvXwVjfgVH6wpD+UFhwYJckJIjTMhLamxj4XaAA+ZumhbGk8HOo+PxTMZ
# 2mjQL9t5HcRcgVSdHSDnxdoz1Q12iYZSHflGKcg2MVKxfpQq+Wo255fJdUA8sH0s
# ZRMRv9dGXrzY+9M2mzz/D6RFsgIskHAdWYhHk+3miwkcl/kXbVZ7erjK4FQFJ739
# OQV1E5ktI79TdRGGmzvnd1sIYnquXoO17Zr5RrGG1wC+vPNWPueUbJW6l31ikzm2
# /CAzErGhQmDZftkno8I4NnLJs9ewerooUK4tIYeZ2b3x6+jetDfb70sleIr8xlSf
# i5xyzybn+YPMgqX6TWf2QYB3v0mdAzdTSJPltsjvg4z+KbVekej9f5BJsnn4HzgS
# 8OTVMpFHfbJ/pXzFkfaip02v+VfOdoa8RUzQGO9CEBN+uU2yruw2mg7RP/3MRSDv
# L7N9NaLzuFI1lhvjHW+JlSiD84edhUkv6VQIEA/bANgLerrXcT01gVAu2xNiVK25
# S3k7AQEPuwgK+Zmtt3EiUv4g/fvU4Mv96OlozmjWp+CUTCVAfuH/B+PaGZ9XnyWQ
# aeZccmqcuItO1W2yIU0dA8U=
# SIG # End signature block
