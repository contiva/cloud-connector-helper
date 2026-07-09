#!/usr/bin/env bash
set -Eeuo pipefail

TOOLS_URL="https://tools.hana.ondemand.com/#cloud"
DOWNLOAD_BASE_URL="https://tools.hana.ondemand.com/additional"
USER_AGENT="cloud-connector-helper/1.0"
UNATTENDED=false
EMAIL=""
UPDATE_RESULTS=""
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

usage() {
    cat <<'EOF'
Usage: update.sh [--unattended [email]]

Updates installed SAP JVM and SAP Cloud Connector RPM packages on supported
Linux x86_64 systems.
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

require_supported_platform() {
    [[ "$(uname -s)" == "Linux" ]] || die "This helper supports Linux only."
    [[ "$(uname -m)" == "x86_64" ]] || die "This helper supports x86_64 only."
    command_exists rpm || die "This helper updates SAP RPM packages and requires rpm."
}

install_required_packages() {
    local packages=(curl unzip coreutils)

    echo "Ensuring required packages are installed..."
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

    sudo rpm -Uvh "$rpm_package"
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

    current_version=$(installed_version "$package_regex")
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

    parse_args "$@"
    require_supported_platform
    install_required_packages

    tools_page=$(fetch_tools_page)
    EULA_COOKIE_NAME=$(extract_eula_cookie_name "$tools_page")
    EULA_COOKIE_VALUE=$(extract_eula_cookie_value "$tools_page")
    [[ -n "$EULA_COOKIE_NAME" && -n "$EULA_COOKIE_VALUE" ]] || die "Failed to extract EULA cookie information."

    ask_or_default_yes "Do you accept the EULA (https://${EULA_COOKIE_VALUE})?" || die "You did not accept the EULA. Update aborted."

    jvm_version=$(latest_version "$tools_page" "sapjvm" "rpm")
    scc_version=$(latest_version "$tools_page" "sapcc" "zip")

    update_common "SAP JVM" "sapjvm" '^sapjvm$' "$jvm_version" "rpm"
    update_common "SAP Cloud Connector" "sapcc" '^com\.sap\.scc[.-]ui$' "$scc_version" "zip"

    send_update_email
    echo "All updates completed."
}

main "$@"
