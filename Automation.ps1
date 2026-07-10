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
# Environment Configuration
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

# =========================================================================
# Resolve Script Paths
# =========================================================================

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

if (-not $ScriptDir) {
    $ScriptDir = (Get-Location).Path
}

$OUListFile = Join-Path $ScriptDir $ActiveProfile.OUFileName
$LogFile    = Join-Path $ScriptDir "sync_log.txt"
$HostsFile  = Join-Path $ScriptDir "hosts.txt"

# =========================================================================
# Logging Function
# =========================================================================

function Log-Message {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [Parameter(Mandatory = $false)]
        [string]$Color = "White"
    )

    $TimeStamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $FormattedMessage = "[$TimeStamp] $Message"

    $FormattedMessage |
        Out-File -FilePath $LogFile -Append -Encoding utf8

    Write-Host $FormattedMessage -ForegroundColor $Color
}

# =========================================================================
# Load Qualys Credential
# =========================================================================

if (-not (Test-Path -LiteralPath $SecretPath)) {
    throw "Encrypted Qualys credential not found at '$SecretPath'. Run Initialize-QualysPassword.ps1 first."
}

$PlaintextQualysKey = $null
$BSTR = [IntPtr]::Zero

try {
    $QualysPassword = Get-Content -LiteralPath $SecretPath -ErrorAction Stop |
        ConvertTo-SecureString -ErrorAction Stop

    $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR(
        $QualysPassword
    )

    $PlaintextQualysKey =
        [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($BSTR)

    Write-Host "[INIT] Qualys API credential loaded into process memory." `
        -ForegroundColor Green
}
catch {
    $CurrentUser =
        [System.Security.Principal.WindowsIdentity]::GetCurrent().Name

    Write-Error "Credential decryption failed for '$CurrentUser'. $($_.Exception.Message)"
    throw
}
finally {
    if ($BSTR -ne [IntPtr]::Zero) {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)
    }
}

# =========================================================================
# Main Execution Start
# =========================================================================

$DateHeader = Get-Date -Format "dddd, MMMM dd, yyyy"

Log-Message "=========================================================" "Cyan"
Log-Message "STARTING AUTOMATED AD-TO-QUALYS SYNC IN [$($TargetMode.ToUpper())] MODE" "Cyan"
Log-Message "Run Date: $DateHeader" "Cyan"
Log-Message "=========================================================" "Cyan"

# =========================================================================
# Validate OU Configuration File
# =========================================================================

if (-not (Test-Path -LiteralPath $OUListFile)) {
    Log-Message "CRITICAL ERROR: Expected configuration file was not found at '$OUListFile'." "Red"
    exit 1
}

$SourceOUNames = @(
    Get-Content -LiteralPath $OUListFile -ErrorAction Stop |
        Where-Object { $_ -match "\S" } |
        ForEach-Object { $_.Trim() } |
        Sort-Object -Unique
)

if ($SourceOUNames.Count -eq 0) {
    Log-Message "CRITICAL ERROR: '$($ActiveProfile.OUFileName)' is empty. No OU scope can be compiled." "Red"
    exit 1
}

Log-Message "Loaded $($SourceOUNames.Count) configured OU target(s) from '$($ActiveProfile.OUFileName)'." "Gray"

# =========================================================================
# Resolve Target Active Directory Group
# =========================================================================

try {
    $TargetGroup = Get-ADGroup `
        -Identity $ActiveProfile.ADGroupDN `
        -ErrorAction Stop
}
catch {
    Log-Message "CRITICAL ERROR: Active Directory could not resolve group '$($ActiveProfile.ADGroupDN)'." "Red"
    Log-Message "Error details: $($_.Exception.Message)" "Red"
    exit 1
}

# Get direct computer members currently assigned to the group.
try {
    $InitialMembers = @(
        Get-ADGroupMember `
            -Identity $TargetGroup `
            -ErrorAction Stop |
            Where-Object { $_.objectClass -eq "computer" }
    )
}
catch {
    Log-Message "CRITICAL ERROR: Could not enumerate members of '$($TargetGroup.Name)'." "Red"
    Log-Message "Error details: $($_.Exception.Message)" "Red"
    exit 1
}

$InitialCount = $InitialMembers.Count

$CurrentMemberDNs = @{}

foreach ($Member in $InitialMembers) {
    $CurrentMemberDNs[$Member.DistinguishedName] = $Member
}

Log-Message "Target Active Directory group: $($TargetGroup.Name)" "Gray"
Log-Message "Computer membership before reconciliation: $InitialCount" "Gray"

# =========================================================================
# Reconciliation Counters and Collections
# =========================================================================

$GlobalAddedCount   = 0
$GlobalRemovedCount = 0
$GlobalFailedCount  = 0

# Contains every computer that should be a member of the group.
# The distinguished name is used as the key to prevent duplicates.
$DesiredMemberDNs = @{}

# Removal is permitted only when every configured OU can be resolved and
# queried successfully.
$ScopeValidationPassed = $true

# =========================================================================
# Build Authoritative Computer Scope from Configured OUs
# =========================================================================

foreach ($OUName in $SourceOUNames) {
    Log-Message "---------------------------------------------------------" "DarkGray"
    Log-Message "Evaluating configured OU: $OUName" "White"

    # Escape apostrophes before placing the OU name inside the AD filter.
    $EscapedOUName = $OUName.Replace("'", "''")

    try {
        $MatchingOUs = @(
            Get-ADOrganizationalUnit `
                -Filter "Name -eq '$EscapedOUName'" `
                -SearchBase $OUMenuSearchBase `
                -SearchScope OneLevel `
                -ErrorAction Stop
        )
    }
    catch {
        Log-Message " [OU QUERY FAILED]: Could not search for OU '$OUName'." "Red"
        Log-Message " Error details: $($_.Exception.Message)" "Red"

        $ScopeValidationPassed = $false
        continue
    }

    if ($MatchingOUs.Count -eq 0) {
        Log-Message " [OU NOT FOUND]: '$OUName' was not found directly under '$OUMenuSearchBase'." "Red"

        $ScopeValidationPassed = $false
        continue
    }

    if ($MatchingOUs.Count -gt 1) {
        Log-Message " [OU AMBIGUOUS]: Multiple OUs named '$OUName' were returned." "Red"
        Log-Message " OU names in the configuration file must resolve to one unique OU." "Red"

        $ScopeValidationPassed = $false
        continue
    }

    $OU = $MatchingOUs[0]

    try {
        $OUComputers = @(
            Get-ADComputer `
                -Filter * `
                -SearchBase $OU.DistinguishedName `
                -SearchScope Subtree `
                -Properties OperatingSystem `
                -ErrorAction Stop
        )
    }
    catch {
        Log-Message " [OU COMPUTER QUERY FAILED]: Could not enumerate computers in '$OUName'." "Red"
        Log-Message " Error details: $($_.Exception.Message)" "Red"

        $ScopeValidationPassed = $false
        continue
    }

    $MatchedOSCount = 0
    $SkippedOSCount = 0

    foreach ($Computer in $OUComputers) {
        $OSName = if ([string]::IsNullOrWhiteSpace($Computer.OperatingSystem)) {
            "UNKNOWN"
        }
        else {
            $Computer.OperatingSystem
        }

        $IsServerOS = $OSName -match $ActiveProfile.FilterMatch

        # Workstation mode skips systems whose OS contains "Server".
        # Server mode skips systems whose OS does not contain "Server".
        if ($IsServerOS -eq $ActiveProfile.SkipOnMatch) {
            $SkippedOSCount++
            continue
        }

        $MatchedOSCount++

        $DesiredMemberDNs[$Computer.DistinguishedName] = $Computer
    }

    Log-Message " OU distinguished name: $($OU.DistinguishedName)" "DarkGray"
    Log-Message " Found $MatchedOSCount eligible $($ActiveProfile.LabelMatch)." "White"
    Log-Message " Skipped $SkippedOSCount $($ActiveProfile.LabelSkip)." "Gray"
}

