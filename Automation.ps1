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

$QualysServerClassificationTags = @(
    "<server-classification-tag-1>"
    "<server-classification-tag-2>"
)

$WorkstationOUFileName = "<list-of-workstation-ous.txt>"
$ServerOUFileName      = "<list-of-server-ous.txt>"

$QualysLastSeenDays = 30
$QualysLastSeenCutoff = (Get-Date).ToUniversalTime().AddDays(-$QualysLastSeenDays)

$ClearTargetQualysTagBeforeAdd = $false
$EnableADGroupAdditions       = $true
$EnableADGroupRemovals        = $true
$EnableDepartmentTagResolution = $true
$EnableStragglerResolution    = $true
$EnableQualysTagAdditions     = $true
$EnableQualysTagRemovals      = $true
$CondensedOutput                = $true
$CondensedSummaryNameLimit      = 5
$QualysFallbackBatchSize        = 25
$QualysVerificationAttempts     = 3
$QualysVerificationDelaySeconds = 30
$Qualys503RetryDelaysSeconds     = @(15, 30, 60)
$RemoveUnverifiedDevicesFromAD  = $true

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

    if ($CondensedOutput) {
        $CondensedPatterns = @(
            "^Evaluating configured OU:",
            "^ Found \d+ eligible ",
            "^ Skipped \d+ ",
            "^ \[AD ADD SUCCESS\]:",
            "^ \[AD REMOVE SUCCESS\]:",
            "^\[.*\] Fetching Qualys asset batch ",
            "^Searching Qualys for tag ",
            "^Resolved Qualys tag ",
            "^\[STRAGGLER TAG ADD\] Evaluating device:",
            "^\[TAG REMOVE\] Evaluating device:",
            "^\s+\[TRYING ASSET NAME QUERY\]:",
            "^\s+\[SUCCESS MATCH\]:",
            "^\s+\[DUPLICATE MATCH\]:",
            "^\s+\[STALE ASSET SKIPPED\]:",
            "^\s+\[DEVICE RESOLVED\]:",
            "^\s+\[QUALYS ASSET NOT FOUND\]:",
            "^\[MSAD - .*\] Skipping stale asset ",
            "^\s*\[AD QUALYS COVERAGE ADD SUCCESS\]:",
            "^\s*\[AD QUALYS COVERAGE ADD FAILED\]:",
            "^\s*\[AD QUALYS COVERAGE REMOVE SUCCESS\]:",
            "^\s*\[AD QUALYS COVERAGE REMOVE FAILED\]:",
            "^ERROR: Qualys tag (add|remove) failed for batch ",
            "^WARNING: Qualys rejected batch ",
            "^(Add|Remove) Qualys tag '.*' for batch ",
            "^SUCCESS: Qualys accepted batch ",
            "^Retrying failed batch ",
            "^Retrying failed .* individually to preserve valid assets in the batch\.$",
        )

        foreach ($Pattern in $CondensedPatterns) {
            if ($Message -match $Pattern) {
                return
            }
        }
    }

    $TimeStamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $FormattedMessage = "[$TimeStamp] $Message"

    $FormattedMessage |
        Out-File -FilePath $LogFile -Append -Encoding utf8

    Write-Host $FormattedMessage -ForegroundColor $Color
}

function Format-CondensedNameList {
    param(
        [Parameter(Mandatory = $false)]
        [object[]]$Names,

        [Parameter(Mandatory = $false)]
        [int]$Limit = 50
    )

    $UniqueNames = @(
        $Names |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
            ForEach-Object { ([string]$_).Trim() } |
            Sort-Object -Unique
    )

    if ($UniqueNames.Count -eq 0) {
        return "None"
    }

    $DisplayedNames = @(
        $UniqueNames |
            Select-Object -First $Limit
    )

    $Result = $DisplayedNames -join ", "

    if ($UniqueNames.Count -gt $Limit) {
        $Result += " ... and $($UniqueNames.Count - $Limit) more"
    }

    return $Result
}

# =========================================================================
# XML Escaping
# =========================================================================

