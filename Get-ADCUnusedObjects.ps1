# Get NetScaler Unused Objects
# Note: This script works on Windows 10, but the regex match group commands fail on Windows 7

param (
    # Full path to source config file saved from NetScaler ADC (System > Diagnostics > Running Configuration)
    # If set to "", then the script will prompt for the file.
    [string]$configFile = "",
    #$configFile = "$env:userprofile\Downloads\nsrunning.conf"

    # Optional filename to save output - file will be overwritten
    # If set to "screen", then output will go to screen.
    # If set to "", then the script will prompt for a file. Clicking cancel will output to the screen.
    #[string]$outputFile = "",
    #[string]$outputFile = "screen",
    [string]$outputFile = "$env:userprofile\Downloads\UnusedObjects.txt",
    #[string]$outputFile = "$env:HOME/Downloads/UnusedObjects.txt",

    # Optional text editor to open saved output file - text editor should handle UNIX line endings (e.g. Wordpad or Notepad++)
    [string]$textEditor = "c:\Program Files (x86)\Notepad++\notepad++.exe"

)

# Change Log
# ----------

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
        $DefaultName = 'default name "UnusedObjects.txt"'
        if ($initialDirectory){
            $DefaultLocation = 'default location "'+$initialDirectory+'"'
        }
        $filename = (('tell application "SystemUIServer"'+"`n"+'activate'+"`n"+'set theName to POSIX path of (choose file name '+$($DefaultName)+' '+$($DefaultLocation)+' with prompt "Save NetScaler documentation file as")'+"`n"+'end tell' | osascript -s s) -split '"')[1]
        $filename
    }else{
        [System.Reflection.Assembly]::LoadWithPartialName("System.windows.forms") | Out-Null
        $SaveFileDialog = New-Object System.Windows.Forms.SaveFileDialog
        $SaveFileDialog.Title = "Save Unused Objects List"
        $SaveFileDialog.initialDirectory = $initialDirectory
        # $SaveFileDialog.filter = "NetScaler Config File (*.conf)| *.conf|All files (*.*)|*.*"
        $SaveFileDialog.ShowDialog() | Out-Null
        $SaveFileDialog.filename
    }
}


# Run the Get-InputFile function to ask the user for the NetScaler config file
if (!$configFile) { $configFile = Get-InputFile $inputfile }

"Loading config file $configFile ...`n"

$config = ""
$config = Get-Content $configFile -ErrorAction Stop

# Strip Comments
$config = $config | ForEach-Object {$_ -replace '-comment ".*?"' }


function addNSObject ($NSObjectType, $NSObjectName) {
    if (!$NSObjectName) { return }
    
    if (!$nsObjects.$NSObjectType) { 
        $nsObjects.$NSObjectType = @()
    }
    
    $nsObjects.$NSObjectType += $NSObjectName
    $nsObjects.$NSObjectType = @($nsObjects.$NSObjectType | Select-Object -Unique)

    # Display progress
    foreach ($unusedObjectName in $NSObjectName) {
        write-host (("Found unused {0,-30} " -f $NSObjectType) + $unusedObjectName)
    }
    
}


