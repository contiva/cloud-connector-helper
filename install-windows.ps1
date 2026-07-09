<#
.SYNOPSIS
    Installs SAP Cloud Connector on Windows via the official MSI installer.
.DESCRIPTION
    Downloads the latest (or a chosen) SAP Cloud Connector MSI from the SAP
    development tools page, verifies its SHA1 checksum, and installs it
    silently via msiexec. The MSI registers the "SAP Cloud Connector"
    Windows service. Requires administrator privileges and an installed
    JDK (SAP JVM 8, SapMachine 17/21, or another supported JDK).

    NOTE: SAP does not officially document silent MSI properties for the
    Cloud Connector; this script uses msiexec /qn with installer defaults
    (C:\SAP\scc, port 8443). Verify on a test machine before rolling out.
.PARAMETER Unattended
    Run without prompts; requires -AcceptEula.
.PARAMETER AcceptEula
    Accept the SAP developer EULA without prompting.
.PARAMETER SccVersion
    Install this Cloud Connector version instead of the latest.
.PARAMETER DryRun
    Show what would be installed without changing anything.
#>
[CmdletBinding()]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Interactive console script with colored output')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingBrokenHashAlgorithms', '', Justification = 'SAP publishes SHA1 checksums as the upstream integrity metadata')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Switches are read via dynamic scoping inside helper functions')]
param(
    [switch]$Unattended,
    [switch]$AcceptEula,
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

function Test-JavaAvailable {
    if ($env:JAVA_HOME -and (Test-Path (Join-Path $env:JAVA_HOME "bin\java.exe"))) {
        return $env:JAVA_HOME
    }
    $java = Get-Command java.exe -ErrorAction SilentlyContinue
    if ($java) {
        return (Split-Path (Split-Path $java.Source -Parent) -Parent)
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

function Install-SccMsi([string]$MsiPath) {
    $logPath = Join-Path $env:TEMP "cloud-connector-helper-msi.log"
    Write-Info "Installing SAP Cloud Connector (msiexec /qn, log: $logPath)..."
    $process = Start-Process msiexec.exe -ArgumentList "/i", "`"$MsiPath`"", "/qn", "/norestart", "/L*v", "`"$logPath`"" -Wait -PassThru
    if ($process.ExitCode -ne 0) {
        Fail "msiexec exited with code $($process.ExitCode). See $logPath for details."
    }
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

if ($Unattended -and -not $AcceptEula) {
    Fail "Unattended mode requires -AcceptEula. Review the EULA at $ToolsUrl first."
}
if (-not $DryRun -and -not (Test-Administrator)) {
    Fail "Administrator privileges are required. Start PowerShell as administrator."
}

$javaHome = Test-JavaAvailable
$page = Get-ToolsPage
$cookie = Get-EulaCookie $page
$version = Resolve-SccVersion $page $SccVersion
$installedVersion = Get-InstalledSccVersion

Write-Section "Installation plan"
Write-Host "  System:               Windows $([Environment]::OSVersion.Version), x64"
if ($javaHome) {
    Write-Host "  Java runtime:         $javaHome"
} else {
    Write-Host "  Java runtime:         not found"
}
Write-Host "  SAP Cloud Connector:  $version (MSI, installer defaults: C:\SAP\scc, port 8443)"
if ($installedVersion) {
    Write-Host "  Currently installed:  $installedVersion"
}
Write-Host ""
if (-not $javaHome) {
    Write-Note "No JDK found via JAVA_HOME or PATH. The Cloud Connector requires Java 1.8, 17, 21, or 25 (e.g. SapMachine: https://sapmachine.io). The MSI installation may fail without one."
}
Write-Note "This script is not yet verified on a production Windows host; test before rolling out."
Write-Host ""

if ($DryRun) {
    Write-Ok "Dry run complete - nothing was installed."
    exit 0
}

Write-Host "Please read the EULA at: https://$($cookie.Value)"
if ($AcceptEula) {
    Write-Ok "EULA accepted via -AcceptEula."
} elseif (-not (Confirm-YesNo "Do you accept the EULA?")) {
    Fail "You did not accept the EULA. Install aborted."
}

if (-not (Confirm-YesNo "Install SAP Cloud Connector $version?" "y")) {
    Write-Note "Nothing installed."
    exit 0
}

$workDir = Join-Path $env:TEMP "cloud-connector-helper-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $workDir | Out-Null
try {
    $msiPath = Get-SccDownload $cookie $version $workDir
    Install-SccMsi $msiPath
} finally {
    Remove-Item -Recurse -Force $workDir -ErrorAction SilentlyContinue
}

$service = Get-Service | Where-Object { $_.DisplayName -like $ServiceDisplayName } | Select-Object -First 1
if ($service -and $service.Status -ne "Running") {
    Write-Info "Starting the $($service.DisplayName) service..."
    Start-Service $service.Name -ErrorAction SilentlyContinue
}

Write-Section "Installation finished"
Write-Host "Waiting for the administration UI to become available..."
if (Wait-SccUi 90) {
    Write-Ok "Administration UI is up."
} else {
    Write-Note "The administration UI did not respond within 90s; check the SAP Cloud Connector service in services.msc."
}
Write-Host ""
Write-Host "  URL:      https://localhost:8443"
Write-Host "  User:     Administrator"
Write-Host "  Password: manage (must be changed at first login)"
Write-Host "  Service:  services.msc -> SAP Cloud Connector"
Write-Host ""
