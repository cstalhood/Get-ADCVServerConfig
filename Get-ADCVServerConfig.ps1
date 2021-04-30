# NetScaler Configuration Extractor
# Note: This script works on Windows 10, but the regex match group commands fail on Windows 7

param (
    # Full path to source config file saved from NetScaler (System > Diagnostics > Running Configuration)
    # If set to "", then the script will prompt for the file.
    [string]$configFile = "",
    #$configFile = "$env:userprofile\Downloads\nsrunning.conf"

    # Name of vServer - or VIP - case insensitive
    # Partial match supported - if more than one match, the script will prompt for a selection. Set it to "" to list all vServers.
    # If vserver name is exact match for one vserver, that vserver will be used, even if it's a substring match for another vserver
    [string]$vserver = "",

    # Optional filename to save output - file will be overwritten
    # If you intend to batch import to NetScaler, then no spaces or capital letters in the file name.
    # If set to "screen", then output will go to screen.
    # If set to "", then the script will prompt for a file. Clicking cancel will output to the screen.
    #[string]$outputFile = "",
    #[string]$outputFile = "screen",
    [string]$outputFile = "$env:userprofile\Downloads\nsconfig.conf",
    #[string]$outputFile = "$env:HOME/Downloads/nsconfig.conf",

    # Optional text editor to open saved output file - text editor should handle UNIX line endings (e.g. Wordpad or Notepad++)
    [string]$textEditor = "c:\Program Files (x86)\Notepad++\notepad++.exe",

    # Optional get CSW vserver Binds for selected LB and/or VPN virtual server
    [switch]$cswBind,

    # Max # of nFactor Next Factors to extract
    [int]$nFactorNestingLevel = 5
)

# Change Log
# ----------
# 2021 Apr 30 - added: get variables from expressions; get variable assignments from responders
# 2021 Apr 27 - fixed sorting of Backup vServers
# 2021 Apr 20 - added DISABLED state to VIP selection screen
# 2021 Feb 5 - fixed TACACS policies and Local Authentication Policies, including global
# 2020 Dec 7 - added Captcha action and NoAuth action
# 2020 Dec 7 - added parameter to set nFactor nesting level
# 2020 Dec 7 - sorted authentication policylabels so NextFactors are created first
# 2019 Jun 3 - added RNAT; added OTP Push Service; added partitions; added Azure Keys
# 2019 Apr 22 - added vServer VIP extraction from other commands (e.g. LDAP Action)
# 2019 Apr 15 - fixed server enumeration
# 2019 Apr 7 - reordered Policy Expression output
# 2019 Apr 1 - new "Sys" option to extract System Settings
# 2019 Mar 6 - fixed Visualizer substring match, and added emailAction
# 2018 Dec 27 - fix aaa tm trafficpolicy/action aaa kcdAccount output (BKF)
# 2018 Dec 2 - added nFactor Visualizer for AAA vServers
# 2018 Nov 19 - MacOS: added List Dialog to select vServers. fix: dialogfocus (BKF)
# 2018 Nov 17 - changed vServer selection to Out-GridView (GUI)
# 2018 Nov 16 - support for MacOS popups for nsconf and saveas. Switch for sort to Sort-object to support MacOs & Powershell core 6
# 2018 Nov 5 - check text editor existince (h/t Bjørn-Kåre Flister)
# 2018 Nov 5 - switch to extract CS vServer for selected LB/VPN/AAA vServer (h/t Bjørn-Kåre Flister)
# 2018 Sep 19 - fixed SAML Policy and SAML Action
# 2018 Sep 11 - parameterized the script, fixed specified vServer
# 2018 July 22 - added ICA Parameters to VPN Global Settings
# 2018 July 18 - added preauthentication policy, added AlwaysOn profile
# 2018 July 12 - added two levels of nFactor NextFactor extraction
# 2018 July 8 - added DNS configuration to every extraction
# 2018 July 7 - added GSLB Sites and rpcNodes
# 2018 July 4 - extract local LB VIPs from Session Action URLs (e.g. StoreFront URL to local LB VIP)
# 2018 July 3 - extract DNS vServers from "set vpn parameter" and Session Actions
# 2018 July 3 - added "*" to select all vServers
# 2018 July 3 - updated for 12.1 (SSL Log Profile, IP Set, Analytics Profile)
# 2018 Jan 23 - skip gobal cache settings if cache feature is not enabled
# 2018 Jan 4 - Sirius' Mark Scott added code to browse to open and save files. Added kcdaccounts to extraction.



#  Start of script code
cls


#  Function to prompt the user for a NetScaler config file.
#  The NetScaler config file can be found in the System > Diagnostics > Running Configuration location in the GUI
Function Get-InputFile($initialDirectory)
{
    if ($IsMacOS){
        $filename = (('tell application "SystemUIServer"'+"`n"+'activate'+"`n"+'set fileName to POSIX path of (choose file with prompt "NetScaler documentation file")'+"`n"+'end tell' | osascript -s s) -split '"')[1]
        if ([String]::IsNullOrEmpty($filename)){break}else{$filename}
    }else{
        [System.Reflection.Assembly]::LoadWithPartialName("System.windows.forms") | Out-Null
        $OpenFileDialog = New-Object System.Windows.Forms.OpenFileDialog
        $OpenFileDialog.Title = "Open NetScaler Config"
        $OpenFileDialog.initialDirectory = $initialDirectory
        $OpenFileDialog.filter = "NetScaler Config (*.conf)| *.conf|All files (*.*)|*.*"
        $OpenFileDialog.ShowDialog() | Out-Null
        $OpenFileDialog.filename
    }
}

#  Function to prompt the user to save the output file
Function Get-OutputFile($initialDirectory)
{
    if ($IsMacOS){
        $DefaultName = 'default name "nsconfig.conf"'
        if ($initialDirectory){
            $DefaultLocation = 'default location "'+$initialDirectory+'"'
        }
        $filename = (('tell application "SystemUIServer"'+"`n"+'activate'+"`n"+'set theName to POSIX path of (choose file name '+$($DefaultName)+' '+$($DefaultLocation)+' with prompt "Save NetScaler documentation file as")'+"`n"+'end tell' | osascript -s s) -split '"')[1]
        $filename
    }else{
        [System.Reflection.Assembly]::LoadWithPartialName("System.windows.forms") | Out-Null
        $SaveFileDialog = New-Object System.Windows.Forms.SaveFileDialog
        $SaveFileDialog.Title = "Save Extracted Config"
        $SaveFileDialog.initialDirectory = $initialDirectory
        $SaveFileDialog.filter = "NetScaler Config File (*.conf)| *.conf|All files (*.*)|*.*"
        $SaveFileDialog.ShowDialog() | Out-Null
        $SaveFileDialog.filename
    }
}


# Run the Get-InputFile function to ask the user for the NetScaler config file
if (!$configFile) { 
    $configFile = Get-InputFile $inputfile 
}
if (!$configFile) { exit }

"Loading config file $configFile ...`n"

$config = ""
$config = Get-Content $configFile -ErrorAction Stop


function addNSObject ($NSObjectType, $NSObjectName) {
    if (!$NSObjectName) { return }
    # write-host $NSObjectType $NSObjectName  #Debug
    if (!$nsObjects.$NSObjectType) { $nsObjects.$NSObjectType = @()}
    $tempObjects = $nsObjects.$NSObjectType
    $nsObjects.$NSObjectType += $NSObjectName
    $nsObjects.$NSObjectType = @($nsObjects.$NSObjectType | Select-Object -Unique)

    # Check if anything was added and display - exit function if nothing new
    $newObjects =@()
    $newObjects = Compare-Object $tempObjects $nsObjects.$NSObjectType
    if (!$newObjects) {return}
    
    # Display progress
    foreach ($newObject in $newObjects) { 
        write-host (("Found {0,-25} " -f $NSObjectType) + $newObject.InputObject )
        #write-host ("In " + $timer.ElapsedMilliseconds + " ms, found $NSObjectType`t " + $newObject.InputObject)
        #$timer.Stop()
        #$timer.Restart()
    }
    
    # Get Filtered Config for the object being added to check for policy sub-objects
    # Don't match "-" to prevent "add serviceGroup -netProfile"
    # Ensure there's whitespace before match to prevent substring matches (e.g. server matching MyServer)
    
    foreach ($uniqueObject in $newObjects.InputObject) {
        $filteredConfig = $config -match "[^-\S]" + $NSObjectType + " " + $uniqueObject + "[^\S]"
        
        
        # Look for Pattern Sets
        if ($config -match "policy patset") {
            $foundObjects = getNSObjects $filteredConfig "policy patset"
            if ($foundObjects) { 
                $nsObjects."policy patset" += $foundObjects
                $nsObjects."policy patset" = @($nsObjects."policy patset" | Select-Object -Unique) 
            }
        }

        # Look for Data Sets
        if ($config -match "policy dataset") {
            $foundObjects = getNSObjects $filteredConfig "policy dataset"
            if ($foundObjects) { 
                $nsObjects."policy dataset" += $foundObjects
                $nsObjects."policy dataset" = @($nsObjects."policy dataset" | Select-Object -Unique) 
            }
        }

        # Look for String Maps
        if ($config -match "policy stringmap") {
            $foundObjects = getNSObjects $filteredConfig "policy stringmap"
            if ($foundObjects) { 
                $nsObjects."policy stringmap" += $foundObjects
                $nsObjects."policy stringmap" = @($nsObjects."policy stringmap" | Select-Object -Unique) 
            }
        }

        # Look for URL Sets
        if ($config -match "policy urlset") {
            $foundObjects = getNSObjects $filteredConfig "policy urlset"
            if ($foundObjects) { 
                $nsObjects."policy urlset" += $foundObjects
                $nsObjects."policy urlset" = @($nsObjects."policy urlset" | Select-Object -Unique) 
            }
        }

        # Look for Expressions
        if ($config -match "policy expression") {
            $foundObjects = getNSObjects $filteredConfig "policy expression"
            if ($foundObjects) { 
                $nsObjects."policy expression" += $foundObjects
                $nsObjects."policy expression" = @($nsObjects."policy expression" | Select-Object -Unique) 
            }
        }

        # Look for Variables
        if ($config -match "ns variable") {
            $foundObjects = getNSObjects $filteredConfig "ns variable"
            if ($foundObjects) { 
                $nsObjects."ns variable" += $foundObjects
                $nsObjects."ns variable" = @($nsObjects."ns variable" | Select-Object -Unique) 
            }
        }

        # Look for Policy Maps
        if ($config -match "policy map") {
            $foundObjects = getNSObjects $filteredConfig "policy map"
            if ($foundObjects) { 
                $nsObjects."policy map" += $foundObjects
                $nsObjects."policy map" = @($nsObjects."policy map" | Select-Object -Unique) 
            }
        }

        # Look for Limit Identifiers
        if ($config -match "ns limitIdentifier") {
            $foundObjects = getNSObjects $filteredConfig "ns limitIdentifier"
            if ($foundObjects) { 
                $nsObjects."ns limitIdentifier" += $foundObjects
                $nsObjects."ns limitIdentifier" = @($nsObjects."ns limitIdentifier" | Select-Object -Unique) 
            }
        }

        # Look for Stream Identifiers
        if ($config -match "stream identifier") {
            $foundObjects = getNSObjects $filteredConfig "stream identifier"
            if ($foundObjects) { 
                $nsObjects."stream identifier" += $foundObjects
                $nsObjects."stream identifier" = @($nsObjects."stream identifier" | Select-Object -Unique) 
            }
        }

        # Look for Policy Extensions
        if ($config -match "ns extension") {
            $foundObjects = getNSObjects $filteredConfig "ns extension"
            if ($foundObjects) { 
                $nsObjects."ns extension" += $foundObjects
                $nsObjects."ns extension" = @($nsObjects."ns extension" | Select-Object -Unique) 
            }
        }

        # Look for Callouts
        if ($filteredConfig -match "CALLOUT") {
            if (!$nsObjects."policy httpCallout") { $nsObjects."policy httpCallout" = @()}
            $nsObjects."policy httpCallout" += getNSObjects $filteredConfig "policy httpCallout"
            $nsObjects."policy httpCallout" = @($nsObjects."policy httpCallout" | Select-Object -Unique)
        }

        # Look for DNS Records
        $foundObjects = getNSObjects $filteredConfig "dns addRec"
        if ($foundObjects) 
        { 
            $nsObjects."dns addRec" += $foundObjects
            $nsObjects."dns addRec" = @($nsObjects."dns addRec" | Select-Object -Unique) 
        }
        $foundObjects = getNSObjects $filteredConfig "dns nsRec"
        if ($foundObjects) 
        { 
            $nsObjects."dns nsRec" += $foundObjects
            $nsObjects."dns nsRec" = @($nsObjects."dns nsRec" | Select-Object -Unique) 
        }

        # Look for vServer VIPs
        if ($filteredConfig -match "\d+\.\d+\.\d+\.\d+" -and $NSObjectType -notmatch " vserver") {
            $objectsToAdd = getNSObjects $filteredConfig "lb vserver"
            if ($objectsToAdd) {
                if (!$nsObjects."lb vserver") { $nsObjects."lb vserver" = @()}
                $nsObjects."lb vserver" += getNSObjects $filteredConfig "lb vserver"
                $nsObjects."lb vserver" = @($nsObjects."lb vserver" | Select-Object -Unique)
                GetLBvServerBindings $objectsToAdd
            }
            
            $objectsToAdd = getNSObjects $filteredConfig "cs vserver"
            if ($objectsToAdd) {
                if (!$nsObjects."cs vserver") { $nsObjects."cs vserver" = @()}
                $nsObjects."cs vserver" += getNSObjects $filteredConfig "cs vserver"
                $nsObjects."cs vserver" = @($nsObjects."cs vserver" | Select-Object -Unique)
            }

            $objectsToAdd = getNSObjects $filteredConfig "vpn vserver"
            if ($objectsToAdd) {
                if (!$nsObjects."vpn vserver") { $nsObjects."vpn vserver" = @()}
                $nsObjects."vpn vserver" += getNSObjects $filteredConfig "vpn vserver"
                $nsObjects."vpn vserver" = @($nsObjects."vpn vserver" | Select-Object -Unique)
            }
        }
    }
}



function getNSObjects ($matchConfig, $NSObjectType, $paramName, $position) {
    if ($paramName -and !($matchConfig -match $paramName)) {
        return
    }
    
    # Read all objects of type from from full config
    $objectsAll = $config | select-string -Pattern ('^(add|set|bind) ' + $NSObjectType + ' (".*?"|[^-"]\S+)($| )') | ForEach-Object {$_.Matches.Groups[2].value}
    $objectsAll = $objectsAll | Where-Object { $nsObjects.$NSObjectType -notcontains $_ }
    
    # if looking for matching vServers, also match on VIPs
    if ($NSObjectType -match " vserver") {
        $VIPsAll = $config | select-string -Pattern ('^add ' + $NSObjectType + ' (".*?"|[^-"]\S+) \S+ (\d+\.\d+\.\d+\.\d+) (\d+)') | ForEach-Object {
            @{
                VIP = $_.Matches.Groups[2].value
                Name = $_.Matches.Groups[1].value
                Port = $_.Matches.Groups[3].value
            }
        }
        $VIPsAll = $VIPsAll | Where-Object {$_.VIP -ne "0.0.0.0"}
    }

    # Strip Comments
    $matchConfig = $matchConfig | ForEach-Object {$_ -replace '-comment ".*?"' }
    
    # Build Position matching string - match objectCandidate after the # of positions - avoids Action name matching Policy name
    if ($position) {
        $positionString = ""
        1..($position) | ForEach-Object {
            $positionString += '(".*?"|[^"]\S+) '
        }
        $positionString += ".* "
    }

    # Match objects to matchConfig
    # optional searchHint helps prevent too many matches (e.g. "tcp")
    $objectMatches = @()
    foreach ($objectCandidate in $objectsAll) {
        
        # For regex, replace dots with escaped dots
        $objectCandidateDots = $objectCandidate -replace "\.", "\."

        # if ($objectCandidate -match "storefront") { write-host $objectCandidate;write-host ($matchConfig);read-host}
        # if ($NSObjectType -match "ssl certKey") { write-host $objectCandidate;write-host ($matchConfig);read-host}
        
        # Trying to avoid substring matches
        if ($paramName) { 
            # Compare candidate to term immediately following parameter name
            if (($matchConfig -match ($paramName + " " + $objectCandidateDots + "$" )) -or ($matchConfig -match ($paramName + " " + $objectCandidateDots + " "))) { 
                $objectMatches += $objectCandidate
            }
        } elseif ($position) {
            # Compare candidate to all terms after the specified position # - avoids action name matching policy name
            if (($matchConfig -match ($positionString + $objectCandidateDots + "$")) -or ($matchConfig -match ($positionString + $objectCandidateDots + " "))) { 
                $objectMatches += $objectCandidate
                # if ($objectCandidate -match "storefront") { write-host $objectCandidate;write-host ($matchConfig);read-host}
            }
        } elseif (($matchConfig -match (" " + $objectCandidateDots + "$")) -or ($matchConfig -match (" " + $objectCandidateDots + " "))) { 
            # Look for candidate at end of string, or with spaces surrounding it - avoids substring matches                

            $objectMatches += $objectCandidate
        } elseif (($matchConfig -match ('"' + $objectCandidateDots + '\\"')) -or ($matchConfig -match ('\(' + $objectCandidateDots + '\)"'))) {
            # Look for AppExpert objects (e.g. policy sets, callouts) in policy expressions that don't have spaces around it
            
            $objectMatches += $objectCandidate
        } elseif (($matchConfig -match ('//' + $objectCandidateDots)) -or ($matchConfig -match ($objectCandidateDots + ':'))) {
            # Look in URLs for DNS records
            
            $objectMatches += $objectCandidate
        } elseif (($matchConfig -match ('\.' + $objectCandidateDots + '(\.|"|\(| )'))) {
            # Look in Policy Expressions for Policy Extensions - .extension. or .extension" or .extension( or .extension 
            
            $objectMatches += $objectCandidate
        } elseif (($matchConfig -match ('\$' + $objectCandidateDots))) {
            # Look for variables 
            
            $objectMatches += $objectCandidate
        }
        
    }

    foreach ($VIP in $VIPsAll) {
        
        # For regex, replace dots with escaped dots
        $VIPDots = $VIP.VIP -replace "\.", "\."
       
        # Trying to avoid substring matches
        if ($paramName) { 
            # Compare candidate to term immediately following parameter name
            if (($matchConfig -match ($paramName + " " + $VIPDots + "$" )) -or ($matchConfig -match ($paramName + " " + $VIPDots + " "))) { 
                if ($matchConfig -match $VIP.Port) { $objectMatches += $VIP.Name }
            }
        } elseif ($position) {
            # Compare candidate to all terms after the specified position # - avoids action name matching policy name
            if (($matchConfig -match ($positionString + $VIPDots + "$")) -or ($matchConfig -match ($positionString + $VIPDots + " "))) { 
                if ($matchConfig -match $VIP.Port) { $objectMatches += $VIP.Name }
            }
        } elseif (($matchConfig -match (" " + $VIPDots + "$")) -or ($matchConfig -match (" " + $VIPDots + " "))) { 
            # Look for candidate at end of string, or with spaces surrounding it - avoids substring matches                

            if ($matchConfig -match $VIP.Port) { $objectMatches += $VIP.Name }
        } elseif (($matchConfig -match ('"' + $VIPDots + '\\"')) -or ($matchConfig -match ('\(' + $VIPDots + '\)"'))) {
            # Look for AppExpert objects (e.g. policy sets, callouts) in policy expressions that don't have spaces around it
            
            if ($matchConfig -match $VIP.Port) { $objectMatches += $VIP.Name }
        } elseif (($matchConfig -match ('//' + $VIPDots)) -or ($matchConfig -match ($VIPDots + ':'))) {
            # Look in URLs for DNS records
            
            if ($matchConfig -match $VIP.Port) { $objectMatches += $VIP.Name }
        } elseif (($matchConfig -match ('\.' + $VIPDots + '(\.|"|\(| )'))) {
            # Look in Policy Expressions for Policy Extensions - .extension. or .extension" or .extension( or .extension 
            
            if ($matchConfig -match $VIP.Port) { $objectMatches += $VIP.Name }
        }
        
    }

    return $objectMatches
}


