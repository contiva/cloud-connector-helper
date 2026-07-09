# Cloud Connector Helper

[![CI](https://github.com/contiva/cloud-connector-helper/actions/workflows/ci.yml/badge.svg)](https://github.com/contiva/cloud-connector-helper/actions/workflows/ci.yml)
[![Latest release](https://img.shields.io/github/v/release/contiva/cloud-connector-helper)](https://github.com/contiva/cloud-connector-helper/releases/latest)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE.md)

Automated installation and lifecycle management for the **SAP Cloud Connector** (and, on Linux, the **SAP JVM**) across Linux, macOS, and Windows.

The helpers determine the currently installed version, discover the latest release published by SAP, download it with the EULA cookie SAP requires, verify the checksum published by SAP, and install or update the software — including service management, configuration preservation, and a readiness check of the administration UI.

## Platform Overview

| Platform | Scripts | Products | Service | Status |
| --- | --- | --- | --- | --- |
| **Linux** (x86_64, glibc) | `install.sh` / `update.sh` | Cloud Connector + SAP JVM 8 | systemd (`scc_daemon`) | Production-ready, tested |
| **macOS** (Apple Silicon & Intel) | `install-macos.sh` / `update-macos.sh` | Cloud Connector | launchd agent (`com.sap.scc`) | Tested — dev/test use only¹ |
| **Windows** (x64) | `install-windows.ps1` / `update-windows.ps1` | Cloud Connector (MSI) | Windows service | ⚠️ Not yet verified² |

¹ SAP supports the macOS Cloud Connector for non-productive scenarios only.
² SAP does not document silent-install MSI properties; verify on a test machine before rollout.

## Quick Start

### Linux

```shell
# Install
bash -c "$(curl -fsSL https://github.com/contiva/cloud-connector-helper/raw/main/install.sh)"

# Update
bash -c "$(curl -fsSL https://github.com/contiva/cloud-connector-helper/raw/main/update.sh)"
```

### macOS

```shell
# Install
bash -c "$(curl -fsSL https://github.com/contiva/cloud-connector-helper/raw/main/install-macos.sh)"

# Update
bash -c "$(curl -fsSL https://github.com/contiva/cloud-connector-helper/raw/main/update-macos.sh)"
```

### Windows

```powershell
# In an elevated PowerShell
Invoke-WebRequest https://github.com/contiva/cloud-connector-helper/raw/main/install-windows.ps1 -OutFile install-windows.ps1
.\install-windows.ps1
```

## Features

- **Version management** — detects the installed version (RPM database, version markers, or Windows registry) and compares it against the versions published on the [SAP Development Tools](https://tools.hana.ondemand.com/#cloud) page.
- **Integrity verification** — every download is validated against the SHA1 checksum file published by SAP before anything is installed.
- **Service lifecycle** — services are stopped before files are replaced and restarted afterwards; the scripts wait until the administration UI responds on port 8443 before reporting success.
- **Configuration preservation** — the Cloud Connector configuration (`config`, `scc_config`) survives updates; RPM-mode updates additionally keep a backup at `/opt/sap/scc.config-backup`.
- **Safety guards** — installations in use are never replaced: running Cloud Connector processes are detected and listed with their PIDs before the scripts refuse to proceed.
- **Automation-friendly** — unattended mode with explicit EULA acceptance, dry-run checks with meaningful exit codes, version pinning, quiet mode with log files, and optional email summaries (Linux).
- **Polished console output** — colored, TTY-aware status output with an installation plan up front and a summary panel at the end; honors `NO_COLOR`.

## Common Options

All platforms share the same core options (PowerShell uses `-PascalCase` switches):

| Option | Description |
| --- | --- |
| `--unattended` | Run without prompts. The installers additionally require `--accept-eula`. |
| `--accept-eula` | Accept the [SAP developer EULA](https://tools.hana.ondemand.com/#cloud) without prompting. |
| `--scc-version <x.y.z>` | Install or update to a specific Cloud Connector version instead of the latest. Unknown versions abort with a list of available ones. |
| `--dry-run` | Show what would happen without changing anything. The updaters exit with code `2` when updates are available and `0` when up to date — ideal for monitoring and cron checks. |
| `--quiet` | Hide verbose tool output; it is appended to a log file and shown only on failure. |

## Linux

### Supported distributions

| Platform family | Package managers | Install mode |
| --- | --- | --- |
| Red Hat Enterprise Linux, CentOS, Rocky Linux, AlmaLinux, Fedora | `dnf`, `yum` | RPM |
| SUSE Linux Enterprise Server, openSUSE | `zypper` | RPM |
| Debian, Ubuntu | `apt-get` | Archive |
| Arch Linux | `pacman` | Archive |

Requirements: `x86_64` architecture and glibc. BSD, AIX, Solaris, other architectures, and musl-based distributions such as Alpine Linux are not supported because SAP publishes these artifacts for Linux x64 glibc environments only. Root privileges (or `sudo`) are required; missing prerequisites (`ca-certificates`, `curl`, `unzip`, `coreutils`, and in archive mode `tar`/`gzip`) are installed automatically.

### Install modes

- **RPM mode** (`dnf`, `yum`, `zypper`): installs SAP's RPM packages; the RPM manages the `scc_daemon` service itself.
- **Archive mode** (`apt-get`, `pacman`): extracts SAP's archive artifacts to `/opt/sap` (override with `INSTALL_ROOT`, `SAPJVM_HOME`, or `SCC_HOME`). On systemd hosts the installer creates a dedicated `sccadmin` system user, installs a `scc_daemon` unit, and enables and starts it:

  ```shell
  INSTALL_ROOT=/srv/sap ./install.sh    # custom location
  systemctl status scc_daemon           # manage the service
  ```

  Without systemd, start the Cloud Connector manually with `JAVA_HOME=/opt/sap/sapjvm_8 /opt/sap/cloud-connector/go.sh`.

### Linux-specific options

- `--jvm-version <x.y.z>` — pin the SAP JVM version (both scripts).
- `update.sh --unattended [email]` — optionally send a summary email via `sendmail`. The summary is sent even when an update fails or the script aborts.
- `--quiet` logs to `/var/log/cloud-connector-helper.log`.

Example — unattended installation (the `install.sh` after the closing quote is the `$0` placeholder required by `bash -c`):

```shell
bash -c "$(curl -fsSL https://github.com/contiva/cloud-connector-helper/raw/main/install.sh)" install.sh --unattended --accept-eula
```

## macOS

> **Note:** SAP supports the macOS Cloud Connector for **development and testing only**. The helpers are designed accordingly and run entirely **without root privileges**.

- Installs to `~/sap/cloud-connector` (override with `INSTALL_ROOT` or `SCC_HOME`) and manages the Cloud Connector as a per-user launchd agent (`com.sap.scc`) that starts at login.
- Uses the native `macosx-aarch64` artifact on Apple Silicon and `macosx-x64` on Intel.
- Requires an installed Java runtime (1.8, 17, 21, or 25), discovered via `/usr/libexec/java_home`. On Apple Silicon use a native ARM build such as [SapMachine](https://sapmachine.io) (`brew install --cask sapmachine-jdk`) — SAP JVM 8 is not available for ARM.
- Logs: helper output in `~/Library/Logs/cloud-connector-helper.log` (with `--quiet`), Cloud Connector output in `~/Library/Logs/com.sap.scc.log`.

Manage the launch agent:

```shell
launchctl print "gui/$(id -u)/com.sap.scc"                                     # status
launchctl bootout "gui/$(id -u)/com.sap.scc"                                   # stop
launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/com.sap.scc.plist    # start
```

## Windows

> **Warning:** SAP does not officially document silent-install MSI properties for the Cloud Connector, and these scripts have **not yet been verified on a Windows host**. Test on a non-productive machine first.

- Installs and upgrades the official MSI silently via `msiexec /qn /norestart` with the installer defaults (`C:\SAP\scc`, port 8443). A verbose MSI log is written to `%TEMP%\cloud-connector-helper-msi.log`.
- The MSI registers the *SAP Cloud Connector* Windows service; the updater stops it before and starts it after the upgrade.
- Requires administrator privileges (except for `-DryRun`) and an installed JDK (SAP JVM 8, SapMachine 17/21, or another supported JDK); the scripts warn if none is found via `JAVA_HOME` or `PATH`.

```powershell
.\install-windows.ps1 [-Unattended -AcceptEula] [-SccVersion <x.y.z>] [-DryRun]
.\update-windows.ps1  [-Unattended] [-SccVersion <x.y.z>] [-DryRun]
```

## Automation

The updaters are designed for scheduled, unattended operation:

```shell
# Cron example (Linux): check daily at 03:00, update and mail a summary
0 3 * * * bash -c "$(curl -fsSL https://github.com/contiva/cloud-connector-helper/raw/main/update.sh)" update.sh --unattended ops@example.com --quiet

# Monitoring example: exit code 2 signals available updates without changing anything
bash update.sh --dry-run
```

After first installation, log in at `https://<host>:8443` as `Administrator` with the initial password `manage` (a password change is enforced at first login).

## Security

- Downloads are restricted to HTTPS with TLS 1.2 or newer.
- Every artifact is verified against the SHA1 checksum published by SAP. SHA1 is not collision-resistant, but it is the upstream integrity metadata SAP provides for these downloads.
- Temporary files are created in private `mktemp` directories and removed after use — also on failure.
- The scripts fail early on unsupported operating systems, architectures, and package managers.
- Unattended runs never accept the EULA implicitly at install time; explicit `--accept-eula` / `-AcceptEula` is required.

## License

Released under the [MIT License](LICENSE.md).

"SAP" and "SAP Cloud Connector" are trademarks or registered trademarks of SAP SE or its affiliates in Germany and other countries. This project is not affiliated with or endorsed by SAP SE.
