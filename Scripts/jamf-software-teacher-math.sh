#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

TEXLIVE_YEAR="2026"
MAX_REPOSITORY_ATTEMPTS=3

ADMIN_USER="admin"
ADMIN_HOME="/Users/${ADMIN_USER}"

BREW_PREFIX="/opt/homebrew"
BREW="${BREW_PREFIX}/bin/brew"

TEXLIVE_REPOSITORY=""
TEXLIVE_REPOSITORY_CANDIDATES=(
  "https://ftp.fau.de/ctan/systems/texlive/tlnet"
  "https://mirror.ctan.org/systems/texlive/tlnet"
  "https://ctan.math.illinois.edu/systems/texlive/tlnet"
  "https://mirrors.ibiblio.org/CTAN/systems/texlive/tlnet"
)

REPO_RAW="https://raw.githubusercontent.com/ShashkovS/isl-jamf/main"
REMOTE_BREWFILE_URL="${REPO_RAW}/Brewfiles/teacher-math.Brewfile"
REMOTE_PACKAGES_URL="${REPO_RAW}/SchoolTeX/${TEXLIVE_YEAR}/packages.txt"
REMOTE_VSCODE_SETTINGS_URL="${REPO_RAW}/SchoolTeX/${TEXLIVE_YEAR}/vscode-settings.json"

MANAGED_ROOT="/Library/Application Support/The Island/Jamf"
BREWFILE="${MANAGED_ROOT}/Brewfiles/teacher-math.Brewfile"
PACKAGES_FILE="${MANAGED_ROOT}/SchoolTeX/${TEXLIVE_YEAR}/packages.txt"
VSCODE_SETTINGS_DIR="${MANAGED_ROOT}/SchoolTeX/${TEXLIVE_YEAR}"
VSCODE_SETTINGS_FILE=""

LOG_FILE="/var/log/theisland-software-teacher-math.log"
HOMEBREW_LOCK="/private/var/run/theisland-homebrew.lock"
SCHOOLTEX_LOCK="/private/var/run/theisland-schooltex.lock"

WORK_DIR=""
TARGET_WORK_DIR=""
RESULT_FILE=""

TARGET_USER=""
TARGET_HOME=""
TARGET_GROUP=""
TARGET_SHELL=""
ACCOUNT_MODE=""
USE_GLOBAL_TEXBIN=0

SCHOOLTEX_ROOT=""
TEXDIR=""
TEXBIN=""
CURRENT_LINK=""
CURRENT_TEXBIN=""
TEX_COMMAND_DIR=""
MANAGED_MARKER=""
PAPER_MARKER=""

HOMEBREW_ORIGINAL_OWNER=""
HOMEBREW_ORIGINAL_GROUP=""
SERVICES_ORIGINAL_MODE=""
HOMEBREW_PREPARED=0
HOMEBREW_LOCKED=0
SCHOOLTEX_LOCKED=0
SERVICES_COMMAND=""

LOCAL_USERS=()
PACKAGES=()
MISSING_PACKAGES=()
FAILED_TEXLIVE_REPOSITORIES=()

if [[ ${EUID} -ne 0 ]]; then
  /bin/echo "ERROR: Jamf School must run this script as root" >&2
  exit 1
fi

if [[ -L "${LOG_FILE}" ]]; then
  /bin/rm -f "${LOG_FILE}"
fi

/usr/bin/touch "${LOG_FILE}"
/usr/sbin/chown root:wheel "${LOG_FILE}"
/bin/chmod 0640 "${LOG_FILE}"

WORK_DIR="$(/usr/bin/mktemp -d /private/var/tmp/theisland-schooltex.XXXXXX)"
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

run_logged() {
  local label="$1"
  local rc
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
  local url="$1"
  local destination="$2"

  /usr/bin/curl \
    --fail \
    --location \
    --silent \
    --show-error \
    --retry 3 \
    --retry-delay 2 \
    --connect-timeout 25 \
    --proto '=https' \
    --proto-redir '=https' \
    --tlsv1.2 \
    -H 'Cache-Control: no-cache' \
    --output "${destination}" \
    "${url}"
}

brew_as() {
  local user="$1"
  local home="$2"
  shift 2

  /usr/bin/sudo -n -u "${user}" -H \
    /usr/bin/env \
      HOME="${home}" \
      USER="${user}" \
      LOGNAME="${user}" \
      PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
      CI=1 \
      NONINTERACTIVE=1 \
      GIT_TERMINAL_PROMPT=0 \
      SUDO_ASKPASS=/usr/bin/false \
      SSH_ASKPASS=/usr/bin/false \
      HOMEBREW_NO_ANALYTICS=1 \
      HOMEBREW_NO_ASK=1 \
      HOMEBREW_NO_AUTO_UPDATE=1 \
      HOMEBREW_NO_ENV_HINTS=1 \
      HOMEBREW_NO_COLOR=1 \
      HOMEBREW_NO_INSTALL_CLEANUP=1 \
      HOMEBREW_NO_UPGRADE_QUIT_CASKS=1 \
      HOMEBREW_BUNDLE_NO_UPGRADE=1 \
      HOMEBREW_CASK_OPTS='--appdir=/Applications' \
      "${BREW}" "$@"
}

brew_admin() {
  brew_as "${ADMIN_USER}" "${ADMIN_HOME}" "$@"
}

brew_target() {
  brew_as "${TARGET_USER}" "${TARGET_HOME}" "$@"
}

brew_original_owner() {
  if [[ "${HOMEBREW_ORIGINAL_OWNER}" == "${ADMIN_USER}" ]]; then
    brew_admin "$@"
  else
    brew_target "$@"
  fi
}

run_target() {
  /usr/bin/sudo -n -u "${TARGET_USER}" -H \
    /usr/bin/env \
      HOME="${TARGET_HOME}" \
      USER="${TARGET_USER}" \
      LOGNAME="${TARGET_USER}" \
      TMPDIR="${TARGET_WORK_DIR:-/private/var/tmp}" \
      PATH="${TEXBIN:-${TARGET_HOME}/Library/SchoolTeX/current/bin/universal-darwin}:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
      CI=1 \
      NONINTERACTIVE=1 \
      GIT_TERMINAL_PROMPT=0 \
      SUDO_ASKPASS=/usr/bin/false \
      SSH_ASKPASS=/usr/bin/false \
      TEXLIVE_INSTALL_NO_RESUME=1 \
      TEXLIVE_INSTALL_NO_WELCOME=1 \
      TEXLIVE_INSTALL_ENV_NOCHECK=1 \
      "$@"
}

acquire_lock() {
  local lock="$1"
  local label="$2"
  local pid

  if ! /bin/mkdir "${lock}" 2>/dev/null; then
    pid="$(/bin/cat "${lock}/pid" 2>/dev/null || true)"

    if [[ "${pid}" =~ ^[0-9]+$ ]] &&
       ! /bin/kill -0 "${pid}" 2>/dev/null; then
      /bin/rm -rf "${lock}"
      /bin/mkdir "${lock}" || fail "Cannot replace stale ${label} lock"
    else
      fail "Another ${label} deployment is already running"
    fi
  fi

  /usr/sbin/chown root:wheel "${lock}"
  /bin/chmod 0700 "${lock}"
  /usr/bin/printf '%s\n' "$$" >"${lock}/pid"
}

