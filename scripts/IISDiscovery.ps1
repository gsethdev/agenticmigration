param(
	[Parameter()]
	[bool]$aggressiveBlocking = $false
)

function GetConfigPaths {
    $sm = New-Object Microsoft.Web.Administration.ServerManager; 
    $Config = $sm.GetApplicationHostConfiguration();
    $configPathsSection = $Config.GetSection("configPaths")   
    [System.Collections.ArrayList]$allPaths = @()	
	
	$configPathsSection.GetCollection() | ForEach-Object {
		$pathValue =  $_['path'];
		$locationPath = $_['locationPath'];
		
		$configRelativePath = "/";
		$siteName = "";
		$relativeSiteConfigPath = "";
		$heirarchyIndex = 2; # 0 = APPHOST, 1 = APPHOST with site root Location, 2 = site root web.config, 3 = anything lower
		$configError = "";
		if($pathValue.StartsWith("MACHINE/WEBROOT/APPHOST/")) { 
			$configRelativePath = $pathValue.Substring(23);
			$sitePartialPath = $pathValue.Substring(24);
			if($sitePartialPath.Contains("/")) {
				$heirarchyIndex = 3;
				$relativeSiteConfigPath = $sitePartialPath.Substring($sitePartialPath.IndexOf('/'));
				$sitePartialPath = $sitePartialPath.Substring(0, $sitePartialPath.IndexOf('/'));            
			}        
			$siteName = $sitePartialPath;                 
		} elseif ( -not ([string]::IsNullOrEmpty($locationPath))) { 
			$heirarchyIndex = 1;   
			$siteName = $locationPath;
			if($locationPath.Contains("/")) {                
				$heirarchyIndex = 3;
				$siteName = $locationPath.Substring(0, $locationPath.IndexOf('/'));   				
			}                    
		} else {
			$heirarchyIndex = 0;
		}
		
		$pathConfigObject = $null;
		$sections = @{}
		
		$configElementCollection = $_.GetCollection();
		if ($configElementCollection.Count -lt 1 -and $siteName -ne "") {		
		
			$configError = "Configuration path contains no sections. This can be due to issues such as invalid configuration or permissions.";
			# no sections in config indicates an issue with reading config - try to get more specific error with GetWebConfiguration                
		    try {
		       if($siteName -ne "" -and $siteName -ne "/") {
		           $BadConfig = $sm.GetWebConfiguration($siteName, $relativeSiteConfigPath);
		           $root = $BadConfig.RootSectionGroup; #this should throw
		       }
		    }
		    catch
		    {
				$configError = GetConfigErrorFromException -exception $_.Exception -configPath $configRelativePath -location $locationPath	
		    }
		} else {			
			[array]$sectionsInConfig = $configElementCollection | Select -ExpandProperty RawAttributes | ForEach-Object {$_.name}
			$additionalSectionsToGet = $null;			
			if($pathValue -eq "MACHINE/WEBROOT/APPHOST") {		
				$pathConfigObject = $Config;
				if($heirarchyIndex -eq 0) {
					$additionalSectionsToGet = @("system.applicationHost/sites", "system.webServer/globalModules")
				}
			} else {
				$pathConfigObject = $sm.GetWebConfiguration($siteName, $relativeSiteConfigPath);   				
			}
			$sections = GetConfigSections -Config $pathConfigObject -locationPath $locationPath -configPath $configRelativePath -sectionsInConfig $sectionsInConfig -additionalSections $additionalSectionsToGet			
		}						
		
		if($pathvalue -ne "") {            
			$newPath = New-Object -TypeName PSObject
			$newPath | Add-Member -MemberType NoteProperty -Name path -Value $pathValue
			$newPath | Add-Member -MemberType NoteProperty -Name locationPath -Value $locationPath
			$newPath | Add-Member -MemberType NoteProperty -Name configPath -Value $configRelativePath
			$newPath | Add-Member -MemberType NoteProperty -Name site -Value $siteName
			$newPath | Add-Member -MemberType NoteProperty -Name relativeSitePath -Value $relativeSiteConfigPath			
			$newPath | Add-Member -MemberType NoteProperty -Name sections -Value $sections
			$newPath | Add-Member -MemberType NoteProperty -Name heirarchyIndex -Value $heirarchyIndex
			$newPath | Add-Member -MemberType NoteProperty -Name configError -Value $configError
			$addedIndex = $allPaths.Add($newPath)		
		}   		
	}

$allPaths  
}

function GetConfigSections {
    param( $Config, $locationPath, $configPath, $sectionsInConfig, $additionalSections)
	
	$configSections = @{};
	$sectionNamesOfInterest = @{};
   
	$defaultSections = @("system.webServer/handlers", "system.webServer/isapiFilters", "system.webServer/httpPlatform",		
		"system.webServer/security/authentication/basicAuthentication",
		"system.webServer/security/authentication/clientCertificateMappingAuthentication", 
		"system.webServer/security/authentication/iisClientCertificateMappingAuthentication", 
		"system.webServer/security/authentication/digestAuthentication",
		"system.webServer/security/authentication/windowsAuthentication");

	if($additionalSections) {
		$defaultSections += $additionalSections
	}		

	foreach($section in $defaultSections) {
		if($sectionsInConfig -contains $section) {
			$sectionNamesOfInterest.Add($section, "");
		}
	}
    	
	foreach($sectionPath in $sectionNamesOfInterest.Keys) {    	   
        try {
            $configSectionOfInterest = $Config.GetSection($sectionPath, $locationPath);			
			$retVal = @{"section"=$configSectionOfInterest;"isValid"=$true}
			$configSections.Add($sectionPath, $retVal);
		} catch {			           
			$configErrorString = GetConfigErrorFromException -exception $_.Exception -configPath $configPath -location $locationPath -configSection $sectionPath
			$configError = @{"isValid"=$false;"configError"=$configErrorString}			
			$configSections.Add($sectionPath, $configError)
		}
	}	
	
	# add different format for CS section to avoid holding memory in the full config iteration loop
	$csSectionPath = "connectionStrings"	
	$containsCsSection = $sectionsInConfig -contains $csSectionPath
	$configSections.Add($csSectionPath, @{"exists"=$containsCsSection;"isValid"=$true}) 
		
	$configSections;
}

function GetConnectionStrings {
	param($siteObject, $configErrorCheck)
			
	$sm = New-Object Microsoft.Web.Administration.ServerManager;	
	$configConnectionStrings = @()
	$encounteredError = $false;	 
	
	foreach($p in $siteObject.configPaths) {  
		$configError = "";          
		if($p.configError -eq "") {   
			if($p.sections["connectionStrings"].exists) {			
				try {				
					if($p.path -eq "MACHINE/WEBROOT/APPHOST") {							
						$thisconfig = $sm.GetApplicationHostConfiguration();
					} else {						
						$thisconfig = $sm.GetWebConfiguration($p.site, $p.relativeSitePath);
					}
					
					$csSection = $thisconfig.GetSection("connectionStrings", $p.locationPath); 					 
					foreach ($cs in $csSection.GetCollection()) {						
						if($cs.IsLocallyStored) {
							#only add connection strings from the current configuration file
							$csInfo = New-Object -TypeName PSObject
							$csInfo | Add-Member -MemberType NoteProperty -Name name -Value $cs['name']
							$csInfo | Add-Member -MemberType NoteProperty -Name virtualPath -Value $p.configPath 
							$csInfo | Add-Member -MemberType NoteProperty -Name locationPath -Value $p.locationPath  
							$configConnectionStrings += $csInfo
						} 							                           
					}							
				
				} catch {			           
					$encounteredError = $true						
					$errorString = GetConfigErrorFromException -exception $_.Exception -configPath $p.configPath -location $p.locationPath -configSection "connectionStrings"	
					$configErrorCheck = AppendFailCheckResults $errorString -newLocation $p.configPath -prevCheckResults $configErrorCheck
				}

			}				
		} # no else for if config path had top-level errors 	
	} # end foreach config
	      
	$configConnectionStrings
}

function GetConfigErrorFromException {
	param( $exception, $configPath, $location, $configSection )
	
	$combinedString = "message=$($exception.Message)"
	if($exception.HResult) {
		$hresultString = $exception.HResult.ToString("X");
		$combinedString = "$combinedString;hresult=$hresultString"
	}	
	if($configPath) {
		$combinedString ="$combinedString;path=$configPath"
	}
	if($location) {
		$combinedString ="$combinedString;location=$location"
	}
	if($configSection) {
		$combinedString ="$combinedString;sectionName=$configSection"
	}

	$combinedString
}

function GetConfigErrorInfoObj {
	param($errorId, $exception, $message )

	if(-not $message) {
		if($exception) {
			$message = $exception.Message;
		} else { $message = "" }
	}

	$errorObject = New-Object -TypeName PSObject
	$errorObject | Add-Member -MemberType NoteProperty -Name errorId -Value $errorId
	$errorObject | Add-Member -MemberType NoteProperty -Name detailedMessage -Value $message
	$errorObject | Add-Member -MemberType NoteProperty -Name hResult -Value ""
	$errorObject | Add-Member -MemberType NoteProperty -Name stackTrace -Value ""
	$errorObject | Add-Member -MemberType NoteProperty -Name exceptionType -Value ""
			
	if($exception) {
		if($exception.HResult) {
			$errorObject.hResult = $exception.HResult.ToString("X");
		}	
		$errorObject.stackTrace = $exception.Stacktrace
		$errorObject.exceptionType = $exception.GetType().fullname
	}
	
	return $errorObject
}

