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
    Workstation = @{
        ADGroupDN   = $WorkstationADGroupDN
        QualysTag   = $WorkstationQualysTag
        OUFileName  = $WorkstationOUFileName
        FilterMatch = "Server"
        SkipOnMatch = $true
        LabelMatch  = "workstations"
        LabelSkip   = "servers"
    }

    Server = @{
        ADGroupDN   = $ServerADGroupDN
        QualysTag   = $ServerQualysTag
        OUFileName  = $ServerOUFileName
        FilterMatch = "Server"
        SkipOnMatch = $false
        LabelMatch  = "servers"
        LabelSkip   = "workstations"
    }
}

$ActiveProfile = $EnvironmentConfig[$TargetMode]

# =========================================================================
# Paths
# =========================================================================

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

if (-not $ScriptDir) {
    $ScriptDir = (Get-Location).Path
}

$OUListFile = Join-Path $ScriptDir $ActiveProfile.OUFileName
$LogFile    = Join-Path $ScriptDir "sync_log.txt"
$HostsFile  = Join-Path $ScriptDir "hosts.txt"

# =========================================================================
# Logging
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
# XML Escaping
# =========================================================================

function ConvertTo-XmlSafeText {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Value
    )

    return [System.Security.SecurityElement]::Escape($Value)
}

# =========================================================================
# Qualys Asset Resolution
# =========================================================================

function Resolve-QualysAssetIds {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$ComputerNames,

        [Parameter(Mandatory = $true)]
        [hashtable]$Headers,

        [Parameter(Mandatory = $true)]
        [string]$QualysPlatform,

        [Parameter(Mandatory = $true)]
        [string]$DnsSuffix,

        [Parameter(Mandatory = $true)]
        [string]$OperationLabel
    )

    $AssetIds =
        [System.Collections.Generic.HashSet[string]]::new(
            [System.StringComparer]::OrdinalIgnoreCase
        )

    $MatchedComputerCount = 0
    $AssetSearchURL = "https://$QualysPlatform/qps/rest/2.0/search/am/asset"

    foreach ($ComputerName in $ComputerNames) {
        $CleanName = $ComputerName.Trim()

        if ([string]::IsNullOrWhiteSpace($CleanName)) {
            continue
        }

        $DeviceMatchesFound = 0

        $NameVariants = @(
            "$($CleanName.ToLowerInvariant()).$DnsSuffix"
            "$($CleanName.ToUpperInvariant()).$DnsSuffix"
            $CleanName.ToLowerInvariant()
            $CleanName.ToUpperInvariant()
        )

        Log-Message "[$OperationLabel] Evaluating device: $CleanName" "Cyan"

        foreach ($NameAttempt in $NameVariants) {
            Log-Message "   [TRYING ASSET NAME QUERY]: '$NameAttempt'" "DarkGray"

            $SafeNameAttempt = ConvertTo-XmlSafeText -Value $NameAttempt

            $AssetSearchPayload = @"
<ServiceRequest>
    <filters>
        <Criteria field="name" operator="EQUALS">$SafeNameAttempt</Criteria>
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

                        if ($AssetIds.Add($AssetId)) {
                            Log-Message "      [SUCCESS MATCH]: Collected Asset ID $AssetId using '$NameAttempt'." "Green"
                        }
                        else {
                            Log-Message "      [DUPLICATE MATCH]: Asset ID $AssetId was already collected." "DarkGray"
                        }

                        $DeviceMatchesFound++
                    }
                }
            }
            catch {
                Log-Message "      [API EXCEPTION]: Query failed for '$NameAttempt'." "Red"
                Log-Message "      Error details: $($_.Exception.Message)" "Red"
            }
        }

        if ($DeviceMatchesFound -eq 0) {
            Log-Message "   [QUALYS ASSET NOT FOUND]: All four queries failed for '$CleanName'." "Yellow"
        }
        else {
            $MatchedComputerCount++

            Log-Message "   [DEVICE RESOLVED]: '$CleanName' produced $DeviceMatchesFound matching result(s)." "Gray"
        }
    }

    return [pscustomobject]@{
        AssetIds             = $AssetIds
        MatchedComputerCount = $MatchedComputerCount
        ComputerCount        = $ComputerNames.Count
    }
}