function GetLBvServerBindings ($objectsList) {

    foreach ($lbvserver in $objectsList) {
        $vserverConfig = $config -match " lb vserver $lbvserver "
        addNSObject "service" (getNSObjects $vserverConfig "service")
        if ($NSObjects.service) {
            foreach ($service in $NSObjects.service) { 
                # wrap config matches in spaces to avoid substring matches
                $serviceConfig = $config -match " service $service "
                addNSObject "monitor" (getNSObjects $serviceConfig "lb monitor" "-monitorName")
                addNSObject "server" (getNSObjects $serviceConfig "server")
                addNSObject "ssl profile" (getNSObjects $serviceConfig "ssl profile")
                addNSObject "netProfile" (getNSObjects $serviceConfig "netProfile" "-netProfile")
                addNSObject "ns trafficDomain" (getNSObjects $serviceConfig "ns trafficDomain" "-td")
                addNSObject "ns httpProfile" (getNSObjects $serviceConfig "ns httpProfile" "-httpProfileName")
                addNSObject "ssl cipher" (getNSObjects $serviceConfig "ssl cipher")
                addNSObject "ssl certKey" (getNSObjects $serviceConfig "ssl certKey" "-certkeyName")
                addNSObject "ssl certKey" (getNSObjects $serviceConfig "ssl certKey" "-cacert")
            }
        }
        addNSObject "serviceGroup" (getNSObjects $vserverConfig "serviceGroup")
        if ($NSObjects.serviceGroup) {
            foreach ($serviceGroup in $NSObjects.serviceGroup) {
                $serviceConfig = $config -match " serviceGroup $serviceGroup "
                addNSObject "monitor" (getNSObjects $serviceConfig "lb monitor" "-monitorName")
                addNSObject "server" (getNSObjects $serviceConfig "server")
                addNSObject "ssl profile" (getNSObjects $serviceConfig "ssl profile")
                addNSObject "netProfile" (getNSObjects $serviceConfig "netProfile" "-netProfile")
                addNSObject "ns trafficDomain" (getNSObjects $serviceConfig "ns trafficDomain" "-td")
                addNSObject "ns httpProfile" (getNSObjects $serviceConfig "ns httpProfile" "-httpProfileName")
                addNSObject "ssl cipher" (getNSObjects $serviceConfig "ssl cipher")
                addNSObject "ssl certKey" (getNSObjects $serviceConfig "ssl certKey" "-certkeyName")
                addNSObject "ssl certKey" (getNSObjects $serviceConfig "ssl certKey" "-cacert")
            }
        }
        addNSObject "netProfile" (getNSObjects $vserverConfig "netProfile" "-netProfile")
        addNSObject "ns trafficDomain" (getNSObjects $vserverConfig "ns trafficDomain" "-td")
        addNSObject "authentication vserver" (getNSObjects $vserverConfig "authentication vserver" "-authnVsName")
        addNSObject "authentication authnProfile" (getNSObjects $vserverConfig "authentication authnProfile" "-authnProfile")
        addNSObject "authorization policylabel" (getNSObjects $vserverConfig "authorization policylabel")
        addNSObject "authorization policy" (getNSObjects $vserverConfig "authorization policy" "-policyName")
        addNSObject "ssl policy" (getNSObjects $vserverConfig "ssl policy" "-policyName")
        addNSObject "ssl cipher" (getNSObjects $vserverConfig "ssl cipher" "-cipherName")
        addNSObject "ssl profile" (getNSObjects $vserverConfig "ssl profile")
        addNSObject "ssl certKey" (getNSObjects $vserverConfig "ssl certKey" "-certkeyName")
        addNSObject "ssl certKey" (getNSObjects $vserverConfig "ssl certKey" "-cacert")
        addNSObject "ssl vserver" (getNSObjects ($config -match "ssl vserver $lbvserver ") "ssl vserver")
        addNSObject "responder policy" (getNSObjects $vserverConfig "responder policy" "-policyName")
        addNSObject "responder policylabel" (getNSObjects $vserverConfig "responder policylabel" "policylabel")
        addNSObject "rewrite policy" (getNSObjects $vserverConfig "rewrite policy" "-policyName")
        addNSObject "rewrite policylabel" (getNSObjects $vserverConfig "rewrite policylabel" "policylabel")
        addNSObject "cache policy" (getNSObjects $vserverConfig "cache policy" "-policyName")
        addNSObject "cache policylabel" (getNSObjects $vserverConfig "cache policylabel")
        addNSObject "cmp policy" (getNSObjects $vserverConfig "cmp policy" "-policyName")
        addNSObject "cmp policylabel" (getNSObjects $vserverConfig "cmp policylabel" "policylabel")
        addNSObject "appqoe policy" (getNSObjects $vserverConfig "appqoe policy" "-policyName")
        addNSObject "appflow policy" (getNSObjects $vserverConfig "appflow policy" "-policyName")
        addNSObject "appflow policylabel" (getNSObjects $vserverConfig "appflow policylabel" "policylabel")
        addNSObject "appfw policy" (getNSObjects $vserverConfig "appfw policy" "-policyName")
        addNSObject "appfw policylabel" (getNSObjects $vserverConfig "appfw policylabel" "policylabel")
        addNSObject "filter policy" (getNSObjects $vserverConfig "filter policy" "-policyName")
        addNSObject "transform policy" (getNSObjects $vserverConfig "transform policy" "-policyName")
        addNSObject "transform policylabel" (getNSObjects $vserverConfig "transform policylabel")
        addNSObject "tm trafficPolicy" (getNSObjects $vserverConfig "tm trafficPolicy" "-policyName")
        addNSObject "feo policy" (getNSObjects $vserverConfig "feo policy" "-policyName")
        addNSObject "spillover policy" (getNSObjects $vserverConfig "spillover policy" "-policyName")
        addNSObject "audit syslogPolicy" (getNSObjects $vserverConfig "audit syslogPolicy" "-policyName")
        addNSObject "audit nslogPolicy" (getNSObjects $vserverConfig "audit nslogPolicy" "-policyName")
        addNSObject "dns profile" (getNSObjects $vserverConfig "dns profile" "-dnsProfileName" )
        addNSObject "ns tcpProfile" (getNSObjects $vserverConfig "ns tcpProfile" "-tcpProfileName")
        addNSObject "ns httpProfile" (getNSObjects $vserverConfig "ns httpProfile" "-httpProfileName")
        addNSObject "db dbProfile" (getNSObjects $vserverConfig "db dbProfile" "-dbProfileName")
        addNSObject "lb profile" (getNSObjects $vserverConfig "lb profile" "-lbprofilename")
        addNSObject "ipset" (getNSObjects $vserverConfig "ipset" "-ipset")
        addNSObject "authentication adfsProxyProfile" (getNSObjects $vserverConfig "authentication adfsProxyProfile" "-adfsProxyProfile")
    }

}

function getHttpVServer ($matchConfig) {
    # Matches local LB/CS vServer VIPs in URLs (e.g. StoreFront URL) - No FQDN support

    # Read all LB/CS objects of protocol HTTP/SSL from from full config. Extract Name, IP, and Port
    if ($matchConfig -match "http://") 
    {
        $objectsAll = $config | select-string -Pattern '^add (lb|cs) vserver (".*?"|[^-"]\S+) HTTP (\d+\.\d+.\d+\.\d+) (\d+) ' | ForEach-Object { New-Object PSObject -property @{
            Name = $_.Matches.Groups[2].value
            IP = $_.Matches.Groups[3].value
            Port = $_.Matches.Groups[4].value
            }
        }
    } 
    elseif ($matchConfig -match "https://")
    {
        $objectsAll = $config | select-string -Pattern '^add (lb|cs) vserver (".*?"|[^-"]\S+) SSL (\d+\.\d+.\d+\.\d+) (\d+)' | ForEach-Object { New-Object PSObject -property @{
            Name = $_.Matches.Groups[2].value
            IP = $_.Matches.Groups[3].value
            Port = $_.Matches.Groups[4].value
            }
        }
    }
    
    # Check URL for matching VIP and/or Port number
    $objectMatches = @()
    foreach ($objectCandidate in $objectsAll) 
    {
        if ($matchConfig -match $objectCandidate.IP)
        {
            if ($matchConfig -match ":\d+/")
            {
                if ($matchConfig -match (":" + $objectCandidate.Port + "/"))
                {
                    $objectMatches += $objectCandidate.Name
                }
            } 
            elseif ($objectCandidate.Port -eq "80" -or $objectCandidate.Port -eq "443") 
            {
                $objectMatches += $objectCandidate.Name
            }
        }
    }
    
    return $objectMatches
}



function outputnFactorPolicies ($bindingType, $indent) {
    $matchedConfig = @()
    $loginSchemaProfile = $config | select-string -Pattern ('^add ' + $bindingType + ' -loginSchema (".*?"|[^-"]\S+)') | ForEach-Object {$_.Matches.Groups[1].value}
    if ($loginSchemaProfile) {
        $matchedConfig += $linePrefix + ($spacing * ($indent)) + "Login Schema Profile = " + $loginSchemaProfile
        $loginSchemaProfile = $config -match '^add authentication loginSchema ' + $loginSchemaProfile + " "
        $loginSchemaXML = $loginSchemaProfile | select-string -Pattern ('-authenticationSchema (".*?"|[^-"]\S+)') | ForEach-Object {$_.Matches.Groups[1].value}
        if ($loginSchemaXML) {
            $matchedConfig += $linePrefix + ($spacing * ($indent)) + "Login Schema XML = " + $loginSchemaXML
        }
    }
    $policies = $config | select-string -Pattern ('^bind ' + $bindingType + ' -(policy|policyName|loginSchema) (".*?"|[^-"]\S+)($| )') | ForEach-Object {$_.Matches.Groups[2].value}
    foreach ($policy in $policies) {
        $policyBinding = $config -match ('^bind ' + $bindingType + " -(policy|policyName|loginSchema) " + $policy + " ")
        $priority = $policyBinding | select-string -Pattern ('-priority (\d+)') | ForEach-Object {$_.Matches.Groups[1].value}
        $goto = $policyBinding | select-string -Pattern ('-gotoPriorityExpression (\S+)') | ForEach-Object {$_.Matches.Groups[1].value}
        $loginSchemaPolicy = $config -match '^add authentication loginSchemaPolicy ' + $policy + " "
        if ($loginSchemaPolicy) {
            $loginSchemaAction = $loginSchemaPolicy | select-string -Pattern ('-action (".*?"|[^-"]\S+)') | ForEach-Object {$_.Matches.Groups[1].value}
            $rule = $loginSchemaPolicy | select-string -Pattern ('-rule (.*?) -action') | ForEach-Object {$_.Matches.Groups[1].value}
            $matchedConfig += $linePrefix + ($spacing * $indent) + "Login Schema Policy = " + $policy
            $matchedConfig += $linePrefix + ($spacing * ($indent + 1)) + "Priority = " + $priority
            $matchedConfig += $linePrefix + ($spacing * ($indent + 1)) + "Rule = " + $rule
            $loginSchemaProfile = $config -match '^add authentication loginSchema ' + $loginSchemaAction + " "
            if ($loginSchemaProfile) {
                $loginSchemaXML = $loginSchemaProfile | select-string -Pattern ('-authenticationSchema (".*?"|[^-"]\S+)') | ForEach-Object {$_.Matches.Groups[1].value}
                $matchedConfig += $linePrefix + ($spacing * ($indent + 1)) + "Login Schema XML = " + $loginSchemaXML
            }
        }
        $authPolicy = $config -match '^add authentication Policy ' + $policy + ' '
        if ($authPolicy) {
            $authAction = $authPolicy | select-string -Pattern ('-action (".*?"|[^-"]\S+)') | ForEach-Object {$_.Matches.Groups[1].value}
            $authActionConfig = $config -match '^add authentication \w+?Action ' + $authAction + " "
            $AAAGroup = $authActionConfig | select-string -Pattern ('-defaultAuthenticationGroup (".*?"|[^-"]\S+)') | ForEach-Object {$_.Matches.Groups[1].value}
            $authType = $authActionConfig | select-string -Pattern ('^add authentication (\w+?Action)') | ForEach-Object {$_.Matches.Groups[1].value}
            $rule = $authPolicy | select-string -Pattern ('-rule (.*?) -action') | ForEach-Object {$_.Matches.Groups[1].value}
            $nextFactor = $policyBinding | select-string -Pattern ('-nextFactor (".*?"|[^-"]\S+)') | ForEach-Object {$_.Matches.Groups[1].value}
            $matchedConfig += $linePrefix + ($spacing * $indent) + "Adv Authn Policy = " + $policy
            $matchedConfig += $linePrefix + ($spacing * ($indent + 1)) + "Priority = " + $priority
            $matchedConfig += $linePrefix + ($spacing * ($indent + 1)) + "Rule = " + $rule
            if ($authType) {
                $matchedConfig += $linePrefix + ($spacing * ($indent + 1)) + "Action = " + $authType + " named " + $authAction
            } else {
                $matchedConfig += $linePrefix + ($spacing * ($indent + 1)) + "Action = " + $authAction
            }
            if ($AAAGroup) {
                $matchedConfig += $linePrefix + ($spacing * ($indent + 1)) + "AAA Group = " + $AAAGroup            
            }
            $matchedConfig += $linePrefix + ($spacing * ($indent + 1)) + "Goto if failed = " + $goto
            if ($nextFactor) {
                $matchedConfig += $linePrefix + ($spacing * ($indent + 1)) + "Next Factor if Success = " + $nextFactor
                $matchedConfig += outputnFactorPolicies ('authentication policylabel ' + $nextFactor) ($indent + 2)
            }
        }
    }
    return $matchedConfig
}

function outputObjectConfig ($header, $NSObjectKey, $NSObjectType, $explainText) {
    $uniqueObjects = $NSObjects.$NSObjectKey | Select-Object -Unique
    
    # Build header line
    $output = "# " + $header + "`n# "
    1..$header.length | ForEach-Object {$output += "-"}
    $output += "`n"
    
    $matchedConfig = @()
    if ($NSObjectType -eq "raw") { 
        # Print actual Object Values. Don't get output from filtered config.
        $matchedConfig = $NSObjects.$NSObjectKey + "`n"
    } else {    
        foreach ($uniqueObject in $uniqueObjects) {
        
            # For regex, replace dots with escaped dots
            $uniqueObject = $uniqueObject -replace "\.", "\."
            
            # Don't match "-" to prevent "add serviceGroup -netProfile"
            # Ensure there's whitespace before match to prevent substring matches (e.g. MyServer matching server)
            if ($NSObjectType) { 
                # Optional $NSObjectType overrides $NSObjectKey if they don't match (e.g. CA Cert doesn't match certKey)
                $matchedConfig += $config -match "[^-\S]" + $NSObjectType + " " + $uniqueObject + "$"
                $matchedConfig += $config -match "[^-\S]" + $NSObjectType + " " + $uniqueObject + "[^\S]"
            } else { 
                $matchedConfig += $config -match "[^-\S]" + $NSObjectKey + " " + $uniqueObject + "$"
                $matchedConfig += $config -match "[^-\S]" + $NSObjectKey + " " + $uniqueObject + "[^\S]" 
            }
            # if ($uniqueObject -eq "NO_RW_192\.168\.192\.242") {write-host $uniqueObject $matchedConfig}
            
            $matchedConfig += "`n"
        }
    }

    if ($explainText) { 
        $explainText = @($explainText -split "`n")
        $explainText | ForEach-Object {
            $matchedConfig += "# *** " + $_
        }
        $matchedConfig += "`n"
    }

    # nFactor Visualizer
    if ($NSObjectKey -eq "authentication vserver") {
        $linePrefix = "# ** "
        $spacing = "   "
        foreach ($aaavServer in $uniqueObjects) {
            $indent = 0
            $matchedConfig += $linePrefix + "nFactor Visualizer "
            $matchedConfig += $linePrefix + "------------------ "
            $matchedConfig += $linePrefix + ($spacing * $indent) + "AAA vserver: " + $aaavServer
            $matchedConfig += outputnFactorPolicies ("authentication vserver " + $aaavServer) 1
            $matchedConfig += "`n"
        }
    }
    
    # Add line endings to output
    $SSLVServerName = ""
    foreach ($line in $matchedConfig) { 
        
        # if binding new cipher group, remove old ciphers first
        # only add unbind line once per SSL object
        $SSLvserverNameMatch = $line | select-string -Pattern ('^bind ssl (vserver|service|serviceGroup|monitor) (.*) -cipherName') | ForEach-Object {$_.Matches.Groups[2].value}
        if ($SSLvserverNameMatch -and ($SSLVServerName -ne $SSLvserverNameMatch)) {
            $SSLVServerName = $SSLvserverNameMatch
            $output += ($line -replace "bind (.*) -cipherName .*", "unbind `$1 -cipherName DEFAULT`n")
        }
        
        # handle one blank line between mutliple objects of same type
        if ($line -ne "`n") { 
            $output += $line + "`n" 
        } else {
            $output += "`n"
        }
    }
    
    # Output to file or screen
    if ($outputFile -and ($outputFile -ne "screen")) {
        $output | out-file $outputFile -Append
    } else {
        $output
    }
}

## Start main script

# Clear configuration from last run
$nsObjects = @{}

$selectionDone =$false
$firstLoop = $true

