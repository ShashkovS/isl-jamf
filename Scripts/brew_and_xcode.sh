#!/bin/bash
# Jamf School bootstrap for Apple Silicon Macs:
# 1. silently install Xcode Command Line Tools if missing;
# 2. install the current official Homebrew.pkg for local user "admin";
# 3. make /opt/homebrew writable only by "admin".


set -Eeuo pipefail
IFS=$'\n\t'

ADMIN_USER="admin"
ADMIN_HOME="/Users/${ADMIN_USER}"
CLT_DIR="/Library/Developer/CommandLineTools"
CLT_MARKER="/tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress"
BREW_PREFIX="/opt/homebrew"
BREW_BIN="${BREW_PREFIX}/bin/brew"
BREW_MIN_VERSION="6.0.0"
BREW_PKG_VERSION="6.0.18"
BREW_PKG_URL="https://github.com/Homebrew/brew/releases/download/${BREW_PKG_VERSION}/Homebrew.pkg"
BREW_PKG_RECEIPT="sh.brew.homebrew"
BREW_SIGNER_TEAM_ID="927JGANW46"
BREW_PKG_USER_PLIST="/var/tmp/.homebrew_pkg_user.plist"
LOG_FILE="/var/log/theisland-homebrew-bootstrap.log"
TMP_DIR=""
RESULT_FILE=""
CLT_MARKER_CREATED=0
BREW_VERSION=""
BREW_SERVICES_COMMAND=""
INSTALLED_BY_THIS_RUN=0
LAST_ERROR=""

ensure_tmp_dir() {
  if [[ -z "${TMP_DIR}" ]]; then
    TMP_DIR="$(/usr/bin/mktemp -d /private/var/tmp/theisland-homebrew.XXXXXX)"
    /usr/sbin/chown root:wheel "${TMP_DIR}"
    /bin/chmod 0700 "${TMP_DIR}"
    RESULT_FILE="${TMP_DIR}/jamf-result.log"
    /usr/bin/install -o root -g wheel -m 0600 /dev/null "${RESULT_FILE}"
  fi
}

log() {
  local line
  line="$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ') $*"
  /bin/echo "${line}" >>"${LOG_FILE}" 2>/dev/null || true
  if [[ -n "${RESULT_FILE}" ]]; then
    /bin/echo "${line}" >>"${RESULT_FILE}" 2>/dev/null || true
  fi
}

detail_file() {
  local file="$1"
  [[ -f "${file}" ]] || return 0
  /bin/cat "${file}" >>"${LOG_FILE}" 2>/dev/null || true
}

error_tail() {
  local file="$1"
  local count="${2:-8}"
  local line
  [[ -f "${file}" ]] || return 0
  while IFS= read -r line; do
    log "DETAIL: ${line}"
  done < <(/usr/bin/tail -n "${count}" "${file}" 2>/dev/null || true)
}

die() {
  LAST_ERROR="$*"
  log "ERROR: ${LAST_ERROR}"
  exit 1
}

on_error() {
  local rc="$1"
  local line="$2"
  local command="$3"
  if [[ -z "${LAST_ERROR}" ]]; then
    LAST_ERROR="Unexpected command failure at line ${line}: ${command}"
    log "ERROR: ${LAST_ERROR} (exit ${rc})"
  fi
}

cleanup() {
  local rc=$?
  local summary=""
  trap - ERR EXIT

  if [[ ${rc} -eq 0 ]]; then
    log "FINISH: exit code 0"
  else
    if [[ -z "${LAST_ERROR}" ]]; then
      LAST_ERROR="Unexpected failure"
      log "ERROR: ${LAST_ERROR}"
    fi
    log "FINISH: exit code ${rc}"
  fi

  if [[ -n "${RESULT_FILE}" && -f "${RESULT_FILE}" ]]; then
    /usr/bin/tail -n 40 "${RESULT_FILE}"
  else
    /bin/echo "Homebrew bootstrap finished with exit code ${rc}"
  fi

  if [[ ${rc} -ne 0 ]]; then
    summary="FAILED: ${LAST_ERROR}; full log: ${LOG_FILE}"
    /bin/echo "${summary}" >&2
  fi

  if [[ ${CLT_MARKER_CREATED} -eq 1 ]]; then
    /bin/rm -rf "${CLT_MARKER}" 2>/dev/null || true
  fi
  /bin/rm -rf "${BREW_PKG_USER_PLIST}" 2>/dev/null || true
  if [[ -n "${TMP_DIR}" && -d "${TMP_DIR}" ]]; then
    /bin/rm -rf "${TMP_DIR}" 2>/dev/null || true
  fi
  exit "${rc}"
}