# =========================================================================
# Qualys Tag Update
# =========================================================================

function Update-QualysAssetTag {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("Add", "Remove")]
        [string]$Action,

        [Parameter(Mandatory = $true)]
        [System.Collections.Generic.HashSet[string]]$AssetIds,

        [Parameter(Mandatory = $true)]
        [string]$TagId,

        [Parameter(Mandatory = $true)]
        [string]$TagName,

        [Parameter(Mandatory = $true)]
        [hashtable]$Headers,

        [Parameter(Mandatory = $true)]
        [string]$QualysPlatform
    )

    if ($AssetIds.Count -eq 0) {
        Log-Message "Skipping Qualys tag $($Action.ToLower()) operation because no asset IDs were collected." "Gray"
        return $false
    }

    $HostIdString = @($AssetIds) -join ","
    $BulkUpdateURL = "https://$QualysPlatform/qps/rest/2.0/update/am/hostasset"

    $SafeTagId = ConvertTo-XmlSafeText -Value $TagId

    $TagOperationXml = switch ($Action) {
        "Add" {
@"
<add>
    <TagSimple>
        <id>$SafeTagId</id>
    </TagSimple>
</add>
"@
        }

        "Remove" {
@"
<remove>
    <TagSimple>
        <id>$SafeTagId</id>
    </TagSimple>
</remove>
"@
        }
    }

    $BulkUpdatePayload = @"
<ServiceRequest>
    <filters>
        <Criteria field="id" operator="IN">$HostIdString</Criteria>
    </filters>
    <data>
        <HostAsset>
            <tags>
                $TagOperationXml
            </tags>
        </HostAsset>
    </data>
