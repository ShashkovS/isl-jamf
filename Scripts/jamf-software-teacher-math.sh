#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

TEXLIVE_YEAR="2026"
ADMIN_USER="admin"
ADMIN_HOME="/Users/${ADMIN_USER}"
BREW_PREFIX="/opt/homebrew"
BREW="${BREW_PREFIX}/bin/brew"
TEXLIVE_REPOSITORY="https://mirror.ctan.org/systems/texlive/tlnet"
REPO_RAW="https://raw.githubusercontent.com/ShashkovS/isl-jamf/main"
REMOTE_BREWFILE_URL="${REPO_RAW}/Brewfiles/teacher-math.Brewfile"
REMOTE_PACKAGES_URL="${REPO_RAW}/SchoolTeX/${TEXLIVE_YEAR}/packages.txt"
REMOTE_VSCODE_SETTINGS_URL="${REPO_RAW}/SchoolTeX/${TEXLIVE_YEAR}/vscode-settings.json"
MANAGED_ROOT="/Library/Application Support/The Island/Jamf"
BREWFILE="${MANAGED_ROOT}/Brewfiles/teacher-math.Brewfile"
PACKAGES_FILE="${MANAGED_ROOT}/SchoolTeX/${TEXLIVE_YEAR}/packages.txt"
VSCODE_SETTINGS_FILE="${MANAGED_ROOT}/SchoolTeX/${TEXLIVE_YEAR}/vscode-settings.json"
LOG_FILE="/var/log/theisland-software-teacher-math.log"
HOMEBREW_LOCK="/private/var/run/theisland-homebrew.lock"
SCHOOLTEX_LOCK="/private/var/run/theisland-schooltex.lock"

WORK_DIR=""
TEACHER_WORK_DIR=""
RESULT_FILE=""
TEACHER_USER=""
TEACHER_HOME=""
TEACHER_GROUP=""
SCHOOLTEX_ROOT=""
TEXDIR=""
TEXBIN=""
CURRENT_LINK=""
MANAGED_MARKER=""
HOMEBREW_LOCKED=0
SCHOOLTEX_LOCKED=0
RESTORE_HOMEBREW=0
SERVICES_COMMAND=""
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
WORK_DIR="$(/usr/bin/mktemp -d /private/var/tmp/theisland-teacher-math.XXXXXX)"
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

  if [[ ${RESTORE_HOMEBREW} -eq 1 && -n "${TEACHER_USER}" && -d "${BREW_PREFIX}" ]]; then
    /bin/chmod -RN "${BREW_PREFIX}" 2>/dev/null || true
    /usr/sbin/chown -R "${TEACHER_USER}:admin" "${BREW_PREFIX}" 2>/dev/null || true
    /bin/chmod -R u+rwX,go-w "${BREW_PREFIX}" 2>/dev/null || true
    if [[ -n "${SERVICES_COMMAND}" && -f "${SERVICES_COMMAND}" ]]; then
      /usr/sbin/chown "${TEACHER_USER}:admin" "${SERVICES_COMMAND}" 2>/dev/null || true
      /bin/chmod 0644 "${SERVICES_COMMAND}" 2>/dev/null || true
    fi
    log "Restored Homebrew ownership to ${TEACHER_USER} after failure"
  fi

  [[ ${HOMEBREW_LOCKED} -eq 0 ]] || /bin/rm -rf "${HOMEBREW_LOCK}" 2>/dev/null || true
  [[ ${SCHOOLTEX_LOCKED} -eq 0 ]] || /bin/rm -rf "${SCHOOLTEX_LOCK}" 2>/dev/null || true

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

