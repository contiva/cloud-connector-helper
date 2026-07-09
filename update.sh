#!/usr/bin/env bash
set -Eeuo pipefail

TOOLS_URL="https://tools.hana.ondemand.com/#cloud"
DOWNLOAD_BASE_URL="https://tools.hana.ondemand.com/additional"
USER_AGENT="cloud-connector-helper/1.5"
UNATTENDED=false
EMAIL=""
QUIET=false
DRY_RUN=false
PENDING_UPDATES=0
JVM_VERSION_OVERRIDE=""
SCC_VERSION_OVERRIDE=""
SCC_SERVICE_STOPPED=false
LOG_FILE="${LOG_FILE:-/var/log/cloud-connector-helper.log}"
UPDATE_RESULTS=""
WORK_DIR=""
PACKAGE_MANAGER=""
INSTALL_MODE=""
LINUX_ARCH=""
JVM_AVAILABLE=true
INSTALL_ROOT="${INSTALL_ROOT:-/opt/sap}"
SAPJVM_HOME="${SAPJVM_HOME:-${INSTALL_ROOT}/sapjvm_8}"
SCC_HOME="${SCC_HOME:-${INSTALL_ROOT}/cloud-connector}"
SCC_RPM_HOME="${SCC_RPM_HOME:-/opt/sap/scc}"

if [[ -t 1 && -z "${NO_COLOR:-}" && "${TERM:-}" != "dumb" ]]; then
    C_BOLD=$'\033[1m'
    C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'
    C_RED=$'\033[31m'
    C_RESET=$'\033[0m'
else
    C_BOLD="" C_GREEN="" C_YELLOW="" C_RED="" C_RESET=""
fi

die() {
    echo "${C_RED}ERROR:${C_RESET} $*" >&2
    exit 1
}

log_error() {
    echo "${C_RED}ERROR:${C_RESET} $*" >&2
}

info() {
    echo "${C_BOLD}==>${C_RESET} $*"
}

ok() {
    echo "${C_GREEN} ✓${C_RESET} $*"
}

note() {
    echo "${C_YELLOW} !${C_RESET} $*"
}

section() {
    echo
    echo "${C_BOLD}$*${C_RESET}"
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

append_log() {
    if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
        cat >> "$LOG_FILE" 2>/dev/null || cat >/dev/null
    elif command_exists sudo; then
        sudo tee -a "$LOG_FILE" >/dev/null 2>&1 || cat >/dev/null
    else
        cat >/dev/null
    fi
}

run_quiet() {
    if ! $QUIET; then
        "$@"
        return
    fi

    local out rc=0
    out=$(mktemp)
    "$@" >"$out" 2>&1 || rc=$?
    {
        printf '\n[%s] %s (exit %s)\n' "$(date '+%F %T')" "$*" "$rc"
        cat "$out"
    } | append_log
    if [[ "$rc" -ne 0 ]]; then
        cat "$out" >&2
    fi
    rm -f "$out"
    return "$rc"
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
    if $DRY_RUN; then
        return 0
    fi
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
Linux glibc systems (x86_64, aarch64, ppc64le).

  --unattended [email]    Run without prompts; optionally send a summary email.
  --jvm-version <x.y.z>   Update to this SAP JVM version instead of the latest.
  --scc-version <x.y.z>   Update to this SAP Cloud Connector version instead of the latest.
  --dry-run               Only check for updates; exit code 2 if updates are available.
  --quiet                 Hide package-manager output; it is appended to
                          /var/log/cloud-connector-helper.log instead.

Set NO_COLOR to disable colored output.
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
            --dry-run)
                DRY_RUN=true
                ;;
            --quiet)
                QUIET=true
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
    case "$(uname -m)" in
        x86_64)
            LINUX_ARCH=x64
            ;;
        aarch64)
            LINUX_ARCH=aarch64
            # SAP does not publish the SAP JVM for aarch64; an existing JDK is used instead.
            JVM_AVAILABLE=false
            ;;
        ppc64le)
            LINUX_ARCH=ppc64le
            ;;
        *)
            die "Unsupported architecture: $(uname -m). SAP publishes Linux artifacts for x86_64, aarch64, and ppc64le."
            ;;
    esac
    getconf GNU_LIBC_VERSION >/dev/null 2>&1 || die "SAP Linux artifacts require glibc; musl-based distributions such as Alpine Linux are not supported."

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

    info "Ensuring required packages are installed..."
    case "$PACKAGE_MANAGER" in
        dnf)
            run_quiet as_root dnf -y install "${packages[@]}"
            ;;
        yum)
            run_quiet as_root yum -y install "${packages[@]}"
            ;;
        zypper)
            run_quiet as_root zypper --non-interactive install "${packages[@]}"
            ;;
        apt-get)
            run_quiet as_root apt-get update
            run_quiet as_root apt-get install -y --no-install-recommends "${packages[@]}"
            ;;
        pacman)
            run_quiet as_root pacman -Sy --noconfirm --needed "${packages[@]}"
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

