# Easy Installer and Updater for SAP Cloud Connector and SAP JVM

This suite of Bash scripts automates the update or installation process of the SAP Cloud Connector and the SAP Java Virtual Machine (SAPJVM) on common glibc-based Linux distributions with `x86_64` architecture. It facilitates the management of the lifecycle for both the SAP Cloud Connector and SAP JVM by automating version checks, downloading the latest versions available online, and ensuring the integrity of downloaded packages through the checksum files published by SAP.

## Supported Platforms

| Platform family | Package managers | Install mode |
| --- | --- | --- |
| Red Hat Enterprise Linux, CentOS, Rocky Linux, AlmaLinux, Fedora | `dnf`, `yum` | RPM |
| SUSE Linux Enterprise Server, openSUSE | `zypper` | RPM |
| Debian, Ubuntu | `apt-get` | Archive |
| Arch Linux | `pacman` | Archive |

The scripts support two install modes:

- **RPM mode** on RPM-based distributions with `dnf`, `yum`, or `zypper`.
- **Archive mode** on `apt-get` or `pacman` based distributions, using SAP's Linux `zip`/`tar.gz` artifacts under `/opt/sap` by default.

These are Linux installers, not portable UNIX installers. They do not support macOS, BSD, AIX, Solaris, non-`x86_64` architectures, or musl-based distributions such as Alpine Linux because the SAP artifacts handled here are published for Linux x64 glibc environments.

## Overview

The toolkit includes:

1. **Updater Script**: Checks and updates the currently installed versions of the SAP Cloud Connector and SAP Java Virtual Machine (SAPJVM) if newer versions are available.
2. **Installer Script**: Installs the SAP Cloud Connector and SAP Java Virtual Machine (SAPJVM) if they are not already installed on the system.

The scripts automate several tasks for managing the SAP Cloud Connector and SAP JVM:

- **Determining the currently installed versions**: By querying installed RPM packages or archive-mode version markers.
- **Searching for the latest versions**: Checks online for the available versions and selects the most recent versions.
- **Downloading the necessary files**: Includes both the SAP Cloud Connector and JVM packages along with their associated SHA1 hash files, while respecting EULA conditions.
- **Verifying integrity**: Ensures the downloaded files match the checksum files published by SAP.
- **Installation or update**: Utilizes RPM packages on RPM-based systems and archive extraction on other supported Linux distributions.
- **Cleanup**: Removes downloaded and temporary files after completion.

## Requirements

Before running any of the scripts, ensure your system has the necessary tools installed:

```shell
dnf -y install ca-certificates curl unzip coreutils
```

The scripts can install these prerequisites automatically with `dnf`, `yum`, `zypper`, `apt-get`, or `pacman` when the package manager is available. Archive mode also requires `tar` and `gzip`, which the scripts install automatically.

Archive mode installs SAP JVM to `/opt/sap/sapjvm_8` and SAP Cloud Connector to `/opt/sap/cloud-connector` unless `INSTALL_ROOT`, `SAPJVM_HOME`, or `SCC_HOME` are set before running the script:

```shell
INSTALL_ROOT=/srv/sap ./install.sh
```

Start an archive-mode installation with:

```shell
JAVA_HOME=/opt/sap/sapjvm_8 /opt/sap/cloud-connector/go.sh
```

Archive updates detect previous archive installations through helper-managed version marker files in the installation directories.

## Running the Scripts

### Update the SAP Cloud Connector and JVM

To update existing installations of the SAP Cloud Connector and SAP JVM, use the updater script. This script checks for the latest versions online and performs updates if the installed versions are outdated.

Execute the following command to update:

```shell
bash -c "$(curl -fsSL https://github.com/robertfels/cloud-connector-helper/raw/main/update.sh)"
```

### Install the SAP Cloud Connector and JVM

If the SAP Cloud Connector and SAP JVM are not installed on your system, you can use the installer script to perform a fresh installation of both.

Execute the following command to install:

```shell
bash -c "$(curl -fsSL https://github.com/robertfels/cloud-connector-helper/raw/main/install.sh)"
```

## Security Notes

- Downloads are restricted to HTTPS and TLS 1.2 or newer.
- Temporary files are created in a private `mktemp` directory and removed after use.
- The scripts fail early on unsupported operating systems, architectures, and package managers.
- RPM packages are only installed on RPM-based distributions; other supported Linux distributions use SAP's archive artifacts.
- SAP currently publishes SHA1 checksum files for these artifacts. SHA1 is not collision-resistant, but the scripts keep the verification because it is the upstream integrity metadata available for these downloads.

## Notes

- Ensure you have sufficient permissions (e.g., root or sudo) to install software and manage services on your system.
- It is highly recommended to create a backup of your system configuration and any existing SAP Cloud Connector and JVM settings before running these scripts.

These scripts aim to streamline the installation and update processes for the SAP Cloud Connector and Java Virtual Machine, reducing manual effort and ensuring consistency across installations.

"SAP" is a trademark or registered trademark of SAP SE or its affiliates in Germany and other countries.
