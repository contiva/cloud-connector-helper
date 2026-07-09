#!/usr/bin/env bash
set -Eeuo pipefail

TOOLS_URL="https://tools.hana.ondemand.com/#cloud"
DOWNLOAD_BASE_URL="https://tools.hana.ondemand.com/additional"
USER_AGENT="cloud-connector-helper/1.4"
UNATTENDED=false
ACCEPT_EULA=false
QUIET=false
DRY_RUN=false
JVM_VERSION_OVERRIDE=""
SCC_VERSION_OVERRIDE=""
SCC_SERVICE_STOPPED=false
SCC_INSTALLED=false
LOG_FILE="${LOG_FILE:-/var/log/cloud-connector-helper.log}"
WORK_DIR=""
PACKAGE_MANAGER=""
INSTALL_MODE=""
INSTALL_ROOT="${INSTALL_ROOT:-/opt/sap}"
SAPJVM_HOME="${SAPJVM_HOME:-${INSTALL_ROOT}/sapjvm_8}"
SCC_HOME="${SCC_HOME:-${INSTALL_ROOT}/cloud-connector}"

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
trap cleanup EXIT

usage() {
    cat <<'EOF'
Usage: install.sh [--unattended] [--accept-eula] [--jvm-version <version>] [--scc-version <version>]

Installs SAP JVM and SAP Cloud Connector on supported Linux x86_64 glibc systems.

  --unattended            Run without prompts; requires --accept-eula.
  --accept-eula           Accept the SAP developer EULA without prompting.
  --jvm-version <x.y.z>   Install this SAP JVM version instead of the latest.
  --scc-version <x.y.z>   Install this SAP Cloud Connector version instead of the latest.
  --dry-run               Show what would be installed without changing anything.
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
                ;;
            --accept-eula)
                ACCEPT_EULA=true
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
                die "Unknown argument: $1"
                ;;
        esac
        shift
    done

    if $UNATTENDED && ! $ACCEPT_EULA; then
        die "Unattended mode requires --accept-eula. Review the EULA at $TOOLS_URL first."
    fi
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

    info "Installing required packages..."
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

    { grep -Eo "${prefix}-[0-9.]+-linux-x64\.${safe_extension}" <<< "$page" || true; } \
        | sed -E "s/${prefix}-([0-9.]+)-linux-x64\.${safe_extension}/\1/" \
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
        grep -qF "${prefix}-${override}-linux-x64.${extension}" <<< "$page" \
            || die "Version ${override} of ${prefix} is not available. Available versions: $(list_versions "$page" "$prefix" "$extension" | tr '\n' ' ')"
        echo "$override"
        return 0
    fi
    latest_version "$page" "$prefix" "$extension"
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

    [[ -n "$expected" ]] || die "SHA1 file is empty: $sha1_filename"
    [[ "$expected" == "$actual" ]] || die "Hash verification failed for $filename"
}

install_rpm() {
    local rpm_package=$1

    as_root rpm -Uvh "$rpm_package"
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
        die "Stop the SAP Cloud Connector (or the listed processes) before installing."
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
    as_root systemctl start scc_daemon.service || log_error "Failed to start scc_daemon service."
}

ensure_scc_user() {
    local nologin_shell

    getent group sccgroup >/dev/null 2>&1 || as_root groupadd --system sccgroup
    if ! getent passwd sccadmin >/dev/null 2>&1; then
        nologin_shell=$(command -v nologin || echo /bin/false)
        as_root useradd --system --gid sccgroup --home-dir "$SCC_HOME" --no-create-home --shell "$nologin_shell" sccadmin
    fi
}

setup_scc_service() {
    if ! systemd_available; then
        note "systemd not detected; start the Cloud Connector manually with: JAVA_HOME=$SAPJVM_HOME $SCC_HOME/go.sh"
        return 0
    fi
    if [[ ! -x "$SAPJVM_HOME/bin/java" ]]; then
        log_error "No SAP JVM found at $SAPJVM_HOME; skipping scc_daemon service setup. Start manually with: JAVA_HOME=<jvm> $SCC_HOME/go.sh"
        return 0
    fi

    ensure_scc_user
    as_root chown -R sccadmin:sccgroup "$SCC_HOME"

    as_root tee /etc/systemd/system/scc_daemon.service >/dev/null <<EOF
[Unit]
Description=SAP Cloud Connector (archive installation)
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=sccadmin
Group=sccgroup
Environment=JAVA_HOME=${SAPJVM_HOME}
WorkingDirectory=${SCC_HOME}
ExecStart=${SCC_HOME}/go.sh
Restart=on-failure
RestartSec=10
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
    as_root systemctl daemon-reload
    as_root systemctl enable scc_daemon.service
    as_root systemctl restart scc_daemon.service || log_error "Failed to start scc_daemon service."
    SCC_SERVICE_STOPPED=false
    ok "scc_daemon service installed, enabled, and started."
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

    stop_scc_service_if_running
    ensure_not_running "SAP JVM" "$SAPJVM_HOME"

    mkdir -p "$extract_dir"
    unzip -q "$artifact" -d "$extract_dir" || die "Failed to extract $artifact"
    [[ -d "$extract_dir/sapjvm_8" ]] || die "Expected sapjvm_8 directory in $artifact."

    as_root mkdir -p "$(dirname "$SAPJVM_HOME")"
    as_root rm -rf "$SAPJVM_HOME"
    as_root mv "$extract_dir/sapjvm_8" "$SAPJVM_HOME"
    write_version_marker "$SAPJVM_HOME" "$version"
    ok "SAP JVM archive installed at $SAPJVM_HOME."
}

