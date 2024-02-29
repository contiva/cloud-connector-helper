# Easy Updater for SAP Cloud Connector

This Bash script automates the update process of the SAP Cloud Connector on Linux systems. It checks the currently installed version of the SAP Cloud Connector, identifies the latest version available online, and performs an update if necessary. Additionally, it manages the download of the necessary files, including the verification of SHA1 hashes to ensure the integrity of the downloaded packages.

## Supported Distributions

The script is compatible with Linux distributions on `x86_64` that use the RPM Package Manager and `systemd` as their init system. These distributions include:

- Red Hat Enterprise Linux (RHEL)
- CentOS
- Fedora
- openSUSE

## How It Works

The script performs the following steps:

1. **Determining the currently installed version**: By querying installed RPM packages.
2. **Searching for the latest version**: Online checking of available versions and selecting the most recent version.
3. **Downloading the update files**: Downloading the new version of the SAP Cloud Connector and the associated SHA1 hash file, respecting EULA conditions.
4. **Verifying integrity**: Comparing the downloaded files with the SHA1 hash to ensure file integrity.
5. **Installing the update**: Updating the SAP Cloud Connector using RPM.
6. **Restarting the SAP Cloud Connector service**: To ensure the latest version is active.
7. **Cleanup**: Removing downloaded and temporary files after the update.

## Requirements

Before running the script, ensure your system has the necessary tools installed:

```shell=
yum -y install wget curl unzip
```

## Run the update:

To update the SAP Cloud Connector, execute the following command:

```shell=
bash -c "$(wget -qLO - https://github.com/robertfels/updateCloudConnector/raw/main/update.sh)"
```

## Notes

- Ensure you have sufficient permissions to install software on your system and restart services.
- It is recommended to create a backup of your system configuration and SAP Cloud Connector before executing this script.

This script simplifies the update process and reduces manual effort, helping administrators save time and ensure installation consistency.