function ConvertTo-NormalizedComputerName {
    param(
        [Parameter(Mandatory = $false)]
        [string]$DeviceName,

        [Parameter(Mandatory = $true)]
        [string]$DnsSuffix
    )

    if ([string]::IsNullOrWhiteSpace($DeviceName)) {
        return $null
    }

    $NormalizedDeviceName = $DeviceName.Trim()

    if (
        $NormalizedDeviceName.EndsWith(
            ".$DnsSuffix",
            [System.StringComparison]::OrdinalIgnoreCase
        )
    ) {
        $NormalizedDeviceName = $NormalizedDeviceName.Substring(
            0,
            $NormalizedDeviceName.Length - ($DnsSuffix.Length + 1)
        )
    }
    elseif ($NormalizedDeviceName.Contains(".")) {
        $NormalizedDeviceName = $NormalizedDeviceName.Split(".")[0]
    }

    return $NormalizedDeviceName
}

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

    $AssetSearchURL = "https://$QualysPlatform/qps/rest/2.0/search/am/hostasset"

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
                $XmlResult.SelectNodes("//HostAsset")
            )

            foreach ($AssetNode in $AssetNodes) {
                $AssetIdNode = $AssetNode.SelectSingleNode("id")
                $NameNode = $AssetNode.SelectSingleNode("name")
                $LastCheckedInNode = $AssetNode.SelectSingleNode("agentInfo/lastCheckedIn")

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

                $LastCheckedIn = $null

                if (
                    $LastCheckedInNode -and
                    -not [string]::IsNullOrWhiteSpace($LastCheckedInNode.InnerText)
                ) {
                    try {
                        $LastCheckedIn = [datetime]::Parse(
                            $LastCheckedInNode.InnerText.Trim(),
                            [System.Globalization.CultureInfo]::InvariantCulture,
                            [System.Globalization.DateTimeStyles]::AdjustToUniversal
                        ).ToUniversalTime()
                    }
                    catch {
                        $LastCheckedIn = $null
                    }
                }

                $Assets.Add(
                    [pscustomobject]@{
                        AssetId      = $AssetId
                        DeviceName   = $DeviceName
                        LastCheckedIn = $LastCheckedIn
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
        [string]$OperationLabel,

        [Parameter(Mandatory = $false)]
        [datetime]$LastSeenCutoff,

        [Parameter(Mandatory = $false)]
        [int]$LastSeenDays = 30,

        [Parameter(Mandatory = $false)]
        [int[]]$ServiceUnavailableRetryDelaysSeconds = @(15, 30, 60),

        [Parameter(Mandatory = $false)]
        [switch]$RequireRecentCheckIn
    )

    $AssetIds = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )

    $MatchedComputerCount = 0
    $CoverageUnknownComputerCount = 0
    $DeviceResults = [System.Collections.Generic.List[object]]::new()
    $AssetSearchURL = "https://$QualysPlatform/qps/rest/2.0/search/am/hostasset"

    foreach ($ComputerName in $ComputerNames) {
        $CleanName = $ComputerName.Trim()

        if ([string]::IsNullOrWhiteSpace($CleanName)) {
            continue
        }

        $DeviceMatchesFound = 0
        $DeviceStaleAssetCount = 0
        $DeviceHadApiError = $false
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

            $Response = $null
            $RequestSucceeded = $false
            $FinalRequestError = $null
            $MaximumAttempts = $ServiceUnavailableRetryDelaysSeconds.Count + 1

            for ($RequestAttempt = 1; $RequestAttempt -le $MaximumAttempts; $RequestAttempt++) {
                try {
                    $Response = Invoke-WebRequest `
                        -Uri $AssetSearchURL `
                        -Method Post `
                        -Headers $Headers `
                        -ContentType "text/xml" `
                        -Body $AssetSearchPayload `
                        -ErrorAction Stop

                    $RequestSucceeded = $true
                    break
                }
                catch {
                    $FinalRequestError = $_

                    $StatusCode = $null

                    if ($_.Exception.Response) {
                        try {
                            $StatusCode = [int]$_.Exception.Response.StatusCode
                        }
                        catch {
                            $StatusCode = $null
                        }
                    }

                    $IsServiceUnavailable = (
                        $StatusCode -eq 503 -or
                        $_.Exception.Message -match "\b503\b|Server Unavailable"
                    )

                    if (
                        $IsServiceUnavailable -and
                        $RequestAttempt -le $ServiceUnavailableRetryDelaysSeconds.Count
                    ) {
                        Start-Sleep -Seconds $ServiceUnavailableRetryDelaysSeconds[$RequestAttempt - 1]
                        continue
                    }

                    break
                }
            }

            if (-not $RequestSucceeded) {
                $DeviceHadApiError = $true
                $ErrorMessage = if ($FinalRequestError) {
                    $FinalRequestError.Exception.Message
                }
                else {
                    "Unknown Qualys API error."
                }

                $DeviceErrors.Add("$NameAttempt`: $ErrorMessage")
                Log-Message "      [API EXCEPTION]: Query failed for '$NameAttempt' after retry processing." "Red"
                Log-Message "      Error details: $ErrorMessage" "Red"
                continue
            }

            try {
                [xml]$XmlResult = $Response.Content

                $AssetNodes = @(
                    $XmlResult.SelectNodes("//HostAsset")
                )

                foreach ($AssetNode in $AssetNodes) {
                    $AssetIdNode = $AssetNode.SelectSingleNode("id")
                    $LastCheckedInNode = $AssetNode.SelectSingleNode("agentInfo/lastCheckedIn")

                    if (
                        -not $AssetIdNode -or
                        [string]::IsNullOrWhiteSpace($AssetIdNode.InnerText)
                    ) {
                        continue
                    }

                    $AssetId = $AssetIdNode.InnerText.Trim()

                    if ($RequireRecentCheckIn) {
                        $LastCheckedIn = $null

                        if (
                            $LastCheckedInNode -and
                            -not [string]::IsNullOrWhiteSpace($LastCheckedInNode.InnerText)
                        ) {
                            try {
                                $LastCheckedIn = [datetime]::Parse(
                                    $LastCheckedInNode.InnerText.Trim(),
                                    [System.Globalization.CultureInfo]::InvariantCulture,
                                    [System.Globalization.DateTimeStyles]::AdjustToUniversal
                                ).ToUniversalTime()
                            }
                            catch {
                                $LastCheckedIn = $null
                            }
                        }

                        if (
                            $null -eq $LastCheckedIn -or
                            $LastCheckedIn -lt $LastSeenCutoff
                        ) {
                            $DeviceStaleAssetCount++
                            Log-Message "      [STALE ASSET SKIPPED]: Asset ID $AssetId has not checked in within the last $LastSeenDays days." "Yellow"
                            continue
                        }
                    }

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
            catch {
                $DeviceHadApiError = $true
                $DeviceErrors.Add("$NameAttempt`: Failed to parse the Qualys response. $($_.Exception.Message)")
            }
        }

        if ($DeviceMatchesFound -eq 0) {
            $CoverageUnknown = $DeviceHadApiError

            $FailureReason = if ($CoverageUnknown) {
                "Qualys coverage is unknown because asset lookup API requests failed after retry processing: $($DeviceErrors -join ' | ')"
            }
            elseif ($RequireRecentCheckIn -and $DeviceStaleAssetCount -gt 0) {
                "Matching Qualys Host Asset records were found, but none checked in within the last $LastSeenDays days."
            }
            else {
                "No matching Qualys asset was found using any hostname variant."
            }

            if ($CoverageUnknown) {
                $CoverageUnknownComputerCount++
            }

            Log-Message "   [QUALYS ASSET NOT FOUND]: No usable recent Qualys asset was resolved for '$CleanName'." "Yellow"

            $DeviceResults.Add(
                [pscustomobject]@{
                    ComputerName   = $CleanName
                    AssetIds       = @()
                    Success        = $false
                    CoverageUnknown = $CoverageUnknown
                    FailureReason  = $FailureReason
                }
            )
        }
        else {
            $MatchedComputerCount++

            Log-Message "   [DEVICE RESOLVED]: '$CleanName' produced $DeviceMatchesFound matching result(s)." "Gray"

            $DeviceResults.Add(
                [pscustomobject]@{
                    ComputerName   = $CleanName
                    AssetIds       = @($DeviceAssetIds)
                    Success        = $true
                    CoverageUnknown = $false
                    FailureReason  = ""
                }
            )
        }
    }

    return [pscustomobject]@{
        AssetIds                    = $AssetIds
        MatchedComputerCount        = $MatchedComputerCount
        CoverageUnknownComputerCount = $CoverageUnknownComputerCount
        ComputerCount               = $ComputerNames.Count
        DeviceResults               = @($DeviceResults)
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
    $PrimaryBatchSize = 200
    $FallbackBatchSize = 25
    $AssetIdArray = @($AssetIds)

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

    function Get-QualysErrorSummary {
        param(
            [string]$ResponseContent,
            [string]$FallbackMessage
        )

        if (-not [string]::IsNullOrWhiteSpace($ResponseContent)) {
            try {
                [xml]$ErrorXml = $ResponseContent
                $ErrorMessageNode = $ErrorXml.SelectSingleNode("//errorMessage")
                $ErrorResolutionNode = $ErrorXml.SelectSingleNode("//errorResolution")
                $Parts = [System.Collections.Generic.List[string]]::new()

                if ($ErrorMessageNode -and -not [string]::IsNullOrWhiteSpace($ErrorMessageNode.InnerText)) {
                    $Parts.Add(($ErrorMessageNode.InnerText -replace "\s+", " ").Trim())
                }

                if ($ErrorResolutionNode -and -not [string]::IsNullOrWhiteSpace($ErrorResolutionNode.InnerText)) {
                    $Parts.Add("Resolution: " + (($ErrorResolutionNode.InnerText -replace "\s+", " ").Trim()))
                }

                if ($Parts.Count -gt 0) {
                    return ($Parts -join " ")
                }
            }
            catch {
            }

            return (($ResponseContent -replace "\s+", " ").Trim())
        }

        return $FallbackMessage
    }

    function Invoke-QualysTagBatch {
        param(
            [string[]]$BatchAssetIds,
            [string]$BatchLabel
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
            Log-Message "$Action Qualys tag '$TagName' for $BatchLabel containing $($BatchAssetIds.Count) asset(s)." "Yellow"

            $UpdateResponse = Invoke-WebRequest `
                -Uri $BulkUpdateURL `
                -Method Post `
                -Headers $Headers `
                -ContentType "text/xml; charset=utf-8" `
                -Body $BulkUpdatePayload `
                -ErrorAction Stop

            if ($UpdateResponse.Content -match "SUCCESS") {
                Log-Message "SUCCESS: Qualys accepted $BatchLabel." "Green"

                return [pscustomobject]@{
                    Success = $true
                    Reason  = ""
                }
            }

            $FailureReason = Get-QualysErrorSummary `
                -ResponseContent $UpdateResponse.Content `
                -FallbackMessage "Qualys returned no explicit SUCCESS result."

            Log-Message "WARNING: Qualys rejected $BatchLabel. $FailureReason" "Yellow"

            return [pscustomobject]@{
                Success = $false
                Reason  = $FailureReason
            }
        }
        catch {
            $ResponseDetails = ""

            if ($_.Exception.Response) {
                try {
                    $ResponseStream = $_.Exception.Response.GetResponseStream()
                    $StreamReader = New-Object System.IO.StreamReader($ResponseStream)
                    $ResponseDetails = $StreamReader.ReadToEnd()
                    $StreamReader.Dispose()
                    $ResponseStream.Dispose()
                }
                catch {
                    $ResponseDetails = ""
                }
            }

            $FailureReason = Get-QualysErrorSummary `
                -ResponseContent $ResponseDetails `
                -FallbackMessage $_.Exception.Message

            Log-Message "ERROR: Qualys tag $($Action.ToLower()) failed for $BatchLabel. $FailureReason" "Red"

            return [pscustomobject]@{
                Success = $false
                Reason  = $FailureReason
            }
        }
    }

    $PrimaryBatchCount = [int][Math]::Ceiling(
        $AssetIdArray.Count / [double]$PrimaryBatchSize
    )

    for ($PrimaryBatchIndex = 0; $PrimaryBatchIndex -lt $PrimaryBatchCount; $PrimaryBatchIndex++) {
        $PrimaryStartIndex = $PrimaryBatchIndex * $PrimaryBatchSize
        $PrimaryRemainingCount = $AssetIdArray.Count - $PrimaryStartIndex
        $PrimaryCurrentBatchSize = [Math]::Min($PrimaryBatchSize, $PrimaryRemainingCount)

        $PrimaryBatchAssetIds = @(
            $AssetIdArray |
                Select-Object -Skip $PrimaryStartIndex -First $PrimaryCurrentBatchSize
        )

        $PrimaryLabel = "batch $($PrimaryBatchIndex + 1) of $PrimaryBatchCount"

        $PrimaryResult = Invoke-QualysTagBatch `
            -BatchAssetIds $PrimaryBatchAssetIds `
            -BatchLabel $PrimaryLabel

        if ($PrimaryResult.Success) {
            foreach ($AssetId in $PrimaryBatchAssetIds) {
                $SuccessfulAssetIds.Add($AssetId) | Out-Null
            }

            continue
        }

        if ($PrimaryBatchAssetIds.Count -le $FallbackBatchSize) {
            foreach ($AssetId in $PrimaryBatchAssetIds) {
                $FailedAssetIds.Add($AssetId) | Out-Null
                $FailureReasons[$AssetId] = $PrimaryResult.Reason
            }

            continue
        }

        $FallbackBatchCount = [int][Math]::Ceiling(
            $PrimaryBatchAssetIds.Count / [double]$FallbackBatchSize
        )

        Log-Message "Retrying failed $PrimaryLabel in $FallbackBatchCount smaller batch(es) of up to $FallbackBatchSize asset(s)." "Yellow"

        for ($FallbackBatchIndex = 0; $FallbackBatchIndex -lt $FallbackBatchCount; $FallbackBatchIndex++) {
            $FallbackStartIndex = $FallbackBatchIndex * $FallbackBatchSize
            $FallbackRemainingCount = $PrimaryBatchAssetIds.Count - $FallbackStartIndex
            $FallbackCurrentBatchSize = [Math]::Min($FallbackBatchSize, $FallbackRemainingCount)

            $FallbackBatchAssetIds = @(
                $PrimaryBatchAssetIds |
                    Select-Object -Skip $FallbackStartIndex -First $FallbackCurrentBatchSize
            )

            $FallbackLabel = "$PrimaryLabel retry $($FallbackBatchIndex + 1) of $FallbackBatchCount"

            $FallbackResult = Invoke-QualysTagBatch `
                -BatchAssetIds $FallbackBatchAssetIds `
                -BatchLabel $FallbackLabel

            if ($FallbackResult.Success) {
                foreach ($AssetId in $FallbackBatchAssetIds) {
                    $SuccessfulAssetIds.Add($AssetId) | Out-Null
                }

                continue
            }

            Log-Message "Retrying failed $FallbackLabel individually to preserve valid assets in the batch." "Yellow"

            foreach ($AssetId in $FallbackBatchAssetIds) {
                $IndividualLabel = "$FallbackLabel individual asset $AssetId"

                $IndividualResult = Invoke-QualysTagBatch `
                    -BatchAssetIds @($AssetId) `
                    -BatchLabel $IndividualLabel

                if ($IndividualResult.Success) {
                    $SuccessfulAssetIds.Add($AssetId) | Out-Null
                    $FailedAssetIds.Remove($AssetId) | Out-Null
                    $FailureReasons.Remove($AssetId)
                }
                else {
                    $FailedAssetIds.Add($AssetId) | Out-Null
                    $FailureReasons[$AssetId] = $IndividualResult.Reason
                }
            }
        }
    }

    return [pscustomobject]@{
        Success            = ($FailedAssetIds.Count -eq 0)
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
Log-Message "AD group additions enabled: $EnableADGroupAdditions" "Gray"
Log-Message "AD group removals enabled: $EnableADGroupRemovals" "Gray"
Log-Message "Department-tag resolution enabled: $EnableDepartmentTagResolution" "Gray"
Log-Message "Hostname straggler resolution enabled: $EnableStragglerResolution" "Gray"
Log-Message "Qualys tag additions enabled: $EnableQualysTagAdditions" "Gray"
Log-Message "Qualys tag removals enabled: $EnableQualysTagRemovals" "Gray"
Log-Message "Clear target Qualys tag before additions: $ClearTargetQualysTagBeforeAdd" "Gray"
Log-Message "Condensed output enabled: $CondensedOutput" "Gray"
Log-Message "Remove devices without verified Qualys coverage from AD: $RemoveUnverifiedDevicesFromAD" "Gray"
Log-Message "Qualys failed-batch retry size: $QualysFallbackBatchSize" "Gray"
Log-Message "Qualys verification attempts: $QualysVerificationAttempts" "Gray"
Log-Message "Qualys verification delay: $QualysVerificationDelaySeconds second(s)" "Gray"
Log-Message "Qualys 503 retry delays: $($Qualys503RetryDelaysSeconds -join ', ') second(s)" "Gray"

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

$ADAddedNames  = [System.Collections.Generic.List[string]]::new()
$ADRemovedNames = [System.Collections.Generic.List[string]]::new()
$ADFailedNames = [System.Collections.Generic.List[string]]::new()

$DesiredMemberDNs = @{}
$ComputerDepartmentMap = @{}

$SuccessfullyRemovedComputers =
    [System.Collections.Generic.List[object]]::new()

$ScopeValidationPassed = $true

# =========================================================================
# Build Authoritative OU Scope
# =========================================================================

foreach ($OUName in $SourceOUNames) {
if (-not $CondensedOutput) {
        Log-Message "---------------------------------------------------------" "DarkGray"
    }
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
# Defer AD Group Additions Until Qualys Coverage Is Verified
# =========================================================================

$DevicesPendingQualysVerification = @(
    foreach ($DesiredDN in $DesiredMemberDNs.Keys) {
        if (-not $CurrentMemberDNs.ContainsKey($DesiredDN)) {
            $DesiredMemberDNs[$DesiredDN]
        }
    }
)

if ($DevicesPendingQualysVerification.Count -gt 0) {
    Log-Message "$($DevicesPendingQualysVerification.Count) OU-eligible computer(s) are pending Qualys verification before AD group addition." "Gray"
}
else {
    Log-Message "No new OU-eligible computers are pending AD group addition." "Gray"
}

# =========================================================================
# Remove Ineligible AD Group Members
# =========================================================================

if (-not $EnableADGroupRemovals) {
    Log-Message "AD group removals are disabled. Existing members were left unchanged." "Yellow"
}
elseif ($ScopeValidationPassed) {
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
                $ADRemovedNames.Add($Device.Name)
                $GlobalRemovedCount++
            }
            catch {
                Log-Message " [AD REMOVE FAILED]: Could not remove '$($Device.Name)'." "Red"
                Log-Message " Error details: $($_.Exception.Message)" "Red"

                $ADFailedNames.Add($Device.Name)
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
    $DesiredMemberDNs.Values |
        Where-Object {
            -not [string]::IsNullOrWhiteSpace($_.Name)
        } |
        ForEach-Object {
            $_.Name
        } |
        Sort-Object -Unique
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
Log-Message " Current AD group membership before Qualys coverage enforcement: $FinalCount" "White"

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
# Exclude Qualys-Classified Servers from Workstation Scope
# =========================================================================

$ServerClassifiedAssetIds = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase
)

$ServerClassifiedComputerNames = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase
)

$SuccessfulQualysRemovalCount = 0

$ServerClassifiedWorkstationExclusions = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase
)

if ($TargetMode -eq "Workstation") {
    Log-Message "=========================================================" "Cyan"
    Log-Message "CHECKING QUALYS SERVER-CLASSIFICATION TAGS" "Cyan"
    Log-Message "=========================================================" "Cyan"

    foreach ($ServerClassificationTag in $QualysServerClassificationTags) {
        $ServerTagResult = Get-QualysAssetsByTag `
            -TagName $ServerClassificationTag `
            -Headers $Headers `
            -QualysPlatform $QualysPlatform `
            -SuppressNotFoundLog

        if (-not $ServerTagResult.Success) {
            Log-Message "WARNING: Qualys server-classification tag '$ServerClassificationTag' was not found or could not be read." "Yellow"
            continue
        }

        foreach ($ServerAsset in $ServerTagResult.Assets) {
            if (-not [string]::IsNullOrWhiteSpace($ServerAsset.AssetId)) {
                $ServerClassifiedAssetIds.Add($ServerAsset.AssetId) | Out-Null
            }

            $ServerComputerName = ConvertTo-NormalizedComputerName `
                -DeviceName $ServerAsset.DeviceName `
                -DnsSuffix $DnsSuffix

            if (-not [string]::IsNullOrWhiteSpace($ServerComputerName)) {
                $ServerClassifiedComputerNames.Add($ServerComputerName) | Out-Null
            }
        }
    }

    foreach ($ComputerName in @($QualysTargetComputersList)) {
        if ($ServerClassifiedComputerNames.Contains($ComputerName)) {
            $ServerClassifiedWorkstationExclusions.Add($ComputerName) | Out-Null
        }
    }

    if ($ServerClassifiedWorkstationExclusions.Count -gt 0) {
        $QualysTargetComputersList = @(
            $QualysTargetComputersList |
                Where-Object {
                    -not $ServerClassifiedWorkstationExclusions.Contains($_)
                } |
                Sort-Object -Unique
        )

        Log-Message "Excluded $($ServerClassifiedWorkstationExclusions.Count) server-classified device(s) from workstation Qualys and AD patch scope." "Yellow"
    }
    else {
        Log-Message "No OU-eligible workstation candidates were classified as servers by the configured Qualys tags." "Green"
    }

    if (-not $ClearTargetQualysTagBeforeAdd -and $ServerClassifiedAssetIds.Count -gt 0) {
        $CurrentWorkstationTagResult = Get-QualysAssetsByTag `
            -TagName $ActiveProfile.QualysTag `
            -Headers $Headers `
            -QualysPlatform $QualysPlatform

        if ($CurrentWorkstationTagResult.Success) {
            $ServerAssetsCurrentlyInWorkstationTag = [System.Collections.Generic.HashSet[string]]::new(
                [System.StringComparer]::OrdinalIgnoreCase
            )

            foreach ($CurrentWorkstationAsset in $CurrentWorkstationTagResult.Assets) {
                if (
                    -not [string]::IsNullOrWhiteSpace($CurrentWorkstationAsset.AssetId) -and
                    $ServerClassifiedAssetIds.Contains($CurrentWorkstationAsset.AssetId)
                ) {
                    $ServerAssetsCurrentlyInWorkstationTag.Add(
                        $CurrentWorkstationAsset.AssetId
                    ) | Out-Null
                }
            }

            if (
                $ServerAssetsCurrentlyInWorkstationTag.Count -gt 0 -and
                $EnableQualysTagRemovals
            ) {
                $ServerTagRemovalResult = Update-QualysAssetTag `
                    -Action Remove `
                    -AssetIds $ServerAssetsCurrentlyInWorkstationTag `
                    -TagId $TargetTagId `
                    -TagName $ActiveProfile.QualysTag `
                    -Headers $Headers `
                    -QualysPlatform $QualysPlatform

                $SuccessfulQualysRemovalCount += $ServerTagRemovalResult.SuccessfulAssetIds.Count

                Log-Message "Removed $($ServerTagRemovalResult.SuccessfulAssetIds.Count) server-classified asset(s) from the workstation Qualys tag." "Yellow"
            }
            elseif ($ServerAssetsCurrentlyInWorkstationTag.Count -gt 0) {
                Log-Message "WARNING: Server-classified assets remain in the workstation Qualys tag because Qualys tag removals are disabled." "Yellow"
            }
        }
    }
}

# =========================================================================
# Optional Target Qualys Tag Reset
# =========================================================================

$TargetTagClearAttempted = $false
$TargetTagClearSucceeded = $false
$TargetTagClearedAssetCount = 0

if ($ClearTargetQualysTagBeforeAdd) {
    $TargetTagClearAttempted = $true

    Log-Message "=========================================================" "Red"
    Log-Message "CLEARING ALL ASSETS FROM QUALYS TAG '$($ActiveProfile.QualysTag)'" "Red"
    Log-Message "=========================================================" "Red"

    $CurrentTagMembership = Get-QualysAssetsByTag `
        -TagName $ActiveProfile.QualysTag `
        -Headers $Headers `
        -QualysPlatform $QualysPlatform

    if (-not $CurrentTagMembership.Success) {
        Log-Message "CRITICAL ERROR: Could not retrieve the current target-tag membership. The clear operation was not performed." "Red"
        exit 1
    }

    $AssetsToClear = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )

    foreach ($Asset in $CurrentTagMembership.Assets) {
        if (-not [string]::IsNullOrWhiteSpace($Asset.AssetId)) {
            $AssetsToClear.Add($Asset.AssetId) | Out-Null
        }
    }

    $TargetTagClearedAssetCount = $AssetsToClear.Count

    if ($AssetsToClear.Count -eq 0) {
        $TargetTagClearSucceeded = $true
        Log-Message "The target Qualys tag is already empty. No clear operation was required." "Gray"
    }
    else {
        Log-Message "Removing '$($ActiveProfile.QualysTag)' from $($AssetsToClear.Count) existing asset(s) before rebuilding membership." "Yellow"

        $TargetTagClearResult = Update-QualysAssetTag `
            -Action Remove `
            -AssetIds $AssetsToClear `
            -TagId $TargetTagId `
            -TagName $ActiveProfile.QualysTag `
            -Headers $Headers `
            -QualysPlatform $QualysPlatform

        $TargetTagClearSucceeded = $TargetTagClearResult.Success

        if ($TargetTagClearSucceeded) {
            Log-Message "Successfully cleared $($AssetsToClear.Count) asset(s) from '$($ActiveProfile.QualysTag)'." "Green"
        }
        else {
            Log-Message "WARNING: One or more batches failed while clearing '$($ActiveProfile.QualysTag)'. The workflow will continue and rebuild eligible membership." "Yellow"
        }
    }
}
else {
    Log-Message "Target Qualys tag reset is disabled. Existing membership will be preserved." "Gray"
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

$DepartmentSeenComputerNames = [System.Collections.Generic.HashSet[string]]::new(
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
$CoverageUnknownComputerNames = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase
)
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
$DepartmentTagStaleAssetsSkipped = 0
$DepartmentTagStaleComputerNames = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase
)
$DepartmentTagAddSucceeded = $false
$DepartmentsFound = [System.Collections.Generic.List[string]]::new()
$DepartmentsNotFound = [System.Collections.Generic.List[string]]::new()

if ($QualysTargetComputersList.Count -gt 0 -and $EnableDepartmentTagResolution) {
    Log-Message "=========================================================" "Cyan"
    Log-Message "COLLECTING CURRENT AD MEMBERS FROM DEPARTMENT QUALYS TAGS" "Cyan"
    Log-Message "=========================================================" "Cyan"

    foreach ($DepartmentName in $SourceOUNames) {
    $DepartmentFound = $false

    $DepartmentTagNames = @(
        "MSAD - $($DepartmentName.ToUpperInvariant())"
        "MSAD - $($DepartmentName.ToLowerInvariant())"
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

            $NormalizedDeviceName = ConvertTo-NormalizedComputerName `
                -DeviceName $Asset.DeviceName `
                -DnsSuffix $DnsSuffix

            if ([string]::IsNullOrWhiteSpace($NormalizedDeviceName)) {
                continue
            }

            if (-not $FinalComputerNameSet.Contains($NormalizedDeviceName)) {
                continue
            }

            if (
                $TargetMode -eq "Workstation" -and
                (
                    $ServerClassifiedComputerNames.Contains($NormalizedDeviceName) -or
                    $ServerClassifiedAssetIds.Contains($Asset.AssetId)
                )
            ) {
                $ServerClassifiedWorkstationExclusions.Add($NormalizedDeviceName) | Out-Null
                continue
            }

            $DepartmentSeenComputerNames.Add($NormalizedDeviceName) | Out-Null

            if (
                $null -eq $Asset.LastCheckedIn -or
                $Asset.LastCheckedIn -lt $QualysLastSeenCutoff
            ) {
                $DepartmentTagStaleAssetsSkipped++
                $DepartmentTagStaleComputerNames.Add($NormalizedDeviceName) | Out-Null

                if (-not $DeviceResolutionFailureMap.ContainsKey($NormalizedDeviceName)) {
                    $DeviceResolutionFailureMap[$NormalizedDeviceName] = "Matching Qualys Host Asset records were found, but none checked in within the last $QualysLastSeenDays days."
                }

                Log-Message "[$DepartmentTagName] Skipping stale asset '$NormalizedDeviceName' (Asset ID $($Asset.AssetId)); no check-in within the last $QualysLastSeenDays days." "Yellow"
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


    if ($DepartmentTagAssetIds.Count -gt 0 -and $EnableQualysTagAdditions) {
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
    elseif ($DepartmentTagAssetIds.Count -gt 0) {
        Log-Message "Qualys tag additions are disabled. Department-resolved assets were not added to '$($ActiveProfile.QualysTag)'." "Yellow"
    }
    else {
        Log-Message "No current AD members were matched through department Qualys tags." "Gray"
    }
}
elseif (-not $EnableDepartmentTagResolution) {
    Log-Message "Department Qualys tag resolution is disabled." "Yellow"
}
else {
    Log-Message "No final AD group members exist. Department Qualys tag searches were skipped." "Gray"
}

$StragglerComputerNames = @(
    foreach ($ComputerName in $QualysTargetComputersList) {
        if (-not $DepartmentSeenComputerNames.Contains($ComputerName)) {
            $ComputerName
        }
    }
)

$AddResolutionResult = $null
$QualysStragglerAddSucceeded = $false

if ($StragglerComputerNames.Count -gt 0 -and $EnableStragglerResolution) {
    Log-Message "=========================================================" "Cyan"
    Log-Message "RESOLVING $($StragglerComputerNames.Count) QUALYS STRAGGLER(S) BY HOSTNAME" "Cyan"
    Log-Message "=========================================================" "Cyan"

    $AddResolutionResult = Resolve-QualysAssetIds `
        -ComputerNames $StragglerComputerNames `
        -Headers $Headers `
        -QualysPlatform $QualysPlatform `
        -DnsSuffix $DnsSuffix `
        -OperationLabel "STRAGGLER TAG ADD" `
        -LastSeenCutoff $QualysLastSeenCutoff `
        -LastSeenDays $QualysLastSeenDays `
        -ServiceUnavailableRetryDelaysSeconds $Qualys503RetryDelaysSeconds `
        -RequireRecentCheckIn

    foreach ($DeviceResult in $AddResolutionResult.DeviceResults) {
        if ($DeviceResult.Success) {
            $DeviceResolutionFailureMap.Remove($DeviceResult.ComputerName)
            $CoverageUnknownComputerNames.Remove($DeviceResult.ComputerName) | Out-Null

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

            if ($DeviceResult.CoverageUnknown) {
                $CoverageUnknownComputerNames.Add($DeviceResult.ComputerName) | Out-Null
            }
        }
    }

    if ($EnableQualysTagAdditions) {
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
    else {
        Log-Message "Qualys tag additions are disabled. Hostname-resolved stragglers were not added to '$($ActiveProfile.QualysTag)'." "Yellow"
    }
}
elseif ($StragglerComputerNames.Count -gt 0 -and -not $EnableStragglerResolution) {
    Log-Message "Hostname straggler resolution is disabled. $($StragglerComputerNames.Count) unmatched AD member(s) were not searched individually." "Yellow"
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

if ($QualysRemovedComputersList.Count -gt 0 -and $EnableQualysTagRemovals) {
    Log-Message "=========================================================" "Cyan"
    Log-Message "RESOLVING REMOVED AD MEMBERS FOR QUALYS TAG REMOVAL" "Cyan"
    Log-Message "=========================================================" "Cyan"

    $RemoveResolutionResult = Resolve-QualysAssetIds `
        -ComputerNames $QualysRemovedComputersList `
        -Headers $Headers `
        -QualysPlatform $QualysPlatform `
        -DnsSuffix $DnsSuffix `
        -OperationLabel "TAG REMOVE" `
        -ServiceUnavailableRetryDelaysSeconds $Qualys503RetryDelaysSeconds

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
$SuccessfulQualysRemovalCount += $QualysRemoveResult.SuccessfulAssetIds.Count
}
elseif ($QualysRemovedComputersList.Count -gt 0) {
    Log-Message "Qualys tag removals are disabled. Removed AD members were not untagged in Qualys." "Yellow"
}
else {
    Log-Message "No computers were successfully removed from AD. Qualys tag removal was skipped." "Gray"
}

$QualysEvaluationComputersList = @($QualysTargetComputersList)

# =========================================================================
# Verify Final Qualys Patch-Management Tag Membership
# =========================================================================

$VerifiedTargetAssetIds = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase
)

$VerificationSucceeded = $false

if (-not [string]::IsNullOrWhiteSpace($TargetTagId)) {
    Log-Message "=========================================================" "Cyan"
    Log-Message "VERIFYING FINAL QUALYS PATCH-MANAGEMENT TAG MEMBERSHIP" "Cyan"
    Log-Message "=========================================================" "Cyan"

    for (
        $VerificationAttempt = 1;
        $VerificationAttempt -le $QualysVerificationAttempts;
        $VerificationAttempt++
    ) {
        $VerifiedTargetAssetIds.Clear()

        $VerificationResult = Get-QualysAssetsByTag `
            -TagName $ActiveProfile.QualysTag `
            -Headers $Headers `
            -QualysPlatform $QualysPlatform

        if ($VerificationResult.Success) {
            foreach ($Asset in $VerificationResult.Assets) {
                if (-not [string]::IsNullOrWhiteSpace($Asset.AssetId)) {
                    $VerifiedTargetAssetIds.Add($Asset.AssetId) | Out-Null
                }
            }

            $MissingExpectedAssetIds = @(
                $CurrentTargetAssetIds |
                    Where-Object {
                        -not $VerifiedTargetAssetIds.Contains($_)
                    }
            )

            if ($MissingExpectedAssetIds.Count -eq 0) {
                $VerificationSucceeded = $true
                Log-Message "Verified $($VerifiedTargetAssetIds.Count) asset(s) currently assigned to Qualys tag '$($ActiveProfile.QualysTag)'." "Green"
                break
            }

            Log-Message "Verification attempt $VerificationAttempt of $QualysVerificationAttempts found $($MissingExpectedAssetIds.Count) expected asset(s) not yet visible in the target tag." "Yellow"
        }
        else {
            Log-Message "Verification attempt $VerificationAttempt of $QualysVerificationAttempts could not retrieve the target tag membership." "Red"
        }

        if ($VerificationAttempt -lt $QualysVerificationAttempts) {
            Log-Message "Waiting $QualysVerificationDelaySeconds second(s) before retrying final Qualys verification." "Gray"
            Start-Sleep -Seconds $QualysVerificationDelaySeconds
        }
    }

    if (-not $VerificationSucceeded) {
        Log-Message "ERROR: Final Qualys tag membership verification did not confirm all expected assets after $QualysVerificationAttempts attempt(s)." "Red"
    }
}

# =========================================================================
# Synchronize AD Group with Verified Qualys Patch Coverage
# =========================================================================

$QualysCoverageAddedToADNames = [System.Collections.Generic.List[string]]::new()
$QualysCoverageADAdditionFailedNames = [System.Collections.Generic.List[string]]::new()
$QualysCoverageRemovedFromADNames = [System.Collections.Generic.List[string]]::new()
$QualysCoverageADRemovalFailedNames = [System.Collections.Generic.List[string]]::new()
$QualysCoverageADActionMap = @{}

if (-not $VerificationSucceeded) {
    Log-Message "SAFETY LOCK: Final Qualys verification failed. No coverage-based AD group changes were made." "Red"
}
elseif (-not $EnableQualysTagAdditions) {
    Log-Message "SAFETY LOCK: Qualys tag additions are disabled. No coverage-based AD group changes were made." "Red"
}
else {
    $DesiredComputerByName = @{}

    foreach ($DesiredComputer in $DesiredMemberDNs.Values) {
        if (-not [string]::IsNullOrWhiteSpace($DesiredComputer.Name)) {
            $DesiredComputerByName[$DesiredComputer.Name] = $DesiredComputer
        }
    }

    $VerifiedCoveredComputerNames = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )

    foreach ($ComputerName in ($QualysEvaluationComputersList | Sort-Object -Unique)) {
        $ResolvedAssetIds = if ($DeviceAssetIdsMap.ContainsKey($ComputerName)) {
            @($DeviceAssetIdsMap[$ComputerName])
        }
        else {
            @()
        }

        $HasVerifiedCoverage = $false

        foreach ($AssetId in $ResolvedAssetIds) {
            if ($VerifiedTargetAssetIds.Contains($AssetId)) {
                $HasVerifiedCoverage = $true
                break
            }
        }

        if ($HasVerifiedCoverage) {
            $VerifiedCoveredComputerNames.Add($ComputerName) | Out-Null
        }
    }

    try {
        $CurrentCoverageMembers = @(
            Get-ADGroupMember `
                -Identity $TargetGroup `
                -ErrorAction Stop |
                Where-Object { $_.objectClass -eq "computer" }
        )
    }
    catch {
        Log-Message "CRITICAL ERROR: Could not read AD group membership before coverage enforcement." "Red"
        Log-Message "Error details: $($_.Exception.Message)" "Red"
        exit 1
    }

    $CurrentCoverageMemberByName = @{}

    foreach ($Member in $CurrentCoverageMembers) {
        if (-not [string]::IsNullOrWhiteSpace($Member.Name)) {
            $CurrentCoverageMemberByName[$Member.Name] = $Member
        }
    }

    if ($EnableADGroupAdditions) {
        $VerifiedDevicesToAdd = @(
            foreach ($ComputerName in $VerifiedCoveredComputerNames) {
                if (
                    $DesiredComputerByName.ContainsKey($ComputerName) -and
                    -not $CurrentCoverageMemberByName.ContainsKey($ComputerName)
                ) {
                    $ComputerName
                }
            }
        )

        foreach ($ComputerName in $VerifiedDevicesToAdd) {
            try {
                Add-ADGroupMember `
                    -Identity $TargetGroup `
                    -Members $DesiredComputerByName[$ComputerName].DistinguishedName `
                    -ErrorAction Stop

                $QualysCoverageAddedToADNames.Add($ComputerName)
                $ADAddedNames.Add($ComputerName)
                $QualysCoverageADActionMap[$ComputerName] = "ADDED to the AD Qualys patch group after Qualys coverage was verified."
                $GlobalAddedCount++

                Log-Message " [AD QUALYS COVERAGE ADD SUCCESS]: $ComputerName" "Green"
            }
            catch {
                $QualysCoverageADAdditionFailedNames.Add($ComputerName)
                $ADFailedNames.Add($ComputerName)
                $QualysCoverageADActionMap[$ComputerName] = "AD addition failed after Qualys coverage was verified: $($_.Exception.Message)"
                $GlobalFailedCount++

                Log-Message " [AD QUALYS COVERAGE ADD FAILED]: $ComputerName" "Red"
                Log-Message " Error details: $($_.Exception.Message)" "Red"
            }
        }
    }
    else {
        Log-Message "AD group additions are disabled. Verified devices were not added to the AD Qualys patch group." "Yellow"
    }

    if ($RemoveUnverifiedDevicesFromAD) {
        try {
            $CurrentCoverageMembers = @(
                Get-ADGroupMember `
                    -Identity $TargetGroup `
                    -ErrorAction Stop |
                    Where-Object { $_.objectClass -eq "computer" }
            )
        }
        catch {
            Log-Message "CRITICAL ERROR: Could not refresh AD group membership before removing unverified devices." "Red"
            Log-Message "Error details: $($_.Exception.Message)" "Red"
            exit 1
        }

        foreach ($Member in $CurrentCoverageMembers) {
            if ([string]::IsNullOrWhiteSpace($Member.Name)) {
                continue
            }

            if (-not $DesiredComputerByName.ContainsKey($Member.Name)) {
                continue
            }

            if ($VerifiedCoveredComputerNames.Contains($Member.Name)) {
                continue
            }

            if ($CoverageUnknownComputerNames.Contains($Member.Name)) {
                $QualysCoverageADActionMap[$Member.Name] = "No AD group change was made because Qualys coverage could not be determined after API retries."
                continue
            }

            try {
                Remove-ADGroupMember `
                    -Identity $TargetGroup `
                    -Members $Member.DistinguishedName `
                    -Confirm:$false `
                    -ErrorAction Stop

                $QualysCoverageRemovedFromADNames.Add($Member.Name)
                $QualysCoverageADActionMap[$Member.Name] = "REMOVED from the AD Qualys patch group because verified recent Qualys patch coverage was not available."

                Log-Message " [AD QUALYS COVERAGE REMOVE SUCCESS]: $($Member.Name)" "Yellow"
            }
            catch {
                $QualysCoverageADRemovalFailedNames.Add($Member.Name)
                $QualysCoverageADActionMap[$Member.Name] = "AD removal failed even though verified Qualys patch coverage was missing: $($_.Exception.Message)"

                Log-Message " [AD QUALYS COVERAGE REMOVE FAILED]: $($Member.Name)" "Red"
                Log-Message " Error details: $($_.Exception.Message)" "Red"
            }
        }
    }
    else {
        Log-Message "Removal of AD members without verified Qualys coverage is disabled." "Gray"
    }

    try {
        $FinalMembers = @(
            Get-ADGroupMember `
                -Identity $TargetGroup `
                -ErrorAction Stop |
                Where-Object { $_.objectClass -eq "computer" }
        )

        $FinalCount = $FinalMembers.Count

        $QualysTargetComputersList = @(
            $FinalMembers |
                Where-Object {
                    -not [string]::IsNullOrWhiteSpace($_.Name)
                } |
                ForEach-Object {
                    $_.Name
                } |
                Sort-Object -Unique
        )

        $QualysTargetComputersList |
            Out-File `
                -FilePath $HostsFile `
                -Force `
                -Encoding utf8

        Log-Message "Final AD group membership after Qualys coverage enforcement: $FinalCount" "White"
    }
    catch {
        Log-Message "ERROR: Could not refresh final AD group membership after coverage enforcement." "Red"
        Log-Message "Error details: $($_.Exception.Message)" "Red"
    }
}

# =========================================================================
# Export Qualys Tag Results
# =========================================================================

$QualysResults = @(
    foreach ($ComputerName in ($QualysEvaluationComputersList | Sort-Object -Unique)) {
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

        $VerifiedIds = @(
            $AssetIds |
                Where-Object {
                    $VerifiedTargetAssetIds.Contains($_)
                }
        )

        $MissingIds = @(
            $AssetIds |
                Where-Object {
                    -not $VerifiedTargetAssetIds.Contains($_)
                }
        )

        $Status = "Failed"
        $FailureDescription = ""
        $ADGroupAction = if ($QualysCoverageADActionMap.ContainsKey($ComputerName)) {
            $QualysCoverageADActionMap[$ComputerName]
        }
        else {
            "No AD group change required."
        }

        if (-not $VerificationSucceeded) {
            $FailureDescription = "Final Qualys patch-management tag verification could not be completed."
        }
        elseif ($CoverageUnknownComputerNames.Contains($ComputerName)) {
            $Status = "Coverage Unknown - Qualys API Error"
            $FailureDescription = $DeviceResolutionFailureMap[$ComputerName]
        }
        elseif ($AssetIds.Count -eq 0) {
            $FailureDescription = if ($DeviceResolutionFailureMap.ContainsKey($ComputerName)) {
                $DeviceResolutionFailureMap[$ComputerName]
            }
            else {
                "No matching Qualys Host Asset record was found through department tags or hostname lookup."
            }
        }
        elseif ($VerifiedIds.Count -eq $AssetIds.Count) {
            $Status = "Verified"
        }
        elseif ($VerifiedIds.Count -gt 0) {
            $Status = "Partially Verified"
            $FailureDescription = "Some resolved Qualys Host Asset IDs were not present in the final patch-management tag: $($MissingIds -join '; ')"
        }
        else {
            $FailureDescription = "Resolved Qualys Host Asset IDs were not present in the final patch-management tag: $($MissingIds -join '; ')"
        }

        if ($QualysCoverageAddedToADNames.Contains($ComputerName)) {
            $Status = "Verified"
        }
        elseif ($QualysCoverageADAdditionFailedNames.Contains($ComputerName)) {
            $Status = "AD Addition Failed"

            if ([string]::IsNullOrWhiteSpace($FailureDescription)) {
                $FailureDescription = "Qualys patch coverage was verified, but the computer could not be ADDED to the AD Qualys patch group."
            }
        }
        elseif ($QualysCoverageRemovedFromADNames.Contains($ComputerName)) {
            $Status = "Removed from AD - No Verified Qualys Coverage"

            if ([string]::IsNullOrWhiteSpace($FailureDescription)) {
                $FailureDescription = "No verified recent Qualys Host Asset was present in the target patch-management tag."
            }
        }
        elseif ($QualysCoverageADRemovalFailedNames.Contains($ComputerName)) {
            $Status = "AD Removal Failed"

            if ([string]::IsNullOrWhiteSpace($FailureDescription)) {
                $FailureDescription = "No verified recent Qualys Host Asset was present, and removal from the AD group failed."
            }
        }

        [pscustomobject]@{
            DeviceName         = $ComputerName
            Department         = ($Departments | Sort-Object -Unique) -join "; "
            QualysAssetIds     = $AssetIds -join "; "
            Status             = $Status
            ADGroupAction       = $ADGroupAction
            FailureDescription = $FailureDescription
        }
    }
)

$QualysFailureResults = @(
    $QualysResults |
        Where-Object {
            $_.Status -ne "Verified"
        }
)

$QualysFailureResults |
    Export-Csv `
        -LiteralPath $QualysResultsCsv `
        -NoTypeInformation `
        -Encoding UTF8 `
        -Force

Log-Message "Exported $($QualysFailureResults.Count) verified Qualys tag failure row(s) to '$QualysResultsCsv'." "Yellow"
# =========================================================================
# Final Summary
# =========================================================================

Log-Message "=========================================================" "Cyan"
Log-Message "FINAL AUTOMATION SUMMARY FOR [$($TargetMode.ToUpper())] MODE" "Cyan"
Log-Message "=========================================================" "Cyan"

Log-Message "ACTIVE DIRECTORY GPO GROUP '$($TargetGroup.Name)'" "Cyan"

if ($QualysCoverageAddedToADNames.Count -gt 0) {
    Log-Message " Devices added after Qualys coverage was verified: $($QualysCoverageAddedToADNames.Count)" "Green"
}

if ($QualysCoverageADAdditionFailedNames.Count -gt 0) {
    Log-Message " Devices that failed to be added: $($QualysCoverageADAdditionFailedNames.Count)" "Red"
}

if ($GlobalRemovedCount -gt 0) {
    Log-Message " Devices removed after leaving the configured OU scope: $GlobalRemovedCount" "Yellow"
}

if ($QualysCoverageRemovedFromADNames.Count -gt 0) {
    Log-Message " Devices removed because verified Qualys coverage was missing: $($QualysCoverageRemovedFromADNames.Count)" "Yellow"
}

if ($QualysCoverageADRemovalFailedNames.Count -gt 0) {
    Log-Message " Devices that failed to be removed: $($QualysCoverageADRemovalFailedNames.Count)" "Red"
}

if ($CoverageUnknownComputerNames.Count -gt 0) {
    Log-Message " Existing members left unchanged because Qualys coverage was unknown after API retries: $($CoverageUnknownComputerNames.Count)" "Yellow"
}

Log-Message " Final devices in the Active Directory GPO group: $FinalCount" "White"

Log-Message "---------------------------------------------------------" "Cyan"

Log-Message "QUALYS PATCH-MANAGEMENT TAG '$($ActiveProfile.QualysTag)'" "Cyan"

if ($SuccessfulTagAssetIds.Count -gt 0) {
    Log-Message " Qualys asset IDs added to the tag this run: $($SuccessfulTagAssetIds.Count)" "Green"
}

if ($SuccessfulQualysRemovalCount -gt 0) {
    Log-Message " Qualys asset IDs removed from the tag this run: $SuccessfulQualysRemovalCount" "Yellow"
}

Log-Message " Final verified Qualys asset IDs in the tag: $($VerifiedTargetAssetIds.Count)" "White"
Log-Message " Final Qualys tag verification successful: $VerificationSucceeded" "White"

Log-Message "---------------------------------------------------------" "Cyan"

Log-Message "COVERAGE CHECKS" "Cyan"
Log-Message " OU-eligible devices evaluated: $($QualysEvaluationComputersList.Count)" "White"

if ($DepartmentMatchedComputerNames.Count -gt 0) {
    Log-Message " Devices with recent Qualys coverage found through department tags: $($DepartmentMatchedComputerNames.Count)" "Green"
}

if ($DepartmentTagStaleComputerNames.Count -gt 0) {
    Log-Message " Stale Qualys devices excluded: $($DepartmentTagStaleComputerNames.Count)" "Yellow"
}

if ($ServerClassifiedWorkstationExclusions.Count -gt 0) {
    Log-Message " Server-classified devices excluded from workstation scope: $($ServerClassifiedWorkstationExclusions.Count)" "Yellow"
}

if ($AddResolutionResult) {
    if ($AddResolutionResult.ComputerCount -gt 0) {
        Log-Message " Devices checked through hostname fallback: $($AddResolutionResult.ComputerCount)" "White"
    }

    if ($AddResolutionResult.MatchedComputerCount -gt 0) {
        Log-Message " Devices with recent Qualys coverage found through hostname fallback: $($AddResolutionResult.MatchedComputerCount)" "Green"
    }

    if ($AddResolutionResult.CoverageUnknownComputerCount -gt 0) {
        Log-Message " Devices with unknown coverage after Qualys API retries: $($AddResolutionResult.CoverageUnknownComputerCount)" "Yellow"
    }
}
elseif (-not $EnableStragglerResolution) {
    Log-Message " Hostname fallback: Disabled" "Gray"
}

if ($QualysFailureResults.Count -gt 0) {
    Log-Message " Failure rows written to CSV: $($QualysFailureResults.Count)" "Yellow"
}

Log-Message "=========================================================`n" "Cyan"