</ServiceRequest>
"@

    try {
        Log-Message "$Action Qualys tag '$TagName' for $($AssetIds.Count) asset(s)." "Yellow"

        $UpdateResponse = Invoke-WebRequest `
            -Uri $BulkUpdateURL `
            -Method Post `
            -Headers $Headers `
            -ContentType "text/xml; charset=utf-8" `
            -Body $BulkUpdatePayload `
            -ErrorAction Stop

        if ($UpdateResponse.Content -match "SUCCESS") {
            Log-Message "SUCCESS: Qualys accepted the tag $($Action.ToLower()) request." "Green"
            return $true
        }

        Log-Message "WARNING: Qualys returned a response without an explicit SUCCESS result." "Yellow"
        Log-Message "Response content: $($UpdateResponse.Content)" "DarkGray"

        return $false
    }
    catch {
        Log-Message "ERROR: Qualys tag $($Action.ToLower()) request failed." "Red"
        Log-Message "Error details: $($_.Exception.Message)" "Red"

        return $false
    }
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
    $QualysPassword = Get-Content `
        -LiteralPath $SecretPath `
        -ErrorAction Stop |
        ConvertTo-SecureString `
            -ErrorAction Stop

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
# Main Execution
# =========================================================================

$DateHeader = Get-Date -Format "dddd, MMMM dd, yyyy"

Log-Message "=========================================================" "Cyan"
Log-Message "STARTING AUTOMATED AD-TO-QUALYS SYNC IN [$($TargetMode.ToUpper())] MODE" "Cyan"
Log-Message "Run Date: $DateHeader" "Cyan"
Log-Message "=========================================================" "Cyan"

# =========================================================================
# Validate OU Configuration
# =========================================================================

if (-not (Test-Path -LiteralPath $OUListFile)) {
    Log-Message "CRITICAL ERROR: Configuration file not found at '$OUListFile'." "Red"
    exit 1
}

try {
    $SourceOUNames = @(
        Get-Content `
            -LiteralPath $OUListFile `
            -ErrorAction Stop |
            Where-Object { $_ -match "\S" } |
            ForEach-Object { $_.Trim() } |
            Sort-Object -Unique
    )
}
catch {
    Log-Message "CRITICAL ERROR: Could not read '$OUListFile'." "Red"
    Log-Message "Error details: $($_.Exception.Message)" "Red"
    exit 1
}

if ($SourceOUNames.Count -eq 0) {
    Log-Message "CRITICAL ERROR: '$($ActiveProfile.OUFileName)' is empty." "Red"
    exit 1
}

Log-Message "Loaded $($SourceOUNames.Count) configured OU target(s)." "Gray"

# =========================================================================
# Resolve AD Group and Current Membership
# =========================================================================

try {
    $TargetGroup = Get-ADGroup `
        -Identity $ActiveProfile.ADGroupDN `
        -ErrorAction Stop

    $InitialMembers = @(
        Get-ADGroupMember `
            -Identity $TargetGroup `
            -ErrorAction Stop |
            Where-Object { $_.objectClass -eq "computer" }
    )
}
catch {
    Log-Message "CRITICAL ERROR: Could not resolve the AD group or enumerate its membership." "Red"
    Log-Message "Error details: $($_.Exception.Message)" "Red"
    exit 1
}

$InitialCount = $InitialMembers.Count

$CurrentMemberDNs = @{}

foreach ($Member in $InitialMembers) {
    $CurrentMemberDNs[$Member.DistinguishedName] = $Member
}

Log-Message "Target AD group: $($TargetGroup.Name)" "Gray"
Log-Message "Computer membership before reconciliation: $InitialCount" "Gray"

# =========================================================================
# Reconciliation Collections
# =========================================================================

$GlobalAddedCount   = 0
$GlobalRemovedCount = 0
$GlobalFailedCount  = 0

$DesiredMemberDNs = @{}

$SuccessfullyRemovedComputers =
    [System.Collections.Generic.List[object]]::new()

$ScopeValidationPassed = $true

# =========================================================================
# Build Authoritative OU Scope
# =========================================================================

foreach ($OUName in $SourceOUNames) {
    Log-Message "---------------------------------------------------------" "DarkGray"
    Log-Message "Evaluating configured OU: $OUName" "White"

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
        Log-Message " [OU QUERY FAILED]: Could not search for '$OUName'." "Red"
        Log-Message " Error details: $($_.Exception.Message)" "Red"

        $ScopeValidationPassed = $false
        continue
    }

    if ($MatchingOUs.Count -eq 0) {
        Log-Message " [OU NOT FOUND]: '$OUName' was not found under '$OUMenuSearchBase'." "Red"

        $ScopeValidationPassed = $false
        continue
    }

    if ($MatchingOUs.Count -gt 1) {
        Log-Message " [OU AMBIGUOUS]: Multiple OUs named '$OUName' were returned." "Red"

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

        if ($IsServerOS -eq $ActiveProfile.SkipOnMatch) {
            $SkippedOSCount++
            continue
        }

        $MatchedOSCount++
        $DesiredMemberDNs[$Computer.DistinguishedName] = $Computer
    }

    Log-Message " Found $MatchedOSCount eligible $($ActiveProfile.LabelMatch)." "White"
    Log-Message " Skipped $SkippedOSCount $($ActiveProfile.LabelSkip)." "Gray"
}

Log-Message "---------------------------------------------------------" "Cyan"
Log-Message "Authoritative eligible computer count: $($DesiredMemberDNs.Count)" "Cyan"

# =========================================================================
# Add Missing AD Group Members
# =========================================================================

$DevicesToAdd = @(
    foreach ($DesiredDN in $DesiredMemberDNs.Keys) {
        if (-not $CurrentMemberDNs.ContainsKey($DesiredDN)) {
            $DesiredMemberDNs[$DesiredDN]
        }
    }
)

if ($DevicesToAdd.Count -gt 0) {
    Log-Message "Found $($DevicesToAdd.Count) computer(s) missing from the AD group." "Green"

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
# Remove Ineligible AD Group Members
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
        Log-Message "Found $($DevicesToRemove.Count) member(s) outside the authoritative OU scope." "Yellow"

        foreach ($Device in $DevicesToRemove) {
            try {
                Remove-ADGroupMember `
                    -Identity $TargetGroup `
                    -Members $Device.DistinguishedName `
                    -Confirm:$false `
                    -ErrorAction Stop

                Log-Message " [AD REMOVE SUCCESS]: $($Device.Name)" "Yellow"

                $SuccessfullyRemovedComputers.Add($Device)
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
    Log-Message "SAFETY LOCK: At least one configured OU could not be fully validated." "Red"
    Log-Message "No computers were removed from the AD group or Qualys tag." "Red"
}

# =========================================================================
# Final AD Group Membership
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
    Log-Message "CRITICAL ERROR: Could not retrieve final group membership." "Red"
    Log-Message "Error details: $($_.Exception.Message)" "Red"
    exit 1
}

$FinalCount = $FinalMembers.Count

$QualysTargetComputersList = @(
    $FinalMembers |
        Where-Object {
            -not [string]::IsNullOrWhiteSpace($_.Name)
        } |
        ForEach-Object {
            $_.Name
        }
)

$QualysRemovedComputersList = @(
    $SuccessfullyRemovedComputers |
        Where-Object {
            -not [string]::IsNullOrWhiteSpace($_.Name)
        } |
        ForEach-Object {
            $_.Name
        }
)

# =========================================================================
# AD Summary
# =========================================================================

Log-Message "---------------------------------------------------------" "Cyan"
Log-Message "ACTIVE DIRECTORY RECONCILIATION SUMMARY:" "Cyan"
Log-Message " Initial membership: $InitialCount" "White"
Log-Message " Authoritative eligible computers: $($DesiredMemberDNs.Count)" "White"
Log-Message " Computers added: $GlobalAddedCount" "Green"
Log-Message " Computers removed: $GlobalRemovedCount" "Yellow"
Log-Message " Final membership: $FinalCount" "White"

if ($GlobalFailedCount -gt 0) {
    Log-Message " AD operation failures: $GlobalFailedCount" "Red"
}

# =========================================================================
# Export Final Hostnames
# =========================================================================

if ($QualysTargetComputersList.Count -gt 0) {
    $QualysTargetComputersList |
        Sort-Object -Unique |
        Out-File `
            -FilePath $HostsFile `
            -Force `
            -Encoding utf8

    Log-Message "Exported $($QualysTargetComputersList.Count) hostname(s) to '$HostsFile'." "Yellow"
}
else {
    $null |
        Out-File `
            -FilePath $HostsFile `
            -Force `
            -Encoding utf8

    Log-Message "The reconciled AD group is empty. Wrote an empty hosts file." "Yellow"
}

# =========================================================================
# Build Qualys Authorization Header
# =========================================================================

$BasicAuthString =
    [System.Text.Encoding]::UTF8.GetBytes(
        "${QualysUsername}:${PlaintextQualysKey}"
    )

$BasicAuthBase64Encoded =
    [System.Convert]::ToBase64String($BasicAuthString)

$PlaintextQualysKey = $null

$Headers = @{
    Authorization      = "Basic $BasicAuthBase64Encoded"
    "X-Requested-With" = "QualysPostman"
}

# =========================================================================
# Resolve Qualys Tag ID
# =========================================================================

$TargetTagId = $null

if (
    $QualysTargetComputersList.Count -gt 0 -or
    $QualysRemovedComputersList.Count -gt 0
) {
    $TagSearchURL =
        "https://$QualysPlatform/qps/rest/2.0/search/am/tag"

    $SafeTagName =
        ConvertTo-XmlSafeText -Value $ActiveProfile.QualysTag

    $TagSearchPayload = @"
<ServiceRequest>
    <filters>
        <Criteria field="name" operator="EQUALS">$SafeTagName</Criteria>
    </filters>
</ServiceRequest>
"@

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

        if (
            $TagNode -and
            -not [string]::IsNullOrWhiteSpace($TagNode.InnerText)
        ) {
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
}

# =========================================================================
# Resolve and Add Tag to Current AD Group Members
# =========================================================================

$AddResolutionResult = $null
$QualysAddSucceeded = $false

if ($QualysTargetComputersList.Count -gt 0) {
    Log-Message "=========================================================" "Cyan"
    Log-Message "RESOLVING CURRENT AD GROUP MEMBERS FOR QUALYS TAG ADDITION" "Cyan"
    Log-Message "=========================================================" "Cyan"

    $AddResolutionResult = Resolve-QualysAssetIds `
        -ComputerNames $QualysTargetComputersList `
        -Headers $Headers `
        -QualysPlatform $QualysPlatform `
        -DnsSuffix $DnsSuffix `
        -OperationLabel "TAG ADD"

    $QualysAddSucceeded = Update-QualysAssetTag `
        -Action Add `
        -AssetIds $AddResolutionResult.AssetIds `
        -TagId $TargetTagId `
        -TagName $ActiveProfile.QualysTag `
        -Headers $Headers `
        -QualysPlatform $QualysPlatform
}
else {
    Log-Message "No final AD group members exist. Qualys tag addition was skipped." "Gray"
}

