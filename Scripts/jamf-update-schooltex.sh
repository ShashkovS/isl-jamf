#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

TEXLIVE_YEAR="2026"
ADMIN_USER="admin"
TEXLIVE_REPOSITORY="https://mirror.ctan.org/systems/texlive/tlnet"
REMOTE_PACKAGES_URL="https://raw.githubusercontent.com/ShashkovS/isl-jamf/main/SchoolTeX/${TEXLIVE_YEAR}/packages.txt"
PACKAGES_FILE="/Library/Application Support/The Island/Jamf/SchoolTeX/${TEXLIVE_YEAR}/packages.txt"
LOG_FILE="/var/log/theisland-schooltex-update.log"
LOCK_DIR="/private/var/run/theisland-schooltex.lock"

WORK_DIR=""
RESULT_FILE=""
TEACHER_USER=""
TEACHER_HOME=""
SCHOOLTEX_ROOT=""
TEXDIR=""
TEXBIN=""
MANAGED_MARKER=""
LOCKED=0
LOCAL_USERS=()
PACKAGES=()

if [[ ${EUID} -ne 0 ]]; then
  /bin/echo "ERROR: Jamf School must run this script as root" >&2
  exit 1
fi

if [[ -L "${LOG_FILE}" ]]; then /bin/rm -f "${LOG_FILE}"; fi
/usr/bin/touch "${LOG_FILE}"
/usr/sbin/chown root:wheel "${LOG_FILE}"
/bin/chmod 0640 "${LOG_FILE}"
WORK_DIR="$(/usr/bin/mktemp -d /private/var/tmp/theisland-schooltex-update.XXXXXX)"
RESULT_FILE="${WORK_DIR}/result.log"
/usr/bin/touch "${RESULT_FILE}"
/usr/sbin/chown -R root:wheel "${WORK_DIR}"
/bin/chmod 0700 "${WORK_DIR}"
/bin/chmod 0600 "${RESULT_FILE}"

log() {
  local line
  line="$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ') $*"
  /usr/bin/printf '%s\n' "${line}" >>"${LOG_FILE}" 2>/dev/null || true
  /usr/bin/printf '%s\n' "${line}" >>"${RESULT_FILE}" 2>/dev/null || true
}

fail() {
  log "ERROR: $*"
  /usr/bin/printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  local rc=$?
  trap - EXIT
  [[ ${LOCKED} -eq 0 ]] || /bin/rm -rf "${LOCK_DIR}" 2>/dev/null || true
  log "FINISH: exit code ${rc}"
  if [[ ${rc} -ne 0 ]]; then
    /usr/bin/printf '%s\n' "--- last 100 lines of ${LOG_FILE} ---" >>"${RESULT_FILE}" 2>/dev/null || true
    /usr/bin/tail -n 100 "${LOG_FILE}" >>"${RESULT_FILE}" 2>/dev/null || true
  fi
  /usr/bin/tail -n 180 "${RESULT_FILE}" 2>/dev/null || true
  /bin/rm -rf "${WORK_DIR}" 2>/dev/null || true
  exit "${rc}"
}
trap cleanup EXIT

run_logged() {
  local label="$1" rc
  shift
  log "${label}"
  /usr/bin/printf '\n=== %s ===\n' "${label}" >>"${LOG_FILE}"
  set +e
  "$@" >>"${LOG_FILE}" 2>&1
  rc=$?
  set -e
  /usr/bin/printf '=== exit code %s ===\n' "${rc}" >>"${LOG_FILE}"
  return "${rc}"
}

curl_file() {
  local url="$1" destination="$2"
  /usr/bin/curl \
    --fail --location --silent --show-error \
    --retry 3 --retry-delay 2 --connect-timeout 25 \
    --proto '=https' --proto-redir '=https' --tlsv1.2 \
    -H 'Cache-Control: no-cache' \
    --output "${destination}" "${url}"
}

run_teacher() {
  /usr/bin/sudo -n -u "${TEACHER_USER}" -H \
    /usr/bin/env \
      HOME="${TEACHER_HOME}" USER="${TEACHER_USER}" LOGNAME="${TEACHER_USER}" \
      PATH="${TEXBIN}:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
      CI=1 NONINTERACTIVE=1 GIT_TERMINAL_PROMPT=0 \
      SUDO_ASKPASS=/usr/bin/false SSH_ASKPASS=/usr/bin/false \
      "$@"
}

