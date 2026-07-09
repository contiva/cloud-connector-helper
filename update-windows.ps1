<#
.SYNOPSIS
    Updates an MSI-based SAP Cloud Connector installation on Windows.
.DESCRIPTION
    Compares the installed SAP Cloud Connector version (from the Windows
    registry) with the latest version on the SAP development tools page,
    downloads the newer MSI, verifies its SHA1 checksum, and upgrades via
    msiexec. The "SAP Cloud Connector" Windows service is stopped before
    and started after the upgrade. Requires administrator privileges.

    NOTE: SAP does not officially document silent MSI properties for the
    Cloud Connector; this script uses msiexec /qn with installer defaults.
    Verify on a test machine before rolling out.
.PARAMETER Unattended
    Run without prompts.
.PARAMETER SccVersion
    Update to this Cloud Connector version instead of the latest.
.PARAMETER DryRun
    Only check for updates; exit code 2 if an update is available.
#>
[CmdletBinding()]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Interactive console script with colored output')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingBrokenHashAlgorithms', '', Justification = 'SAP publishes SHA1 checksums as the upstream integrity metadata')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Switches are read via dynamic scoping inside helper functions')]
param(
    [switch]$Unattended,
    [string]$SccVersion = "",
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ToolsUrl = "https://tools.hana.ondemand.com/#cloud"
$DownloadBaseUrl = "https://tools.hana.ondemand.com/additional"
$UserAgent = "cloud-connector-helper/1.4"
$ServiceDisplayName = "SAP Cloud Connector*"

function Write-Info([string]$Message) { Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Ok([string]$Message) { Write-Host " + $Message" -ForegroundColor Green }
function Write-Note([string]$Message) { Write-Host " ! $Message" -ForegroundColor Yellow }
function Write-Section([string]$Message) { Write-Host ""; Write-Host $Message -ForegroundColor White }
function Fail([string]$Message) { Write-Host "ERROR: $Message" -ForegroundColor Red; exit 1 }

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-ToolsPage {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $response = Invoke-WebRequest -Uri $ToolsUrl -UseBasicParsing -UserAgent $UserAgent
    return $response.Content
}

function Get-EulaCookie([string]$Page) {
    $nameMatch = [regex]::Match($Page, "eulaConst\.devLicense\.cookieName = '([^']+)'")
    $valueMatch = [regex]::Match($Page, "eulaConst\.devLicense\.cookieValue = '([^']+)'")
    if (-not $nameMatch.Success -or -not $valueMatch.Success) {
        Fail "Failed to extract EULA cookie information from $ToolsUrl."
    }
    return @{ Name = $nameMatch.Groups[1].Value; Value = $valueMatch.Groups[1].Value }
}

function Get-AvailableVersionList([string]$Page) {
    $found = [regex]::Matches($Page, "sapcc-([0-9.]+)-windows-x64\.msi") |
        ForEach-Object { $_.Groups[1].Value } |
        Sort-Object -Unique { [version]$_ }
    return @($found)
}

function Resolve-SccVersion([string]$Page, [string]$Override) {
    $versions = Get-AvailableVersionList $Page
    if ($versions.Count -eq 0) {
        Fail "Could not find any Cloud Connector Windows versions at $ToolsUrl."
    }
    if ($Override) {
        if ($versions -notcontains $Override) {
            Fail "Version $Override is not available for windows-x64. Available versions: $($versions -join ' ')"
        }
        return $Override
    }
    return $versions[-1]
}

function Get-InstalledSccVersion {
    $uninstallKeys = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )
    foreach ($keyPath in $uninstallKeys) {
        $entry = Get-ItemProperty -Path $keyPath -ErrorAction SilentlyContinue |
            Where-Object { $_.PSObject.Properties.Name -contains "DisplayName" -and $_.DisplayName -like "SAP Cloud Connector*" } |
            Select-Object -First 1
        if ($entry -and $entry.PSObject.Properties.Name -contains "DisplayVersion") {
            return $entry.DisplayVersion
        }
    }
    return ""
}

function Get-SccDownload([hashtable]$Cookie, [string]$Version, [string]$TargetDir) {
    $artifact = "sapcc-$Version-windows-x64.msi"
    $msiPath = Join-Path $TargetDir $artifact
    $sha1Path = "$msiPath.sha1"
    $headers = @{ Cookie = "$($Cookie.Name)=$($Cookie.Value)" }

    Write-Info "Downloading SAP Cloud Connector $Version..."
    try {
        Invoke-WebRequest -Uri "$DownloadBaseUrl/$artifact" -OutFile $msiPath -Headers $headers -UseBasicParsing -UserAgent $UserAgent
        Invoke-WebRequest -Uri "$DownloadBaseUrl/$artifact.sha1" -OutFile $sha1Path -Headers $headers -UseBasicParsing -UserAgent $UserAgent
    } catch {
        Fail "Download failed: $($_.Exception.Message). Check network connectivity and proxy settings."
    }

    $expected = (Get-Content $sha1Path -Raw).Trim().Split(" ")[0]
    $actual = (Get-FileHash -Path $msiPath -Algorithm SHA1).Hash.ToLowerInvariant()
    if (-not $expected) { Fail "SHA1 file is empty: $sha1Path" }
    if ($expected.ToLowerInvariant() -ne $actual) { Fail "Hash verification failed for $artifact." }
    return $msiPath
}

function Confirm-YesNo([string]$Prompt, [string]$Default = "n") {
    if ($Unattended) {
        Write-Host "${Prompt}: Auto-accepting for unattended mode."
        return $true
    }
    if ($Default -eq "y") {
        $response = Read-Host "$Prompt (Y/n)"
        return ($response -eq "" -or $response -match "^[yY]")
    }
    $response = Read-Host "$Prompt (y/N)"
    return ($response -match "^[yY]")
}

function Wait-SccUi([int]$TimeoutSeconds = 90) {
    $waited = 0
    while ($waited -lt $TimeoutSeconds) {
        try {
            # Ignore certificate errors; the Cloud Connector uses a self-signed certificate.
            $request = [Net.HttpWebRequest]::Create("https://localhost:8443/")
            $request.ServerCertificateValidationCallback = { $true }
            $request.Timeout = 3000
            $response = $request.GetResponse()
            $response.Close()
            return $true
        } catch {
            Start-Sleep -Seconds 3
            $waited += 3
        }
    }
    return $false
}

# --- main -------------------------------------------------------------------

if (-not $DryRun -and -not (Test-Administrator)) {
    Fail "Administrator privileges are required. Start PowerShell as administrator."
}

$installedVersion = Get-InstalledSccVersion
if (-not $installedVersion) {
    Fail "No MSI-based SAP Cloud Connector installation found in the registry. Run install-windows.ps1 first."
}

$page = Get-ToolsPage
$cookie = Get-EulaCookie $page
$targetVersion = Resolve-SccVersion $page $SccVersion

if ($DryRun) {
    Write-Section "Update check (dry run)"
    if ($installedVersion -eq $targetVersion) {
        Write-Ok "SAP Cloud Connector: $installedVersion is up to date"
        Write-Host ""
        Write-Ok "Everything is up to date."
        exit 0
    }
    Write-Note "SAP Cloud Connector: UPDATE AVAILABLE ($installedVersion installed, $targetVersion available)"
    Write-Host ""
    Write-Host "1 update available. Run without -DryRun to install it."
    exit 2
}

Write-Info "SAP Cloud Connector: installed $installedVersion, latest available $targetVersion"
if ($installedVersion -eq $targetVersion) {
    Write-Ok "The latest version of SAP Cloud Connector is already installed."
    exit 0
}

if (-not (Confirm-YesNo "Do you accept the EULA (https://$($cookie.Value))?")) {
    Fail "You did not accept the EULA. Update aborted."
}
if (-not (Confirm-YesNo "Update SAP Cloud Connector to $targetVersion?" "y")) {
    Write-Note "Update skipped by user."
    exit 0
}

$workDir = Join-Path $env:TEMP "cloud-connector-helper-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $workDir | Out-Null
try {
    $msiPath = Get-SccDownload $cookie $targetVersion $workDir

    $service = Get-Service | Where-Object { $_.DisplayName -like $ServiceDisplayName } | Select-Object -First 1
    if ($service -and $service.Status -eq "Running") {
        Write-Info "Stopping the $($service.DisplayName) service..."
        Stop-Service $service.Name -Force
        $service.WaitForStatus("Stopped", [TimeSpan]::FromSeconds(60))
    }

    $logPath = Join-Path $env:TEMP "cloud-connector-helper-msi.log"
    Write-Info "Updating SAP Cloud Connector (msiexec /qn, log: $logPath)..."
    $process = Start-Process msiexec.exe -ArgumentList "/i", "`"$msiPath`"", "/qn", "/norestart", "/L*v", "`"$logPath`"" -Wait -PassThru
    if ($process.ExitCode -ne 0) {
        if ($service) {
            Start-Service $service.Name -ErrorAction SilentlyContinue
        }
        Fail "msiexec exited with code $($process.ExitCode). See $logPath for details."
    }

    $service = Get-Service | Where-Object { $_.DisplayName -like $ServiceDisplayName } | Select-Object -First 1
    if ($service -and $service.Status -ne "Running") {
        Write-Info "Starting the $($service.DisplayName) service..."
        Start-Service $service.Name
    }
} finally {
    Remove-Item -Recurse -Force $workDir -ErrorAction SilentlyContinue
}

Write-Host "Waiting for the administration UI to become available..."
if (Wait-SccUi 90) {
    Write-Ok "Administration UI is up."
} else {
    Write-Note "The administration UI did not respond within 90s; check the SAP Cloud Connector service in services.msc."
}
Write-Ok "All updates completed."
