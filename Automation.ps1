# Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force

# Requires -Module ActiveDirectory
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [ValidateSet("Workstation", "Server")]
    [string]$TargetMode = "Workstation"
)

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# =========================================================================
# Variables
# =========================================================================

$QualysUsername = "<your-api-username>"
$QualysPlatform = "<qualysapi.qualys.com>"
$SecretPath     = "<path-to-secret-enc>"

$DnsSuffix       = "<foo.bar>"
$OUMenuSearchBase = "<DC=foo,DC=bar>"

$WorkstationADGroupDN = "<CN=workstations-group-name,OU=xyz,OU=abc,DC=foo,DC=bar>"
$ServerADGroupDN      = "<CN=servers-group-name,OU=xyz,OU=abc,DC=foo,DC=bar>"

$WorkstationQualysTag = "<qualys-workstations-tag-group>"
$ServerQualysTag      = "<qualys-servers-tag-group>"

$WorkstationOUFileName = "<list-of-workstation-ous.txt>"
$ServerOUFileName      = "<list-of-server-ous.txt>"

# =========================================================================
# Config
# =========================================================================

$EnvironmentConfig = @{
    "Workstation" = @{
        "ADGroupDN"   = $WorkstationADGroupDN
        "QualysTag"   = $WorkstationQualysTag
        "OUFileName"  = $WorkstationOUFileName
        "FilterMatch" = "Server"
        "SkipOnMatch" = $true
        "LabelMatch"  = "workstations"
        "LabelSkip"   = "servers"
    }

    "Server" = @{
        "ADGroupDN"   = $ServerADGroupDN
        "QualysTag"   = $ServerQualysTag
        "OUFileName"  = $ServerOUFileName
        "FilterMatch" = "Server"
        "SkipOnMatch" = $false
        "LabelMatch"  = "servers"
        "LabelSkip"   = "workstations"
    }
}

$ActiveProfile = $EnvironmentConfig[$TargetMode]

if (-not (Test-Path $SecretPath)) {
    Throw "Error: Encrypted Qualys key not found at $SecretPath. Run the Saver script first."
}

try {
    $QualysPassword = Get-Content -Path $SecretPath | ConvertTo-SecureString
    
    $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($QualysPassword)
    $PlaintextQualysKey = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
    
    Write-Host "[INIT] Qualys API Key loaded hands-free into memory." -ForegroundColor Green
}
catch {
    $CurrentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    Write-Error "Decryption Failed! The current user ($CurrentUser) is not authorized to decrypt this file."
    Throw
}

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $ScriptDir) { $ScriptDir = Get-Location }

$OUListFile = Join-Path $ScriptDir $ActiveProfile.OUFileName
$LogFile    = Join-Path $ScriptDir "sync_log.txt"

function Log-Message {
    param(
        [string]$Message,
        [string]$Color = "White"
    )
    $TimeStamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $FormattedMessage = "[$TimeStamp] $Message"
    $FormattedMessage | Out-File -FilePath $LogFile -Append -Encoding utf8
    Write-Host $FormattedMessage -ForegroundColor $Color
}

# --- MAIN EXECUTION START ---
$DateHeader = Get-Date -Format "dddd, MMMM dd, yyyy"
Log-Message "=========================================================" "Cyan"
Log-Message "STARTING AUTOMATED HOSTNAME SYNC IN [$($TargetMode.ToUpper())] MODE" "Cyan"
Log-Message "Run Date: $DateHeader" "Cyan"
Log-Message "=========================================================" "Cyan"

if (-not (Test-Path $OUListFile)) {
    Log-Message "CRITICAL ERROR: Expected configuration file not found at '$OUListFile'. Exiting." "Red"
    Exit
}

$SourceOUNames = Get-Content -Path $OUListFile | Where-Object { $_ -match '\S' } | ForEach-Object { $_.Trim() }

if (-not $SourceOUNames) {
    Log-Message "WARNING: The text configuration file '$($ActiveProfile.OUFileName)' is empty. No tracking targets compiled." "Yellow"
    Exit
}

