#!/bin/bash
# Jamf School: update an admin-owned Homebrew installation on student Macs.
# v6: bounded commands, guaranteed cleanup, failing exit codes, disk cleanup,
# exam guard and a weekly forced update of running apps.
set -Eeuo pipefail
IFS=$'\n\t'
umask 022
# A closed Jamf output pipe must not kill the script before cleanup.
trap '' PIPE

ADMIN_USER="admin"
ADMIN_HOME="/Users/${ADMIN_USER}"
BREW_PREFIX="/opt/homebrew"
BREW="${BREW_PREFIX}/bin/brew"
# Prefer the system jq: a broken Homebrew jq must not stop the updater itself.
JQ="/usr/bin/jq"
[[ -x "${JQ}" ]] || JQ="${BREW_PREFIX}/bin/jq"
LOG_FILE="/var/log/theisland-homebrew-update.log"
LOCK_DIR="/private/var/run/theisland-homebrew.lock"
EXAM_STATE_FILE="/var/db/exam_netlock_state"

SKIP_RUNNING_APPS=1
# Weekly forced update of running apps. Day as in `date +%u`: 1=Mon, 5=Fri, 0=off.
# Local hours are [start, end); narrow them to avoid closing apps during lessons.
FORCE_QUIT_WEEKDAY=5
FORCE_QUIT_START_HOUR=0
FORCE_QUIT_END_HOUR=24
FORCE_QUIT_GRACE_SECONDS=10

EXAM_MARGIN_SECONDS=3600
JITTER_MAX_SECONDS=900
MIN_FREE_GB=10
CLEANUP_PRUNE_DAYS=30
# Student virtual environments can point at a specific Python keg in the Cellar.
KEEP_FORMULAE="python@3.14,python-tk@3.14"

TIMEOUT_UPDATE=1200
TIMEOUT_UPGRADE=2400
TIMEOUT_QUERY=120
TIMEOUT_CLEANUP=900
TIMEOUT_PERMISSIONS=600
LOCK_PID_GRACE_SECONDS=300
LOCK_MAX_AGE_SECONDS=21600

# Run a command in its own process group with a deadline. Exit 124 on timeout.
# TERM, then KILL for the whole group, so curl and git children cannot survive.
WATCHDOG='
use POSIX ":sys_wait_h";
my ($limit, @cmd) = @ARGV;
my $pid = fork() // exit 125;
if (!$pid) {
  setpgrp(0, 0);
  $SIG{$_} = "DEFAULT" for qw(TERM INT HUP PIPE);
  exec { $cmd[0] } @cmd;
  exit 127;
}
setpgrp($pid, $pid);
my $stop = sub {
  my $rc = shift;
  $SIG{$_} = "IGNORE" for qw(ALRM TERM INT HUP);
  kill "TERM", -$pid;
  for (1 .. 15) {
    waitpid($pid, WNOHANG);
    last unless kill 0, -$pid;
    sleep 1;
  }
  kill "KILL", -$pid;
  exit $rc;
};
$SIG{ALRM} = sub { $stop->(124) };
$SIG{$_} = sub { $stop->(143) } for qw(TERM INT HUP);
alarm $limit;
waitpid($pid, 0);
alarm 0;
exit(($? & 127) ? 128 + ($? & 127) : $? >> 8);
'

WORK_DIR=""
RESULT_FILE=""
LOCKED=0
RESTORE_PERMISSIONS=0
PERMISSIONS_STATUS="not checked"
CAFFEINATE_PID=""
OK=0
SKIPPED=0
FAILED=0
APP_MANAGEMENT_STATUS="not reported missing"
CURRENT_OPERATION="initialization"
ACTIVE_OUTPUT=""
ACTIVE_PID=""
RELAUNCH_APPS=""
RELAUNCH_USER=""
RELAUNCH_UID=""
START_SECONDS=${SECONDS}

[[ ${EUID} -eq 0 ]] || { echo "ERROR: run through Jamf as root" >&2; exit 1; }
[[ ! -L "${LOG_FILE}" ]] || { echo "ERROR: log path is a symlink" >&2; exit 1; }
[[ ! -e "${LOG_FILE}" || -f "${LOG_FILE}" ]] || { echo "ERROR: log path is not a file" >&2; exit 1; }
if [[ -f "${LOG_FILE}" ]] && (( $(/usr/bin/stat -f '%z' "${LOG_FILE}") > 10485760 )); then
  /bin/mv -f "${LOG_FILE}" "${LOG_FILE}.1"
