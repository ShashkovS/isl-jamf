#!/bin/bash
# OBS installer for Jamf School / macOS Bash 3.2. Deploy the companion MDM profile first.
set -Eeuo pipefail
IFS=$'\n\t'
umask 022

BUILD="obs-jamf-1.1"
ADMIN_USER="admin"
BREW_PREFIX="/opt/homebrew"
BREW="${BREW_PREFIX}/bin/brew"
APP="/Applications/OBS.app"
BUNDLE_ID="com.obsproject.obs-studio"
TEAM_ID="2MMRE5MTB8"
PROFILE_ID="tech.leaders.obs.permissions"
EXTENSION_ID="com.obsproject.obs-studio.mac-camera-extension"
LOG_FILE="/var/log/theisland-install-obs.log"
LOCK_DIR="/private/var/run/theisland-homebrew.lock"
REQUIRE_PROFILE=1

ADMIN_HOME=""
WORK_DIR=""
LOCKED=0
RESTORE_NEEDED=0
CAFFEINATE_PID=""
APP_VERSION="unknown"
PROFILE_STATUS="not checked"
APP_STATUS="not checked"
PERMISSIONS_STATUS="not changed"
CURRENT_STEP="initialization"
COMPLETE=0
START_SECONDS=${SECONDS}

log() {
  local line
  line="$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ') $*"
  # Some Jamf School results expose only one channel. Keep each independently useful.
  builtin printf '%s\n' "${line}" || true
  builtin printf '%s\n' "${line}" >&2 || true
  if [[ -f "${LOG_FILE}" && ! -L "${LOG_FILE}" ]]; then
    builtin printf '%s\n' "${line}" >>"${LOG_FILE}" 2>/dev/null || true
  fi
}

die() {
  log "ERROR: $*"
  exit 1
}

show_tail() {
  local file="$1" line
  [[ -f "${file}" ]] || return 0
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -z "${line}" ]] || log "DETAIL: ${line:0:1000}"
  done < <(/usr/bin/tail -n 25 "${file}" 2>/dev/null)
}

run_step() {
  local label="$1" rc=0 started=${SECONDS}
  shift
  CURRENT_STEP="${label}"
  log "BEGIN: ${label}"
  builtin printf '\n=== %s ===\n' "${label}" >>"${LOG_FILE}"
  "$@" </dev/null >"${WORK_DIR}/step.log" 2>&1 || rc=$?
  /bin/cat "${WORK_DIR}/step.log" >>"${LOG_FILE}" || true
  log "END: ${label}; exit=${rc}; elapsed=$((SECONDS - started))s"
  if [[ ${rc} -ne 0 ]]; then
    local command_line
    builtin printf -v command_line ' %q' "$@"
    log "FAILED COMMAND:${command_line}"
    if [[ -s "${WORK_DIR}/step.log" ]]; then
      show_tail "${WORK_DIR}/step.log"
    else
      log "DETAIL: command returned ${rc} without stdout/stderr"
    fi
  fi
  return "${rc}"
}

brew_admin() {
  /usr/bin/sudo -n -u "${ADMIN_USER}" -H /usr/bin/env -i \
    HOME="${ADMIN_HOME}" USER="${ADMIN_USER}" LOGNAME="${ADMIN_USER}" \
    PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    LC_ALL=en_US.UTF-8 CI=1 NONINTERACTIVE=1 GIT_TERMINAL_PROMPT=0 \
    SUDO_ASKPASS=/usr/bin/false SSH_ASKPASS=/usr/bin/false \
    SSH_ASKPASS_REQUIRE=force GIT_SSH_COMMAND="/usr/bin/ssh -oBatchMode=yes" \
    HOMEBREW_NO_SUDO=1 HOMEBREW_NO_ASK=1 HOMEBREW_NO_ANALYTICS=1 \
    HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_UPDATE_TO_TAG=1 \
    HOMEBREW_NO_ENV_HINTS=1 HOMEBREW_NO_COLOR=1 \
    HOMEBREW_NO_INSTALL_CLEANUP=1 HOMEBREW_NO_AUTOREMOVE=1 \
    HOMEBREW_NO_UPGRADE_QUIT_CASKS=1 \
    HOMEBREW_CASK_OPTS="--appdir=/Applications" \
    "${BREW}" "$@" </dev/null
}