human_user() {
  local user="$1" uid shell
  case "${user}" in ""|root|admin|Guest|Shared|loginwindow|_*) return 1 ;; esac
  uid="$(/usr/bin/id -u "${user}" 2>/dev/null || true)"
  [[ "${uid}" =~ ^[0-9]+$ ]] && (( uid >= 501 )) || return 1
  shell="$(/usr/bin/dscl . -read "/Users/${user}" UserShell 2>/dev/null | /usr/bin/awk '{print $2}' || true)"
  [[ -n "${shell}" && "${shell}" != "/usr/bin/false" && "${shell}" != "/sbin/nologin" ]]
}

detect_teacher() {
  local dir user console home
  for dir in /Users/*; do
    [[ -d "${dir}" ]] || continue
    user="$(/usr/bin/basename "${dir}")"
    human_user "${user}" && LOCAL_USERS+=("${user}")
  done
  console="$(/usr/bin/stat -f '%Su' /dev/console 2>/dev/null || true)"
  if human_user "${console}"; then
    TEACHER_USER="${console}"
  elif [[ ${#LOCAL_USERS[@]} -eq 1 ]]; then
    TEACHER_USER="${LOCAL_USERS[0]}"
  else
    fail "Cannot determine teacher account; detected: ${LOCAL_USERS[*]:-none}"
  fi

  home="$(/usr/bin/dscl . -read "/Users/${TEACHER_USER}" NFSHomeDirectory 2>/dev/null | /usr/bin/sed -E 's/^NFSHomeDirectory:[[:space:]]*//' || true)"
  [[ -n "${home}" && -d "${home}" ]] || fail "Cannot determine home directory for ${TEACHER_USER}"
  TEACHER_HOME="${home}"
  SCHOOLTEX_ROOT="${TEACHER_HOME}/Library/SchoolTeX"
  TEXDIR="${SCHOOLTEX_ROOT}/${TEXLIVE_YEAR}"
  TEXBIN="${TEXDIR}/bin/universal-darwin"
  MANAGED_MARKER="${SCHOOLTEX_ROOT}/.managed-by-isl-jamf"
  log "Teacher account: ${TEACHER_USER}"
}

acquire_lock() {
  local pid
  if ! /bin/mkdir "${LOCK_DIR}" 2>/dev/null; then
    pid="$(/bin/cat "${LOCK_DIR}/pid" 2>/dev/null || true)"
    if [[ "${pid}" =~ ^[0-9]+$ ]] && ! /bin/kill -0 "${pid}" 2>/dev/null; then
      /bin/rm -rf "${LOCK_DIR}"
      /bin/mkdir "${LOCK_DIR}" || fail "Cannot replace stale SchoolTeX lock"
    else
      fail "Another SchoolTeX deployment is already running"
    fi
  fi
  /usr/sbin/chown root:wheel "${LOCK_DIR}"
  /bin/chmod 0700 "${LOCK_DIR}"
  /usr/bin/printf '%s\n' "$$" >"${LOCK_DIR}/pid"
  LOCKED=1
}

validate_packages() {
  /usr/bin/awk '
    /^[[:space:]]*$/ { next }
    /^[[:space:]]*#/ { next }
    /^[A-Za-z0-9][A-Za-z0-9+._-]*$/ { count++; next }
    { printf "Unsupported package-manifest line %d: %s\n", NR, $0; bad=1 }
    END { if (count == 0) bad=1; exit bad }
  ' "$1"
}

fetch_packages() {
  local downloaded sha
  downloaded="${WORK_DIR}/packages.txt"
  log "Downloading SchoolTeX package manifest"
  curl_file "${REMOTE_PACKAGES_URL}" "${downloaded}" >>"${LOG_FILE}" 2>&1 || fail "Cannot download SchoolTeX package manifest"
  validate_packages "${downloaded}" >>"${LOG_FILE}" 2>&1 || fail "SchoolTeX package manifest is invalid or empty"
  /bin/mkdir -p "$(/usr/bin/dirname "${PACKAGES_FILE}")"
  /usr/bin/install -o root -g wheel -m 0644 "${downloaded}" "${PACKAGES_FILE}"
  sha="$(/usr/bin/shasum -a 256 "${PACKAGES_FILE}" | /usr/bin/awk '{print $1}')"
  log "Package manifest ready: SHA-256 ${sha}"
}

