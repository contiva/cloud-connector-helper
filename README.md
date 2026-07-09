# Easy Installer and Updater for SAP Cloud Connector and SAP JVM

This suite of Bash scripts automates the update or installation process of the SAP Cloud Connector and the SAP Java Virtual Machine (SAPJVM) on RPM-based Linux systems with `x86_64` architecture. It facilitates the management of the lifecycle for both the SAP Cloud Connector and SAP JVM by automating version checks, downloading the latest versions available online, and ensuring the integrity of downloaded packages through the checksum files published by SAP.

## Supported Distributions
- Red Hat Enterprise Linux (RHEL)
- CentOS
- Rocky Linux / AlmaLinux
- Fedora
- SUSE Linux Enterprise Server / openSUSE

The scripts are not portable UNIX installers. They do not support Debian, Ubuntu, macOS, BSD, AIX, Solaris, or non-`x86_64` architectures because SAP's Linux installer artifacts handled here are RPM packages.

## Overview

The toolkit includes:

1. **Updater Script**: Checks and updates the currently installed versions of the SAP Cloud Connector and SAP Java Virtual Machine (SAPJVM) if newer versions are available.
2. **Installer Script**: Installs the SAP Cloud Connector and SAP Java Virtual Machine (SAPJVM) if they are not already installed on the system.

The scripts automate several tasks for managing the SAP Cloud Connector and SAP JVM:

- **Determining the currently installed versions**: By querying installed RPM packages.
- **Searching for the latest versions**: Checks online for the available versions and selects the most recent versions.
- **Downloading the necessary files**: Includes both the SAP Cloud Connector and JVM packages along with their associated SHA1 hash files, while respecting EULA conditions.
- **Verifying integrity**: Ensures the downloaded files match the checksum files published by SAP.
- **Installation or update**: Utilizes RPM for installing or updating the SAP Cloud Connector and SAP JVM.
- **Cleanup**: Removes downloaded and temporary files after completion.

## Requirements

Before running any of the scripts, ensure your system has the necessary tools installed:

```shell
dnf -y install curl unzip coreutils
```

The scripts can install these prerequisites automatically with `dnf`, `yum`, or `zypper` when the package manager is available.

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
- The scripts fail early on unsupported operating systems, architectures, and systems without RPM support.
- SAP currently publishes SHA1 checksum files for these artifacts. SHA1 is not collision-resistant, but the scripts keep the verification because it is the upstream integrity metadata available for these downloads.

## Notes

- Ensure you have sufficient permissions (e.g., root or sudo) to install software and manage services on your system.
- It is highly recommended to create a backup of your system configuration and any existing SAP Cloud Connector and JVM settings before running these scripts.

These scripts aim to streamline the installation and update processes for the SAP Cloud Connector and Java Virtual Machine, reducing manual effort and ensuring consistency across installations.

"SAP" is a trademark or registered trademark of SAP SE or its affiliates in Germany and other countries.