acquire_lock() {
  local pid
  if ! /bin/mkdir "${LOCK_DIR}" 2>/dev/null; then
    [[ -d "${LOCK_DIR}" && ! -L "${LOCK_DIR}" ]] || die "Unsafe Homebrew lock path"
    [[ "$(/usr/bin/stat -f '%u' "${LOCK_DIR}")" == "0" ]] || die "Homebrew lock is not owned by root"
    pid="$(/bin/cat "${LOCK_DIR}/pid" 2>/dev/null || true)"
    if [[ "${pid}" =~ ^[0-9]+$ ]] && (( pid > 1 )) && ! /bin/kill -0 "${pid}" 2>/dev/null; then
      /bin/rm -f "${LOCK_DIR}/pid"
      /bin/rmdir "${LOCK_DIR}" || die "Cannot remove stale Homebrew lock"
      /bin/mkdir "${LOCK_DIR}" || die "Another Homebrew deployment acquired the lock"
    else
      die "Another Homebrew deployment is active (PID ${pid:-unknown}); rerun this script later"
    fi
  fi
  LOCKED=1
  /usr/sbin/chown root:wheel "${LOCK_DIR}"
  /bin/chmod 0700 "${LOCK_DIR}"
  builtin printf '%s\n' "$$" >"${LOCK_DIR}/pid"
}

clear_homebrew_acls() {
  local paths="${WORK_DIR}/acl-paths.bin"
  local errors="${WORK_DIR}/acl-scan.stderr"
  local details="${WORK_DIR}/acl-details.log"
  local path="" count=0 bad=0 rc=0

  CURRENT_STEP="Scan actual Homebrew ACLs"
  log "BEGIN: ${CURRENT_STEP}"
  /usr/bin/find -P "${BREW_PREFIX}" -xdev ! -type l -acl -print0 \
    >"${paths}" 2>"${errors}" || rc=$?
  /bin/cat "${errors}" >>"${LOG_FILE}" || true
  if [[ ${rc} -ne 0 ]]; then
    log "ERROR: cannot enumerate Homebrew ACLs; exit=${rc}"
    show_tail "${errors}"
    return 1
  fi

  # Do not call chmod -N on every file in Cellar; operate only on actual ACLs.
  # NUL-separated paths preserve spaces, quotes and newlines in file names.
  while IFS= read -r -d '' path; do
    count=$((count + 1))
    if [[ -L "${path}" || ! -e "${path}" ]]; then
      log "ERROR: ACL candidate changed during repair: ${path}"
      bad=1
      continue
    fi
    if ! run_step "Remove ACL: ${path}" /bin/chmod -h -N "${path}"; then
      bad=1
      /bin/ls -ldeO "${path}" >"${details}" 2>&1 || true
      /bin/cat "${details}" >>"${LOG_FILE}" || true
      show_tail "${details}"
    fi
  done <"${paths}"

  log "ACL repair: paths with ACL=${count}; failed=${bad}"
  return "${bad}"
}

