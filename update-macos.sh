#!/usr/bin/env bash
# Updates a SAP Cloud Connector installation created by install-macos.sh.
# SAP supports the macOS Cloud Connector for non-productive use only.
set -Eeuo pipefail

TOOLS_URL="https://tools.hana.ondemand.com/#cloud"
DOWNLOAD_BASE_URL="https://tools.hana.ondemand.com/additional"
USER_AGENT="cloud-connector-helper/1.4"
UNATTENDED=false
QUIET=false
DRY_RUN=false
SCC_VERSION_OVERRIDE=""
INSTALL_ROOT="${INSTALL_ROOT:-$HOME/sap}"
SCC_HOME="${SCC_HOME:-${INSTALL_ROOT}/cloud-connector}"
LOG_FILE="${LOG_FILE:-$HOME/Library/Logs/cloud-connector-helper.log}"
SCC_LOG_FILE="$HOME/Library/Logs/com.sap.scc.log"
PLIST_LABEL="com.sap.scc"
PLIST_PATH="$HOME/Library/LaunchAgents/${PLIST_LABEL}.plist"
SCC_ARCH=""
AGENT_STOPPED=false
WORK_DIR=""

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
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    cat >> "$LOG_FILE" 2>/dev/null || cat >/dev/null
}

cleanup() {
    if [[ -n "${WORK_DIR:-}" && -d "$WORK_DIR" ]]; then
        rm -rf "$WORK_DIR"
    fi
}
trap cleanup EXIT

usage() {
    cat <<'EOF'
Usage: update-macos.sh [--unattended] [--scc-version <version>] [--dry-run]

Updates a SAP Cloud Connector installation created by install-macos.sh.
SAP supports the macOS Cloud Connector for non-productive use only.

  --unattended            Run without prompts.
  --scc-version <x.y.z>   Update to this SAP Cloud Connector version instead of the latest.
  --dry-run               Only check for updates; exit code 2 if an update is available.
  --quiet                 Append verbose output to ~/Library/Logs/cloud-connector-helper.log.

Set NO_COLOR to disable colored output.
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --unattended)
                UNATTENDED=true
                ;;
            --dry-run)
                DRY_RUN=true
                ;;
            --quiet)
                QUIET=true
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
}

require_supported_platform() {
    [[ "$(uname -s)" == "Darwin" ]] || die "This helper supports macOS only. Use update.sh on Linux."
    case "$(uname -m)" in
        arm64)
            SCC_ARCH=aarch64
            ;;
        x86_64)
            SCC_ARCH=x64
            ;;
        *)
            die "Unsupported architecture: $(uname -m). SAP publishes macOS artifacts for arm64 and x86_64."
            ;;
    esac
    command_exists curl || die "curl is required."
    command_exists shasum || die "shasum is required."
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

    { grep -Eo "sapcc-[0-9.]+-macosx-${SCC_ARCH}\.tar\.gz" <<< "$page" || true; } \
        | sed -E "s/sapcc-([0-9.]+)-macosx-${SCC_ARCH}\.tar\.gz/\1/" \
        | sort -uV
}

latest_version() {
    list_versions "$1" | tail -n1
}

resolve_version() {
    local page=$1
    local override=$2

    if [[ -n "$override" ]]; then
        grep -qF "sapcc-${override}-macosx-${SCC_ARCH}.tar.gz" <<< "$page" \
            || die "Version ${override} is not available for macosx-${SCC_ARCH}. Available versions: $(list_versions "$page" | tr '\n' ' ')"
        echo "$override"
        return 0
    fi
    latest_version "$page"
}

installed_version() {
    local marker="$SCC_HOME/.cloud-connector-helper-version"

    [[ -f "$marker" ]] || return 0
    awk 'NR == 1 { print; exit }' "$marker"
}

download_file() {
    local url=$1
    local output=$2

    local progress="--silent --show-error"
    if [[ -t 1 ]] && ! $QUIET; then
        progress="--progress-bar"
    fi

    # shellcheck disable=SC2086
    curl -fL $progress --proto '=https' --tlsv1.2 --user-agent "$USER_AGENT" \
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
    actual=$(shasum -a 1 "$filename" | awk '{print $1}')

    [[ -n "$expected" ]] || die "SHA1 file is empty: $sha1_filename"
    [[ "$expected" == "$actual" ]] || die "Hash verification failed for $filename"
}

ensure_not_running() {
    local processes

    command_exists pgrep || return 0
    processes=$(pgrep -fl -- "$SCC_HOME" 2>/dev/null | head -n 5) || true
    if [[ -n "$processes" ]]; then
        log_error "SAP Cloud Connector appears to be in use by these processes:"
        echo "$processes" >&2
        die "Stop the SAP Cloud Connector (or the listed processes) before updating."
    fi
}

write_version_marker() {
    printf '%s\n' "$1" > "$SCC_HOME/.cloud-connector-helper-version"
}

launch_agent_loaded() {
    launchctl print "gui/$(id -u)/${PLIST_LABEL}" >/dev/null 2>&1
}

