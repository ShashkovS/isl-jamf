#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

PROFILE="teacher"
ADMIN_USER="admin"
ADMIN_HOME="/Users/${ADMIN_USER}"
BREW_PREFIX="/opt/homebrew"
BREW="${BREW_PREFIX}/bin/brew"
PY_VER="3.14"
REMOTE_BREWFILE_URL="https://raw.githubusercontent.com/shashkovs/isl-jamf/main/Brewfiles/${PROFILE}.Brewfile"
BREWFILE_DIR="/Library/Application Support/The Island/Jamf/Brewfiles"
BREWFILE="${BREWFILE_DIR}/${PROFILE}.Brewfile"
LOG_FILE="/var/log/theisland-software-${PROFILE}.log"
LOCK_DIR="/private/var/run/theisland-homebrew.lock"
WORK_DIR=""
RESULT_FILE=""
LOCKED=0
SERVICES_COMMAND=""
LOCAL_USERS=()
TEACHER_USER=""
RESTORE_TEACHER_ON_EXIT=0

if [[ ${EUID} -ne 0 ]]; then
  /bin/echo "ERROR: Jamf School must run this script as root" >&2
  exit 1
fi

if [[ -L "${LOG_FILE}" ]]; then /bin/rm -f "${LOG_FILE}"; fi
/usr/bin/touch "${LOG_FILE}"
/usr/sbin/chown root:wheel "${LOG_FILE}"
/bin/chmod 0640 "${LOG_FILE}"
WORK_DIR="$(/usr/bin/mktemp -d "/private/var/tmp/theisland-${PROFILE}.XXXXXX")"
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
  if [[ "${PROFILE}" == "teacher" && ${RESTORE_TEACHER_ON_EXIT} -eq 1 && -n "${TEACHER_USER}" && -d "${BREW_PREFIX}" ]]; then
    /bin/chmod -RN "${BREW_PREFIX}" 2>/dev/null || true
    /usr/sbin/chown -R "${TEACHER_USER}:admin" "${BREW_PREFIX}" 2>/dev/null || true
    /bin/chmod -R u+rwX,go-w "${BREW_PREFIX}" 2>/dev/null || true
    log "Restored Homebrew ownership to ${TEACHER_USER} after failure"
  fi
  log "FINISH: exit code ${rc}"
  if [[ ${rc} -ne 0 ]]; then
    /usr/bin/printf '%s\n' "--- last 80 lines of ${LOG_FILE} ---" >>"${RESULT_FILE}" 2>/dev/null || true
    /usr/bin/tail -n 80 "${LOG_FILE}" >>"${RESULT_FILE}" 2>/dev/null || true
  fi
  /usr/bin/tail -n 140 "${RESULT_FILE}" 2>/dev/null || true
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

brew_admin() {
  /usr/bin/sudo -n -u "${ADMIN_USER}" -H \
    /usr/bin/env HOME="${ADMIN_HOME}" USER="${ADMIN_USER}" LOGNAME="${ADMIN_USER}" \
      PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
      CI=1 NONINTERACTIVE=1 GIT_TERMINAL_PROMPT=0 \
      SUDO_ASKPASS=/usr/bin/false SSH_ASKPASS=/usr/bin/false \
      HOMEBREW_NO_ANALYTICS=1 HOMEBREW_NO_ASK=1 HOMEBREW_NO_AUTO_UPDATE=1 \
      HOMEBREW_NO_ENV_HINTS=1 HOMEBREW_NO_COLOR=1 HOMEBREW_NO_INSTALL_CLEANUP=1 \
      HOMEBREW_NO_UPGRADE_QUIT_CASKS=1 HOMEBREW_BUNDLE_NO_UPGRADE=1 \
      "${BREW}" "$@"
}

run_admin() {
  /usr/bin/sudo -n -u "${ADMIN_USER}" -H \
    /usr/bin/env HOME="${ADMIN_HOME}" USER="${ADMIN_USER}" LOGNAME="${ADMIN_USER}" \
      PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
      CI=1 NONINTERACTIVE=1 GIT_TERMINAL_PROMPT=0 \
      SUDO_ASKPASS=/usr/bin/false SSH_ASKPASS=/usr/bin/false "$@"
}