fi
/usr/bin/touch "${LOG_FILE}"
/usr/sbin/chown root:wheel "${LOG_FILE}"
/bin/chmod 0640 "${LOG_FILE}"
WORK_DIR="$(/usr/bin/mktemp -d /private/var/tmp/theisland-brew-update.XXXXXX)"
/bin/chmod 0700 "${WORK_DIR}"
RESULT_FILE="${WORK_DIR}/result.log"

# File first: the persistent log survives even if Jamf stops reading stdout.
# External printf only: after a failed write the Bash 3.2 builtin keeps its
# buffer, and the next $(...) captures that text instead of its own output.
log() {
  local line
  line="$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ') $*"
  /usr/bin/printf '%s\n' "${line}" >>"${LOG_FILE}" 2>/dev/null || true
  /usr/bin/printf '%s\n' "${line}" >>"${RESULT_FILE}" 2>/dev/null || true
  /usr/bin/printf '%s\n' "${line}" 2>/dev/null || true
}

fail() {
  log "ERROR: $*"
  exit 1
}

# This outer sudo changes root into admin. Homebrew itself cannot use sudo.
AS_ADMIN=(
  /usr/bin/sudo -n -u "${ADMIN_USER}" -H /usr/bin/env -i
  "HOME=${ADMIN_HOME}" "USER=${ADMIN_USER}" "LOGNAME=${ADMIN_USER}"
  "PATH=/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  LC_ALL=en_US.UTF-8 CI=1 NONINTERACTIVE=1 GIT_TERMINAL_PROMPT=0
  SUDO_ASKPASS=/usr/bin/false SSH_ASKPASS=/usr/bin/false
  SSH_ASKPASS_REQUIRE=force "GIT_SSH_COMMAND=/usr/bin/ssh -oBatchMode=yes"
  HOMEBREW_NO_SUDO=1 HOMEBREW_NO_ASK=1 HOMEBREW_NO_ANALYTICS=1
  HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_UPDATE_TO_TAG=1
  HOMEBREW_NO_ENV_HINTS=1 HOMEBREW_NO_COLOR=1
  HOMEBREW_NO_INSTALL_CLEANUP=1 HOMEBREW_NO_AUTOREMOVE=1
  "HOMEBREW_NO_CLEANUP_FORMULAE=${KEEP_FORMULAE}"
  HOMEBREW_NO_UPGRADE_QUIT_CASKS=1
  HOMEBREW_NO_APP_MANAGEMENT_PERMISSIONS_PROMPT=1
)

as_admin() {
  "${AS_ADMIN[@]}" "$@"
}

# Run in the background: `wait` returns to a signal trap at once, while a
# foreground child would delay the trap until the child exits.
wait_active() {
  local rc=0
  ACTIVE_PID=$!
  wait "${ACTIVE_PID}" || rc=$?
  ACTIVE_PID=""
  return "${rc}"
}

stop_active_command() {
  local attempt
  [[ -n "${ACTIVE_PID}" ]] || return 0
  /bin/kill -TERM "${ACTIVE_PID}" 2>/dev/null
  for ((attempt = 0; attempt < 20; attempt++)); do
    /bin/kill -0 "${ACTIVE_PID}" 2>/dev/null || break
    /bin/sleep 1
  done
  /bin/kill -KILL "${ACTIVE_PID}" 2>/dev/null
  wait "${ACTIVE_PID}" 2>/dev/null
  ACTIVE_PID=""
}

# Keep stdout separate: some commands return JSON. Full output stays on disk.
capture_brew() {
  local limit="$1" output="$2" rc=0 command_line started
  shift 2
  builtin printf -v command_line ' %q' "$@"
  CURRENT_OPERATION="brew${command_line}"
  ACTIVE_OUTPUT="${output}"
  started=${SECONDS}
  log "BEGIN: ${CURRENT_OPERATION}"
  log "Command output while running: ${output} and ${output}.stderr"

  "${AS_ADMIN[@]}" /usr/bin/perl -e "${WATCHDOG}" "${limit}" "${BREW}" "$@" \
    </dev/null >"${output}" 2>"${output}.stderr" &
  wait_active || rc=$?
  {
    /usr/bin/printf '\n=== %s | exit %s | %ss ===\n' \
      "${CURRENT_OPERATION}" "${rc}" "$((SECONDS - started))"
    # Cask metadata is large and changes nothing; keep the log readable.
    if [[ "$1" != "info" ]]; then /bin/cat "${output}"; fi
    /bin/cat "${output}.stderr"
  } >>"${LOG_FILE}" || true
  ACTIVE_OUTPUT=""
  log "END: ${CURRENT_OPERATION}; exit=${rc}; elapsed=$((SECONDS - started))s"
  [[ ${rc} -ne 124 ]] || log "ERROR: timed out after ${limit}s: ${CURRENT_OPERATION}"
  CURRENT_OPERATION="between Homebrew commands"
  return "${rc}"
}