do {
    # Get matching vServer Names. If more than one, prompt for selection.
    # This loop allows users to change the vServer filter text

    if ($vserver -match " ") { 
        $vserver = [char]34 + $vserver + [char]34 
    }
    $vservers = $config -match "$vserver" | select-string -Pattern ('^add \w+ vserver (".*?"|[^-"]\S+)') | ForEach-Object {$_.Matches.Groups[1].value}
    if (!$vservers) {
        # Try substring matches without quotes
        if ($vserver -match " ") { $vserver = $vserver -replace [char]34 }
        $vservers = $config -match "$vserver" | select-string -Pattern ('^add \w+ vserver (".*?"|[^-"]\S+)') | ForEach-Object {$_.Matches.Groups[1].value}
    }
    
    # Make sure it's an array, even if only one match
    $vservers = @($vservers)

    # FirstLoop flag enables running script without prompting. 
    # If second loop, then user must have changed the filter and wants to see results even if only one (or none).
    if (($vservers.length -eq 1 -and $firstLoop) -or $vservers -contains $vserver) { 
        # Get vServer Type
        $vserverType = $config -match " $vservers " | select-string -Pattern ('^add (\w+) vserver') | ForEach-Object {$_.Matches.Groups[1].value}
        addNSObject ($vserverType + " vserver") $vservers
        $selectionDone = $true
    } else {
        # Prompt for vServer selection
        
        # Prepend System option
        $vservers = @("System Settings") + $vservers

        # Get vServer Type for each vServer name - later display to user
        $vserverTypes = @("") * ($vservers.length)
        $vserverTypes[0] = "sys"
        for ($x = 1; $x -lt $vservers.length; $x++) {
            $vserverTypes[$x] = $config -match "$vserver" | select-string -Pattern ('^add (\w+) vserver ' + $vservers[$x] + " ") | ForEach-Object {$_.Matches.Groups[1].value}
        }
        
        # Change "authentication" to "aaa" so it fits within 4 char column
        $vserverTypes = $vserverTypes -replace "authentication", "aaa"
    
        # Get VIPs for each vServer so they can be displayed to the user
        $VIPs = @("") * ($vservers.length)
        for ($x = 1; $x -lt $vservers.length; $x++) {
            $VIPs[$x] = $config -match "$vserver" | select-string -Pattern ('^add \w+ vserver ' + $vservers[$x] + ' \w+ (\d+\.\d+\.\d+\.\d+)') | ForEach-Object {$_.Matches.Groups[1].value}
        }
		
		# Get Enabled/Disabled State for each vServer so they can be displayed to the user
        $States = @("") * ($vservers.length)
        for ($x = 1; $x -lt $vservers.length; $x++) {
            $States[$x] = $config -match "$vserver" | select-string -Pattern ('^add \w+ vserver ' + $vservers[$x] + ' .*? -state (\w+)') | ForEach-Object {$_.Matches.Groups[1].value}
        }

        $selected = @("") * ($vservers.length)
    
        # Grid View 
        $vserverObjects = @()
        $vserverObjects = for ($x = 0; $x -lt $vservers.length; $x++) {
            [PSCustomObject] @{
                Type = $vserverTypes[$x]
                Name = $vservers[$x]
                VIP = $VIPs[$x]
				State = $States[$x]
                }
        }
        if ($IsMacOS){
            "Use Listbox window to select Virtual Servers`n"
            $vserverlist = $vservers | Foreach-object{,($_.trim('"') )}
            $vserverlist = (('tell application "SystemUIServer"'+"`n"+'activate'+"`n"+'set vserver to (choose from list  {"'+($vserverlist -join '","')+'"} with prompt "Command+Select Multiple Virtual Servers to extract" with multiple selections allowed)'+"`n"+'end tell' | osascript -s s) -replace ', ',',')
            $vserverObjects = @()
            [regex]::Matches($vserverlist, '(?:([\w\s]+))') | ForEach-Object {
                if ($_.value -match ' '){$vservername = '"'+$_.value+'"'}
                else {$vservername = $_.value}
                $x = $vservers.IndexOf($vservername)
                $vserverObjects += [PSCustomObject] @{
                    Type = $vserverTypes[$x]
                    Name = $vservers[$x]
                    }
            }
        } else {
            "Use Grid View window to select Virtual Servers`n"
            $vserverObjects = $vserverObjects | Out-GridView -Title "Ctrl+Select Multiple Virtual Servers to extract" -PassThru
        }
        if (!$vserverObjects) { exit }
        $vservers = @()
        foreach ($vserverObject in $vserverObjects) {
            if ($vserverObject.Type -eq "aaa") {
                $vserverObject.Type = "authentication"
            }
            if ($vserverObject.Type -eq "sys") {
                addNSObject ("sys") $vserverObject.Name
                $vservers += "System Settings"
            } else {
                addNSObject ($vserverObject.Type + " vserver") $vserverObject.Name
                $vservers += $vserverObject.Name
            }
        }
        $selectionDone = $true

        # CLI Menu Selection
        <# do {
            $count = 1
            cls
            $promptString = "Select one or more of the following Virtual Servers for configuration extraction:`n`n"
            $promptString += "Virtual Server Filter = $vserver`n`n"
            $promptString += "   Num   Type        VIP          Name`n"
            $maxLength = ($vservers | sort-object length -desc | select -first 1).length
            $promptString += "  -----  ----  " + ("-" * 15) + "  " + ("-" * $maxLength) + "`n"
            write-host $promptString
            foreach ($vserverOption in $vservers) {
                $promptString = "{0,1} {1,4}:  {2,4}  {3,15}  $vserverOption" -f $selected[$count-1], $count, $vserverTypes[$count-1], $VIPs[$count-1]
                if ($selected[$count-1] -eq "*") {
                    write-host -foregroundcolor yellow $promptString
                } else {
                    write-host $promptString
                }
                $count++
            }
            write-host ""
            $entry = read-host "Enter Number to select/deselect, * for all, 0 for new filter string, or <Enter> to begin extraction"
            if (!$entry -or $entry -eq "") { $selectionDone = $true; break }
            if ($entry -eq "*")
            {
                for ($x = 0; $x -lt $selected.length; $x++) {
                    if ($selected[$x] -eq "*") { 
                        $selected[$x] = "" 
                    } else
                    { 
                        $selected[$x] = "*" 
                    }
                }
            } else
            {
                try
                {
                    $entry = [int]$entry
                    if ($entry -lt 0 -or $entry -gt $count) 
                    {
                        write-host "`nInvalid entry. Press Enter to try again. ";read-host
                        $entry = "retry"
                    } elseif ($entry -ge 1 -and $entry -le $count) 
                    {
                        # Swap select status
                        if ($selected[$entry -1] -eq "*") 
                        { 
                            $selected[$entry-1] = "" 
                        } else
                        { 
                            $selected[$entry-1] = "*" 
                        }
                    } elseif ($entry -eq 0) 
                    {
                        $newFilter = read-host "Enter new filter string"
                        $vserver = $newFilter
                        $entry = ""
                        $selected = ""
                    }
                } catch 
                {
                    write-host "`nInvalid entry. Press Enter to try again. ";read-host
                    $entry = "retry"
                }
            }
        } while ($entry -and $entry -ne "")

        $vserversSelected = @()
        for ($x = 0; $x -lt ($selected.length); $x++) {
            $vserverTypes = $vserverTypes -replace "aaa", "authentication"
            if ($selected[$x] -eq "*") {
                addNSObject ($vserverTypes[$x] + " vserver") $vservers[$x] 
                $vserversSelected += $vservers[$x]
                $selectionDone = $true
            }
        }
    
        $vservers = $vserversSelected #>
    }
    $firstLoop = $false
} while (!$selectionDone)

if (!$vservers) { exit }


# Run the Get-Output function to ask the user where to save the NetScaler documentation file
if (!$outputFile) { $outputFile = Get-OutputFile $outputfile }


"`nLooking for objects associated with selected vServers: `n" + ($vservers -join "`n") + "`n"

$Timer = [system.diagnostics.stopwatch]::StartNew()

# Get DNS Servers
if ($nsObjects."sys") {
    addNSObject "ns partition" (getNSObjects ($config -match "add ns partition") "ns partition")
    addNSObject "dns nameServer" (getNSObjects ($config -match "add dns nameServer") "dns nameServer")
    if ($nsObjects."dns nameServer") 
    {
        foreach ($nameserver in $nsObjects."dns nameServer") {
            $nameServerConfig = $config -match "lb vserver $nameserver "
            addNSObject "lb vserver" (getNSObjects $nameServerConfig "lb vserver")
        }
    }
    addNSObject "ns feature" ($config -match "ns feature")
    addNSObject "ns mode" ($config -match "ns mode")
    addNSObject "system parameter" ($config -match "system parameter")
    addNSObject "ns encryptionParams" ($config -match "set ns encryptionParams")
    addNSObject "ssl cipher" (getNSObjects $vserverConfig "ssl cipher" "-cipherName")
    
    # Get Networking Settings
    addNSObject "ns config" ($config -match "ns config")
    addNSObject "ns hostName" ($config -match "ns hostName")
    addNSObject "interface" ($config -match " interface ")
    addNSObject "channel" ($config -match " channel ")
    addNSObject "vlan" (getNSObjects ($config -match " vlan ") "vlan")
    addNSObject "vrid" (getNSObjects ($config -match "vrid") "vrid")
    addNSObject "ns ip" (getNSObjects ($config -match "ns ip") "ns ip")
    addNSObject "route" ($config -match " route ")
    addNSObject "ns pbr" ($config -match " ns pbr")
    addNSObject "mgmt ssl service" (getNSObjects ($config -match " ssl service ns(krpcs|https|rpcs|rnatsip)-") "ssl service")

    # Get SNMP
    addNSObject "snmp community" ($config -match " snmp community")
    addNSObject "snmp manager" ($config -match " snmp manager")
    addNSObject "snmp trap" ($config -match " snmp trap")
    addNSObject "snmp alarm" ($config -match " snmp alarm")

    # Get HA settings
    addNSObject "ha node" ($config -match "HA node")
    addNSObject "ha rpcNode" (getNSObjects ($config -match "set ns config") "ns rpcNode")
    addNSObject "ha rpcNode" (getNSObjects ($config -match "HA node") "ns rpcNode")
    
    # Get System Global Bindings - authentication, syslog
    addNSObject "system global" ($config -match "system global")
    addNSObject "authentication Policy" (getNSObjects ($config -match "system global") "authentication Policy")
    addNSObject "authentication ldapPolicy" (getNSObjects ($config -match "system global") "authentication ldapPolicy")
    addNSObject "authentication radiusPolicy" (getNSObjects ($config -match "system global") "authentication radiusPolicy")
    addNSObject "authentication tacacsPolicy" (getNSObjects ($config -match "system global") "authentication tacacsPolicy")
    addNSObject "authentication localPolicy" (getNSObjects ($config -match "system global") "authentication localPolicy")
    addNSObject "audit syslogPolicy" (getNSObjects ($config -match "bind system global") "audit syslogPolicy")
    addNSObject "audit syslogPolicy" (getNSObjects ($config -match "bind audit syslogGlobal") "audit syslogPolicy")
    addNSObject "audit nslogPolicy" (getNSObjects ($config -match "bind system global") "audit nslogPolicy") 
    addNSObject "system user" (getNSObjects ($config -match "system user") "system user")
    addNSObject "system group" (getNSObjects ($config -match "system group") "system group")
    
}


# If $cswBind switch is true, look for CS vServers that the LB, AAA, and/or VPN vServers are bound to.
if ($cswBind){
    $cswBindType = @{lb='lbvserver';vpn='vserver';authentication='vserver'}
    foreach ($vsrvType in 'lb','vpn','authentication' ) {
        if ($nsObjects."$vsrvType vserver") {
            foreach ($vsrv in $nsObjects."$vsrvType vserver")
            {
                # CSW Default virtual server
                if ($config -match "bind cs vserver .* -$($cswBindType.$vsrvType) $vsrv"){
                    addNSObject "cs vserver" ($config -match "bind cs vserver .* -$($cswBindType.$vsrvType) $vsrv" | select-string -Pattern ('^bind cs vserver (".*?"|[^-"]\S+)') | ForEach-Object {$_.Matches.Groups[1].value})
                }
                # CSW Policy Bind -targetlbserver
                if ($config -match "bind cs vserver .* -policyName .* -targetLBVserver $vsrv"){
                    addNSObject "cs vserver" ($config -match "bind cs vserver .* -policyName .* -targetLBVserver $vsrv" | select-string -Pattern ('^bind cs vserver (".*?"|[^-"]\S+)') | ForEach-Object {$_.Matches.Groups[1].value})
                }
                # CSW Action -targetlbserver -targetvserver
                if ($config -match "add cs action .* -target$($cswBindType.$vsrvType) $vsrv"){
                    $csaction = ($config -match "add cs action .* -target$($cswBindType.$vsrvType) $vsrv" | select-string -Pattern ('^add cs action (".*?"|[^-"]\S+)') | ForEach-Object {$_.Matches.Groups[1].value})
                    #CS Policy for CS Action
                    $cspolicy = ($config -match "add cs policy .* -action $csaction" | select-string -Pattern ('^add cs policy (".*?"|[^-"]\S+)') | ForEach-Object {$_.Matches.Groups[1].value})
                    #CS vServer for CS Policy
                    addNSObject "cs vserver" ($config -match "bind cs vserver .* -policyName $cspolicy" | select-string -Pattern ('^bind cs vserver (".*?"|[^-"]\S+)') | ForEach-Object {$_.Matches.Groups[1].value})
                }
            }
        }
    }
}

# Look for Backup CSW vServers and Linked LB vServers
if ($nsObjects."cs vserver") {
    if ($config -match "enable ns feature.* CS") 
    {
        $NSObjects."cs parameter" = @("enable ns feature CS")
    } else {
        $NSObjects."cs parameter" = @("# *** CS feature is not enabled")
    }
    
    foreach ($csvserver in $nsObjects."cs vserver") {
        $currentVServers = $nsObjects."cs vserver"
        $nsObjects."cs vserver" = @()   
        $vserverConfig = $config -match " $csvserver "
        # Backup VServers should be created before Active VServers
        $backupVServers = getNSObjects ($vserverConfig) "cs vserver" "-backupVServer"
        if ($backupVServers) {
            addNSObject "cs vserver" ($backupVServers)
            foreach ($vserver in $currentvservers) {
                if ($backupVServers -notcontains $vserver) {
                    addNSObject "cs vserver" ($vserver)
                }
            }
        } else {
            $nsObjects."cs vserver" = $currentVServers
        }
        addNSObject "lb vserver" (getNSObjects $vserverconfig "lb vserver" "-targetLBVserver")
    }
}


# Enumerate CSW vServer config for additional bound objects
if ($nsObjects."cs vserver") {
    foreach ($csvserver in $nsObjects."cs vserver") {
        $vserverConfig = $config -match "vserver $csvserver "
        addNSObject "cs policy" (getNSObjects $vserverConfig "cs policy" "-policyName")
        addNSObject "cs policylabel" (getNSObjects $vserverConfig "cs policylabel" "policylabel")
        addNSObject "lb vserver" (getNSObjects $vserverConfig "lb vserver" "-lbvserver")
        addNSObject "gslb vserver" (getNSObjects $vserverConfig "gslb vserver" "-vserver")
        addNSObject "vpn vserver" (getNSObjects $vserverConfig "vpn vserver" "-vserver")
        addNSObject "netProfile" (getNSObjects $vserverConfig "netProfile" "-netProfile")
        addNSObject "ns trafficDomain" (getNSObjects $vserverConfig "ns trafficDomain" "-td")
        addNSObject "ns tcpProfile" (getNSObjects $vserverConfig "ns tcpProfile" "-tcpProfileName")
        addNSObject "ns httpProfile" (getNSObjects $vserverConfig "ns httpProfile" "-httpProfileName")
        addNSObject "db dbProfile" (getNSObjects $vserverConfig "db dbProfile" "-dbProfileName")
        addNSObject "dns profile" (getNSObjects $vserverConfig "dns profile" "-dnsProfileName")
        addNSObject "authentication vserver" (getNSObjects $vserverConfig "authentication vserver" "-authnVsName")
        addNSObject "authentication authnProfile" (getNSObjects $vserverConfig "authentication authnProfile" "-authnProfile")
        addNSObject "authorization policylabel" (getNSObjects $vserverConfig "authorization policylabel")
        addNSObject "authorization policy" (getNSObjects $vserverConfig "authorization policy" "-policyName")
        addNSObject "audit syslogPolicy" (getNSObjects $vserverConfig "audit syslogPolicy" "-policyName")
        addNSObject "audit nslogPolicy" (getNSObjects $vserverConfig "audit nslogPolicy" "-policyName")
        addNSObject "ssl policy" (getNSObjects $vserverConfig "ssl policy" "-policyName")
        addNSObject "ssl cipher" (getNSObjects $vserverConfig "ssl cipher" "-cipherName")
        addNSObject "ssl profile" (getNSObjects $vserverConfig "ssl profile")
        addNSObject "ssl certKey" (getNSObjects $vserverConfig "ssl certKey" "-certKeyName")
        addNSObject "ssl vserver" (getNSObjects ($config -match "ssl vserver $csvserver ") "ssl vserver")
        addNSObject "cmp policy" (getNSObjects $vserverConfig "cmp policy" "-policyName")
        addNSObject "cmp policylabel" (getNSObjects $vserverConfig "cmp policylabel" "policylabel")
        addNSObject "responder policy" (getNSObjects $vserverConfig "responder policy" "-policyName")
        addNSObject "responder policylabel" (getNSObjects $vserverConfig "responder policylabel" "policylabel")
        addNSObject "rewrite policy" (getNSObjects $vserverConfig "rewrite policy" "-policyName")
        addNSObject "rewrite policylabel" (getNSObjects $vserverConfig "rewrite policylabel" "policylabel")
        addNSObject "appflow policy" (getNSObjects $vserverConfig "appflow policy" "-policyName")
        addNSObject "appflow policylabel" (getNSObjects $vserverConfig "appflow policylabel" "policylabel")
        addNSObject "appfw policy" (getNSObjects $vserverConfig "appfw policy" "-policyName")
        addNSObject "appfw policylabel" (getNSObjects $vserverConfig "appfw policylabel" "policylabel")
        addNSObject "cache policy" (getNSObjects $vserverConfig "cache policy" "-policyName")
        addNSObject "cache policylabel" (getNSObjects $vserverConfig "cache policylabel" "policylabel")
        addNSObject "transform policy" (getNSObjects $vserverConfig "transform policy" "-policyName")
        addNSObject "transform policylabel" (getNSObjects $vserverConfig "transform policylabel")
        addNSObject "tm trafficPolicy" (getNSObjects $vserverConfig "tm trafficPolicy" "-policyName")
        addNSObject "feo policy" (getNSObjects $vserverConfig "feo policy" "-policyName")
        addNSObject "spillover policy" (getNSObjects $vserverConfig "spillover policy" "-policyName")
        addNSObject "appqoe policy" (getNSObjects $vserverConfig "appqoe policy" "-policyName")
        addNSObject "ipset" (getNSObjects $vserverConfig "ipset" "-ipset")
        addNSObject "analytics profile" (getNSObjects $vserverConfig "analytics profile" "-analyticsProfile")
    }
}


# Get CSW Policies from CSW Policy Labels
if ($NSObjects."cs policylabel") {
    foreach ($policy in $NSObjects."cs policylabel") {
        addNSObject "cs policy" (getNSObjects ($config -match " $policy ") "cs policy")
    }
}


# Get CSW Actions from CSW Policies
if ($NSObjects."cs policy") {
    foreach ($policy in $NSObjects."cs policy") {
        addNSObject "cs action" (getNSObjects ($config -match " $policy ") "cs action")
        addNSObject "audit messageaction" (getNSObjects ($config -match "cr policy $policy") "audit messageaction" "-logAction")

    }
    # Get vServers linked to CSW Actions
    if ($NSObjects."cs action") {
        foreach ($action in $NSObjects."cs action") {
            addNSObject "lb vserver" (getNSObjects ($config -match " $action ") "lb vserver" "-targetLBVserver")
            addNSObject "vpn vserver" (getNSObjects ($config -match " $action ") "vpn vserver" "-targetVserver")
            addNSObject "authentication vserver" (getNSObjects ($config -match " $action ") "authentication vserver" "-targetVserver")
            addNSObject "gslb vserver" (getNSObjects ($config -match " $action ") "gslb vserver" "-targetVserver")
        }
    }
}