# =========================================================================
# Resolve and Remove Tag from Successfully Removed AD Members
# =========================================================================

$RemoveResolutionResult = $null
$QualysRemoveSucceeded = $false

if ($QualysRemovedComputersList.Count -gt 0) {
    Log-Message "=========================================================" "Cyan"
    Log-Message "RESOLVING REMOVED AD MEMBERS FOR QUALYS TAG REMOVAL" "Cyan"
    Log-Message "=========================================================" "Cyan"

    $RemoveResolutionResult = Resolve-QualysAssetIds `
        -ComputerNames $QualysRemovedComputersList `
        -Headers $Headers `
        -QualysPlatform $QualysPlatform `
        -DnsSuffix $DnsSuffix `
        -OperationLabel "TAG REMOVE"

    if ($AddResolutionResult) {
        foreach ($CurrentAssetId in $AddResolutionResult.AssetIds) {
            if ($RemoveResolutionResult.AssetIds.Contains($CurrentAssetId)) {
                $RemoveResolutionResult.AssetIds.Remove($CurrentAssetId) | Out-Null

                Log-Message "SAFETY CHECK: Asset ID $CurrentAssetId exists in the current target set and was excluded from tag removal." "Yellow"
            }
        }
    }

    $QualysRemoveSucceeded = Update-QualysAssetTag `
        -Action Remove `
        -AssetIds $RemoveResolutionResult.AssetIds `
        -TagId $TargetTagId `
        -TagName $ActiveProfile.QualysTag `
        -Headers $Headers `
        -QualysPlatform $QualysPlatform
}
else {
    Log-Message "No computers were successfully removed from AD. Qualys tag removal was skipped." "Gray"
}

# =========================================================================
# Final Summary
# =========================================================================

Log-Message "---------------------------------------------------------" "Cyan"
Log-Message "FINAL AUTOMATION SUMMARY FOR [$($TargetMode.ToUpper())] MODE:" "Cyan"
Log-Message " AD computers added: $GlobalAddedCount" "Green"
Log-Message " AD computers removed: $GlobalRemovedCount" "Yellow"
Log-Message " Final AD group membership: $FinalCount" "White"

if ($AddResolutionResult) {
    Log-Message " Current AD members evaluated in Qualys: $($AddResolutionResult.ComputerCount)" "White"
    Log-Message " Current AD members matched in Qualys: $($AddResolutionResult.MatchedComputerCount)" "Green"
    Log-Message " Unique asset IDs submitted for tag addition: $($AddResolutionResult.AssetIds.Count)" "White"
}

if ($RemoveResolutionResult) {
    Log-Message " Removed AD members evaluated in Qualys: $($RemoveResolutionResult.ComputerCount)" "White"
    Log-Message " Removed AD members matched in Qualys: $($RemoveResolutionResult.MatchedComputerCount)" "Yellow"
    Log-Message " Unique asset IDs submitted for tag removal: $($RemoveResolutionResult.AssetIds.Count)" "White"
}

Log-Message " Qualys tag addition accepted: $QualysAddSucceeded" "White"
Log-Message " Qualys tag removal accepted: $QualysRemoveSucceeded" "White"
Log-Message "=========================================================`n" "Cyan"