list_versions() {
    local page=$1
    local prefix=$2
    local extension=$3
    local safe_extension

    safe_extension=$(sed -E 's/[][\/.^$*+?{}()|]/\\&/g' <<< "$extension")

    { grep -Eo "${prefix}-[0-9.]+-linux-${LINUX_ARCH}\.${safe_extension}" <<< "$page" || true; } \
        | sed -E "s/${prefix}-([0-9.]+)-linux-${LINUX_ARCH}\.${safe_extension}/\1/" \
        | sort -uV
}

latest_version() {
    list_versions "$@" | tail -n1
}

resolve_version() {
    local page=$1
    local prefix=$2
    local extension=$3
    local override=$4

    if [[ -n "$override" ]]; then
        grep -qF "${prefix}-${override}-linux-${LINUX_ARCH}.${extension}" <<< "$page" \
            || die "Version ${override} of ${prefix} is not available for linux-${LINUX_ARCH}. Available versions: $(list_versions "$page" "$prefix" "$extension" | tr '\n' ' ')"
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
    local default=${2:-n}
    local response

    if $UNATTENDED; then
        echo "$prompt: Auto-accepting for unattended mode."
        return 0
    fi

    if [[ "$default" == "y" ]]; then
        read -r -p "$prompt (Y/n) " response
        [[ -z "$response" || "${response,,}" == "y" ]]
    else
        read -r -p "$prompt (y/N) " response
        [[ "${response,,}" == "y" ]]
    fi
}

get_installed_version() {
    local product_prefix=$1
    local package_regex=$2

    if [[ "$INSTALL_MODE" == "archive" ]]; then
        archive_installed_version "$product_prefix"
    else
        installed_version "$package_regex"
    fi
}

dry_run_check() {
    local product_name=$1
    local product_prefix=$2
    local package_regex=$3
    local new_version=$4
    local current_version

    current_version=$(get_installed_version "$product_prefix" "$package_regex")
    if [[ -z "$current_version" ]]; then
        note "$product_name: not installed (latest available: ${new_version:-unknown})"
    elif [[ "$current_version" == "$new_version" ]]; then
        ok "$product_name: $current_version is up to date"
    else
        note "$product_name: UPDATE AVAILABLE ($current_version installed, ${new_version:-unknown} available)"
        PENDING_UPDATES=$((PENDING_UPDATES + 1))
    fi
}

download_file() {
    local url=$1
    local output=$2
    local -a progress_opts

    if [[ -t 1 ]] && ! $QUIET; then
        progress_opts=(--progress-bar)
    else
        progress_opts=(--silent --show-error)
    fi

    curl -fL "${progress_opts[@]}" --proto '=https' --tlsv1.2 --user-agent "$USER_AGENT" \
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
    local processes

    command_exists pgrep || return 0
    processes=$(pgrep -af -- "$home_dir" 2>/dev/null | head -n 5) || true
    if [[ -n "$processes" ]]; then
        log_error "$product_name appears to be in use by these processes:"
        echo "$processes" >&2
        log_error "Stop the SAP Cloud Connector (or the listed processes) before updating."
        return 1
    fi
}

wait_for_scc_ui() {
    local timeout_seconds=${1:-90}
    local waited=0

    while (( waited < timeout_seconds )); do
        if curl -skf -o /dev/null --max-time 3 https://localhost:8443/; then
            return 0
        fi
        sleep 3
        waited=$((waited + 3))
    done
    return 1
}

preserve_scc_config_backup() {
    local backup_dir=$1
    local rescue_dir="${SCC_HOME}.config-backup"

    as_root rm -rf "$rescue_dir"
    as_root cp -a "$backup_dir" "$rescue_dir"
    note "SAP Cloud Connector configuration backup preserved at $rescue_dir."
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
        info "SAP Cloud Connector configuration backed up to $backup_dir (previous backup replaced)."
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
        info "Stopping scc_daemon service..."
        as_root systemctl stop scc_daemon.service
        SCC_SERVICE_STOPPED=true
    fi
}

start_scc_service_if_stopped() {
    $SCC_SERVICE_STOPPED || return 0
    SCC_SERVICE_STOPPED=false
    info "Starting scc_daemon service..."
    if as_root systemctl start scc_daemon.service; then
        if wait_for_scc_ui 90; then
            ok "scc_daemon is running; the administration UI responds on port 8443."
        else
            note "scc_daemon started, but the UI did not respond within 90s; check: systemctl status scc_daemon"
        fi
    else
        log_error "Failed to start scc_daemon service."
    fi
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
    ok "SAP JVM archive updated at $SAPJVM_HOME."
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
    ok "SAP Cloud Connector archive updated at $SCC_HOME."
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
        ok "$product_name update completed."
    fi
    return "$status"
}

