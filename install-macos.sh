#!/usr/bin/env bash
# Installs SAP Cloud Connector on macOS for development and testing.
# SAP supports the macOS Cloud Connector for non-productive use only.
set -Eeuo pipefail

TOOLS_URL="https://tools.hana.ondemand.com/#cloud"
DOWNLOAD_BASE_URL="https://tools.hana.ondemand.com/additional"
USER_AGENT="cloud-connector-helper/1.5"
UNATTENDED=false
ACCEPT_EULA=false
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
JAVA_HOME_RESOLVED=""
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

cleanup() {
    if [[ -n "${WORK_DIR:-}" && -d "$WORK_DIR" ]]; then
        rm -rf "$WORK_DIR"
    fi
}
trap cleanup EXIT

usage() {
    cat <<'EOF'
Usage: install-macos.sh [--unattended] [--accept-eula] [--scc-version <version>]

Installs SAP Cloud Connector on macOS for development and testing.
SAP supports the macOS Cloud Connector for non-productive use only.

The Cloud Connector is installed into ~/sap/cloud-connector (override with
INSTALL_ROOT or SCC_HOME) and started as a per-user launchd agent - no root
privileges are required. A Java runtime (1.8, 17, 21, or 25) must already be
installed; it is discovered via /usr/libexec/java_home.

  --unattended            Run without prompts; requires --accept-eula.
  --accept-eula           Accept the SAP developer EULA without prompting.
  --scc-version <x.y.z>   Install this SAP Cloud Connector version instead of the latest.
  --dry-run               Show what would be installed without changing anything.
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
            --accept-eula)
                ACCEPT_EULA=true
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

    if $UNATTENDED && ! $ACCEPT_EULA; then
        die "Unattended mode requires --accept-eula. Review the EULA at $TOOLS_URL first."
    fi
}

require_supported_platform() {
    [[ "$(uname -s)" == "Darwin" ]] || die "This helper supports macOS only. Use install.sh on Linux."
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

find_java_home() {
    local version candidate

    for version in 21 17 25 1.8; do
        candidate=$(/usr/libexec/java_home -v "$version" 2>/dev/null || true)
        if [[ -n "$candidate" && -x "$candidate/bin/java" ]]; then
            echo "$candidate"
            return 0
        fi
    done
    return 1
}

require_java() {
    JAVA_HOME_RESOLVED=$(find_java_home) || die "No suitable Java runtime found. SAP Cloud Connector requires Java 1.8, 17, 21, or 25.
Install one first, e.g. SapMachine: brew install --cask sapmachine-jdk (or https://sapmachine.io)."
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
        die "Stop the SAP Cloud Connector (or the listed processes) before installing."
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
        # launchctl bootout is asynchronous; wait for the process to exit.
        if command_exists pgrep; then
            while pgrep -f -- "$SCC_HOME" >/dev/null 2>&1 && (( waited < 30 )); do
                sleep 1
                waited=$((waited + 1))
            done
        fi
    fi
}

setup_launch_agent() {
    mkdir -p "$(dirname "$PLIST_PATH")"
    cat > "$PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${PLIST_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${SCC_HOME}/go.sh</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>JAVA_HOME</key>
        <string>${JAVA_HOME_RESOLVED}</string>
    </dict>
    <key>WorkingDirectory</key>
    <string>${SCC_HOME}</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>StandardOutPath</key>
    <string>${SCC_LOG_FILE}</string>
    <key>StandardErrorPath</key>
    <string>${SCC_LOG_FILE}</string>
</dict>
</plist>
EOF

    launchctl bootout "gui/$(id -u)/${PLIST_LABEL}" 2>/dev/null || true
    if launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH" 2>/dev/null; then
        ok "Launch agent ${PLIST_LABEL} installed and started."
    else
        note "Could not bootstrap the launch agent (no GUI session?). Start manually with: JAVA_HOME=$JAVA_HOME_RESOLVED $SCC_HOME/go.sh"
    fi
}

install_scc() {
    local version=$1
    local artifact="sapcc-${version}-macosx-${SCC_ARCH}.tar.gz"
    local download_url="${DOWNLOAD_BASE_URL}/${artifact}"
    local sha1_url="${download_url}.sha1"
    local previous_dir=$PWD

    WORK_DIR=$(mktemp -d)
    cd "$WORK_DIR"

    info "Downloading SAP Cloud Connector $version..."
    download_file "$download_url" "$artifact" || die "Failed to download $download_url. Check network connectivity and proxy settings (e.g. https_proxy)."
    download_file "$sha1_url" "${artifact}.sha1" || die "Failed to download $sha1_url. Check network connectivity and proxy settings (e.g. https_proxy)."
    verify_sha1 "$artifact" "${artifact}.sha1"

    stop_launch_agent
    ensure_not_running

    rm -rf "$SCC_HOME"
    mkdir -p "$SCC_HOME"
    tar -xzf "$artifact" -C "$SCC_HOME" || die "Failed to extract $artifact"
    [[ -f "$SCC_HOME/go.sh" ]] || die "Expected go.sh in extracted SAP Cloud Connector archive."
    write_version_marker "$version"
    ok "SAP Cloud Connector installed at $SCC_HOME."

    cd "$previous_dir"
    cleanup
    WORK_DIR=""

    setup_launch_agent
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

print_install_plan() {
    local scc_version=$1

    section "Installation plan"
    echo "  System:               macOS $(sw_vers -productVersion 2>/dev/null || true), $(uname -m)"
    echo "  Java runtime:         ${JAVA_HOME_RESOLVED}"
    echo "  SAP Cloud Connector:  ${scc_version:-unknown} (macosx-${SCC_ARCH}) -> $SCC_HOME"
    echo "  Service:              launchd agent ${PLIST_LABEL} (starts at login)"
    echo
    note "SAP supports the macOS Cloud Connector for development and testing only."
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
    section "Installation finished"

    if launch_agent_loaded; then
        echo "Waiting for the administration UI to become available..."
        if wait_for_scc_ui 90; then
            ok "Administration UI is up."
        else
            note "The administration UI did not respond within 90s; check: $SCC_LOG_FILE"
        fi
    fi

    echo
    echo "  URL:      https://localhost:8443"
    echo "  User:     Administrator"
    echo "  Password: manage (must be changed at first login)"
    echo "  Agent:    launchctl print gui/$(id -u)/${PLIST_LABEL}"
    echo "  Logs:     $SCC_LOG_FILE"
    echo "  Config:   $SCC_HOME/config"
    echo
}

main() {
    local tools_page
    local scc_version

    parse_args "$@"
    require_supported_platform
    require_java

    tools_page=$(fetch_tools_page) || die "Failed to fetch $TOOLS_URL. Check network connectivity and proxy settings (e.g. https_proxy)."
    EULA_COOKIE_NAME=$(extract_eula_cookie_name "$tools_page")
    EULA_COOKIE_VALUE=$(extract_eula_cookie_value "$tools_page")
    [[ -n "$EULA_COOKIE_NAME" && -n "$EULA_COOKIE_VALUE" ]] || die "Failed to extract EULA cookie information."

    scc_version=$(resolve_version "$tools_page" "$SCC_VERSION_OVERRIDE")
    [[ -n "$scc_version" ]] || die "Could not determine the latest SAP Cloud Connector version."

    print_install_plan "$scc_version"

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

    if ask_yes_no "Install SAP Cloud Connector ${scc_version}?" y; then
        install_scc "$scc_version"
        print_completion_panel
    else
        note "Nothing installed."
    fi
}

main "$@"