# Look for Backup CR vServers
if ($nsObjects."cr vserver") {
    foreach ($crvserver in $nsObjects."cr vserver") {
        $currentVServers = $nsObjects."cr vserver"
        $nsObjects."cr vserver" = @()   
        $vserverConfig = $config -match " $crvserver "
        # Backup VServers should be created before Active VServers
        $backupVServers = getNSObjects ($vserverConfig) "cr vserver" "-backupVServer"
        if ($backupVServers) {
            addNSObject "cr vserver" ($backupVServers)
            foreach ($vserver in $currentvservers) {
                if ($backupVServers -notcontains $vserver) {
                    addNSObject "cr vserver" ($vserver)
                }
            }
        } else {
            $nsObjects."cr vserver" = $currentVServers
        }
    }
}


# Enumerate CR vServer config for additional bound objects
if ($nsObjects."cr vserver") {
    foreach ($crvserver in $nsObjects."cr vserver") {
        $vserverConfig = $config -match " $crvserver "
        addNSObject "cs policy" (getNSObjects $vserverConfig "cs policy")
        addNSObject "cs policylabel" (getNSObjects $vserverConfig "cs policylabel" "policylabel")
        addNSObject "cr policy" (getNSObjects $vserverConfig "cr policy")
        addNSObject "lb vserver" (getNSObjects $vserverConfig "lb vserver" "-lbvserver")
        addNSObject "lb vserver" (getNSObjects $vserverConfig "lb vserver" "-dnsVserverName")
        addNSObject "netProfile" (getNSObjects $vserverConfig "netProfile" "-netProfile")
        addNSObject "ns trafficDomain" (getNSObjects $vserverConfig "ns trafficDomain" "-td")
        addNSObject "ns tcpProfile" (getNSObjects $vserverConfig "ns tcpProfile" "-tcpProfileName")
        addNSObject "ns httpProfile" (getNSObjects $vserverConfig "ns httpProfile" "-httpProfileName")
        addNSObject "ssl policy" (getNSObjects $vserverConfig "ssl policy" "-policyName")
        addNSObject "ssl cipher" (getNSObjects $vserverConfig "ssl cipher")
        addNSObject "ssl profile" (getNSObjects $vserverConfig "ssl profile")
        addNSObject "ssl certKey" (getNSObjects $vserverConfig "ssl certKey" "-certKeyName")
        addNSObject "ssl vserver" (getNSObjects ($config -match "ssl vserver $crvserver ") "ssl vserver")
        addNSObject "cmp policy" (getNSObjects $vserverConfig "cmp policy" "-policyName")
        addNSObject "cmp policylabel" (getNSObjects $vserverConfig "cmp policylabel" "policylabel")
        addNSObject "responder policy" (getNSObjects $vserverConfig "responder policy" "-policyName")
        addNSObject "responder policylabel" (getNSObjects $vserverConfig "responder policylabel" "policylabel")
        addNSObject "rewrite policy" (getNSObjects $vserverConfig "rewrite policy" "-policyName")
        addNSObject "rewrite policylabel" (getNSObjects $vserverConfig "rewrite policylabel" "policylabel")
        addNSObject "appflow policy" (getNSObjects $vserverConfig "appflow policy" "-policyName")
        addNSObject "appflow policylabel" (getNSObjects $vserverConfig "appflow policylabel" "policylabel")
        addNSObject "appfw policy" (getNSObjects $vserverConfig "appfw policy" "-policyName")
        addNSObject "appfw policylabel" (getNSObjects $vserverConfig "appfw policylabel" "policylabel")
        addNSObject "cache policy" (getNSObjects $vserverConfig "cache policy" "-policyName")
        addNSObject "cache policylabel" (getNSObjects $vserverConfig "cache policylabel" "policylabel")
        addNSObject "feo policy" (getNSObjects $vserverConfig "feo policy" "-policyName")
        addNSObject "spillover policy" (getNSObjects $vserverConfig "spillover policy" "-policyName")
        addNSObject "appqoe policy" (getNSObjects $vserverConfig "appqoe policy" "-policyName")
        addNSObject "ica policy" (getNSObjects $vserverConfig "ica policy" "-policyName")
        addNSObject "ipset" (getNSObjects $vserverConfig "ipset" "-ipset")
        addNSObject "analytics profile" (getNSObjects $vserverConfig "analytics profile" "-analyticsProfile")
    }
}


# Get Message Actions from CR Policies
if ($NSObjects."cr policy") {
    foreach ($policy in $NSObjects."cr policy") {
        addNSObject "audit messageaction" (getNSObjects ($config -match "cr policy $policy") "audit messageaction" "-logAction")
    }
}


# Get CSW Policies from CSW Policy Labels
if ($NSObjects."cs policylabel") {
    foreach ($policy in $NSObjects."cs policylabel") {
        addNSObject "cs policy" (getNSObjects ($config -match " $policy ") "cs policy")
    }
}


# Get CSW Actions from CSW Policies
if ($NSObjects."cs policy") {
    foreach ($policy in $NSObjects."cs policy") {
        addNSObject "cs action" (getNSObjects ($config -match " $policy ") "cs action")
        addNSObject "audit messageaction" (getNSObjects ($config -match "cr policy $policy") "audit messageaction" "-logAction")

    }
    # Get vServers linked to CSW Actions
    if ($NSObjects."cs action") {
        foreach ($action in $NSObjects."cs action") {
            addNSObject "lb vserver" (getNSObjects ($config -match " $action ") "lb vserver" "-targetLBVserver")
            addNSObject "vpn vserver" (getNSObjects ($config -match " $action ") "vpn vserver" "-targetVserver")
            addNSObject "gslb vserver" (getNSObjects ($config -match " $action ") "gslb vserver" "-targetVserver")
        }
    }
}


# Look for Backup GSLB vServers
if ($nsObjects."gslb vserver") {
    foreach ($gslbvserver in $nsObjects."gslb vserver") {
        $currentVServers = $nsObjects."gslb vserver"
        $nsObjects."gslb vserver" = @()   
        $vserverConfig = $config -match " $gslbvserver "
        # Backup VServers should be created before Active VServers
        $backupVServers = getNSObjects ($vserverConfig) "gslb vserver" "-backupVServer"
        if ($backupVServers) {
            addNSObject "gslb vserver" ($backupVServers)
            foreach ($vserver in $currentvservers) {
                if ($backupVServers -notcontains $vserver) {
                    addNSObject "gslb vserver" ($vserver)
                }
            }
        } else {
            $nsObjects."gslb vserver" = $currentVServers
        }
    }
}


# Enumerate GSLB vServer config for additional bound objects
if ($nsObjects."gslb vserver") {
    if ($config -match "enable ns feature.* GSLB") {
        $NSObjects."gslb parameter" = @("enable ns feature gslb")
    } else {
        $NSObjects."gslb parameter" = @("# *** GSLB feature is not enabled")
    }
    foreach ($gslbvserver in $nsObjects."gslb vserver") {
        $vserverConfig = $config -match " $gslbvserver "
        addNSObject "gslb service" (getNSObjects $vserverConfig "gslb service" "-serviceName")
        addNSObject "ssl vserver" (getNSObjects ($config -match "ssl vserver $gslbvserver ") "ssl vserver")
        addNSObject "dns soaRec" (getNSObjects $vserverConfig "dns soaRec")
        addNSObject "dns nsRec" (getNSObjects $vserverConfig "dns nsRec")
    }

    if ($NSObjects."gslb service")
    {
        foreach ($service in $NSObjects."gslb service") 
        { 
            # wrap config matches in spaces to avoid substring matches
            $serviceConfig = $config -match " gslb service $service "
            addNSObject "monitor" (getNSObjects $serviceConfig "lb monitor" "-monitorName")
            addNSObject "server" (getNSObjects $serviceConfig "server")
            addNSObject "ssl profile" (getNSObjects $serviceConfig "ssl profile")
            addNSObject "netProfile" (getNSObjects $serviceConfig "netProfile" "-netProfile")
            addNSObject "ns trafficDomain" (getNSObjects $serviceConfig "ns trafficDomain" "-td")
            addNSObject "dns view" (getNSObjects $serviceConfig "dns view" "-viewName")
            addNSObject "gslb site" (getNSObjects $serviceConfig "gslb site" "-siteName")
        }
    }
    
    if ($NSObjects."gslb site")
    {
        foreach ($site in $NSObjects."gslb site") 
        { 
            $siteConfig = $config -match "add gslb site $site "
            addNSObject "ns rpcNode" (getNSObjects $siteConfig "ns rpcNode")
        }
    }
     
    addNSObject "dns cnameRec" (getNSObjects ($config -match "^add dns cnameRec ") "dns cnameRec")
    addNSObject "dns addRec" (getNSObjects ($config | select-string -Pattern "^add dns addRec" | select-string -NotMatch -Pattern ".root-servers.net") "dns addRec")
    addNSObject "gslb location" ($config -match "^set locationParameter") "gslb location"
    addNSObject "gslb location" ($config -match " locationFile ") "gslb location"
    addNSObject "gslb location" ($config -match "^add location ") "gslb location"
    addNSObject "gslb parameter" ($config -match "^set gslb parameter ") "gslb parameter"
    addNSObject "gslb parameter" ($config -match "^set dns parameter") "gslb parameter"
    # Get all global DNS Responder policies in case they affect GSLB DNS traffic
    addNSObject "responder policy" (getNSObjects ($config -match "^bind responder global .*? -type DNS_REQ_") "responder policy")
    # Get all global DNS Policy bindings in case they affect ADNS traffic?
    addNSObject "dns policy" (getNSObjects ($config -match "^bind dns global") "dns policy")
    addNSObject "adns service" ($config -match '^add service (".*?"|[^-"]\S+) \d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3} ADNS') "adns service"
    # Get all DNS LB vServers in case they are used for DNS Queries?
    addNSObject "lb vserver" (getNSObjects ($config -match '^add lb vserver (".*?"|[^-"]\S+) DNS') "lb vserver")
}


# Get DNS Actions and DNS Polices from DNS Views
if ($nsObjects."dns view") {
    foreach ($view in $nsObjects."dns view") {
        addNSObject "dns action" (getNSObjects ($config -match "dns action .*? -viewName $view") "dns action")
    }
    foreach ($action in $nsObjects."dns action") {
        addNSObject "dns policy" (getNSObjects ($config -match "dns policy .*? $action") "dns policy" )
    }
}


if ($nsObjects."dns policy") {
    # Get DNS Actions for global DNS policies discovered earlier
    foreach ($policy in $nsObjects."dns policy") {
        addNSObject "dns action" (getNSObjects ($config -match "dns policy $policy") "dns action")
        addNSObject "audit messageaction" (getNSObjects ($config -match "dns policy $policy") "audit messageaction" "-logAction")
    }
    # Get DNS Profiles linked to DNS Actions
    foreach ($action in $nsObjects."dns action") {
        addNSObject "dns profile" (getNSObjects ($config -match "dns action $action") "dns profile" "-dnsProfileName" )
    }
    # Get DNS Views linked to DNS Actions
    foreach ($action in $nsObjects."dns action") {
        addNSObject "dns view" (getNSObjects ($config -match "dns action $action") "dns view" "-viewName" )
    }
    addNSObject "dns global" ($config -match "bind dns global ") "dns global"
}



# Enumerate VPN vServer config for additional bound objects
if ($nsObjects."vpn vserver") {
    if ($config -match "enable ns feature.* SSLVPN") {
        $NSObjects."vpn parameter" = @("enable ns feature SSLVPN")
    } else {
        $NSObjects."vpn parameter" = @("# *** Citrix Gateway feature is not enabled")
    }
    addNSObject "vpn parameter" ($config -match "vpn parameter") "vpn parameter"
    addNSObject "vpn parameter" ($config -match "ica parameter") "vpn parameter"
    addNSObject "vpn parameter" ($config -match "aaa parameter") "vpn parameter"
    addNSObject "vpn parameter" ($config -match "dns suffix") "vpn parameter"
    addNSObject "clientless domains" ($config -match "ns_cvpn_default_inet_domains") "clientless domains"
    foreach ($vpnvserver in $nsObjects."vpn vserver") {
        $vserverConfig = $config -match " $vpnvserver "
        addNSObject "cs policylabel" (getNSObjects $vserverConfig "cs policylabel")
        addNSObject "cs policy" (getNSObjects $vserverConfig "cs policy")
        addNSObject "ns tcpProfile" (getNSObjects $vserverConfig "ns tcpProfile")
        addNSObject "netProfile" (getNSObjects $vserverConfig "netProfile" "-netProfile")
        addNSObject "ns httpProfile" (getNSObjects $vserverConfig "ns httpProfile" "-httpProfileName")
        addNSObject "ns trafficDomain" (getNSObjects $vserverConfig "ns trafficDomain" "-td")
        addNSObject "authentication authnProfile" (getNSObjects $vserverConfig "authentication authnProfile" "-authnProfile")
        addNSObject "vpn pcoipVserverProfile" (getNSObjects $vserverConfig "vpn pcoipVserverProfile" "-pcoipVserverProfileName")
        addNSObject "vpn intranetApplication" (getNSObjects $vserverConfig "vpn intranetApplication" "-intranetApplication")
        addNSObject "vpn portaltheme" (getNSObjects $vserverConfig "vpn portaltheme" "-portaltheme")
        addNSObject "vpn eula" (getNSObjects $vserverConfig "vpn eula" "-eula")
        addNSObject "vpn nextHopServer" (getNSObjects $vserverConfig "vpn nextHopServer" "-nextHopServer")
        addNSObject "authentication ldapPolicy" (getNSObjects $vserverConfig "authentication ldapPolicy" "-policy")
        addNSObject "authentication radiusPolicy" (getNSObjects $vserverConfig "authentication radiusPolicy" "-policy")
        addNSObject "authentication samlIdPPolicy" (getNSObjects $vserverConfig "authentication samlIdPPolicy")
        addNSObject "authentication samlPolicy" (getNSObjects $vserverConfig "authentication samlPolicy")
        addNSObject "authentication certPolicy" (getNSObjects $vserverConfig "authentication certPolicy")
        addNSObject "authentication dfaPolicy" (getNSObjects $vserverConfig "authentication dfaPolicy")
        addNSObject "authentication localPolicy" (getNSObjects $vserverConfig "authentication localPolicy")
        addNSObject "authentication negotiatePolicy" (getNSObjects $vserverConfig "authentication negotiatePolicy")
        addNSObject "authentication tacacsPolicy" (getNSObjects $vserverConfig "authentication tacacsPolicy")
        addNSObject "authentication webAuthPolicy" (getNSObjects $vserverConfig "authentication webAuthPolicy")
        addNSObject "aaa preauthenticationpolicy" (getNSObjects $vserverConfig "aaa preauthenticationpolicy" "-policy")
        addNSObject "vpn sessionPolicy" (getNSObjects $vserverConfig "vpn sessionPolicy" "-policy")
        addNSObject "vpn trafficPolicy" (getNSObjects $vserverConfig "vpn trafficPolicy" "-policy")
        addNSObject "vpn clientlessAccessPolicy" (getNSObjects $vserverConfig "vpn clientlessAccessPolicy" "-policy")
        addNSObject "authorization policylabel" (getNSObjects $vserverConfig "authorization policylabel")
        addNSObject "authorization policy" (getNSObjects $vserverConfig "authorization policy" "-policy")
        addNSObject "responder policy" (getNSObjects $vserverConfig "responder policy" "-policy")
        addNSObject "responder policylabel" (getNSObjects $vserverConfig "responder policylabel" "policylabel")
        addNSObject "rewrite policy" (getNSObjects $vserverConfig "rewrite policy" "-policy")
        addNSObject "rewrite policylabel" (getNSObjects $vserverConfig "rewrite policylabel" "policylabel")
        addNSObject "appflow policy" (getNSObjects $vserverConfig "appflow policy" "-policy")
        addNSObject "appflow policylabel" (getNSObjects $vserverConfig "appflow policylabel" "policylabel")
        addNSObject "cache policy" (getNSObjects $vserverConfig "cache policy" "-policy")
        addNSObject "cache policylabel" (getNSObjects $vserverConfig "cache policylabel" "policylabel")
        addNSObject "audit syslogPolicy" (getNSObjects $vserverConfig "audit syslogPolicy" "-policy")
        addNSObject "audit nslogPolicy" (getNSObjects $vserverConfig "audit nslogPolicy" "-policy")
        addNSObject "ica policy" (getNSObjects $vserverConfig "ica policy" "-policy")
        addNSObject "ssl policy" (getNSObjects $vserverConfig "ssl policy" "-policy")
        addNSObject "ssl cipher" (getNSObjects $vserverConfig "ssl cipher") 
        addNSObject "ssl profile" (getNSObjects $vserverConfig "ssl profile")
        addNSObject "ssl certKey" (getNSObjects $vserverConfig "ssl certKey" "-certkeyName")
        addNSObject "ssl vserver" (getNSObjects ($config -match "ssl vserver $vpnvserver ") "ssl vserver")
        addNSObject "vpn url" (getNSObjects $vserverConfig "vpn url" "-urlName")
        addNSObject "ipset" (getNSObjects $vserverConfig "ipset" "-ipset")
        addNSObject "analytics profile" (getNSObjects $vserverConfig "analytics profile" "-analyticsProfile")
    }
    addNSObject "aaa group" (getNSObjects ($config -match "add aaa group") "aaa group")
    addNSObject "vpn global" ($config -match "bind vpn global ") "vpn global"
}


# Get CSW Policies from CSW Policy Labels
if ($NSObjects."cs policylabel") {
    foreach ($policy in $NSObjects."cs policylabel") {
        addNSObject "cs policy" (getNSObjects ($config -match " $policy ") "cs policy")
    }
}


# Get CSW Actions from CSW Policies
if ($NSObjects."cs policy") {
    foreach ($policy in $NSObjects."cs policy") {
        addNSObject "cs action" (getNSObjects ($config -match " $policy ") "cs action")
        addNSObject "audit messageaction" (getNSObjects ($config -match "cr policy $policy") "audit messageaction" "-logAction")

    }
    # Get vServers linked to CSW Actions
    if ($NSObjects."cs action") {
        foreach ($action in $NSObjects."cs action") {
            addNSObject "lb vserver" (getNSObjects ($config -match " $action ") "lb vserver" "-targetLBVserver")
            addNSObject "vpn vserver" (getNSObjects ($config -match " $action ") "vpn vserver" "-targetVserver")
            addNSObject "gslb vserver" (getNSObjects ($config -match " $action ") "gslb vserver" "-targetVserver")
        }
    }
}