function GetApplicationPools {
    $sm = New-Object Microsoft.Web.Administration.ServerManager; 
    $Config = $sm.GetApplicationHostConfiguration();
    $appPoolSection = $Config.GetSection("system.applicationHost/applicationPools")   
    
	$appPools = @{};
    foreach($appPool in $appPoolSection.GetCollection()) {	
		if(-not($appPools.ContainsKey($appPool['name']))) {
			$poolProperties = @{			
				"enable32BitAppOnWin64" = $appPool['enable32BitAppOnWin64'];
				"managedRuntimeVersion" = $appPool['managedRuntimeVersion'];
				"managedPipelineMode" = $appPool['managedPipelineMode'];
				"identityType" = $appPool.GetChildElement('processModel')['identityType']; #is an ENUM value
			}
			$appPools.Add($appPool['name'], $poolProperties);  
		}
    }
	$appPools 
}	

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

function AppendFailCheckDetail {
    param([string] $newDetails, $prevCheckResults)  
    if($newDetails -eq $null) { $newDetails = ""}	
	$prevCheckResults.detailsString += $newDetails;
	$prevCheckResults.result = "Fail";
    return $prevCheckResults
} 

function AppendFailCheckResults {
    param([string] $newDetails, [string] $newLocation, $prevCheckResults)  
    if($newDetails -eq $null) { $newDetails = ""}
	if($newLocation -eq $null) { $newLocation = ""}
	$newDetail = New-Object -TypeName PSObject
    $newDetail | Add-Member -MemberType NoteProperty -Name location -Value $newLocation			  
    $newDetail | Add-Member -MemberType NoteProperty -Name detail -Value $newDetails
	$prevCheckResults.detailsArray += $newDetail;
	$prevCheckResults.result = "Fail";
    return $prevCheckResults
} 

function CondenseDetailsArrayToString {
	param($CheckResults)  
    $detailString = "";
	foreach($d in $CheckResults.detailsArray) {		
		if($d.location -ne $null -and $d.location -ne "") {
			$detailString = "$detailString$($d.detail) ($($d.location)), "
		} else {
			$detailString = "$detailString$($d.detail), ";
		}
	}
	if($detailString.EndsWith(', ')) {
		$detailString = $detailString.Substring(0, $detailString.Length-2)
	}	
	$CheckResults.detailsString += $detailString;	
	$CheckResults.PSObject.Properties.Remove('detailsArray')
    $CheckResults
}
        