try {
    $TargetGroup = Get-ADGroup -Identity $ActiveProfile.ADGroupDN -ErrorAction Stop
} catch {
    Log-Message "CRITICAL ERROR: Active Directory could not locate the group via DN: $($ActiveProfile.ADGroupDN). Exiting script." "Red"
    Exit
}

$InitialMembers = Get-ADGroupMember -Identity $TargetGroup | Where-Object { $_.objectClass -eq "computer" }
$InitialCount   = ($InitialMembers | Measure-Object).Count

$CurrentMemberDNs = @{}
foreach ($member in $InitialMembers) { $CurrentMemberDNs[$member.DistinguishedName] = $true }

Log-Message "Target Active Directory Group Name: $($TargetGroup.Name)" "Gray"
Log-Message "Total group computer count BEFORE OU delta processing: $InitialCount" "Gray"

$GlobalAddedCount = 0
$GlobalFailedCount = 0

# 2. Process each OU
foreach ($OUName in $SourceOUNames) {
    $OU = Get-ADOrganizationalUnit -Filter "Name -eq '$OUName'" -SearchBase $OUMenuSearchBase -SearchScope OneLevel
    if (-not $OU) {
        Log-Message " -> WARNING: OU '$OUName' was not found directly under $OUMenuSearchBase. Skipping." "Yellow"
        continue
    }

    $OUComputers = Get-ADComputer -Filter * -SearchBase $OU.DistinguishedName -SearchScope Subtree -Properties OperatingSystem

    $NewDevices = [System.Collections.Generic.List[Object]]::new()
    $MatchedOSCount = 0
    $SkippedOSCount = 0

    foreach ($computer in $OUComputers) {
        $OSName = if ($computer.OperatingSystem) { $computer.OperatingSystem } else { "UNKNOWN" }
        $IsServerOS = $OSName -match $ActiveProfile.FilterMatch

        if ($IsServerOS -eq $ActiveProfile.SkipOnMatch) {
            $SkippedOSCount++
            continue
        }

        $MatchedOSCount++

        if (-not $CurrentMemberDNs.ContainsKey($computer.DistinguishedName)) {
            $NewDevices.Add($computer)
        }
    }

    Log-Message " -> Analyzing OU Context: $OUName (Found $MatchedOSCount valid $($ActiveProfile.LabelMatch), skipped $SkippedOSCount $($ActiveProfile.LabelSkip))" "White"

    # 3. Add Net-New Devices to the AD Group
    if ($NewDevices.Count -gt 0) {
        Log-Message "    -> Found $($NewDevices.Count) missing device(s). Syncing entries..." "Green"
        foreach ($device in $NewDevices) {
            try {
                Add-ADGroupMember -Identity $TargetGroup -Members $device.DistinguishedName -ErrorAction Stop
                Log-Message "       [AD ADDED SUCCESS]: $($device.Name)" "Green"
                $GlobalAddedCount++
            } catch {
                Log-Message "       [AD ADDED FAILED]: Could not register '$($device.Name)'. Error Details: $_" "Red"
                $GlobalFailedCount++
            }
        }
    } else {
        Log-Message "    -> Status: Active Directory targets match current structural requirements." "Gray"
    }
}

# 4. Final Membership Gathering for Qualys Compilation
$FinalMembers = Get-ADGroupMember -Identity $TargetGroup | Where-Object { $_.objectClass -eq "computer" }
$FinalCount   = ($FinalMembers | Measure-Object).Count

$QualysTargetComputersList = [System.Collections.Generic.List[string]]::new()
foreach ($member in $FinalMembers) {
    $QualysTargetComputersList.Add($member.Name)
}

# 5. Write the Summary Blocks to Log
Log-Message "---------------------------------------------------------" "Cyan"
Log-Message "RUN SUMMARY:" "Cyan"
Log-Message " Total net-new computers added to AD Group during this run: $GlobalAddedCount" "White"
if ($GlobalFailedCount -gt 0) {
    Log-Message " Total AD errors/failures encountered: $GlobalFailedCount" "Red"
}
Log-Message " Total target computers compiled for Qualys verification: $FinalCount" "White"

