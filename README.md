# Easy Updater and Installer for SAP Cloud Connector and SAP JVM

This suite of Bash scripts automates the update or installation process of the SAP Cloud Connector and the SAP Java Virtual Machine (SAPJVM) on Linux systems with `x86_64` architecture. It facilitates the management of the lifecycle for both the SAP Cloud Connector and SAP JVM by automating version checks, downloading the latest versions available online, and ensuring the integrity of downloaded packages through SHA1 hash verification.

## Supported Distributions
- Red Hat Enterprise Linux (RHEL)
- CentOS
- Fedora
- openSUSE

## Overview

The toolkit includes:

1. **Updater Script**: Checks and updates the currently installed versions of the SAP Cloud Connector and SAP Java Virtual Machine (SAPJVM) if newer versions are available.
2. **Installer Script**: Installs the SAP Cloud Connector and SAP Java Virtual Machine (SAPJVM) if they are not already installed on the system.

The scripts automate several tasks for managing the SAP Cloud Connector and SAP JVM:

- **Determining the currently installed versions**: By querying installed RPM packages.
- **Searching for the latest versions**: Checks online for the available versions and selects the most recent versions.
- **Downloading the necessary files**: Includes both the SAP Cloud Connector and JVM packages along with their associated SHA1 hash files, while respecting EULA conditions.
- **Verifying integrity**: Ensures the downloaded files match their SHA1 hashes to guarantee file integrity.
- **Installation or update**: Utilizes RPM for installing or updating the SAP Cloud Connector and SAP JVM.
- **Service restart**: Restarts the SAP Cloud Connector service to activate the latest versions.
- **Cleanup**: Removes downloaded and temporary files after completion.

## Requirements

Before running any of the scripts, ensure your system has the necessary tools installed:

```shell
yum -y install wget curl unzip
```

## Running the Scripts

### Update the SAP Cloud Connector and JVM

To update existing installations of the SAP Cloud Connector and SAP JVM, use the updater script. This script checks for the latest versions online and performs updates if the installed versions are outdated.

Execute the following command to update:

```shell
bash -c "$(wget -qLO - https://github.com/robertfels/cloud-connector-helper/raw/main/update.sh)"
```

### Install the SAP Cloud Connector and JVM

If the SAP Cloud Connector and SAP JVM are not installed on your system, you can use the installer script to perform a fresh installation of both.

Execute the following command to install:

```shell
bash -c "$(wget -qLO - https://github.com/robertfels/cloud-connector-helper/raw/main/install.sh)"
```

## Notes

- Ensure you have sufficient permissions (e.g., root or sudo) to install software and manage services on your system.
- It is highly recommended to create a backup of your system configuration and any existing SAP Cloud Connector and JVM settings before running these scripts.

These scripts aim to streamline the installation and update processes for the SAP Cloud Connector and Java Virtual Machine, reducing manual effort and ensuring consistency across installations.