function DiscoverAndAssess {
	param($configPaths, $appPoolSettings, $webServerBase)

	$appHostConfigPathObject = $configPaths | Where-Object {$_.path -eq "MACHINE/WEBROOT/APPHOST" -and $_.locationPath -eq ""} | Select-Object -First 1	

    $allSites = @();
    $SitesSection = $appHostConfigPathObject.sections["system.applicationHost/sites"].section; 
	#TODO: check that $appHostConfigPathObject.sections["system.applicationHost/sites"].isValid -eq true or fail here, and non null

	# # PS VERSION CHECK FOR MIGRATION
	# $psVersionCheck = [pscustomobject]@{IssueId="PSVersionCheck";result="Pass";detailsString=""};
	# try {
	# 	$majorVersion = $PSVersionTable.PSVersion.Major
	# 	if($majorVersion -lt 4) {							
	# 		$psVersionCheck = AppendFailCheckDetail -prevCheckResults $psVersionCheck -newDetails "$majorVersion"
	# 	} 		
	# } catch {	
	#     $psVersionCheck = AppendFailCheckDetail -prevCheckResults $psVersionCheck -newDetails "Failed to determine version"
	# }

    foreach($siteSection in $SitesSection.GetCollection()) {          
		$siteName = $siteSection['name'];		
        $newSite = New-Object -TypeName PSObject
        $newSite | Add-Member -MemberType NoteProperty -Name webAppName -Value $siteName
		
		#default pass check objects
		$configErrorCheck = [pscustomobject]@{IssueId="ConfigErrorCheck";result="Pass";detailsString="";detailsArray=@()};
		$httpsBindingCheck = [pscustomobject]@{IssueId="HttpsBindingCheck";result="Pass";detailsString=""};
		$protocolCheck = [pscustomobject]@{IssueId="ProtocolCheck";result="Pass";detailsString=""};
		$tcpPortCheck = [pscustomobject]@{IssueId="TcpPortCheck";result="Pass";detailsString=""};		
		$locationTagCheck = [pscustomobject]@{IssueId="LocationTagCheck";result="Pass";detailsString=""};	
		$appPoolCheck = [pscustomobject]@{IssueId="AppPoolCheck";result="Pass";detailsString=""};
		$appPoolIdentityCheck = [pscustomobject]@{IssueId="AppPoolIdentityCheck";result="Pass";detailsString=""};
		$virtualDirectoryCheck = [pscustomobject]@{IssueId="VirtualDirectoryCheck";result="Pass";detailsString=""};		
		$contentSizeCheck = [pscustomobject]@{IssueId="ContentSizeCheck";result="Pass";detailsString=""};	
		$globalModuleCheck = [pscustomobject]@{IssueId="GlobalModuleCheck";result="Pass";detailsString=""};
	
		#Add binding information (including binding-related check results)
		$bindings = @();						
		$failedProtocols = @{};
		$failedPorts = @{};
		foreach($binding in $siteSection.ChildElements['bindings']) { 
			$bindingInfo = $binding['bindingInformation'];									
			$protocol = $binding['protocol'].ToLower();
			$port = "";
			$ipAddress = "";
			$hostName = "";
			if($protocol -eq "http" -or $protocol -eq "https" -or $protocol -eq "ftp") {				
				$ipAndPort = $bindingInfo.Substring(0,$bindingInfo.LastIndexOf(':'))
				$ipAddress = $ipAndPort.Substring(0,$ipAndPort.LastIndexOf(':'))
				$port = $ipAndPort.SubString($ipAndPort.LastIndexOf(':')+1)
				$hostName = $bindingInfo.Substring($bindingInfo.LastIndexOf(':')+1)
			}
						
            $newBinding = New-Object -TypeName PSObject		
            $newBinding | Add-Member -MemberType NoteProperty -Name protocol -Value $protocol			              
			$newBinding | Add-Member -MemberType NoteProperty -Name ipAddress -Value $ipAddress
            $newBinding | Add-Member -MemberType NoteProperty -Name port -Value $port
            $newBinding | Add-Member -MemberType NoteProperty -Name hostName -Value $hostName            
            $bindings += $newBinding 
			if($protocol -eq 'https') {				
				$httpsBindingCheck.result = "Warn"
			}
			if ($protocol -ne "http" -and $protocol -ne "https") {								
				if (-not $failedProtocols.ContainsKey($protocol)) { $failedProtocols.Add($protocol,0) }				
			}
			if($port -ne "80" -and $port -ne "443" -and $port -ne "") {
				if (-not $failedPorts.ContainsKey($port)) { $failedPorts.Add($port,0) }				
			}
		}
		$newSite | Add-Member -MemberType NoteProperty -Name bindings -Value $bindings	
		if($failedProtocols.Count -gt 0) {
			$protocolCheck = AppendFailCheckDetail -newDetails "$($failedProtocols.Keys -join ', ')" -prevCheckResults $protocolCheck 			
		}
		if($failedPorts.Count -gt 0) {			
			$tcpPortCheck.result = "Warn";
			$tcpPortCheck.detailsString = "$($failedPorts.Keys -join ', ')"
		}

		# Application Pool information including virtual directories and app pool-based check results
		$appPools = @();	
		$virtualApplications=@();
		$appPoolNames = @{};
		$uncPaths = @{};		
		$errorOccurredGettingContentSize = $false;
		$unsupportedIdentityTypes = @{};
		$dirPathsToZip = @{};

		# Each site must have a root application, otherwise various other things may fail about the discovery due to this invalid config
		if( @($siteSection.GetCollection()| Where-Object {$_['path'] -eq '/'}).Count -lt 1) {			
			$errorObj = GetConfigErrorInfoObj -errorId "IISWebServerDiscoveryError" -message "Invalid IIS configuration encountered, a site has no root application defined."	
			$webServerBase | Add-Member -MemberType NoteProperty -Name error -Value $errorObj 
			return $webServerBase;		
		}
		$siteRootVDir = ($siteSection.GetCollection() | Where-Object {$_['path'] -eq '/'}).GetCollection() | Where-Object {$_['path'] -eq '/'}
 		$siteRootPhysicalPath = [System.Environment]::ExpandEnvironmentVariables($siteRootVDir['physicalPath'])
		
		foreach($appPool in $siteSection.GetCollection()) {	
		
			$appRootVPath = $appPool['path'];
			$appRootZipPath = "";
			$vdirsForAppConfig = @();

			$vDirs = @();			
			foreach($vdir in $appPool.GetCollection()) {							
				$expandedFullPath = [System.Environment]::ExpandEnvironmentVariables($vdir['physicalPath']);
				$vdirInfo = @{"path"=$vdir['path'];"physicalPath"=$expandedFullPath;"sizeInBytes"=0}
				if($vdir['physicalPath'].StartsWith("\\") -and (-not($vdir['physicalPath'].StartsWith("\\?\")) -or $vdir['physicalPath'].StartsWith("\\?\UNC\"))){															
					if(-not($uncPaths.ContainsKey($vdir['path']))) {
						$uncPaths.Add($vdir['path'], "");
					}	
					$errorOccurredGettingContentSize = $true
				} else {
					try {	
						$vdirSize = 0;
						# piping ForEach uses significantly less memory than foreach with index, which will hit max memory limits for large number of files
						Get-ChildItem $expandedFullPath -recurse | ForEach {
							if(-not $_.PSIsContainer) {								
								$vdirSize += $_.Length 																
 							}
						}						
						$vdirInfo.sizeInBytes += $vdirSize;
					} catch {
						$errorOccurredGettingContentSize = $true
					}

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
				$vDirs += $vdirInfo; 
				
				#virtual directory config creation
				$vdirZipPath = GetZipRelativePath -fullPhysicalPath $expandedFullPath -siteHomeDirectory $siteRootPhysicalPath	
				
                if ($vdir['path'] -eq "/")
                {
                     $appRootZipPath = $vdirZipPath;
                }
                else
                {
					$newAppServiceVDir = New-Object -TypeName PSObject
					$newAppServiceVDir | Add-Member NoteProperty -Name virtualPath -Value $vdir['path']
					$newAppServiceVDir | Add-Member NoteProperty -Name physicalPath -Value $vdirZipPath							
                    $vdirsForAppConfig += $newAppServiceVDir                            
                }
			}			
			
			$appPoolName = $appPool['applicationPool'];
			$appPoolInfo = $appPoolSettings[$appPoolName];
			
			$newAppPool = New-Object -TypeName PSObject
			$newAppPool | Add-Member -MemberType NoteProperty -Name path -Value $appPool['path']
			$newAppPool | Add-Member -MemberType NoteProperty -Name applicationPool -Value $appPoolName
			$newAppPool | Add-Member -MemberType NoteProperty -Name enable32BitAppOnWin64 -Value $appPoolInfo.enable32BitAppOnWin64
			$newAppPool | Add-Member -MemberType NoteProperty -Name managedRuntimeVersion -Value $appPoolInfo.managedRuntimeVersion			
			$pipelineModeString = "Integrated";
			if($appPoolInfo.managedPipelineMode -eq 1) { $pipelineModeString = "Classic" }
			$newAppPool | Add-Member -MemberType NoteProperty -Name managedPipelineMode -Value $pipelineModeString			
			$newAppPool | Add-Member -MemberType NoteProperty -Name vdirs -Value $vDirs			
			$appPools += $newAppPool
			if(-not($appPoolNames.ContainsKey($appPoolName))){
				$appPoolNames.Add($appPoolName, "");
			}
			# 0 = LocalSystem; 1=LocalService; 2=NetworkService; 3=SpecificUser; 4=ApplicationPoolIdentity
			if( $appPoolInfo.identityType -ne 4 -and $appPoolInfo.identityType -ne 2 -and $appPoolInfo.identityType -ne 1 ) {
				if(-not($unsupportedIdentityTypes.ContainsKey($appPoolName))) {
					$poolIdentityTypeName = "Unknown Type $($appPoolInfo.identityType)"
					if($appPoolInfo.identityType -eq 3) { $poolIdentityTypeName = "SpecificUser" } 
					if($appPoolInfo.identityType -eq 0) { $poolIdentityTypeName = "LocalSystem" }				
					$unsupportedIdentityTypes.Add($appPoolName, $poolIdentityTypeName);
				}
			}	
			
			$newVirtualApplication = New-Object -TypeName PSObject
			$newVirtualApplication | Add-Member -MemberType NoteProperty -Name virtualPath -Value $appRootVPath
			$newVirtualApplication | Add-Member -MemberType NoteProperty -Name physicalPath -Value $appRootZipPath
			$newVirtualApplication | Add-Member -MemberType NoteProperty -Name virtualDirectories -Value $vdirsForAppConfig			
			$virtualApplications += $newVirtualApplication
		}		
		$newSite  | Add-Member -MemberType NoteProperty -Name applications -Value $appPools	
		$newSite  | Add-Member -MemberType NoteProperty -Name virtualApplications -Value $virtualApplications	
		
		# VIRTUAL DIRECTORIES CHECK 
		if($uncPaths.Count -gt 0) {
			$virtualDirectoryCheck = AppendFailCheckDetail -newDetails "$($uncPaths.Keys -join ', ')" -prevCheckResults $virtualDirectoryCheck 
			if(-not $aggressiveBlocking) {
				$virtualDirectoryCheck.result = "Warn"
			}
		}

		# MAX CONTENT SIZE CHECK
		$runningContentSize = 0;
		$maxBytesSize = 2 * 1024 * 1024 * 1024; # 2GB	
		try {	
			if(-not $errorOccurredGettingContentSize) {
				foreach($vdir in $dirPathsToZip.Keys) {	
					$vdirMatch = $null;
					foreach($app in $appPools) {
						$vdirMatch = $app.vdirs | Where-Object {$_.physicalPath -eq $vdir} | Select-Object -First 1
						if($vdirMatch) { break; }
					}		    	
					if($vdirMatch) {
						$runningContentSize += $vdirMatch.sizeInBytes
						if($runningContentSize -gt $maxBytesSize) {
							break;
						}
					} else {
						$errorOccurredGettingContentSize = $true;
					} 			
				}
			}
		} catch {
			$errorOccurredGettingContentSize = $true;
		}
        
		if( $runningContentSize -gt $maxBytesSize) {
			$contentSizeCheck = AppendFailCheckDetail -newDetails "$runningContentSize" -prevCheckResults $contentSizeCheck
		} elseif ($errorOccurredGettingContentSize) {
			# this occurs in cases like if unable to read directory size and/or UNC shares, probable issue for migration time
			$contentSizeCheck.IssueId = "ContentSizeCheckUnknown"
			$contentSizeCheck.result = "Unknown";
		}
		
		# MULTIPLE APP POOL CHECK
		if($appPoolNames.Count -gt 1) {
			$appPoolCheck = AppendFailCheckDetail -newDetails "$($appPoolNames.Keys -join ', ')" -prevCheckResults $appPoolCheck 
			if(-not $aggressiveBlocking) {
				$appPoolCheck.result = "Warn"
			}
		}
		# APP POOL IDENTITY CHECK
		if($unsupportedIdentityTypes.Count -gt 0) {			
			$detailString = "";
			foreach($key in $unsupportedIdentityTypes.keys) {
				$detailString = "$detailString$($unsupportedIdentityTypes[$key]) ($key), "								
			}	
			if($detailString.EndsWith(', ')) {
				$detailString = $detailString.Substring(0, $detailString.Length-2)
			}
			$appPoolIdentityCheck = AppendFailCheckDetail -newDetails $detailString -prevCheckResults $appPoolIdentityCheck 						
			if(-not $aggressiveBlocking) {
				$appPoolIdentityCheck.result = "Warn"
			}
		}			
				 
		# CONFIG ERRORS		
		[array]$siteConfigPaths = $configPaths | Where-Object {$_.site -eq $siteName}          	
		# in PowerShell 2.0 foreach on a $null object still does a first iteration $null item
		if($siteConfigPaths -ne $null) {
			foreach($configPathObject in $siteConfigPaths) {
				if($configPathObject.configError -ne "") {
					$configErrorCheck = AppendFailCheckResults -newDetails $configPathObject.configError -newLocation $configPathObject.configPath -prevCheckResults $configErrorCheck 
				}
				foreach($sectionkey in $configPathObject.sections.Keys) {			
					if(-not $configPathObject.sections[$sectionKey].isValid) {
						$sectionError =  $configPathObject.sections[$sectionKey].configError
						if(-not $sectionError) {
							$locationPathPart = ""
							if($configPathObject.locationPath -ne "") {
								$locationPathPart = ";location=$($configPathObject.locationPath)"
							}
							$sectionError = "message=Error with config section;path=$($configPathObject.configPath)$locationPathPart;sectionName=$sectionKey"
							
						}
						$configErrorCheck = AppendFailCheckResults -newDetails $sectionError -prevCheckResults $configErrorCheck
					}			
				}
			}
		}
		# TODO: apphost level config errors not getting added to above configErrorCheck
		$siteConfigPaths += $appHostConfigPathObject 

		# LOCATION TAG CHECK
		[array]$locationTags = $siteConfigPaths | Where-Object {$_.locationPath -ne "" -and $_.configPath -eq "/" } | Select -ExpandProperty locationPath			
		if($locationTags.Count -gt 0) {						
			$locationTagCheck = AppendFailCheckDetail -newDetails  "$($locationTags -join ', ')"  -prevCheckResults $locationTagCheck
			if(-not $aggressiveBlocking) {
				$locationTagCheck.result = "Warn"
			}
		}
		
		# GLOBAL MODULES CHECK
		$unsupportedModules = GetUnsupportedGlobalModules -appHostGlobalModulesSection $appHostConfigPathObject.sections["system.webServer/globalModules"]
		if($unsupportedModules.Count -gt 0) {			
			$globalModuleCheck = AppendFailCheckDetail -newDetails "$($unsupportedModules.Keys -join ', ')" -prevCheckResults $globalModuleCheck
			if(-not $aggressiveBlocking) {
				$globalModuleCheck.result = "Warn"
			}
		}
		
		$checksScaffolding = @([pscustomobject]@{IssueId="IsapiFilterCheck";result="Pass";detailsString=""},          
							 [pscustomobject]@{IssueId="AuthCheck";result="Pass";detailsString=""},
							 [pscustomobject]@{IssueId="FrameworkCheck";result="Pass";detailsString=""},
							 [pscustomobject]@{IssueId="ConfigConnectionStringsCheck";result="Pass";detailsString=""};);
		$appHostLevelChecks = @($configErrorCheck, $httpsBindingCheck, $protocolCheck, $TcpPortCheck, $appPoolCheck, $appPoolIdentityCheck, $locationTagCheck, $globalModuleCheck, $virtualDirectoryCheck, $contentSizeCheck); 
		$checksScaffolding += $appHostLevelChecks;
        		
        $newSite | Add-Member -MemberType NoteProperty -Name configPaths -Value $siteConfigPaths				
        $newSite | Add-Member -MemberType NoteProperty -Name checks -Value $checksScaffolding        

        $allSites += $newSite
    }        

    foreach($site in $allSites) {
		#framework determination	
		# ORDER OF PRECEDENCE if multiple detected: PYTHON > NODE > JAVA > .NET Core > PHP > .NET
		$discoveredFrameworks = @();
		
		#.NET (DEFAULT)
		$dotnetFName = ".NET"
		$rootAppPoolNetFxVersion = ($site.applications | Where-Object {$_.path -eq "/"} | Select-Object -Property managedRuntimeVersion).managedRuntimeVersion		
		$netFx = New-Object -TypeName PSObject
        $netFx | Add-Member -MemberType NoteProperty -Name framework -Value $dotnetFName			  
        $netFx | Add-Member -MemberType NoteProperty -Name version -Value $rootAppPoolNetFxVersion
        $discoveredFrameworks += $netFx 		
		$fx = $dotnetFName;
		$fxVer = $rootAppPoolNetFxVersion;		
				
		[array]$sections = ($site.configPaths | Where-Object {$_.configError -eq ""} |  Select-Object -Property sections).sections  		
		#PYTHON		
		$possiblePythonHandlers = GetMatchingHandlersForSite -appHostGlobalModulesSection $appHostConfigPathObject.sections["system.webServer/globalModules"] -siteConfigPaths $site.configPaths -handlerFileNames @("cgi.dll", "iisfcgi.dll");
		$matchingPyProcessors = $possiblePythonHandlers.Values | Where-Object {$_.ToLower().EndsWith("python.exe") -or $_.ToLower().EndsWith(".py")}
		if($matchingPyProcessors.Count -gt 0) {						
			$pyFx = New-Object -TypeName PSObject
            $pyFx | Add-Member -MemberType NoteProperty -Name framework -Value "PYTHON"			  
            $pyFx | Add-Member -MemberType NoteProperty -Name version -Value ""          
            $discoveredFrameworks += $pyFx 
			if($fx -eq $dotnetFName){				
				$fx = $pyFx.framework
				$fxVer = $pyFx.version
			}						
		}			
		#NODE
		$nodeHandlers = GetMatchingHandlersForSite -appHostGlobalModulesSection $appHostConfigPathObject.sections["system.webServer/globalModules"] -siteConfigPaths $site.configPaths -handlerFileNames @("iisnode.dll");
		if($nodeHandlers.Count -gt 0 ) {			
			$nodeFx = New-Object -TypeName PSObject
            $nodeFx | Add-Member -MemberType NoteProperty -Name framework -Value "NODE"			  
            $nodeFx | Add-Member -MemberType NoteProperty -Name version -Value ""           
            $discoveredFrameworks += $nodeFx 
			if($fx -eq $dotnetFName){				
				$fx = $nodeFx.framework
				$fxVer = $nodeFx.version
			} 
		}

		#JAVA
		$hasJava = HasJREHOMEEnvVar -siteSections $sections		
		if($hasJava) {			
			$nodeFx = New-Object -TypeName PSObject
            $nodeFx | Add-Member -MemberType NoteProperty -Name framework -Value "JAVA"			  
            $nodeFx | Add-Member -MemberType NoteProperty -Name version -Value ""           
            $discoveredFrameworks += $nodeFx 
			if($fx -eq $dotnetFName){				
				$fx = $nodeFx.framework
				$fxVer = $nodeFx.version
			} 
		}

		#.NET Core
		$aspnetcoreHandlers = GetMatchingHandlersForSite -appHostGlobalModulesSection $appHostConfigPathObject.sections["system.webServer/globalModules"] -siteConfigPaths $site.configPaths -handlerFileNames @("aspnetcorev2.dll", "aspnetcore.dll");
		if($aspnetcoreHandlers.Count -gt 0 ) {			
			$aspnetcoreFx = New-Object -TypeName PSObject
            $aspnetcoreFx | Add-Member -MemberType NoteProperty -Name framework -Value ".NET Core"			  
            $aspnetcoreFx | Add-Member -MemberType NoteProperty -Name version -Value ""           
            $discoveredFrameworks += $aspnetcoreFx 
			if($fx -eq $dotnetFName){				
				$fx = $aspnetcoreFx.framework
				$fxVer = $aspnetcoreFx.version
			} 
		}

		#PHP
		$possiblePHPHandlers = GetMatchingHandlersForSite -appHostGlobalModulesSection $appHostConfigPathObject.sections["system.webServer/globalModules"] -siteConfigPaths $site.configPaths -handlerFileNames @("cgi.dll", "iisfcgi.dll");
		$matchingPHPProcessors = $possiblePHPHandlers.Values | Where-Object {$_.ToLower().EndsWith("php-cgi.exe") -or $_.ToLower().EndsWith("cgi.exe")}
		if($matchingPHPProcessors.Count -gt 0) {			
			$phpFx = New-Object -TypeName PSObject
            $phpFx | Add-Member -MemberType NoteProperty -Name framework -Value "PHP"			  
            $phpFx | Add-Member -MemberType NoteProperty -Name version -Value ""          
            $discoveredFrameworks += $phpFx 
			if($fx -eq $dotnetFName){				
				$fx = $phpFx.framework
				$fxVer = $phpFx.version
			}						
		}
		
		$site | Add-Member -MemberType NoteProperty -Name framework -Value $fx
		$site | Add-Member -MemberType NoteProperty -Name frameworkVersion -Value $fxVer
		$site | Add-Member -MemberType NoteProperty -Name discoveredFrameworks -Value $discoveredFrameworks
	
		$configCheck    = $site.checks | Where-Object { $_.IssueId -eq "ConfigErrorCheck" } | Select-Object -First 1;
		$authCheck      = $site.checks | Where-Object { $_.IssueId -eq "AuthCheck" }        | Select-Object -First 1;
		$isapiCheck     = $site.checks | Where-Object { $_.IssueId -eq "IsapiFilterCheck" } | Select-Object -First 1;
		$frameworkCheck = $site.checks | Where-Object {$_.IssueId -eq "FrameworkCheck" }    | Select-Object -First 1;
		$configConnectionStringsCheck = $site.checks | Where-Object {$_.IssueId -eq "ConfigConnectionStringsCheck" } | Select-Object -First 1;		

		#FRAMEWORK CHECK						
		if($netFx.version.StartsWith("v1.")) {
			# want to warn for unsupported v1.X .NET framework usage			
			$netFx.framework = "$($netFx.framework)($($netFx.version))"
		}		
		[array]$warnFrameworks = $discoveredFrameworks | Where-Object {-not $_.framework.StartsWith($dotnetFName) -or $_.version.StartsWith("v1.")}
		if($warnFrameworks.Length -gt 0) {
			$frameworkCheck.result = "Warn";
			$frameworkCheck.detailsString = "$($warnFrameworks.framework -join ', ')"			
		}
		
		#AUTHENTICATION TYPES CHECK 
		$enabledAuthenticationTypes = @(GetEnabledAuthSectionsForSite -siteObject $site -authCheck $authCheck -configErrorCheck $configCheck)
		$site | Add-Member -MemberType NoteProperty -Name enabledAuthenticationTypes -Value $enabledAuthenticationTypes
		
		#ISAPI FILTER CHECK	
		$isapiCheck = GetUnsupportedIsapiFilters -siteConfigs $site.configPaths -isapiCheck $isapiCheck -configErrorCheck $configCheck
		
		#CONNECTION STRINGS config
		$configConnectionStrings = @(GetConnectionStrings -siteObject $site -configErrorCheck $configCheck)
		$site | Add-Member -MemberType NoteProperty -Name configConnectionStrings -Value $configConnectionStrings

		#CONFIG CONNECTION STRINGS CHECK
		if($configConnectionStrings.Count -gt 0){			
			$configCSDetailString = "";
			$configConnectionStringsCheck.result = "Warn";
			foreach($configCS in $configConnectionStrings) {
			    $configCSDetailString = "$configCSDetailString$($configCS.name) ($($configCS.virtualPath)), "
			}
			if($configCSDetailString.EndsWith(', ')) {
			    $configCSDetailString = $configCSDetailString.Substring(0, $configCSDetailString.Length-2)
			}
			$configConnectionStringsCheck.detailsString = $configCSDetailString;
		}

		$configCheck = CondenseDetailsArrayToString -CheckResults $configCheck
		if($configCheck.result -eq "Fail" -and -not $aggressiveBlocking) {
			$configCheck.result = "Warn"
		}
		
		$migrationReadiness = "Ready";
		$numFails = 0;
		$numWarns = 0;
		$numUnknown = 0;
		foreach($check in $site.checks) {
			if($check.result -eq "Fail") {
				$numFails++;
			} elseif ($check.result -eq "Warn") {
				$numWarns++;
			} elseif ($check.result -eq "Unknown") {
				$numUnknown++;
			}
			# reset single details string to string array		
            if($check.detailsString) {	
			    $check | Add-Member NoteProperty -Name Details -Value @($check.detailsString)
			    $check.PSObject.Properties.Remove('detailsString')
            }
		}
		if($numFails -gt 0) {
			$migrationReadiness = "NotReady";
		} elseif($numUnknown -gt 0) {
			$migrationReadiness = "Unknown"; 		
		} elseif($numWarns -gt 0) {
			$migrationReadiness = "ConditionallyReady"; 
		}
		$site | Add-Member NoteProperty -Name migrationReadiness -Value $migrationReadiness

		# Passed checks are never displayed, only those with non-pass results need to be included
		[array]$site.checks = $site.checks | Where-Object {$_.result -ne "Pass"}
		if($site.checks -eq $null){
			$site.checks = @()
		}
    }
	 
	[array]$discoverySiteData = $allSites | Select-Object -Property webAppName, bindings, applications, virtualApplications, framework, frameworkVersion, discoveredFrameworks, configConnectionStrings, enabledAuthenticationTypes
	[array]$readinessSiteData = $allSites | Select-Object -Property webAppName, migrationReadiness, checks
	$discoveryIISSiteDataObject = New-Object -TypeName PSObject
	$discoveryIISSiteDataObject | Add-Member NoteProperty -Name IISSites -Value $discoverySiteData
	$readinessIISSiteDataObject = New-Object -TypeName PSObject
	$readinessIISSiteDataObject | Add-Member NoteProperty -Name IISSites -Value $readinessSiteData 
		 
	# populate on final output object	 
	if($discoverySiteData.Count -lt 1) {
		$errorObj = GetConfigErrorInfoObj -errorId "IISWebServerZeroWebAppsFound" -message "No websites were discovered."	
		$webServerBase | Add-Member -MemberType NoteProperty -Name error -Value $errorObj 		
	} else {
		$webServerBase | Add-Member -MemberType NoteProperty -Name discoveryData -Value $discoveryIISSiteDataObject
		$webServerBase | Add-Member -MemberType NoteProperty -Name readinessData -Value $readinessIISSiteDataObject
	}

	return $webServerBase
}

function GetWebServerBaseObject {
    $defaultAppHostConfigPath = [System.Environment]::ExpandEnvironmentVariables("%windir%\System32\inetsrv\config\applicationHost.config");
  	$IISVersion = "";

	try {
		$IISStpKey = Get-ItemProperty -Path Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\InetStp
		$MajorVersion = $IISStpKey.MajorVersion
		$MinorVersion = $IISStpKey.MinorVersion
		if($MajorVersion -ne $null -and $MinorVersion -ne $null) {
			$IISVersion = "$MajorVersion.$MinorVersion"
		} elseif ($MajorVersion -ne $null) {
			$IISVersion = "$MajorVersion"
		}
	} catch {
		# Do nothing. Version discovery is best effort 
		# Write-Output "Failed to determine IIS version: $($_.Exception)"
	}
	 
  $ServerInfo = New-Object -TypeName PSObject
  $ServerInfo | Add-Member -MemberType NoteProperty -Name type -Value "IIS"
  $ServerInfo | Add-Member -MemberType NoteProperty -Name version -Value $IISVersion
  $ServerInfo | Add-Member -MemberType NoteProperty -Name rootConfigurationLocation -Value $defaultAppHostConfigPath 
  return $ServerInfo
}

function CheckForRedirectionConfigPath {
	try {	
		$sm = New-Object Microsoft.Web.Administration.ServerManager;
		$redirectionConfig = $sm.GetRedirectionConfiguration();
		$cr = $redirectionConfig.GetSection("configurationRedirection");		
		if($cr.Attributes["enabled"].Value) { 
			# redirection is enabled
			return "$($cr.Attributes['path'].Value)\applicationHost.config"
		}
	} catch {
		# Do nothing. Checking for shared config is best effort		
		# Write-Output "Failed to determine config location: $($_.Exception)"
	}
    return $null
}

function GetEnabledAuthSectionsForSite {
    param( $siteObject, $authCheck, $configErrorCheck)
    $failedAuthTypesStringResult = ""; 
	$encounteredError = $false;
	$enabledAuthTypesResults = @();	

	$authTypes = @("basicAuthentication","clientCertificateMappingAuthentication", "iisClientCertificateMappingAuthentication", "digestAuthentication","windowsAuthentication");
	foreach($authType in $authTypes) {		
		$topLevelConfigResults=@{}; #heirarchIndex, Block|Allow
		$failedConfigPaths = @{};   #configPath, Block|Allow (not considering locationPath2)
		# reminder heirarchyIndex: # 0 = APPHOST, 1 = APPHOST with site root Location, 2 = site root web.config, 3 = anything lower
		foreach($p in $siteObject.configPaths) {  
            $configError = "";  	
			# Below looks at effective site config (i.e. ignoring appHost settings if a root web.config exists)
            if($p.configError -eq "") {                           
				#AUTHENTICATION TYPES CHECK       										
			    try {							
					$authSection = $p.sections["system.webServer/security/authentication/$authType"];
					if($authSection) {
						if($authSection.isValid -and $authSection.section['enabled']) { 
							if($p.heirarchyIndex -lt 3) {								
								if(-not $topLevelConfigResults.ContainsKey($p.heirarchyIndex)) {
									$topLevelConfigResults.Add($p.heirarchyIndex, "Block");										
								}
							} else {							
								$subpathOfExistingFailPath = $false;
								$removeKeys = @{};
								# check if current path is already represented in failedConfigPaths
								foreach($cp in $failedConfigPaths.Keys) {									
									if($p.configPath.ToLower().StartsWith($cp.ToLower())) {
										$subpathOfExistingFailPath = $true;
										break;
									} elseif ($cp.ToLower().StartsWith($p.configPath.ToLower())) {
										$removeKeys.Add($cp, "");
									}
								}
								#only add unique paths to failure message, not subpaths
								if(-not($failedConfigPaths.ContainsKey($p.configPath)) -and -not($subpathOfExistingFailPath)) {
									$failedConfigPaths.Add($p.configPath, "Block");

									$authTInfo = New-Object -TypeName PSObject
									$authTInfo | Add-Member -MemberType NoteProperty -Name name -Value $authType
									$authTInfo | Add-Member -MemberType NoteProperty -Name virtualPath -Value $p.configPath 
									$authTInfo | Add-Member -MemberType NoteProperty -Name locationPath -Value $p.locationPath  
									$enabledAuthTypesResults += $authTInfo
								}
								if($removeKeys.Count > 0) {
									foreach($k in $removeKeys.Keys) {
										$failedConfigPaths.Remove($k)
									}
								}
							}
						} elseif ($p.heirarchyIndex -lt 3 -and $authSection.isValid ) {
							if(-not $topLevelConfigResults.ContainsKey($p.heirarchyIndex)) {
								$topLevelConfigResults.Add($p.heirarchyIndex, "Allow");								
							}
						} elseif (-not $authSection.isValid) {
							$encounteredError = $true							
						}
					}
			    } catch {
					$encounteredError = $true
					$errorString = GetConfigErrorFromException -exception $_.Exception -configPath $p.configPath -location $p.locationPath -configSection "security/authentication/$authType"	
					$configErrorCheck = AppendFailCheckResults $errorString -newLocation $p.configPath -prevCheckResults $configErrorCheck
			    }
			} else {
				$encounteredError = $true				
				break #bail on this authtype check - we can't tell if can't read a root-level config
			} 	
		} #end foreach config path
	
		$topBlockConfigPath = "";
		$topBlockLocationPath = "";
		$topLevelEnabledAuth = New-Object -TypeName PSObject
		$topLevelEnabledAuth | Add-Member -MemberType NoteProperty -Name name -Value $authType
		if($topLevelConfigResults.Count -gt 0 -and $topLevelConfigResults.Values -contains "Block") {
			$topBlockConfigPath = "/";							
			if($topLevelConfigResults.ContainsKey(2)) {
				if($topLevelConfigResults[2] -eq "Block" -and -not($topLevelConfigResults[0] -eq "Block" -or $topLevelConfigResults[1] -eq "Block")) {
					#root web.config blocks without higher block in apphost
					$topBlockConfigPath = "/$($siteObject.webAppName)"; 			
				} elseif($topLevelConfigResults[2] -eq "Allow") {
					#allowed at site level, look at subpaths for Block configs
					$topBlockConfigPath = "";						
				} 				
			} elseif ($topLevelConfigResults[1] -eq "Allow") {
				#appHost global Block but appHost location tag overrides at root site level
				$topBlockConfigPath = "";
			} elseif($topLevelConfigResults[1] -eq "Block") {
				#prefer appHost location tag config over root apphost config for enabled unsupported auth
				$topBlockLocationPath = "/$($siteObject.webAppName)"
			}			
		} 

		if($topBlockConfigPath -ne "") {			
			$failedAuthTypesStringResult = "$failedAuthTypesStringResult$authType ($topBlockConfigPath), "
			
			$topLevelEnabledAuth | Add-Member -MemberType NoteProperty -Name virtualPath -Value $topBlockConfigPath 
			$topLevelEnabledAuth | Add-Member -MemberType NoteProperty -Name locationPath -Value $topBlockLocationPath			 
			$enabledAuthTypesResults = @($topLevelEnabledAuth)

		} elseif ($failedConfigPaths.Count -gt 0) {                            
			foreach($key in $failedConfigPaths.keys) {
				$failedAuthTypesStringResult = "$failedAuthTypesStringResult$authType ($key), "								
			}
		}
	} #end foreach authtype

	if($failedAuthTypesStringResult.EndsWith(', ')) {						
		$failedAuthTypesStringResult = $failedAuthTypesStringResult.Substring(0, $failedAuthTypesStringResult.Length-2)
	} 

	if($failedAuthTypesStringResult -ne "") {						
		$authCheck = AppendFailCheckDetail -newDetails $failedAuthTypesStringResult -prevCheckResults $authCheck
		if(-not $aggressiveBlocking) {
				$authCheck.result = "Warn"
		}
	} elseif ($encounteredError) {
		$authCheck.IssueId = "AuthCheckUnknown";
		$authCheck.result = "Unknown"
		if(-not $aggressiveBlocking) {
				$authCheck.result = "Warn"
		}
	}

	$enabledAuthTypesResults 
}

function GetUnsupportedIsapiFilters {
    param($siteConfigs, $isapiCheck, $configErrorCheck)
    
	$unsupportedIsapiFilters = @{};
	$encounteredError = $false;
    foreach($p in $siteConfigs) {  
		$configError = "";          
		if($p.configError -eq "") {          
			try {					
				foreach($isapiSection in $p.sections["system.webServer/isapiFilters"]) {					
					if($isapiSection.isValid) {
						foreach ($filter in $isapiSection.section.GetCollection()) {
							$filterName = $filter['name'];
							if(-not($filterName.StartsWith("ASP.Net_") -or $unsupportedIsapiFilters.ContainsKey($filterName))) {
								$unsupportedIsapiFilters.Add($filterName, "")	
							}
						}						
					} else {
						$encounteredError = $true
					}
				}
			} catch {
				$encounteredError = $true								 
				$errorString = GetConfigErrorFromException -exception $_.Exception -configPath $p.configPath -location $p.locationPath -configSection "system.webServer/isapiFilters"	
				$configErrorCheck = AppendFailCheckResults $errorString -newLocation $p.configPath -prevCheckResults $configErrorCheck
			}
		} else {
			$encounteredError = $true				
		} 	
	} # end foreach config
          
    if($unsupportedIsapiFilters.Count -gt 0) {						
		$isapiCheck = AppendFailCheckDetail -newDetails "$($unsupportedIsapiFilters.Keys -join ', ')" -prevCheckResults $isapiCheck		
	} elseif ($encounteredError) {
		$isapiCheck.IssueId = "IsapiFilterCheckUnknown"
		$isapiCheck.result = "Unknown"
		if(-not $aggressiveBlocking) {
				$isapiCheck.result = "Warn"
		}
	}
	$isapiCheck
}

function GetUnsupportedGlobalModules {
	param ( $appHostGlobalModulesSection )
	$unsupportedModules = @{};
	
	$supportedGlobalModules = @{	 
            "HttpLoggingModule"="";
            "UriCacheModule"="";
            "FileCacheModule"="";
            "TokenCacheModule"="";
            "HttpCacheModule"="";
            "DynamicCompressionModule"="";
            "StaticCompressionModule"="";
            "DefaultDocumentModule"="";
            "DirectoryListingModule"="";
            "ProtocolSupportModule"="";
            "HttpRedirectionModule"="";
            "ServerSideIncludeModule"="";
            "StaticFileModule"="";
            "AnonymousAuthenticationModule"="";
            "RequestFilteringModule"="";
            "CustomErrorModule"="";
            "TracingModule"="";
            "FailedRequestsTracingModule"="";
            "RequestMonitorModule"="";
            "IsapiModule"="";
            "IsapiFilterModule"="";
            "CgiModule"="";
            "FastCgiModule"="";
            "ManagedEngineV4.0_32bit"="";
            "ConfigurationValidationModule"="";
            "ManagedEngineV4.0_64bit"="";
            "RewriteModule"="";
            "ManagedEngine64"="";
            "ManagedEngine"="";
            "IpRestrictionModule"="";
            "DynamicIpRestrictionModule"="";
            "ApplicationInitializationModule"="";
            "ModSecurity IIS (32bits)"="";
            "ModSecurity IIS (64bits)"="";
            "iisnode"="";
            "AspNetCoreModuleV2"="";
            "AspNetCoreModule"="";
            "ApplicationRequestRouting"="";
            "httpPlatformHandler"="";
            "PipeStat"="";
            "WebSocketModule"="";

            # The following modules are supported for compatibility with
            # the out-of-box standard IIS modules.  They are not installed
            # on an Antares worker role, so any configuration that
            # references them will need to be handled by a different
            # check
            "UrlAuthorizationModule"="";
            "BasicAuthenticationModule"="";
            "CertificateMappingAuthenticationModule"="";
            "WindowsAuthenticationModule"="";
            "DigestAuthenticationModule"="";
            "IISCertificateMappingAuthenticationModule"="";

            # ToDo: Implement checks for the following:
            "CustomLoggingModule"="";
            "WebDAVModule"=""
        };
	
	if($appHostGlobalModulesSection.isValid) {
		$globalModules = $appHostGlobalModulesSection.section.GetCollection();
		
		foreach ($gModule in $globalModules) {
			$modName = $gModule['name'];
			if(-not($supportedGlobalModules.ContainsKey($modName))) {
				$unsupportedModules.Add($modName, "");
			}		
		}
	} 
	$unsupportedModules
}

function GetMatchingHandlersForSite {
    param( $appHostGlobalModulesSection, $siteConfigPaths, [array]$handlerFileNames)

	$matchingModules = @{};
	$matchingHandlers = @{}; #key=handler, value=scriptProcessor	
	
	if($appHostGlobalModulesSection.isValid) {
		$globalModules = $appHostGlobalModulesSection.section.GetCollection();		
		foreach ($gModule in $globalModules) {
			$modName = $gModule['name'].ToLower();		
			foreach ($fileName in $handlerFileNames) {
				if(-not($matchingModules.ContainsKey($modName))) {
					if($gModule['image'].ToLower().EndsWith($fileName.ToLower())) {
						$matchingModules.Add($modName,"");
					}		
				}
			}
		}
		 	
		$topLevelConfigResults=@{}; #heirarchIndex, list of handlers at apphost or site root level
		$matchingHandlersSubLevels = @{}; #key=handler, value=scriptProcessor #handlers seen at any other level
		foreach($p in $siteConfigPaths) {  						
            if($p.configError -eq "") { 			                       
				#GET HANDLERS
			    try {	
					$handlersSection = $p.sections["system.webServer/handlers"];
					if($handlersSection.isValid) {
						foreach($handler in $handlersSection.section.GetCollection()) {			
							[array]$modNames = $handler['modules'].split(',');
							
							foreach ($module in $matchingModules.keys) {
								foreach($mod in $modNames) {
									if($mod.ToLower() -eq $module) {
										$matchHandlerName = $handler['name'];
										$matchHandlerProcessor =  $handler['scriptProcessor'];

										if($p.heirarchyIndex -lt 3) {
											if(-not $topLevelConfigResults.ContainsKey($p.heirarchyIndex)) {
												$matchModuleHash = @{$matchHandlerName = $matchHandlerProcessor }
												$topLevelConfigResults.Add($p.heirarchyIndex, $matchModuleHash);							
											} else {
												$currentLevelList = $topLevelConfigResults[$p.heirarchyIndex];
												if(-not($currentLevelList.ContainsKey($handler['name']))) {
													$currentLevelList.Add($matchHandlerName, $matchHandlerProcessor)
												}											
											}
										} else {									
											if(-not($matchingHandlersSubLevels.ContainsKey($handler['name']))) {
												$matchingHandlersSubLevels.Add($matchHandlerName, $matchHandlerProcessor)
											}
										}
	
									}
								}
							}
						}
					}
				} catch {
					# don't fail discovery on framework discovery issues
			    }
			} #	else # errors for any section with isValid=false is logged in configErrors check already
		} #end foreach config path
		
		$topBlockConfigPath = "";
		if($topLevelConfigResults.Count -gt 0) {
			# use lowest top level configuration that has handlers defined
			# allows looking at effective site config (i.e. ignoring appHost settings if a root web.config overrides it)
			for($level = 2; $level -ge 0; $level--) {
				if($topLevelConfigResults.ContainsKey($level)) {
					$matchingHandlers = $topLevelConfigResults[$level];		
					break;
				}
			}			
		} 

		if($matchingHandlersSubLevels.Count -gt 0) {
			foreach($subHandler in $matchingHandlersSubLevels.Keys) {
				if(-not($matchingHandlers.ContainsKey($subHandler))) {
					$matchingHandlers.Add($subHandler, $matchingHandlersSubLevels[$subHandler]);
				}
			}
		}							
	} #end if apphost globalmodules section isValid=$true
	
	$matchingHandlers
}

function HasJREHOMEEnvVar {
	param ( $siteSections )

    # Presence of the JRE_HOME environment variable indicates recommended Java configuration using httpPlatformHandler
	try {
		foreach ($sectionsGroup in $siteSections) {		
			if($sectionsGroup["system.webServer/httpPlatform"] -and $sectionsGroup["system.webServer/httpPlatform"].isValid) {
				foreach($varName in $sectionsGroup["system.webServer/httpPlatform"].section.ChildElements['environmentVariables'])				
				{
					if($varName['name'].ToLower() -eq "jre_home") {
						return $true;
					}
				}		
			}
		}
	} catch {
		# do not fail discovery due to Java detection issue
	}
	
	return $false;
}

function ConvertTo-JsonStringWrapper {
	param ($objectToConvert, $depth)

	if(-not $depth) {
		$depth = 10
	}

	try {				
		$majorVersion = $PSVersionTable.PSVersion.Major
		if($majorVersion -lt 3) {
			# ConvertTo-Json is not supported in PS versions lower than 3
			return ConvertObjectToJson -inputObj $objectToConvert		
		} 
	
	} catch {
		Write-Output "ERROR! $($_.Exception)" # Will ultimately result in ResultFileContentJSONParseError
		return
	}

	return ConvertTo-Json $objectToConvert -depth $depth -Compress
}

# TODO: implement depth so can't get caught in infinite recursion loop
function ConvertObjectToJson {
	param($inputObj)

	if($inputObj -eq $null) {
		return "null";  
	}

	$objType = $inputObj.GetType().Name;

	switch	($objType) {
		'String' {			
			$escapedStr = $inputObj.Replace('\', '\\').Replace('"', '\"').Replace("`n","\n").Replace("`r","\r").Replace("`t", "\t");
			return "`"$escapedStr`"";		
		}
		'Boolean'{
			return $inputObj.ToString().ToLower();
		}
		'Int32' {
			return $inputObj.ToString();
		}
		'Int64' {
			return $inputObj.ToString();
		}
		'Double' {
			return $inputObj.ToString();
		}
		'Object[]' {
			$arrayContentsJson = "";
			foreach($item in $inputObj) {
				if($arrayContentsJson -ne "") { $arrayContentsJson += ", "}
				$arrayContentsJson += ConvertObjectToJson($item)
			}
			return "[ $arrayContentsJson ]";    
		}
		'Hashtable' { 
			$hashContentsJson = "";
			foreach($key in $inputObj.Keys){
				if($hashContentsJson -ne "") {$hashContentsJson += ", "}
				$hashContentsJson += "`"$key`": $(ConvertObjectToJson($inputObj[$key]))"
			}
		    return "{ $hashContentsJson }"
		}
		default {
			return "{" + 
				(($inputObj | Get-Member -MemberType Properties | % { "`"$($_.Name)`": $(ConvertObjectToJson($inputObj.($_.Name)))" } ) -join ', ') +
				"}";			
		}
	}
}

$ErrorActionPreference = "Stop"; #Make all errors terminating
$errorObj = $null;
try {
	$ServerInfo = GetWebServerBaseObject
	#LoadMWH
	$iisInstallPath = [System.Environment]::ExpandEnvironmentVariables("%windir%\system32\inetsrv\Microsoft.Web.Administration.dll");
	[System.Reflection.Assembly]::LoadFrom($iisInstallPath) | Out-Null;
	$nonDefaultAppHostConfigPath = CheckForRedirectionConfigPath
	if($nonDefaultAppHostConfigPath)
	{
	    $ServerInfo.rootConfigurationLocation = $nonDefaultAppHostConfigPath 
	}
	$configPaths = GetConfigPaths;
	$appPoolSettings = GetApplicationPools;

	try {	    
		$ServerInfo = DiscoverAndAssess -configPaths $configPaths -appPoolSettings $appPoolSettings -webServerBase $ServerInfo		
	} catch [System.Security.SecurityException] {    
		$errorObj = GetConfigErrorInfoObj -errorId "IISWebServerAccessFailedError" -exception $_.Exception	    	
	} catch [System.Management.Automation.MethodInvocationException] {    		
		$errorObj = GetConfigErrorInfoObj -errorId "IISWebServerDiscoveryError" -exception $_.Exception	    
	} 
} catch [System.IO.FileNotFoundException] {    
	$errorObj = GetConfigErrorInfoObj -errorId "IISWebServerIISNotFoundError" -exception $_.Exception
} catch [System.Security.SecurityException] {    
	$errorObj = GetConfigErrorInfoObj -errorId "IISWebServerAccessFailedError" -exception $_.Exception 
} catch [System.Management.Automation.MethodInvocationException] {    
	# this can occur due to file access issues, including on apphost or redirection config
	$errorObj = GetConfigErrorInfoObj -errorId "IISWebServerAccessFailedError" -exception $_.Exception
} catch {	
	$errorObj = GetConfigErrorInfoObj -errorId "IISWebServerPowerShellError" -exception $_.Exception
}finally{
	if($errorObj){
		if(-not $ServerInfo.error) {
			$ServerInfo | Add-Member -MemberType NoteProperty -Name error -Value $errorObj			
		} 		 
	} 
	ConvertTo-JsonStringWrapper -objectToConvert $ServerInfo | Write-Output
   $ErrorActionPreference = "Continue"; #Reset the error action pref to default
}


# SIG # Begin signature block
# MIIoLAYJKoZIhvcNAQcCoIIoHTCCKBkCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCAM2XAcbqhx/dwQ
# fptoREmceU3P2LijAj45a0r646yS1qCCDXYwggX0MIID3KADAgECAhMzAAAEhV6Z
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
# /Xmfwb1tbWrJUnMTDXpQzTGCGgwwghoIAgEBMIGVMH4xCzAJBgNVBAYTAlVTMRMw
# EQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVN
# aWNyb3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMTH01pY3Jvc29mdCBDb2RlIFNp
# Z25pbmcgUENBIDIwMTECEzMAAASFXpnsDlkvzdcAAAAABIUwDQYJYIZIAWUDBAIB
# BQCgga4wGQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQwHAYKKwYBBAGCNwIBCzEO
# MAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEIDE5qLGb83ygHXASUwa6AlVu
# +5wnDdzuogiAJ7jJSpxtMEIGCisGAQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8A
# cwBvAGYAdKEagBhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEB
# BQAEggEAJeZ26qvxnCHaBzX7LnEra2KDzKENiBhhFZIvX4d53jwPk0oilg2MmBqc
# Eofn4KIadkYj7kAceUCGvHJ6rb4XNwShBPMN2Re4nGvkvGp1vtllrFt0+yRIOgqA
# TnBZABjpPtvZRaOM7FEgTfh/O8UsYTf6UM0KJSYy0viUxH39CANQzAQwXQHHMwLD
# iXd0yf/dKTTjwmRlJp/AOFX/I0b55exzoFS8NhS38puY+e80Df/w5EVC4JZBkB2C
# HP2+j+ikUXbIbqu9K+uipvoi5n4+j2SXQprFZQESTLSeTkL1aw+ap+61oDXIgNwb
# jzDsFhqjf4MDnNAML2fQiU+t2ZkgM6GCF5YwgheSBgorBgEEAYI3AwMBMYIXgjCC
# F34GCSqGSIb3DQEHAqCCF28wghdrAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFRBgsq
# hkiG9w0BCRABBKCCAUAEggE8MIIBOAIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFl
# AwQCAQUABCDHE9BBxR6JgWQo5iZDHX0F9IBaGgwIvUlYiSKaU3Mf3wIGaRYWGPsA
# GBIyMDI1MTEyNTAwMjEwOC40MVowBIACAfSggdGkgc4wgcsxCzAJBgNVBAYTAlVT
# MRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQK
# ExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJTAjBgNVBAsTHE1pY3Jvc29mdCBBbWVy
# aWNhIE9wZXJhdGlvbnMxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjo4NjAzLTA1
# RTAtRDk0NzElMCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2VydmljZaCC
# Ee0wggcgMIIFCKADAgECAhMzAAACBywROYnNhfvFAAEAAAIHMA0GCSqGSIb3DQEB
# CwUAMHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQH
# EwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNV
# BAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwMB4XDTI1MDEzMDE5NDI1
# MloXDTI2MDQyMjE5NDI1MlowgcsxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNo
# aW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29y
# cG9yYXRpb24xJTAjBgNVBAsTHE1pY3Jvc29mdCBBbWVyaWNhIE9wZXJhdGlvbnMx
# JzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjo4NjAzLTA1RTAtRDk0NzElMCMGA1UE
# AxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2VydmljZTCCAiIwDQYJKoZIhvcNAQEB
# BQADggIPADCCAgoCggIBAMU//3p0+Zx+A4N7f+e4W964Gy38mZLFKQ6fz1kXK0dC
# bfjiIug+qRXCz4KJR6NBpsp/79zspTWerACaa2I+cbzObhKX35EllpDgPHeq0D2Z
# 1B1LsKF/phRs/hn77yVo1tNCKAmhcKbOVXfi+YLjOkWsRPgoABONdI8rSxC4WEqv
# uW01owUZyVdKciFydJyP1BQNUtCkCwm2wofIc3tw3vhoRcukUZzUj5ZgVHFpOCpI
# +oZF8R+5DbIasBtaMlg5e555MDUxUqFbzPNISl+Mp4r+3Ze4rKSkJRoqfmzyyo1s
# jdse3+sT+k3PBacArP484FFsnEiSYv6f8QxWKvm7y7JY+XW3zwwrnnUAZWH7YfjO
# JHXhgPHPIIb3biBqicqOJxidZQE61euc8roBL8s3pj7wrGHbprq8psVvNqpZcCPM
# SJDwRj0r2lgj8oLKCLGMPAd9SBVJYLJPwrDuYYHJRmZE8/Fc42W4x78/wK0Ekym6
# HwIFbKO8V8WY5I1ErwRORSaVNQBHUIg5p4GosbCxxKEV/K8NCtsKGaFeJvidExfl
# T1iv13tVxgefp5kmyDLOHlAqUhsJAL9i+EUrjZx4IEMxtz463lHpP8zBx7mNXJUK
# apdXFY5pBzisDadXuicw5kLpS8IbwsYVJkGePWWgMMtaj8j5G5GiTaP9DjNwyfCR
# AgMBAAGjggFJMIIBRTAdBgNVHQ4EFgQUcrVSYsK9etAK9H3wkGrXz/jOjR4wHwYD
# VR0jBBgwFoAUn6cVXQBeYl2D9OXSZacbUzUZ6XIwXwYDVR0fBFgwVjBUoFKgUIZO
# aHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9jcmwvTWljcm9zb2Z0JTIw
# VGltZS1TdGFtcCUyMFBDQSUyMDIwMTAoMSkuY3JsMGwGCCsGAQUFBwEBBGAwXjBc
# BggrBgEFBQcwAoZQaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9jZXJ0
# cy9NaWNyb3NvZnQlMjBUaW1lLVN0YW1wJTIwUENBJTIwMjAxMCgxKS5jcnQwDAYD
# VR0TAQH/BAIwADAWBgNVHSUBAf8EDDAKBggrBgEFBQcDCDAOBgNVHQ8BAf8EBAMC
# B4AwDQYJKoZIhvcNAQELBQADggIBAOO7Sq49ueLHSyUSMPuPbbbilg48ZOZ0O87T
# 5s1EI2RmpS/Ts/Tid/Uh/dj+IkSZRpTvDXYWbnzYiakP8rDYKVes0os9ME7qd/G8
# 48a1qWkCXjCqgaBnG+nFvbIS6cbjJlDoRA6mDV0T245ejN7eAPgeO1xzvmRxrzKK
# +jAQj6uFe5VRYHu+iDhMZTEp2cO+mTkZIZec6E8OF0h36DqFHJd1mLCARr6r0z1d
# y3PhMaEOA4oWxjEWFc0lmj0pG4arp6+G3I125iuTOMO1ZLqBbxqRHn1SG4saxWr7
# gCCoRjxaVeNAYzY5OTIGeVAukHyoPvH2NGljYKrQ5ZaUrTB8f/XN5+tY3n5t7ztL
# DZM9wi50gmff1tsMbtrAoxVgMd+w8nxm/GBaRm5/plkCSmHR5gaHchXzjm1ouR0s
# 4K/Dj1bGqFrkOaLY6OHwaNrm/2TJjcpMXJfdPgLaxzF+Cn/rFF34MY6E1U+9U9r/
# fJFSpjmzlRinLwOdumlXudA7ax7ce8JJutv7I/J6hvWRR8xhr18TZsSygxs5odGA
# aOLxk+38l3Zs991CgEdxQ6o/CMcFQhxJzvF0lliNFvibzWrGOZrcMuO44WWMxlNi
# i9GIa8Qwv3FmPakdFTK/6zm/tUbBwzquM1gzirNlAzoDZEZgkZTvzQZAbRA73zD6
# y5y5NWt9MIIHcTCCBVmgAwIBAgITMwAAABXF52ueAptJmQAAAAAAFTANBgkqhkiG
# 9w0BAQsFADCBiDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAO
# BgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEy
# MDAGA1UEAxMpTWljcm9zb2Z0IFJvb3QgQ2VydGlmaWNhdGUgQXV0aG9yaXR5IDIw
# MTAwHhcNMjEwOTMwMTgyMjI1WhcNMzAwOTMwMTgzMjI1WjB8MQswCQYDVQQGEwJV
# UzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UE
# ChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGlt
# ZS1TdGFtcCBQQ0EgMjAxMDCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIB
# AOThpkzntHIhC3miy9ckeb0O1YLT/e6cBwfSqWxOdcjKNVf2AX9sSuDivbk+F2Az
# /1xPx2b3lVNxWuJ+Slr+uDZnhUYjDLWNE893MsAQGOhgfWpSg0S3po5GawcU88V2
# 9YZQ3MFEyHFcUTE3oAo4bo3t1w/YJlN8OWECesSq/XJprx2rrPY2vjUmZNqYO7oa
# ezOtgFt+jBAcnVL+tuhiJdxqD89d9P6OU8/W7IVWTe/dvI2k45GPsjksUZzpcGkN
# yjYtcI4xyDUoveO0hyTD4MmPfrVUj9z6BVWYbWg7mka97aSueik3rMvrg0XnRm7K
# MtXAhjBcTyziYrLNueKNiOSWrAFKu75xqRdbZ2De+JKRHh09/SDPc31BmkZ1zcRf
# NN0Sidb9pSB9fvzZnkXftnIv231fgLrbqn427DZM9ituqBJR6L8FA6PRc6ZNN3SU
# HDSCD/AQ8rdHGO2n6Jl8P0zbr17C89XYcz1DTsEzOUyOArxCaC4Q6oRRRuLRvWoY
# WmEBc8pnol7XKHYC4jMYctenIPDC+hIK12NvDMk2ZItboKaDIV1fMHSRlJTYuVD5
# C4lh8zYGNRiER9vcG9H9stQcxWv2XFJRXRLbJbqvUAV6bMURHXLvjflSxIUXk8A8
# FdsaN8cIFRg/eKtFtvUeh17aj54WcmnGrnu3tz5q4i6tAgMBAAGjggHdMIIB2TAS
# BgkrBgEEAYI3FQEEBQIDAQABMCMGCSsGAQQBgjcVAgQWBBQqp1L+ZMSavoKRPEY1
# Kc8Q/y8E7jAdBgNVHQ4EFgQUn6cVXQBeYl2D9OXSZacbUzUZ6XIwXAYDVR0gBFUw
# UzBRBgwrBgEEAYI3TIN9AQEwQTA/BggrBgEFBQcCARYzaHR0cDovL3d3dy5taWNy
# b3NvZnQuY29tL3BraW9wcy9Eb2NzL1JlcG9zaXRvcnkuaHRtMBMGA1UdJQQMMAoG
# CCsGAQUFBwMIMBkGCSsGAQQBgjcUAgQMHgoAUwB1AGIAQwBBMAsGA1UdDwQEAwIB
# hjAPBgNVHRMBAf8EBTADAQH/MB8GA1UdIwQYMBaAFNX2VsuP6KJcYmjRPZSQW9fO
# mhjEMFYGA1UdHwRPME0wS6BJoEeGRWh0dHA6Ly9jcmwubWljcm9zb2Z0LmNvbS9w
# a2kvY3JsL3Byb2R1Y3RzL01pY1Jvb0NlckF1dF8yMDEwLTA2LTIzLmNybDBaBggr
# BgEFBQcBAQROMEwwSgYIKwYBBQUHMAKGPmh0dHA6Ly93d3cubWljcm9zb2Z0LmNv
# bS9wa2kvY2VydHMvTWljUm9vQ2VyQXV0XzIwMTAtMDYtMjMuY3J0MA0GCSqGSIb3
# DQEBCwUAA4ICAQCdVX38Kq3hLB9nATEkW+Geckv8qW/qXBS2Pk5HZHixBpOXPTEz
# tTnXwnE2P9pkbHzQdTltuw8x5MKP+2zRoZQYIu7pZmc6U03dmLq2HnjYNi6cqYJW
# AAOwBb6J6Gngugnue99qb74py27YP0h1AdkY3m2CDPVtI1TkeFN1JFe53Z/zjj3G
# 82jfZfakVqr3lbYoVSfQJL1AoL8ZthISEV09J+BAljis9/kpicO8F7BUhUKz/Aye
# ixmJ5/ALaoHCgRlCGVJ1ijbCHcNhcy4sa3tuPywJeBTpkbKpW99Jo3QMvOyRgNI9
# 5ko+ZjtPu4b6MhrZlvSP9pEB9s7GdP32THJvEKt1MMU0sHrYUP4KWN1APMdUbZ1j
# dEgssU5HLcEUBHG/ZPkkvnNtyo4JvbMBV0lUZNlz138eW0QBjloZkWsNn6Qo3GcZ
# KCS6OEuabvshVGtqRRFHqfG3rsjoiV5PndLQTHa1V1QJsWkBRH58oWFsc/4Ku+xB
# Zj1p/cvBQUl+fpO+y/g75LcVv7TOPqUxUYS8vwLBgqJ7Fx0ViY1w/ue10CgaiQuP
# Ntq6TPmb/wrpNPgkNWcr4A245oyZ1uEi6vAnQj0llOZ0dFtq0Z4+7X6gMTN9vMvp
# e784cETRkPHIqzqKOghif9lwY1NNje6CbaUFEMFxBmoQtB1VM1izoXBm8qGCA1Aw
# ggI4AgEBMIH5oYHRpIHOMIHLMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGlu
# Z3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScw
# JQYDVQQLEx5uU2hpZWxkIFRTUyBFU046ODYwMy0wNUUwLUQ5NDcxJTAjBgNVBAMT
# HE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2WiIwoBATAHBgUrDgMCGgMVANO9
# VT9iP2VRLJ4MJqInYNrmFSJLoIGDMIGApH4wfDELMAkGA1UEBhMCVVMxEzARBgNV
# BAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jv
# c29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAg
# UENBIDIwMTAwDQYJKoZIhvcNAQELBQACBQDszxOaMCIYDzIwMjUxMTI0MTcyNTQ2
# WhgPMjAyNTExMjUxNzI1NDZaMHcwPQYKKwYBBAGEWQoEATEvMC0wCgIFAOzPE5oC
# AQAwCgIBAAICKPwCAf8wBwIBAAICE/QwCgIFAOzQZRoCAQAwNgYKKwYBBAGEWQoE
# AjEoMCYwDAYKKwYBBAGEWQoDAqAKMAgCAQACAwehIKEKMAgCAQACAwGGoDANBgkq
# hkiG9w0BAQsFAAOCAQEAFKyI3b4b11rqhZ0Wem2zdjmcefYk30kMvB9jlGJDMG9T
# B3z+3c1J0p4tCQmSoNF3zsCkfNPYqi1KXG8RH00WSr4AedIZHbXh8Mk5ExGxhev3
# T5rjJ+1l8iywlzSuCvnXhqI4PfJTJKEDc8igb1tji5ZEdgZqF/xyJLAC5nk31pRn
# RU1SXukZsggfhWKxhAjRD7UNoopvLwtgt0YH7AImfKNrz/63YkAizxQNEwVtxqVp
# L9kVwKz3bw0qwZ8i03tRo5gZbh2a5IEPgokqul/h/MO4WWq+eySfvlYmLDuQt9Y5
# s6YuyPBhVk0tQW5HeFRnrcfJ35oq4yFsMjObQt/YRDGCBA0wggQJAgEBMIGTMHwx
# CzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRt
# b25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1p
# Y3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwAhMzAAACBywROYnNhfvFAAEAAAIH
# MA0GCWCGSAFlAwQCAQUAoIIBSjAaBgkqhkiG9w0BCQMxDQYLKoZIhvcNAQkQAQQw
# LwYJKoZIhvcNAQkEMSIEIOSSVcL8Lkk0ZmiOI42BhlvUOxywuF68Oih5VUy/X5q3
# MIH6BgsqhkiG9w0BCRACLzGB6jCB5zCB5DCBvQQgL/fU0dB2zUhnmw+e/n2n6/oG
# MEOCgM8jCICafQ8ep7MwgZgwgYCkfjB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMK
# V2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0
# IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0Eg
# MjAxMAITMwAAAgcsETmJzYX7xQABAAACBzAiBCAfQhGuVw2RiPq/M+GAi2t2Pf7m
# hXhf+AGdMP3+m99O6TANBgkqhkiG9w0BAQsFAASCAgCbBlcpYK3usblLzxmaoYkY
# hZqfQZe8+xTkD5OTmNugxUo1GSzjpFlECtUM5YErtxiDyUcIiaT5f5SAXsl2oci8
# ALzZ0LtO43XceWRiWUxrrWEIgiA12c3UKPIikXVlRfi+IJaUgxG/moe6JWfcg0OR
# H35Wtk0E7IDMFPGPXTY3GgR1kQdPOsG2CBRd9jUXt78GI5m3kxAox20BL+vXaTxA
# j+HDVmu/lrGRvOgFE3htOj0/TT7YEa/RcXTVYXslvoHewPrr/dpixvCM21AnECmP
# NoawYQ7jF6YV4vXKKGdouUm/X+B7vqqSXcChS38LlnFLC9MLGCeg6ynAO4pXgTfd
# vsQ7Ku1pcU6KDv3zGBS38itJYqoP8PzpyEGeR1YxNEMSZIfunv5unvV5eO7m6oj8
# ljxFiHQRUCqz9zsX5ch/MHGijdWBB27+A80ENn1NZskMoGLaV/zvD8uubkkDvPkP
# RZ1n8mlkEpJCNtbwnzj1lmVx1GhitrehLAcSwwWLmRYuZo0Z0kASWoE/1Xh9SkJp
# L18hc796HgNBFm3jtqDQD6JWKbobQQ25EPMW7YSKPmIIdAz3S88dd8V41KnKJUi7
# UfVqUGkBXlzEdV3hLtSgr4nh/EWm8bnWz/cOAJZ8TNrzAxkv5JoNqq5/TbbD8WOs
# rrUBPwfex80bQkb8d/dkHA==
# SIG # End signature block