function getUnusedNSObjects ($matchConfig, $NSObjectType, $paramName, $position) {
    # Read all objects of type from from full config
    $objectsAll = $config | select-string -Pattern ('^add ' + $NSObjectType + ' (".*?"|[^-"]\S+)($| )') | % {$_.Matches.Groups[1].value}
    
    # Match objects to matchConfig
    $objectMatches = @()
    foreach ($objectCandidate in $objectsAll) {
        
        # For regex, replace dots with escaped dots
        $objectCandidateDots = $objectCandidate -replace "\.", "\."

        # Don't remove ADNS Services
        if ($NSObjectType -eq "service" -and ($matchConfig | select-string -Pattern ('^add service ' + $objectCandidate + ' \d+.\d+.\d+.\d+ ADNS'))) {
            continue
        }

        # Don't remove built-in cache policies
        if ($NSObjectType -eq "cache policy" -and $objectCandidate -match "^ctx_") {
            continue
        }

        # Don't remove built-in cache content groups
        if ($NSObjectType -eq "cache contentGroup" -and ($objectCandidate -match "BASEFILE" -or $objectCandidate -match "DELTAJS")) {
            continue
        }
        
        # strip current object from config so remaining config can be checked
        $remainingConfig = $matchConfig | select-string -Pattern ('^(add|bind|set) ' + $NSObjectType + ' ' + $objectCandidate + ' ') -NotMatch

        # strip SSL settings for current object from remaining config
        $remainingConfig = $remainingConfig | select-string -Pattern ('^(add|bind|set) ssl (service|vserver|servicegroup|monitor|cipher|certkey) ' + $objectCandidate + ' ') -NotMatch

        # if ($objectCandidate -match "storefront") { write-host $objectCandidate;write-host ($matchConfig);read-host}
        # if ($NSObjectType -match "ssl certKey") { write-host $objectCandidate;write-host ($matchConfig);read-host}
        
        # Trying to avoid substring matches
        if (($remainingConfig -match (" " + $objectCandidateDots + "$")) -or ($remainingConfig -match (" " + $objectCandidateDots + " "))) { 
            # Look for candidate at end of string, or with spaces surrounding it - avoids substring matches
            continue
        } elseif (($remainingConfig -match ('"' + $objectCandidateDots + '\\"')) -or ($remainingConfig -match ('\(' + $objectCandidateDots + '\)"'))) {
            # Look for AppExpert objects (e.g. policy sets, callouts) in policy expressions that don't have spaces around it
            continue
        } elseif (($remainingConfig -match ('//' + $objectCandidateDots)) -or ($remainingConfig -match ($objectCandidateDots + ':'))) {
            # Look in URLs for DNS records
            continue
        } elseif (($remainingConfig -match ('\.' + $objectCandidateDots + '(\.|"|\(| )'))) {
            # Look in Policy Expressions for Policy Extensions - .extension. or .extension" or .extension( or .extension 
            continue
        } else {
            $objectMatches += $objectCandidate
        }
        
    }
    return $objectMatches
}


function outputObjectConfig ($header, $NSObjectType, $typeNeeded) {
    $uniqueObjects = $NSObjects.$NSObjectType | Select-Object -Unique
    
    # Build header line
    $output = "# " + $header + "`n# "
    1..$header.length | % {$output += "-"}
    $output += "`n"
    
    foreach ($uniqueObject in $uniqueObjects) {       
        # The "rm" command for LB Monitors requires a type parameter
        if ($typeNeeded) {
            $type = $config -match ("add " + $NSObjectType + " " + $uniqueObject + " (\S+)") | select-object -First 1
            if ($type) {
                $type = $type -match ("add " + $NSObjectType + " " + $uniqueObject + " (\S+)")
                $type = $Matches[1]
                $output += ("rm " + $NSObjectType + " " + $uniqueObject + " " + $type + "`n")
            } else {
                $output += ("rm " + $NSObjectType + " " + $uniqueObject + "`n")
            }
        } else {
            $output += ("rm " + $NSObjectType + " " + $uniqueObject + "`n")
        }
    }
    $output += "`n"

    # Output to file or screen
    if ($outputFile -and ($outputFile -ne "screen")) {
        $output | out-file $outputFile -Append
    } else {
        $output
    }
}

function outputUnusedADCObjects ($objectType, $objectTypeName, $typeNeeded) {
    if ($config -match $objectType) { 
        "`nLooking for unused " + $objectTypeName + ": `n"
        addNSObject $objectType (getUnusedNSObjects ($config) $objectType)
        if ($NSObjects.$objectType) { outputObjectConfig $objectTypeName $objectType $typeNeeded}
        }
}

# Clear configuration from last run
$nsObjects = @{}

# Run the Get-Output function to ask the user where to save the Unused Objects List
if (!$outputFile) { $outputFile = Get-OutputFile $outputfile }

# Prepare the output file
if ($outputFile -and ($outputFile -ne "screen")) {
    "# Unused ADC objects`n`n" | out-file $outputFile
} else {
    "# Unused ADC objects`n`n"
}