json() {
  as_admin "${JQ}" "$@"
}

failure_detail() {
  local output="$1" file line
  for file in "${output}" "${output}.stderr"; do
    [[ -f "${file}" ]] || continue
    while IFS= read -r line || [[ -n "${line}" ]]; do
      [[ -z "${line}" ]] || log "DETAIL: ${line:0:300}"
    done < <(/usr/bin/tail -n 4 "${file}" 2>/dev/null || true)
  done
}

permission_step() {
  local label="$1" output="${WORK_DIR}/permissions.log" rc=0 started command_line file line
  shift
  builtin printf -v command_line ' %q' "$@"
  CURRENT_OPERATION="permissions: ${label}"
  ACTIVE_OUTPUT="${output}"
  started=${SECONDS}
  log "BEGIN: ${CURRENT_OPERATION}"

  /usr/bin/perl -e "${WATCHDOG}" "${TIMEOUT_PERMISSIONS}" "$@" \
    </dev/null >"${output}" 2>"${output}.stderr" || rc=$?
  {
    /usr/bin/printf '\n=== %s | command:%s | exit %s ===\n' \
      "${CURRENT_OPERATION}" "${command_line}" "${rc}"
    /bin/cat "${output}" "${output}.stderr"
  } >>"${LOG_FILE}" || true
  ACTIVE_OUTPUT=""
  log "END: ${CURRENT_OPERATION}; exit=${rc}; elapsed=$((SECONDS - started))s"

  if [[ ${rc} -ne 0 ]]; then
    log "ERROR: ${label}; command:${command_line}"
    for file in "${output}" "${output}.stderr"; do
      while IFS= read -r line || [[ -n "${line}" ]]; do
        [[ -z "${line}" ]] || log "DETAIL: ${line:0:1200}"
      done < <(/usr/bin/tail -n 12 "${file}" 2>/dev/null || true)
    done
  fi
  return "${rc}"
}

