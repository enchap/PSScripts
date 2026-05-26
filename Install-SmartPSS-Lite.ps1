if (!([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    # Admin Check
    Write-Warning "Please run as Administrator."
    Start-Sleep -Seconds 3
    Exit
}

### 1. Install SmartPSS ###

$InstallerPath = "C:\Data\SmartPSS Lite 8_25.exe"
Write-Host "`nInstalling SmartPSS Lite." -ForegroundColor Cyan
$InstallArgs = "/S"
Start-Process $InstallerPath -ArgumentList $InstallArgs -Wait
Start-Sleep -Seconds 5

Write-Host "Setup complete." -ForegroundColor Green

### 2. Remove PC-NVR ###

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
            Write-Host "Executing hidden uninstaller: $($uninstaller.Name)." -ForegroundColor Green
            Start-Process -FilePath $uninstaller.FullName -ArgumentList "/S" -Wait
        } 
        else {
            Write-Host "No uninstaller found. Proceeding to force-remove files." -ForegroundColor Yellow
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
Write-Host "Cleaning up Registry startup entries." -ForegroundColor Cyan
$regPathMachine = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"
$regPathUser = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"

Remove-ItemProperty -Path $regPathMachine -Name "PC-NVR" -ErrorAction SilentlyContinue
Remove-ItemProperty -Path $regPathUser -Name "PC-NVR" -ErrorAction SilentlyContinue

Write-Host "PC-NVR removed." -ForegroundColor Green

### 3. Final Installation Validation ###
Write-Host "Validating SmartPSS installation." -ForegroundColor Cyan

$uninstallPaths = @(
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
    "HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
)

# Search the registry for the newly installed application
$installedApp = Get-ItemProperty $uninstallPaths -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match "SmartPSS" }

if ($installedApp) {
    Write-Host "`nSmartPSS installation success." -ForegroundColor Green
} 
else {
    Write-Host "`nSmartPSS installation failed." -ForegroundColor Red
}
