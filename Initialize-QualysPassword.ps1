$SecretDirectory = "<secret-directory>"
$SecretPath = "$SecretDirectory\<secret-file-name.enc>"


if (-not (Test-Path $SecretDirectory)) {
    New-Item -ItemType Directory -Path $SecretDirectory -Force | Out-Null
}

$CurrentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
Write-Host "Configuring Qualys Key for account: $CurrentUser" -ForegroundColor Yellow
Write-Host "Please paste your Qualys API Key below and press Enter:" -ForegroundColor Cyan
$SecureInput = Read-Host -AsSecureString

try {
    $SecureInput | ConvertFrom-SecureString | Out-File -FilePath $SecretPath -Force
    
    Write-Host "`n[SUCCESS] Secret securely encrypted and saved to $SecretPath" -ForegroundColor Green
    Write-Host "Only $CurrentUser can decrypt or read this file on this machine." -ForegroundColor Yellow
}
catch {
    Write-Error "Failed to save file: $_"
}
