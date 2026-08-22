#!/bin/zsh
set -euo pipefail

readonly USER_HOME="${HOME:?HOME is not set}"
readonly USER_ID="$(/usr/bin/id -u)"
readonly LABEL="com.local.wacom-recovery"
readonly INSTALL_DIR="${USER_HOME}/Library/Application Support/WacomRecovery"
readonly PLIST_PATH="${USER_HOME}/Library/LaunchAgents/${LABEL}.plist"
readonly LOG_PATH="${USER_HOME}/Library/Logs/WacomRecovery.log"
readonly CACHE_DIR="${USER_HOME}/Library/Caches/WacomRecovery"

/bin/launchctl bootout "gui/${USER_ID}/${LABEL}" >/dev/null 2>&1 || true
/bin/rm -f "${PLIST_PATH}" "${INSTALL_DIR}/wacom-recovery" "${INSTALL_DIR}/wacom-recover.sh"
/bin/rmdir "${INSTALL_DIR}" >/dev/null 2>&1 || true

if [[ "${1:-}" == "--purge" ]]; then
    /bin/rm -f "${LOG_PATH}" "${CACHE_DIR}/first_seen" "${CACHE_DIR}/last_restart"
    /bin/rmdir "${CACHE_DIR}" >/dev/null 2>&1 || true
fi

print "Uninstalled ${LABEL}."