# Get objects bound to VPN Global
if ($nsObjects."vpn global") {
    $vserverConfig = $config -match "bind vpn global "
    addNSObject "vpn intranetApplication" (getNSObjects $vserverConfig "vpn intranetApplication" "-intranetApplication")
    addNSObject "vpn portaltheme" (getNSObjects $vserverConfig "vpn portaltheme" "-portaltheme")
    addNSObject "vpn eula" (getNSObjects $vserverConfig "vpn eula" "-eula")
    addNSObject "vpn nextHopServer" (getNSObjects $vserverConfig "vpn nextHopServer" "-nextHopServer")
    addNSObject "authentication ldapPolicy" (getNSObjects $vserverConfig "authentication ldapPolicy" "-policyName")
    addNSObject "authentication radiusPolicy" (getNSObjects $vserverConfig "authentication radiusPolicy" "-policyName")
    addNSObject "authentication samlIdPPolicy" (getNSObjects $vserverConfig "authentication samlIdPPolicy")
    addNSObject "authentication samlPolicy" (getNSObjects $vserverConfig "authentication samlPolicy")
    addNSObject "authentication certPolicy" (getNSObjects $vserverConfig "authentication certPolicy")
    addNSObject "authentication dfaPolicy" (getNSObjects $vserverConfig "authentication dfaPolicy")
    addNSObject "authentication localPolicy" (getNSObjects $vserverConfig "authentication localPolicy")
    addNSObject "authentication negotiatePolicy" (getNSObjects $vserverConfig "authentication negotiatePolicy")
    addNSObject "authentication tacacsPolicy" (getNSObjects $vserverConfig "authentication tacacsPolicy")
    addNSObject "authentication webAuthPolicy" (getNSObjects $vserverConfig "authentication webAuthPolicy")
    addNSObject "vpn sessionPolicy" (getNSObjects $vserverConfig "vpn sessionPolicy" "-policyName")
    addNSObject "vpn trafficPolicy" (getNSObjects $vserverConfig "vpn trafficPolicy" "-policyName")
    addNSObject "vpn clientlessAccessPolicy" (getNSObjects $vserverConfig "vpn clientlessAccessPolicy" "-policyName")
    addNSObject "authorization policylabel" (getNSObjects $vserverConfig "authorization policylabel" "policylabel")
    addNSObject "authorization policy" (getNSObjects $vserverConfig "authorization policy" "-policyName")
    addNSObject "responder policy" (getNSObjects $vserverConfig "responder policy" "-policyName")
    addNSObject "responder policylabel" (getNSObjects $vserverConfig "responder policylabel" "policylabel")
    addNSObject "rewrite policy" (getNSObjects $vserverConfig "rewrite policy" "-policyName")
    addNSObject "rewrite policylabel" (getNSObjects $vserverConfig "rewrite policylabel" "policylabel")
    addNSObject "cache policy" (getNSObjects $vserverConfig "cache policy" "-policyName")
    addNSObject "cache policylabel" (getNSObjects $vserverConfig "cache policylabel" "policylabel")
    addNSObject "audit syslogPolicy" (getNSObjects $vserverConfig "audit syslogPolicy" "-policyName")
    addNSObject "audit nslogPolicy" (getNSObjects $vserverConfig "audit nslogPolicy" "-policyName")
    addNSObject "ica policy" (getNSObjects $vserverConfig "ica policy" "-policyName")
    addNSObject "ssl policy" (getNSObjects $vserverConfig "ssl policy" "-policyName")
    addNSObject "vpn url" (getNSObjects $vserverConfig "vpn url" "-urlName")
    addNSObject "ssl certKey" (getNSObjects $vserverConfig "ssl certKey" "-certkeyName")
    addNSObject "ssl certKey" (getNSObjects $vserverConfig "ssl certKey" "-cacert")
    
    $vserverConfig = $config -match "set vpn parameter "
    addNSObject "lb vserver" (getNSObjects $vserverConfig "lb vserver" "-dnsVserverName")
    addNSObject "vpn alwaysONProfile" (getNSObjects $vserverConfig "vpn alwaysONProfile" "-alwaysONProfileName")
    addNSObject "aaa kcdAccount" (getNSObjects $vserverConfig "aaa kcdAccount" "-kcdAccount")
    addNSObject "vpn pcoipProfile" (getNSObjects $vserverConfig "vpn pcoipProfile" "-pcoipProfileName")
    addNSObject "rdp clientprofile" (getNSObjects $vserverConfig "rdp clientprofile" "-rdpClientProfileName")
}


# Look for LB Persistency Groups
if ($nsObjects."lb vserver") {
    foreach ($lbvserver in $nsObjects."lb vserver") {
        $vserverConfig = $config -match " $lbvserver$"
        addNSObject "lb group" (getNSObjects ($vserverConfig) "lb group")
        if ($nsObjects."lb group") {
            foreach ($lbgroup in $NSObjects."lb group") { 
                addNSObject "lb vserver" (getNSObjects ($config -match "lb group " + $lbgroup) "lb vserver")
            }
        }
    }
}


# Look for Backup LB vServers
if ($nsObjects."lb vserver") {
    foreach ($lbvserver in $nsObjects."lb vserver") {
        $currentVServers = $nsObjects."lb vserver"
        $nsObjects."lb vserver" = @()   
        $vserverConfig = $config -match " $lbvserver "
        # Backup VServers should be created before Active VServers
        $backupVServers = getNSObjects ($vserverConfig) "lb vserver" "-backupVServer"
        if ($backupVServers) {
            addNSObject "lb vserver" ($backupVServers)
            foreach ($vserver in $currentvservers) {
                if ($backupVServers -notcontains $vserver) {
                    addNSObject "lb vserver" ($vserver)
                }
            }
        } else {
            $nsObjects."lb vserver" = $currentVServers
        }
    }
}


# Get objects linked to AAA Groups
if ($nsObjects."aaa group") {
    foreach ($group in $nsObjects."aaa group") {
        $groupConfig = $config -match " aaa group $group "
        addNSObject "vpn intranetApplication" (getNSObjects $groupConfig "vpn intranetApplication" "-intranetApplication")
        addNSObject "vpn sessionPolicy" (getNSObjects $groupConfig "vpn sessionPolicy" "-policy")
        addNSObject "vpn trafficPolicy" (getNSObjects $groupConfig "vpn trafficPolicy" "-policy")
        addNSObject "authorization policylabel" (getNSObjects $vserverConfig "authorization policylabel")
        addNSObject "authorization policy" (getNSObjects $groupConfig "authorization policy" "-policy")
        addNSObject "vpn url" (getNSObjects $groupConfig "vpn url" "-urlName")
    }
}


# Get Preauthentication Actions from Preauthentication Policies
if ($NSObjects."aaa preauthenticationpolicy") {
    foreach ($policy in $NSObjects."aaa preauthenticationpolicy") {
        addNSObject "aaa preauthenticationaction" (getNSObjects ($config -match "aaa preauthenticationpolicy $policy ") "aaa preauthenticationaction" -position 4)
    }
}


# Get VPN Session Actions from VPN Session Policies
if ($NSObjects."vpn sessionPolicy") {
    foreach ($policy in $NSObjects."vpn sessionPolicy") {
        addNSObject "vpn sessionAction" (getNSObjects ($config -match "vpn sessionPolicy $policy ") "vpn sessionAction" -position 4)
    }
}


# Get KCD Accounts and DNS LB vServers from VPN Session Actions
if ($NSObjects."vpn sessionAction") {
    foreach ($profile in $NSObjects."vpn sessionAction") 
    {
        $profileConfig = $config -match "vpn sessionAction $profile "
        addNSObject "aaa kcdAccount" (getNSObjects $profileConfig "aaa kcdAccount" "-kcdAccount")
        addNSObject "lb vserver" (getNSObjects $profileConfig "lb vserver" "-dnsVserverName")
        if ($profileConfig -match "http://" -or $profileConfig -match "https://")
        {
            addNSObject "lb vserver" (getHttpVServer $profileConfig)            
        }
    }
}


# Enumerate LB vServer config for additional bound objects
if ($nsObjects."lb vserver" -or $nsObjects."sys") {
    if ($config -match "enable ns feature.* lb") {
        $NSObjects."lb parameter" = @("enable ns feature lb")
    } else {
        $NSObjects."lb parameter" = @("# *** Load Balancing feature is not enabled")
    }
    addNSObject "lb parameter" ($config -match "ns mode") "lb parameter"
    addNSObject "lb parameter" ($config -match "set lb parameter") "lb parameter"
    addNSObject "lb parameter" ($config -match "set ns param") "lb parameter"
    addNSObject "lb parameter" ($config -match "set dns parameter") "lb parameter"
    addNSObject "lb parameter" ($config -match "set dns profile default-dns-profile") "lb parameter"
    addNSObject "lb parameter" ($config -match "set ns tcpParam") "lb parameter"
    addNSObject "lb parameter" ($config -match "set ns tcpProfile nstcp_default") "lb parameter"
    addNSObject "lb parameter" ($config -match "set ns httpParam") "lb parameter"
    addNSObject "lb parameter" ($config -match "set ns tcpbufParam") "lb parameter"
    addNSObject "lb parameter" ($config -match "set ns timeout") "lb parameter"
    GetLBvServerBindings $NSObjects."lb vserver"
}


# Get AAA VServers linked to Authentication Profiles
if ($NSObjects."authentication authnProfile") {
    foreach ($profile in $NSObjects."authentication authnProfile") {
        addNSObject "authentication vserver" (getNSObjects ($config -match "authentication authnProfile $profile ") "authentication vserver" "-authnVsName")
    }
}


# Get Objects linked to Authentication vServers
if ($NSObjects."authentication vserver") {
    if ($config -match "enable ns feature.* rewrite") {
        $NSObjects."authentication param" = @("enable ns feature AAA")
    } else {
        $NSObjects."authentication param" = @("# *** AAA feature is not enabled")
    }
    foreach ($authVServer in $NSObjects."authentication vserver") {
        $vserverConfig = $config -match " $authVServer "
        addNSObject "ns trafficDomain" (getNSObjects $vserverConfig "ns trafficDomain" "-td")
        addNSObject "authentication ldapPolicy" (getNSObjects $vserverConfig "authentication ldapPolicy")
        addNSObject "authentication radiusPolicy" (getNSObjects $vserverConfig "authentication radiusPolicy")
        addNSObject "authentication policy" (getNSObjects $vserverConfig "authentication policy")
        addNSObject "authentication samlIdPPolicy" (getNSObjects $vserverConfig "authentication samlIdPPolicy")
        addNSObject "authentication samlPolicy" (getNSObjects $vserverConfig "authentication samlPolicy")
        addNSObject "authentication certPolicy" (getNSObjects $vserverConfig "authentication certPolicy")
        addNSObject "authentication dfaPolicy" (getNSObjects $vserverConfig "authentication dfaPolicy")
        addNSObject "authentication localPolicy" (getNSObjects $vserverConfig "authentication localPolicy")
        addNSObject "authentication negotiatePolicy" (getNSObjects $vserverConfig "authentication negotiatePolicy")
        addNSObject "authentication tacacsPolicy" (getNSObjects $vserverConfig "authentication tacacsPolicy")
        addNSObject "authentication webAuthPolicy" (getNSObjects $vserverConfig "authentication webAuthPolicy")
        addNSObject "tm sessionPolicy" (getNSObjects $vserverConfig "tm sessionPolicy")
        addNSObject "vpn portaltheme" (getNSObjects $vserverConfig "vpn portaltheme" "-portaltheme")
        addNSObject "authentication loginSchemaPolicy" (getNSObjects $vserverConfig "authentication loginSchemaPolicy")
        addNSObject "authentication policylabel" (getNSObjects $vserverConfig "authentication policylabel" "-nextFactor")
        addNSObject "audit syslogPolicy" (getNSObjects $vserverConfig "audit syslogPolicy" "-policy")
        addNSObject "audit nslogPolicy" (getNSObjects $vserverConfig "audit nslogPolicy" "-policy")
        addNSObject "cs policy" (getNSObjects $vserverConfig "cs policy" "-policy")
        addNSObject "ssl policy" (getNSObjects $vserverConfig "ssl policy" "-policy")
        addNSObject "ssl cipher" (getNSObjects $vserverConfig "ssl cipher" "-cipherName")
        addNSObject "ssl profile" (getNSObjects $vserverConfig "ssl profile")
        addNSObject "ssl certKey" (getNSObjects $vserverConfig "ssl certKey" "-certkeyName")
        addNSObject "ssl certKey" (getNSObjects $vserverConfig "ssl certKey" "-cacert")
        addNSObject "ssl vserver" (getNSObjects ($config -match "ssl vserver $authVServer ") "ssl vserver")
    }
}


# Get CSW Actions from CSW Policies
if ($NSObjects."cs policy") {
    foreach ($policy in $NSObjects."cs policy") {
        addNSObject "cs action" (getNSObjects ($config -match " $policy ") "cs action")
        addNSObject "audit messageaction" (getNSObjects ($config -match "cr policy $policy") "audit messageaction" "-logAction")

    }
    # Get vServers linked to CSW Actions
    if ($NSObjects."cs action") {
        foreach ($action in $NSObjects."cs action") {
            addNSObject "lb vserver" (getNSObjects ($config -match " $action ") "lb vserver" "-targetLBVserver")
            addNSObject "vpn vserver" (getNSObjects ($config -match " $action ") "vpn vserver" "-targetVserver")
            addNSObject "gslb vserver" (getNSObjects ($config -match " $action ") "gslb vserver" "-targetVserver")
        }
    }
}


# Get SSL Objects from SSL vServers
if ($NSObjects."ssl vserver") {
    foreach ($vserver in $NSObjects."ssl vserver") {
        addNSObject "ssl cipher" (getNSObjects ($config -match " ssl vserver $vserver ") "ssl cipher" "-cipherName")
        addNSObject "ssl certKey" (getNSObjects ($config -match " ssl vserver $vserver ") "ssl certKey" "-certkeyName")
        addNSObject "ssl certKey" (getNSObjects ($config -match " ssl vserver $vserver ") "ssl certKey" "-cacert")
        addNSObject "ssl logprofile" (getNSObjects ($config -match " ssl vserver $vserver ") "ssl logprofile" "-ssllogprofile")
        addNSObject "ssl profile" (getNSObjects ($config -match " ssl vserver $vserver ") "ssl profile" "-sslProfile")
    }
}



# Get Next Factors, Authentication Policies and Login Schemas from Authentication Policy Labels
if ($NSObjects."authentication policylabel") {
    # Get Next Factors; repeat multiple times for Next Factor nesting level
    for ($i=0;$i -le $nFactorNestingLevel; $i++) {
        foreach ($policy in $NSObjects."authentication policylabel") {
            addNSObject "authentication policylabel" (getNSObjects ($config -match " $policy ") "authentication policylabel" "-nextFactor")
        }
    }

    foreach ($policy in $NSObjects."authentication policylabel") {
        addNSObject "authentication policy" (getNSObjects ($config -match " $policy ") "authentication policy")
        addNSObject "authentication loginSchema" (getNSObjects ($config -match " $policy ") "authentication loginSchema")
    }
}


# Sort the Policy Labels so Next Factors are created prior to policy bindings in earlier factors
if ($NSObjects."authentication policylabel") {
    $policyLabelsSorted = @()
    foreach ($policyLabel in $NSObjects."authentication policylabel") {
        $policyBindings = $config -match ('^bind authentication policylabel ' + $policyLabel + " -(policy|policyName) ")
        $nextFactors = $policyBindings | select-string -Pattern ('-nextFactor (".*?"|[^-"]\S+)') | ForEach-Object {$_.Matches.Groups[1].value}
        if (-not $nextFactors) {
            $policyLabelsSorted = ,$policyLabel + $policyLabelsSorted
        } else {
            foreach ($nextFactor in $nextFactors) {
                if ($policyLabelsSorted -contains $nextFactor) {
                    $policyLabelsSorted = $policyLabelsSorted + ,$policyLabel
                }
            }
        }
    }
    for ($i=0; $i -lt $nFactorNestingLevel; $i++) {
        foreach ($policyLabel in $NSObjects."authentication policylabel") {
            $policyBindings = $config -match ('^bind authentication policylabel ' + $policyLabel + " -(policy|policyName) ")
            $nextFactors = $policyBindings | select-string -Pattern ('-nextFactor (".*?"|[^-"]\S+)') | ForEach-Object {$_.Matches.Groups[1].value}
            foreach ($nextFactor in $nextFactors) {
                if ($policyLabelsSorted -contains $nextFactor) {
                    $policyLabelsSorted = $policyLabelsSorted + ,$policyLabel
                }
            }
        }
    }
    $NSObjects."authentication policylabel" = $policyLabelsSorted
}


# Get Authentication Actions from Advanced Authentication Policies
if ($NSObjects."authentication policy") {
    foreach ($policy in $NSObjects."authentication policy") {
        addNSObject "authentication ldapAction" (getNSObjects ($config -match "authentication policy $policy ") "authentication ldapAction")
        addNSObject "audit messageaction" (getNSObjects ($config -match "authentication policy $policy") "audit messageaction" "-logAction")
        addNSObject "authentication radiusAction" (getNSObjects ($config -match "authentication policy $policy ") "authentication radiusAction")
        addNSObject "authentication samlAction" (getNSObjects ($config -match "authentication policy $policy ") "authentication samlAction" -position 4)
        addNSObject "authentication certAction" (getNSObjects ($config -match "authentication policy $policy ") "authentication certAction")
        addNSObject "authentication dfaAction" (getNSObjects ($config -match "authentication policy $policy ") "authentication dfaAction")
        addNSObject "authentication epaAction" (getNSObjects ($config -match "authentication policy $policy ") "authentication epaAction")
        addNSObject "authentication negotiateAction" (getNSObjects ($config -match "authentication policy $policy ") "authentication negotiateAction")
        addNSObject "authentication OAuthAction" (getNSObjects ($config -match "authentication policy $policy ") "authentication OAuthAction")
        addNSObject "authentication storefrontAuthAction" (getNSObjects ($config -match "authentication policy $policy ") "authentication storefrontAuthAction")
        addNSObject "authentication tacacsAction" (getNSObjects ($config -match "authentication policy $policy ") "authentication tacacsAction")
        addNSObject "authentication webAuthAction" (getNSObjects ($config -match "authentication policy $policy ") "authentication webAuthAction")
        addNSObject "authentication emailAction" (getNSObjects ($config -match "authentication policy $policy ") "authentication emailAction")
        addNSObject "authentication noAuthAction" (getNSObjects ($config -match "authentication policy $policy ") "authentication noAuthAction")
        addNSObject "authentication captchaAction" (getNSObjects ($config -match "authentication policy $policy ") "authentication captchaAction")
    }
}


# Get LDAP Actions from LDAP Policies
if ($NSObjects."authentication ldapPolicy") {
    foreach ($policy in $NSObjects."authentication ldapPolicy") {
        addNSObject "authentication ldapAction" (getNSObjects ($config -match "authentication ldapPolicy $policy ") "authentication ldapAction")
    }
}


# Get RADIUS Actions from RADIUS Policies
if ($NSObjects."authentication radiusPolicy") {
    foreach ($policy in $NSObjects."authentication radiusPolicy") {
        addNSObject "authentication radiusAction" (getNSObjects ($config -match "authentication radiusPolicy $policy ") "authentication radiusAction" -position 4)
    }
}


# Get Cert Actions from Cert Policies
if ($NSObjects."authentication certPolicy") {
    foreach ($policy in $NSObjects."authentication certPolicy") {
        addNSObject "authentication certAction" (getNSObjects ($config -match "authentication certPolicy $policy ") "authentication certAction" -position 4)
    }
}


# Get DFA Actions from DFA Policies
if ($NSObjects."authentication dfaPolicy") {
    foreach ($policy in $NSObjects."authentication dfaPolicy") {
        addNSObject "authentication dfaAction" (getNSObjects ($config -match "authentication dfaPolicy $policy ") "authentication dfaAction")
    }
}