restore_permissions() {
  local services="" services_dir="" writable="" service_state="" bad=0
  local query="${WORK_DIR}/permissions-services.log"
  local audit="${WORK_DIR}/permissions-audit.log"
  log "Restoring admin-only Homebrew writes"

  if [[ ! -d "${BREW_PREFIX}" || -L "${BREW_PREFIX}" ]]; then
    log "ERROR: Homebrew prefix is missing or is a symlink; refusing permission changes"
    return 1
  fi

  # Resolve the command before changing permissions; no brew calls below this block.
  if capture_brew "${TIMEOUT_QUERY}" "${query}" command services; then
    services="$(/bin/cat "${query}")"
  else
    failure_detail "${query}"
  fi
  if [[ -z "${services}" && -f "${BREW_PREFIX}/Library/Homebrew/cmd/services.rb" ]]; then
    services="${BREW_PREFIX}/Library/Homebrew/cmd/services.rb"
  fi
  if [[ "${services}" == "${BREW_PREFIX}"/* && -f "${services}" && ! -L "${services}" ]]; then
    services_dir="$(cd -P "${services%/*}" && builtin pwd -P)" || services_dir=""
    if [[ -n "${services_dir}" ]]; then
      services="${services_dir}/${services##*/}"
    else
      services=""
    fi
  else
    services=""
  fi
  if [[ "${services}" != "${BREW_PREFIX}"/* ]]; then
    log "ERROR: cannot locate brew services safely inside ${BREW_PREFIX}"
    services=""
    bad=1
  fi

  # Walk physically. Never clear ACLs or change modes through symlinks.
  permission_step "Remove ACLs from real Homebrew paths" \
    /usr/bin/find -P "${BREW_PREFIX}" -xdev ! -type l \
    -exec /bin/chmod -h -N {} + || bad=1

  # -h changes a symlink's owner, never the owner of its target.
  permission_step "Set Homebrew ownership to ${ADMIN_USER}" \
    /usr/bin/find -P "${BREW_PREFIX}" -xdev \
    -exec /usr/sbin/chown -h "${ADMIN_USER}:admin" {} + || bad=1

  permission_step "Remove group/other writes from real Homebrew paths" \
    /usr/bin/find -P "${BREW_PREFIX}" -xdev ! -type l \
    -exec /bin/chmod -h u+rwX,go-w {} + || bad=1

  if [[ -n "${services}" ]]; then
    permission_step "Restrict brew services to ${ADMIN_USER}" \
      /bin/chmod -h 0600 "${services}" || bad=1
    if service_state="$(/usr/bin/stat -f '%Su:%Sg:%Lp' "${services}" 2>"${audit}.stderr")"; then
      if [[ "${service_state}" != "${ADMIN_USER}:admin:600" ]]; then
        log "ERROR: unexpected brew services owner/mode: ${service_state}; path: ${services}"
        bad=1
      fi
    else
      log "ERROR: cannot verify brew services owner/mode"
      failure_detail "${audit}"
      bad=1
    fi
  fi

  CURRENT_OPERATION="permissions: verify Homebrew tree"
  log "BEGIN: ${CURRENT_OPERATION}"
  # Symlink modes do not grant write access to their targets.
  if ! /usr/bin/perl -e "${WATCHDOG}" "${TIMEOUT_PERMISSIONS}" \
      /usr/bin/find -P "${BREW_PREFIX}" -xdev ! -type l \
      \( ! -user "${ADMIN_USER}" -o ! -group admin -o -perm -0020 -o -perm -0002 \) \
      -print -quit </dev/null >"${audit}" 2>"${audit}.stderr"; then
    log "ERROR: cannot traverse Homebrew to verify ownership and permissions"
    failure_detail "${audit}"
    bad=1
  elif [[ -s "${audit}" ]]; then
    writable="$(/bin/cat "${audit}")"
    log "ERROR: Homebrew path has unexpected ownership or group/other write access: ${writable}"
    /bin/ls -ldeO "${writable}" >"${audit}.details" 2>&1 || true
    /bin/cat "${audit}.details" >>"${LOG_FILE}" || true
    failure_detail "${audit}.details"
    bad=1
  fi

  if [[ ${bad} -eq 0 ]]; then
    log "OK: Homebrew restrictions restored; ownership and modes verified"
    CURRENT_OPERATION="permissions verified"
  else
    log "ERROR: Homebrew permission checks failed; see the named step and DETAIL above"
  fi
  return "${bad}"
}

cleanup() {
  local rc=$?
  trap - EXIT ERR
  # Repairs below must finish even if the signal is repeated.
  trap '' INT TERM HUP
  set +e
  stop_active_command
  if [[ ${rc} -ne 0 ]]; then
    log "Interrupted/failed operation: ${CURRENT_OPERATION}"
    if [[ -n "${ACTIVE_OUTPUT}" ]]; then
      failure_detail "${ACTIVE_OUTPUT}"
      /bin/cat "${ACTIVE_OUTPUT}" "${ACTIVE_OUTPUT}.stderr" >>"${LOG_FILE}" 2>/dev/null || true
    fi
  fi
  if [[ ${RESTORE_PERMISSIONS} -eq 1 ]]; then
    if restore_permissions; then
      PERMISSIONS_STATUS="ok"
    else
      PERMISSIONS_STATUS="failed"
      log "ERROR: could not fully restore Homebrew restrictions"
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
  log "SUMMARY: successful upgrade commands=${OK}; skipped=${SKIPPED}; package warnings/errors=${FAILED}; permissions=${PERMISSIONS_STATUS}; app management=${APP_MANAGEMENT_STATUS}"
  log "FINISH: exit code ${rc}; elapsed=$((SECONDS - START_SECONDS))s; full log: ${LOG_FILE}"
  if [[ ${rc} -ne 0 ]]; then
    /usr/bin/tail -n 60 "${RESULT_FILE}" >&2
  fi
  /bin/rm -rf "${WORK_DIR}"
  exit "${rc}"
}
trap cleanup EXIT
trap 'fail "Unexpected failure at line ${LINENO} (exit $?)"' ERR
trap 'fail "Received SIGINT during ${CURRENT_OPERATION}"' INT
trap 'fail "Received SIGTERM during ${CURRENT_OPERATION}"' TERM
trap 'fail "Received SIGHUP during ${CURRENT_OPERATION}"' HUP

remove_stale_lock() {
  /bin/rm -f "${LOCK_DIR}/pid"
  /bin/rmdir "${LOCK_DIR}" || fail "Cannot remove stale lock"
  /bin/mkdir "${LOCK_DIR}" || fail "Another deployment acquired the lock"
}

acquire_lock() {
  local pid="" age
  if ! /bin/mkdir "${LOCK_DIR}" 2>/dev/null; then
    [[ -d "${LOCK_DIR}" && ! -L "${LOCK_DIR}" ]] || fail "Unsafe lock directory"
    [[ "$(/usr/bin/stat -f '%u' "${LOCK_DIR}")" == "0" ]] || fail "Lock is not owned by root"
    pid="$(/bin/cat "${LOCK_DIR}/pid" 2>/dev/null || true)"
    age=$(($(/bin/date '+%s') - $(/usr/bin/stat -f '%m' "${LOCK_DIR}")))
    if [[ "${pid}" =~ ^[0-9]+$ ]]; then
      if /bin/kill -0 "${pid}" 2>/dev/null; then
        [[ ${age} -lt ${LOCK_MAX_AGE_SECONDS} ]] ||
          fail "Lock held by PID ${pid} for ${age}s; the deployment looks hung"
        log "SKIP: another Homebrew deployment is running (PID ${pid}); retry at the next scheduled run"
        exit 0
      fi
      log "Removing stale lock of dead PID ${pid}"
      remove_stale_lock
    elif [[ ${age} -lt ${LOCK_PID_GRACE_SECONDS} ]]; then
      # A new lock holder writes its PID right after mkdir.
      log "SKIP: another Homebrew deployment is starting; retry at the next scheduled run"
      exit 0
    else
      log "Removing lock without a valid PID; age ${age}s"
      remove_stale_lock
    fi
  fi
  LOCKED=1
  /usr/sbin/chown root:wheel "${LOCK_DIR}"
  /bin/chmod 0700 "${LOCK_DIR}"
  /usr/bin/printf '%s\n' "$$" >"${LOCK_DIR}/pid"
}

upgrade_one() {
  local kind="$1" name="$2" rc=0 output="${WORK_DIR}/upgrade.log"
  log "UPGRADE: ${kind} ${name}"
  if [[ "${kind}" == "formula" ]]; then
    capture_brew "${TIMEOUT_UPGRADE}" "${output}" upgrade --formula --no-ask "${name}" || rc=$?
  else
    capture_brew "${TIMEOUT_UPGRADE}" "${output}" upgrade --cask --greedy --no-ask --no-quit \
      --appdir=/Applications "${name}" || rc=$?
    if /usr/bin/grep -Fq 'does not have App Management' "${output}" "${output}.stderr" 2>/dev/null; then
      APP_MANAGEMENT_STATUS="missing"
      log "WARN: cask ${name}: no App Management permission; Homebrew deleted and reinstalled the app"
    fi
  fi
  if [[ ${rc} -eq 0 ]]; then
    OK=$((OK + 1))
    log "OK: ${kind} ${name}"
  else
    FAILED=$((FAILED + 1))
    log "WARN: ${kind} ${name}: exit ${rc}; continuing with other packages"
    failure_detail "${output}"
  fi
}

# Output: "PID<tab>UID" per process. The snapshot goes to a file first, so that
# this search can never match its own command line.
running_app_processes() {
  local processes="${WORK_DIR}/processes.txt"
  /bin/ps -axww -o pid=,uid=,command= >"${processes}" || return 1
  APP_PATH="$1/Contents/" /usr/bin/awk '
    {
      pid = $1; uid = $2; command = $0
      sub(/^[[:space:]]*[0-9]+[[:space:]]+[0-9]+[[:space:]]+/, "", command)
      if (index(command, ENVIRON["APP_PATH"]) > 0) print pid "\t" uid
    }' "${processes}"
}

force_quit_allowed() {
  local weekday hour
  [[ ${FORCE_QUIT_WEEKDAY} -ne 0 ]] || return 1
  weekday="$(/bin/date '+%u')"
  hour="$(/bin/date '+%H')"
  hour=$((10#${hour}))
  [[ ${weekday} -eq ${FORCE_QUIT_WEEKDAY} &&
    ${hour} -ge ${FORCE_QUIT_START_HOUR} && ${hour} -lt ${FORCE_QUIT_END_HOUR} ]]
}

# Returns 0 only when no process of the app is left.
force_quit_app() {
  local app="$1" processes="" remaining="" pid uid console console_uid="" attempt relaunch=0
  console="$(/usr/bin/stat -f '%Su' /dev/console 2>/dev/null || true)"
  case "${console}" in
    ""|root|loginwindow) ;;
    *) console_uid="$(/usr/bin/id -u "${console}" 2>/dev/null || true)" ;;
  esac

  processes="$(running_app_processes "${app}")" || return 1
  while IFS=$'\t' read -r pid uid; do
    [[ "${pid}" =~ ^[0-9]+$ ]] || continue
    if [[ -n "${console_uid}" && "${uid}" == "${console_uid}" ]]; then relaunch=1; fi
    log "QUIT: ${app}: PID ${pid} (UID ${uid})"
    /bin/kill -TERM "${pid}" 2>/dev/null || true
  done <<<"${processes}"
  if [[ ${relaunch} -eq 1 ]]; then
    RELAUNCH_APPS="${RELAUNCH_APPS}${app}"$'\n'
    RELAUNCH_USER="${console}"
    RELAUNCH_UID="${console_uid}"
  fi

  for ((attempt = 0; attempt < FORCE_QUIT_GRACE_SECONDS; attempt++)); do
    remaining="$(running_app_processes "${app}")" || return 1
    [[ -n "${remaining}" ]] || return 0
    /bin/sleep 1
  done

  log "QUIT: ${app} did not stop after SIGTERM; sending SIGKILL"
  while IFS=$'\t' read -r pid uid; do
    [[ "${pid}" =~ ^[0-9]+$ ]] || continue
    /bin/kill -KILL "${pid}" 2>/dev/null || true
  done <<<"${remaining}"
  /bin/sleep 2
  remaining="$(running_app_processes "${app}")" || return 1
  [[ -z "${remaining}" ]]
}

relaunch_apps() {
  local app active
  [[ -n "${RELAUNCH_APPS}" ]] || return 0
  active="$(/usr/bin/stat -f '%Su' /dev/console 2>/dev/null || true)"
  while IFS= read -r app; do
    [[ -n "${app}" ]] || continue
    if [[ "${active}" != "${RELAUNCH_USER}" ]]; then
      log "RESTART: skipped ${app}; ${RELAUNCH_USER} is no longer at the console"
    elif [[ ! -d "${app}" ]]; then
      log "WARN: cannot relaunch ${app}: application is missing"
    elif ! /usr/bin/perl -e "${WATCHDOG}" "${TIMEOUT_QUERY}" /usr/bin/codesign --verify "${app}" \
        </dev/null >>"${LOG_FILE}" 2>&1; then
      log "WARN: refusing to relaunch ${app}: invalid code signature"
    elif /usr/bin/perl -e "${WATCHDOG}" "${TIMEOUT_QUERY}" \
        /bin/launchctl asuser "${RELAUNCH_UID}" \
        /usr/bin/sudo -n -u "${RELAUNCH_USER}" -H /usr/bin/open -a "${app}" \
        </dev/null >>"${LOG_FILE}" 2>&1; then
      log "RESTART: launched ${app} for ${RELAUNCH_USER}"
    else
      log "WARN: could not relaunch ${app}; the student can open it manually"
    fi
  done <<<"${RELAUNCH_APPS}"
  RELAUNCH_APPS=""
}

cask_can_update() {
  local name="$1" info="${WORK_DIR}/cask.json" fetched="${WORK_DIR}/fetch.log"
  local reason apps app processes prefetched=0
  if ! capture_brew "${TIMEOUT_QUERY}" "${info}" info --json=v2 --cask "${name}"; then
    log "WARN: cannot read metadata for cask ${name}"
    FAILED=$((FAILED + 1))
    return 1
  fi
  if ! reason="$(json -er '
    if (.casks | length) != 1 then error("expected one cask") else
      .casks[0] |
      if .disabled then "disabled by Homebrew"
      elif .pinned then "pinned"
      elif any(.artifacts[]?; has("pkg") or has("installer"))
      then "pkg/custom installer: excluded from unattended upgrades"
      else "ok" end
    end' <"${info}")"; then
    log "WARN: unsupported metadata for cask ${name}"
    FAILED=$((FAILED + 1))
    return 1
  fi
  if [[ "${reason}" != "ok" ]]; then
    log "SKIP: cask ${name}: ${reason}"
    SKIPPED=$((SKIPPED + 1))
    return 1
  fi
  if [[ ${SKIP_RUNNING_APPS} -eq 1 ]]; then
    if ! apps="$(json -r '.casks[0].artifacts[]? | select(has("app")) |
        (.target // ("/Applications/" + (.app[0] | split("/") | last)))' <"${info}")"; then
      log "WARN: cannot read application paths for ${name}; deferring"
      FAILED=$((FAILED + 1))
      return 1
    fi
    while IFS= read -r app; do
      [[ -z "${app}" ]] && continue
      if ! processes="$(running_app_processes "${app}")"; then
        log "WARN: cannot check running apps for ${name}; deferring"
        FAILED=$((FAILED + 1))
        return 1
      fi
      [[ -n "${processes}" ]] || continue
      if ! force_quit_allowed; then
        log "SKIP: cask ${name}: ${app} is running"
        SKIPPED=$((SKIPPED + 1))
        return 1
      fi
      # Download first: never close an app for an update that cannot arrive.
      if [[ ${prefetched} -eq 0 ]]; then
        if ! capture_brew "${TIMEOUT_UPGRADE}" "${fetched}" fetch --cask "${name}"; then
          log "WARN: cannot download cask ${name}; ${app} stays open"
          failure_detail "${fetched}"
          FAILED=$((FAILED + 1))
          return 1
        fi
        prefetched=1
      fi
      if ! force_quit_app "${app}"; then
        log "WARN: cask ${name}: could not stop ${app}"
        FAILED=$((FAILED + 1))
        return 1
      fi
      log "QUIT: ${app} stopped for the weekly forced update"
    done <<<"${apps}"
  fi
  return 0
}

check_edupy() {
  local shared="/opt/edupy"
  [[ -f "${shared}/pyvenv.cfg" ]] || return 0
  if [[ ! -L "${shared}" && -x "${shared}/bin/python" ]] &&
      as_admin /usr/bin/perl -e "${WATCHDOG}" "${TIMEOUT_QUERY}" "${shared}/bin/python" -c \
      'import sys,site,pip; assert sys.version_info[:2] == (3,14); assert sys.prefix == "/opt/edupy"; assert site.ENABLE_USER_SITE; print(sys.version)' \
      </dev/null >>"${LOG_FILE}" 2>&1; then
    log "OK: existing /opt/edupy still runs; its packages and interpreter links were not changed"
  else
    log "WARN: /opt/edupy needs repair by the TLF installer"
    FAILED=$((FAILED + 1))
  fi
}

# True from the margin before a scheduled exam lock until its end.
exam_is_near() {
  local start_ts end_ts now
  [[ -f "${EXAM_STATE_FILE}" ]] || return 1
  start_ts="$(/usr/bin/awk -F= '$1 == "START_TS" { print $2; exit }' "${EXAM_STATE_FILE}")"
  end_ts="$(/usr/bin/awk -F= '$1 == "END_TS" { print $2; exit }' "${EXAM_STATE_FILE}")"
  if [[ ! "${start_ts}" =~ ^[0-9]+$ || ! "${end_ts}" =~ ^[0-9]+$ ]]; then
    log "WARN: ignoring invalid ${EXAM_STATE_FILE}"
    return 1
  fi
  now="$(/bin/date '+%s')"
  [[ ${now} -ge $((start_ts - EXAM_MARGIN_SECONDS)) && ${now} -lt ${end_ts} ]]
}

# Spread the fleet: every Mac behind the school NAT gets the same Jamf schedule.
random_delay() {
  local delay=$((RANDOM % (JITTER_MAX_SECONDS + 1)))
  log "Waiting ${delay}s before contacting Homebrew"
  CURRENT_OPERATION="random start delay"
  /bin/sleep "${delay}" &
  wait_active
}

prune_homebrew() {
  local output="${WORK_DIR}/prune.log"
  if ! capture_brew "${TIMEOUT_CLEANUP}" "${output}" cleanup "--prune=${CLEANUP_PRUNE_DAYS}"; then
    log "WARN: brew cleanup failed"
    failure_detail "${output}"
    FAILED=$((FAILED + 1))
  fi
}

check_free_space() {
  local free
  free="$(/bin/df -g "${BREW_PREFIX}" | /usr/bin/awk 'NR == 2 { print $4 }')"
  [[ "${free}" =~ ^[0-9]+$ ]] || fail "Cannot read free disk space"
  log "Free disk space: ${free} GB"
  [[ ${free} -ge ${MIN_FREE_GB} ]] || fail "Only ${free} GB free; ${MIN_FREE_GB} GB required for updates"
}

log "START: Homebrew maintenance v6; latest available versions, no seven-day age guarantee"
[[ "$(/usr/bin/uname -s)" == "Darwin" && "$(/usr/bin/uname -m)" == "arm64" ]] || fail "Apple Silicon macOS is required"
/usr/bin/id "${ADMIN_USER}" >/dev/null 2>&1 || fail "Account ${ADMIN_USER} is missing"
[[ -d "${ADMIN_HOME}" && -x "${BREW}" && -x "${JQ}" && ! -L "${BREW_PREFIX}" ]] || fail "Homebrew, jq or admin home is missing/invalid"
[[ -x /usr/bin/perl ]] || fail "/usr/bin/perl is required for command timeouts"
[[ "$(/usr/bin/stat -f '%Su' "${BREW_PREFIX}")" == "${ADMIN_USER}" ]] || fail "Homebrew is not owned by admin; do not scope this script to teacher-owned installations"
random_delay
if exam_is_near; then
  log "SKIP: exam network lock is scheduled now; retry at the next scheduled run"
  exit 0
fi
acquire_lock
/usr/bin/caffeinate -i -w "$$" </dev/null >/dev/null 2>&1 &
CAFFEINATE_PID=$!
RESTORE_PERMISSIONS=1
cd "${ADMIN_HOME}"

log "Refreshing Homebrew and package definitions"
if ! capture_brew "${TIMEOUT_UPDATE}" "${WORK_DIR}/update.log" update; then
  failure_detail "${WORK_DIR}/update.log"
  fail "brew update failed; not proceeding with stale metadata"
fi

prune_homebrew
check_free_space

# Take one inventory snapshot; includes dependencies and self-updating casks.
if ! capture_brew "${TIMEOUT_QUERY}" "${WORK_DIR}/outdated.json" outdated --json=v2 --greedy; then
  failure_detail "${WORK_DIR}/outdated.json"
  fail "Cannot obtain the outdated-package inventory"
fi
json -er '(.formulae | type == "array") and (.casks | type == "array")' \
  <"${WORK_DIR}/outdated.json" >/dev/null || fail "Invalid outdated-package inventory"
json -r '.formulae[] | [.name, (.current_version // "unknown"), (.pinned // false)] | @tsv' \
  <"${WORK_DIR}/outdated.json" >"${WORK_DIR}/formulae.tsv" || fail "Cannot parse formula updates"
json -r '.casks[] | [.name, (.current_version // "unknown"), (.pinned // false)] | @tsv' \
  <"${WORK_DIR}/outdated.json" >"${WORK_DIR}/casks.tsv" || fail "Cannot parse cask updates"

for kind in formula cask; do
  if [[ "${kind}" == "formula" ]]; then plan="${WORK_DIR}/formulae.tsv"; else plan="${WORK_DIR}/casks.tsv"; fi
  while IFS=$'\t' read -r name _ pinned; do
    [[ -z "${name}" ]] && continue
    [[ "${name}" =~ ^[A-Za-z0-9][A-Za-z0-9@+._/-]*$ ]] || fail "Invalid package name in inventory"
    if [[ "${pinned}" == "true" ]]; then
      log "SKIP: ${kind} ${name}: pinned"
      SKIPPED=$((SKIPPED + 1))
      continue
    fi
    if [[ "${kind}" == "cask" ]] && ! cask_can_update "${name}"; then
      relaunch_apps
      continue
    fi
    upgrade_one "${kind}" "${name}"
    relaunch_apps
  done <"${plan}"
done

check_edupy
CURRENT_OPERATION="final status"
if [[ ${FAILED} -ne 0 ]]; then
  fail "${FAILED} package operations failed; see WARN and DETAIL above"
fi
if [[ ${SKIPPED} -eq 0 ]]; then
  log "COMPLETE: update pass finished"
else
  log "COMPLETE WITH SKIPS: ${SKIPPED} packages skipped; see SKIP above"
fi
