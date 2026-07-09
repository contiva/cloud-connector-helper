#!/usr/bin/env bash
set -Eeuo pipefail

TOOLS_URL="https://tools.hana.ondemand.com/#cloud"
DOWNLOAD_BASE_URL="https://tools.hana.ondemand.com/additional"
USER_AGENT="cloud-connector-helper/1.2"
UNATTENDED=false
EMAIL=""
JVM_VERSION_OVERRIDE=""
SCC_VERSION_OVERRIDE=""
SCC_SERVICE_STOPPED=false
UPDATE_RESULTS=""
WORK_DIR=""
PACKAGE_MANAGER=""
INSTALL_MODE=""
INSTALL_ROOT="${INSTALL_ROOT:-/opt/sap}"
SAPJVM_HOME="${SAPJVM_HOME:-${INSTALL_ROOT}/sapjvm_8}"
SCC_HOME="${SCC_HOME:-${INSTALL_ROOT}/cloud-connector}"
SCC_RPM_HOME="${SCC_RPM_HOME:-/opt/sap/scc}"

die() {
    echo "ERROR: $*" >&2
    exit 1
}

log_error() {
    echo "ERROR: $*" >&2
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

on_exit() {
    local exit_code=$?

    cleanup
    if [[ "$exit_code" -ne 0 && -z "$UPDATE_RESULTS" ]]; then
        UPDATE_RESULTS=$'\n'"Update aborted before any product update ran (exit code ${exit_code})."
    fi
    send_update_email || true
}
trap on_exit EXIT

usage() {
    cat <<'EOF'
Usage: update.sh [--unattended [email]] [--jvm-version <version>] [--scc-version <version>]

Updates installed SAP JVM and SAP Cloud Connector packages on supported
Linux x86_64 glibc systems.

  --unattended [email]    Run without prompts; optionally send a summary email.
  --jvm-version <x.y.z>   Update to this SAP JVM version instead of the latest.
  --scc-version <x.y.z>   Update to this SAP Cloud Connector version instead of the latest.
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --unattended)
                UNATTENDED=true
                if [[ $# -gt 1 && "${2#-}" == "$2" ]]; then
                    EMAIL=$2
                    shift
                fi
                ;;
            --jvm-version)
                JVM_VERSION_OVERRIDE="${2:-}"
                [[ -n "$JVM_VERSION_OVERRIDE" ]] || die "--jvm-version requires a value."
                shift
                ;;
            --scc-version)
                SCC_VERSION_OVERRIDE="${2:-}"
                [[ -n "$SCC_VERSION_OVERRIDE" ]] || die "--scc-version requires a value."
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                usage >&2
                exit 1
                ;;
        esac
        shift
    done
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

resolve_version() {
    local page=$1
    local prefix=$2
    local extension=$3
    local override=$4

    if [[ -n "$override" ]]; then
        grep -qF "${prefix}-${override}-linux-x64.${extension}" <<< "$page" \
            || die "Version ${override} of ${prefix} is not available at ${TOOLS_URL}."
        echo "$override"
        return 0
    fi
    latest_version "$page" "$prefix" "$extension"
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

    if [[ -z "$expected" ]]; then
        log_error "SHA1 file is empty: $sha1_filename"
        return 1
    fi
    if [[ "$expected" != "$actual" ]]; then
        log_error "Hash verification failed for $filename"
        return 1
    fi
}

ensure_not_running() {
    local product_name=$1
    local home_dir=$2

    command_exists pgrep || return 0
    if pgrep -f -- "$home_dir" >/dev/null 2>&1; then
        log_error "$product_name appears to be in use: running processes reference $home_dir. Stop the SAP Cloud Connector before updating."
        return 1
    fi
}

preserve_scc_config_backup() {
    local backup_dir=$1
    local rescue_dir="${SCC_HOME}.config-backup"

    as_root rm -rf "$rescue_dir"
    as_root cp -a "$backup_dir" "$rescue_dir"
    echo "SAP Cloud Connector configuration backup preserved at $rescue_dir."
}

backup_rpm_scc_config() {
    local backup_dir="${SCC_RPM_HOME}.config-backup"
    local dir
    local copied=false

    for dir in config scc_config; do
        if [[ -d "$SCC_RPM_HOME/$dir" ]]; then
            if ! $copied; then
                as_root rm -rf "$backup_dir"
                as_root mkdir -p "$backup_dir"
                copied=true
            fi
            as_root cp -a "$SCC_RPM_HOME/$dir" "$backup_dir/$dir"
        fi
    done
    if $copied; then
        echo "SAP Cloud Connector configuration backed up to $backup_dir (previous backup replaced)."
    fi
}

systemd_available() {
    [[ -d /run/systemd/system ]] && command_exists systemctl
}

scc_service_exists() {
    systemd_available && [[ -f /etc/systemd/system/scc_daemon.service ]]
}

stop_scc_service_if_running() {
    scc_service_exists || return 0
    if systemctl is-active --quiet scc_daemon.service; then
        echo "Stopping scc_daemon service..."
        as_root systemctl stop scc_daemon.service
        SCC_SERVICE_STOPPED=true
    fi
}

start_scc_service_if_stopped() {
    $SCC_SERVICE_STOPPED || return 0
    SCC_SERVICE_STOPPED=false
    echo "Starting scc_daemon service..."
    as_root systemctl start scc_daemon.service || log_error "Failed to start scc_daemon service."
}

restore_scc_ownership() {
    getent passwd sccadmin >/dev/null 2>&1 || return 0
    as_root chown -R sccadmin:sccgroup "$SCC_HOME"
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

    stop_scc_service_if_running
    ensure_not_running "SAP JVM" "$SAPJVM_HOME" || return 1

    mkdir -p "$extract_dir"
    if ! unzip -q "$artifact" -d "$extract_dir"; then
        log_error "Failed to extract $artifact"
        return 1
    fi
    if [[ ! -d "$extract_dir/sapjvm_8" ]]; then
        log_error "Expected sapjvm_8 directory in $artifact."
        return 1
    fi

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

    stop_scc_service_if_running
    ensure_not_running "SAP Cloud Connector" "$SCC_HOME" || return 1

    mkdir -p "$backup_dir"
    if [[ -d "$SCC_HOME/config" ]]; then
        as_root cp -a "$SCC_HOME/config" "$backup_dir/config"
    fi
    if [[ -d "$SCC_HOME/scc_config" ]]; then
        as_root cp -a "$SCC_HOME/scc_config" "$backup_dir/scc_config"
    fi

    as_root rm -rf "$SCC_HOME"
    as_root mkdir -p "$SCC_HOME"
    if ! as_root tar -xzf "$artifact" -C "$SCC_HOME"; then
        preserve_scc_config_backup "$backup_dir"
        log_error "Failed to extract $artifact into $SCC_HOME."
        return 1
    fi
    if [[ ! -f "$SCC_HOME/go.sh" ]]; then
        preserve_scc_config_backup "$backup_dir"
        log_error "Expected go.sh in extracted SAP Cloud Connector archive."
        return 1
    fi

    if [[ -d "$backup_dir/config" ]]; then
        as_root rm -rf "$SCC_HOME/config"
        as_root cp -a "$backup_dir/config" "$SCC_HOME/config"
    fi
    if [[ -d "$backup_dir/scc_config" ]]; then
        as_root rm -rf "$SCC_HOME/scc_config"
        as_root cp -a "$backup_dir/scc_config" "$SCC_HOME/scc_config"
    fi

    write_version_marker "$SCC_HOME" "$version"
    restore_scc_ownership
    echo "SAP Cloud Connector archive updated at $SCC_HOME."
}

download_and_update() {
    local product_name=$1
    local product_prefix=$2
    local version=$3
    local file_type=$4
    local previous_dir=$PWD
    local status=0

    if [[ -z "$version" ]]; then
        log_error "Could not determine latest $product_name version."
        return 1
    fi

    WORK_DIR=$(mktemp -d)
    cd "$WORK_DIR"

    fetch_and_apply_update "$product_name" "$product_prefix" "$version" "$file_type" || status=1

    cd "$previous_dir"
    cleanup
    WORK_DIR=""
    start_scc_service_if_stopped

    if [[ "$status" -eq 0 ]]; then
        echo "$product_name update completed."
    fi
    return "$status"
}

fetch_and_apply_update() {
    local product_name=$1
    local product_prefix=$2
    local version=$3
    local file_type=$4
    local artifact="${product_prefix}-${version}-linux-x64.${file_type}"
    local download_url="${DOWNLOAD_BASE_URL}/${artifact}"
    local sha1_url="${download_url}.sha1"
    local rpm_package
    local -a rpm_packages

    echo "Downloading $product_name $version..."
    if ! download_file "$download_url" "$artifact"; then
        log_error "Failed to download $download_url"
        return 1
    fi
    if ! download_file "$sha1_url" "${artifact}.sha1"; then
        log_error "Failed to download $sha1_url"
        return 1
    fi
    verify_sha1 "$artifact" "${artifact}.sha1" || return 1

    if [[ "$INSTALL_MODE" == "archive" && "$product_prefix" == "sapjvm" ]]; then
        replace_sapjvm_archive "$artifact" "$version"
    elif [[ "$INSTALL_MODE" == "archive" && "$product_prefix" == "sapcc" ]]; then
        replace_scc_archive "$artifact" "$version"
    else
        if [[ "$file_type" == "zip" ]]; then
            if ! unzip -q "$artifact"; then
                log_error "Failed to extract $artifact"
                return 1
            fi
            mapfile -t rpm_packages < <(find . -maxdepth 1 -type f -name '*.rpm' -print)
            if [[ "${#rpm_packages[@]}" -ne 1 ]]; then
                log_error "Expected one RPM in $artifact, found ${#rpm_packages[@]}."
                return 1
            fi
            rpm_package=${rpm_packages[0]}
        else
            rpm_package=$artifact
        fi

        if [[ "$product_prefix" == "sapcc" ]]; then
            backup_rpm_scc_config
        fi

        echo "Updating $product_name..."
        if ! update_rpm "$rpm_package"; then
            log_error "Failed to update $product_name via rpm."
            return 1
        fi
    fi
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
    [[ -n "$EMAIL" ]] || return 0
    if ! command_exists sendmail; then
        log_error "sendmail not found; skipping the update summary email."
        return 0
    fi
    {
        echo "To: $EMAIL"
        echo "Subject: SAP Cloud Connector Helper Update Summary"
        echo
        printf 'Update Summary:%s\n' "$UPDATE_RESULTS"
    } | sendmail -t || log_error "Failed to send the update summary email to $EMAIL."
}

main() {
    local tools_page
    local scc_version
    local jvm_version
    local scc_file_type
    local jvm_file_type
    local overall_status=0

    parse_args "$@"
    if [[ -n "$EMAIL" ]]; then
        command_exists sendmail || die "sendmail is required when an email recipient is provided."
    fi
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

    jvm_version=$(resolve_version "$tools_page" "sapjvm" "$jvm_file_type" "$JVM_VERSION_OVERRIDE")
    scc_version=$(resolve_version "$tools_page" "sapcc" "$scc_file_type" "$SCC_VERSION_OVERRIDE")

    update_common "SAP JVM" "sapjvm" '^sapjvm$' "$jvm_version" "$jvm_file_type" || overall_status=1
    update_common "SAP Cloud Connector" "sapcc" '^com[.]sap[.]scc[.-]ui$' "$scc_version" "$scc_file_type" || overall_status=1

    printf 'Update Summary:%s\n' "$UPDATE_RESULTS"
    if [[ "$overall_status" -ne 0 ]]; then
        die "One or more updates failed."
    fi
    echo "All updates completed."
}

main "$@"