# Get Negotiate Actions from Negotiate Policies
if ($NSObjects."authentication negotiatePolicy") {
    foreach ($policy in $NSObjects."authentication negotiatePolicy") {
        addNSObject "authentication negotiateAction" (getNSObjects ($config -match "authentication negotiatePolicy $policy ") "authentication negotiateAction")
    }
}


# Get TACACS Actions from TACACS Policies
if ($NSObjects."authentication tacacsPolicy") {
    foreach ($policy in $NSObjects."authentication tacacsPolicy") {
        addNSObject "authentication tacacsAction" (getNSObjects ($config -match "authentication tacacsPolicy $policy ") "authentication tacacsAction")
    }
}


# Get Web Auth Actions from Web Auth Policies
if ($NSObjects."authentication webAuthPolicy") {
    foreach ($policy in $NSObjects."authentication webAuthPolicy") {
        addNSObject "authentication webAuthAction" (getNSObjects ($config -match "authentication webAuthPolicy $policy ") "authentication webAuthAction")
    }
}


# Get SAML iDP Profiles from SAML iDP Policies
if ($NSObjects."authentication samlIdPPolicy") {
    foreach ($policy in $NSObjects."authentication samlIdPPolicy") {
        addNSObject "authentication samlIdPProfile" (getNSObjects ($config -match "authentication samlIdPPolicy $policy ") "authentication samlIdPProfile" -position 4)
        addNSObject "audit messageaction" (getNSObjects ($config -match "authentication samlIdPPolicy $policy") "audit messageaction" "-logAction")
    }
 
}


# Get SAML Actions from SAML Authentication Policies
if ($NSObjects."authentication samlPolicy") {
    foreach ($policy in $NSObjects."authentication samlPolicy") {
        addNSObject "authentication samlAction" (getNSObjects ($config -match "authentication samlPolicy $policy ") "authentication samlAction" -position 4)
    }
}


# Get SSL Certificates from SAML Actions, SAML Profiles, and ADFS Proxy Profiles
foreach ($action in $NSObjects."authentication samlAction") {
    addNSObject "ssl certKey" (getNSObjects ($config -match "authentication samlAction $action ") "ssl certKey" "-samlIdPCertName")
    addNSObject "ssl certKey" (getNSObjects ($config -match "authentication samlAction $action ") "ssl certKey" "-samlSigningCertName")
}

foreach ($action in $NSObjects."authentication samlIdPProfile") {
    addNSObject "ssl certKey" (getNSObjects ($config -match "authentication samlIdPProfile $action ") "ssl certKey" "-samlIdPCertName")
    addNSObject "ssl certKey" (getNSObjects ($config -match "authentication samlIdPProfile $action ") "ssl certKey" "-samlSPCertName")
}

foreach ($action in $NSObjects."authentication adfsProxyProfile") {
    addNSObject "ssl certKey" (getNSObjects ($config -match "authentication adfsProxyProfile $action ") "ssl certKey" "-certKeyName")
}



# Get Push Service from LDAP Actions
foreach ($action in $NSObjects."authentication ldapAction") {
    addNSObject "authentication pushService" (getNSObjects ($config -match "authentication ldapAction $action ") "authentication pushService" "-pushService")
}


# Get Default AAA Groups from Authentication Actions
foreach ($action in $NSObjects."authentication certAction") {
    addNSObject "aaa group" (getNSObjects ($config -match "authentication certAction $action ") "aaa group" "-defaultAuthenticationGroup")
}
foreach ($action in $NSObjects."authentication dfaAction") {
    addNSObject "aaa group" (getNSObjects ($config -match "authentication dfaAction $action ") "aaa group" "-defaultAuthenticationGroup")
}
foreach ($action in $NSObjects."authentication epaAction") {
    addNSObject "aaa group" (getNSObjects ($config -match "authentication epaAction $action ") "aaa group" "-defaultEPAGroup")
    addNSObject "aaa group" (getNSObjects ($config -match "authentication epaAction $action ") "aaa group" "-quarantineGroup")
}
foreach ($action in $NSObjects."authentication ldapAction") {
    addNSObject "aaa group" (getNSObjects ($config -match "authentication ldapAction $action ") "aaa group" "-defaultAuthenticationGroup")
}
foreach ($action in $NSObjects."authentication negotiateAction") {
    addNSObject "aaa group" (getNSObjects ($config -match "authentication negotiateAction $action ") "aaa group" "-defaultAuthenticationGroup")
}
foreach ($action in $NSObjects."authentication OAuthAction") {
    addNSObject "aaa group" (getNSObjects ($config -match "authentication OAuthAction $action ") "aaa group" "-defaultAuthenticationGroup")
}
foreach ($action in $NSObjects."authentication radiusAction") {
    addNSObject "aaa group" (getNSObjects ($config -match "authentication radiusAction $action ") "aaa group" "-defaultAuthenticationGroup")
}
foreach ($action in $NSObjects."authentication samlAction") {
    addNSObject "aaa group" (getNSObjects ($config -match "authentication samlAction $action ") "aaa group" "-defaultAuthenticationGroup")
}
foreach ($action in $NSObjects."authentication webAuthAction") {
    addNSObject "aaa group" (getNSObjects ($config -match "authentication webAuthAction $action ") "aaa group" "-defaultAuthenticationGroup")
}


# Get objects linked to certKeys
if ($NSObjects."ssl certKey") {
    foreach ($certKey in $NSObjects."ssl certKey") {
        # Get FIPS Keys from SSL Certs
        addNSObject "ssl fipsKey" (getNSObjects ($config -match "add ssl certKey $certKey ") "ssl fipsKey" "-fipsKey")
        
        # Get HSM Keys from SSL Certs
        addNSObject "ssl hsmKey" (getNSObjects ($config -match "add ssl certKey $certKey ") "ssl hsmKey" "-hsmKey")
        
        # Put Server Cerficates in different bucket than CA Certificates
        addNSObject "ssl cert" ($config -match "add ssl certKey $certKey") "ssl certKey"
        
        # CA Certs are seperate section so they can be outputted before server certs
        $CACert = getNSObjects ($config -match "link ssl certKey $certKey ") "ssl certKey"
        foreach ($cert in $CACert) { if ($cert -notmatch $certKey) {$CACert = $cert} }
        if ($CACert) {
            addNSObject "ssl cert" ($config -match "add ssl certKey $CACert") "ssl certKey"
            addNSObject "ssl link" ($config -match "link ssl certKey $certKey") "ssl certKey"
            $certKey = $CACert
        }
        
        # Intermediate certs are sometimes linked to other intermediates
        $CACert = getNSObjects ($config -match "link ssl certKey $CACert ") "ssl certKey"
        foreach ($cert in $CACert) { if ($cert -notmatch $certKey) {$CACert = $cert} }
        if ($CACert) {
            addNSObject "ssl cert" ($config -match "add ssl certKey $CACert") "ssl certKey"
            addNSObject "ssl link" ($config -match "link ssl certKey $certKey") "ssl certKey"
            $certKey = $CACert
        }
        
        
        # Intermedicate certs are sometimes linked to root certs
        $CACert = getNSObjects ($config -match "link ssl certKey $CACert ") "ssl certKey"
        foreach ($cert in $CACert) { if ($cert -notmatch $certKey) {$CACert = $cert} }
        if ($CACert) {
            addNSObject "ssl cert" ($config -match "add ssl certKey $CACert") "ssl certKey"
            addNSObject "ssl link" ($config -match "link ssl certKey $certKey") "ssl certKey"
        }
        
    }
}


# Get Azure Key Vaults from HSM Keys
if ($NSObjects."ssl hmsKey") {
    foreach ($hmsKey in $NSObjects."ssl hmsKey") {
        addNSObject "azure keyvault" (getNSObjects ($config -match "add ssl hsmKey $hsmKey ") "azure keyvault" "-keystore")
    }

    # Get callout root certificates
    addNSObject "ssl cert" ($config -match "bind ssl cacertGroup ns_callout_certs ") "ssl certKey"
}


# Get Azure Applications from Azure Key Vaults
if ($NSObjects."azure keyvault") {
    foreach ($vault in $NSObjects."azure keyVault") {
        addNSObject "azure application" (getNSObjects ($config -match "add azure keyVault $vault ") "azure application" "-azureApplication")
    }
}


# Get Objects linked to Monitors
if ($NSObjects.monitor) {
    foreach ($monitor in $NSObjects.monitor) {
        $monitorConfig = $config -match "lb monitor $monitor "
        addNSObject "netProfile" (getNSObjects $monitorConfig "netProfile" "-netProfile")
        addNSObject "ns trafficDomain" (getNSObjects $monitorConfig "ns trafficDomain" "-td")
        addNSObject "aaa kcdAccount" (getNSObjects $monitorConfig "aaa kcdAccount" "-kcdAccount")
        addNSObject "ssl profile" (getNSObjects $monitorConfig "ssl profile" "-sslProfile")
        addNSObject "lb metricTable" (getNSObjects $monitorConfig "lb metricTable" "-metricTable")
    }
}


# Get VPN Clientless Profiles from VPN Clientless Policies
if ($NSObjects."vpn clientlessAccessPolicy") {
    foreach ($policy in $NSObjects."vpn clientlessAccessPolicy") {
        addNSObject "vpn clientlessAccessProfile" (getNSObjects ($config -match " vpn clientlessAccessPolicy $policy ") "vpn clientlessAccessProfile" -position 4)
    }
}


# Get Rewrite PolicyLabels from VPN Clientless Profiles
if ($NSObjects."vpn clientlessAccessProfile") {
    foreach ($Profile in $NSObjects."vpn clientlessAccessProfile") {
        addNSObject "rewrite policylabel" (getNSObjects ($config -match " vpn clientlessAccessProfile $Profile ") "rewrite policylabel" -position 4)
    }
}


# Get global filter bindings, filter actions, and forwarding services

if ($config -match "enable ns feature.* CF") {
    addNSObject "filter policy" (getNSObjects ($config -match "bind filter global ") "filter policy")
    if ($NSObjects."filter policy") {
        # Get Filter Actions from Filter Policies
        foreach ($policy in $NSObjects."filter policy") {
            addNSObject "filter action" (getNSObjects ($config -match "filter policy $policy ") "filter action")
        }
        # Get Forwarding Services from Filter Actions
        foreach ($action in $NSObjects."filter action") {
            addNSObject "service" (getNSObjects ($config -match "filter action $action ") "service" "forward")
        }
    }
}

 if ($config -match "enable ns feature.* IC") {
    $NSObjects."cache parameter" = @("enable ns feature IC")
    # Get Cache Policies from Global Cache Bindings
    addNSObject "cache policylabel" (getNSObjects ($config -match "bind cache global ") "cache policylabel")
    addNSObject "cache Policy" (getNSObjects ($config -match "bind cache global ") "cache Policy")
    addNSObject "cache parameter" ($config -match "set cache parameter ") "cache parameter"
    addNSObject "cache global" ($config -match "bind cache global ") "cache global"
} else {
    $NSObjects."cache parameter" = @("# *** Integrated Caching feature is not enabled. Cache Global bindings skipped.")
}



# Get Cache Policies from Cache Policy Labels
if ($NSObjects."cache policylabel") {
    foreach ($policy in $NSObjects."cache policylabel") {
        addNSObject "cache Policy" (getNSObjects ($config -match " $policy ") "cache Policy")
    }
}


# Get Cache Content Groups from Cache Policies
if ($NSObjects."cache policy") {
    foreach ($policy in $NSObjects."cache policy") {
        addNSObject "cache contentGroup" (getNSObjects ($config -match " $policy ") "cache contentGroup")
    }
}


# Get Cache Selectors from Cache Content Groups
if ($NSObjects."cache contentGroup") {
    foreach ($policy in $NSObjects."cache contentGroup") {
        addNSObject "cache selector" (getNSObjects ($config -match " $policy ") "cache selector")
    }
}


# Get Global Responder Bindings
addNSObject "responder policy" (getNSObjects ($config -match "bind responder global ") "responder policy")
addNSObject "responder policylabel" (getNSObjects ($config -match "bind responder global ") "responder policylabel")


# Get Responder Policies from Responder Policy Labels
if ($NSObjects."responder policylabel") {
    foreach ($policy in $NSObjects."responder policylabel") {
        addNSObject "responder Policy" (getNSObjects ($config -match " $policy ") "responder Policy")
    }
}


# Get Responder Actions and Responder Global Settings
if ($NSObjects."responder policy") {
    foreach ($policy in $NSObjects."responder policy") {
        addNSObject "responder action" (getNSObjects ($config -match " responder policy $policy ") "responder action")
        addNSObject "audit messageaction" (getNSObjects ($config -match "responder policy $policy") "audit messageaction" "-logAction")
        addNSObject "ns assignment" (getNSObjects ($config -match "responder policy $policy") "ns assignment")
    }
    if ($config -match "enable ns feature.* RESPONDER") {
        $NSObjects."responder param" = @("enable ns feature RESPONDER")
    } else {
        $NSObjects."responder param" = @("# *** Responder feature is not enabled")
    }
    addNSObject "responder param" ($config -match "set responder param ") "responder param"
    addNSObject "responder global" ($config -match "bind responder global ") "responder global"

}


# Get Rewrite Policies from Global Rewrite Bindings
addNSObject "rewrite policy" (getNSObjects ($config -match "bind rewrite global ") "rewrite policy")
addNSObject "rewrite policylabel" (getNSObjects ($config -match "bind rewrite global ") "rewrite policylabel")


# Get Rewrite Policies from Rewrite Policy Labels
if ($NSObjects."rewrite policylabel") {
    foreach ($policy in $NSObjects."rewrite policylabel") {
        addNSObject "rewrite Policy" (getNSObjects ($config -match " $policy ") "rewrite Policy")
    }
}


# Get Rewrite Actions and Rewrite Global Settings
if ($NSObjects."rewrite policy") {
    foreach ($policy in $NSObjects."rewrite policy") {
        addNSObject "rewrite action" (getNSObjects ($config -match "rewrite policy $policy ") "rewrite action")
        addNSObject "audit messageaction" (getNSObjects ($config -match "rewrite policy $policy") "audit messageaction" "-logAction")
    }
    if ($config -match "enable ns feature.* rewrite") {
        $NSObjects."rewrite param" = @("enable ns feature rewrite")
    } else {
        $NSObjects."rewrite param" = @("# *** Rewrite feature is not enabled")
    }
    addNSObject "rewrite param" ($config -match "set rewrite param ") "rewrite param"
    addNSObject "rewrite global" ($config -match "bind rewrite global ") "rewrite global"
}


# Get Compression Policies from Global Compression Bindings
addNSObject "cmp policy" (getNSObjects ($config -match "bind cmp global ") "cmp policy")
addNSObject "cmp policylabel" (getNSObjects ($config -match "bind cmp global ") "cmp policylabel")


# Get Compression Policies from Compression Policy Labels
if ($NSObjects."cmp policylabel") {
    foreach ($policy in $NSObjects."cmp policylabel") {
        addNSObject "cmp policy" (getNSObjects ($config -match "cmp policylabel $policy ") "cmp policy")
    }
}


# Get Compression Actions and Compression Global Settings
if ($NSObjects."cmp policy") {
    foreach ($policy in $NSObjects."cmp policy") {
        addNSObject "cmp action" (getNSObjects ($config -match "cmp policy $Pplicy ") "cmp action")
        addNSObject "audit messageaction" (getNSObjects ($config -match "cmp policy $policy") "audit messageaction" "-logAction")
    }
    if ($config -match "enable ns feature.* cmp") {
        $NSObjects."cmp parameter" = @("enable ns feature cmp")
    } else {
        $NSObjects."cmp parameter" = @("# *** Compression feature is not enabled")
    }
    addNSObject "cmp parameter" ($config -match "set cmp parameter ") "cmp parameter"
    addNSObject "cmp global" ($config -match "bind cmp global ") "cmp global"
}


# Get global bound Traffic Management Policies
addNSObject "tm trafficPolicy" (getNSObjects ($config -match "bind tm global") "tm trafficPolicy")
addNSObject "tm sessionPolicy" (getNSObjects ($config -match "bind tm global") "tm sessionPolicy")
addNSObject "audit syslogPolicy" (getNSObjects ($config -match "bind tm global") "audit syslogPolicy")
addNSObject "audit nslogPolicy" (getNSObjects ($config -match "bind tm global") "audit nslogPolicy")
addNSObject "tm global" ($config -match "bind tm global ") "tm global"


# Get AAA Traffic Actions from AAA Traffic Policies
if ($NSObjects."tm trafficPolicy") {
    foreach ($policy in $NSObjects."tm trafficPolicy") {
        addNSObject "tm trafficAction" (getNSObjects ($config -match " $policy ") "tm trafficAction" -position 4)
    }
}


# Get KCD Accounts and SSO Profiles from AAA Traffic Actions
if ($NSObjects."tm trafficAction") {
    foreach ($profile in $NSObjects."tm trafficAction") {
        addNSObject "aaa kcdAccount" (getNSObjects ($config -match "tm trafficAction $profile ") "aaa kcdAccount" "-kcdAccount")
        addNSObject "tm formSSOAction" (getNSObjects ($config -match "tm trafficAction $profile ") "tm formSSOAction" "-formSSOAction")
        addNSObject "tm samlSSOProfile" (getNSObjects ($config -match "tm trafficAction $profile ") "tm samlSSOProfile" "-samlSSOProfile")
    }
}


# Get Authorization Policies from Authorization Policy Labels
if ($NSObjects."authorization policylabel") {
    foreach ($policy in $NSObjects."authorization policylabel") {
        addNSObject "authorization policy" (getNSObjects ($config -match "authorization policy $policy ") "authorization policy")
        addNSObject "audit messageaction" (getNSObjects ($config -match "authorization policy $policy") "audit messageaction" "-logAction")
    }
}


# Get SmartControl Actions from SmartControl Policies
if ($NSObjects."ica policy") {
    foreach ($policy in $NSObjects."ica policy") {
        addNSObject "ica action" (getNSObjects ($config -match "ica policy $policy ") "ica action" -position 4)
        addNSObject "audit messageaction" (getNSObjects ($config -match "ica policy $policy") "audit messageaction" "-logAction")

    }
    
    # Get SmartControl Access Profiles from SmartControl Actions
    if ($NSObjects."ica action") {
        foreach ($policy in $NSObjects."ica action") {
            addNSObject "ica accessprofile" (getNSObjects ($config -match " $policy ") "ica accessprofile" -position 4)
        }
    }
}


# Get VPN Traffic Actions from VPN Traffic Policies
if ($NSObjects."vpn trafficPolicy") {
    foreach ($policy in $NSObjects."vpn trafficPolicy") {
        addNSObject "vpn trafficAction" (getNSObjects ($config -match " $policy ") "vpn trafficAction" -position 4)
    }
}


# Get KCD Accounts and SSO Profiles from VPN Traffic Actions
if ($NSObjects."vpn trafficAction") {
    foreach ($profile in $NSObjects."vpn trafficAction") {
        addNSObject "aaa kcdAccount" (getNSObjects ($config -match "vpn trafficAction $profile ") "aaa kcdAccount" "-kcdAccount")
        addNSObject "vpn formSSOAction" (getNSObjects ($config -match "vpn trafficAction $profile ") "vpn formSSOAction" "-formSSOAction")
        addNSObject "vpn samlSSOProfile" (getNSObjects ($config -match "vpn trafficAction $profile ") "vpn samlSSOProfile" "-samlSSOProfile")
    }
}


