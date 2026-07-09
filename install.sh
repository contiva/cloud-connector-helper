#!/usr/bin/env bash
set -Eeuo pipefail

TOOLS_URL="https://tools.hana.ondemand.com/#cloud"
DOWNLOAD_BASE_URL="https://tools.hana.ondemand.com/additional"
USER_AGENT="cloud-connector-helper/1.0"
WORK_DIR=""
PACKAGE_MANAGER=""
INSTALL_MODE=""
INSTALL_ROOT="${INSTALL_ROOT:-/opt/sap}"
SAPJVM_HOME="${SAPJVM_HOME:-${INSTALL_ROOT}/sapjvm_8}"
SCC_HOME="${SCC_HOME:-${INSTALL_ROOT}/cloud-connector}"

die() {
    echo "ERROR: $*" >&2
    exit 1
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

as_root() {
    if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
        "$@"
    elif command_exists sudo; then
        sudo "$@"
    else
        die "Root privileges are required. Re-run as root or install sudo."
    fi
}

cleanup() {
    if [[ -n "${WORK_DIR:-}" && -d "$WORK_DIR" ]]; then
        rm -rf "$WORK_DIR"
    fi
}
trap cleanup EXIT

detect_package_manager() {
    if command_exists dnf; then
        PACKAGE_MANAGER=dnf
    elif command_exists yum; then
        PACKAGE_MANAGER=yum
    elif command_exists zypper; then
        PACKAGE_MANAGER=zypper
    elif command_exists apt-get; then
        PACKAGE_MANAGER=apt-get
    elif command_exists pacman; then
        PACKAGE_MANAGER=pacman
    else
        die "No supported package manager found. Install curl, unzip, tar, gzip, and coreutils manually."
    fi
}

require_supported_platform() {
    [[ "$(uname -s)" == "Linux" ]] || die "This helper supports Linux only."
    [[ "$(uname -m)" == "x86_64" ]] || die "This helper supports x86_64 only."
    getconf GNU_LIBC_VERSION >/dev/null 2>&1 || die "SAP Linux x64 artifacts require glibc; musl-based distributions such as Alpine Linux are not supported."

    detect_package_manager
    case "$PACKAGE_MANAGER" in
        dnf|yum|zypper)
            command_exists rpm || die "RPM-based installation requires rpm."
            INSTALL_MODE=rpm
            ;;
        apt-get|pacman)
            INSTALL_MODE=archive
            ;;
    esac
}

install_required_packages() {
    local packages=(ca-certificates curl unzip coreutils)

    if [[ "$INSTALL_MODE" == "archive" ]]; then
        packages+=(tar gzip)
    fi

    echo "Installing required packages..."
    case "$PACKAGE_MANAGER" in
        dnf)
            as_root dnf -y install "${packages[@]}"
            ;;
        yum)
            as_root yum -y install "${packages[@]}"
            ;;
        zypper)
            as_root zypper --non-interactive install "${packages[@]}"
            ;;
        apt-get)
            as_root apt-get update
            as_root apt-get install -y --no-install-recommends "${packages[@]}"
            ;;
        pacman)
            as_root pacman -Sy --noconfirm --needed "${packages[@]}"
            ;;
    esac
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
    local safe_extension

    safe_extension=$(sed -E 's/[][\/.^$*+?{}()|]/\\&/g' <<< "$extension")

    { grep -Eo "${prefix}-[0-9.]+-linux-x64\.${safe_extension}" <<< "$page" || true; } \
        | sed -E "s/${prefix}-([0-9.]+)-linux-x64\.${safe_extension}/\1/" \
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

    as_root rpm -Uvh "$rpm_package"
}

write_version_marker() {
    local target_dir=$1
    local version=$2

    printf '%s\n' "$version" > "$WORK_DIR/.cloud-connector-helper-version"
    as_root cp "$WORK_DIR/.cloud-connector-helper-version" "$target_dir/.cloud-connector-helper-version"
}

install_sapjvm_archive() {
    local artifact=$1
    local version=$2
    local extract_dir="$WORK_DIR/sapjvm"

    mkdir -p "$extract_dir"
    unzip -q "$artifact" -d "$extract_dir" || die "Failed to extract $artifact"
    [[ -d "$extract_dir/sapjvm_8" ]] || die "Expected sapjvm_8 directory in $artifact."

    as_root mkdir -p "$(dirname "$SAPJVM_HOME")"
    as_root rm -rf "$SAPJVM_HOME"
    as_root mv "$extract_dir/sapjvm_8" "$SAPJVM_HOME"
    write_version_marker "$SAPJVM_HOME" "$version"
    echo "SAP JVM archive installed at $SAPJVM_HOME."
}

install_scc_archive() {
    local artifact=$1
    local version=$2

    as_root rm -rf "$SCC_HOME"
    as_root mkdir -p "$SCC_HOME"
    as_root tar -xzf "$artifact" -C "$SCC_HOME" || die "Failed to extract $artifact"
    [[ -f "$SCC_HOME/go.sh" ]] || die "Expected go.sh in extracted SAP Cloud Connector archive."
    write_version_marker "$SCC_HOME" "$version"
    echo "SAP Cloud Connector archive installed at $SCC_HOME."
    echo "Start it with: JAVA_HOME=$SAPJVM_HOME $SCC_HOME/go.sh"
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

    if [[ "$INSTALL_MODE" == "archive" && "$product_prefix" == "sapjvm" ]]; then
        install_sapjvm_archive "$artifact" "$version"
    elif [[ "$INSTALL_MODE" == "archive" && "$product_prefix" == "sapcc" ]]; then
        install_scc_archive "$artifact" "$version"
    else
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
    fi

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
    local scc_file_type
    local jvm_file_type

    require_supported_platform
    install_required_packages

    tools_page=$(fetch_tools_page)
    EULA_COOKIE_NAME=$(extract_eula_cookie_name "$tools_page")
    EULA_COOKIE_VALUE=$(extract_eula_cookie_value "$tools_page")
    [[ -n "$EULA_COOKIE_NAME" && -n "$EULA_COOKIE_VALUE" ]] || die "Failed to extract EULA cookie information."

    echo "Please read the EULA at: https://${EULA_COOKIE_VALUE}"
    ask_yes_no "Do you accept the EULA?" || die "You did not accept the EULA. Install aborted."

    if [[ "$INSTALL_MODE" == "archive" ]]; then
        jvm_file_type=zip
        scc_file_type=tar.gz
    else
        jvm_file_type=rpm
        scc_file_type=zip
    fi

    jvm_version=$(latest_version "$tools_page" "sapjvm" "$jvm_file_type")
    scc_version=$(latest_version "$tools_page" "sapcc" "$scc_file_type")

    if ask_yes_no "Do you want to install SAP JVM ${jvm_version}?"; then
        download_and_install "SAP JVM" "sapjvm" "$jvm_version" "$jvm_file_type"
    fi

    if ask_yes_no "Do you want to install SAP Cloud Connector ${scc_version}?"; then
        download_and_install "SAP Cloud Connector" "sapcc" "$scc_version" "$scc_file_type"
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