# --- EXPORT HOSTNAMES TO FILE ---
$HostsFile = Join-Path $ScriptDir "hosts.txt"
if ($QualysTargetComputersList.Count -gt 0) {
    Log-Message "Exporting compiled hostnames to '$HostsFile'..." "Yellow"
    @($QualysTargetComputersList) | Out-File -FilePath $HostsFile -Force -Encoding utf8
} else {
    $null | Out-File -FilePath $HostsFile -Force
}

# --- QUALYS API AUTOMATED TAGGING INTEGRATION ---
if ($QualysTargetComputersList.Count -gt 0) {
    Log-Message "Initiating optimized Hostname-based Qualys tagging process for $($QualysTargetComputersList.Count) devices..." "Yellow"

    $BasicAuthString = [System.Text.Encoding]::UTF8.GetBytes("${QualysUsername}:${PlaintextQualysKey}")
    $BasicAuthBase64Encoded = [System.Convert]::ToBase64String($BasicAuthString)
    
    $Headers = @{ 
        'Authorization'    = "Basic $BasicAuthBase64Encoded"
        'X-Requested-With' = "QualysPostman" 
    }

    # ==========================================
    # STEP A: FETCH TARGET TAG ID BY NAME
    # ==========================================
    $TagSearchURL = "https://$QualysPlatform/qps/rest/2.0/search/am/tag"
    $TagSearchPayload = "<ServiceRequest><filters><Criteria field=`"name`" operator=`"EQUALS`">$($ActiveProfile.QualysTag)</Criteria></filters></ServiceRequest>"

    $TargetTagId = $null
    try {
        Log-Message "Searching Qualys for Tag ID matching: '$($ActiveProfile.QualysTag)'..." "Gray"
        $TagResponse = Invoke-WebRequest -Uri $TagSearchURL -Method "Post" -Headers $Headers -ContentType "text/xml" -Body $TagSearchPayload -ErrorAction Stop
        
        [xml]$TagXml = $TagResponse.Content
        $TagNode = $TagXml.SelectSingleNode("//Tag/id")
        
        if ($TagNode -and $TagNode.InnerText) {
            $TargetTagId = $TagNode.InnerText.Trim()
            Log-Message "Successfully resolved target Tag ID: $TargetTagId" "Green"
        } else {
            Log-Message "CRITICAL ERROR: Tag name '$($ActiveProfile.QualysTag)' does not exist in Qualys. Please create it first. Exiting script." "Red"
            Exit
        }
    } catch {
        Log-Message "CRITICAL ERROR: Failed communicating with Qualys Tag Search API: $($_.Exception.Message)" "Red"
        Exit
    }

    # ==========================================
    # STEP B & C: EXHAUSTIVE 4-POINT ASSET NAME SEARCH (DUPLICATE SAFE)
    # ==========================================
    $HostIdsToTag = [System.Collections.Generic.List[string]]::new()
    $SuccessfullyMatchedDevicesCount = 0
    Log-Message "Resolving Active Directory hostnames against the v2 Asset Name index..." "Gray"

    $AssetSearchURL = "https://$QualysPlatform/qps/rest/2.0/search/am/asset"

    foreach ($DeviceName in $QualysTargetComputersList) {
        $CleanName = $DeviceName.Trim()
        $DeviceMatchesFound = 0
        
            $NameVariants = @(
        "$($CleanName.ToLower()).$DnsSuffix",
        "$($CleanName.ToUpper()).$DnsSuffix",
        $CleanName.ToLower(),
        $CleanName.ToUpper()
        )

        Log-Message "-> Evaluating target device entry: [$CleanName]" "Cyan"

        foreach ($NameAttempt in $NameVariants) {
            Log-Message "   [TRYING ASSET NAME QUERY]: '$NameAttempt'" "DarkGray"

            $AssetSearchPayload = "<ServiceRequest><filters><Criteria field=`"name`" operator=`"EQUALS`">$NameAttempt</Criteria></filters></ServiceRequest>"
            
            try {
                $Response = Invoke-WebRequest -Uri $AssetSearchURL -Method "Post" -Headers $Headers -ContentType "text/xml" -Body $AssetSearchPayload -ErrorAction Stop
                
                [xml]$XmlResult = $Response.Content
                $AssetNode = $XmlResult.SelectSingleNode("//Asset")
                
                if ($AssetNode) {
                    $AssetId = $AssetNode.SelectSingleNode("id").InnerText
                    if ($AssetId) {
                        if (-not $HostIdsToTag.Contains([string]$AssetId)) {
                            $HostIdsToTag.Add([string]$AssetId)
                            Log-Message "     >> [SUCCESS MATCH]: Collected Asset ID: $AssetId via string '$NameAttempt'" "Green"
                        }
                        $DeviceMatchesFound++
                    }
                }
            } catch {
                Log-Message "     [API EXCEPTION]: Critical communication error on tracking segment: $($_.Exception.Message)" "Red"
            }
        }
        
        if ($DeviceMatchesFound -eq 0) {
            Log-Message "    [SKIPPED]: All 4 format combinations failed to return an asset for '$CleanName'." "Yellow"
        } else {
            $SuccessfullyMatchedDevicesCount++
            Log-Message "    [STATUS]: Completed evaluation for '$CleanName'. Found $DeviceMatchesFound tracking instance(s)." "Gray"
        }
    }
    
    Log-Message "Final Evaluation Matrix: Matched and verified $($HostIdsToTag.Count) total asset entries inside the Qualys Platform." "Green"

    # ==========================================
    # STEP D: BULK APPLY TAG TO MATCHED HOSTS
    # ==========================================
    if ($HostIdsToTag.Count -gt 0 -and $null -ne $TargetTagId) {
        $HostIdStringString = $HostIdsToTag -join ","
        $BulkUpdateURL = "https://$QualysPlatform/qps/rest/2.0/update/am/hostasset"
        
        $BulkUpdatePayload = @"
<ServiceRequest>
   <filters>
       <Criteria field="id" operator="IN">$HostIdStringString</Criteria>
   </filters>
   <data>
       <HostAsset>
          <tags>
               <add>
                   <TagSimple>
                       <id>$TargetTagId</id>
                   </TagSimple>                    
               </add>
           </tags>
       </HostAsset>
   </data>
</ServiceRequest>
"@

        try {
            Log-Message "Sending bulk application request to update asset tag groups inside Qualys..." "Yellow"
            $UpdateResponse = Invoke-WebRequest -Uri $BulkUpdateURL -Method "Post" -Headers $Headers -ContentType "text/xml; charset=utf-8" -Body $BulkUpdatePayload -ErrorAction Stop
            
            if ($UpdateResponse.Content -match "SUCCESS") {
                Log-Message "SUCCESS: Successfully validated and tagged all verified matches inside your Qualys platform!" "Green"
            } else {
                Log-Message "WARNING: Qualys API processing loop completed, but server response text structure was unverified." "Yellow"
            }
        } catch {
            Log-Message "ERROR: Bulk asset tag update action failed execution sequence: $($_.Exception.Message)" "Red"
        }
    } else {
        Log-Message "Skipping batch modification: zero valid host IDs compiled or target Tag ID is empty." "Yellow"
    }

    # Final Success Metrics block
    Log-Message "---------------------------------------------------------" "Cyan"
    Log-Message "QUALYS RESOLUTION FINAL STATISTICS FOR [$($TargetMode.ToUpper())] MODE:" "Cyan"
    Log-Message " [$SuccessfullyMatchedDevicesCount/$($QualysTargetComputersList.Count) worked]" "Green"
    Log-Message "---------------------------------------------------------" "Cyan"

} else {
    Log-Message "Target Active Directory group is entirely empty; skipping Qualys API updates." "Gray"
}

Log-Message "=========================================================`n`n" "Cyan"