install_scc_archive() {
    local artifact=$1
    local version=$2

    stop_scc_service_if_running
    ensure_not_running "SAP Cloud Connector" "$SCC_HOME"

    as_root rm -rf "$SCC_HOME"
    as_root mkdir -p "$SCC_HOME"
    as_root tar -xzf "$artifact" -C "$SCC_HOME" || die "Failed to extract $artifact"
    [[ -f "$SCC_HOME/go.sh" ]] || die "Expected go.sh in extracted SAP Cloud Connector archive."
    write_version_marker "$SCC_HOME" "$version"
    ok "SAP Cloud Connector archive installed at $SCC_HOME."
    setup_scc_service
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

    info "Downloading $product_name $version..."
    download_file "$download_url" "$artifact" || die "Failed to download $download_url. Check network connectivity and proxy settings (e.g. https_proxy)."
    download_file "$sha1_url" "${artifact}.sha1" || die "Failed to download $sha1_url. Check network connectivity and proxy settings (e.g. https_proxy)."
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

        info "Installing $product_name..."
        run_quiet install_rpm "$rpm_package" || die "Failed to install $product_name"
    fi

    cd "$previous_dir"
    cleanup
    WORK_DIR=""
    start_scc_service_if_stopped
    ok "$product_name installation completed."
}

ask_yes_no() {
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

os_pretty_name() {
    local name=""

    if [[ -r /etc/os-release ]]; then
        name=$(sed -nE 's/^PRETTY_NAME="?([^"]*)"?$/\1/p' /etc/os-release | head -n1)
    fi
    echo "${name:-$(uname -s)}"
}

print_install_plan() {
    local jvm_version=$1
    local scc_version=$2

    section "Installation plan"
    echo "  System:               $(os_pretty_name), $(uname -m)"
    echo "  Install mode:         $INSTALL_MODE ($PACKAGE_MANAGER)"
    if [[ "$INSTALL_MODE" == "archive" ]]; then
        echo "  SAP JVM:              ${jvm_version:-unknown} -> $SAPJVM_HOME"
        echo "  SAP Cloud Connector:  ${scc_version:-unknown} -> $SCC_HOME"
    else
        echo "  SAP JVM:              ${jvm_version:-unknown} (RPM package)"
        echo "  SAP Cloud Connector:  ${scc_version:-unknown} (RPM package)"
    fi
    echo
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

print_completion_panel() {
    local ip_address=""

    section "Installation finished"
    if ! $SCC_INSTALLED; then
        ok "Done."
        return 0
    fi

    if systemd_available && systemctl is-active --quiet scc_daemon.service 2>/dev/null; then
        echo "Waiting for the administration UI to become available..."
        if wait_for_scc_ui 90; then
            ok "Administration UI is up."
        else
            note "The administration UI did not respond within 90s; check: systemctl status scc_daemon"
        fi
    fi

    if command_exists hostname; then
        ip_address=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
    fi

    echo
    echo "  URL:      https://${ip_address:-<server-ip>}:8443"
    echo "  User:     Administrator"
    echo "  Password: manage (must be changed at first login)"
    if systemd_available; then
        echo "  Service:  systemctl status scc_daemon"
    fi
    if [[ "$INSTALL_MODE" == "archive" ]]; then
        echo "  Config:   $SCC_HOME/config"
    fi
    echo
}

main() {
    local tools_page
    local scc_version
    local jvm_version
    local scc_file_type
    local jvm_file_type

    parse_args "$@"
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

    jvm_version=$(resolve_version "$tools_page" "sapjvm" "$jvm_file_type" "$JVM_VERSION_OVERRIDE")
    scc_version=$(resolve_version "$tools_page" "sapcc" "$scc_file_type" "$SCC_VERSION_OVERRIDE")

    print_install_plan "$jvm_version" "$scc_version"

    if $DRY_RUN; then
        ok "Dry run complete - nothing was installed."
        return 0
    fi

    echo "Please read the EULA at: https://${EULA_COOKIE_VALUE}"
    if $ACCEPT_EULA; then
        ok "EULA accepted via --accept-eula."
    else
        ask_yes_no "Do you accept the EULA?" || die "You did not accept the EULA. Install aborted."
    fi

    if ask_yes_no "Install SAP JVM ${jvm_version}?" y; then
        download_and_install "SAP JVM" "sapjvm" "$jvm_version" "$jvm_file_type"
    fi

    if ask_yes_no "Install SAP Cloud Connector ${scc_version}?" y; then
        download_and_install "SAP Cloud Connector" "sapcc" "$scc_version" "$scc_file_type"
        SCC_INSTALLED=true
    fi

    print_completion_panel
}

main "$@"
