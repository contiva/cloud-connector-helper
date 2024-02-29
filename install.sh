#!/bin/bash

echo "Updating system and installing required packages..."
sudo yum update -y
sudo yum -y install curl wget unzip


# URL and basic information
URL="https://tools.hana.ondemand.com/#cloud"
DOWNLOAD_BASE_URL="https://tools.hana.ondemand.com/additional"

# Function to update SAP Cloud Connector
update_scc() {
    local INSTALLED_PACKAGE=$(rpm -qa | grep "com.sap.scc-ui")
    local CURRENT_VERSION=$(echo "$INSTALLED_PACKAGE" | grep -oP "[0-9]+\.[0-9]+\.[0-9]+")
    local NEW_VERSION=$(curl -s "$URL" | grep -oP "sapcc-\K[0-9.]+(?=-linux-x64.zip)" | sort -V | tail -n1)
    
    update_common "SAP Cloud Connector" "sapcc" "$CURRENT_VERSION" "$NEW_VERSION"
}

# Function to update SAP JVM
update_jvm() {
    local INSTALLED_PACKAGE=$(rpm -qa | grep "sapjvm")
    local CURRENT_VERSION=$(echo "$INSTALLED_PACKAGE" | sed 's/sapjvm-\([^-]*\)-\([^-]*\).*/\1.\2/')
    local NEW_VERSION=$(curl -s "$URL" | grep -oP "sapjvm-\K[0-9.]+(?=-linux-x64.zip)" | sort -V | tail -n1)
    
    update_common "SAP JVM" "sapjvm" "$CURRENT_VERSION" "$NEW_VERSION" "rpm"
}

# Common update function
update_common() {
    local PRODUCT_NAME=$1
    local PRODUCT_PREFIX=$2
    local CURRENT_VERSION=$3
    local NEW_VERSION=$4
    local FILE_TYPE=${5:-zip} # Default to zip if not specified
    
    echo "Checking for $PRODUCT_NAME update..."
    
    if [ "$NEW_VERSION" = "$CURRENT_VERSION" ]; then
        echo "The latest version of $PRODUCT_NAME is already installed: $CURRENT_VERSION"
        return 0
    fi
    
    echo "A new version of $PRODUCT_NAME is available: $NEW_VERSION"
    read -p "Do you want to proceed with the update? (y/N) " PROCEED_UPDATE
    
    if [ "${PROCEED_UPDATE,,}" != "y" ]; then
        echo "Update aborted by the user."
        return 1
    fi
    
    # Download and update process
    download_and_update "$PRODUCT_NAME" "$PRODUCT_PREFIX" "$NEW_VERSION" "$FILE_TYPE"
}

# Download and update process
download_and_update() {
    local PRODUCT_NAME=$1
    local PRODUCT_PREFIX=$2
    local NEW_VERSION=$3
    local FILE_TYPE=$4
    
    local DOWNLOAD_URL="$DOWNLOAD_BASE_URL/$PRODUCT_PREFIX-$NEW_VERSION-linux-x64.$FILE_TYPE"
    local SHA1_URL="$DOWNLOAD_URL.sha1"
    
    # Use a common cleanup function defined outside this scope
    
    mkdir -p update_temp && cd update_temp || { echo "Failed to create/update directory."; exit 1; }
    
    echo "Downloading the new $PRODUCT_NAME version..."
    if ! curl -# -b "$EULA_COOKIE_NAME=$EULA_COOKIE_VALUE" -O "$DOWNLOAD_URL"; then
        echo "Failed to download the $PRODUCT_NAME version."
        cleanup
        return 1
    fi
    
    echo "Downloading SHA1 hash..."
    if ! curl -# -b "$EULA_COOKIE_NAME=$EULA_COOKIE_VALUE" -O "$SHA1_URL"; then
        echo "Failed to download the SHA1 hash."
        cleanup
        return 1
    fi
    
    local FILENAME="$PRODUCT_PREFIX-$NEW_VERSION-linux-x64.$FILE_TYPE"
    local SHA1_FILENAME="$FILENAME.sha1"
    
    verify_hash "$FILENAME" "$SHA1_FILENAME"
    
    if [ "$FILE_TYPE" = "zip" ]; then
        unzip "$FILENAME"
    fi
    
    local RPM_PACKAGE=$(ls *.rpm)
    
    echo "Updating $PRODUCT_NAME..."
    if ! sudo rpm -U "$RPM_PACKAGE"; then
        echo "Update failed."
        cleanup
        return 1
    fi
    
    cleanup
    echo "$PRODUCT_NAME update completed."
}

# Cleanup function
cleanup() {
    echo "Cleaning up temporary files..."
    cd ..
    rm -rf update_temp
}

# Verify the SHA1 hash
verify_hash() {
    local FILENAME=$1
    local SHA1_FILENAME=$2
    
    echo "Verifying the SHA1 hash..."
    local SHA1SUM_EXPECTED=$(cat "$SHA1_FILENAME")
    local SHA1SUM_ACTUAL=$(sha1sum "$FILENAME" | awk '{print $1}')
    
    if [ "$SHA1SUM_EXPECTED" != "$SHA1SUM_ACTUAL" ]; then
        echo "Hash verification failed. Update aborted."
        cleanup
        exit 1
    fi
    
    echo "Hash verification successful."
}

# Extract EULA information once for both updates
EULA_COOKIE_NAME=$(curl -s "$URL" | grep -oP "eulaConst.devLicense.cookieName = '\K[^']+" )
EULA_COOKIE_VALUE=$(curl -s "$URL" | grep -oP "eulaConst.devLicense.cookieValue = '\K[^']+" )

if [ -z "$EULA_COOKIE_VALUE" ]; then
    echo "Failed to extract EULA cookie value."
    exit 1
fi

EULA_URL="https://$EULA_COOKIE_VALUE"

echo "Please read the EULA at: $EULA_URL"
read -p "Do you accept the EULA? (y/N) " ACCEPT_EULA

if [ "${ACCEPT_EULA,,}" != "y" ]; then
    echo "You did not accept the EULA. Update aborted."
    exit 1
fi

# Ask user for each product update
read -p "Do you want to update SAP JVM? (y/N) " UPDATE_JVM
if [ "${UPDATE_JVM,,}" = "y" ]; then
    update_jvm
fi

read -p "Do you want to update SAP Cloud Connector? (y/N) " UPDATE_SCC
if [ "${UPDATE_SCC,,}" = "y" ]; then
    update_scc
fi

echo "All updates completed."