Log-Message "---------------------------------------------------------" "Cyan"
Log-Message "Authoritative eligible computer count: $($DesiredMemberDNs.Count)" "Cyan"

# =========================================================================
# Determine Computers to Add
# =========================================================================

$DevicesToAdd = @(
    foreach ($DesiredDN in $DesiredMemberDNs.Keys) {
        if (-not $CurrentMemberDNs.ContainsKey($DesiredDN)) {
            $DesiredMemberDNs[$DesiredDN]
        }
    }
)

if ($DevicesToAdd.Count -gt 0) {
    Log-Message "Found $($DevicesToAdd.Count) eligible computer(s) missing from the AD group." "Green"

    foreach ($Device in $DevicesToAdd) {
        try {
            Add-ADGroupMember `
                -Identity $TargetGroup `
                -Members $Device.DistinguishedName `
                -ErrorAction Stop

            Log-Message " [AD ADD SUCCESS]: $($Device.Name)" "Green"
            $GlobalAddedCount++
        }
        catch {
            Log-Message " [AD ADD FAILED]: Could not add '$($Device.Name)'." "Red"
            Log-Message " Error details: $($_.Exception.Message)" "Red"

            $GlobalFailedCount++
        }
    }
}
else {
    Log-Message "No eligible computers need to be added to the AD group." "Gray"
}

# =========================================================================
# Determine Computers to Remove
# =========================================================================

if ($ScopeValidationPassed) {
    $DevicesToRemove = @(
        foreach ($Member in $InitialMembers) {
            if (-not $DesiredMemberDNs.ContainsKey($Member.DistinguishedName)) {
                $Member
            }
        }
    )

    if ($DevicesToRemove.Count -gt 0) {
        Log-Message "Found $($DevicesToRemove.Count) existing group member(s) outside the authoritative OU scope." "Yellow"

        foreach ($Device in $DevicesToRemove) {
            try {
                Remove-ADGroupMember `
                    -Identity $TargetGroup `
                    -Members $Device.DistinguishedName `
                    -Confirm:$false `
                    -ErrorAction Stop

                Log-Message " [AD REMOVE SUCCESS]: $($Device.Name)" "Yellow"
                $GlobalRemovedCount++
            }
            catch {
                Log-Message " [AD REMOVE FAILED]: Could not remove '$($Device.Name)'." "Red"
                Log-Message " Error details: $($_.Exception.Message)" "Red"

                $GlobalFailedCount++
            }
        }
    }
    else {
        Log-Message "No existing group members have fallen outside the configured OU scope." "Gray"
    }
}
else {
    Log-Message "SAFETY LOCK ENABLED: At least one configured OU could not be fully validated." "Red"
    Log-Message "No computers will be removed from the AD group during this run." "Red"
}

# =========================================================================
# Gather Final AD Group Membership
# =========================================================================

try {
    $FinalMembers = @(
        Get-ADGroupMember `
            -Identity $TargetGroup `
            -ErrorAction Stop |
            Where-Object { $_.objectClass -eq "computer" }
    )
}
catch {
    Log-Message "CRITICAL ERROR: Could not retrieve final group membership after reconciliation." "Red"
    Log-Message "Error details: $($_.Exception.Message)" "Red"
    exit 1
}

$FinalCount = $FinalMembers.Count

$QualysTargetComputersList =
    [System.Collections.Generic.List[string]]::new()

foreach ($Member in $FinalMembers) {
    if (-not [string]::IsNullOrWhiteSpace($Member.Name)) {
        $QualysTargetComputersList.Add($Member.Name)
    }
}

# =========================================================================
# AD Reconciliation Summary
# =========================================================================

Log-Message "---------------------------------------------------------" "Cyan"
Log-Message "ACTIVE DIRECTORY RECONCILIATION SUMMARY:" "Cyan"
Log-Message " Initial computer membership: $InitialCount" "White"
Log-Message " Authoritative eligible computer count: $($DesiredMemberDNs.Count)" "White"
Log-Message " Computers added during this run: $GlobalAddedCount" "Green"
Log-Message " Computers removed during this run: $GlobalRemovedCount" "Yellow"
Log-Message " Final computer membership: $FinalCount" "White"

if ($GlobalFailedCount -gt 0) {
    Log-Message " Active Directory operation failures: $GlobalFailedCount" "Red"
}

if (-not $ScopeValidationPassed) {
    Log-Message " Removal safety lock status: ENABLED" "Red"
}
else {
    Log-Message " Removal safety lock status: Not required" "Gray"
}

# =========================================================================
# Export Final Hostnames
# =========================================================================

if ($QualysTargetComputersList.Count -gt 0) {
    Log-Message "Exporting $($QualysTargetComputersList.Count) final hostname(s) to '$HostsFile'." "Yellow"

    @(
        $QualysTargetComputersList |
            Sort-Object -Unique
    ) |
        Out-File `
            -FilePath $HostsFile `
            -Force `
            -Encoding utf8
}
else {
    Log-Message "The reconciled AD group is empty. Writing an empty hosts file." "Yellow"

    $null |
        Out-File `
            -FilePath $HostsFile `
            -Force `
            -Encoding utf8
}

# =========================================================================
# Qualys API Automated Tagging
# =========================================================================

if ($QualysTargetComputersList.Count -gt 0) {
    Log-Message "=========================================================" "Cyan"
    Log-Message "STARTING QUALYS ASSET RESOLUTION AND TAGGING" "Cyan"
    Log-Message "Target asset count: $($QualysTargetComputersList.Count)" "Cyan"
    Log-Message "=========================================================" "Cyan"

    try {
        $BasicAuthString =
            [System.Text.Encoding]::UTF8.GetBytes(
                "${QualysUsername}:${PlaintextQualysKey}"
            )

        $BasicAuthBase64Encoded =
            [System.Convert]::ToBase64String($BasicAuthString)
    }
    catch {
        Log-Message "CRITICAL ERROR: Failed to construct Qualys API authorization header." "Red"
        Log-Message "Error details: $($_.Exception.Message)" "Red"
        exit 1
    }
    finally {
        $PlaintextQualysKey = $null
    }

    $Headers = @{
        "Authorization"    = "Basic $BasicAuthBase64Encoded"
        "X-Requested-With" = "QualysPostman"
    }

    # =====================================================================
    # Step A: Resolve Qualys Tag ID
    # =====================================================================

    $TagSearchURL =
        "https://$QualysPlatform/qps/rest/2.0/search/am/tag"

    $TagSearchPayload = @"
<ServiceRequest>
    <filters>
        <Criteria field="name" operator="EQUALS">$($ActiveProfile.QualysTag)</Criteria>
    </filters>
</ServiceRequest>
"@

    $TargetTagId = $null

    try {
        Log-Message "Searching Qualys for tag '$($ActiveProfile.QualysTag)'." "Gray"

        $TagResponse = Invoke-WebRequest `
            -Uri $TagSearchURL `
            -Method Post `
            -Headers $Headers `
            -ContentType "text/xml" `
            -Body $TagSearchPayload `
            -ErrorAction Stop

        [xml]$TagXml = $TagResponse.Content

        $TagNode = $TagXml.SelectSingleNode("//Tag/id")

        if ($TagNode -and -not [string]::IsNullOrWhiteSpace($TagNode.InnerText)) {
            $TargetTagId = $TagNode.InnerText.Trim()

            Log-Message "Resolved Qualys tag ID: $TargetTagId" "Green"
        }
        else {
            Log-Message "CRITICAL ERROR: Qualys tag '$($ActiveProfile.QualysTag)' was not found." "Red"
            exit 1
        }
    }
    catch {
        Log-Message "CRITICAL ERROR: Qualys tag search failed." "Red"
        Log-Message "Error details: $($_.Exception.Message)" "Red"
        exit 1
    }

    # =====================================================================
    # Steps B and C: Resolve AD Hostnames to Qualys Asset IDs
    # =====================================================================

    $HostIdsToTag =
        [System.Collections.Generic.HashSet[string]]::new(
            [System.StringComparer]::OrdinalIgnoreCase
        )

    $SuccessfullyMatchedDevicesCount = 0

    $AssetSearchURL =
        "https://$QualysPlatform/qps/rest/2.0/search/am/asset"

    Log-Message "Resolving AD hostnames against the Qualys Asset Management index." "Gray"

    foreach ($DeviceName in $QualysTargetComputersList) {
        $CleanName = $DeviceName.Trim()

        if ([string]::IsNullOrWhiteSpace($CleanName)) {
            continue
        }

        $DeviceMatchesFound = 0

        $NameVariants = @(
            "$($CleanName.ToLowerInvariant()).$DnsSuffix"
            "$($CleanName.ToUpperInvariant()).$DnsSuffix"
            $CleanName.ToLowerInvariant()
            $CleanName.ToUpperInvariant()
        ) | Sort-Object -Unique

        Log-Message "Evaluating Qualys asset name variants for [$CleanName]." "Cyan"

        foreach ($NameAttempt in $NameVariants) {
            Log-Message " [ASSET QUERY]: '$NameAttempt'" "DarkGray"

            $AssetSearchPayload = @"
<ServiceRequest>
    <filters>
        <Criteria field="name" operator="EQUALS">$NameAttempt</Criteria>
    </filters>
</ServiceRequest>
"@

            try {
                $Response = Invoke-WebRequest `
                    -Uri $AssetSearchURL `
                    -Method Post `
                    -Headers $Headers `
                    -ContentType "text/xml" `
                    -Body $AssetSearchPayload `
                    -ErrorAction Stop

                [xml]$XmlResult = $Response.Content

                # Select every Asset returned rather than only the first one.
                $AssetNodes = @(
                    $XmlResult.SelectNodes("//Asset")
                )

                foreach ($AssetNode in $AssetNodes) {
                    $AssetIdNode = $AssetNode.SelectSingleNode("id")

                    if (
                        $AssetIdNode -and
                        -not [string]::IsNullOrWhiteSpace($AssetIdNode.InnerText)
                    ) {
                        $AssetId = $AssetIdNode.InnerText.Trim()

                        $WasAdded = $HostIdsToTag.Add($AssetId)

                        if ($WasAdded) {
                            Log-Message "  [SUCCESS MATCH]: Collected asset ID $AssetId using '$NameAttempt'." "Green"
                        }
                        else {
                            Log-Message "  [DUPLICATE MATCH]: Asset ID $AssetId was already collected." "DarkGray"
                        }

                        $DeviceMatchesFound++
                    }
                }
            }
            catch {
                Log-Message "  [API EXCEPTION]: Asset lookup failed for '$NameAttempt'." "Red"
                Log-Message "  Error details: $($_.Exception.Message)" "Red"
            }
        }

        if ($DeviceMatchesFound -eq 0) {
            Log-Message " [QUALYS ASSET NOT FOUND]: No asset was returned for '$CleanName'." "Yellow"
        }
        else {
            $SuccessfullyMatchedDevicesCount++

            Log-Message " [DEVICE RESOLVED]: '$CleanName' returned $DeviceMatchesFound matching asset record(s)." "Gray"
        }
    }

    Log-Message "Qualys resolution collected $($HostIdsToTag.Count) unique asset ID(s)." "Green"

    # =====================================================================
    # Step D: Bulk Apply Qualys Tag
    # =====================================================================

    if (
        $HostIdsToTag.Count -gt 0 -and
        -not [string]::IsNullOrWhiteSpace($TargetTagId)
    ) {
        $HostIdString = @($HostIdsToTag) -join ","

        $BulkUpdateURL =
            "https://$QualysPlatform/qps/rest/2.0/update/am/hostasset"

        $BulkUpdatePayload = @"
<ServiceRequest>
    <filters>
        <Criteria field="id" operator="IN">$HostIdString</Criteria>
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
            Log-Message "Applying Qualys tag '$($ActiveProfile.QualysTag)' to $($HostIdsToTag.Count) asset(s)." "Yellow"

            $UpdateResponse = Invoke-WebRequest `
                -Uri $BulkUpdateURL `
                -Method Post `
                -Headers $Headers `
                -ContentType "text/xml; charset=utf-8" `
                -Body $BulkUpdatePayload `
                -ErrorAction Stop

            if ($UpdateResponse.Content -match "SUCCESS") {
                Log-Message "SUCCESS: Qualys accepted the bulk asset tag update." "Green"
            }
            else {
                Log-Message "WARNING: Qualys returned a response, but an explicit SUCCESS value was not detected." "Yellow"
                Log-Message "Response content: $($UpdateResponse.Content)" "DarkGray"
            }
        }
        catch {
            Log-Message "ERROR: Qualys bulk tag update failed." "Red"
            Log-Message "Error details: $($_.Exception.Message)" "Red"
        }
    }
    else {
        Log-Message "Skipping Qualys bulk update because no asset IDs or tag ID were available." "Yellow"
    }

    # =====================================================================
    # Qualys Summary
    # =====================================================================

    Log-Message "---------------------------------------------------------" "Cyan"
    Log-Message "QUALYS RESOLUTION SUMMARY FOR [$($TargetMode.ToUpper())] MODE:" "Cyan"
    Log-Message " AD computers evaluated: $($QualysTargetComputersList.Count)" "White"
    Log-Message " AD computers with at least one Qualys match: $SuccessfullyMatchedDevicesCount" "Green"
    Log-Message " Unique Qualys asset IDs collected: $($HostIdsToTag.Count)" "White"
    Log-Message " Target Qualys tag: $($ActiveProfile.QualysTag)" "White"
    Log-Message "---------------------------------------------------------" "Cyan"
}
else {
    Log-Message "The target AD group is empty after reconciliation. Qualys tagging was skipped." "Gray"
}

# =========================================================================
# Completion
# =========================================================================

Log-Message "=========================================================" "Cyan"
Log-Message "AUTOMATION COMPLETED IN [$($TargetMode.ToUpper())] MODE" "Cyan"
Log-Message "=========================================================`n" "Cyan"