stop_launch_agent() {
    local waited=0

    if launch_agent_loaded; then
        info "Stopping the ${PLIST_LABEL} launch agent..."
        launchctl bootout "gui/$(id -u)/${PLIST_LABEL}" 2>/dev/null || true
        AGENT_STOPPED=true
        # launchctl bootout is asynchronous; wait for the process to exit.
        if command_exists pgrep; then
            while pgrep -f -- "$SCC_HOME" >/dev/null 2>&1 && (( waited < 30 )); do
                sleep 1
                waited=$((waited + 1))
            done
        fi
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

start_launch_agent_if_stopped() {
    $AGENT_STOPPED || return 0
    AGENT_STOPPED=false
    [[ -f "$PLIST_PATH" ]] || return 0

    info "Starting the ${PLIST_LABEL} launch agent..."
    if launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH" 2>/dev/null; then
        if wait_for_scc_ui 90; then
            ok "The administration UI responds on port 8443."
        else
            note "The launch agent started, but the UI did not respond within 90s; check: $SCC_LOG_FILE"
        fi
    else
        log_error "Failed to bootstrap the launch agent. Start manually with: launchctl bootstrap gui/$(id -u) $PLIST_PATH"
    fi
}

update_scc() {
    local version=$1
    local artifact="sapcc-${version}-macosx-${SCC_ARCH}.tar.gz"
    local download_url="${DOWNLOAD_BASE_URL}/${artifact}"
    local sha1_url="${download_url}.sha1"
    local previous_dir=$PWD
    local backup_dir

    WORK_DIR=$(mktemp -d)
    backup_dir="$WORK_DIR/scc-config-backup"
    cd "$WORK_DIR"

    info "Downloading SAP Cloud Connector $version..."
    download_file "$download_url" "$artifact" || die "Failed to download $download_url. Check network connectivity and proxy settings (e.g. https_proxy)."
    download_file "$sha1_url" "${artifact}.sha1" || die "Failed to download $sha1_url. Check network connectivity and proxy settings (e.g. https_proxy)."
    verify_sha1 "$artifact" "${artifact}.sha1"

    stop_launch_agent
    ensure_not_running

    mkdir -p "$backup_dir"
    if [[ -d "$SCC_HOME/config" ]]; then
        cp -a "$SCC_HOME/config" "$backup_dir/config"
    fi
    if [[ -d "$SCC_HOME/scc_config" ]]; then
        cp -a "$SCC_HOME/scc_config" "$backup_dir/scc_config"
    fi

    rm -rf "$SCC_HOME"
    mkdir -p "$SCC_HOME"
    if ! tar -xzf "$artifact" -C "$SCC_HOME"; then
        rm -rf "${SCC_HOME}.config-backup"
        cp -a "$backup_dir" "${SCC_HOME}.config-backup"
        die "Failed to extract $artifact. Configuration backup preserved at ${SCC_HOME}.config-backup."
    fi
    [[ -f "$SCC_HOME/go.sh" ]] || die "Expected go.sh in extracted SAP Cloud Connector archive."

    if [[ -d "$backup_dir/config" ]]; then
        rm -rf "$SCC_HOME/config"
        cp -a "$backup_dir/config" "$SCC_HOME/config"
    fi
    if [[ -d "$backup_dir/scc_config" ]]; then
        rm -rf "$SCC_HOME/scc_config"
        cp -a "$backup_dir/scc_config" "$SCC_HOME/scc_config"
    fi

    write_version_marker "$version"
    ok "SAP Cloud Connector updated at $SCC_HOME."

    cd "$previous_dir"
    cleanup
    WORK_DIR=""

    start_launch_agent_if_stopped
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
        [[ -z "$response" || "$(tr '[:upper:]' '[:lower:]' <<< "$response")" == "y" ]]
    else
        read -r -p "$prompt (y/N) " response
        [[ "$(tr '[:upper:]' '[:lower:]' <<< "$response")" == "y" ]]
    fi
}

main() {
    local tools_page
    local scc_version
    local current_version

    parse_args "$@"
    require_supported_platform

    current_version=$(installed_version)
    [[ -n "$current_version" ]] || die "No SAP Cloud Connector installation found at $SCC_HOME (missing version marker). Run install-macos.sh first."

    tools_page=$(fetch_tools_page) || die "Failed to fetch $TOOLS_URL. Check network connectivity and proxy settings (e.g. https_proxy)."
    EULA_COOKIE_NAME=$(extract_eula_cookie_name "$tools_page")
    EULA_COOKIE_VALUE=$(extract_eula_cookie_value "$tools_page")
    [[ -n "$EULA_COOKIE_NAME" && -n "$EULA_COOKIE_VALUE" ]] || die "Failed to extract EULA cookie information."

    scc_version=$(resolve_version "$tools_page" "$SCC_VERSION_OVERRIDE")
    [[ -n "$scc_version" ]] || die "Could not determine the latest SAP Cloud Connector version."

    if $DRY_RUN; then
        section "Update check (dry run)"
        if [[ "$current_version" == "$scc_version" ]]; then
            ok "SAP Cloud Connector: $current_version is up to date"
            echo
            ok "Everything is up to date."
            return 0
        fi
        note "SAP Cloud Connector: UPDATE AVAILABLE ($current_version installed, $scc_version available)"
        echo
        echo "1 update available. Run without --dry-run to install it."
        exit 2
    fi

    info "SAP Cloud Connector: installed $current_version, latest available $scc_version"
    if [[ "$current_version" == "$scc_version" ]]; then
        ok "The latest version of SAP Cloud Connector is already installed."
        return 0
    fi

    ask_yes_no "Do you accept the EULA (https://${EULA_COOKIE_VALUE})?" || die "You did not accept the EULA. Update aborted."

    if ask_yes_no "Update SAP Cloud Connector to ${scc_version}?" y; then
        update_scc "$scc_version"
        ok "All updates completed."
    else
        note "Update skipped by user."
    fi
}

main "$@"
