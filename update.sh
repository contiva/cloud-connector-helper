#!/bin/bash

# URL und Basisinformationen
URL="https://tools.hana.ondemand.com/#cloud"
DOWNLOAD_BASE_URL="https://tools.hana.ondemand.com/additional"

# Bestimme die aktuell installierte Version
INSTALLED_PACKAGE=$(rpm -qa | grep "com.sap.scc-ui")
CURRENT_VERSION=$(echo "$INSTALLED_PACKAGE" | grep -oP "[0-9]+\.[0-9]+\.[0-9]+")

echo "Aktuell installierte Version: $CURRENT_VERSION"

# Symbolische Bestimmung der neuen Version (Dies sollte dynamisch erfolgen)
NEW_VERSION=$(curl -s "$URL" | grep -oP "sapcc-\K[0-9.]+(?=-linux-x64.zip)" | sort -V | tail -n1)

# Prüfen, ob eine neue Version verfügbar ist
if [ "$NEW_VERSION" = "$CURRENT_VERSION" ]; then
    echo "Die neueste Version ist bereits installiert."
    exit 0
fi

echo "Neue Version verfügbar: $NEW_VERSION"

# EULA Information extrahieren
EULA_COOKIE_NAME=$(curl -s "$URL" | grep -oP "eulaConst.devLicense.cookieName = '\K[^']+" )
EULA_COOKIE_VALUE=$(curl -s "$URL" | grep -oP "eulaConst.devLicense.cookieValue = '\K[^']+" )

if [ -z "$EULA_COOKIE_VALUE" ]; then
    echo "Konnte EULA Cookie-Wert nicht extrahieren."
    exit 1
fi

echo "EULA Cookie-Wert: $EULA_COOKIE_VALUE"

# Download-URLs
DOWNLOAD_URL="$DOWNLOAD_BASE_URL/sapcc-$NEW_VERSION-linux-x64.zip"
SHA1_URL="$DOWNLOAD_URL.sha1"

# 1. Vorbereitung für das Update
mkdir -p sapcc_update
cd sapcc_update/

# 2. Herunterladen der neuen SAP Cloud Connector Version und des SHA1 Hash
echo "Download der neuen SAP Cloud Connector Version..."
curl -# -b "$EULA_COOKIE_NAME=$EULA_COOKIE_VALUE" -O "$DOWNLOAD_URL"
echo "Download des SHA1 Hash..."
curl -# -b "$EULA_COOKIE_NAME=$EULA_COOKIE_VALUE" -O "$SHA1_URL"

FILENAME="sapcc-$NEW_VERSION-linux-x64.zip"
SHA1_FILENAME="$FILENAME.sha1"

# 3. Überprüfen des SHA1 Hash
echo "Überprüfe den SHA1 Hash..."
SHA1SUM_EXPECTED=$(cat "$SHA1_FILENAME")
SHA1SUM_ACTUAL=$(sha1sum "$FILENAME" | awk '{print $1}')

if [ "$SHA1SUM_EXPECTED" != "$SHA1SUM_ACTUAL" ]; then
    echo "Hash-Überprüfung fehlgeschlagen. Abbruch des Updates."
    exit 1
else
    echo "Hash-Überprüfung erfolgreich."
fi

# 4. Entpacken des heruntergeladenen Update-Pakets
unzip "$FILENAME"

RPM_PACKAGE=$(ls *.rpm)

# 5. Update des SAP Cloud Connectors
echo "Update des SAP Cloud Connectors..."
sudo rpm -U "$RPM_PACKAGE"

# 6. Neustart des SAP Cloud Connector Daemons
echo "Neustart des SAP Cloud Connector Daemons..."
sudo systemctl restart scc_daemon

echo "Update abgeschlossen."

# Aufräumen: Löschen der heruntergeladenen und entpackten Daten
cd ..
rm -rf sapcc_update

echo "Temporäre Dateien gelöscht."