fetch_and_apply_update() {
    local product_name=$1
    local product_prefix=$2
    local version=$3
    local file_type=$4
    local artifact="${product_prefix}-${version}-linux-${LINUX_ARCH}.${file_type}"
    local download_url="${DOWNLOAD_BASE_URL}/${artifact}"
    local sha1_url="${download_url}.sha1"
    local rpm_package
    local -a rpm_packages

    info "Downloading $product_name $version..."
    if ! download_file "$download_url" "$artifact"; then
        log_error "Failed to download $download_url. Check network connectivity and proxy settings (e.g. https_proxy)."
        return 1
    fi
    if ! download_file "$sha1_url" "${artifact}.sha1"; then
        log_error "Failed to download $sha1_url. Check network connectivity and proxy settings (e.g. https_proxy)."
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

        info "Updating $product_name..."
        if ! run_quiet update_rpm "$rpm_package"; then
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

    current_version=$(get_installed_version "$product_prefix" "$package_regex")
    if [[ -z "$current_version" ]]; then
        note "$product_name is not installed; skipping update."
        append_update_results "$product_name" "SKIPPED - NOT INSTALLED"
        return 0
    fi

    info "$product_name: installed $current_version, latest available $new_version"

    if [[ "$new_version" == "$current_version" ]]; then
        ok "The latest version of $product_name is already installed."
        append_update_results "$product_name" "ALREADY UP-TO-DATE"
        return 0
    fi

    if ask_or_default_yes "Update $product_name to $new_version?" y; then
        if download_and_update "$product_name" "$product_prefix" "$new_version" "$file_type"; then
            append_update_results "$product_name" "SUCCESS"
        else
            append_update_results "$product_name" "FAILED"
            return 1
        fi
    else
        note "$product_name update skipped by user."
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
    if $DRY_RUN; then
        command_exists curl || die "curl is required for --dry-run."
    else
        install_required_packages
    fi

    tools_page=$(fetch_tools_page) || die "Failed to fetch $TOOLS_URL. Check network connectivity and proxy settings (e.g. https_proxy)."
    EULA_COOKIE_NAME=$(extract_eula_cookie_name "$tools_page")
    EULA_COOKIE_VALUE=$(extract_eula_cookie_value "$tools_page")
    [[ -n "$EULA_COOKIE_NAME" && -n "$EULA_COOKIE_VALUE" ]] || die "Failed to extract EULA cookie information."

    if [[ "$INSTALL_MODE" == "archive" ]]; then
        jvm_file_type=zip
        scc_file_type=tar.gz
    else
        jvm_file_type=rpm
        scc_file_type=zip
    fi

    if $JVM_AVAILABLE; then
        jvm_version=$(resolve_version "$tools_page" "sapjvm" "$jvm_file_type" "$JVM_VERSION_OVERRIDE")
    else
        [[ -z "$JVM_VERSION_OVERRIDE" ]] || die "SAP JVM is not published for linux-${LINUX_ARCH}; --jvm-version cannot be used."
        jvm_version=""
    fi
    scc_version=$(resolve_version "$tools_page" "sapcc" "$scc_file_type" "$SCC_VERSION_OVERRIDE")

    if $DRY_RUN; then
        section "Update check (dry run)"
        if $JVM_AVAILABLE; then
            dry_run_check "SAP JVM" "sapjvm" '^sapjvm$' "$jvm_version"
        else
            note "SAP JVM: not published for linux-${LINUX_ARCH}; managed outside this helper"
        fi
        dry_run_check "SAP Cloud Connector" "sapcc" '^com[.]sap[.]scc[.-]ui$' "$scc_version"
        echo
        if (( PENDING_UPDATES > 0 )); then
            echo "$PENDING_UPDATES update(s) available. Run without --dry-run to install them."
            exit 2
        fi
        ok "Everything is up to date."
        return 0
    fi

    ask_or_default_yes "Do you accept the EULA (https://${EULA_COOKIE_VALUE})?" || die "You did not accept the EULA. Update aborted."

    if $JVM_AVAILABLE; then
        update_common "SAP JVM" "sapjvm" '^sapjvm$' "$jvm_version" "$jvm_file_type" || overall_status=1
    else
        note "SAP JVM is not published for linux-${LINUX_ARCH}; skipping (managed outside this helper)."
        append_update_results "SAP JVM" "SKIPPED - NOT PUBLISHED FOR ${LINUX_ARCH}"
    fi
    update_common "SAP Cloud Connector" "sapcc" '^com[.]sap[.]scc[.-]ui$' "$scc_version" "$scc_file_type" || overall_status=1

    section "Update Summary"
    printf '%s\n' "${UPDATE_RESULTS#$'\n'}"
    echo
    if [[ "$overall_status" -ne 0 ]]; then
        die "One or more updates failed."
    fi
    ok "All updates completed."
}

main "$@"