acquire_lock() {
  local pid
  if ! /bin/mkdir "${LOCK_DIR}" 2>/dev/null; then
    pid="$(/bin/cat "${LOCK_DIR}/pid" 2>/dev/null || true)"
    if [[ "${pid}" =~ ^[0-9]+$ ]] && ! /bin/kill -0 "${pid}" 2>/dev/null; then
      /bin/rm -rf "${LOCK_DIR}"
      /bin/mkdir "${LOCK_DIR}" || fail "Cannot replace stale Homebrew lock"
    else
      fail "Another Homebrew deployment is already running"
    fi
  fi
  /usr/sbin/chown root:wheel "${LOCK_DIR}"
  /bin/chmod 0700 "${LOCK_DIR}"
  /usr/bin/printf '%s\n' "$$" >"${LOCK_DIR}/pid"
  LOCKED=1
}

human_user() {
  local user="$1" uid shell
  case "${user}" in ""|root|admin|Guest|Shared|loginwindow|_*) return 1 ;; esac
  uid="$(/usr/bin/id -u "${user}" 2>/dev/null || true)"
  [[ "${uid}" =~ ^[0-9]+$ ]] && (( uid >= 501 )) || return 1
  shell="$(/usr/bin/dscl . -read "/Users/${user}" UserShell 2>/dev/null | /usr/bin/awk '{print $2}' || true)"
  [[ -n "${shell}" && "${shell}" != "/usr/bin/false" && "${shell}" != "/sbin/nologin" ]]
}