human_user() {
  local user="$1"
  local uid
  local shell

  case "${user}" in
    ""|root|admin|Guest|Shared|loginwindow|_*)
      return 1
      ;;
  esac

  uid="$(/usr/bin/id -u "${user}" 2>/dev/null || true)"
  [[ "${uid}" =~ ^[0-9]+$ ]] && (( uid >= 501 )) || return 1

  shell="$(
    /usr/bin/dscl . -read "/Users/${user}" UserShell 2>/dev/null |
      /usr/bin/awk '{print $2}' || true
  )"

  [[ -n "${shell}" &&
     "${shell}" != "/usr/bin/false" &&
     "${shell}" != "/sbin/nologin" ]]
}

detect_target_user() {
  local dir
  local user
  local console
  local home

  for dir in /Users/*; do
    [[ -d "${dir}" ]] || continue
    user="$(/usr/bin/basename "${dir}")"
    if human_user "${user}"; then
      LOCAL_USERS+=("${user}")
    fi
  done

  log "Personal users: ${LOCAL_USERS[*]:-none}"

  console="$(/usr/bin/stat -f '%Su' /dev/console 2>/dev/null || true)"

  if human_user "${console}"; then
    TARGET_USER="${console}"
  elif [[ ${#LOCAL_USERS[@]} -eq 1 ]]; then
    TARGET_USER="${LOCAL_USERS[0]}"
  else
    fail "Cannot determine target account; detected: ${LOCAL_USERS[*]:-none}"
  fi

  home="$(
    /usr/bin/dscl . -read "/Users/${TARGET_USER}" NFSHomeDirectory 2>/dev/null |
      /usr/bin/sed -E 's/^NFSHomeDirectory:[[:space:]]*//' || true
  )"

  [[ -n "${home}" && -d "${home}" ]] ||
    fail "Cannot determine home directory for ${TARGET_USER}"

  [[ "${home}" != *$'\n'* && "${home}" != *' '* ]] ||
    fail "Unsupported target home path: ${home}"

  TARGET_HOME="${home}"
  TARGET_GROUP="$(/usr/bin/id -gn "${TARGET_USER}")"
  TARGET_SHELL="$(
    /usr/bin/dscl . -read "/Users/${TARGET_USER}" UserShell 2>/dev/null |
      /usr/bin/awk '{print $2}' || true
  )"
  case "${TARGET_SHELL}" in
    /bin/zsh|/bin/bash)
      ;;
    *)
      TARGET_SHELL="/bin/zsh"
      ;;
  esac

  SCHOOLTEX_ROOT="${TARGET_HOME}/Library/SchoolTeX"
  TEXDIR="${SCHOOLTEX_ROOT}/${TEXLIVE_YEAR}"
  TEXBIN="${TEXDIR}/bin/universal-darwin"
  CURRENT_LINK="${SCHOOLTEX_ROOT}/current"
  CURRENT_TEXBIN="${CURRENT_LINK}/bin/universal-darwin"
  MANAGED_MARKER="${SCHOOLTEX_ROOT}/.managed-by-isl-jamf"
  PAPER_MARKER="${SCHOOLTEX_ROOT}/.paper-a4-${TEXLIVE_YEAR}"
  VSCODE_SETTINGS_FILE="${VSCODE_SETTINGS_DIR}/vscode-settings-${TARGET_USER}.json"

  log "Target account: ${TARGET_USER}"
  log "SchoolTeX directory: ${TEXDIR}"
}

create_target_work_dir() {
  TARGET_WORK_DIR="$(
    /usr/bin/mktemp -d /private/var/tmp/theisland-schooltex-user.XXXXXX
  )"

  /usr/sbin/chown "${TARGET_USER}:${TARGET_GROUP}" "${TARGET_WORK_DIR}"
  /bin/chmod 0700 "${TARGET_WORK_DIR}"
  log "Target work directory: ${TARGET_WORK_DIR}"
}

check_prerequisites() {
  [[ "$(/usr/bin/uname -m)" == "arm64" ]] ||
    fail "Only Apple Silicon is supported"

  /usr/bin/id "${ADMIN_USER}" >/dev/null 2>&1 ||
    fail "Local account ${ADMIN_USER} does not exist"

  [[ -d "${ADMIN_HOME}" ]] ||
    fail "Home directory ${ADMIN_HOME} does not exist"

  /usr/bin/id -Gn "${ADMIN_USER}" |
    /usr/bin/tr ' ' '\n' |
    /usr/bin/grep -qx admin ||
    fail "${ADMIN_USER} is not an administrator"

  [[ -x "${BREW}" ]] ||
    fail "Homebrew is missing; run step 0 first"

  /usr/bin/xcrun --find clang >/dev/null 2>&1 ||
    fail "Command Line Tools are missing; run step 0 first"

  [[ -x /usr/bin/perl ]] ||
    fail "System Perl is missing; install-tl cannot run"

  [[ -x /opt/homebrew/bin/python3.14 ]] ||
    fail "Python 3.14 is missing; run the normal student or teacher profile first"
}