brew_admin() {
  /usr/bin/sudo -n -u "${ADMIN_USER}" -H \
    /usr/bin/env \
      HOME="${ADMIN_HOME}" USER="${ADMIN_USER}" LOGNAME="${ADMIN_USER}" \
      PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
      CI=1 NONINTERACTIVE=1 GIT_TERMINAL_PROMPT=0 \
      SUDO_ASKPASS=/usr/bin/false SSH_ASKPASS=/usr/bin/false \
      HOMEBREW_NO_ANALYTICS=1 HOMEBREW_NO_ASK=1 HOMEBREW_NO_AUTO_UPDATE=1 \
      HOMEBREW_NO_ENV_HINTS=1 HOMEBREW_NO_COLOR=1 HOMEBREW_NO_INSTALL_CLEANUP=1 \
      HOMEBREW_NO_UPGRADE_QUIT_CASKS=1 HOMEBREW_BUNDLE_NO_UPGRADE=1 \
      "${BREW}" "$@"
}

run_teacher() {
  /usr/bin/sudo -n -u "${TEACHER_USER}" -H \
    /usr/bin/env \
      HOME="${TEACHER_HOME}" USER="${TEACHER_USER}" LOGNAME="${TEACHER_USER}" \
      PATH="${TEXBIN:-/Library/TeX/texbin}:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
      CI=1 NONINTERACTIVE=1 GIT_TERMINAL_PROMPT=0 \
      SUDO_ASKPASS=/usr/bin/false SSH_ASKPASS=/usr/bin/false \
      TEXLIVE_INSTALL_NO_RESUME=1 TEXLIVE_INSTALL_NO_WELCOME=1 \
      "$@"
}

acquire_lock() {
  local lock="$1" label="$2" pid
  if ! /bin/mkdir "${lock}" 2>/dev/null; then
    pid="$(/bin/cat "${lock}/pid" 2>/dev/null || true)"
    if [[ "${pid}" =~ ^[0-9]+$ ]] && ! /bin/kill -0 "${pid}" 2>/dev/null; then
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
  log "Personal users: ${LOCAL_USERS[*]:-none}"

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
  [[ "${home}" != *$'\n'* && "${home}" != *' '* ]] || fail "Unsupported teacher home path: ${home}"

  TEACHER_HOME="${home}"
  TEACHER_GROUP="$(/usr/bin/id -gn "${TEACHER_USER}")"
  SCHOOLTEX_ROOT="${TEACHER_HOME}/Library/SchoolTeX"
  TEXDIR="${SCHOOLTEX_ROOT}/${TEXLIVE_YEAR}"
  TEXBIN="${TEXDIR}/bin/universal-darwin"
  CURRENT_LINK="${SCHOOLTEX_ROOT}/current"
  MANAGED_MARKER="${SCHOOLTEX_ROOT}/.managed-by-isl-jamf"
  log "Teacher account: ${TEACHER_USER}"
  log "SchoolTeX directory: ${TEXDIR}"
}

create_teacher_work_dir() {
  TEACHER_WORK_DIR="$(
    /usr/bin/mktemp -d /private/var/tmp/theisland-schooltex-teacher.XXXXXX
  )"
  /usr/sbin/chown "${TEACHER_USER}:${TEACHER_GROUP}" "${TEACHER_WORK_DIR}"
  /bin/chmod 0700 "${TEACHER_WORK_DIR}"
  log "Teacher work directory: ${TEACHER_WORK_DIR}"
}

