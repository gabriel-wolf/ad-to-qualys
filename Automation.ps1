# Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force

# Requires -Module ActiveDirectory
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [ValidateSet("Workstation", "Server")]
    [string]$TargetMode = "Workstation"
)

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$PSDefaultParameterValues["Invoke-WebRequest:UseBasicParsing"] = $true

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
$QualysResultsCsv = Join-Path $ScriptDir "qualys_tag_failures.csv"

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
# Qualys Tag Resolution
# =========================================================================

function Resolve-QualysTagId {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$TagName,

        [Parameter(Mandatory = $true)]
        [hashtable]$Headers,

        [Parameter(Mandatory = $true)]
        [string]$QualysPlatform,

        [Parameter(Mandatory = $false)]
        [switch]$SuppressNotFoundLog
    )

    $TagSearchURL = "https://$QualysPlatform/qps/rest/2.0/search/am/tag"
    $SafeTagName = ConvertTo-XmlSafeText -Value $TagName

    $TagSearchPayload = @"
<ServiceRequest>
    <filters>
        <Criteria field="name" operator="EQUALS">$SafeTagName</Criteria>
    </filters>
</ServiceRequest>
"@

    try {
        Log-Message "Searching Qualys for tag '$TagName'." "Gray"

        $TagResponse = Invoke-WebRequest `
            -Uri $TagSearchURL `
            -Method Post `
            -Headers $Headers `
            -ContentType "text/xml" `
            -Body $TagSearchPayload `
            -ErrorAction Stop

        [xml]$TagXml = $TagResponse.Content
        $TagNodes = @($TagXml.SelectNodes("//Tag/id"))

        if ($TagNodes.Count -eq 1 -and -not [string]::IsNullOrWhiteSpace($TagNodes[0].InnerText)) {
            $TagId = $TagNodes[0].InnerText.Trim()
            Log-Message "Resolved Qualys tag '$TagName' to ID $TagId." "Green"
            return $TagId
        }

        if ($TagNodes.Count -gt 1) {
            Log-Message "ERROR: Multiple Qualys tags named '$TagName' were returned." "Red"
            return $null
        }

        if (-not $SuppressNotFoundLog) {
            Log-Message "ERROR: Qualys tag '$TagName' was not found." "Red"
        }

        return $null
    }
    catch {
        Log-Message "ERROR: Qualys tag search failed for '$TagName'." "Red"
        Log-Message "Error details: $($_.Exception.Message)" "Red"
        return $null
    }
}

# =========================================================================
# Qualys Department Tag Asset Collection
# =========================================================================