load_packages() {
  local line
  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="$(/usr/bin/printf '%s' "${line}" | /usr/bin/sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
    [[ -z "${line}" || "${line}" == \#* ]] && continue
    PACKAGES+=("${line}")
  done <"${PACKAGES_FILE}"
  [[ ${#PACKAGES[@]} -gt 0 ]] || fail "SchoolTeX package manifest is empty"
  log "Package manifest contains ${#PACKAGES[@]} entries"
}

marker_matches() {
  [[ -f "${MANAGED_MARKER}" ]] || return 1
  /usr/bin/grep -Fqx 'managed_by=ShashkovS/isl-jamf' "${MANAGED_MARKER}" &&
    /usr/bin/grep -Fqx "teacher=${TEACHER_USER}" "${MANAGED_MARKER}" &&
    /usr/bin/grep -Fqx "year=${TEXLIVE_YEAR}" "${MANAGED_MARKER}" &&
    /usr/bin/grep -Fqx "texdir=${TEXDIR}" "${MANAGED_MARKER}"
}

verify_texlive_year() {
  local version
  version="$(run_teacher "${TEXBIN}/tlmgr" --version 2>&1)" || return 1
  /usr/bin/printf '%s\n' "${version}" | /usr/bin/grep -Eq "TeX Live.*${TEXLIVE_YEAR}"
}

verify_repository_year() {
  curl_file "${TEXLIVE_REPOSITORY}/TEXLIVE_${TEXLIVE_YEAR}" /dev/null >>"${LOG_FILE}" 2>&1
}

verify_installation() {
  local latexmk_info
  marker_matches || fail "SchoolTeX managed marker is missing or invalid"
  [[ -x "${TEXBIN}/tlmgr" ]] || fail "tlmgr is missing"
  verify_texlive_year || fail "tlmgr does not report TeX Live ${TEXLIVE_YEAR}"
  /usr/bin/sudo -n -u "${TEACHER_USER}" -H /usr/bin/test -w "${TEXDIR}/tlpkg/texlive.tlpdb" || fail "${TEACHER_USER} cannot update TeX Live"
  [[ -x /Library/TeX/texbin/latexmk ]] || fail "/Library/TeX/texbin is missing or broken; rerun the math-teacher profile"
  latexmk_info="$(run_teacher "${TEXBIN}/tlmgr" info --only-installed latexmk 2>>"${LOG_FILE}" || true)"
  /usr/bin/printf '%s\n' "${latexmk_info}" | /usr/bin/grep -Fq 'installed: Yes' || fail "latexmk is not installed"
}

log "START: SchoolTeX ${TEXLIVE_YEAR} update"
detect_teacher
acquire_lock
marker_matches || fail "This Mac has no managed SchoolTeX ${TEXLIVE_YEAR} installation"
[[ -x "${TEXBIN}/tlmgr" ]] || fail "tlmgr is missing at ${TEXBIN}/tlmgr"
verify_texlive_year || fail "Installed TeX Live is not ${TEXLIVE_YEAR}"
verify_repository_year || fail "Current repository is no longer serving TeX Live ${TEXLIVE_YEAR}; install the next yearly release side by side"
fetch_packages
load_packages

run_logged "Setting TeX Live repository" run_teacher "${TEXBIN}/tlmgr" option repository "${TEXLIVE_REPOSITORY}" || fail "Cannot configure tlmgr repository"
run_logged "Disabling TeX source files" run_teacher "${TEXBIN}/tlmgr" option srcfiles 0 || fail "Cannot disable source files"
run_logged "Disabling TeX documentation files" run_teacher "${TEXBIN}/tlmgr" option docfiles 0 || fail "Cannot disable documentation files"
run_logged "Keeping one tlmgr backup" run_teacher "${TEXBIN}/tlmgr" option autobackup 1 || fail "Cannot configure tlmgr backups"
run_logged "Updating all TeX Live packages" run_teacher "${TEXBIN}/tlmgr" update --self --all || fail "tlmgr update --self --all failed"
run_logged "Applying SchoolTeX package manifest" run_teacher "${TEXBIN}/tlmgr" install "${PACKAGES[@]}" || fail "tlmgr package installation failed"
run_logged "Setting A4 paper" run_teacher "${TEXBIN}/tlmgr" paper a4 || fail "Cannot set A4 paper"
verify_installation

/bin/rm -rf "${LOCK_DIR}"
LOCKED=0
log "SUCCESS: SchoolTeX ${TEXLIVE_YEAR} updated"