check_prerequisites() {
  [[ "$(/usr/bin/uname -m)" == "arm64" ]] || fail "Only Apple Silicon is supported"
  /usr/bin/id "${ADMIN_USER}" >/dev/null 2>&1 || fail "Local account ${ADMIN_USER} does not exist"
  [[ -d "${ADMIN_HOME}" ]] || fail "Home directory ${ADMIN_HOME} does not exist"
  /usr/bin/id -Gn "${ADMIN_USER}" | /usr/bin/tr ' ' '\n' | /usr/bin/grep -qx admin || fail "${ADMIN_USER} is not an administrator"
  [[ -x "${BREW}" ]] || fail "Homebrew is missing; run step 0 first"
  /usr/bin/xcrun --find clang >/dev/null 2>&1 || fail "Command Line Tools are missing; run step 0 first"
  [[ -x /usr/bin/perl ]] || fail "System Perl is missing; install-tl cannot run"
  [[ -x /opt/homebrew/bin/python3.14 ]] || fail "Python 3.14 is missing; run the general teacher profile first"
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

validate_packages() {
  /usr/bin/awk '
    /^[[:space:]]*$/ { next }
    /^[[:space:]]*#/ { next }
    /^[A-Za-z0-9][A-Za-z0-9+._-]*$/ { count++; next }
    { printf "Unsupported package-manifest line %d: %s\n", NR, $0; bad=1 }
    END { if (count == 0) bad=1; exit bad }
  ' "$1"
}

fetch_managed_files() {
  local remote_brew remote_packages remote_settings sha
  remote_brew="${WORK_DIR}/teacher-math.Brewfile"
  remote_packages="${WORK_DIR}/packages.txt"
  remote_settings="${WORK_DIR}/vscode-settings.json"

  log "Downloading math-teacher manifests from GitHub"
  curl_file "${REMOTE_BREWFILE_URL}" "${remote_brew}" >>"${LOG_FILE}" 2>&1 || fail "Cannot download teacher-math.Brewfile"
  curl_file "${REMOTE_PACKAGES_URL}" "${remote_packages}" >>"${LOG_FILE}" 2>&1 || fail "Cannot download SchoolTeX package manifest"
  curl_file "${REMOTE_VSCODE_SETTINGS_URL}" "${remote_settings}" >>"${LOG_FILE}" 2>&1 || fail "Cannot download VS Code settings"

  validate_brewfile "${remote_brew}" >>"${LOG_FILE}" 2>&1 || fail "teacher-math.Brewfile contains unsupported syntax"
  validate_packages "${remote_packages}" >>"${LOG_FILE}" 2>&1 || fail "SchoolTeX package manifest is invalid or empty"
  /opt/homebrew/bin/python3.14 -m json.tool "${remote_settings}" >/dev/null 2>>"${LOG_FILE}" || fail "Downloaded VS Code settings are not valid JSON"

  /usr/bin/grep -Fqx 'brew "ghostscript"' "${remote_brew}" || fail "teacher-math.Brewfile must contain ghostscript"
  /usr/bin/grep -Fqx 'cask "visual-studio-code"' "${remote_brew}" || fail "teacher-math.Brewfile must contain Visual Studio Code"
  /usr/bin/grep -Fqx 'cask "tex-live-utility"' "${remote_brew}" || fail "teacher-math.Brewfile must contain TeX Live Utility"
  /usr/bin/grep -Fqx 'cask "skim"' "${remote_brew}" || fail "teacher-math.Brewfile must contain Skim"

  /bin/mkdir -p "$(/usr/bin/dirname "${BREWFILE}")" "$(/usr/bin/dirname "${PACKAGES_FILE}")"
  /usr/bin/install -o root -g wheel -m 0644 "${remote_brew}" "${BREWFILE}"
  /usr/bin/install -o root -g wheel -m 0644 "${remote_packages}" "${PACKAGES_FILE}"
  /usr/bin/install -o root -g wheel -m 0644 "${remote_settings}" "${VSCODE_SETTINGS_FILE}"

  sha="$(/usr/bin/shasum -a 256 "${BREWFILE}" | /usr/bin/awk '{print $1}')"
  log "Brewfile ready: SHA-256 ${sha}"
  sha="$(/usr/bin/shasum -a 256 "${PACKAGES_FILE}" | /usr/bin/awk '{print $1}')"
  log "Package manifest ready: SHA-256 ${sha}"
}

prepare_homebrew_for_admin() {
  local owner
  owner="$(/usr/bin/stat -f '%Su' "${BREW_PREFIX}")"
  [[ "${owner}" == "${ADMIN_USER}" || "${owner}" == "${TEACHER_USER}" ]] || fail "Unexpected Homebrew owner: ${owner}"
  RESTORE_HOMEBREW=1
  if [[ "${owner}" == "${TEACHER_USER}" ]]; then
    log "Temporarily transferring Homebrew to ${ADMIN_USER}"
    /bin/chmod -RN "${BREW_PREFIX}" 2>/dev/null || true
    /usr/sbin/chown -R "${ADMIN_USER}:admin" "${BREW_PREFIX}"
    /bin/chmod -R u+rwX,go-w "${BREW_PREFIX}"
  fi
}

restore_homebrew_to_teacher() {
  SERVICES_COMMAND="$(brew_admin command services 2>/dev/null || true)"
  if [[ -n "${SERVICES_COMMAND}" ]]; then
    [[ "${SERVICES_COMMAND}" == "${BREW_PREFIX}"/* && -f "${SERVICES_COMMAND}" && ! -L "${SERVICES_COMMAND}" ]] || fail "Unexpected brew services path: ${SERVICES_COMMAND}"
  fi

  log "Restoring Homebrew ownership to ${TEACHER_USER}"
  /bin/chmod -RN "${BREW_PREFIX}" 2>/dev/null || true
  /usr/sbin/chown -R "${TEACHER_USER}:admin" "${BREW_PREFIX}"
  /bin/chmod -R u+rwX,go-w "${BREW_PREFIX}"
  if [[ -n "${SERVICES_COMMAND}" ]]; then
    /usr/sbin/chown "${TEACHER_USER}:admin" "${SERVICES_COMMAND}"
    /bin/chmod 0644 "${SERVICES_COMMAND}"
  fi
  RESTORE_HOMEBREW=0
  /usr/bin/sudo -n -u "${TEACHER_USER}" -H /bin/test -w "${BREW_PREFIX}" || fail "${TEACHER_USER} cannot write to Homebrew"
}

reconcile_homebrew() {
  acquire_lock "${HOMEBREW_LOCK}" "Homebrew"
  HOMEBREW_LOCKED=1
  prepare_homebrew_for_admin

  if run_logged "Checking math-teacher Brewfile" brew_admin bundle check --file="${BREWFILE}" --no-upgrade; then
    log "Math-teacher Homebrew software is already installed"
  else
    run_logged "Refreshing Homebrew metadata" brew_admin update-if-needed || fail "brew update-if-needed failed"
    run_logged "Applying math-teacher Brewfile" brew_admin bundle --file="${BREWFILE}" --no-upgrade || fail "brew bundle failed"
    run_logged "Verifying math-teacher Brewfile" brew_admin bundle check --file="${BREWFILE}" --no-upgrade || fail "Math-teacher Brewfile remains incomplete"
  fi

  log "$(brew_admin --version | /usr/bin/head -n 1)"
  restore_homebrew_to_teacher
  /bin/rm -rf "${HOMEBREW_LOCK}"
  HOMEBREW_LOCKED=0
}

load_packages() {
  local line
  PACKAGES=()
  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="$(/usr/bin/printf '%s' "${line}" | /usr/bin/sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
    [[ -z "${line}" || "${line}" == \#* ]] && continue
    [[ "${line}" =~ ^[A-Za-z0-9][A-Za-z0-9+._-]*$ ]] || fail "Invalid TeX Live package name: ${line}"
    PACKAGES+=("${line}")
  done <"${PACKAGES_FILE}"
  [[ ${#PACKAGES[@]} -gt 0 ]] || fail "SchoolTeX package manifest is empty"
  log "Package manifest contains ${#PACKAGES[@]} entries"
}

repository_is_current_year() {
  curl_file "${TEXLIVE_REPOSITORY}/TEXLIVE_${TEXLIVE_YEAR}" /dev/null >>"${LOG_FILE}" 2>&1
}

write_marker() {
  /bin/mkdir -p "${SCHOOLTEX_ROOT}"
  /bin/cat >"${MANAGED_MARKER}" <<EOF_MARKER
managed_by=ShashkovS/isl-jamf
teacher=${TEACHER_USER}
year=${TEXLIVE_YEAR}
texdir=${TEXDIR}
EOF_MARKER
  /usr/sbin/chown "${TEACHER_USER}:${TEACHER_GROUP}" "${SCHOOLTEX_ROOT}" "${MANAGED_MARKER}"
  /bin/chmod 0755 "${SCHOOLTEX_ROOT}"
  /bin/chmod 0644 "${MANAGED_MARKER}"
}

marker_matches() {
  [[ -f "${MANAGED_MARKER}" ]] || return 1
  /usr/bin/grep -Fqx 'managed_by=ShashkovS/isl-jamf' "${MANAGED_MARKER}" &&
    /usr/bin/grep -Fqx "teacher=${TEACHER_USER}" "${MANAGED_MARKER}" &&
    /usr/bin/grep -Fqx "year=${TEXLIVE_YEAR}" "${MANAGED_MARKER}" &&
    /usr/bin/grep -Fqx "texdir=${TEXDIR}" "${MANAGED_MARKER}"
}

texlive_installed() {
  [[ -x "${TEXBIN}/tlmgr" && -x "${TEXBIN}/kpsewhich" && -x "${TEXBIN}/pdftex" ]]
}

verify_texlive_year() {
  local version
  version="$(run_teacher "${TEXBIN}/tlmgr" --version 2>&1)" || return 1
  /usr/bin/printf '%s\n' "${version}" | /usr/bin/grep -Eq "TeX Live.*${TEXLIVE_YEAR}"
}

generate_install_profile() {
  local profile="$1"
  /bin/cat >"${profile}" <<EOF_PROFILE
selected_scheme scheme-small
TEXDIR ${TEXDIR}
TEXMFCONFIG ${TEXDIR}/texmf-config
TEXMFHOME ${TEACHER_HOME}/Library/texmf
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

install_texlive_if_needed() {
  local archive checksum expected actual installer_path installer_dir profile extract_dir

  if texlive_installed; then
    marker_matches || fail "Existing TeX Live installation is not marked as managed by isl-jamf"
    verify_texlive_year || fail "Existing TeX Live installation is not TeX Live ${TEXLIVE_YEAR}"
    log "TeX Live ${TEXLIVE_YEAR} already installed; skipping install-tl"
    return
  fi

  if [[ -e "${TEXDIR}" ]]; then
    marker_matches || fail "${TEXDIR} exists without a matching managed marker; refusing to overwrite it"
    log "Removing incomplete managed TeX Live installation"
    /bin/rm -rf "${TEXDIR}"
  fi

  repository_is_current_year || fail "Configured repository is not serving TeX Live ${TEXLIVE_YEAR}"
  write_marker
  /bin/mkdir -p "${TEACHER_HOME}/Library/texmf" "${SCHOOLTEX_ROOT}/texmf-local"
  /usr/sbin/chown -R "${TEACHER_USER}:${TEACHER_GROUP}" "${SCHOOLTEX_ROOT}" "${TEACHER_HOME}/Library/texmf"

  archive="${WORK_DIR}/install-tl-unx.tar.gz"
  checksum="${archive}.sha512"
  log "Downloading TeX Live ${TEXLIVE_YEAR} network installer"
  curl_file "${TEXLIVE_REPOSITORY}/install-tl-unx.tar.gz" "${archive}" >>"${LOG_FILE}" 2>&1 || fail "Cannot download install-tl"
  curl_file "${TEXLIVE_REPOSITORY}/install-tl-unx.tar.gz.sha512" "${checksum}" >>"${LOG_FILE}" 2>&1 || fail "Cannot download install-tl SHA-512"
  [[ -s "${archive}" && -s "${checksum}" ]] || fail "Downloaded install-tl files are empty"

  expected="$(/usr/bin/awk 'NR==1 {print $1}' "${checksum}" || true)"
  actual="$(/usr/bin/shasum -a 512 "${archive}" | /usr/bin/awk '{print $1}')"
  [[ "${expected}" =~ ^[0-9a-fA-F]{128}$ && "${actual}" == "${expected}" ]] || fail "install-tl SHA-512 verification failed"
  log "Verified install-tl SHA-512 ${actual}"

  extract_dir="${TEACHER_WORK_DIR}/installer"
  /bin/mkdir -p "${extract_dir}"
  /usr/bin/tar -xzf "${archive}" -C "${extract_dir}" >>"${LOG_FILE}" 2>&1 || fail "Cannot extract install-tl"
  installer_path=""
  for candidate in "${extract_dir}"/*/install-tl "${extract_dir}"/install-tl; do
    if [[ -f "${candidate}" ]]; then
      installer_path="${candidate}"
      break
    fi
  done
  [[ -n "${installer_path}" ]] || fail "Cannot locate install-tl after extraction"
  installer_dir="$(/usr/bin/dirname "${installer_path}")"
  [[ -f "${installer_dir}/release-texlive.txt" ]] || fail "install-tl archive lacks release-texlive.txt"
  /usr/bin/grep -Eq "version[[:space:]]+${TEXLIVE_YEAR}|TeX Live ${TEXLIVE_YEAR}" "${installer_dir}/release-texlive.txt" || fail "Downloaded installer is not TeX Live ${TEXLIVE_YEAR}"

  profile="${installer_dir}/schooltex.profile"
  generate_install_profile "${profile}"
  /usr/sbin/chown -R "${TEACHER_USER}:${TEACHER_GROUP}" "${extract_dir}"
  /bin/chmod 0600 "${profile}"
  run_teacher /bin/test -r "${profile}" || fail "install-tl profile is not readable by ${TEACHER_USER}"

  run_logged "Installing TeX Live ${TEXLIVE_YEAR} scheme-small" \
    run_teacher /bin/bash -c '
      cd "$1" || exit 1
      exec /usr/bin/perl "$2" \
        --no-interaction \
        --scheme scheme-small \
        --texdir "$3" \
        --no-doc-install \
        --no-src-install \
        --profile "$4" \
        --repository "$5"
    ' bash "${installer_dir}" "${installer_path}" "${TEXDIR}" "${profile}" "${TEXLIVE_REPOSITORY}" || fail "install-tl failed"

  texlive_installed || fail "install-tl completed but core TeX Live binaries are missing"
  verify_texlive_year || fail "Installed TeX Live does not report version ${TEXLIVE_YEAR}"
  log "TeX Live ${TEXLIVE_YEAR} installed"
}

reconcile_packages() {
  repository_is_current_year || fail "Configured repository is no longer serving TeX Live ${TEXLIVE_YEAR}"
  load_packages

  run_logged "Setting TeX Live repository" run_teacher "${TEXBIN}/tlmgr" option repository "${TEXLIVE_REPOSITORY}" || fail "Cannot configure tlmgr repository"
  run_logged "Disabling TeX source files" run_teacher "${TEXBIN}/tlmgr" option srcfiles 0 || fail "Cannot disable source files"
  run_logged "Disabling TeX documentation files" run_teacher "${TEXBIN}/tlmgr" option docfiles 0 || fail "Cannot disable documentation files"
  run_logged "Keeping one tlmgr backup" run_teacher "${TEXBIN}/tlmgr" option autobackup 1 || fail "Cannot configure tlmgr backups"
  run_logged "Updating tlmgr infrastructure" run_teacher "${TEXBIN}/tlmgr" update --self || fail "tlmgr self-update failed"
  run_logged "Installing SchoolTeX package manifest" run_teacher "${TEXBIN}/tlmgr" install "${PACKAGES[@]}" || fail "tlmgr package installation failed"
  run_logged "Setting A4 paper" run_teacher "${TEXBIN}/tlmgr" paper a4 || fail "Cannot set A4 paper"
}

configure_links_and_path() {
  local global_target zprofile path_line
  /bin/mkdir -p /Library/TeX /etc/paths.d
  /usr/sbin/chown root:wheel /Library/TeX
  /bin/chmod 0755 /Library/TeX

  if [[ -e "${CURRENT_LINK}" && ! -L "${CURRENT_LINK}" ]]; then
    fail "${CURRENT_LINK} exists and is not a symbolic link"
  fi
  /bin/rm -f "${CURRENT_LINK}"
  run_teacher /bin/ln -s "${TEXDIR}" "${CURRENT_LINK}" || fail "Cannot create SchoolTeX current link"

  global_target="${CURRENT_LINK}/bin/universal-darwin"
  if [[ -e /Library/TeX/texbin && ! -L /Library/TeX/texbin ]]; then
    fail "/Library/TeX/texbin exists and is not a symbolic link"
  fi
  if [[ -L /Library/TeX/texbin ]]; then
    [[ "$(/bin/readlink /Library/TeX/texbin)" == "${global_target}" ]] || fail "/Library/TeX/texbin points to an unexpected installation"
  else
    /bin/ln -s "${global_target}" /Library/TeX/texbin
  fi
  /usr/sbin/chown -h root:wheel /Library/TeX/texbin

  /usr/bin/printf '%s\n' '/Library/TeX/texbin' >/etc/paths.d/20-schooltex
  /usr/sbin/chown root:wheel /etc/paths.d/20-schooltex
  /bin/chmod 0644 /etc/paths.d/20-schooltex

  zprofile="${TEACHER_HOME}/.zprofile"
  path_line='export PATH="/Library/TeX/texbin:${PATH}"'
  if [[ -L "${zprofile}" ]]; then
    log "WARNING: ${zprofile} is a symlink; not modifying it"
  else
    /usr/bin/grep -Fqx "${path_line}" "${zprofile}" 2>/dev/null || /usr/bin/printf '\n%s\n' "${path_line}" >>"${zprofile}"
    /usr/sbin/chown "${TEACHER_USER}:${TEACHER_GROUP}" "${zprofile}"
    /bin/chmod 0644 "${zprofile}"
  fi
  log "Configured /Library/TeX/texbin and PATH"
}

configure_tex_live_utility() {
  run_teacher /usr/bin/defaults write com.googlecode.mactlmgr.tlu TLMTexBinPathPreferenceKey -string /Library/TeX/texbin || fail "Cannot configure TeX Live Utility"
  log "Configured TeX Live Utility"
}

install_latex_workshop() {
  local code_cli extensions
  code_cli="/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"
  [[ -x "${code_cli}" ]] || fail "Visual Studio Code CLI is missing"
  extensions="$(run_teacher "${code_cli}" --list-extensions 2>>"${LOG_FILE}" || true)"
  if /usr/bin/printf '%s\n' "${extensions}" | /usr/bin/grep -Fxiq 'james-yu.latex-workshop'; then
    log "LaTeX Workshop already installed"
  else
    run_logged "Installing VS Code LaTeX Workshop" run_teacher "${code_cli}" --install-extension james-yu.latex-workshop --force || fail "Cannot install LaTeX Workshop"
  fi
}

merge_vscode_settings() {
  local settings_dir settings_file backup
  settings_dir="${TEACHER_HOME}/Library/Application Support/Code/User"
  settings_file="${settings_dir}/settings.json"
  backup="${settings_file}.pre-schooltex"

  /bin/mkdir -p "${settings_dir}"
  /usr/sbin/chown -R "${TEACHER_USER}:${TEACHER_GROUP}" "${TEACHER_HOME}/Library/Application Support/Code"
  [[ ! -L "${settings_file}" ]] || fail "VS Code settings file is a symbolic link"

  if [[ ! -e "${settings_file}" || ! -s "${settings_file}" ]]; then
    /usr/bin/install -o "${TEACHER_USER}" -g "${TEACHER_GROUP}" -m 0644 "${VSCODE_SETTINGS_FILE}" "${settings_file}"
    log "Installed new VS Code settings.json"
    return
  fi

  if ! run_teacher /opt/homebrew/bin/python3.14 -m json.tool "${settings_file}" >/dev/null 2>>"${LOG_FILE}"; then
    /usr/bin/install -o "${TEACHER_USER}" -g "${TEACHER_GROUP}" -m 0644 "${VSCODE_SETTINGS_FILE}" "${settings_dir}/settings.schooltex.json"
    log "WARNING: existing settings.json uses JSONC or invalid JSON; left it unchanged and wrote settings.schooltex.json"
    return
  fi

  [[ -e "${backup}" ]] || /bin/cp -p "${settings_file}" "${backup}"
  /usr/sbin/chown "${TEACHER_USER}:${TEACHER_GROUP}" "${backup}"

  run_logged "Merging LaTeX Workshop settings" run_teacher /opt/homebrew/bin/python3.14 - "${settings_file}" "${VSCODE_SETTINGS_FILE}" <<'PYTHON' || fail "Cannot merge VS Code settings"
import json
import os
import sys
import tempfile

settings_path, managed_path = sys.argv[1:]
with open(settings_path, encoding="utf-8") as f:
    settings = json.load(f)
with open(managed_path, encoding="utf-8") as f:
    managed = json.load(f)
if not isinstance(settings, dict) or not isinstance(managed, dict):
    raise ValueError("VS Code settings must be JSON objects")
settings.update(managed)
fd, tmp = tempfile.mkstemp(prefix="settings.schooltex.", suffix=".json", dir=os.path.dirname(settings_path))
try:
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(settings, f, ensure_ascii=False, indent=2)
        f.write("\n")
    os.replace(tmp, settings_path)
finally:
    if os.path.exists(tmp):
        os.unlink(tmp)
PYTHON
  /usr/sbin/chown "${TEACHER_USER}:${TEACHER_GROUP}" "${settings_file}"
  /bin/chmod 0644 "${settings_file}"
  log "Merged LaTeX Workshop settings"
}

verify_installation() {
  local command texroot latexmk_info
  marker_matches || fail "SchoolTeX managed marker is missing or invalid"
  verify_texlive_year || fail "tlmgr does not report TeX Live ${TEXLIVE_YEAR}"
  /usr/bin/sudo -n -u "${TEACHER_USER}" -H /bin/test -w "${TEXDIR}/tlpkg/texlive.tlpdb" || fail "${TEACHER_USER} cannot update TeX Live"

  for command in tlmgr kpsewhich latexmk pdflatex xelatex lualatex biber texfindpkg; do
    [[ -x "${TEXBIN}/${command}" ]] || fail "Required TeX command is missing: ${command}"
  done
  [[ -x /Library/TeX/texbin/latexmk ]] || fail "/Library/TeX/texbin is not usable"

  texroot="$(run_teacher "${TEXBIN}/kpsewhich" -var-value=TEXMFROOT 2>>"${LOG_FILE}" || true)"
  [[ "${texroot}" == "${TEXDIR}" ]] || fail "kpsewhich reports unexpected TEXMFROOT: ${texroot}"
  latexmk_info="$(run_teacher "${TEXBIN}/tlmgr" info --only-installed latexmk 2>>"${LOG_FILE}" || true)"
  /usr/bin/printf '%s\n' "${latexmk_info}" | /usr/bin/grep -Fq 'installed: Yes' || fail "latexmk is not registered as installed in tlmgr"
  log "Verified TeX Live ${TEXLIVE_YEAR}; tlmgr is writable by ${TEACHER_USER} without sudo"
}

log "START: math-teacher SchoolTeX ${TEXLIVE_YEAR} profile"
detect_teacher
create_teacher_work_dir
check_prerequisites
fetch_managed_files
reconcile_homebrew

acquire_lock "${SCHOOLTEX_LOCK}" "SchoolTeX"
SCHOOLTEX_LOCKED=1
install_texlive_if_needed
reconcile_packages
configure_links_and_path
configure_tex_live_utility
install_latex_workshop
merge_vscode_settings
verify_installation
/bin/rm -rf "${SCHOOLTEX_LOCK}"
SCHOOLTEX_LOCKED=0

log "SUCCESS: math-teacher SchoolTeX ${TEXLIVE_YEAR} profile installed"