restore_permissions() {
  local bad=0 services="" services_dir="" state=""
  [[ -d "${BREW_PREFIX}" && ! -L "${BREW_PREFIX}" ]] || {
    log "ERROR: Homebrew prefix is missing or is a symlink"
    return 1
  }
  # All brew calls finish before filesystem permission changes.
  services="$(brew_admin command services 2>>"${LOG_FILE}")" || services=""
  if [[ -z "${services}" && -f "${BREW_PREFIX}/Library/Homebrew/cmd/services.rb" ]]; then
    services="${BREW_PREFIX}/Library/Homebrew/cmd/services.rb"
  fi
  if [[ "${services}" == "${BREW_PREFIX}"/* && -f "${services}" && ! -L "${services}" ]]; then
    services_dir="$(cd -P "${services%/*}" && builtin pwd -P)" || services_dir=""
    services="${services_dir}/${services##*/}"
  fi
  if [[ "${services}" != "${BREW_PREFIX}"/* || ! -f "${services}" || -L "${services}" ]]; then
    log "ERROR: cannot safely locate brew services"
    services=""
    bad=1
  fi

  clear_homebrew_acls || bad=1
  run_step "Restore Homebrew ownership to admin" \
    /usr/bin/find -P "${BREW_PREFIX}" -xdev \
    \( ! -user "${ADMIN_USER}" -o ! -group admin \) \
    -exec /usr/sbin/chown -h "${ADMIN_USER}:admin" {} + || bad=1
  run_step "Remove group/other writes from real Homebrew paths" \
    /usr/bin/find -P "${BREW_PREFIX}" -xdev ! -type l \
    -exec /bin/chmod -h u+rwX,go-w {} + || bad=1
  if [[ -n "${services}" ]]; then
    run_step "Keep brew services admin-only" /bin/chmod -h 0600 "${services}" || bad=1
    state="$(/usr/bin/stat -f '%Su:%Sg:%Lp' "${services}" 2>>"${LOG_FILE}")" || bad=1
    if [[ "${state}" != "${ADMIN_USER}:admin:600" ]]; then
      log "ERROR: unexpected brew services ownership/mode: ${state}"
      bad=1
    fi
  fi
  if ! /usr/bin/find -P "${BREW_PREFIX}" -xdev ! -type l \
      \( ! -user "${ADMIN_USER}" -o ! -group admin -o -perm -0020 -o -perm -0002 -o -acl \) \
      -print -quit >"${WORK_DIR}/permission-audit.log" 2>"${WORK_DIR}/permission-audit.stderr"; then
    log "ERROR: cannot complete Homebrew ownership/mode/ACL audit"
    show_tail "${WORK_DIR}/permission-audit.stderr"
    bad=1
  elif [[ -s "${WORK_DIR}/permission-audit.log" ]]; then
    log "ERROR: Homebrew path still has unexpected ownership, writable mode or an ACL"
    show_tail "${WORK_DIR}/permission-audit.log"
    bad=1
  fi
  if [[ ${bad} -eq 0 ]]; then log "OK: admin-only Homebrew ownership, modes and ACLs verified"; fi
  return "${bad}"
}

cleanup() {
  local rc=$?
  trap - EXIT ERR INT TERM HUP
  set +e
  if [[ ${rc} -ne 0 && -n "${WORK_DIR}" ]]; then
    log "FAILED STEP: ${CURRENT_STEP}"
    show_tail "${WORK_DIR}/step.log"
  fi
  if [[ ${RESTORE_NEEDED} -eq 1 ]]; then
    if restore_permissions; then
      PERMISSIONS_STATUS="ok"
    else
      PERMISSIONS_STATUS="FAILED"
      log "ERROR: could not fully restore Homebrew permissions"
      rc=1
    fi
  fi
  if [[ ${LOCKED} -eq 1 ]]; then
    /bin/rm -f "${LOCK_DIR}/pid"
    /bin/rmdir "${LOCK_DIR}" 2>>"${LOG_FILE}" || true
  fi
  if [[ -n "${CAFFEINATE_PID}" ]]; then
    /bin/kill "${CAFFEINATE_PID}" 2>/dev/null || true
    wait "${CAFFEINATE_PID}" 2>/dev/null || true
  fi
  if [[ ${rc} -eq 0 && ${COMPLETE} -ne 1 ]]; then
    log "ERROR: script ended before final verification"
    rc=1
  fi
  log "SUMMARY: OBS=${APP_STATUS}; version=${APP_VERSION}; MDM profile=${PROFILE_STATUS}; Homebrew permissions=${PERMISSIONS_STATUS}"
  log "USER CONSENT: camera, microphone and screen capture were NOT silently granted or tested"
  log "FINISH: exit=${rc}; elapsed=$((SECONDS - START_SECONDS))s; full log=${LOG_FILE}"
  [[ -z "${WORK_DIR}" ]] || /bin/rm -rf "${WORK_DIR}"
  exit "${rc}"
}

[[ ${EUID} -eq 0 ]] || { builtin printf 'ERROR: Jamf must run this script as root\n' >&2; exit 1; }
[[ ! -L "${LOG_FILE}" && ( ! -e "${LOG_FILE}" || -f "${LOG_FILE}" ) ]] || die "Unsafe log path"
/usr/bin/touch "${LOG_FILE}"
/usr/sbin/chown root:wheel "${LOG_FILE}"
/bin/chmod 0640 "${LOG_FILE}"
WORK_DIR="$(/usr/bin/mktemp -d "/private/var/tmp/theisland-obs.XXXXXX")"
/bin/chmod 0700 "${WORK_DIR}"
trap cleanup EXIT
trap 'die "Command failed at line ${LINENO}, status $?, during ${CURRENT_STEP}"' ERR
trap 'log "ERROR: received SIGTERM"; exit 143' TERM
trap 'log "ERROR: received SIGINT"; exit 130' INT
trap 'log "ERROR: received SIGHUP"; exit 129' HUP

log "START: ${BUILD}; install OBS and verify deployment prerequisites"
[[ "$(/usr/bin/uname -s)" == "Darwin" && "$(/usr/bin/uname -m)" == "arm64" ]] || die "This script targets Apple Silicon macOS"
log "macOS: $(/usr/bin/sw_vers -productVersion)"
/usr/bin/id "${ADMIN_USER}" >/dev/null 2>&1 || die "Local account admin is missing"
ADMIN_HOME="$(/usr/bin/dscl . -read "/Users/${ADMIN_USER}" NFSHomeDirectory | /usr/bin/sed 's/^NFSHomeDirectory: *//')"
[[ -d "${ADMIN_HOME}" && -x "${BREW}" && ! -L "${BREW_PREFIX}" ]] || die "Admin home or Homebrew is missing/invalid"
[[ "$(/usr/bin/stat -f '%Su' "${BREW_PREFIX}")" == "${ADMIN_USER}" ]] || die "Homebrew is not owned by admin; do not use this student installer on teacher-owned Homebrew"
[[ ! -L "${APP}" ]] || die "${APP} is a symlink; refusing to replace it"

acquire_lock
RESTORE_NEEDED=1
/usr/bin/caffeinate -i -w "$$" </dev/null >/dev/null 2>&1 &
CAFFEINATE_PID=$!
cd "${ADMIN_HOME}"

if [[ -e "${APP}" ]]; then
  log "OBS already exists; skipping installation and checking its signature/version"
else
  run_step "Refresh Homebrew metadata" brew_admin update || die "brew update failed"
  if brew_admin list --cask --versions obs >"${WORK_DIR}/obs-receipt.log" 2>&1; then
    run_step "Repair missing OBS.app from its Homebrew cask" \
      brew_admin reinstall --cask --no-ask --appdir=/Applications obs || die "Cannot reinstall OBS"
  else
    run_step "Install OBS to /Applications as admin" \
      brew_admin install --cask --no-ask --appdir=/Applications obs || die "Cannot install OBS"
  fi
fi

CURRENT_STEP="verify OBS"
[[ -f "${APP}/Contents/Info.plist" && -x "${APP}/Contents/MacOS/OBS" ]] || die "OBS app bundle is incomplete"
installed_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${APP}/Contents/Info.plist")"
[[ "${installed_id}" == "${BUNDLE_ID}" ]] || die "Unexpected OBS bundle ID: ${installed_id}"
APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${APP}/Contents/Info.plist")"
APP_STATUS="present; verification in progress"
log "APP PRESENT: ${APP}; version=${APP_VERSION}; bundle=${installed_id}"
run_step "Verify OBS code signature" /usr/bin/codesign --verify --deep --strict --verbose=2 "${APP}" || die "OBS signature verification failed"
/usr/bin/codesign --display --verbose=4 "${APP}" >"${WORK_DIR}/signature.log" 2>&1 || die "Cannot inspect OBS signature"
/bin/cat "${WORK_DIR}/signature.log" >>"${LOG_FILE}"
/usr/bin/grep -Fqx "TeamIdentifier=${TEAM_ID}" "${WORK_DIR}/signature.log" || die "OBS is not signed by the expected team ${TEAM_ID}"
APP_STATUS="present; code signature and team verified"
# The leading '=' makes the next argument requirement text rather than a filename.
run_step "Verify that OBS matches the MDM code requirement" \
  /usr/bin/codesign --verify --verbose=2 --test-requirement \
  "=identifier \"${BUNDLE_ID}\" and anchor apple generic and certificate leaf[subject.OU] = \"${TEAM_ID}\"" \
  "${APP}" || die "OBS requirement verification failed; see the codesign output above"
run_step "Verify OBS Gatekeeper assessment" /usr/sbin/spctl --assess --type execute --verbose=2 "${APP}" || die "Gatekeeper did not accept OBS"
APP_STATUS="installed and signature verified"
log "APP: ${APP}; version=${APP_VERSION}; bundle=${BUNDLE_ID}; team=${TEAM_ID}"

CURRENT_STEP="check access for personal accounts"
/usr/bin/dscl . -list /Users UniqueID >"${WORK_DIR}/users.txt"
users_checked=0
while IFS=$' \t' read -r user uid; do
  case "${user}" in admin|root|Guest|Shared|_*|'') continue ;; esac
  [[ "${uid}" =~ ^[0-9]+$ ]] || continue
  (( uid >= 501 )) || continue
  /usr/bin/sudo -n -u "${user}" -H /bin/test -r "${APP}/Contents/Info.plist" || die "${user} cannot read OBS"
  /usr/bin/sudo -n -u "${user}" -H /bin/test -x "${APP}/Contents/MacOS/OBS" || die "${user} cannot execute OBS"
  log "ACCOUNT: ${user}: OBS files accessible; GUI launch and privacy consent not tested"
  users_checked=$((users_checked + 1))
done <"${WORK_DIR}/users.txt"
[[ ${users_checked} -gt 0 ]] || log "WARNING: no personal local accounts found; installed for future users"

CURRENT_STEP="check MDM profile"
if /usr/bin/profiles list -type configuration >"${WORK_DIR}/profiles.txt" 2>"${WORK_DIR}/profiles.stderr"; then
  if /usr/bin/grep -Eq "profileIdentifier:[[:space:]]*tech\\.leaders\\.obs\\.permissions[[:space:]]*$" "${WORK_DIR}/profiles.txt"; then
    PROFILE_STATUS="present (not a test of effective TCC consent)"
    log "PROFILE: ${PROFILE_ID} is installed"
  else
    PROFILE_STATUS="MISSING"
    log "ACTION REQUIRED: install OBS-Permissions.mobileconfig through Jamf Profiles; identifier=${PROFILE_ID}"
  fi
else
  PROFILE_STATUS="UNKNOWN"
  show_tail "${WORK_DIR}/profiles.stderr"
  log "ERROR: cannot list installed configuration profiles"
fi

CURRENT_STEP="report virtual-camera state"
if /usr/bin/systemextensionsctl list >"${WORK_DIR}/extensions.txt" 2>"${WORK_DIR}/extensions.stderr"; then
  if /usr/bin/grep -F "${EXTENSION_ID}" "${WORK_DIR}/extensions.txt" >"${WORK_DIR}/obs-extension.txt"; then
    show_tail "${WORK_DIR}/obs-extension.txt"
  else
    log "VIRTUAL CAMERA: not registered yet; OBS may activate it on first launch. Ordinary recording does not require it"
  fi
else
  show_tail "${WORK_DIR}/extensions.stderr"
  log "WARNING: virtual-camera state could not be read"
fi

if [[ ${REQUIRE_PROFILE} -eq 1 && ( "${PROFILE_STATUS}" == "MISSING" || "${PROFILE_STATUS}" == "UNKNOWN" ) ]]; then
  die "OBS is installed, but its required MDM permissions profile is missing/unverified; deploy the profile and rerun"
fi
log "USER ACTION: open OBS > Review App Permissions; allow Camera/Microphone; enable Screen Recording and optional Input Monitoring"
log "MDM CHECK: allow ${BUNDLE_ID} in any existing app safelist; remove conflicting camera/screen-capture denies for this cohort"
log "DONE: OBS deployment checks completed; no app was launched and no recording was started"
COMPLETE=1