function Get-QualysAssetsByTag {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$TagName,

        [Parameter(Mandatory = $true)]
        [hashtable]$Headers,

        [Parameter(Mandatory = $true)]
        [string]$QualysPlatform,

        [Parameter(Mandatory = $false)]
        [switch]$SuppressNotFoundLog
    )

    $TagId = Resolve-QualysTagId `
        -TagName $TagName `
        -Headers $Headers `
        -QualysPlatform $QualysPlatform `
        -SuppressNotFoundLog:$SuppressNotFoundLog

    if ([string]::IsNullOrWhiteSpace($TagId)) {
        return [pscustomobject]@{
            TagName = $TagName
            TagId   = $null
            Assets  = @()
            Success = $false
        }
    }

    $AssetSearchURL = "https://$QualysPlatform/qps/rest/2.0/search/am/asset"

    $Assets = [System.Collections.Generic.List[object]]::new()

    $CollectedAssetIds = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )

    $HasMoreRecords = $true
    $LastId = $null
    $PageNumber = 1

    while ($HasMoreRecords) {
        $PaginationFilter = if ($null -ne $LastId) {
@"
        <Criteria field="id" operator="GREATER">$LastId</Criteria>
"@
        }
        else {
            ""
        }

        $AssetPayload = @"
<ServiceRequest>
    <preferences>
        <limitResults>1000</limitResults>
    </preferences>
    <filters>
        <Criteria field="tagId" operator="EQUALS">$TagId</Criteria>
$PaginationFilter
    </filters>
</ServiceRequest>
"@

        try {
            Log-Message "[$TagName] Fetching Qualys asset batch $PageNumber." "DarkGray"

            $Response = Invoke-WebRequest `
                -Uri $AssetSearchURL `
                -Method Post `
                -Headers $Headers `
                -ContentType "text/xml" `
                -Body $AssetPayload `
                -ErrorAction Stop

            [xml]$XmlResult = $Response.Content

            $AssetNodes = @(
                $XmlResult.SelectNodes("//Asset")
            )

            foreach ($AssetNode in $AssetNodes) {
                $AssetIdNode = $AssetNode.SelectSingleNode("id")
                $NameNode = $AssetNode.SelectSingleNode("name")

                if (
                    -not $AssetIdNode -or
                    [string]::IsNullOrWhiteSpace($AssetIdNode.InnerText)
                ) {
                    continue
                }

                $AssetId = $AssetIdNode.InnerText.Trim()

                if (-not $CollectedAssetIds.Add($AssetId)) {
                    continue
                }

                $DeviceName = if (
                    $NameNode -and
                    -not [string]::IsNullOrWhiteSpace($NameNode.InnerText)
                ) {
                    $NameNode.InnerText.Trim()
                }
                else {
                    $null
                }

                $Assets.Add(
                    [pscustomobject]@{
                        AssetId   = $AssetId
                        DeviceName = $DeviceName
                    }
                )
            }

            $HasMoreNode = $XmlResult.SelectSingleNode("//hasMoreRecords")
            $LastIdNode = $XmlResult.SelectSingleNode("//lastId")

            $HasMoreRecords = if (
                $HasMoreNode -and
                -not [string]::IsNullOrWhiteSpace($HasMoreNode.InnerText)
            ) {
                [System.Convert]::ToBoolean(
                    $HasMoreNode.InnerText.Trim()
                )
            }
            else {
                $false
            }

            $LastId = if (
                $LastIdNode -and
                -not [string]::IsNullOrWhiteSpace($LastIdNode.InnerText)
            ) {
                $LastIdNode.InnerText.Trim()
            }
            else {
                $null
            }

            if ($HasMoreRecords -and [string]::IsNullOrWhiteSpace($LastId)) {
                Log-Message "ERROR: Qualys indicated more assets for '$TagName' but did not return a last ID." "Red"

                return [pscustomobject]@{
                    TagName = $TagName
                    TagId   = $TagId
                    Assets  = @($Assets)
                    Success = $false
                }
            }

            $PageNumber++
        }
        catch {
            Log-Message "ERROR: Qualys asset search failed for tag '$TagName' on batch $PageNumber." "Red"
            Log-Message "Error details: $($_.Exception.Message)" "Red"

            return [pscustomobject]@{
                TagName = $TagName
                TagId   = $TagId
                Assets  = @($Assets)
                Success = $false
            }
        }
    }

    Log-Message "Collected $($Assets.Count) unique asset(s) from Qualys tag '$TagName'." "Green"

    return [pscustomobject]@{
        TagName = $TagName
        TagId   = $TagId
        Assets  = @($Assets)
        Success = $true
    }
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
    $DeviceResults = [System.Collections.Generic.List[object]]::new()
    $AssetSearchURL = "https://$QualysPlatform/qps/rest/2.0/search/am/asset"

    foreach ($ComputerName in $ComputerNames) {
        $CleanName = $ComputerName.Trim()

        if ([string]::IsNullOrWhiteSpace($CleanName)) {
            continue
        }

        $DeviceMatchesFound = 0
        $DeviceAssetIds = [System.Collections.Generic.HashSet[string]]::new(
            [System.StringComparer]::OrdinalIgnoreCase
        )
        $DeviceErrors = [System.Collections.Generic.List[string]]::new()

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

                        $DeviceAssetIds.Add($AssetId) | Out-Null

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
                $DeviceErrors.Add("$NameAttempt`: $($_.Exception.Message)")
                Log-Message "      [API EXCEPTION]: Query failed for '$NameAttempt'." "Red"
                Log-Message "      Error details: $($_.Exception.Message)" "Red"
            }
        }

        if ($DeviceMatchesFound -eq 0) {
            $FailureReason = if ($DeviceErrors.Count -gt 0) {
                "Qualys asset lookup encountered API errors: $($DeviceErrors -join ' | ')"
            }
            else {
                "No matching Qualys asset was found using any hostname variant."
            }

            Log-Message "   [QUALYS ASSET NOT FOUND]: All four queries failed for '$CleanName'." "Yellow"

            $DeviceResults.Add(
                [pscustomobject]@{
                    ComputerName = $CleanName
                    AssetIds     = @()
                    Success      = $false
                    FailureReason = $FailureReason
                }
            )
        }
        else {
            $MatchedComputerCount++

            Log-Message "   [DEVICE RESOLVED]: '$CleanName' produced $DeviceMatchesFound matching result(s)." "Gray"

            $DeviceResults.Add(
                [pscustomobject]@{
                    ComputerName = $CleanName
                    AssetIds     = @($DeviceAssetIds)
                    Success      = $true
                    FailureReason = ""
                }
            )
        }
    }

    return [pscustomobject]@{
        AssetIds             = $AssetIds
        MatchedComputerCount = $MatchedComputerCount
        ComputerCount        = $ComputerNames.Count
        DeviceResults        = @($DeviceResults)
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

    $SuccessfulAssetIds = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    $FailedAssetIds = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    $FailureReasons = @{}

    if ($AssetIds.Count -eq 0) {
        Log-Message "Skipping Qualys tag $($Action.ToLower()) operation because no asset IDs were collected." "Gray"
        return [pscustomobject]@{
            Success            = $false
            SuccessfulAssetIds = $SuccessfulAssetIds
            FailedAssetIds     = $FailedAssetIds
            FailureReasons     = $FailureReasons
        }
    }

    $BulkUpdateURL = "https://$QualysPlatform/qps/rest/2.0/update/am/hostasset"
    $SafeTagId = ConvertTo-XmlSafeText -Value $TagId
    $BatchSize = 200
    $AssetIdArray = @($AssetIds)
    $BatchCount = [int][Math]::Ceiling($AssetIdArray.Count / [double]$BatchSize)
    $AllBatchesSucceeded = $true

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

    for ($BatchIndex = 0; $BatchIndex -lt $BatchCount; $BatchIndex++) {
        $StartIndex = $BatchIndex * $BatchSize
        $RemainingCount = $AssetIdArray.Count - $StartIndex
        $CurrentBatchSize = [Math]::Min($BatchSize, $RemainingCount)

        $BatchAssetIds = @(
            $AssetIdArray |
                Select-Object `
                    -Skip $StartIndex `
                    -First $CurrentBatchSize
        )

        $HostIdString = $BatchAssetIds -join ","

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
            Log-Message "$Action Qualys tag '$TagName' for batch $($BatchIndex + 1) of $BatchCount containing $($BatchAssetIds.Count) asset(s)." "Yellow"

            $UpdateResponse = Invoke-WebRequest `
                -Uri $BulkUpdateURL `
                -Method Post `
                -Headers $Headers `
                -ContentType "text/xml; charset=utf-8" `
                -Body $BulkUpdatePayload `
                -ErrorAction Stop

            if ($UpdateResponse.Content -match "SUCCESS") {
                foreach ($AssetId in $BatchAssetIds) {
                    $SuccessfulAssetIds.Add($AssetId) | Out-Null
                }

                Log-Message "SUCCESS: Qualys accepted batch $($BatchIndex + 1) of $BatchCount." "Green"
            }
            else {
                $FailureReason = "Qualys returned no explicit SUCCESS result for batch $($BatchIndex + 1) of $BatchCount."

                foreach ($AssetId in $BatchAssetIds) {
                    $FailedAssetIds.Add($AssetId) | Out-Null
                    $FailureReasons[$AssetId] = $FailureReason
                }

                Log-Message "WARNING: $FailureReason" "Yellow"
                Log-Message "Response content: $($UpdateResponse.Content)" "DarkGray"
                $AllBatchesSucceeded = $false
            }
        }
        catch {
            $FailureReason = "Qualys tag $($Action.ToLower()) failed for batch $($BatchIndex + 1) of $($BatchCount): $($_.Exception.Message)"

            foreach ($AssetId in $BatchAssetIds) {
                $FailedAssetIds.Add($AssetId) | Out-Null
                $FailureReasons[$AssetId] = $FailureReason
            }

            Log-Message "ERROR: Qualys tag $($Action.ToLower()) failed for batch $($BatchIndex + 1) of $BatchCount." "Red"
            Log-Message "Error details: $($_.Exception.Message)" "Red"
            $AllBatchesSucceeded = $false
        }
    }

    return [pscustomobject]@{
        Success            = $AllBatchesSucceeded
        SuccessfulAssetIds = $SuccessfulAssetIds
        FailedAssetIds     = $FailedAssetIds
        FailureReasons     = $FailureReasons
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
$ComputerDepartmentMap = @{}

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

        if (-not $ComputerDepartmentMap.ContainsKey($Computer.Name)) {
            $ComputerDepartmentMap[$Computer.Name] = [System.Collections.Generic.List[string]]::new()
        }

        if (-not $ComputerDepartmentMap[$Computer.Name].Contains($OUName)) {
            $ComputerDepartmentMap[$Computer.Name].Add($OUName)
        }
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
# Resolve Qualys Target Tag ID
# =========================================================================

$TargetTagId = $null

if (
    $QualysTargetComputersList.Count -gt 0 -or
    $QualysRemovedComputersList.Count -gt 0
) {
    $TargetTagId = Resolve-QualysTagId `
        -TagName $ActiveProfile.QualysTag `
        -Headers $Headers `
        -QualysPlatform $QualysPlatform

    if ([string]::IsNullOrWhiteSpace($TargetTagId)) {
        Log-Message "CRITICAL ERROR: Could not resolve target Qualys tag '$($ActiveProfile.QualysTag)'." "Red"
        exit 1
    }
}

# =========================================================================
# Add Target Tag from Department Tags and Resolve Stragglers
# =========================================================================

$DepartmentTagAssetIds = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase
)

$DepartmentMatchedComputerNames = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase
)

$CurrentTargetAssetIds = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase
)

$FinalComputerNameSet = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase
)

$DeviceAssetIdsMap = @{}
$DeviceDepartmentMap = @{}
$DeviceResolutionFailureMap = @{}
$SuccessfulTagAssetIds = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase
)
$FailedTagAssetIds = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase
)
$TagFailureReasons = @{}

foreach ($ComputerName in $QualysTargetComputersList) {
    $FinalComputerNameSet.Add($ComputerName) | Out-Null
}

$DepartmentTagSearchCount = 0
$DepartmentTagSearchFailureCount = 0
$DepartmentTagAssetsEvaluated = 0
$DepartmentTagAssetsMatched = 0
$DepartmentTagAddSucceeded = $false
$DepartmentsFound = [System.Collections.Generic.List[string]]::new()
$DepartmentsNotFound = [System.Collections.Generic.List[string]]::new()

if ($QualysTargetComputersList.Count -gt 0) {
    Log-Message "=========================================================" "Cyan"
    Log-Message "COLLECTING CURRENT AD MEMBERS FROM DEPARTMENT QUALYS TAGS" "Cyan"
    Log-Message "=========================================================" "Cyan"

    foreach ($DepartmentName in $SourceOUNames) {
    $DepartmentFound = $false

    $DepartmentTagNames = @(
        "AD - $($DepartmentName.ToUpperInvariant())"
        "AD - $($DepartmentName.ToLowerInvariant())"
    ) | Select-Object -Unique

    foreach ($DepartmentTagName in $DepartmentTagNames) {
        $DepartmentTagSearchCount++

        $DepartmentResult = Get-QualysAssetsByTag `
            -TagName $DepartmentTagName `
            -Headers $Headers `
            -QualysPlatform $QualysPlatform `
            -SuppressNotFoundLog

        if (-not $DepartmentResult.Success) {
            $DepartmentTagSearchFailureCount++
            continue
        }

        $DepartmentFound = $true

        foreach ($Asset in $DepartmentResult.Assets) {
            $DepartmentTagAssetsEvaluated++

            if ([string]::IsNullOrWhiteSpace($Asset.DeviceName)) {
                continue
            }

            $NormalizedDeviceName = $Asset.DeviceName.Trim()

            if ($NormalizedDeviceName.EndsWith(".$DnsSuffix", [System.StringComparison]::OrdinalIgnoreCase)) {
                $NormalizedDeviceName = $NormalizedDeviceName.Substring(
                    0,
                    $NormalizedDeviceName.Length - ($DnsSuffix.Length + 1)
                )
            }
            elseif ($NormalizedDeviceName.Contains(".")) {
                $NormalizedDeviceName = $NormalizedDeviceName.Split(".")[0]
            }

            if (-not $FinalComputerNameSet.Contains($NormalizedDeviceName)) {
                continue
            }

            if ($DepartmentTagAssetIds.Add($Asset.AssetId)) {
                $DepartmentTagAssetsMatched++
            }

            $DepartmentMatchedComputerNames.Add($NormalizedDeviceName) | Out-Null
            $CurrentTargetAssetIds.Add($Asset.AssetId) | Out-Null

            if (-not $DeviceAssetIdsMap.ContainsKey($NormalizedDeviceName)) {
                $DeviceAssetIdsMap[$NormalizedDeviceName] = [System.Collections.Generic.HashSet[string]]::new(
                    [System.StringComparer]::OrdinalIgnoreCase
                )
            }

            $DeviceAssetIdsMap[$NormalizedDeviceName].Add($Asset.AssetId) | Out-Null

            if (-not $DeviceDepartmentMap.ContainsKey($NormalizedDeviceName)) {
                $DeviceDepartmentMap[$NormalizedDeviceName] = [System.Collections.Generic.List[string]]::new()
            }

            if (-not $DeviceDepartmentMap[$NormalizedDeviceName].Contains($DepartmentName)) {
                $DeviceDepartmentMap[$NormalizedDeviceName].Add($DepartmentName)
            }
        }
    }

    if ($DepartmentFound) {
        $DepartmentsFound.Add($DepartmentName)
    }
    else {
        $DepartmentsNotFound.Add($DepartmentName)
        Log-Message "ERROR: No Qualys department tag was found for '$DepartmentName'." "Red"
    }
}

Log-Message "---------------------------------------------------------" "Cyan"
Log-Message "DEPARTMENT QUALYS TAG SEARCH SUMMARY:" "Cyan"

if ($DepartmentsFound.Count -gt 0) {
    Log-Message "FOUND: $($DepartmentsFound -join ', ')" "Green"
}
else {
    Log-Message "FOUND: None" "Gray"
}

if ($DepartmentsNotFound.Count -gt 0) {
    Log-Message "NOT FOUND: $($DepartmentsNotFound -join ', ')" "Yellow"
}
else {
    Log-Message "NOT FOUND: None" "Green"
}


    if ($DepartmentTagAssetIds.Count -gt 0) {
        $DepartmentTagAddResult = Update-QualysAssetTag `
            -Action Add `
            -AssetIds $DepartmentTagAssetIds `
            -TagId $TargetTagId `
            -TagName $ActiveProfile.QualysTag `
            -Headers $Headers `
            -QualysPlatform $QualysPlatform

        $DepartmentTagAddSucceeded = $DepartmentTagAddResult.Success

        foreach ($AssetId in $DepartmentTagAddResult.SuccessfulAssetIds) {
            $SuccessfulTagAssetIds.Add($AssetId) | Out-Null
        }

        foreach ($AssetId in $DepartmentTagAddResult.FailedAssetIds) {
            $FailedTagAssetIds.Add($AssetId) | Out-Null
            $TagFailureReasons[$AssetId] = $DepartmentTagAddResult.FailureReasons[$AssetId]
        }
    }
    else {
        Log-Message "No current AD members were matched through department Qualys tags." "Gray"
    }
}
else {
    Log-Message "No final AD group members exist. Department Qualys tag searches were skipped." "Gray"
}

$StragglerComputerNames = @(
    foreach ($ComputerName in $QualysTargetComputersList) {
        if (-not $DepartmentMatchedComputerNames.Contains($ComputerName)) {
            $ComputerName
        }
    }
)

$AddResolutionResult = $null
$QualysStragglerAddSucceeded = $false

if ($StragglerComputerNames.Count -gt 0) {
    Log-Message "=========================================================" "Cyan"
    Log-Message "RESOLVING $($StragglerComputerNames.Count) QUALYS STRAGGLER(S) BY HOSTNAME" "Cyan"
    Log-Message "=========================================================" "Cyan"

    $AddResolutionResult = Resolve-QualysAssetIds `
        -ComputerNames $StragglerComputerNames `
        -Headers $Headers `
        -QualysPlatform $QualysPlatform `
        -DnsSuffix $DnsSuffix `
        -OperationLabel "STRAGGLER TAG ADD"

    foreach ($DeviceResult in $AddResolutionResult.DeviceResults) {
        if ($DeviceResult.Success) {
            if (-not $DeviceAssetIdsMap.ContainsKey($DeviceResult.ComputerName)) {
                $DeviceAssetIdsMap[$DeviceResult.ComputerName] = [System.Collections.Generic.HashSet[string]]::new(
                    [System.StringComparer]::OrdinalIgnoreCase
                )
            }

            foreach ($AssetId in $DeviceResult.AssetIds) {
                $DeviceAssetIdsMap[$DeviceResult.ComputerName].Add($AssetId) | Out-Null
                $CurrentTargetAssetIds.Add($AssetId) | Out-Null
            }
        }
        else {
            $DeviceResolutionFailureMap[$DeviceResult.ComputerName] = $DeviceResult.FailureReason
        }
    }

    $QualysStragglerAddResult = Update-QualysAssetTag `
        -Action Add `
        -AssetIds $AddResolutionResult.AssetIds `
        -TagId $TargetTagId `
        -TagName $ActiveProfile.QualysTag `
        -Headers $Headers `
        -QualysPlatform $QualysPlatform

    $QualysStragglerAddSucceeded = $QualysStragglerAddResult.Success

    foreach ($AssetId in $QualysStragglerAddResult.SuccessfulAssetIds) {
        $SuccessfulTagAssetIds.Add($AssetId) | Out-Null
    }

    foreach ($AssetId in $QualysStragglerAddResult.FailedAssetIds) {
        $FailedTagAssetIds.Add($AssetId) | Out-Null
        $TagFailureReasons[$AssetId] = $QualysStragglerAddResult.FailureReasons[$AssetId]
    }
}
elseif ($QualysTargetComputersList.Count -gt 0) {
    Log-Message "All current AD group members were matched through department Qualys tags." "Green"
}
else {
    Log-Message "No final AD group members exist. Qualys tag addition was skipped." "Gray"
}

$QualysAddSucceeded = if ($QualysTargetComputersList.Count -eq 0) {
    $false
}
elseif ($StragglerComputerNames.Count -eq 0) {
    $DepartmentTagAddSucceeded
}
elseif ($DepartmentTagAssetIds.Count -eq 0) {
    $QualysStragglerAddSucceeded
}
else {
    $DepartmentTagAddSucceeded -and $QualysStragglerAddSucceeded
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

    foreach ($CurrentAssetId in $CurrentTargetAssetIds) {
        if ($RemoveResolutionResult.AssetIds.Contains($CurrentAssetId)) {
            $RemoveResolutionResult.AssetIds.Remove($CurrentAssetId) | Out-Null

            Log-Message "SAFETY CHECK: Asset ID $CurrentAssetId exists in the current target set and was excluded from tag removal." "Yellow"
        }
    }

    $QualysRemoveResult = Update-QualysAssetTag `
        -Action Remove `
        -AssetIds $RemoveResolutionResult.AssetIds `
        -TagId $TargetTagId `
        -TagName $ActiveProfile.QualysTag `
        -Headers $Headers `
        -QualysPlatform $QualysPlatform

    $QualysRemoveSucceeded = $QualysRemoveResult.Success
}
else {
    Log-Message "No computers were successfully removed from AD. Qualys tag removal was skipped." "Gray"
}

# =========================================================================
# Export Qualys Tag Results
# =========================================================================

$QualysResults = @(
    foreach ($ComputerName in ($QualysTargetComputersList | Sort-Object -Unique)) {
        $Departments = if ($DeviceDepartmentMap.ContainsKey($ComputerName)) {
            @($DeviceDepartmentMap[$ComputerName])
        }
        elseif ($ComputerDepartmentMap.ContainsKey($ComputerName)) {
            @($ComputerDepartmentMap[$ComputerName])
        }
        else {
            @("Unknown")
        }

        $AssetIds = if ($DeviceAssetIdsMap.ContainsKey($ComputerName)) {
            @($DeviceAssetIdsMap[$ComputerName])
        }
        else {
            @()
        }

        $SuccessfulIds = @(
            $AssetIds | Where-Object { $SuccessfulTagAssetIds.Contains($_) }
        )

        $FailedIds = @(
            $AssetIds | Where-Object { $FailedTagAssetIds.Contains($_) }
        )

        $Status = "Failed"
        $FailureDescription = ""

        if ($AssetIds.Count -eq 0) {
            $FailureDescription = if ($DeviceResolutionFailureMap.ContainsKey($ComputerName)) {
                $DeviceResolutionFailureMap[$ComputerName]
            }
            else {
                "No matching Qualys asset was found through department tags or hostname lookup."
            }
        }
        elseif ($SuccessfulIds.Count -gt 0 -and $FailedIds.Count -eq 0) {
            $Status = "Tag Applied or Already Present"
        }
        elseif ($SuccessfulIds.Count -gt 0 -and $FailedIds.Count -gt 0) {
            $Status = "Partially Applied"
            $FailureDescription = @(
                $FailedIds |
                    ForEach-Object { $TagFailureReasons[$_] } |
                    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                    Sort-Object -Unique
            ) -join " | "
        }
        else {
            $FailureDescription = @(
                $FailedIds |
                    ForEach-Object { $TagFailureReasons[$_] } |
                    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                    Sort-Object -Unique
            ) -join " | "

            if ([string]::IsNullOrWhiteSpace($FailureDescription)) {
                $FailureDescription = "Qualys asset IDs were resolved, but the patch-management tag update was not accepted."
            }
        }

        [pscustomobject]@{
            DeviceName         = $ComputerName
            Department         = ($Departments | Sort-Object -Unique) -join "; "
            QualysAssetIds     = $AssetIds -join "; "
            Status             = $Status
            FailureDescription = $FailureDescription
        }
    }
)

$QualysFailureResults = @(
    $QualysResults |
        Where-Object {
            $_.Status -eq "Failed" -or
            $_.Status -eq "Partially Applied"
        }
)

$QualysFailureResults |
    Export-Csv `
        -LiteralPath $QualysResultsCsv `
        -NoTypeInformation `
        -Encoding UTF8 `
        -Force

Log-Message "Exported $($QualysFailureResults.Count) Qualys tag failure row(s) to '$QualysResultsCsv'." "Yellow"

# =========================================================================
# Final Summary
# =========================================================================
Log-Message "---------------------------------------------------------" "Cyan"
Log-Message "FINAL AUTOMATION SUMMARY FOR [$($TargetMode.ToUpper())] MODE:" "Cyan"
Log-Message " Active Directory computers added: $GlobalAddedCount" "Green"
Log-Message " Active Directory computers removed: $GlobalRemovedCount" "Yellow"
Log-Message " Final Active Directory group membership: $FinalCount" "White"

Log-Message " Department tag lookup attempts: $DepartmentTagSearchCount" "White"
Log-Message " Department tag variants not found or unresolved: $DepartmentTagSearchFailureCount" "White"
Log-Message " Qualys assets evaluated from department tags: $DepartmentTagAssetsEvaluated" "White"
Log-Message " Active Directory members matched through department tags: $($DepartmentMatchedComputerNames.Count)" "Green"
Log-Message " Unique Qualys asset IDs resolved through department tags: $($DepartmentTagAssetIds.Count)" "White"
Log-Message " Active Directory members not matched through department tags: $($StragglerComputerNames.Count)" "Yellow"

if ($AddResolutionResult) {
    Log-Message " Unmatched Active Directory members evaluated by hostname: $($AddResolutionResult.ComputerCount)" "White"
    Log-Message " Unmatched Active Directory members resolved by hostname: $($AddResolutionResult.MatchedComputerCount)" "Green"
    Log-Message " Unique Qualys asset IDs resolved by hostname: $($AddResolutionResult.AssetIds.Count)" "White"
}

if ($RemoveResolutionResult) {
    Log-Message " Removed Active Directory members evaluated in Qualys: $($RemoveResolutionResult.ComputerCount)" "White"
    Log-Message " Removed Active Directory members resolved in Qualys: $($RemoveResolutionResult.MatchedComputerCount)" "Yellow"
    Log-Message " Unique Qualys asset IDs submitted for tag removal: $($RemoveResolutionResult.AssetIds.Count)" "White"
}

Log-Message " Qualys patch-management tag addition request successful: $QualysAddSucceeded" "White"
Log-Message " Qualys patch-management tag removal request successful: $QualysRemoveSucceeded" "White"
Log-Message "=========================================================`n" "Cyan"
