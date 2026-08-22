#!/bin/zsh
set -euo pipefail

readonly SCRIPT_DIR="${0:A:h}"
readonly REPO_DIR="${SCRIPT_DIR:h}"
readonly USER_HOME="${HOME:?HOME is not set}"
readonly USER_ID="$(/usr/bin/id -u)"
readonly LABEL="com.local.wacom-recovery"
readonly INSTALL_DIR="${USER_HOME}/Library/Application Support/WacomRecovery"
readonly BINARY_PATH="${INSTALL_DIR}/wacom-recovery"
readonly PLIST_PATH="${USER_HOME}/Library/LaunchAgents/${LABEL}.plist"
readonly LOG_PATH="${USER_HOME}/Library/Logs/WacomRecovery.log"
readonly PRODUCT_NAME="${WACOM_PRODUCT_NAME:-Cintiq Pro 16}"
readonly GRACE_SECONDS="${WACOM_GRACE_SECONDS:-3}"
readonly COOLDOWN_SECONDS="${WACOM_COOLDOWN_SECONDS:-120}"

if [[ "$(/usr/bin/uname -s)" != "Darwin" ]]; then
    print -u2 "This project supports macOS only."
    exit 1
fi

if ! /usr/bin/xcrun --find swiftc >/dev/null 2>&1; then
    print -u2 "Swift is required. Install Apple's Command Line Tools with: xcode-select --install"
    exit 1
fi

print "Building the native event listener..."
/usr/bin/make -C "${REPO_DIR}" release

/bin/mkdir -p "${INSTALL_DIR}" "${USER_HOME}/Library/LaunchAgents" "${USER_HOME}/Library/Logs"
/usr/bin/install -m 0755 "${REPO_DIR}/.build/release/wacom-recovery" "${BINARY_PATH}"
/usr/bin/touch "${LOG_PATH}"

readonly TEMP_PLIST="$(/usr/bin/mktemp "${TMPDIR:-/tmp}/wacom-recovery.XXXXXX.plist")"
trap '/bin/rm -f "${TEMP_PLIST}"' EXIT
/bin/cp "${REPO_DIR}/launchd/${LABEL}.plist" "${TEMP_PLIST}"
# PlistBuddy is used for array elements because macOS 26's plutil currently
# inserts, rather than replaces, a final numeric key-path component.
/usr/libexec/PlistBuddy -c "Set :ProgramArguments:0 ${BINARY_PATH}" "${TEMP_PLIST}"
/usr/libexec/PlistBuddy -c "Set :ProgramArguments:2 ${PRODUCT_NAME}" "${TEMP_PLIST}"
/usr/libexec/PlistBuddy -c "Set :ProgramArguments:4 ${GRACE_SECONDS}" "${TEMP_PLIST}"
/usr/libexec/PlistBuddy -c "Set :ProgramArguments:6 ${COOLDOWN_SECONDS}" "${TEMP_PLIST}"
/usr/bin/plutil -replace StandardOutPath -string "${LOG_PATH}" "${TEMP_PLIST}"
/usr/bin/plutil -replace StandardErrorPath -string "${LOG_PATH}" "${TEMP_PLIST}"
/usr/bin/plutil -lint "${TEMP_PLIST}"

# Replace the earlier polling implementation if it is installed.
/bin/launchctl bootout "gui/${USER_ID}/${LABEL}" >/dev/null 2>&1 || true
/bin/cp "${TEMP_PLIST}" "${PLIST_PATH}"
/bin/rm -f "${INSTALL_DIR}/wacom-recover.sh"
/bin/launchctl bootstrap "gui/${USER_ID}" "${PLIST_PATH}"
/bin/launchctl kickstart "gui/${USER_ID}/${LABEL}"

print "Installed ${LABEL}."
print "It now reacts to USB events and does not poll."
print "Log: ${LOG_PATH}"
