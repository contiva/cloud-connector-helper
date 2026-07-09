#!/usr/bin/env bash
set -Eeuo pipefail

TOOLS_URL="https://tools.hana.ondemand.com/#cloud"
DOWNLOAD_BASE_URL="https://tools.hana.ondemand.com/additional"
USER_AGENT="cloud-connector-helper/1.0"
UNATTENDED=false
EMAIL=""
UPDATE_RESULTS=""
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

usage() {
    cat <<'EOF'
Usage: update.sh [--unattended [email]]

Updates installed SAP JVM and SAP Cloud Connector packages on supported
Linux x86_64 glibc systems.
EOF
}

parse_args() {
    case "${1:-}" in
        "")
            ;;
        --unattended)
            UNATTENDED=true
            EMAIL="${2:-}"
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage
            exit 1
            ;;
    esac
}

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
            command_exists rpm || die "RPM-based updates require rpm."
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

    echo "Ensuring required packages are installed..."
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

archive_installed_version() {
    local product_prefix=$1
    local marker

    case "$product_prefix" in
        sapjvm)
            marker="$SAPJVM_HOME/.cloud-connector-helper-version"
            ;;
        sapcc)
            marker="$SCC_HOME/.cloud-connector-helper-version"
            ;;
        *)
            return 0
            ;;
    esac

    [[ -f "$marker" ]] || return 0
    awk 'NR == 1 { print; exit }' "$marker"
}

installed_version() {
    local package_regex=$1

    rpm -qa --qf '%{NAME} %{VERSION}\n' \
        | awk -v package_regex="$package_regex" '$1 ~ package_regex { print $2; exit }'
}

append_update_results() {
    local product_name=$1
    local update_status=$2

    UPDATE_RESULTS="${UPDATE_RESULTS}"$'\n'"${product_name} update: ${update_status}"
}