list_users() {
  local dir user
  for dir in /Users/*; do
    [[ -d "${dir}" ]] || continue
    user="$(/usr/bin/basename "${dir}")"
    human_user "${user}" && LOCAL_USERS+=("${user}")
  done
  log "Personal users: ${LOCAL_USERS[*]:-none}"
}

check_common() {
  [[ "$(/usr/bin/uname -m)" == "arm64" ]] || fail "Only Apple Silicon is supported"
  /usr/bin/id "${ADMIN_USER}" >/dev/null 2>&1 || fail "Local account ${ADMIN_USER} does not exist"
  [[ -d "${ADMIN_HOME}" ]] || fail "Home directory ${ADMIN_HOME} does not exist"
  /usr/bin/id -Gn "${ADMIN_USER}" | /usr/bin/tr ' ' '\n' | /usr/bin/grep -qx admin || fail "${ADMIN_USER} is not an administrator"
  [[ -x "${BREW}" ]] || fail "Homebrew is missing; run step 0 first"
  /usr/bin/xcrun --find clang >/dev/null 2>&1 || fail "Command Line Tools are missing; run step 0 first"
}

ensure_rosetta() {
  if [[ -e /Library/Apple/usr/libexec/oah/libRosettaRuntime ]] || \
     /usr/sbin/pkgutil --pkg-info com.apple.pkg.RosettaUpdateAuto >/dev/null 2>&1; then
    log "Rosetta 2 already installed"
    return
  fi
  run_logged "Installing Rosetta 2" /usr/sbin/softwareupdate --install-rosetta --agree-to-license || fail "Rosetta 2 installation failed"
  if [[ ! -e /Library/Apple/usr/libexec/oah/libRosettaRuntime ]] && \
     ! /usr/sbin/pkgutil --pkg-info com.apple.pkg.RosettaUpdateAuto >/dev/null 2>&1; then
    fail "Rosetta 2 is unavailable after installation"
  fi
  log "Rosetta 2 ready"
}

write_embedded_brewfile() {
  /bin/cat >"$1" <<'EOF_BREWFILE'
cask_args appdir: "/Applications"

brew "python@3.14"
brew "python-tk@3.14"
brew "git"
brew "uv"
brew "sqlite"
brew "p7zip"
brew "ripgrep"
brew "mupdf"
brew "poppler"
brew "tesseract"
brew "tesseract-lang"

cask "iterm2"
cask "visual-studio-code"
EOF_BREWFILE
}

validate_brewfile() {
  /usr/bin/awk '
    /^[[:space:]]*$/ { next }
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*cask_args[[:space:]]+appdir:[[:space:]]*"\/Applications"[[:space:]]*$/ { next }
    /^[[:space:]]*(brew|cask)[[:space:]]+"[A-Za-z0-9@+._-]+"[[:space:]]*$/ { next }
    { printf "Unsupported Brewfile line %d: %s\n", NR, $0; bad=1 }
    END { exit bad }
  ' "$1"
}

prepare_brewfile() {
  local remote embedded selected line sha
  remote="${WORK_DIR}/remote.Brewfile"
  embedded="${WORK_DIR}/embedded.Brewfile"
  selected="${WORK_DIR}/${PROFILE}.Brewfile"
  write_embedded_brewfile "${embedded}"

  log "Checking remote Brewfile ${REMOTE_BREWFILE_URL}"
  if /usr/bin/curl --fail --location --silent --show-error --retry 3 --retry-delay 2 \
      --connect-timeout 20 --proto '=https' --proto-redir '=https' --tlsv1.2 \
      -H 'Cache-Control: no-cache' --output "${remote}" "${REMOTE_BREWFILE_URL}" \
      >>"${LOG_FILE}" 2>&1; then
    validate_brewfile "${remote}" >>"${LOG_FILE}" 2>&1 || fail "Remote Brewfile contains unsupported syntax"
    /bin/cp "${remote}" "${selected}"
    log "Using remote Brewfile"
  else
    /bin/cp "${embedded}" "${selected}"
    log "Remote Brewfile unavailable; using embedded Brewfile"
  fi

  while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    /usr/bin/grep -Fqx "${line}" "${selected}" || fail "Brewfile is missing required entry: ${line}"
  done < <(/usr/bin/grep -Ev '^[[:space:]]*(#|$)' "${embedded}" | /usr/bin/grep -Ev '^[[:space:]]*cask[[:space:]]')

  /bin/mkdir -p "${BREWFILE_DIR}"
  /usr/bin/install -o root -g wheel -m 0644 "${selected}" "${BREWFILE}"
  sha="$(/usr/bin/shasum -a 256 "${BREWFILE}" | /usr/bin/awk '{print $1}')"
  log "Brewfile ready: ${BREWFILE}; SHA-256 ${sha}"
}

reconcile_brewfile() {
  if run_logged "Checking Brewfile state" brew_admin bundle check --file="${BREWFILE}" --no-upgrade; then
    log "All Homebrew packages are already installed"
  else
    log "Installing missing Homebrew packages"
    run_logged "Refreshing Homebrew metadata" brew_admin update-if-needed || fail "brew update-if-needed failed"
    run_logged "Applying Brewfile" brew_admin bundle --file="${BREWFILE}" --no-upgrade || fail "brew bundle failed"
    run_logged "Verifying Brewfile state" brew_admin bundle check --file="${BREWFILE}" --no-upgrade || fail "Brewfile is still incomplete"
  fi
  SERVICES_COMMAND="$(brew_admin command services 2>/dev/null || true)"
  if [[ -n "${SERVICES_COMMAND}" ]]; then
    [[ "${SERVICES_COMMAND}" == "${BREW_PREFIX}"/* && -f "${SERVICES_COMMAND}" && ! -L "${SERVICES_COMMAND}" ]] || fail "Unexpected brew services path: ${SERVICES_COMMAND}"
  fi
  log "$(brew_admin --version | /usr/bin/head -n 1)"
}

write_common_path() {
  /bin/mkdir -p /etc/paths.d
  /bin/cat >/etc/paths.d/10-homebrew <<'EOF_PATH'
/opt/homebrew/bin
/opt/homebrew/sbin
EOF_PATH
  /usr/sbin/chown root:wheel /etc/paths.d/10-homebrew
  /bin/chmod 0644 /etc/paths.d/10-homebrew
}

write_user_path() {
  local user="$1" line="$2" home file group
  home="/Users/${user}"
  file="${home}/.zprofile"
  group="$(/usr/bin/id -gn "${user}")"
  if [[ -L "${file}" ]]; then
    log "WARNING: ${file} is a symlink; not changing it"
    return
  fi
  /usr/bin/grep -Fqx "${line}" "${file}" 2>/dev/null || /usr/bin/printf '\n%s\n' "${line}" >>"${file}"
  /usr/sbin/chown "${user}:${group}" "${file}"
  /bin/chmod 0644 "${file}"
}

detect_teacher() {
  local console
  list_users
  console="$(/usr/bin/stat -f '%Su' /dev/console 2>/dev/null || true)"
  if human_user "${console}"; then
    TEACHER_USER="${console}"
  elif [[ ${#LOCAL_USERS[@]} -eq 1 ]]; then
    TEACHER_USER="${LOCAL_USERS[0]}"
  else
    fail "Cannot determine teacher account; detected: ${LOCAL_USERS[*]:-none}"
  fi
  log "Teacher account: ${TEACHER_USER}"
}

prepare_teacher_owner() {
  local owner
  owner="$(/usr/bin/stat -f '%Su' "${BREW_PREFIX}")"
  [[ "${owner}" == "${ADMIN_USER}" || "${owner}" == "${TEACHER_USER}" ]] || fail "Unexpected Homebrew owner ${owner}"
  if [[ "${owner}" == "${TEACHER_USER}" ]]; then
    log "Temporarily transferring Homebrew to ${ADMIN_USER}"
    /bin/chmod -RN "${BREW_PREFIX}" 2>/dev/null || true
    /usr/sbin/chown -R "${ADMIN_USER}:admin" "${BREW_PREFIX}"
    /bin/chmod -R u+rwX,go-w "${BREW_PREFIX}"
    RESTORE_TEACHER_ON_EXIT=1
  fi
}

unlock_for_teacher() {
  local home group env_file
  home="/Users/${TEACHER_USER}"
  group="$(/usr/bin/id -gn "${TEACHER_USER}")"
  /bin/mkdir -p /etc/homebrew
  /usr/bin/printf '%s\n' 'HOMEBREW_NO_ANALYTICS=1' >/etc/homebrew/brew.env
  /usr/sbin/chown root:wheel /etc/homebrew/brew.env
  /bin/chmod 0644 /etc/homebrew/brew.env

  log "Transferring Homebrew ownership to ${TEACHER_USER}"
  /bin/chmod -RN "${BREW_PREFIX}" 2>/dev/null || true
  /usr/sbin/chown -R "${TEACHER_USER}:admin" "${BREW_PREFIX}"
  /bin/chmod -R u+rwX,go-w "${BREW_PREFIX}"
  if [[ -n "${SERVICES_COMMAND}" ]]; then
    /usr/sbin/chown "${TEACHER_USER}:admin" "${SERVICES_COMMAND}"
    /bin/chmod 0644 "${SERVICES_COMMAND}"
  fi

  /bin/mkdir -p "${home}/Applications" "${home}/.homebrew"
  /usr/sbin/chown "${TEACHER_USER}:${group}" "${home}/Applications" "${home}/.homebrew"
  env_file="${home}/.homebrew/brew.env"
  /usr/bin/printf 'HOMEBREW_CASK_OPTS=--appdir=%s/Applications\n' "${home}" >"${env_file}"
  /usr/sbin/chown "${TEACHER_USER}:${group}" "${env_file}"
  /bin/chmod 0644 "${env_file}"
  write_user_path "${TEACHER_USER}" 'export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:${PATH}"'
  /usr/bin/sudo -n -u "${TEACHER_USER}" -H /usr/bin/test -w "${BREW_PREFIX}" || fail "${TEACHER_USER} cannot write to Homebrew"
  /usr/bin/sudo -n -u "${TEACHER_USER}" -H "${BREW}" --version >/dev/null 2>&1 || fail "${TEACHER_USER} cannot run Homebrew"
  RESTORE_TEACHER_ON_EXIT=0
  log "Homebrew is writable by ${TEACHER_USER}; future casks default to ${home}/Applications"
}

log "START: teacher software profile"
detect_teacher
check_common
acquire_lock
ensure_rosetta
write_common_path
prepare_teacher_owner
prepare_brewfile
reconcile_brewfile
unlock_for_teacher
log "SUCCESS: teacher profile installed"