# Get PCoIP and RDP Profiles, and AlwaysOn Profiles from VPN Session Actions
if ($NSObjects."vpn sessionAction") {
    foreach ($policy in $NSObjects."vpn sessionAction") {
        addNSObject "vpn pcoipProfile" (getNSObjects ($config -match " $policy ") "vpn pcoipProfile" -position 4)
        addNSObject "rdp clientprofile" (getNSObjects ($config -match " $policy ") "rdp clientprofile" -position 4)
        addNSObject "vpn alwaysONProfile" (getNSObjects ($config -match " $policy ") "vpn alwaysONProfile" "-alwaysONProfileName")
    }
}


# Get AAA Session Actions
if ($NSObjects."tm sessionPolicy") {
    foreach ($policy in $NSObjects."tm sessionPolicy") {
        addNSObject "tm sessionAction" (getNSObjects ($config -match " $policy ") "tm sessionAction")
    }
}


# Get KCD Accounts from AAA Session Actions
if ($NSObjects."tm sessionAction") {
    foreach ($profile in $NSObjects."tm sessionAction") {
        addNSObject "aaa kcdAccount" (getNSObjects ($config -match "tm sessionAction $profile ") "aaa kcdAccount" "-kcdAccount")
    }
}


# Get Appflow Policies from Global Appflow Bindings
addNSObject "appflow policy" (getNSObjects ($config -match "bind appflow global ") "appflow policy")
addNSObject "appflow policylabel" (getNSObjects ($config -match "bind appflow global ") "appflow policylabel")


# Get Appflow Policies from Appflow Policy Labels
if ($NSObjects."appflow policylabel") {
    foreach ($policy in $NSObjects."appflow policylabel") {
        addNSObject "appflow Policy" (getNSObjects ($config -match " $policy ") "appflow Policy")
    }
}


# Get Appflow Actions from AppFlow Policies
# Get AppFlow Global Settings
if ($NSObjects."appflow policy") {
    foreach ($policy in $NSObjects."appflow policy") {
        addNSObject "appflow action" (getNSObjects ($config -match " $policy ") "appflow action")
    }
    # Get AppFlow Collector
    if ($NSObjects."appflow action") {
        foreach ($action in $NSObjects."appflow action") {
            addNSObject "appflow collector" (getNSObjects ($config -match " $action ") "appflow collector" "-collectors")
        }
    }
    if ($config -match "enable ns feature.* appflow") {
        $NSObjects."appflow param" = @("enable ns feature appflow")
    } else {
        $NSObjects."appflow param" = @("# *** AppFlow feature is not enabled")
    }
    addNSObject "appflow param" ($config -match "set appflow param ")
    addNSObject "appflow global" ($config -match "bind appflow global ") "appflow global"
}


# Get AppQoE Actions from AppQoE Policies
# Get AppQoE Global Settings
if ($NSObjects."appqoe policy") {
    foreach ($policy in $NSObjects."appqoe policy") {
        addNSObject "appqoe action" (getNSObjects ($config -match " $policy ") "appqoe action")
    }
    if ($config -match "enable ns feature.* appqoe") {
        $NSObjects."appqoe parameter" = @("enable ns feature appqoe")
    } else {
        $NSObjects."appqoe parameter" = @("# *** AppQoE feature is not enabled")
    }
    addNSObject "appqoe parameter" ($config -match "appqoe parameter") "appqoe parameter"
    addNSObject "appqoe parameter" ($config -match "set qos parameters") "appqoe parameter"
}


# Get AppFW Policies from Global AppFW Bindings
addNSObject "appfw policy" (getNSObjects ($config -match "bind appfw global ") "appfw Policy")
addNSObject "appfw policylabel" (getNSObjects ($config -match "bind appfw global ") "appfw policylabel")


# Get AppFW Policies from AppFW Policy Labels
if ($NSObjects."appfw policylabel") {
    foreach ($policy in $NSObjects."appfw policylabel") {
        addNSObject "appfw policy" (getNSObjects ($config -match " $policy ") "appfw policy")
    }
}


# Get AppFW Profiles from AppFW Policies
if ($NSObjects."appfw policy") {
    foreach ($policy in $NSObjects."appfw policy") {
        addNSObject "appfw profile" (getNSObjects ($config -match "appfw policy $policy ") "appfw profile")
        addNSObject "audit messageaction" (getNSObjects ($config -match "appfw policy $policy") "audit messageaction" "-logAction")

    }
    if ($config -match "enable ns feature.* appfw") {
        $NSObjects."appfw parameter" = @("enable ns feature appfw")
    } else {
        $NSObjects."appfw parameter" = @("# *** AppFW feature is not enabled")
    }
    addNSObject "appfw parameter" ($config -match "set appfw settings") "appfw parameter"
    addNSObject "appfw global" ($config -match "bind appfw global ") "appfw global"
}


# Get Login Schemas from Login Schema Policies
if ($NSObjects."authentication loginSchemaPolicy") {
    foreach ($policy in $NSObjects."authentication loginSchemaPolicy") {
        addNSObject "authentication loginSchema" (getNSObjects ($config -match "authentication loginSchemaPolicy $policy ") "authentication loginSchema")
        addNSObject "audit messageaction" (getNSObjects ($config -match "authentication loginSchemaPolicy $policy") "audit messageaction" "-logAction")

    }
}


# Get KCD Accounts from Database Profiles
if ($NSObjects."db dbProfile") {
    foreach ($profile in $NSObjects."db dbProfile") {
        addNSObject "aaa kcdAccount" (getNSObjects ($config -match " db dbProfile $profile ") "aaa kcdAccount")
    }
}


# Get Transform Policies from Global Transform Bindings
addNSObject "transform policy" (getNSObjects ($config -match "bind transform global ") "transform policy")
addNSObject "transform policylabel" (getNSObjects ($config -match "bind transform global ") "transform policylabel")


# Get Transform Policies from Transform Policy Labels
if ($NSObjects."transform policylabel") {
    foreach ($policy in $NSObjects."transform policylabel") {
        addNSObject "transform policy" (getNSObjects ($config -match " $policy ") "transform policy")
    }
}


# Get Transform Actions and Profiles from Transform Policies
if ($NSObjects."transform policy") {
    foreach ($policy in $NSObjects."transform policy") {
        addNSObject "transform action" (getNSObjects ($config -match " transform policy $policy ") "transform action")
        addNSObject "audit messageaction" (getNSObjects ($config -match "transform policy $policy") "audit messageaction" "-logAction")
    }
    foreach ($action in $NSObjects."transform action") {
        addNSObject "transform profile" (getNSObjects ($config -match " transform action $action ") "transform profile")
    }
    addNSObject "transform global" ($config -match "bind transform global ") "transform global"
}


# If FEO feature is enabled, get global FEO settings
addNSObject "feo policy" (getNSObjects ($config -match "bind feo global ") "feo Policy")


# Get FEO Actions from FEO Policies
# Get FEO Global Settings
if ($NSObjects."feo policy") {
    foreach ($policy in $NSObjects."feo policy") {
        addNSObject "feo action" (getNSObjects ($config -match " feo policy $policy ") "feo action")
    }
    if ($config -match "enable ns feature.* feo") {
        $NSObjects."feo parameter" = @("enable ns feature feo")
    } else {
        $NSObjects."feo parameter" = @("# feo feature is not enabled")
    }
    addNSObject "feo parameter" ($config -match "set feo param ") "feo parameter"
    addNSObject "feo global" ($config -match "bind feo global ") "feo global"
}


# Get Spillover Actions from Spillover Policies
if ($NSObjects."spillover policy") {
    foreach ($policy in $NSObjects."spillover policy") {
        addNSObject "spillover action" (getNSObjects ($config -match " spillover policy $policy ") "spillover action")
    }
}



# Get Audit Syslog Actions from Audit Syslog Policies
if ($NSObjects."audit syslogpolicy") {
    foreach ($policy in $NSObjects."audit syslogpolicy") {
        addNSObject "audit syslogaction" (getNSObjects ($config -match " audit syslogpolicy $policy ") "audit syslogaction")
    }
    addNSObject "audit syslogactionglobal" ($config -match "audit syslogParams ") "audit syslogactionglobal"
    addNSObject "audit syslogactionglobal" ($config -match "bind audit syslogactionglobal ") "audit syslogactionglobal"
    addNSObject "audit syslogactionglobal" ($config -match "bind audit syslogGlobal ") "audit syslogactionglobal"
}


# Get Audit Nslog Policies from Global Audit Nslog Bindings
addNSObject "audit nslogpolicy" (getNSObjects ($config -match "bind audit nslogglobal ") "audit nslogpolicy")


# Get Audit Nslog Actions from Audit Nslog Policies
if ($NSObjects."audit nslogpolicy") {
    foreach ($policy in $NSObjects."audit nslogpolicy") {
        addNSObject "audit nslogaction" (getNSObjects ($config -match " audit nslogpolicy $policy ") "audit nslogaction")
    }
    addNSObject "audit nslogactionglobal" ($config -match "bind audit syslogactionglobal ") "audit nslogactionglobal"
}


# Get SSL Policies from Global SSL Bindings
addNSObject "ssl policy" (getNSObjects ($config -match "bind ssl global ") "ssl policy")
addNSObject "ssl policylabel" (getNSObjects ($config -match "bind ssl global ") "ssl policylabel")


# Get SSL Policies from SSL Policy Labels
if ($NSObjects."ssl policylabel") {
    foreach ($policy in $NSObjects."ssl policylabel") {
        addNSObject "ssl policy" (getNSObjects ($config -match " $policy ") "ssl policy")
    }
}


# Get SSL Actions from SSL Policies
if ($NSObjects."ssl policy") {
    foreach ($ssl in $NSObjects."ssl policy") {
        addNSObject "ssl action" (getNSObjects ($config -match " $ssl ") "ssl action")
    }
    addNSObject "ssl global" ($config -match "bind ssl global ") "ssl global"
}


# Get SSL Log Profiles from SSL Actions
if ($NSObjects."ssl action") {
    foreach ($ssl in $NSObjects."ssl action") {
        addNSObject "ssl logprofile" (getNSObjects ($config -match " $ssl ") "ssl logprofile" "-ssllogprofile")
    }
}


# Get SSL Global Settings
if ($config -match "enable ns feature.* ssl") {
    $NSObjects."ssl parameter" = @("enable ns feature ssl")
} else {
    $NSObjects."ssl parameter" = @("# ssl feature is not enabled")
}
addNSObject "ssl parameter" ($config -match "set ssl parameter") "ssl parameter"
addNSObject "ssl parameter" ($config -match "set ssl fips") "ssl parameter"
addNSObject "ssl parameter" ($config -match "set ssl profile ns_default_ssl_profile_backend") "ssl parameter"


# Get Ciphers from SSL profiles
if ($NSObjects."ssl profile") {
    foreach ($ssl in $NSObjects."ssl profile") {
        addNSObject "ssl cipher" (getNSObjects ($config -match "bind ssl profile $ssl ") "ssl cipher" "-cipherName")
    }
}

# Get Global Policy Parameters
addNSObject "policy param" ($config -match "set policy param") "policy param"


# Get ACLs and RNAT
addNSObject "ns acl" ($config -match "ns acl") "ns acl"
addNSObject "ns acl" ($config -match "ns simpleacl") "ns acl"
addNSObject "rnat" (getNSObjects ($config -match "rnat ") "rnat")


# Get Limit Selectors from Limit Identifiers
if ($NSObjects."ns limitIdentifier") {
    foreach ($identifier in $NSObjects."ns limitIdentifier") {
        addNSObject "ns limitSelector" (getNSObjects ($config -match "ns limitIdentifier $identifier ") "ns limitSelector" "-selectorName")
        addNSObject "stream selector" (getNSObjects ($config -match "ns limitIdentifier $identifier ") "stream selector")
    }
}


# Get Stream Selectors from Stream Identifiers
if ($NSObjects."stream identifier") {
    foreach ($identifier in $NSObjects."ns limitIdentifier") {
        addNSObject "ns limitSelector" (getNSObjects ($config -match "stream identifier $identifier ") "ns limitSelector")
        addNSObject "stream selector" (getNSObjects ($config -match "stream identifier $identifier ") "stream selector")
    }
}


# Output Extracted Config


#cls
"`nExtracted Objects"
$NSObjects.GetEnumerator() | sort-object -Property Name

write-host "`nBuilding Config...`n
"
if ($outputFile -and ($outputFile -ne "screen")) {
    "# Extracted Config for: " + ($vservers -join ", ") + "`n`n" | out-file $outputFile
} else {
    "# Extracted Config for: " + ($vservers -join ", ") + "`n`n"
}


# System Settings
if ($NSObjects."ns config" ) { outputObjectConfig "NSIP" "ns config" "raw"}
if ($NSObjects."ns hostName" ) { outputObjectConfig "Hostname" "ns hostName" "raw"}
if ($NSObjects."ha node" ) { outputObjectConfig "High Availability Nodes" "HA node" "raw"}
if ($NSObjects."ha rpcNode" ) { outputObjectConfig "High Availability RPC Nodes" "ha rpcNode" "ns rpcNode"}
if ($NSObjects."ns feature" ) { outputObjectConfig "Enabled Features" "ns feature" "raw"}
if ($NSObjects."ns mode" ) { outputObjectConfig "Enabled Modes" "ns mode" "raw"}
if ($NSObjects."system parameter" ) { outputObjectConfig "CEIP" "system parameter" "raw"}
if ($NSObjects."ns encryptionParams" ) { outputObjectConfig "System Encryption Parameters" "ns encryptionParams" "raw"}
if ($NSObjects."system user" ) { outputObjectConfig "System Users" "system user"}
if ($NSObjects."system group" ) { outputObjectConfig "System Groups" "system group"}
if ($NSObjects."interface" ) { outputObjectConfig "Interfaces" "interface" "raw"}
if ($NSObjects."channel" ) { outputObjectConfig "Channels" "channel" "raw"}
if ($NSObjects."ns ip" ) { outputObjectConfig "IP Addresses" "ns ip"}
if ($NSObjects."vlan" ) { outputObjectConfig "VLANs" "vlan"}
if ($NSObjects."vrid" ) { outputObjectConfig "VMACs" "vrid"}
if ($NSObjects."ns partition" ) { outputObjectConfig "Partitions" "ns partition" -explainText "Partition configs are in /nsconfig/partitions" }
if ($NSObjects."ns pbr" ) { outputObjectConfig "Policy Based Routes (PBRs)" "ns pbr" "raw"}
if ($NSObjects."route" ) { outputObjectConfig "Routes" "route" "raw"}
if ($NSObjects."mgmt ssl service" ) { outputObjectConfig "Internal Management Services SSL Settings" "mgmt ssl service" "ssl service"}
if ($NSObjects."snmp trap" ) { outputObjectConfig "SNMP Traps" "snmp trap" "raw"}
if ($NSObjects."snmp community" ) { outputObjectConfig "SNMP Communities" "snmp community" "raw"}
if ($NSObjects."snmp manager" ) { outputObjectConfig "SNMP Managers" "snmp manager" "raw"}
if ($NSObjects."snmp alarm" ) { outputObjectConfig "SNMP Alarms" "snmp alarm" "raw"}


# Policy Expression Components and Profiles Output
if ($NSObjects."ns acl" ) { outputObjectConfig "Global ACLs" "ns acl" "raw" }
if ($NSObjects."rnat" ) { outputObjectConfig "Global RNAT" "rnat" }
if ($NSObjects."ns variable" ) { outputObjectConfig "Variables" "ns variable" }
if ($NSObjects."ns assignment" ) { outputObjectConfig "Variable Assignments" "ns assignment" }
if ($NSObjects."ns limitSelector" ) { outputObjectConfig "Rate Limiting Selectors" "ns limitSelector" }
if ($NSObjects."ns limitIdentifier" ) { outputObjectConfig "Rate Limiting Identifiers" "ns limitIdentifier" }
if ($NSObjects."stream selector" ) { outputObjectConfig "Action Analytics Selectors" "stream selector" }
if ($NSObjects."stream identifier" ) { outputObjectConfig "Action Analytics Identifiers" "stream identifier" }
if ($NSObjects."policy param" ) { outputObjectConfig "Policy Global Params" "policy param" "raw" }
if ($NSObjects."policy patset" ) { outputObjectConfig "Policy Pattern Sets" "policy patset" }
if ($NSObjects."policy dataset" ) { outputObjectConfig "Policy Data Sets" "policy dataset" }
if ($NSObjects."policy map" ) { outputObjectConfig "Policy Maps" "policy map" }
if ($NSObjects."policy stringmap" ) { outputObjectConfig "Policy String Maps" "policy stringmap" }
if ($NSObjects."policy urlset" ) { outputObjectConfig "Policy URL Sets" "policy urlset" }
if ($NSObjects."policy httpCallout" ) { outputObjectConfig "HTTP Callouts" "policy httpCallout" }
if ($NSObjects."policy expression" ) { outputObjectConfig "Policy Expressions" "policy expression" }
if ($NSObjects."dns addRec" ) { outputObjectConfig "DNS Address Records" "dns addRec" }
if ($NSObjects."dns nsRec" ) { outputObjectConfig "DNS Name Server Records" "dns nsRec"}
if ($NSObjects."dns cnameRec" ) { outputObjectConfig "DNS CNAME Records" "dns cnameRec"}
if ($NSObjects."dns soaRec" ) { outputObjectConfig "DNS SOA Records" "dns soaRec"}
if ($NSObjects."ns tcpProfile" ) { outputObjectConfig "TCP Profiles" "ns tcpProfile" }
if ($NSObjects."ns httpProfile" ) { outputObjectConfig "HTTP Profiles" "ns httpProfile" }
if ($NSObjects."db dbProfile" ) { outputObjectConfig "Database Profiles" "db dbProfile" }
if ($NSObjects."netProfile" ) { outputObjectConfig "Net Profiles" "netProfile" }
if ($NSObjects."ns trafficDomain" ) { outputObjectConfig "Traffic Domains" "ns trafficDomain" }
if ($NSObjects."ipset" ) { outputObjectConfig "IP Sets" "ipset" }
if ($NSObjects."analytics profile" ) { outputObjectConfig "Analytics Profiles" "analytics profile" }


# Policies Output
if ($NSObjects."appflow param" ) { outputObjectConfig "Appflow Global Params" "appflow param" "raw" }
if ($NSObjects."appflow collector" ) { outputObjectConfig "Appflow Collectors" "appflow collector" }
if ($NSObjects."appflow action" ) { outputObjectConfig "Appflow Actions" "appflow action" }
if ($NSObjects."appflow policy" ) { outputObjectConfig "Appflow Policies" "appflow policy" }
if ($NSObjects."appflow policylabel" ) { outputObjectConfig "Appflow Policy Labels" "appflow policylabel" }
if ($NSObjects."appflow global" ) { outputObjectConfig "Appflow Global Bindings" "appflow global" "raw" }

