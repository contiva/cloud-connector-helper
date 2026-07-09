#!/usr/bin/env bash
set -Eeuo pipefail

TOOLS_URL="https://tools.hana.ondemand.com/#cloud"
DOWNLOAD_BASE_URL="https://tools.hana.ondemand.com/additional"
USER_AGENT="cloud-connector-helper/1.0"
WORK_DIR=""

die() {
    echo "ERROR: $*" >&2
    exit 1
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

cleanup() {
    if [[ -n "${WORK_DIR:-}" && -d "$WORK_DIR" ]]; then
        rm -rf "$WORK_DIR"
    fi
}
trap cleanup EXIT

require_supported_platform() {
    [[ "$(uname -s)" == "Linux" ]] || die "This helper supports Linux only."
    [[ "$(uname -m)" == "x86_64" ]] || die "This helper supports x86_64 only."
    command_exists rpm || die "This helper installs SAP RPM packages and requires rpm."
}

install_required_packages() {
    local packages=(curl unzip coreutils)

    echo "Installing required packages..."
    if command_exists dnf; then
        sudo dnf -y install "${packages[@]}"
    elif command_exists yum; then
        sudo yum -y install "${packages[@]}"
    elif command_exists zypper; then
        sudo zypper --non-interactive install "${packages[@]}"
    else
        die "No supported package manager found. Install curl, unzip, and coreutils manually."
    fi
}

fetch_tools_page() {
    curl -fsSL --proto '=https' --tlsv1.2 --user-agent "$USER_AGENT" "$TOOLS_URL"
}

extract_eula_cookie_name() {
    sed -nE "s/.*eulaConst\.devLicense\.cookieName = '([^']+)'.*/\1/p" <<< "$1" | head -n1
}

extract_eula_cookie_value() {
    sed -nE "s/.*eulaConst\.devLicense\.cookieValue = '([^']+)'.*/\1/p" <<< "$1" | head -n1
}

latest_version() {
    local page=$1
    local prefix=$2
    local extension=$3

    { grep -Eo "${prefix}-[0-9.]+-linux-x64\.${extension}" <<< "$page" || true; } \
        | sed -E "s/${prefix}-([0-9.]+)-linux-x64\.${extension}/\1/" \
        | sort -V \
        | tail -n1
}

download_file() {
    local url=$1
    local output=$2

    curl -fL --proto '=https' --tlsv1.2 --user-agent "$USER_AGENT" \
        -b "$EULA_COOKIE_NAME=$EULA_COOKIE_VALUE" \
        -o "$output" \
        "$url"
}

verify_sha1() {
    local filename=$1
    local sha1_filename=$2
    local expected
    local actual

    expected=$(awk '{print $1}' "$sha1_filename")
    actual=$(sha1sum "$filename" | awk '{print $1}')

    [[ -n "$expected" ]] || die "SHA1 file is empty: $sha1_filename"
    [[ "$expected" == "$actual" ]] || die "Hash verification failed for $filename"
}

install_rpm() {
    local rpm_package=$1

    sudo rpm -Uvh "$rpm_package"
}

download_and_install() {
    local product_name=$1
    local product_prefix=$2
    local version=$3
    local file_type=$4
    local artifact="${product_prefix}-${version}-linux-x64.${file_type}"
    local download_url="${DOWNLOAD_BASE_URL}/${artifact}"
    local sha1_url="${download_url}.sha1"
    local previous_dir=$PWD
    local rpm_package
    local -a rpm_packages

    [[ -n "$version" ]] || die "Could not determine latest $product_name version."

    WORK_DIR=$(mktemp -d)
    cd "$WORK_DIR"

    echo "Downloading $product_name $version..."
    download_file "$download_url" "$artifact" || die "Failed to download $download_url"
    download_file "$sha1_url" "${artifact}.sha1" || die "Failed to download $sha1_url"
    verify_sha1 "$artifact" "${artifact}.sha1"

    if [[ "$file_type" == "zip" ]]; then
        unzip -q "$artifact" || die "Failed to extract $artifact"
        mapfile -t rpm_packages < <(find . -maxdepth 1 -type f -name '*.rpm' -print)
        [[ "${#rpm_packages[@]}" -eq 1 ]] || die "Expected one RPM in $artifact, found ${#rpm_packages[@]}."
        rpm_package=${rpm_packages[0]}
    else
        rpm_package=$artifact
    fi

    echo "Installing $product_name..."
    install_rpm "$rpm_package" || die "Failed to install $product_name"
    cd "$previous_dir"
    cleanup
    WORK_DIR=""
    echo "$product_name installation completed."
}

ask_yes_no() {
    local prompt=$1
    local response

    read -r -p "$prompt (y/N) " response
    [[ "${response,,}" == "y" ]]
}

main() {
    local tools_page
    local scc_version
    local jvm_version

    require_supported_platform
    install_required_packages

    tools_page=$(fetch_tools_page)
    EULA_COOKIE_NAME=$(extract_eula_cookie_name "$tools_page")
    EULA_COOKIE_VALUE=$(extract_eula_cookie_value "$tools_page")
    [[ -n "$EULA_COOKIE_NAME" && -n "$EULA_COOKIE_VALUE" ]] || die "Failed to extract EULA cookie information."

    echo "Please read the EULA at: https://${EULA_COOKIE_VALUE}"
    ask_yes_no "Do you accept the EULA?" || die "You did not accept the EULA. Install aborted."

    jvm_version=$(latest_version "$tools_page" "sapjvm" "rpm")
    scc_version=$(latest_version "$tools_page" "sapcc" "zip")

    if ask_yes_no "Do you want to install SAP JVM ${jvm_version}?"; then
        download_and_install "SAP JVM" "sapjvm" "$jvm_version" "rpm"
    fi

    if ask_yes_no "Do you want to install SAP Cloud Connector ${scc_version}?"; then
        download_and_install "SAP Cloud Connector" "sapcc" "$scc_version" "zip"
    fi

    echo "All installations are completed."
    if command_exists hostname; then
        ip_address=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
        if [[ -n "${ip_address:-}" ]]; then
            echo "Login via https://${ip_address}:8443"
            echo "Username: Administrator"
            echo "Password: manage"
        fi
    fi
}

main "$@"
