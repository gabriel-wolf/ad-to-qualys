[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Import-Module ActiveDirectory

# --- Variables ---
$QualysUsername = "<qualys-api-username>"
$QualysPlatform = "<qualysapi.qualys.com?"
$TestDevice     = "<test-device-name>"
$SecretPath = "<path-to-secret-enc>"


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


Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host "RUNNING V2 ASSET SEARCH FOR: $TestDevice" -ForegroundColor Cyan
Write-Host "=========================================================" -ForegroundColor Cyan

$BasicAuthString = [System.Text.Encoding]::UTF8.GetBytes("${QualysUsername}:${PlaintextQualysKey}")
$BasicAuthBase64Encoded = [System.Convert]::ToBase64String($BasicAuthString)

$Headers = @{ 
    'Authorization'    = "Basic $BasicAuthBase64Encoded"
    'X-Requested-With' = "QualysPostman"
}

$SearchURL = "https://$QualysPlatform/qps/rest/2.0/search/am/asset"
$SearchPayload = "<ServiceRequest><filters><Criteria field=`"name`" operator=`"EQUALS`">$TestDevice</Criteria></filters></ServiceRequest>"

Try {
    Write-Host "Querying modern Qualys Asset Management index by name..." -ForegroundColor Gray
    
    $Response = Invoke-WebRequest -Uri $SearchURL `
                                  -Method "Post" `
                                  -Headers $Headers `
                                  -ContentType "text/xml" `
                                  -Body $SearchPayload `
                                  -ErrorAction Stop
    
    [xml]$XmlResult = $Response.Content
    $AssetNode = $XmlResult.SelectSingleNode("//Asset")

    if ($AssetNode) {
    $AssetIdNode = $AssetNode.SelectSingleNode("id")
    $NameNode    = $AssetNode.SelectSingleNode("name")

    $AddressNode = $AssetNode.SelectSingleNode(
        ".//HostInterface/address | .//HostInterface/addresses/HostAssetInterfaceAddress/address | .//address"
    )

    $AssetId = if ($AssetIdNode) {
        $AssetIdNode.InnerText.Trim()
    }
    else {
        "<not returned>"
    }

    $Name = if ($NameNode) {
        $NameNode.InnerText.Trim()
    }
    else {
        "<not returned>"
    }

    $TrackIP = if ($AddressNode) {
        $AddressNode.InnerText.Trim()
    }
    else {
        "<not returned>"
    }

    Write-Host "`n[QUALYS MATCH FOUND!]" -ForegroundColor Green
    Write-Host " -> Resolved Asset ID : $AssetId" -ForegroundColor Green
    Write-Host " -> Asset Name Record : $Name" -ForegroundColor Green
    Write-Host " -> Current Tracking IP: $TrackIP" -ForegroundColor Yellow
}

else {
    Write-Host "`n[ALERT]: Qualys returned a valid response, but no asset record exists named '$TestDevice'." -ForegroundColor Yellow
}

} Catch {
    Write-Host "`n[CRITICAL ERROR]: The Qualys API call failed!" -ForegroundColor Red
    Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
}