ask_or_default_yes() {
    local prompt=$1
    local response

    if $UNATTENDED; then
        echo "$prompt: Auto-accepting for unattended mode."
        return 0
    fi

    read -r -p "$prompt (y/N) " response
    [[ "${response,,}" == "y" ]]
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

update_rpm() {
    local rpm_package=$1

    as_root rpm -Uvh "$rpm_package"
}

write_version_marker() {
    local target_dir=$1
    local version=$2

    printf '%s\n' "$version" > "$WORK_DIR/.cloud-connector-helper-version"
    as_root cp "$WORK_DIR/.cloud-connector-helper-version" "$target_dir/.cloud-connector-helper-version"
}

replace_sapjvm_archive() {
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
    echo "SAP JVM archive updated at $SAPJVM_HOME."
}

replace_scc_archive() {
    local artifact=$1
    local version=$2
    local backup_dir="$WORK_DIR/scc-config-backup"

    mkdir -p "$backup_dir"
    if [[ -d "$SCC_HOME/config" ]]; then
        as_root cp -a "$SCC_HOME/config" "$backup_dir/config"
    fi
    if [[ -d "$SCC_HOME/scc_config" ]]; then
        as_root cp -a "$SCC_HOME/scc_config" "$backup_dir/scc_config"
    fi

    as_root rm -rf "$SCC_HOME"
    as_root mkdir -p "$SCC_HOME"
    as_root tar -xzf "$artifact" -C "$SCC_HOME" || die "Failed to extract $artifact"
    [[ -f "$SCC_HOME/go.sh" ]] || die "Expected go.sh in extracted SAP Cloud Connector archive."

    if [[ -d "$backup_dir/config" ]]; then
        as_root rm -rf "$SCC_HOME/config"
        as_root cp -a "$backup_dir/config" "$SCC_HOME/config"
    fi
    if [[ -d "$backup_dir/scc_config" ]]; then
        as_root rm -rf "$SCC_HOME/scc_config"
        as_root cp -a "$backup_dir/scc_config" "$SCC_HOME/scc_config"
    fi

    write_version_marker "$SCC_HOME" "$version"
    echo "SAP Cloud Connector archive updated at $SCC_HOME."
}

download_and_update() {
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
        replace_sapjvm_archive "$artifact" "$version"
    elif [[ "$INSTALL_MODE" == "archive" && "$product_prefix" == "sapcc" ]]; then
        replace_scc_archive "$artifact" "$version"
    else
        if [[ "$file_type" == "zip" ]]; then
            unzip -q "$artifact" || die "Failed to extract $artifact"
            mapfile -t rpm_packages < <(find . -maxdepth 1 -type f -name '*.rpm' -print)
            [[ "${#rpm_packages[@]}" -eq 1 ]] || die "Expected one RPM in $artifact, found ${#rpm_packages[@]}."
            rpm_package=${rpm_packages[0]}
        else
            rpm_package=$artifact
        fi

        echo "Updating $product_name..."
        update_rpm "$rpm_package" || return 1
    fi

    cd "$previous_dir"
    cleanup
    WORK_DIR=""
    echo "$product_name update completed."
}

update_common() {
    local product_name=$1
    local product_prefix=$2
    local package_regex=$3
    local new_version=$4
    local file_type=$5
    local current_version

    if [[ "$INSTALL_MODE" == "archive" ]]; then
        current_version=$(archive_installed_version "$product_prefix")
    else
        current_version=$(installed_version "$package_regex")
    fi
    if [[ -z "$current_version" ]]; then
        echo "$product_name is not installed; skipping update."
        append_update_results "$product_name" "SKIPPED - NOT INSTALLED"
        return 0
    fi

    echo "Installed $product_name version: $current_version"
    echo "Latest available $product_name artifact version: $new_version"

    if [[ "$new_version" == "$current_version" ]]; then
        echo "The latest version of $product_name is already installed."
        append_update_results "$product_name" "ALREADY UP-TO-DATE"
        return 0
    fi

    if ask_or_default_yes "Do you want to update $product_name to $new_version?"; then
        if download_and_update "$product_name" "$product_prefix" "$new_version" "$file_type"; then
            append_update_results "$product_name" "SUCCESS"
        else
            append_update_results "$product_name" "FAILED"
            return 1
        fi
    else
        echo "$product_name update skipped by user."
        append_update_results "$product_name" "SKIPPED BY USER"
    fi
}

send_update_email() {
    if [[ -n "$EMAIL" ]]; then
        command_exists sendmail || die "sendmail is required when an email recipient is provided."
        {
            echo "To: $EMAIL"
            echo "Subject: SAP Cloud Connector Helper Update Summary"
            echo
            printf 'Update Summary:%s\n' "$UPDATE_RESULTS"
        } | sendmail -t
    fi
}

main() {
    local tools_page
    local scc_version
    local jvm_version
    local scc_file_type
    local jvm_file_type

    parse_args "$@"
    require_supported_platform
    install_required_packages

    tools_page=$(fetch_tools_page)
    EULA_COOKIE_NAME=$(extract_eula_cookie_name "$tools_page")
    EULA_COOKIE_VALUE=$(extract_eula_cookie_value "$tools_page")
    [[ -n "$EULA_COOKIE_NAME" && -n "$EULA_COOKIE_VALUE" ]] || die "Failed to extract EULA cookie information."

    ask_or_default_yes "Do you accept the EULA (https://${EULA_COOKIE_VALUE})?" || die "You did not accept the EULA. Update aborted."

    if [[ "$INSTALL_MODE" == "archive" ]]; then
        jvm_file_type=zip
        scc_file_type=tar.gz
    else
        jvm_file_type=rpm
        scc_file_type=zip
    fi

    jvm_version=$(latest_version "$tools_page" "sapjvm" "$jvm_file_type")
    scc_version=$(latest_version "$tools_page" "sapcc" "$scc_file_type")

    update_common "SAP JVM" "sapjvm" '^sapjvm$' "$jvm_version" "$jvm_file_type"
    update_common "SAP Cloud Connector" "sapcc" '^com[.]sap[.]scc[.-]ui$' "$scc_version" "$scc_file_type"

    send_update_email
    echo "All updates completed."
}

main "$@"
