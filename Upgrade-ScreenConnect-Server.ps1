<# Upgrade-ScreenConnect-Server - Isaac Good

Requirements:
- ScreenConnect server must already be installed.
- ScreenConnect license must be eligible to upgrade to the current version!
  If not, the upgrade will break your SC install and you'll have to uninstall,
  reinstall your old version and restore from the backup files.
- Upgrade will only be performed if the installer is newer than the currently installed version.

Version 1.0 - 2025-09-11
    Forked from Upgrade-ScreenConnect-Server 0.0.1 by David Szpunar https://github.com/dszp/MSP-Scripts/blob/main/ScreenConnect%20Server/Upgrade-ScreenConnect-Server.ps1
    Added - Automatic download of current version, optionally Stable or Pre-Release
    Added - Keep each version of the installer and remove if older than x days
    Added - Backup before upgrade and remove backups older than x days
    Added - Option to disable transition effects in the UI
    Added - Syncro RMM alert creation for errors
    Changed - Use license page URL to scrape for download URL
#>

### START CONFIG

$DisableTransitionEffects = $true
$BackupFolder = "${env:ProgramFiles(x86)}\ScreenConnect Backups"
$DaysToKeepBackups = '180'
$DownloadFolder = "${env:ProgramFiles(x86)}\ScreenConnect Installers"
$DaysToKeepInstallers = '180'
$ReleaseType = 'Release' # Use 'Release' for Stable Release or 'Debug' for Pre-Release
# Download page to scrape for the latest version
# In ScreenConnect go to: Administration > License > ... > Upgrade License
# and copy that URL below. You'll need to update this whenever you upgrade/renew your license
$DownloadPage = "https://order.screenconnect.com/Create-Order?UpgradeLicense="

### END CONFIG

function Exit-WithError {
    param ($Text)
    if ($Datto) {
        Write-Information "<-Start Result->Alert=$Text<-End Result->"
    } elseif ($Syncro) {
        Write-Information $Text
        Rmm-Alert -Category "Upgrade ScreenConnect Server" -Body $Text
    } else {
        Write-Information $Text
    }
    Start-Sleep 10 # Give us a chance to view output when running interactively
    exit 1
}

function Get-Download {
    param ($URL, $DownloadFolder, $FileName)
    $DownloadSize = (Invoke-WebRequest $URL -Method Head -UseBasicParsing).Headers.'Content-Length'
    if (Test-Path $DownloadFolder -ErrorAction SilentlyContinue) {
        Write-Output "Download folder exists: $DownloadFolder"
    } else {
        Write-Output "Creating download folder: $DownloadFolder"
        New-Item -ItemType Directory -Path $DownloadFolder | Out-Null
    }
    Write-Output "Downloading: $URL ($([math]::round($DownloadSize/1MB, 2)) MB)`nDestination: $DownloadFolder\$FileName..."
    Start-BitsTransfer -Source $URL -Destination $DownloadFolder\$FileName -Priority Normal
    # Verify download success
    $DownloadSizeOnDisk = (Get-ItemProperty $DownloadFolder\$FileName -ErrorAction SilentlyContinue).Length
    if ($DownloadSize -ne $DownloadSizeOnDisk) {
        Remove-Item $DownloadFolder\$FileName
        Exit-WithError "Download size ($DownloadSize) and size on disk ($DownloadSizeOnDisk) do not match, download failed."
    }
}

# Test if installed
$ServicePath = [System.IO.Path]::Combine(${env:ProgramFiles(x86)}, "ScreenConnect\Bin", "ScreenConnect.Service.exe")
if (!(Test-Path $ServicePath)) {
    Exit-WithError "Unable to locate ScreenConnect Service executable file. Quitting."
}
$ServiceVersion = (Get-Command $ServicePath).FileVersionInfo.FileVersion
Write-Host "Installed Path:`t`t" $ServicePath
Write-Host "Installed Version:`t" $ServiceVersion

# Determine installer URL
$Request = Invoke-WebRequest -Uri $DownloadPage -UseBasicParsing
$DownloadURL = ($Request).Links.href | Where-Object { $_ -match "https://[^`"]+ScreenConnect_[\d\.]+_$ReleaseType\.msi" } | Select-Object -First 1

# Check existing version against version to install
$InstallerVersion = [regex]::new('(?<=ScreenConnect_)[\d\.]+').matches($DownloadURL).value
Write-Host "Installer URL Version:`t" $InstallerVersion
$installedVer = [version]$ServiceVersion
$installerVer = [version]$InstallerVersion
if ($installerVer -eq $installedVer) {
    Exit-WithError "The installer is the same version as current! Exiting."
} elseif ($installerVer -lt $installedVer) {
    Exit-WithError "The installer is older than current install! Exiting."
} elseif ($installerVer -gt $installedVer) {
    Write-Host "The installer is newer than current install. Proceeding..."
}

# Backup before upgrading
$BackupSubFolder = "$BackupFolder\SC Backup of $ServiceVersion - $(Get-Date -Format 'yyyy-MM-dd-HHmmss')"
Write-Host "Backing up to: $BackupSubFolder"
New-Item -ItemType Directory -Path $BackupSubFolder | Out-Null
$Backup = robocopy "${env:ProgramFiles(x86)}\ScreenConnect" "$BackupSubFolder" /s /r:6
if ($LastExitCode -ne 1) {
    Exit-WithError "Backup was not successful! Exiting. Backup output:`n$Backup"
}

# Start upgrade
$FileName = $DownloadURL | Split-Path -Leaf
Get-Download $DownloadURL $DownloadFolder $FileName
$InstallerLogFile = [io.path]::ChangeExtension([io.path]::GetTempFileName(), ".log")
Write-Host "InstallerLogFile:`t" $InstallerLogFile
$Arguments = " /c msiexec /i `"$DownloadFolder\$FileName`" /qn /l*v `"$InstallerLogFile`""
$Process = Start-Process cmd -ArgumentList $Arguments -Wait -PassThru
# Get the current version again
[version]$ServiceVersion = (Get-Command $ServicePath).FileVersionInfo.FileVersion
# Check if upgrade was successful
if ($Process.ExitCode -ne 0 -or $installerVer -ne $ServiceVersion) {
    Get-Content $InstallerLogFile -ErrorAction SilentlyContinue | Select-Object -Last 200
    Exit-WithError "Upgrade failed, please troubleshoot manually. Log file: $InstallerLogFile"
} else {
    Write-Host "Upgrade successfully completed."
    # Disable transitions
    if ($DisableTransitionEffects) {
        Start-Sleep -Seconds 10 # Give the service a moment to settle
        $file = "${env:ProgramFiles(x86)}\ScreenConnect\App_Themes\Base.css"
        if (Test-Path "$file") {
	        (Get-Content $file) -replace 'TransitionTime: 0.+s', 'TransitionTime: 0s' | Set-Content $file
        }
    }
    # Remove old backups and installers
    Get-ChildItem "$BackupFolder\SC Backup*" | Where-Object { $_.LastWriteTime -lt $((Get-Date).AddDays(-$DaysToKeepBackups)) } | Remove-Item -Recurse
    Get-ChildItem "$DownloadFolder\*" | Where-Object { $_.LastWriteTime -lt $((Get-Date).AddDays(-$DaysToKeepInstallers)) } | Remove-Item
}