run_logged() {
  local name="$1"
  local output rc=0
  shift
  ensure_tmp_dir
  output="${TMP_DIR}/${name}.log"
  "$@" >"${output}" 2>&1 || rc=$?
  {
    /bin/echo "===== ${name}: exit ${rc} ====="
    /bin/cat "${output}"
  } >>"${LOG_FILE}" 2>/dev/null || true
  return "${rc}"
}

version_at_least() {
  local current="$1"
  local minimum="$2"
  local first
  [[ "${current}" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]] || return 1
  [[ "${minimum}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  first="$(
    /usr/bin/printf '%s\n%s\n' "${minimum}" "${current}" |
      LC_ALL=C /usr/bin/sort -V |
      /usr/bin/head -n 1
  )"
  [[ "${first}" == "${minimum}" ]]
}

brew_as_admin() {
  /usr/bin/sudo -u "${ADMIN_USER}" -H \
    /usr/bin/env \
      HOME="${ADMIN_HOME}" \
      USER="${ADMIN_USER}" \
      LOGNAME="${ADMIN_USER}" \
      PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
      HOMEBREW_NO_ANALYTICS=1 \
      HOMEBREW_NO_ASK=1 \
      HOMEBREW_NO_AUTO_UPDATE=1 \
      HOMEBREW_NO_ENV_HINTS=1 \
      HOMEBREW_NO_COLOR=1 \
      NONINTERACTIVE=1 \
    "${BREW_BIN}" "$@"
}

clt_installed() {
  [[ -x "${CLT_DIR}/usr/bin/git" && -x "${CLT_DIR}/usr/bin/clang" ]]
}

developer_tools_ready() {
  /usr/bin/xcrun --find clang >/dev/null 2>&1 &&
    /usr/bin/xcrun --sdk macosx --show-sdk-path >/dev/null 2>&1
}

extract_clt_label() {
  /usr/bin/sed -nE \
    -e 's/^[[:space:]]*\*[[:space:]]*Label:[[:space:]]*(Command Line Tools.*)$/\1/p' \
    -e 's/^[[:space:]]*\*[[:space:]]*(Command Line Tools.*)$/\1/p' \
    "$1" |
    /usr/bin/sed -E -e 's/[[:space:]]+$//' -e '/[Bb][Ee][Tt][Aa]/d' |
    /usr/bin/awk '!seen[$0]++' |
    LC_ALL=C /usr/bin/sort -V |
    /usr/bin/tail -n 1
}

install_clt_if_needed() {
  local attempt clt_label="" list_log install_log

  if developer_tools_ready; then
    log "Developer tools already available at $(/usr/bin/xcode-select --print-path 2>/dev/null || /bin/echo unknown); skipping CLT installation"
    return
  fi

  if clt_installed; then
    log "Command Line Tools exist but are not active; selecting ${CLT_DIR}"
    /usr/bin/xcode-select --switch "${CLT_DIR}"
  else
    ensure_tmp_dir
    /bin/rm -rf "${CLT_MARKER}"
    CLT_MARKER_CREATED=1
    /usr/bin/install -o root -g wheel -m 0600 /dev/null "${CLT_MARKER}"

    [[ -f "${CLT_MARKER}" && ! -L "${CLT_MARKER}" ]] ||
      die "Cannot create a safe Command Line Tools marker"

    [[ "$(/usr/bin/stat -f '%Su:%Sg:%Lp' "${CLT_MARKER}")" == "root:wheel:600" ]] ||
      die "Unsafe Command Line Tools marker owner or mode"

    for attempt in 1 2 3; do
      list_log="${TMP_DIR}/softwareupdate-list-${attempt}.log"
      log "Searching Apple Software Update for Command Line Tools (${attempt}/3)"
      run_logged "softwareupdate-list-${attempt}" /usr/sbin/softwareupdate -l || true
      clt_label="$(extract_clt_label "${list_log}")" || true
      [[ -n "${clt_label}" ]] && break
      [[ ${attempt} -eq 3 ]] || /bin/sleep 10
    done

    [[ -n "${clt_label}" ]] ||
      die "Apple Software Update did not offer Command Line Tools"

    install_log="${TMP_DIR}/softwareupdate-install.log"
    log "Installing ${clt_label}"

    if ! run_logged "softwareupdate-install" /usr/sbin/softwareupdate -i "${clt_label}"; then
      error_tail "${install_log}" 12
      clt_installed || die "Command Line Tools installation failed"
      log "softwareupdate returned a failure code, but Command Line Tools are present"
    fi

    clt_installed ||
      die "Command Line Tools installation completed but clang/git are missing"

    /bin/rm -rf "${CLT_MARKER}"
    CLT_MARKER_CREATED=0
  fi

  if ! developer_tools_ready; then
    log "Selecting ${CLT_DIR} as the active developer directory"
    /usr/bin/xcode-select --switch "${CLT_DIR}"
  fi

  developer_tools_ready ||
    die "xcrun cannot find clang or the macOS SDK"

  log "Developer tools ready: $(/usr/bin/xcrun clang --version | /usr/bin/head -n 1)"
  log "Active developer directory: $(/usr/bin/xcode-select --print-path)"
}

write_homebrew_configuration() {
  /bin/mkdir -p /etc/homebrew /etc/paths.d

  /bin/cat >/etc/homebrew/brew.env <<'EOF_BREW_ENV'
HOMEBREW_SYSTEM_ENV_TAKES_PRIORITY=1
HOMEBREW_NO_ANALYTICS=1
HOMEBREW_NO_ASK=1
HOMEBREW_NO_AUTO_UPDATE=1
HOMEBREW_NO_ENV_HINTS=1
EOF_BREW_ENV

  /usr/sbin/chown root:wheel /etc/homebrew/brew.env
  /bin/chmod 0644 /etc/homebrew/brew.env

  /bin/cat >/etc/paths.d/10-homebrew <<'EOF_PATHS'
/opt/homebrew/bin
/opt/homebrew/sbin
EOF_PATHS

  /usr/sbin/chown root:wheel /etc/paths.d/10-homebrew
  /bin/chmod 0644 /etc/paths.d/10-homebrew
}

verify_homebrew_package() {
  local pkg="$1"
  local signature_log="${TMP_DIR}/pkg-signature.log"
  local spctl_log="${TMP_DIR}/pkg-spctl.log"
  local sha256

  run_logged "pkg-signature" /usr/sbin/pkgutil --check-signature "${pkg}" || {
    error_tail "${signature_log}" 12
    die "Homebrew.pkg signature verification failed"
  }

  /usr/bin/grep -Eq "Developer ID Installer: .+\\(${BREW_SIGNER_TEAM_ID}\\)" "${signature_log}" || {
    error_tail "${signature_log}" 12
    die "Homebrew.pkg is not signed by expected Team ID ${BREW_SIGNER_TEAM_ID}"
  }

  run_logged "pkg-spctl" /usr/sbin/spctl --assess --type install --verbose=2 "${pkg}" || {
    error_tail "${spctl_log}" 12
    die "Homebrew.pkg trust assessment failed"
  }

  sha256="$(/usr/bin/shasum -a 256 "${pkg}" | /usr/bin/awk '{print $1}')"
  log "Verified signed and notarized Homebrew package; SHA-256 ${sha256}"
}

prepare_package_user_plist() {
  local base plist

  ensure_tmp_dir
  base="${TMP_DIR}/.homebrew_pkg_user"
  plist="${base}.plist"

  /bin/rm -f "${plist}"
  /usr/bin/defaults write "${base}" HOMEBREW_PKG_USER "${ADMIN_USER}"
  /usr/sbin/chown root:wheel "${plist}"
  /bin/chmod 0600 "${plist}"
  /bin/chmod -N "${plist}"

  [[ -f "${plist}" && ! -L "${plist}" ]] ||
    die "Cannot create a safe Homebrew package-user plist"

  [[ "$(/usr/bin/stat -f '%Su:%Sg:%Lp' "${plist}")" == "root:wheel:600" ]] ||
    die "Unsafe staged Homebrew package-user plist"

  /bin/rm -rf "${BREW_PKG_USER_PLIST}"
  /bin/mv -f "${plist}" "${BREW_PKG_USER_PLIST}"

  [[ -f "${BREW_PKG_USER_PLIST}" && ! -L "${BREW_PKG_USER_PLIST}" ]] ||
    die "Cannot publish a safe Homebrew package-user plist"

  [[ "$(/usr/bin/stat -f '%Su:%Sg:%Lp' "${BREW_PKG_USER_PLIST}")" == "root:wheel:600" ]] ||
    die "Unsafe Homebrew package-user plist owner or mode"
}

install_homebrew_if_needed() {
  local pkg owner installer_log

  [[ ! -L "${BREW_PREFIX}" ]] ||
    die "${BREW_PREFIX} must not be a symbolic link"

  if [[ -x "${BREW_BIN}" ]]; then
    owner="$(/usr/bin/stat -f '%Su' "${BREW_PREFIX}")"

    [[ "${owner}" == "${ADMIN_USER}" ]] ||
      die "Existing Homebrew is owned by ${owner}, not ${ADMIN_USER}; refusing to take ownership"

    log "Homebrew already installed and owned by ${ADMIN_USER}; skipping package installation"
    return
  fi

  if [[ -e "${BREW_PREFIX}" ]]; then
    [[ -d "${BREW_PREFIX}" ]] ||
      die "${BREW_PREFIX} exists and is not a directory"

    [[ -z "$(/bin/ls -A "${BREW_PREFIX}" 2>/dev/null || true)" ]] ||
      die "${BREW_PREFIX} exists but brew is missing; refusing to overwrite it"

    /bin/rmdir "${BREW_PREFIX}"
  fi

  ensure_tmp_dir
  pkg="${TMP_DIR}/Homebrew-${BREW_PKG_VERSION}.pkg"
  installer_log="${TMP_DIR}/installer.log"

  log "Downloading pinned Homebrew ${BREW_PKG_VERSION} package"

  run_logged "curl" \
    /usr/bin/curl \
      --fail \
      --location \
      --silent \
      --show-error \
      --retry 3 \
      --retry-delay 2 \
      --connect-timeout 20 \
      --proto '=https' \
      --proto-redir '=https' \
      --tlsv1.2 \
      --output "${pkg}" \
      "${BREW_PKG_URL}" || {
        error_tail "${TMP_DIR}/curl.log" 12
        die "Cannot download Homebrew ${BREW_PKG_VERSION}"
      }

  [[ -s "${pkg}" ]] ||
    die "Downloaded Homebrew package is empty"

  log "Verifying Homebrew ${BREW_PKG_VERSION} package"
  verify_homebrew_package "${pkg}"
  prepare_package_user_plist

  log "Installing Homebrew ${BREW_PKG_VERSION} with owner ${ADMIN_USER}"

  run_logged "installer" \
    /usr/sbin/installer \
      -pkg "${pkg}" \
      -target / || {
        error_tail "${installer_log}" 16
        die "Homebrew.pkg installation failed"
      }

  /bin/rm -f "${BREW_PKG_USER_PLIST}"

  [[ -x "${BREW_BIN}" ]] ||
    die "Homebrew.pkg finished but ${BREW_BIN} is missing"

  owner="$(/usr/bin/stat -f '%Su' "${BREW_PREFIX}")"

  [[ "${owner}" == "${ADMIN_USER}" ]] ||
    die "Homebrew.pkg assigned ${BREW_PREFIX} to ${owner}, not ${ADMIN_USER}"

  /usr/sbin/pkgutil --pkg-info "${BREW_PKG_RECEIPT}" >>"${LOG_FILE}" 2>&1 ||
    die "Homebrew package receipt is missing"

  INSTALLED_BY_THIS_RUN=1
}

inspect_homebrew() {
  local output line prefix owner services clean_version

  owner="$(/usr/bin/stat -f '%Su' "${BREW_PREFIX}")"

  [[ "${owner}" == "${ADMIN_USER}" ]] ||
    die "Homebrew prefix is owned by ${owner}, not ${ADMIN_USER}"

  output="$(brew_as_admin --version 2>&1)" || {
    log "DETAIL: ${output}"
    die "Cannot run Homebrew as ${ADMIN_USER}"
  }

  line="${output%%$'\n'*}"
  BREW_VERSION="${line#Homebrew }"
  BREW_VERSION="${BREW_VERSION%% *}"
  clean_version="${BREW_VERSION%%-*}"

  version_at_least "${clean_version}" "${BREW_MIN_VERSION}" ||
    die "Homebrew ${BREW_VERSION:-unknown} is older than required ${BREW_MIN_VERSION}"

  if [[ ${INSTALLED_BY_THIS_RUN} -eq 1 && "${clean_version}" != "${BREW_PKG_VERSION}" ]]; then
    die "Installed Homebrew version ${BREW_VERSION} does not match pinned package ${BREW_PKG_VERSION}"
  fi

  prefix="$(brew_as_admin --prefix 2>&1)" || {
    log "DETAIL: ${prefix}"
    die "Cannot query the Homebrew prefix"
  }

  [[ "${prefix}" == "${BREW_PREFIX}" ]] ||
    die "Homebrew reports unexpected prefix: ${prefix}"

  services="$(brew_as_admin command services 2>/dev/null || true)"

  if [[ -n "${services}" ]]; then
    case "${services}" in
      "${BREW_PREFIX}"/*)
        [[ -f "${services}" && ! -L "${services}" ]] ||
          die "Unexpected brew services command path: ${services}"
        BREW_SERVICES_COMMAND="${services}"
        ;;
      *)
        die "brew services resolved outside ${BREW_PREFIX}: ${services}"
        ;;
    esac
  fi
}

lock_homebrew() {
  local writable error_log

  log "Making Homebrew writable only by ${ADMIN_USER}"

  /bin/chmod -RN "${BREW_PREFIX}" 2>/dev/null || true
  /usr/sbin/chown -R "${ADMIN_USER}:admin" "${BREW_PREFIX}"
  /bin/chmod -R u+rwX,go-w "${BREW_PREFIX}"

  if [[ -n "${BREW_SERVICES_COMMAND}" ]]; then
    /usr/sbin/chown "${ADMIN_USER}:admin" "${BREW_SERVICES_COMMAND}"
    /bin/chmod 0600 "${BREW_SERVICES_COMMAND}"
    log "brew services restricted to ${ADMIN_USER}"
  else
    log "brew services command is not installed"
  fi

  ensure_tmp_dir
  error_log="${TMP_DIR}/find-permissions.log"

  if ! writable="$(
    /usr/bin/find "${BREW_PREFIX}" \
      -xdev \
      ! -type l \
      \( -perm -0020 -o -perm -0002 \) \
      -print \
      -quit \
      2>"${error_log}"
  )"; then
    error_tail "${error_log}" 12
    die "Cannot verify Homebrew permissions"
  fi

  [[ -z "${writable}" ]] ||
    die "Group/other-writable Homebrew path remains: ${writable}"

  if [[ -n "${BREW_SERVICES_COMMAND}" ]]; then
    [[ "$(/usr/bin/stat -f '%Su:%Sg:%Lp' "${BREW_SERVICES_COMMAND}")" == "${ADMIN_USER}:admin:600" ]] ||
      die "Unexpected brew services owner or mode"
  fi
}

[[ ${EUID} -eq 0 ]] || {
  /bin/echo "Jamf School must run this script as root" >&2
  exit 1
}

if [[ -L "${LOG_FILE}" ]]; then
  /bin/rm -f "${LOG_FILE}"
fi

/usr/bin/touch "${LOG_FILE}"
/usr/sbin/chown root:wheel "${LOG_FILE}"
/bin/chmod 0640 "${LOG_FILE}"
ensure_tmp_dir
trap 'on_error $? $LINENO "$BASH_COMMAND"' ERR
trap cleanup EXIT

log "START: Command Line Tools + Homebrew bootstrap"

[[ "$(/usr/bin/uname -m)" == "arm64" ]] ||
  die "This bootstrap supports Apple Silicon only"

/usr/bin/id "${ADMIN_USER}" >/dev/null 2>&1 ||
  die "Local account ${ADMIN_USER} does not exist"

[[ -d "${ADMIN_HOME}" ]] ||
  die "Home directory ${ADMIN_HOME} does not exist"

/usr/bin/id -Gn "${ADMIN_USER}" |
  /usr/bin/tr ' ' '\n' |
  /usr/bin/grep -qx admin ||
  die "Local account ${ADMIN_USER} is not an administrator"

version_at_least "${BREW_PKG_VERSION}" "${BREW_MIN_VERSION}" ||
  die "Pinned Homebrew package ${BREW_PKG_VERSION} is below minimum ${BREW_MIN_VERSION}"

install_clt_if_needed
write_homebrew_configuration
install_homebrew_if_needed
inspect_homebrew
lock_homebrew

log "Installed: Homebrew ${BREW_VERSION}"
log "Prefix: $(/usr/bin/stat -f '%Su:%Sg %Sp' "${BREW_PREFIX}")"
log "Read-only brew commands remain available to other users"
log "SUCCESS"

