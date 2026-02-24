if (-NOT ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
### 1. Admin Priv ###
    Write-Warning "Please run as Administrator to install the software."
    Exit
}

# File Variables
$PublicProfilePath = "C:\Data\SmartPSS\"
$TokenFile         = "C:\Data\SmartPSS\token-file"

#### 2. Prepare Directory ###

if (!(Test-Path -Path $PublicProfilePath)) {
    New-Item -ItemType Directory -Path $PublicProfilePath -Force | Out-Null
}

#### 3. Fetch Installer Metadata ###

# Configuration for Pairing
$PortalUrl  = "https://artifacts.digitalsecurityguard.com"
$OrgSlug    = "en-projects"
$AppID      = "powershell-script"
$InstanceID = if ($env:COMPUTERNAME) { $env:COMPUTERNAME } else { "unknown" }
$platform   = "windows"
$arch       = "x64"

# Start Pairing
$body = @{
    org_slug        = $OrgSlug
    app_id          = $AppID
    instance_id     = $InstanceID
    hostname        = $InstanceID
    platform        = $platform
    arch            = $arch
} | ConvertTo-Json

Write-Host "Initiating device pairing for $OrgSlug." -ForegroundColor Cyan
$Pairing = Invoke-RestMethod -Uri "$PortalUrl/api/v2/pairing/start" -Method POST -ContentType "application/json" -Body $body

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

            # Cache session token
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
    latest_filename = "SmartPSS.exe"

} | ConvertTo-Json

$response = Invoke-RestMethod -Uri "$PortalUrl/api/v2/presign-latest" -Method POST -Headers $Headers -Body $FetchBody

# Set Installer Path to the Public Profile Path
$InstallerPath = Join-Path -Path $PublicProfilePath -ChildPath $response.filename

#### 4. Download and Verify ###

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

#### 5. Install SmartPSS ###

Write-Host "Installing SmartPSS." -ForegroundColor Cyan
$InstallArgs = "/S"
Start-Process $InstallerPath -ArgumentList $InstallArgs -Wait
Start-Sleep -Seconds 5

Write-Host "Setup complete." -ForegroundColor Green

### 6. Remove PC-NVR ###

# Stop the PC-NVR process if it's currently running
Write-Host "Stopping PC-NVR process." -ForegroundColor Cyan
Get-Process "PC-NVR" -ErrorAction SilentlyContinue | Stop-Process -Force

# Define the known installation paths for PC-NVR
$paths = @(
    "C:\Program Files (x86)\Smart Professional Surveillance System\PC-NVR",
    "C:\Program Files\Smart Professional Surveillance System\PC-NVR"
)

# Hunt for the uninstaller and execute if it exists
foreach ($path in $paths) {
    if (Test-Path $path) {
        Write-Host "PC-NVR directory found at: $path" -ForegroundColor Cyan
        
        # Look for any file named uninst.exe, uninstall.exe, or unins000.exe
        $uninstaller = Get-ChildItem -Path $path -Filter "*unins*.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
        
        if ($uninstaller) {
            Write-Host "Executing hidden uninstaller: $($uninstaller.Name)..." -ForegroundColor Green
            Start-Process -FilePath $uninstaller.FullName -ArgumentList "/S" -Wait
        } 
        else {
            Write-Host "No uninstaller found. Proceeding to force-remove files..." -ForegroundColor Yellow
        }

        # Wait for locks to release, then forcefully delete the directory
        Start-Sleep -Seconds 3 
        if (Test-Path $path) {
            Remove-Item -Path $path -Recurse -Force -ErrorAction SilentlyContinue
            Write-Host "Scrubbed leftover PC-NVR files." -ForegroundColor Green
        }
    }
}

# Removed leftover files

Write-Host "Hunting leftover files and shortcuts." -ForegroundColor Cyan
$leftovers = @(
    "C:\Users\Public\PC-NVR",
    "C:\Program Files (x86)\Smart Professional Surveillance System\SmartPSS\Skin\theme1\PC-NVR",
    "C:\Users\Public\Desktop\PC-NVR.lnk"
)

foreach ($item in $leftovers) {
    if (Test-Path $item) {
        Remove-Item -Path $item -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "Successfully removed: $item" -ForegroundColor Green
    }
}

# Remove the auto-start registry keys so Windows doesn't look for a missing app on reboot
Write-Host "Cleaning up Registry startup entries..." -ForegroundColor Cyan
$regPathMachine = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"
$regPathUser = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"

Remove-ItemProperty -Path $regPathMachine -Name "PC-NVR" -ErrorAction SilentlyContinue
Remove-ItemProperty -Path $regPathUser -Name "PC-NVR" -ErrorAction SilentlyContinue

Write-Host "PC-NVR removed." -ForegroundColor Green