detect_homebrew_mode() {
  HOMEBREW_ORIGINAL_OWNER="$(/usr/bin/stat -f '%Su' "${BREW_PREFIX}")"
  HOMEBREW_ORIGINAL_GROUP="$(/usr/bin/stat -f '%Sg' "${BREW_PREFIX}")"

  if [[ "${HOMEBREW_ORIGINAL_OWNER}" == "${ADMIN_USER}" ]]; then
    ACCOUNT_MODE="student-or-managed"
    USE_GLOBAL_TEXBIN=0
    TEX_COMMAND_DIR="${CURRENT_TEXBIN}"
  elif [[ "${HOMEBREW_ORIGINAL_OWNER}" == "${TARGET_USER}" ]]; then
    ACCOUNT_MODE="teacher-or-user-owned"
    USE_GLOBAL_TEXBIN=1
    TEX_COMMAND_DIR="/Library/TeX/texbin"
  else
    fail "Unexpected Homebrew owner: ${HOMEBREW_ORIGINAL_OWNER}"
  fi

  SERVICES_COMMAND="$(brew_original_owner command services 2>/dev/null || true)"
  if [[ -n "${SERVICES_COMMAND}" ]]; then
    [[ "${SERVICES_COMMAND}" == "${BREW_PREFIX}"/* &&
       -f "${SERVICES_COMMAND}" &&
       ! -L "${SERVICES_COMMAND}" ]] ||
      fail "Unexpected brew services path: ${SERVICES_COMMAND}"
    SERVICES_ORIGINAL_MODE="$(/usr/bin/stat -f '%Lp' "${SERVICES_COMMAND}")"
  fi

  log "Account mode: ${ACCOUNT_MODE}"
  log "Homebrew owner will remain ${HOMEBREW_ORIGINAL_OWNER}"
  log "TeX command directory: ${TEX_COMMAND_DIR}"
}

validate_brewfile() {
  /usr/bin/awk '
    /^[[:space:]]*$/ { next }
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*cask_args[[:space:]]+appdir:[[:space:]]*"\/Applications"[[:space:]]*$/ { next }
    /^[[:space:]]*(brew|cask)[[:space:]]+"[A-Za-z0-9@+._-]+"[[:space:]]*$/ { next }
    {
      printf "Unsupported Brewfile line %d: %s\n", NR, $0
      bad=1
    }
    END { exit bad }
  ' "$1"
}

validate_packages() {
  /usr/bin/awk '
    /^[[:space:]]*$/ { next }
    /^[[:space:]]*#/ { next }
    /^[A-Za-z0-9][A-Za-z0-9+._-]*$/ { count++; next }
    {
      printf "Unsupported package-manifest line %d: %s\n", NR, $0
      bad=1
    }
    END {
      if (count == 0) bad=1
      exit bad
    }
  ' "$1"
}

prepare_target_vscode_settings() {
  local source="$1"
  local destination="$2"
  local transform_script="${WORK_DIR}/prepare-vscode-settings.py"

  /bin/cat >"${transform_script}" <<'PYTHON'
import json
import sys

source, destination, command_dir = sys.argv[1:]

with open(source, encoding="utf-8") as f:
    data = json.load(f)

if not isinstance(data, dict):
    raise ValueError("Managed VS Code settings must be a JSON object")

def replace(value):
    if isinstance(value, str):
        return value.replace("/Library/TeX/texbin", command_dir)
    if isinstance(value, list):
        return [replace(item) for item in value]
    if isinstance(value, dict):
        return {key: replace(item) for key, item in value.items()}
    return value

with open(destination, "w", encoding="utf-8") as f:
    json.dump(replace(data), f, ensure_ascii=False, indent=2)
    f.write("\n")
PYTHON

  /opt/homebrew/bin/python3.14 \
    "${transform_script}" \
    "${source}" \
    "${destination}" \
    "${TEX_COMMAND_DIR}" \
    >>"${LOG_FILE}" 2>&1 ||
    fail "Cannot prepare target-specific VS Code settings"
}

fetch_managed_files() {
  local remote_brew="${WORK_DIR}/teacher-math.Brewfile"
  local remote_packages="${WORK_DIR}/packages.txt"
  local remote_settings="${WORK_DIR}/vscode-settings.json"
  local prepared_settings="${WORK_DIR}/vscode-settings-prepared.json"
  local sha

  log "Downloading mathematics manifests from GitHub"

  curl_file "${REMOTE_BREWFILE_URL}" "${remote_brew}" >>"${LOG_FILE}" 2>&1 ||
    fail "Cannot download teacher-math.Brewfile"

  curl_file "${REMOTE_PACKAGES_URL}" "${remote_packages}" >>"${LOG_FILE}" 2>&1 ||
    fail "Cannot download SchoolTeX package manifest"

  curl_file "${REMOTE_VSCODE_SETTINGS_URL}" "${remote_settings}" >>"${LOG_FILE}" 2>&1 ||
    fail "Cannot download VS Code settings"

  validate_brewfile "${remote_brew}" >>"${LOG_FILE}" 2>&1 ||
    fail "teacher-math.Brewfile contains unsupported syntax"

  validate_packages "${remote_packages}" >>"${LOG_FILE}" 2>&1 ||
    fail "SchoolTeX package manifest is invalid or empty"

  /opt/homebrew/bin/python3.14 -m json.tool "${remote_settings}" \
    >/dev/null 2>>"${LOG_FILE}" ||
    fail "Downloaded VS Code settings are not valid JSON"

  /usr/bin/grep -Fqx 'brew "ghostscript"' "${remote_brew}" ||
    fail "teacher-math.Brewfile must contain ghostscript"
  /usr/bin/grep -Fqx 'cask "visual-studio-code"' "${remote_brew}" ||
    fail "teacher-math.Brewfile must contain Visual Studio Code"
  /usr/bin/grep -Fqx 'cask "tex-live-utility"' "${remote_brew}" ||
    fail "teacher-math.Brewfile must contain TeX Live Utility"
  /usr/bin/grep -Fqx 'cask "skim"' "${remote_brew}" ||
    fail "teacher-math.Brewfile must contain Skim"

  prepare_target_vscode_settings "${remote_settings}" "${prepared_settings}"

  /bin/mkdir -p \
    "$(/usr/bin/dirname "${BREWFILE}")" \
    "$(/usr/bin/dirname "${PACKAGES_FILE}")" \
    "${VSCODE_SETTINGS_DIR}"

  /usr/bin/install -o root -g wheel -m 0644 "${remote_brew}" "${BREWFILE}"
  /usr/bin/install -o root -g wheel -m 0644 "${remote_packages}" "${PACKAGES_FILE}"
  /usr/bin/install -o root -g wheel -m 0644 "${prepared_settings}" "${VSCODE_SETTINGS_FILE}"

  sha="$(/usr/bin/shasum -a 256 "${BREWFILE}" | /usr/bin/awk '{print $1}')"
  log "Brewfile ready: SHA-256 ${sha}"

  sha="$(/usr/bin/shasum -a 256 "${PACKAGES_FILE}" | /usr/bin/awk '{print $1}')"
  log "Package manifest ready: SHA-256 ${sha}"
}

prepare_homebrew_for_admin() {
  HOMEBREW_PREPARED=1

  if [[ "${HOMEBREW_ORIGINAL_OWNER}" == "${ADMIN_USER}" ]]; then
    return
  fi

  log "Temporarily transferring Homebrew to ${ADMIN_USER}"
  /bin/chmod -RN "${BREW_PREFIX}" 2>/dev/null || true
  /usr/sbin/chown -R "${ADMIN_USER}:${HOMEBREW_ORIGINAL_GROUP}" "${BREW_PREFIX}"
  /bin/chmod -R u+rwX,go-w "${BREW_PREFIX}"
}

refresh_services_command_as_admin() {
  local candidate
  candidate="$(brew_admin command services 2>/dev/null || true)"

  if [[ -n "${candidate}" ]]; then
    [[ "${candidate}" == "${BREW_PREFIX}"/* &&
       -f "${candidate}" &&
       ! -L "${candidate}" ]] ||
      fail "Unexpected brew services path after update: ${candidate}"
    SERVICES_COMMAND="${candidate}"
  fi
}

restore_homebrew_state() {
  local owner

  [[ ${HOMEBREW_PREPARED} -eq 1 ]] || return 0

  refresh_services_command_as_admin

  log "Restoring Homebrew state for ${ACCOUNT_MODE}"
  /bin/chmod -RN "${BREW_PREFIX}" 2>/dev/null || true
  /usr/sbin/chown -R "${HOMEBREW_ORIGINAL_OWNER}:${HOMEBREW_ORIGINAL_GROUP}" "${BREW_PREFIX}"
  /bin/chmod -R u+rwX,go-w "${BREW_PREFIX}"

  if [[ -n "${SERVICES_COMMAND}" && -f "${SERVICES_COMMAND}" ]]; then
    /usr/sbin/chown "${HOMEBREW_ORIGINAL_OWNER}:${HOMEBREW_ORIGINAL_GROUP}" "${SERVICES_COMMAND}"
    if [[ -n "${SERVICES_ORIGINAL_MODE}" ]]; then
      /bin/chmod "${SERVICES_ORIGINAL_MODE}" "${SERVICES_COMMAND}"
    elif [[ "${HOMEBREW_ORIGINAL_OWNER}" == "${ADMIN_USER}" ]]; then
      /bin/chmod 0600 "${SERVICES_COMMAND}"
    else
      /bin/chmod 0644 "${SERVICES_COMMAND}"
    fi
  fi

  owner="$(/usr/bin/stat -f '%Su' "${BREW_PREFIX}")"
  [[ "${owner}" == "${HOMEBREW_ORIGINAL_OWNER}" ]] ||
    fail "Homebrew owner is ${owner}, expected ${HOMEBREW_ORIGINAL_OWNER}"

  if [[ "${HOMEBREW_ORIGINAL_OWNER}" == "${ADMIN_USER}" ]]; then
    if /usr/bin/sudo -n -u "${TARGET_USER}" -H /bin/test -w "${BREW_PREFIX}"; then
      fail "${TARGET_USER} can write to locked Homebrew"
    fi
  else
    /usr/bin/sudo -n -u "${TARGET_USER}" -H /bin/test -w "${BREW_PREFIX}" ||
      fail "${TARGET_USER} cannot write to user-owned Homebrew"
  fi

  HOMEBREW_PREPARED=0
  brew_original_owner --version >/dev/null 2>&1 ||
    fail "Homebrew is not usable after restoring ownership"
}

restore_homebrew_state_best_effort() {
  [[ ${HOMEBREW_PREPARED} -eq 1 ]] || return 0
  [[ -n "${HOMEBREW_ORIGINAL_OWNER}" && -d "${BREW_PREFIX}" ]] || return 0

  /bin/chmod -RN "${BREW_PREFIX}" 2>/dev/null || true
  /usr/sbin/chown -R "${HOMEBREW_ORIGINAL_OWNER}:${HOMEBREW_ORIGINAL_GROUP}" "${BREW_PREFIX}" 2>/dev/null || true
  /bin/chmod -R u+rwX,go-w "${BREW_PREFIX}" 2>/dev/null || true

  if [[ -n "${SERVICES_COMMAND}" && -f "${SERVICES_COMMAND}" ]]; then
    /usr/sbin/chown "${HOMEBREW_ORIGINAL_OWNER}:${HOMEBREW_ORIGINAL_GROUP}" "${SERVICES_COMMAND}" 2>/dev/null || true
    if [[ -n "${SERVICES_ORIGINAL_MODE}" ]]; then
      /bin/chmod "${SERVICES_ORIGINAL_MODE}" "${SERVICES_COMMAND}" 2>/dev/null || true
    elif [[ "${HOMEBREW_ORIGINAL_OWNER}" == "${ADMIN_USER}" ]]; then
      /bin/chmod 0600 "${SERVICES_COMMAND}" 2>/dev/null || true
    else
      /bin/chmod 0644 "${SERVICES_COMMAND}" 2>/dev/null || true
    fi
  fi

  HOMEBREW_PREPARED=0
  log "Restored Homebrew owner ${HOMEBREW_ORIGINAL_OWNER} after failure"
}

reconcile_homebrew() {
  if run_logged \
    "Checking mathematics Brewfile" \
    brew_original_owner bundle check --file="${BREWFILE}" --no-upgrade; then
    log "Mathematics Homebrew software is already installed"
    log "$(brew_original_owner --version | /usr/bin/head -n 1)"
    return
  fi

  acquire_lock "${HOMEBREW_LOCK}" "Homebrew"
  HOMEBREW_LOCKED=1

  prepare_homebrew_for_admin

  if ! run_logged \
    "Rechecking mathematics Brewfile under Homebrew lock" \
    brew_admin bundle check --file="${BREWFILE}" --no-upgrade; then

    run_logged "Refreshing Homebrew metadata" brew_admin update-if-needed ||
      fail "brew update-if-needed failed"

    run_logged \
      "Applying mathematics Brewfile" \
      brew_admin bundle --file="${BREWFILE}" --no-upgrade ||
      fail "brew bundle failed"

    run_logged \
      "Verifying mathematics Brewfile" \
      brew_admin bundle check --file="${BREWFILE}" --no-upgrade ||
      fail "Mathematics Brewfile remains incomplete"
  fi

  restore_homebrew_state

  /bin/rm -rf "${HOMEBREW_LOCK}"
  HOMEBREW_LOCKED=0

  log "$(brew_original_owner --version | /usr/bin/head -n 1)"
  log "Homebrew ownership and access mode preserved"
}

load_packages() {
  local line
  PACKAGES=()

  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="$(
      /usr/bin/printf '%s' "${line}" |
        /usr/bin/sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//'
    )"

    [[ -z "${line}" || "${line}" == \#* ]] && continue
    [[ "${line}" =~ ^[A-Za-z0-9][A-Za-z0-9+._-]*$ ]] ||
      fail "Invalid TeX Live package name: ${line}"
    PACKAGES+=("${line}")
  done <"${PACKAGES_FILE}"

  [[ ${#PACKAGES[@]} -gt 0 ]] || fail "SchoolTeX package manifest is empty"
  log "Package manifest contains ${#PACKAGES[@]} entries"
}

repository_has_failed() {
  local repository="$1"
  local failed

  for failed in "${FAILED_TEXLIVE_REPOSITORIES[@]}"; do
    [[ "${repository}" == "${failed}" ]] && return 0
  done
  return 1
}

mark_repository_failed() {
  local repository="$1"
  [[ -n "${repository}" ]] || return 0
  repository_has_failed "${repository}" ||
    FAILED_TEXLIVE_REPOSITORIES+=("${repository}")
}

repository_is_current_year() {
  [[ -n "${TEXLIVE_REPOSITORY}" ]] || return 1

  /usr/bin/curl \
    --fail \
    --location \
    --silent \
    --show-error \
    --connect-timeout 8 \
    --max-time 20 \
    --proto '=https' \
    --proto-redir '=https' \
    --tlsv1.2 \
    --output /dev/null \
    "${TEXLIVE_REPOSITORY}/TEXLIVE_${TEXLIVE_YEAR}" \
    >>"${LOG_FILE}" 2>&1
}

select_texlive_repository() {
  local candidate
  local marker_file
  local final_url
  local final_repo
  local candidate_number=0

  TEXLIVE_REPOSITORY=""
  log "Selecting a responsive TeX Live ${TEXLIVE_YEAR} repository"

  for candidate in "${TEXLIVE_REPOSITORY_CANDIDATES[@]}"; do
    candidate_number=$((candidate_number + 1))
    marker_file="${WORK_DIR}/texlive-repository-${candidate_number}.marker"

    log "Testing TeX Live repository candidate: ${candidate}"

    final_url="$(
      /usr/bin/curl \
        --fail \
        --location \
        --silent \
        --show-error \
        --connect-timeout 8 \
        --max-time 20 \
        --retry 1 \
        --retry-delay 1 \
        --proto '=https' \
        --proto-redir '=https' \
        --tlsv1.2 \
        --output "${marker_file}" \
        --write-out '%{url_effective}' \
        "${candidate}/TEXLIVE_${TEXLIVE_YEAR}" \
        2>>"${LOG_FILE}"
    )" || true

    if [[ -z "${final_url}" ]]; then
      log "WARNING: repository candidate did not respond: ${candidate}"
      continue
    fi

    final_url="${final_url%%\?*}"
    final_url="${final_url%%\#*}"

    case "${final_url}" in
      */TEXLIVE_"${TEXLIVE_YEAR}")
        final_repo="${final_url%/TEXLIVE_${TEXLIVE_YEAR}}"
        ;;
      *)
        log "WARNING: repository candidate returned unexpected URL: ${final_url}"
        continue
        ;;
    esac

    final_repo="${final_repo%/}"

    [[ "${final_repo}" == https://* ]] || {
      log "WARNING: repository candidate resolved to non-HTTPS URL: ${final_repo}"
      continue
    }

    if repository_has_failed "${final_repo}"; then
      log "Skipping previously failed TeX Live repository: ${final_repo}"
      continue
    fi

    if ! /usr/bin/curl \
      --fail \
      --location \
      --silent \
      --show-error \
      --connect-timeout 8 \
      --max-time 20 \
      --retry 1 \
      --retry-delay 1 \
      --range 0-65535 \
      --proto '=https' \
      --proto-redir '=https' \
      --tlsv1.2 \
      --output /dev/null \
      "${final_repo}/tlpkg/texlive.tlpdb" \
      >>"${LOG_FILE}" 2>&1; then
      log "WARNING: repository cannot serve texlive.tlpdb: ${final_repo}"
      continue
    fi

    TEXLIVE_REPOSITORY="${final_repo}"
    log "Selected TeX Live repository: ${TEXLIVE_REPOSITORY}"
    return 0
  done

  fail "No responsive unused TeX Live ${TEXLIVE_YEAR} repository found"
}

write_marker() {
  /bin/mkdir -p "${SCHOOLTEX_ROOT}"

  /bin/cat >"${MANAGED_MARKER}" <<EOF_MARKER
managed_by=ShashkovS/isl-jamf
account=${TARGET_USER}
year=${TEXLIVE_YEAR}
texdir=${TEXDIR}
EOF_MARKER

  /usr/sbin/chown \
    "${TARGET_USER}:${TARGET_GROUP}" \
    "${SCHOOLTEX_ROOT}" \
    "${MANAGED_MARKER}"

  /bin/chmod 0755 "${SCHOOLTEX_ROOT}"
  /bin/chmod 0644 "${MANAGED_MARKER}"
}

marker_matches() {
  [[ -f "${MANAGED_MARKER}" ]] || return 1

  /usr/bin/grep -Fqx 'managed_by=ShashkovS/isl-jamf' "${MANAGED_MARKER}" || return 1
  /usr/bin/grep -Fqx "year=${TEXLIVE_YEAR}" "${MANAGED_MARKER}" || return 1
  /usr/bin/grep -Fqx "texdir=${TEXDIR}" "${MANAGED_MARKER}" || return 1

  if /usr/bin/grep -Fqx "account=${TARGET_USER}" "${MANAGED_MARKER}"; then
    return 0
  fi

  /usr/bin/grep -Fqx "teacher=${TARGET_USER}" "${MANAGED_MARKER}"
}

texlive_installed() {
  [[ -x "${TEXBIN}/tlmgr" &&
     -x "${TEXBIN}/kpsewhich" &&
     -x "${TEXBIN}/pdftex" ]]
}

verify_texlive_year() {
  local version
  version="$(run_target "${TEXBIN}/tlmgr" --version 2>&1)" || return 1
  /usr/bin/printf '%s\n' "${version}" |
    /usr/bin/grep -Eq "TeX Live.*${TEXLIVE_YEAR}"
}

generate_install_profile() {
  local profile="$1"

  /bin/cat >"${profile}" <<EOF_PROFILE
selected_scheme scheme-small
TEXDIR ${TEXDIR}
TEXMFCONFIG ${TEXDIR}/texmf-config
TEXMFHOME ${TARGET_HOME}/Library/texmf
TEXMFLOCAL ${SCHOOLTEX_ROOT}/texmf-local
TEXMFSYSCONFIG ${TEXDIR}/texmf-config
TEXMFSYSVAR ${TEXDIR}/texmf-var
TEXMFVAR ${TEXDIR}/texmf-var
binary_universal-darwin 1
instopt_adjustpath 0
instopt_adjustrepo 1
instopt_letter 0
instopt_portable 0
instopt_write18_restricted 1
tlpdbopt_autobackup 1
tlpdbopt_create_formats 1
tlpdbopt_install_docfiles 0
tlpdbopt_install_srcfiles 0
EOF_PROFILE
}

download_install_tl() {
  local archive="$1"
  local checksum="$2"
  local attempt=1
  local expected
  local actual

  while (( attempt <= MAX_REPOSITORY_ATTEMPTS )); do
    /bin/rm -f "${archive}" "${checksum}"
    log "Downloading TeX Live ${TEXLIVE_YEAR} network installer from ${TEXLIVE_REPOSITORY}"

    if curl_file "${TEXLIVE_REPOSITORY}/install-tl-unx.tar.gz" "${archive}" \
         >>"${LOG_FILE}" 2>&1 &&
       curl_file "${TEXLIVE_REPOSITORY}/install-tl-unx.tar.gz.sha512" "${checksum}" \
         >>"${LOG_FILE}" 2>&1; then

      expected="$(/usr/bin/awk 'NR==1 {print $1}' "${checksum}" || true)"
      actual="$(/usr/bin/shasum -a 512 "${archive}" | /usr/bin/awk '{print $1}')"

      if [[ "${expected}" =~ ^[0-9a-fA-F]{128}$ &&
            "${actual}" == "${expected}" ]]; then
        log "Verified install-tl SHA-512 ${actual}"
        return 0
      fi

      log "WARNING: install-tl checksum verification failed for ${TEXLIVE_REPOSITORY}"
    else
      log "WARNING: cannot download install-tl from ${TEXLIVE_REPOSITORY}"
    fi

    mark_repository_failed "${TEXLIVE_REPOSITORY}"
    (( attempt < MAX_REPOSITORY_ATTEMPTS )) || break
    select_texlive_repository
    attempt=$((attempt + 1))
  done

  fail "Cannot download a verified TeX Live ${TEXLIVE_YEAR} installer"
}

install_texlive_if_needed() {
  local archive
  local checksum
  local installer_path
  local installer_dir
  local profile
  local extract_dir
  local candidate
  local install_attempt=1

  if texlive_installed; then
    marker_matches ||
      fail "Existing TeX Live installation is not marked as managed by isl-jamf"
    verify_texlive_year ||
      fail "Existing TeX Live installation is not TeX Live ${TEXLIVE_YEAR}"
    write_marker
    log "TeX Live ${TEXLIVE_YEAR} already installed; skipping install-tl"
    return
  fi

  if [[ -e "${TEXDIR}" ]]; then
    marker_matches ||
      fail "${TEXDIR} exists without a matching managed marker; refusing to overwrite it"
    log "Removing incomplete managed TeX Live installation"
    /bin/rm -rf "${TEXDIR}"
  fi

  repository_is_current_year ||
    fail "Selected repository is not serving TeX Live ${TEXLIVE_YEAR}"

  write_marker

  /bin/mkdir -p \
    "${TARGET_HOME}/Library/texmf" \
    "${SCHOOLTEX_ROOT}/texmf-local"

  /usr/sbin/chown -R \
    "${TARGET_USER}:${TARGET_GROUP}" \
    "${SCHOOLTEX_ROOT}" \
    "${TARGET_HOME}/Library/texmf"

  archive="${WORK_DIR}/install-tl-unx.tar.gz"
  checksum="${archive}.sha512"
  download_install_tl "${archive}" "${checksum}"

  extract_dir="${TARGET_WORK_DIR}/installer"
  /bin/mkdir -p "${extract_dir}"

  /usr/bin/tar -xzf "${archive}" -C "${extract_dir}" >>"${LOG_FILE}" 2>&1 ||
    fail "Cannot extract install-tl"

  installer_path=""
  for candidate in "${extract_dir}"/*/install-tl "${extract_dir}"/install-tl; do
    if [[ -f "${candidate}" ]]; then
      installer_path="${candidate}"
      break
    fi
  done

  [[ -n "${installer_path}" ]] || fail "Cannot locate install-tl after extraction"
  installer_dir="$(/usr/bin/dirname "${installer_path}")"

  [[ -f "${installer_dir}/release-texlive.txt" ]] ||
    fail "install-tl archive lacks release-texlive.txt"

  /usr/bin/grep -Eq \
    "version[[:space:]]+${TEXLIVE_YEAR}|TeX Live ${TEXLIVE_YEAR}" \
    "${installer_dir}/release-texlive.txt" ||
    fail "Downloaded installer is not TeX Live ${TEXLIVE_YEAR}"

  profile="${installer_dir}/schooltex.profile"
  generate_install_profile "${profile}"

  /usr/sbin/chown -R "${TARGET_USER}:${TARGET_GROUP}" "${extract_dir}"
  /bin/chmod 0600 "${profile}"

  run_target /bin/test -r "${profile}" ||
    fail "install-tl profile is not readable by ${TARGET_USER}"

  while (( install_attempt <= MAX_REPOSITORY_ATTEMPTS )); do
    if run_logged \
      "Installing TeX Live ${TEXLIVE_YEAR} scheme-small from ${TEXLIVE_REPOSITORY} (attempt ${install_attempt}/${MAX_REPOSITORY_ATTEMPTS})" \
      run_target /bin/bash -c '
        cd "$1" || exit 1
        exec /usr/bin/perl "$2" \
          --no-interaction \
          --scheme scheme-small \
          --texdir "$3" \
          --paper a4 \
          --no-doc-install \
          --no-src-install \
          --profile "$4" \
          --repository "$5"
      ' bash \
        "${installer_dir}" \
        "${installer_path}" \
        "${TEXDIR}" \
        "${profile}" \
        "${TEXLIVE_REPOSITORY}"; then
      break
    fi

    mark_repository_failed "${TEXLIVE_REPOSITORY}"
    (( install_attempt < MAX_REPOSITORY_ATTEMPTS )) ||
      fail "install-tl failed after ${install_attempt} repository attempts"

    log "Removing incomplete TeX Live tree before retry"
    /bin/rm -rf "${TEXDIR}"
    select_texlive_repository
    install_attempt=$((install_attempt + 1))
  done

  texlive_installed ||
    fail "install-tl completed but core TeX Live binaries are missing"

  verify_texlive_year ||
    fail "Installed TeX Live does not report version ${TEXLIVE_YEAR}"

  run_target /usr/bin/touch "${PAPER_MARKER}" ||
    fail "Cannot record A4 paper configuration"

  write_marker
  log "TeX Live ${TEXLIVE_YEAR} installed"
}

set_tlmgr_repository() {
  run_logged \
    "Setting TeX Live repository to ${TEXLIVE_REPOSITORY}" \
    run_target "${TEXBIN}/tlmgr" option repository "${TEXLIVE_REPOSITORY}" ||
    fail "Cannot configure tlmgr repository"
}

tlmgr_network_action() {
  local label="$1"
  local attempt=1
  shift

  while (( attempt <= MAX_REPOSITORY_ATTEMPTS )); do
    if run_logged \
      "${label} (attempt ${attempt}/${MAX_REPOSITORY_ATTEMPTS}, ${TEXLIVE_REPOSITORY})" \
      run_target "${TEXBIN}/tlmgr" "$@"; then
      return 0
    fi

    log "WARNING: ${label} failed using ${TEXLIVE_REPOSITORY}"
    mark_repository_failed "${TEXLIVE_REPOSITORY}"

    (( attempt < MAX_REPOSITORY_ATTEMPTS )) ||
      fail "${label} failed after ${attempt} repository attempts"

    select_texlive_repository
    set_tlmgr_repository
    attempt=$((attempt + 1))
  done
}
find_missing_packages() {
  local installed_file="${WORK_DIR}/installed-texlive-packages.txt"
  local package

  [[ -r "${TEXDIR}/tlpkg/texlive.tlpdb" ]] ||
    fail "Local TeX Live package database is missing"

  /usr/bin/awk '/^name[[:space:]]+/ {print $2}' \
    "${TEXDIR}/tlpkg/texlive.tlpdb" |
    LC_ALL=C /usr/bin/sort -u >"${installed_file}"

  MISSING_PACKAGES=()
  for package in "${PACKAGES[@]}"; do
    /usr/bin/grep -Fqx "${package}" "${installed_file}" ||
      MISSING_PACKAGES+=("${package}")
  done

  log "Missing manifest packages: ${#MISSING_PACKAGES[@]}"
}

verify_manifest_packages() {
  local installed_file="${WORK_DIR}/installed-texlive-packages-after.txt"
  local package
  local missing=()

  /usr/bin/awk '/^name[[:space:]]+/ {print $2}' \
    "${TEXDIR}/tlpkg/texlive.tlpdb" |
    LC_ALL=C /usr/bin/sort -u >"${installed_file}"

  for package in "${PACKAGES[@]}"; do
    /usr/bin/grep -Fqx "${package}" "${installed_file}" || missing+=("${package}")
  done

  [[ ${#missing[@]} -eq 0 ]] ||
    fail "TeX Live manifest remains incomplete: ${missing[*]}"
}

ensure_a4_paper() {
  if [[ -f "${PAPER_MARKER}" ]]; then
    log "A4 paper configuration already recorded"
    return
  fi

  run_logged \
    "Setting A4 paper" \
    run_target "${TEXBIN}/tlmgr" paper a4 ||
    fail "Cannot set A4 paper"

  run_target /usr/bin/touch "${PAPER_MARKER}" ||
    fail "Cannot record A4 paper configuration"
}

reconcile_packages() {
  if ! repository_is_current_year; then
    log "WARNING: selected TeX Live repository stopped responding"
    mark_repository_failed "${TEXLIVE_REPOSITORY}"
    select_texlive_repository
  fi

  load_packages
  set_tlmgr_repository

  run_logged \
    "Disabling TeX source files" \
    run_target "${TEXBIN}/tlmgr" option srcfiles 0 ||
    fail "Cannot disable source files"

  run_logged \
    "Disabling TeX documentation files" \
    run_target "${TEXBIN}/tlmgr" option docfiles 0 ||
    fail "Cannot disable documentation files"

  run_logged \
    "Keeping one tlmgr backup" \
    run_target "${TEXBIN}/tlmgr" option autobackup 1 ||
    fail "Cannot configure tlmgr backups"

  tlmgr_network_action "Updating tlmgr infrastructure" update --self

  find_missing_packages
  if [[ ${#MISSING_PACKAGES[@]} -gt 0 ]]; then
    tlmgr_network_action \
      "Installing ${#MISSING_PACKAGES[@]} missing SchoolTeX manifest packages" \
      install "${MISSING_PACKAGES[@]}"
  else
    log "All SchoolTeX manifest packages are already installed"
  fi

  verify_manifest_packages
  ensure_a4_paper
}

write_shell_path_block() {
  local file="$1"
  local helper="${TARGET_WORK_DIR}/write-shell-path.py"

  if [[ -L "${file}" ]]; then
    log "WARNING: ${file} is a symlink; not modifying it"
    return
  fi

  /bin/cat >"${helper}" <<'PYTHON'
from pathlib import Path
import sys

path = Path(sys.argv[1])
command_dir = sys.argv[2]
start = "# >>> The Island SchoolTeX >>>"
end = "# <<< The Island SchoolTeX <<<"
block = f'{start}\nexport PATH="{command_dir}:${{PATH}}"\n{end}\n'

text = path.read_text(encoding="utf-8") if path.exists() else ""
while True:
    left = text.find(start)
    if left < 0:
        break
    right = text.find(end, left)
    if right < 0:
        text = text[:left].rstrip() + "\n"
        break
    right += len(end)
    if right < len(text) and text[right] == "\n":
        right += 1
    text = text[:left] + text[right:]

text = text.rstrip()
if text:
    text += "\n\n"
text += block
path.write_text(text, encoding="utf-8")
PYTHON

  /usr/sbin/chown "${TARGET_USER}:${TARGET_GROUP}" "${helper}"
  /bin/chmod 0600 "${helper}"

  run_target /opt/homebrew/bin/python3.14 \
    "${helper}" "${file}" "${TEX_COMMAND_DIR}" >>"${LOG_FILE}" 2>&1 ||
    fail "Cannot update PATH in ${file}"

  /usr/sbin/chown "${TARGET_USER}:${TARGET_GROUP}" "${file}"
  /bin/chmod 0644 "${file}"
}

configure_global_texbin_for_teacher() {
  local global_target="${CURRENT_TEXBIN}"
  local existing_target
  local existing_resolved
  local desired_resolved

  /bin/mkdir -p /Library/TeX /etc/paths.d
  /usr/sbin/chown root:wheel /Library/TeX
  /bin/chmod 0755 /Library/TeX

  if [[ -e /Library/TeX/texbin && ! -L /Library/TeX/texbin ]]; then
    fail "/Library/TeX/texbin exists and is not a symbolic link"
  fi

  if [[ -L /Library/TeX/texbin ]]; then
    existing_target="$(/bin/readlink /Library/TeX/texbin)"
    existing_resolved="$(cd /Library/TeX/texbin 2>/dev/null && /bin/pwd -P)" || true
    desired_resolved="$(cd "${TEXBIN}" 2>/dev/null && /bin/pwd -P)" || true

    if [[ "${existing_target}" == "${global_target}" ]]; then
      :
    elif [[ -n "${existing_resolved}" &&
            "${existing_resolved}" == "${desired_resolved}" ]]; then
      log "Migrating /Library/TeX/texbin from ${existing_target} to ${global_target}"
      /bin/rm -f /Library/TeX/texbin
      /bin/ln -s "${global_target}" /Library/TeX/texbin
    else
      fail "/Library/TeX/texbin points to unexpected target ${existing_target}"
    fi
  else
    /bin/ln -s "${global_target}" /Library/TeX/texbin
  fi

  /usr/sbin/chown -h root:wheel /Library/TeX/texbin
  /usr/bin/printf '%s\n' '/Library/TeX/texbin' >/etc/paths.d/20-schooltex
  /usr/sbin/chown root:wheel /etc/paths.d/20-schooltex
  /bin/chmod 0644 /etc/paths.d/20-schooltex
}

remove_unsafe_student_global_texbin_if_managed() {
  local existing_resolved
  local desired_resolved

  [[ -L /Library/TeX/texbin ]] || return 0

  existing_resolved="$(cd /Library/TeX/texbin 2>/dev/null && /bin/pwd -P)" || true
  desired_resolved="$(cd "${TEXBIN}" 2>/dev/null && /bin/pwd -P)" || true

  if [[ -n "${existing_resolved}" &&
        "${existing_resolved}" == "${desired_resolved}" ]]; then
    log "Removing global /Library/TeX/texbin link to student-writable TeX tree"
    /bin/rm -f /Library/TeX/texbin

    if [[ -f /etc/paths.d/20-schooltex ]] &&
       /usr/bin/grep -Fqx '/Library/TeX/texbin' /etc/paths.d/20-schooltex; then
      /bin/rm -f /etc/paths.d/20-schooltex
    fi
  fi
}

configure_links_and_path() {
  if [[ -e "${CURRENT_LINK}" && ! -L "${CURRENT_LINK}" ]]; then
    fail "${CURRENT_LINK} exists and is not a symbolic link"
  fi

  /bin/rm -f "${CURRENT_LINK}"
  run_target /bin/ln -s "${TEXDIR}" "${CURRENT_LINK}" ||
    fail "Cannot create SchoolTeX current link"

  if [[ ${USE_GLOBAL_TEXBIN} -eq 1 ]]; then
    configure_global_texbin_for_teacher
  else
    remove_unsafe_student_global_texbin_if_managed
  fi

  write_shell_path_block "${TARGET_HOME}/.zprofile"
  write_shell_path_block "${TARGET_HOME}/.zshrc"
  write_shell_path_block "${TARGET_HOME}/.bash_profile"

  log "Configured SchoolTeX command path: ${TEX_COMMAND_DIR}"
}

configure_tex_live_utility() {
  run_target /usr/bin/defaults write \
    com.googlecode.mactlmgr.tlu \
    TLMTexBinPathPreferenceKey \
    -string "${TEX_COMMAND_DIR}" ||
    fail "Cannot configure TeX Live Utility"

  log "Configured TeX Live Utility"
}

install_latex_workshop() {
  local code_cli="/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"
  local extensions

  [[ -x "${code_cli}" ]] || fail "Visual Studio Code CLI is missing"

  extensions="$(run_target "${code_cli}" --list-extensions 2>>"${LOG_FILE}" || true)"

  if /usr/bin/printf '%s\n' "${extensions}" |
     /usr/bin/grep -Fxiq 'james-yu.latex-workshop'; then
    log "LaTeX Workshop already installed"
  else
    run_logged \
      "Installing VS Code LaTeX Workshop" \
      run_target "${code_cli}" \
        --install-extension james-yu.latex-workshop --force ||
      fail "Cannot install LaTeX Workshop"
  fi
}

merge_vscode_settings() {
  local settings_dir="${TARGET_HOME}/Library/Application Support/Code/User"
  local settings_file="${settings_dir}/settings.json"
  local backup="${settings_file}.pre-schooltex"
  local merge_script="${TARGET_WORK_DIR}/merge-vscode-settings.py"

  /bin/mkdir -p "${settings_dir}"
  /usr/sbin/chown -R \
    "${TARGET_USER}:${TARGET_GROUP}" \
    "${TARGET_HOME}/Library/Application Support/Code"

  [[ ! -L "${settings_file}" ]] ||
    fail "VS Code settings file is a symbolic link"

  /bin/cat >"${merge_script}" <<'PYTHON'
import json
import os
import sys
import tempfile

settings_path, managed_path, backup_path = sys.argv[1:]


def strip_jsonc_comments(text: str) -> str:
    out = []
    i = 0
    in_string = False
    escaped = False
    while i < len(text):
        ch = text[i]
        nxt = text[i + 1] if i + 1 < len(text) else ""
        if in_string:
            out.append(ch)
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == '"':
                in_string = False
            i += 1
            continue
        if ch == '"':
            in_string = True
            out.append(ch)
            i += 1
            continue
        if ch == "/" and nxt == "/":
            i += 2
            while i < len(text) and text[i] not in "\r\n":
                i += 1
            continue
        if ch == "/" and nxt == "*":
            i += 2
            while i + 1 < len(text) and not (text[i] == "*" and text[i + 1] == "/"):
                if text[i] in "\r\n":
                    out.append(text[i])
                i += 1
            i += 2
            continue
        out.append(ch)
        i += 1
    return "".join(out)


def strip_trailing_commas(text: str) -> str:
    out = []
    i = 0
    in_string = False
    escaped = False
    while i < len(text):
        ch = text[i]
        if in_string:
            out.append(ch)
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == '"':
                in_string = False
            i += 1
            continue
        if ch == '"':
            in_string = True
            out.append(ch)
            i += 1
            continue
        if ch == ",":
            j = i + 1
            while j < len(text) and text[j].isspace():
                j += 1
            if j < len(text) and text[j] in "}]":
                i += 1
                continue
        out.append(ch)
        i += 1
    return "".join(out)


def load_settings(path: str):
    if not os.path.exists(path) or os.path.getsize(path) == 0:
        return {}, False
    text = open(path, encoding="utf-8").read()
    try:
        return json.loads(text), False
    except json.JSONDecodeError:
        normalized = strip_trailing_commas(strip_jsonc_comments(text))
        return json.loads(normalized), True


settings, normalized_jsonc = load_settings(settings_path)
with open(managed_path, encoding="utf-8") as f:
    managed = json.load(f)

if not isinstance(settings, dict) or not isinstance(managed, dict):
    raise ValueError("VS Code settings must be JSON objects")

if os.path.exists(settings_path) and not os.path.exists(backup_path):
    with open(settings_path, "rb") as source, open(backup_path, "wb") as target:
        target.write(source.read())

settings.update(managed)
os.makedirs(os.path.dirname(settings_path), exist_ok=True)
fd, tmp = tempfile.mkstemp(
    prefix="settings.schooltex.",
    suffix=".json",
    dir=os.path.dirname(settings_path),
)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(settings, f, ensure_ascii=False, indent=2)
        f.write("\n")
    os.replace(tmp, settings_path)
finally:
    if os.path.exists(tmp):
        os.unlink(tmp)

print("Normalized existing JSONC settings" if normalized_jsonc else "Merged JSON settings")
PYTHON

  /usr/sbin/chown "${TARGET_USER}:${TARGET_GROUP}" "${merge_script}"
  /bin/chmod 0600 "${merge_script}"

  run_logged \
    "Merging LaTeX Workshop settings" \
    run_target /opt/homebrew/bin/python3.14 \
      "${merge_script}" \
      "${settings_file}" \
      "${VSCODE_SETTINGS_FILE}" \
      "${backup}" ||
    fail "Cannot merge VS Code settings; existing settings.json was left unchanged"

  /usr/sbin/chown "${TARGET_USER}:${TARGET_GROUP}" "${settings_file}"
  /bin/chmod 0644 "${settings_file}"

  if [[ -e "${backup}" ]]; then
    /usr/sbin/chown "${TARGET_USER}:${TARGET_GROUP}" "${backup}"
    /bin/chmod 0644 "${backup}"
  fi

  log "Merged LaTeX Workshop settings"
}

verify_installation() {
  local command
  local texroot
  local wrong_owner

  marker_matches || fail "SchoolTeX managed marker is missing or invalid"
  verify_texlive_year || fail "tlmgr does not report TeX Live ${TEXLIVE_YEAR}"

  /usr/bin/sudo -n -u "${TARGET_USER}" -H \
    /bin/test -w "${TEXDIR}/tlpkg/texlive.tlpdb" ||
    fail "${TARGET_USER} cannot update TeX Live with tlmgr"

  for command in \
    tlmgr \
    kpsewhich \
    latexmk \
    pdflatex \
    xelatex \
    lualatex \
    biber \
    texfindpkg; do
    [[ -x "${TEXBIN}/${command}" ]] ||
      fail "Required TeX command is missing: ${command}"
  done

  [[ -x "${TEX_COMMAND_DIR}/latexmk" ]] ||
    fail "Configured TeX command directory is not usable: ${TEX_COMMAND_DIR}"

  texroot="$(
    run_target "${TEXBIN}/kpsewhich" -var-value=TEXMFROOT 2>>"${LOG_FILE}" || true
  )"
  [[ "${texroot}" == "${TEXDIR}" ]] ||
    fail "kpsewhich reports unexpected TEXMFROOT: ${texroot}"

  wrong_owner="$(
    /usr/bin/find "${TEXDIR}" -xdev ! -user "${TARGET_USER}" -print -quit 2>>"${LOG_FILE}" || true
  )"
  [[ -z "${wrong_owner}" ]] ||
    fail "TeX Live contains a file not owned by ${TARGET_USER}: ${wrong_owner}"

  run_target /usr/bin/env \
    PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
    "${TARGET_SHELL}" -lc \
    'command -v tlmgr >/dev/null && command -v latexmk >/dev/null' ||
    fail "tlmgr or latexmk is not available in a new login shell"

  verify_manifest_packages

  log "Verified TeX Live ${TEXLIVE_YEAR}; tlmgr is writable by ${TARGET_USER} without sudo"
}

cleanup() {
  local rc=$?
  trap - EXIT

  restore_homebrew_state_best_effort

  [[ ${HOMEBREW_LOCKED} -eq 0 ]] ||
    /bin/rm -rf "${HOMEBREW_LOCK}" 2>/dev/null || true

  [[ ${SCHOOLTEX_LOCKED} -eq 0 ]] ||
    /bin/rm -rf "${SCHOOLTEX_LOCK}" 2>/dev/null || true

  log "FINISH: exit code ${rc}"

  if [[ ${rc} -ne 0 ]]; then
    /usr/bin/printf '%s\n' "--- last 80 lines of ${LOG_FILE} ---" \
      >>"${RESULT_FILE}" 2>/dev/null || true
    /usr/bin/tail -n 80 "${LOG_FILE}" >>"${RESULT_FILE}" 2>/dev/null || true
  fi

  /usr/bin/tail -n 200 "${RESULT_FILE}" 2>/dev/null || true

  if [[ -n "${TARGET_WORK_DIR}" && -d "${TARGET_WORK_DIR}" ]]; then
    /bin/rm -rf "${TARGET_WORK_DIR}" 2>/dev/null || true
  fi
  /bin/rm -rf "${WORK_DIR}" 2>/dev/null || true

  exit "${rc}"
}

trap cleanup EXIT

log "START: SchoolTeX ${TEXLIVE_YEAR} mathematics profile"

detect_target_user
check_prerequisites
detect_homebrew_mode

acquire_lock "${SCHOOLTEX_LOCK}" "SchoolTeX"
SCHOOLTEX_LOCKED=1

create_target_work_dir
fetch_managed_files
reconcile_homebrew
select_texlive_repository
install_texlive_if_needed
reconcile_packages
configure_links_and_path
configure_tex_live_utility
install_latex_workshop
merge_vscode_settings
verify_installation

/bin/rm -rf "${SCHOOLTEX_LOCK}"
SCHOOLTEX_LOCKED=0

log "SUCCESS: SchoolTeX ${TEXLIVE_YEAR} mathematics profile installed for ${TARGET_USER}"
