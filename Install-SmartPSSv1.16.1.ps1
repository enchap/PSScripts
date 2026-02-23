$ErrorActionPreference = "Stop"
if (-NOT ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Warning "Please run as Administrator to install the software."
    Exit
}

# File Variables
$PublicProfilePath = "C:\Data\SmartPSS\"
$TokenFile         = "C:\Data\SmartPSS\token-file"

# 2. Prepare Directory

if (!(Test-Path -Path $PublicProfilePath)) {
    New-Item -ItemType Directory -Path $PublicProfilePath -Force | Out-Null
}

# 3. Fetch Installer Metadata

# Configuration for Pairing
$PortalUrl  = "https://artifacts.digitalsecurityguard.com"
$OrgSlug    = "en-projects"
$AppId      = "powershell-script"
$InstanceId = if ($env:COMPUTERNAME) { $env:COMPUTERNAME } else { "unknown" }
$Platform   = "windows"
$Arch       = "x64"

# Start Pairing
$Body = @{
    org_slug        = $OrgSlug
    app_id          = $AppId
    instance_id     = $InstanceId
    hostname        = $InstanceId
    platform        = $Platform
    arch            = $Arch
} | ConvertTo-Json

Write-Host "Initiating device pairing for $OrgSlug." -ForegroundColor Cyan
$Pairing = Invoke-RestMethod -Uri "$PortalUrl/api/v2/pairing/start" -Method POST -ContentType "application/json" -Body $Body

$PairingCode = $Pairing.pairing_code
$PairingURL = $Pairing.pairing_url
Write-Host "`nPairing Code: $PairingCode" -ForegroundColor Yellow
Write-Host "`nApproval URL: $PortalUrl$($PairingURL)" -ForegroundColor Cyan
Write-Host "`nWaiting for approval..."

# Poll for Approval
$SessionToken = $null
:PairingLoop while ($true) {
    $Status = Invoke-RestMethod -Uri "$PortalUrl/api/v2/pairing/status/$PairingCode" -Method GET
    
    switch ($Status.status) {
        "approved" {
            Write-Host "Approved! Exchanging tokens..." -ForegroundColor Green
            $ExchangeBody = @{
                pairing_code   = $pairing.pairing_code
                exchange_token = $Status.exchange_token 
            } | ConvertTo-Json

            $Token = Invoke-RestMethod -Uri "$PortalUrl/api/v2/pairing/exchange" -Method POST -ContentType "application/json" -Body $ExchangeBody
            $SessionToken = $token.access_token
            $token.access_token | Out-File -FilePath $TokenFile -NoNewline -Encoding utf8
            Write-Host "Token saved to $TokenFile"
            Write-Host "Expires: $($token.expires_at)"
            break PairingLoop
        }
        "denied" {
            Write-Error "Pairing was denied."
            exit 1
        }
        "expired" {
            Write-Error "Pairing expired."
            exit 1
        }
    }
    Start-Sleep -Seconds 5
}

# Add token to authenticate
$Headers = @{
    "Authorization" = "Bearer $SessionToken"
    "Content-Type"  = "application/json"
}

# Proceed with existing logic using $Headers for the MSI Metadata request
Write-Host "Using session token to fetch installer." -ForegroundColor Cyan

$FetchBody = @{
    project = "install"
    tool = "smartpss"
    platform_arch = "windows-x64"
    source_version = "1.16.1.R.20170220"

} | ConvertTo-Json

$response = Invoke-RestMethod -Uri "$PortalUrl/api/v2/presign-latest" -Method POST -Headers $Headers -Body $FetchBody

# Set Installer Path to the Public Profile Path
$InstallerPath = Join-Path -Path $PublicProfilePath -ChildPath $response.filename

# 4. Download and Verify

Write-Host "Downloading SmartPSS to $PublicProfilePath." -ForegroundColor Cyan
Invoke-WebRequest -Uri $response.url -OutFile $InstallerPath

# Verify checksum
$hash = (Get-FileHash -Path $InstallerPath -Algorithm SHA256).Hash.ToLower()
if ($hash -eq $response.sha256) {
    Write-Host "Checksum verified." -ForegroundColor Green
}
else {
    Write-Error "Checksum mismatch! Download may be corrupted."
    Exit
}

# 5. Install SmartPSS

Write-Host "Installing." -ForegroundColor Cyan
$InstallArgs = "/S /v/qn"
Start-Process $InstallerPath -ArgumentList $InstallArgs -Wait
Start-Sleep -Seconds 5

Write-Host "Setup complete." -ForegroundColor Green