if ($NSObjects."rewrite param" ) { outputObjectConfig "Rewrite Global Parameters" "rewrite param" "raw" }
if ($NSObjects."rewrite action" ) { outputObjectConfig "Rewrite Actions" "rewrite action" }
if ($NSObjects."rewrite policy" ) { outputObjectConfig "Rewrite Policies" "rewrite policy" }
if ($NSObjects."rewrite policylabel" ) { outputObjectConfig "Rewrite Policy Labels" "rewrite policylabel" }
if ($NSObjects."rewrite global" ) { outputObjectConfig "Rewrite Global Bindings" "rewrite global" "raw" }

if ($NSObjects."responder param" ) { outputObjectConfig "Responder Global Parameters" "responder param" "raw" }
if ($NSObjects."responder action" ) { outputObjectConfig "Responder Actions" "responder action" }
if ($NSObjects."responder policy" ) { outputObjectConfig "Responder Policies" "responder policy" }
if ($NSObjects."responder policylabel" ) { outputObjectConfig "Responder Policy Labels" "responder policylabel" }
if ($NSObjects."responder global" ) { outputObjectConfig "Responder Global Bindings" "responder global" "raw" }

if ($NSObjects."appqoe parameter" ) { outputObjectConfig "AppQoE Global Parameters" "appqoe parameter" "raw"}
if ($NSObjects."appqoe action" ) { outputObjectConfig "AppQoE Actions" "appqoe action" }
if ($NSObjects."appqoe policy" ) { outputObjectConfig "AppQoE Policies" "appqoe policy" }

if ($NSObjects."feo parameter" ) { outputObjectConfig "Front-End Optimization Global Parameters" "feo parameter" "raw"}
if ($NSObjects."feo action" ) { outputObjectConfig "Front-End Optimization Actions" "feo action" }
if ($NSObjects."feo policy" ) { outputObjectConfig "Front-End Optimization Policies" "feo policy" }
if ($NSObjects."feo global" ) { outputObjectConfig "Front-End Optimization Global Bindings" "feo global" }

if ($NSObjects."cache parameter" ) { outputObjectConfig "Cache Global Parameters" "cache parameter" "raw" }
if ($NSObjects."cache selector" ) { outputObjectConfig "Cache Selectors" "cache selector" }
if ($NSObjects."cache contentGroup" ) { outputObjectConfig "Cache Content Groups" "cache contentGroup" }
if ($NSObjects."cache policy" ) { outputObjectConfig "Cache Policies" "cache policy" }
if ($NSObjects."cache policylabel" ) { outputObjectConfig "Cache Policy Labels" "cache policylabel" }
if ($NSObjects."cache global" ) { outputObjectConfig "Cache Global Bindings" "cache global" "raw" }

if ($NSObjects."cmp parameter" ) { outputObjectConfig "Compression Global Parameters" "cmp parameter" "raw" }
if ($NSObjects."cmp policy" ) { outputObjectConfig "Compression Policies" "cmp policy" }
if ($NSObjects."cmp policylabel" ) { outputObjectConfig "Compression Policy Labels" "cmp policylabel" }
if ($NSObjects."cmp global" ) { outputObjectConfig "Compression Global Bindings" "cmp global" "raw" }

if ($NSObjects."appfw parameter" ) { outputObjectConfig "AppFW Global Settings" "appfw parameter" "raw" }
if ($NSObjects."appfw profile" ) { outputObjectConfig "AppFW Profiles" "appfw profile" `
    -explainText ("Some portions of AppFw Profile are not in the config file.`nManually export/import Signatures Object" + `
    "`nManually export/import the AppFW Import Objects (e.g. HTML Error, XML Schema)") }
if ($NSObjects."appfw policy" ) { outputObjectConfig "AppFW Policies" "appfw policy" }
if ($NSObjects."appfw policylabel" ) { outputObjectConfig "AppFW Policy Labels" "appfw policylabel" }
if ($NSObjects."appfw global" ) { outputObjectConfig "AppFW Global Bindings" "appfw global" "raw" }

if ($NSObjects."transform profile" ) { outputObjectConfig "Transform Profiles" "transform profile" }
if ($NSObjects."transform action" ) { outputObjectConfig "Transform Actions" "transform action" }
if ($NSObjects."transform policy" ) { outputObjectConfig "Transform Policies" "transform policy" }
if ($NSObjects."transform policylabel" ) { outputObjectConfig "Transform Policy Labels" "transform policylabel" }
if ($NSObjects."transform global" ) { outputObjectConfig "Transform Global Bindings" "transform global" "raw" }

if ($NSObjects."filter action" ) { outputObjectConfig "Filter Actions" "filter action" }
if ($NSObjects."filter policy" ) { outputObjectConfig "Filter Policies" "filter policy" }
if ($NSObjects."filter global" ) { outputObjectConfig "Filter Global Bindings" "filter global" "raw" }

if ($NSObjects."audit syslogaction" ) { outputObjectConfig "Audit Syslog Actions" "audit syslogaction" }
if ($NSObjects."audit syslogpolicy" ) { outputObjectConfig "Audit Syslog Policies" "audit syslogpolicy" }

if ($NSObjects."audit nslogaction" ) { outputObjectConfig "Audit NSLog Actions" "audit nslogaction" }
if ($NSObjects."audit nslogpolicy" ) { outputObjectConfig "Audit NSLog Policies" "audit nslogpolicy" }

if ($NSObjects."audit syslogactionglobal" ) { outputObjectConfig "Global Audit Syslog Bindings" "audit syslogactionglobal" "raw" }


# SSL Output
if ($NSObjects."ssl parameter" ) { outputObjectConfig "SSL Global Parameters" "ssl parameter" "raw" }
if ($NSObjects."ssl cipher" ) { outputObjectConfig "SSL Cipher Groups" "ssl cipher" }
if ($NSObjects."ssl fipsKey" ) { outputObjectConfig "SSL FIPS Keys" "ssl fipsKey" }
if ($NSObjects."ssl cert" ) { outputObjectConfig "Certs" "ssl cert" "raw" `
    -explainText "Get certificate files from /nsconfig/ssl" }
if ($NSObjects."ssl link" ) { outputObjectConfig "Cert Links" "ssl link" "raw" }
if ($NSObjects."ssl profile" ) { outputObjectConfig "SSL Profiles" "ssl profile" }
if ($NSObjects."ssl logprofile" ) { outputObjectConfig "SSL Log Profiles" "ssl logprofile" }
if ($NSObjects."ssl action" ) { outputObjectConfig "SSL Actions" "ssl action" }
if ($NSObjects."ssl policy" ) { outputObjectConfig "SSL Policies" "ssl policy" }


# AAA Output
if ($NSObjects."vpn portaltheme" ) { outputObjectConfig "Portal Themes" "vpn portaltheme" `
    -explainText "Portal Theme customizations are not in the NetScaler config file and instead are stored in /var/netscaler/logon/themes/{ThemeName}" }
if ($NSObjects."authentication param" ) { outputObjectConfig "AAA Global Settings" "authentication param" "raw" }
if ($NSObjects."authorization policy" ) { outputObjectConfig "Authorization Policies" "authorization policy" }
if ($NSObjects."authorization policylabel" ) { outputObjectConfig "Authorization Policies" "authorization policylabel" }
if ($NSObjects."authentication pushService" ) { outputObjectConfig "OTP Push Service" "authentication pushService" }
if ($NSObjects."aaa kcdAccount" ) { outputObjectConfig "KCD Accounts" "aaa kcdAccount" }
if ($NSObjects."authentication ldapAction" ) { outputObjectConfig "LDAP Actions" "authentication ldapAction" `
	-explainText "LDAP certificate verification Root certificates are in /nsconfig/truststore" }
if ($NSObjects."authentication ldapPolicy" ) { outputObjectConfig "LDAP Policies" "authentication ldapPolicy" }
if ($NSObjects."authentication radiusAction" ) { outputObjectConfig "RADIUS Actions" "authentication radiusAction" }
if ($NSObjects."authentication radiusPolicy" ) { outputObjectConfig "RADIUS Policies" "authentication radiusPolicy" }
if ($NSObjects."authentication OAuthAction" ) { outputObjectConfig "OAuth Actions" "authentication OAuthAction" }
if ($NSObjects."authentication samlAction" ) { outputObjectConfig "SAML Actions" "authentication samlAction" }
if ($NSObjects."authentication samlIdPProfile" ) { outputObjectConfig "SAML IdP Profiles" "authentication samlIdPProfile" }
if ($NSObjects."authentication certAction" ) { outputObjectConfig "Cert Actions" "authentication certAction" }
if ($NSObjects."authentication dfaAction" ) { outputObjectConfig "Delegaged Forms Authentication Actions" "authentication dfaAction" }
if ($NSObjects."authentication epaAction" ) { outputObjectConfig "Endpoint Analysis Actions" "authentication epaAction" }
if ($NSObjects."authentication negotiateAction" ) { outputObjectConfig "Negotiate (Kerberos) Actions" "authentication negotiateAction" }
if ($NSObjects."authentication storefrontAuthAction" ) { outputObjectConfig "StorefrontAuth Actions" "authentication storefrontAuthAction" }
if ($NSObjects."authentication tacacsAction" ) { outputObjectConfig "TACACS Actions" "authentication tacacsAction" }
if ($NSObjects."authentication tacacsPolicy" ) { outputObjectConfig "TACACS Policies" "authentication tacacsPolicy" }
if ($NSObjects."authentication localPolicy" ) { outputObjectConfig "Local Authentication Policies" "authentication localPolicy" }
if ($NSObjects."authentication webAuthAction" ) { outputObjectConfig "Web Auth Actions" "authentication webAuthAction" }
if ($NSObjects."authentication emailAction" ) { outputObjectConfig "Email (SSPR) Actions" "authentication emailAction" }
if ($NSObjects."authentication noAuthAction" ) { outputObjectConfig "NoAuth Actions" "authentication noAuthAction" }
if ($NSObjects."authentication captchaAction" ) { outputObjectConfig "Captcha Actions" "authentication captchaAction" }
if ($NSObjects."authentication adfsProxyProfile" ) { outputObjectConfig "ADFS Proxy Profile" "authentication adfsProxyProfile" }
if ($NSObjects."authentication samlPolicy" ) { outputObjectConfig "SAML Authentication Policies" "authentication samlPolicy" }
if ($NSObjects."authentication policy" ) { outputObjectConfig "Advanced Authentication Policies" "authentication policy" }
if ($NSObjects."authentication loginSchema" ) { outputObjectConfig "Login Schemas" "authentication loginSchema" }
if ($NSObjects."authentication loginSchemaPolicy" ) { outputObjectConfig "Login Schema Policies" "authentication loginSchemaPolicy" }
if ($NSObjects."authentication policylabel" ) { outputObjectConfig "Authentication Policy Labels" "authentication policylabel" }
if ($NSObjects."tm sessionAction" ) { outputObjectConfig "AAA Session Profiles" "tm sessionAction" }
if ($NSObjects."tm sessionPolicy" ) { outputObjectConfig "AAA Session Policies" "tm sessionPolicy" }
if ($NSObjects."authentication vserver" ) { outputObjectConfig "Authentication Virtual Servers" "authentication vserver" }
if ($NSObjects."authentication authnProfile" ) { outputObjectConfig "Authentication Profiles" "authentication authnProfile" }
if ($NSObjects."tm formSSOAction" ) { outputObjectConfig "AAA Form SSO Profiles" "tm formSSOAction" }
if ($NSObjects."tm trafficAction" ) { outputObjectConfig "AAA Traffic Profiles" "tm trafficAction" }
if ($NSObjects."tm trafficPolicy" ) { outputObjectConfig "AAA Traffic Policies" "tm trafficPolicy" }
if ($NSObjects."tm global" ) { outputObjectConfig "AAA Global Bindings" "tm global" "raw" }

# Load Balancing output
if ($NSObjects."lb parameter" ) { outputObjectConfig "Load Balancing Global Parameters" "lb parameter" "raw" }
if ($NSObjects."lb metricTable" ) { outputObjectConfig "Metric Tables" "lb metricTable" }
if ($NSObjects."lb profile" ) { outputObjectConfig "Load Balancing Profiles" "lb profile" }
if ($NSObjects."monitor" ) { outputObjectConfig "Monitors" "monitor" }
if ($NSObjects."server" ) { outputObjectConfig "Servers" "server" }
if ($NSObjects."service" ) { outputObjectConfig "Services" "service" }
if ($NSObjects."serviceGroup" ) { outputObjectConfig "Service Groups" "serviceGroup" }
if ($NSObjects."lb vserver" ) { outputObjectConfig "Load Balancing Virtual Servers" "lb vserver" }
if ($NSObjects."lb group" ) { outputObjectConfig "Persistency Group" "lb group" }


# Content Switching Output
if ($NSObjects."cs parameter" ) { outputObjectConfig "Content Switching Parameters" "cs parameter" "raw" }
if ($NSObjects."cs action" ) { outputObjectConfig "Content Switching Actions" "cs action" }
if ($NSObjects."cs policy" ) { outputObjectConfig "Content Switching Policies" "cs policy" }
if ($NSObjects."cs policylabel" ) { outputObjectConfig "Content Switching Policy Labels" "cs policylabel" }


# Citrix Gateway Output
if ($NSObjects."vpn intranetApplication" ) { outputObjectConfig "Citrix Gateway Intranet Applications" "vpn intranetApplication" }
if ($NSObjects."aaa preauthenticationaction" ) { outputObjectConfig "Preauthentication Profiles" "aaa preauthenticationaction" }
if ($NSObjects."aaa preauthenticationpolicy" ) { outputObjectConfig "Preauthentication Policies" "aaa preauthenticationpolicy" }
if ($NSObjects."vpn eula" ) { outputObjectConfig "Citrix Gateway EULA" "vpn eula" }
if ($NSObjects."vpn clientlessAccessProfile" ) { outputObjectConfig "Citrix Gateway Clientless Access Profiles" "vpn clientlessAccessProfile" }
if ($NSObjects."vpn clientlessAccessPolicy" ) { outputObjectConfig "Citrix Gateway Clientless Access Policies" "vpn clientlessAccessPolicy" }
if ($NSObjects."rdp clientprofile" ) { outputObjectConfig "Citrix Gateway RDP Profiles" "rdp clientprofile" }
if ($NSObjects."vpn pcoipProfile" ) { outputObjectConfig "Citrix Gateway PCoIP Profiles" "vpn pcoipProfile" }
if ($NSObjects."vpn pcoipVserverProfile" ) { outputObjectConfig "Citrix Gateway VServer PCoIP Profiles" "vpn pcoipVserverProfile" }
if ($NSObjects."vpn formSSOAction" ) { outputObjectConfig "Citrix Gateway Form SSO Profiles" "vpn formSSOAction" }
if ($NSObjects."vpn trafficAction" ) { outputObjectConfig "Citrix Gateway Traffic Profiles" "vpn trafficAction" }
if ($NSObjects."vpn trafficPolicy" ) { outputObjectConfig "Citrix Gateway Traffic Policies" "vpn trafficPolicy" }
if ($NSObjects."vpn alwaysONProfile" ) { outputObjectConfig "Citrix Gateway AlwaysON Profiles" "vpn alwaysONProfile" }
if ($NSObjects."vpn sessionAction" ) { outputObjectConfig "Citrix Gateway Session Profiles" "vpn sessionAction" }
if ($NSObjects."vpn sessionPolicy" ) { outputObjectConfig "Citrix Gateway Session Policies" "vpn sessionPolicy" }
if ($NSObjects."ica accessprofile" ) { outputObjectConfig "Citrix Gateway SmartControl Access Profiles" "ica accessprofile" }
if ($NSObjects."ica action" ) { outputObjectConfig "Citrix Gateway SmartControl Actions" "ica action" }
if ($NSObjects."ica policy" ) { outputObjectConfig "Citrix Gateway SmartControl Policies" "ica policy" }
if ($NSObjects."vpn url" ) { outputObjectConfig "Citrix Gateway Bookmarks" "vpn url" }
if ($NSObjects."vpn parameter" ) { outputObjectConfig "Citrix Gateway Global Settings" "vpn parameter" "raw" }
if ($NSObjects."clientless domains" ) { outputObjectConfig "Citrix Gateway Clientless Domains" "clientless domains" "raw" }
if ($NSObjects."vpn nextHopServer" ) { outputObjectConfig "Citrix Gateway Next Hop Servers" "vpn nextHopServer" }
if ($NSObjects."vpn vserver" ) { outputObjectConfig "Citrix Gateway Virtual Servers" "vpn vserver" }
if ($NSObjects."vpn global" ) { outputObjectConfig "Citrix Gateway Global Bindings" "vpn global" "raw" }
if ($NSObjects."aaa group" ) { outputObjectConfig "AAA Groups" "aaa group" }


# GSLB Output
if ($NSObjects."adns service" ) { outputObjectConfig "ADNS Services" "adns service" "raw" }
if ($NSObjects."gslb site" ) { outputObjectConfig "GSLB Sites" "gslb site" }
if ($NSObjects."ns rpcNode" ) { outputObjectConfig "GSLB RPC Nodes" "ns rpcNode" }
if ($NSObjects."dns view" ) { outputObjectConfig "DNS Views" "dns view" }
if ($NSObjects."dns action" ) { outputObjectConfig "DNS Actions" "dns action" }
if ($NSObjects."dns policy" ) { outputObjectConfig "DNS Policies" "dns policy" }
if ($NSObjects."dns global" ) { outputObjectConfig "DNS Global Bindings" "dns global" "raw"}
if ($NSObjects."gslb location" ) { outputObjectConfig "GSLB Locations (Static Proximity)" "gslb location" "raw" }
if ($NSObjects."gslb parameter" ) { outputObjectConfig "GSLB Parameters" "gslb parameter" "raw" }
if ($NSObjects."gslb service" ) { outputObjectConfig "GSLB Services" "gslb service" }
if ($NSObjects."gslb vserver" ) { outputObjectConfig "GSLB Virtual Servers" "gslb vserver" }

if ($NSObjects."cr policy" ) { outputObjectConfig "Cache Redirection Policies" "cr policy" }
if ($NSObjects."cr vserver" ) { outputObjectConfig "Cache Redirection Virtual Servers" "cr vserver" }

if ($NSObjects."cs vserver" ) { outputObjectConfig "Content Switching Virtual Servers" "cs vserver" }

if ($NSObjects."ssl vserver" ) { outputObjectConfig "SSL Virtual Servers" "ssl vserver" }

# Global System Bindings - can't bind until objects are created
if ($NSObjects."system global" ) { outputObjectConfig "System Global Bindings" "system global" "raw"}
if ($NSObjects."dns nameServer" ) { outputObjectConfig "DNS Name Servers" "dns nameServer" }


if ($outputFile -and ($outputFile -ne "screen")) {
    # Convert file EOLs to UNIX format so file can be batch imported to NetScaler
    $text = [IO.File]::ReadAllText($outputFile) -replace "`r`n", "`n"
    [IO.File]::WriteAllText($outputFile, $text)
}

if ($textEditor -and ($outputFile -and ($outputFile -ne "screen"))) {    

    # Open Text Editor

    if (Test-Path $textEditor -PathType Leaf){

        write-host "`nOpening Output file `"$outputFile`" using `"$textEditor`" ..."

        start-process -FilePath $textEditor -ArgumentList "`"$outputFile`""

    } else { 
        write-host "`nText Editor not found: `"$textEditor`"" 
        write-host "`nCan't open output file: `"$outputFile`""
    }

}