outputUnusedADCObjects "service" "Services"
outputUnusedADCObjects "server" "Server objects"
outputUnusedADCObjects "servicegroup" "Service Groups"
outputUnusedADCObjects "lb monitor" "Monitors" $true
outputUnusedADCObjects "ssl certkey" "Certificates"
outputUnusedADCObjects "cs policylabel" "Content Switching Policy Labels"
outputUnusedADCObjects "cs policy" "Content Switching Policies"
outputUnusedADCObjects "cs action" "Content Switching Actions"
outputUnusedADCObjects "responder policy" "Responder Policies"
outputUnusedADCObjects "responder action" "Responder Actions"
outputUnusedADCObjects "responder policylabel" "Responder Policy Labels"
outputUnusedADCObjects "transform policy" "Transform Policies"
outputUnusedADCObjects "transform action" "Transform Actions"
outputUnusedADCObjects "transform profile" "Transform Profiles"
outputUnusedADCObjects "vpn sessionPolicy" "Gateway Session Policies"
outputUnusedADCObjects "vpn sessionAction" "Gateway Session Profiles"
outputUnusedADCObjects "ns assignment" "Variable Assignments"
outputUnusedADCObjects "ns variable" "Variables"
outputUnusedADCObjects "ns limitSelector" "Rate Limiting Selectors"
outputUnusedADCObjects "ns limitIdentifier" "Rate Limiting Identifiers"
outputUnusedADCObjects "stream selector" "Action Analytics Selectors"
outputUnusedADCObjects "stream identifier" "Action Analytics Identifiers"
outputUnusedADCObjects "policy expression" "Policy Expressions"
outputUnusedADCObjects "policy patset" "Policy Pattern Sets"
outputUnusedADCObjects "policy dataset" "Policy Data Sets"
outputUnusedADCObjects "policy map" "Policy Maps"
outputUnusedADCObjects "policy stringmap" "Policy String Maps"
outputUnusedADCObjects "policy urlset" "Policy URL Sets"
outputUnusedADCObjects "policy httpCallout" "HTTP Callouts"
outputUnusedADCObjects "analytics profile" "Analytics Profiles"
outputUnusedADCObjects "appflow collector" "Appflow Collectors"
outputUnusedADCObjects "appflow action" "Appflow Actions"
outputUnusedADCObjects "appflow policy" "Appflow Policies"
outputUnusedADCObjects "appflow policylabel" "Appflow Policy Labels"
outputUnusedADCObjects "rewrite action" "Rewrite Actions"
outputUnusedADCObjects "rewrite policy" "Rewrite Policies"
outputUnusedADCObjects "rewrite policylabel" "Rewrite Policy Labels"
outputUnusedADCObjects "appqoe action" "AppQoE Actions"
outputUnusedADCObjects "appqoe policy" "AppQoE Policies"
outputUnusedADCObjects "feo action" "Front-End Optimization Actions"
outputUnusedADCObjects "feo policy" "Front-End Optimization Policies"
outputUnusedADCObjects "cache selector" "Cache Selectors"
outputUnusedADCObjects "cache contentGroup" "Cache Content Groups"
outputUnusedADCObjects "cache policy" "Cache Policies"
outputUnusedADCObjects "cache policylabel" "Cache Policy Labels"
outputUnusedADCObjects "cmp policy" "Compression Policies"
outputUnusedADCObjects "cmp policylabel" "Compression Policy Labels"
outputUnusedADCObjects "appfw profile" "AppFW Profiles" "appfw profile" `
outputUnusedADCObjects "appfw policy" "AppFW Policies"
outputUnusedADCObjects "appfw policylabel" "AppFW Policy Labels"
outputUnusedADCObjects "transform policylabel" "Transform Policy Labels"
outputUnusedADCObjects "filter action" "Filter Actions"
outputUnusedADCObjects "filter policy" "Filter Policies"
outputUnusedADCObjects "ssl cipher" "SSL Cipher Groups"
outputUnusedADCObjects "ssl fipsKey" "SSL FIPS Keys"
outputUnusedADCObjects "ssl cert" "Certs" "ssl cert"
outputUnusedADCObjects "ssl profile" "SSL Profiles"
outputUnusedADCObjects "ssl logprofile" "SSL Log Profiles"
outputUnusedADCObjects "ssl action" "SSL Actions"
outputUnusedADCObjects "ssl policy" "SSL Policies"
outputUnusedADCObjects "vpn portaltheme" "Portal Themes"
outputUnusedADCObjects "authorization policy" "Authorization Policies"
outputUnusedADCObjects "authorization policylabel" "Authorization Policies"
outputUnusedADCObjects "aaa kcdAccount" "KCD Accounts"
outputUnusedADCObjects "authentication radiusPolicy" "RADIUS Classic Authentication Policies"
outputUnusedADCObjects "authentication radiusAction" "RADIUS Servers"
outputUnusedADCObjects "authentication ldapPolicy" "LDAP Classic Authentication Policies"
outputUnusedADCObjects "authentication ldapAction" "LDAP Servers"
outputUnusedADCObjects "authentication samlPolicy" "SAML Classic Authentication Policies"
outputUnusedADCObjects "authentication samlAction" "SAML Servers"
outputUnusedADCObjects "authentication authnProfile" "AAA Authentication Profiles"
outputUnusedADCObjects "authentication OAuthAction" "OAuth Actions"
outputUnusedADCObjects "authentication certAction" "Cert Actions"
outputUnusedADCObjects "authentication dfaAction" "Delegaged Forms Authentication Actions"
outputUnusedADCObjects "authentication epaAction" "Endpoint Analysis Actions"
outputUnusedADCObjects "authentication negotiateAction" "Negotiate (Kerberos) Actions"
outputUnusedADCObjects "authentication storefrontAuthAction" "StorefrontAuth Actions"
outputUnusedADCObjects "authentication tacacsPolicy" "TACACS Classic Authentication Policies"
outputUnusedADCObjects "authentication tacacsAction" "TACACS Actions"
outputUnusedADCObjects "authentication webAuthAction" "Web Auth Actions"
outputUnusedADCObjects "authentication policy" "Advanced Authentication Policies"
outputUnusedADCObjects "authentication loginSchema" "Login Schemas"
outputUnusedADCObjects "authentication loginSchemaPolicy" "Login Schema Policies"
outputUnusedADCObjects "authentication policylabel" "Authentication Policy Labels"
outputUnusedADCObjects "tm sessionAction" "AAA Session Profiles"
outputUnusedADCObjects "tm sessionPolicy" "AAA Session Policies"
outputUnusedADCObjects "tm formSSOAction" "AAA Form SSO Profiles"
outputUnusedADCObjects "tm trafficAction" "AAA Traffic Profiles"
outputUnusedADCObjects "tm trafficPolicy" "AAA Traffic Policies"
outputUnusedADCObjects "lb metricTable" "Metric Tables"
outputUnusedADCObjects "lb profile" "Load Balancing Profiles"
outputUnusedADCObjects "vpn intranetApplication" "Gateway Intranet Applications"
outputUnusedADCObjects "aaa preauthenticationaction" "Preauthentication Profiles"
outputUnusedADCObjects "aaa preauthenticationpolicy" "Preauthentication Policies"
outputUnusedADCObjects "vpn eula" "Gateway EULA"
outputUnusedADCObjects "vpn clientlessAccessProfile" " Gateway Clientless Access Profiles"
outputUnusedADCObjects "vpn clientlessAccessPolicy" "Gateway Clientless Access Policies"
outputUnusedADCObjects "rdp clientprofile" "Gateway RDP Profiles"
outputUnusedADCObjects "vpn pcoipProfile" "Gateway PCoIP Profiles"
outputUnusedADCObjects "vpn pcoipVserverProfile" "Gateway VServer PCoIP Profiles"
outputUnusedADCObjects "vpn formSSOAction" "Gateway Form SSO Profiles"
outputUnusedADCObjects "vpn trafficAction" "Gateway Traffic Profiles"
outputUnusedADCObjects "vpn trafficPolicy" "Gateway Traffic Policies"
outputUnusedADCObjects "vpn alwaysONProfile" "Gateway AlwaysON Profiles"
outputUnusedADCObjects "ica accessprofile" "Gateway SmartControl Access Profiles"
outputUnusedADCObjects "ica action" "Gateway SmartControl Actions"
outputUnusedADCObjects "ica policy" "Gateway SmartControl Policies"
outputUnusedADCObjects "vpn url" "Gateway Bookmarks"
outputUnusedADCObjects "vpn nextHopServer" "NetScaler Gateway Next Hop Servers"
outputUnusedADCObjects "dns view" "DNS Views"
outputUnusedADCObjects "dns action" "DNS Actions"
outputUnusedADCObjects "dns policy" "DNS Policies"
outputUnusedADCObjects "gslb service" "GSLB Services"
outputUnusedADCObjects "cr policy" "Cache Redirection Policies"


if ($textEditor -and ($outputFile -and ($outputFile -ne "screen"))) {    

    # Open Text Editor

    if (Test-Path $textEditor -PathType Leaf){

        write-host "`nOpening Output file `"$outputFile`" using `"$textEditor`" ..."

        start-process -FilePath $textEditor -ArgumentList $outputFile

    } else { 
        write-host "`nText Editor not found: `"$textEditor`"" 
        write-host "`nCan't open output file: `"$outputFile`""
    }

}
