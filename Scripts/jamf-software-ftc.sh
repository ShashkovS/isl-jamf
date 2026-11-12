#!/bin/bash
# Jamf School FTC add-on for admin-owned Homebrew on Apple Silicon.
# Paste this entire script into Jamf; it is self-contained. See FTC.md.
# No student sudo, shared writable SDK, user-profile execution as root, or
# changes to /opt/edupy. The existing daily updater maintains the app casks.
set -Eeuo pipefail
IFS=$'\n\t'
umask 022
trap '' PIPE

ADMIN_USER="admin"
ADMIN_HOME="/Users/admin"
BREW_PREFIX="/opt/homebrew"
BREW="${BREW_PREFIX}/bin/brew"
JQ="/usr/bin/jq"
[[ -x "${JQ}" ]] || JQ="${BREW_PREFIX}/bin/jq"
JDK_HOME="/Library/Java/JavaVirtualMachines/temurin-21.jdk/Contents/Home"
FTC_TAG="v12.0"
FTC_COMMIT="e14c2aeb33e84d4ea21697beeea9ac49557be870"
FTC_REMOTE="https://github.com/FIRST-Tech-Challenge/FtcRobotController.git"
FTC_ROOT="/Library/Application Support/The Island/FTC"
SELF_INSTALLED="${FTC_ROOT}/ftc-deploy.sh"
TEMPLATE="${FTC_ROOT}/FtcRobotController-${FTC_TAG}"
ENV_FILE="${FTC_ROOT}/environment.sh"
BREWFILE="/Library/Application Support/The Island/Jamf/Brewfiles/ftc.Brewfile"
SDKMANAGER="${BREW_PREFIX}/share/android-commandlinetools/cmdline-tools/latest/bin/sdkmanager"
SDK_PACKAGES=("platforms;android-30" "build-tools;35.0.0" "platform-tools" "ndk;21.3.6528147")
LAUNCH_AGENT="/Library/LaunchAgents/cy.theisland.ftc-user-setup.plist"
LOCK_DIR="/private/var/run/theisland-homebrew.lock"
EXAM_STATE_FILE="/var/db/exam_netlock_state"
EXAM_MARGIN_SECONDS=3600
MIN_FREE_GB=15
# Installing the Android SDK accepts Google's SDK licences on the school's behalf.
ACCEPT_ANDROID_LICENSES=1
# A real online + offline APK build, as the student, once per installation profile.
VERIFY_APK_BUILD=1
TIMEOUT_BREW=2400
TIMEOUT_SDK=2400
TIMEOUT_BUILD=1800
TIMEOUT_USER=7200

LOG_FILE=""
WORK_DIR=""
ACTIVE_PID=""
CAFFEINATE_PID=""
LOCKED=0
USER_LOCKED=0
USER_LOCK=""
MODE="root"
DEFERRED=0

# Run commands in their own process group; timeouts/signals terminate children too.
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
  for (1 .. 10) {
    waitpid($pid, WNOHANG);
    last unless kill 0, -$pid;
    sleep 1;
  }
  kill "KILL", -$pid;
  waitpid($pid, 0);
  exit $rc;
};
$SIG{ALRM} = sub { $stop->(124) };
$SIG{$_} = sub { $stop->(143) } for qw(TERM INT HUP);
alarm $limit;
waitpid($pid, 0);
my $status = $?;
alarm 0;
exit(($status & 127) ? 128 + ($status & 127) : $status >> 8);
'

log() {
  local line
  line="$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ') $*"
  [[ -z "${LOG_FILE}" ]] || /usr/bin/printf '%s\n' "${line}" >>"${LOG_FILE}" 2>/dev/null || true
  /usr/bin/printf '%s\n' "${line}" >&2 || true
}
fail() { log "ERROR: $*"; exit 1; }

cleanup() {
  local rc=$? attempt
  trap - EXIT ERR
  trap '' INT TERM HUP
  set +e
  if [[ -n "${ACTIVE_PID}" ]]; then
    /bin/kill -TERM "${ACTIVE_PID}" 2>/dev/null
    for ((attempt=0; attempt<15; attempt++)); do
      /bin/kill -0 "${ACTIVE_PID}" 2>/dev/null || break
      /bin/sleep 1
    done
    /bin/kill -KILL "${ACTIVE_PID}" 2>/dev/null
    wait "${ACTIVE_PID}" 2>/dev/null
  fi
  if [[ ${LOCKED} -eq 1 ]]; then
    /bin/rm -f "${LOCK_DIR}/pid"
    /bin/rmdir "${LOCK_DIR}" 2>/dev/null
  fi
  if [[ ${USER_LOCKED} -eq 1 ]]; then
    /bin/rm -f "${USER_LOCK}/pid"
    /bin/rmdir "${USER_LOCK}" 2>/dev/null
  fi
  if [[ -n "${CAFFEINATE_PID}" ]]; then /bin/kill "${CAFFEINATE_PID}" 2>/dev/null; fi
  [[ -z "${WORK_DIR}" ]] || /bin/rm -rf "${WORK_DIR}"
  log "FINISH: mode=${MODE}; exit=${rc}; log=${LOG_FILE}"
  exit "${rc}"
}

run() {
  local label="$1" limit="$2" rc=0
  shift 2
  log "BEGIN: ${label}"
  # The watchdog execs external commands, not shell functions.
  if [[ "$1" == "admin_exec" ]]; then
    shift
    set -- "${AS_ADMIN[@]}" "$@"
  fi
  /usr/bin/perl -e "${WATCHDOG}" "${limit}" "$@" <&0 >>"${RUN_STDOUT:-${LOG_FILE}}" 2>>"${LOG_FILE}" &
  ACTIVE_PID=$!
  wait "${ACTIVE_PID}" || rc=$?
  ACTIVE_PID=""
  log "END: ${label}; exit=${rc}"
  if [[ ${rc} -ne 0 ]]; then /usr/bin/tail -n 15 "${LOG_FILE}" >&2 || true; fi
  return "${rc}"
}

capture() {
  local label="$1" limit="$2" RUN_STDOUT="$3"
  shift 3
  : >"${RUN_STDOUT}"
  run "${label}" "${limit}" "$@"
}

publish_root_file() {
  local source="$1" target="$2" mode="$3" stage
  [[ ! -L "${target}" ]] || fail "Refusing managed-file symlink: ${target}"
  [[ ! -e "${target}" || -f "${target}" ]] || fail "Not a regular managed file: ${target}"
  stage="$(/usr/bin/mktemp "${target}.XXXXXX")"
  /usr/bin/install -o root -g wheel -m "${mode}" "${source}" "${stage}"
  /bin/mv -f "${stage}" "${target}"
}

# Numeric release comparison, including Temurin build number. No lexicographic sort.
version_at_least() {
  /usr/bin/perl -e '
    my @a = split /[^0-9]+/, $ARGV[0]; my @b = split /[^0-9]+/, $ARGV[1];
    for my $i (0 .. ((@a > @b ? scalar @a : scalar @b) - 1)) {
      my $x = $a[$i] // 0; my $y = $b[$i] // 0;
      exit 0 if $x > $y; exit 1 if $x < $y;
    } exit 0;
  ' "$1" "$2"
}

exam_is_near() {
  local start end now
  [[ -f "${EXAM_STATE_FILE}" ]] || return 1
  start="$(/usr/bin/awk -F= '$1=="START_TS" {print $2; exit}' "${EXAM_STATE_FILE}")"
  end="$(/usr/bin/awk -F= '$1=="END_TS" {print $2; exit}' "${EXAM_STATE_FILE}")"
  [[ "${start}" =~ ^[0-9]+$ && "${end}" =~ ^[0-9]+$ ]] || return 1
  now="$(/bin/date '+%s')"
  [[ ${now} -ge $((start - EXAM_MARGIN_SECONDS)) && ${now} -lt ${end} ]]
}

safe_root_dir() {
  local path="$1" owner mode
  [[ ! -L "${path}" ]] || fail "Refusing symlink: ${path}"
  if [[ -e "${path}" ]]; then
    [[ -d "${path}" ]] || fail "Not a directory: ${path}"
    owner="$(/usr/bin/stat -f '%u' "${path}")"
    mode="$(/usr/bin/stat -f '%Lp' "${path}")"
    [[ "${owner}" == 0 && $((8#${mode} & 0022)) -eq 0 ]] || fail "Unsafe owner/mode: ${path}"
  else
    /usr/bin/install -d -o root -g wheel -m 0755 "${path}"
  fi
}

write_brewfile() {
  /bin/cat <<'BREWFILE_END'
# Add-on to tlf.Brewfile. Run Scripts/jamf-software-ftc.sh as root through Jamf.
# The script handles temurin@21's signed PKG separately; no passwordless sudo.
cask_args appdir: "/Applications"

cask "intellij-idea"
cask "android-studio"
cask "android-commandlinetools"
cask "temurin@21"
BREWFILE_END
}

acquire_root_lock() {
  local pid age
  if ! /bin/mkdir "${LOCK_DIR}" 2>/dev/null; then
    [[ -d "${LOCK_DIR}" && ! -L "${LOCK_DIR}" ]] || fail "Unsafe Homebrew lock"
    [[ "$(/usr/bin/stat -f '%u' "${LOCK_DIR}")" == 0 ]] || fail "Homebrew lock is not root-owned"
    pid="$(/bin/cat "${LOCK_DIR}/pid" 2>/dev/null || true)"
    age=$(($(/bin/date '+%s') - $(/usr/bin/stat -f '%m' "${LOCK_DIR}")))
    if [[ "${pid}" =~ ^[1-9][0-9]*$ ]]; then
      if /bin/kill -0 "${pid}" 2>/dev/null; then
        log "DEFER: another Homebrew deployment is running (PID ${pid})"; exit 75
      fi
    elif [[ ${age} -lt 300 ]]; then
      log "DEFER: another deployment is acquiring its lock"; exit 75
    fi
    /bin/rm -f "${LOCK_DIR}/pid"
    /bin/rmdir "${LOCK_DIR}" || fail "Stale lock has unexpected contents"
    /bin/mkdir "${LOCK_DIR}" || fail "Another deployment acquired the lock"
  fi
  LOCKED=1
  /usr/sbin/chown root:wheel "${LOCK_DIR}"
  /bin/chmod 0700 "${LOCK_DIR}"
  /usr/bin/printf '%s\n' "$$" >"${LOCK_DIR}/pid"
}

AS_ADMIN=(
  /usr/bin/sudo -n -u "${ADMIN_USER}" -H /usr/bin/env -i
  "HOME=${ADMIN_HOME}" "USER=${ADMIN_USER}" "LOGNAME=${ADMIN_USER}"
  "PATH=/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  LC_ALL=en_US.UTF-8 CI=1 NONINTERACTIVE=1 GIT_TERMINAL_PROMPT=0
  GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
  HOMEBREW_NO_SUDO=1 HOMEBREW_NO_ASK=1 HOMEBREW_NO_ANALYTICS=1
  HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_UPGRADE=1 HOMEBREW_UPDATE_TO_TAG=1
  HOMEBREW_NO_AUTOREMOVE=1
  HOMEBREW_NO_ENV_HINTS=1 HOMEBREW_NO_COLOR=1 HOMEBREW_NO_INSTALL_CLEANUP=1
  HOMEBREW_NO_UPGRADE_QUIT_CASKS=1 HOMEBREW_NO_APP_MANAGEMENT_PERMISSIONS_PROMPT=1
  HOMEBREW_BUNDLE_NO_UPGRADE=1 HOMEBREW_BUNDLE_CASK_SKIP=temurin@21
  SUDO_ASKPASS=/usr/bin/false SSH_ASKPASS=/usr/bin/false
)
admin_exec() { "${AS_ADMIN[@]}" "$@"; }

install_apps() {
  local cask app
  run "Refresh Homebrew metadata" "${TIMEOUT_BREW}" admin_exec "${BREW}" update || fail "brew update failed"
  # Never take over or delete a Toolbox/manual installation.
  for cask in intellij-idea android-studio; do
    case "${cask}" in
      intellij-idea) app="/Applications/IntelliJ IDEA.app" ;;
      android-studio) app="/Applications/Android Studio.app" ;;
    esac
    if [[ -e "${app}" || -L "${app}" ]]; then
      [[ ! -L "${app}" ]] || fail "${app} is a symlink; resolve the existing installation first"
      admin_exec "${BREW}" list --cask "${cask}" >/dev/null 2>&1 ||
        fail "${app} is not Homebrew-managed; move/migrate it deliberately, then rerun"
    fi
  done
  write_brewfile >"${WORK_DIR}/ftc.Brewfile"
  publish_root_file "${WORK_DIR}/ftc.Brewfile" "${BREWFILE}" 0644
  run "Install missing FTC casks (Temurin PKG handled separately)" "${TIMEOUT_BREW}" \
    admin_exec "${BREW}" bundle install --no-upgrade --file="${BREWFILE}" || fail "FTC Brewfile installation failed"
  for app in "/Applications/IntelliJ IDEA.app" "/Applications/Android Studio.app"; do
    [[ -d "${app}" && ! -L "${app}" ]] || fail "Application missing: ${app}"
    run "Verify signature: ${app}" 120 /usr/bin/codesign --verify --deep --strict "${app}" || fail "Invalid app signature"
    # Only these two bundles; never /Applications as a whole or Toolbox's user dirs.
    /usr/bin/find -P "${app}" -xdev ! -type l -exec /bin/chmod -h -N {} +
    /usr/bin/find -P "${app}" -xdev -exec /usr/sbin/chown -h "${ADMIN_USER}:admin" {} +
    /usr/bin/find -P "${app}" -xdev ! -type l -exec /bin/chmod -h u+rwX,go+rX,go-w {} +
  done
  [[ -x "${SDKMANAGER}" ]] || fail "Homebrew command-line tools do not provide sdkmanager at ${SDKMANAGER}"
  harden_brew_paths
}

harden_brew_paths() {
  local path
  # Limit repairs to this add-on. Never traverse links out of Homebrew.
  for path in "${BREW_PREFIX}/share/android-commandlinetools" \
      "${BREW_PREFIX}/Caskroom/intellij-idea" "${BREW_PREFIX}/Caskroom/android-studio" \
      "${BREW_PREFIX}/Caskroom/android-commandlinetools"; do
    [[ -e "${path}" ]] || continue
    [[ -d "${path}" && ! -L "${path}" ]] || fail "Unexpected Homebrew artifact path: ${path}"
    /usr/bin/find -P "${path}" -xdev ! -type l -exec /bin/chmod -h -N {} +
    /usr/bin/find -P "${path}" -xdev -exec /usr/sbin/chown -h "${ADMIN_USER}:admin" {} +
    /usr/bin/find -P "${path}" -xdev ! -type l -exec /bin/chmod -h u+rwX,go+rX,go-w {} +
  done
}

install_temurin() {
  local metadata="${WORK_DIR}/temurin.json" url sha wanted installed="" pkg
  # Homebrew supplies version/ARM64 URL/checksum; Jamf executes the signed PKG.
  # It is deliberately NOT recorded as an installed cask: the daily updater
  # excludes PKG installers anyway. Re-running this profile updates Java 21.x.
  capture "Read Temurin metadata" 180 "${metadata}" admin_exec "${BREW}" info --json=v2 --cask temurin@21 || fail "Cannot read Temurin metadata"
  "${JQ}" -e '.casks | length == 1' "${metadata}" >/dev/null || fail "Unexpected Temurin metadata"
  url="$("${JQ}" -er '.casks[0].url' "${metadata}")"
  sha="$("${JQ}" -er '.casks[0].sha256' "${metadata}")"
  wanted="$("${JQ}" -er '.casks[0].version | gsub(","; "+")' "${metadata}")"
  [[ "${wanted}" =~ ^21\.[0-9]+\.[0-9]+(\.[0-9]+)?\+[0-9]+$ ]] || fail "Not a stable Java 21 release: ${wanted}"
  [[ "${sha}" =~ ^[0-9a-f]{64}$ ]] || fail "Temurin checksum is missing"
  [[ "${url}" == https://github.com/adoptium/temurin21-binaries/releases/download/jdk-21*/OpenJDK21U-jdk_aarch64_mac_hotspot_*.pkg ]] ||
    fail "Unexpected Temurin download URL: ${url}"
  [[ ! -L /Library/Java/JavaVirtualMachines/temurin-21.jdk ]] || fail "Temurin bundle is a symlink"
  if [[ -f "${JDK_HOME}/release" ]]; then
    installed="$(/usr/bin/sed -nE 's/^JAVA_RUNTIME_VERSION="([^"]+)"$/\1/p' "${JDK_HOME}/release")"
    /usr/bin/grep -Eq '^IMPLEMENTOR="Eclipse Adoptium"$' "${JDK_HOME}/release" || fail "Unexpected vendor at ${JDK_HOME}"
  fi
  if [[ -n "${installed}" ]] && version_at_least "${installed}" "${wanted}"; then
    log "Temurin ${installed} already meets ${wanted}; no downgrade or reinstall"
  else
    if [[ -n "${installed}" ]] && /usr/bin/pgrep -x 'java|javac|javadoc' >/dev/null; then
      log "DEFER: Java processes are running; existing JDK ${installed} stays untouched"
      DEFERRED=1
    else
      pkg="${WORK_DIR}/temurin21.pkg"
      run "Download Temurin ${wanted} ARM64" 1200 /usr/bin/curl --fail --location --silent --show-error \
        --retry 3 --connect-timeout 20 --max-time 1100 --proto '=https' --proto-redir '=https' \
        --tlsv1.2 --output "${pkg}" "${url}" || fail "Temurin download failed"
      [[ "$(/usr/bin/shasum -a 256 "${pkg}" | /usr/bin/awk '{print $1}')" == "${sha}" ]] || fail "Temurin SHA-256 mismatch"
      run "Verify Temurin package signature" 120 /usr/sbin/pkgutil --check-signature "${pkg}" || fail "Unsigned/invalid Temurin package"
      run "Assess Temurin package with Gatekeeper" 120 /usr/sbin/spctl --assess --type install --verbose=2 "${pkg}" || fail "Temurin package failed Gatekeeper"
      run "Install verified Temurin ${wanted}" 900 /usr/sbin/installer -pkg "${pkg}" -target / || fail "Temurin installer failed"
    fi
  fi
  [[ -x "${JDK_HOME}/bin/javac" ]] || fail "Temurin javac missing after installation"
  run "Check Java 21 ARM64" 120 admin_exec "${JDK_HOME}/bin/java" -XshowSettings:properties -version || fail "Java does not run"
  capture "Capture Java properties" 120 "${WORK_DIR}/java-properties" admin_exec \
    /bin/sh -c 'exec "$1/bin/java" -XshowSettings:properties -version 2>&1' sh "${JDK_HOME}" || fail "Cannot inspect Java properties"
  /usr/bin/grep -Eq 'java.specification.version = 21$' "${WORK_DIR}/java-properties" || fail "Wrong Java major"
  /usr/bin/grep -Eq 'os.arch = aarch64$' "${WORK_DIR}/java-properties" || fail "Wrong Java architecture"
}

install_template() {
  local stage="${FTC_ROOT}/.template-staging" actual
  if [[ -d "${TEMPLATE}" ]]; then
    [[ ! -L "${TEMPLATE}" ]] || fail "FTC template is a symlink"
    actual="$(/usr/bin/git -c safe.directory="${TEMPLATE}" -C "${TEMPLATE}" rev-parse HEAD)"
    [[ "${actual}" == "${FTC_COMMIT}" ]] || fail "FTC template has an unexpected commit; refusing to overwrite"
    /usr/bin/git -c safe.directory="${TEMPLATE}" -C "${TEMPLATE}" diff --quiet HEAD -- || fail "FTC template was modified"
    log "Pinned FTC template already installed: ${FTC_TAG} ${actual}"
    return
  fi
  [[ ! -e "${TEMPLATE}" && ! -L "${TEMPLATE}" ]] || fail "Unsafe FTC template destination"
  [[ ! -e "${stage}" && ! -L "${stage}" ]] || fail "Template staging directory exists; inspect ${stage} before retrying"
  /usr/bin/install -d -o "${ADMIN_USER}" -g admin -m 0755 "${stage}"
  if ! run "Fetch pinned FTC SDK ${FTC_TAG}" 900 admin_exec /usr/bin/git clone --depth 1 --branch "${FTC_TAG}" \
      --config core.hooksPath=/dev/null "${FTC_REMOTE}" "${stage}/repo"; then
    /bin/rm -rf "${stage}"; fail "FTC clone failed"
  fi
  actual="$(admin_exec /usr/bin/git -C "${stage}/repo" rev-parse HEAD)"
  if [[ "${actual}" != "${FTC_COMMIT}" ]]; then
    /bin/rm -rf "${stage}"; fail "FTC tag moved: expected ${FTC_COMMIT}, got ${actual}"
  fi
  admin_exec /usr/bin/git -C "${stage}/repo" config --unset core.hooksPath
  /usr/bin/find -P "${stage}/repo" -xdev -exec /usr/sbin/chown -h root:wheel {} +
  /usr/bin/find -P "${stage}/repo" -xdev ! -type l -exec /bin/chmod -h u+rwX,go+rX,go-w {} +
  /bin/mv "${stage}/repo" "${TEMPLATE}"
  /bin/rmdir "${stage}"
  log "FTC SDK pinned by both tag and commit; student work will never be reset"
}

publish_helpers() {
  local source_file
  source_file="${BASH_SOURCE[0]}"
  [[ -f "${source_file}" && ! -L "${source_file}" ]] || fail "Run from a saved Jamf script file, not stdin"
  # Stage before replacing; this also permits running the installed copy again.
  /bin/cp "${source_file}" "${WORK_DIR}/ftc-deploy.sh"
  publish_root_file "${WORK_DIR}/ftc-deploy.sh" "${SELF_INSTALLED}" 0755
  /bin/cat >"${WORK_DIR}/environment.sh" <<'ENV_END'
# School FTC toolchain. Source from the student's shell, never sudo.
export JAVA_HOME="/Library/Java/JavaVirtualMachines/temurin-21.jdk/Contents/Home"
export ANDROID_HOME="$HOME/Library/Android/sdk"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
case ":$PATH:" in
  *":$JAVA_HOME/bin:"*) ;;
  *) export PATH="$JAVA_HOME/bin:$PATH" ;;
esac
case ":$PATH:" in
  *":$ANDROID_HOME/platform-tools:"*) ;;
  *) export PATH="$ANDROID_HOME/platform-tools:$PATH" ;;
esac
ENV_END
  publish_root_file "${WORK_DIR}/environment.sh" "${ENV_FILE}" 0644
  /bin/cat >"${WORK_DIR}/agent.plist" <<'AGENT_END'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>cy.theisland.ftc-user-setup</string>
  <key>ProgramArguments</key><array>
    <string>/bin/bash</string>
    <string>/Library/Application Support/The Island/FTC/ftc-deploy.sh</string>
    <string>--user-setup</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>StartInterval</key><integer>3600</integer>
  <key>ProcessType</key><string>Background</string>
</dict></plist>
AGENT_END
  /usr/bin/plutil -lint "${WORK_DIR}/agent.plist" >/dev/null
  publish_root_file "${WORK_DIR}/agent.plist" "${LAUNCH_AGENT}" 0644
}

# Everything below runs as the student, including all writes under HOME.
# It also runs at login for future accounts; never execute user files as root.
setup_user() {
  local refresh="${1:-}" home="${HOME}" sdk project state stamp fp old="" profile_file line
  local missing=0 input active_uid stage created=0 age
  [[ ${EUID} -ne 0 ]] || fail "--user-setup must not run as root"
  [[ ${EUID} -ge 501 && "$(/usr/bin/id -un)" != "${ADMIN_USER}" ]] || exit 0
  [[ "${home}" == /Users/* && -d "${home}" && ! -L "${home}" ]] || fail "A real local home under /Users is required"
  [[ "$(/usr/bin/stat -f '%u' "${home}")" == "${EUID}" ]] || fail "Home ownership mismatch"
  cd "${home}"
  sdk="${home}/Library/Android/sdk"
  project="${home}/FTC/FtcRobotController-${FTC_TAG}"
  state="${home}/Library/Application Support/The Island/FTC"
  /bin/mkdir -p "${state}" "${home}/Library/Logs/TheIsland"
  LOG_FILE="${home}/Library/Logs/TheIsland/ftc-setup.log"
  [[ ! -L "${LOG_FILE}" ]] || fail "User log is a symlink"
  if [[ -f "${LOG_FILE}" ]] && (( $(/usr/bin/stat -f '%z' "${LOG_FILE}") > 5242880 )); then
    /bin/mv -f "${LOG_FILE}" "${LOG_FILE}.1"
  fi
  /usr/bin/touch "${LOG_FILE}"
  /bin/chmod 0600 "${LOG_FILE}"
  USER_LOCK="${state}/setup.lock"
  if ! /bin/mkdir "${USER_LOCK}" 2>/dev/null; then
    [[ -d "${USER_LOCK}" && ! -L "${USER_LOCK}" ]] || fail "Unsafe user setup lock"
    [[ "$(/usr/bin/stat -f '%u' "${USER_LOCK}")" == "${EUID}" ]] || fail "User setup lock has another owner"
    active_uid="$(/bin/cat "${USER_LOCK}/pid" 2>/dev/null || true)"
    age=$(($(/bin/date '+%s') - $(/usr/bin/stat -f '%m' "${USER_LOCK}")))
    if [[ "${active_uid}" =~ ^[1-9][0-9]*$ ]]; then
      if /bin/kill -0 "${active_uid}" 2>/dev/null; then
        log "DEFER: user setup already running"; exit 75
      fi
    elif [[ ${age} -lt 300 ]]; then
      log "DEFER: user setup lock is being initialized"; exit 75
    fi
    /bin/rm -f "${USER_LOCK}/pid"
    /bin/rmdir "${USER_LOCK}" || fail "User setup lock has unexpected contents"
    /bin/mkdir "${USER_LOCK}" || exit 75
  fi
  USER_LOCKED=1
  /usr/bin/printf '%s\n' "$$" >"${USER_LOCK}/pid"
  WORK_DIR="$(/usr/bin/mktemp -d "${state}/work.XXXXXX")"
  [[ -x "${JDK_HOME}/bin/javac" && -x "${SDKMANAGER}" && -d "${TEMPLATE}/.git" ]] || fail "FTC base installation is incomplete"
  if [[ -r "${EXAM_STATE_FILE}" ]] && exam_is_near; then
    log "DEFER: exam network lock is active or imminent"; exit 75
  fi
  # This is a root-owned file, not a student's shell profile.
  # shellcheck disable=SC1090
  . "${ENV_FILE}"
  export GIT_TERMINAL_PROMPT=0
  [[ ! -w "${BREW_PREFIX}" && ! -w "${JDK_HOME}" && ! -w "${TEMPLATE}" ]] || fail "A shared toolchain path is writable by the student"
  [[ ! -w "/Applications/IntelliJ IDEA.app" && ! -w "/Applications/Android Studio.app" ]] || fail "A shared IDE is writable by the student"
  stamp="${state}/verified-profile.sha256"
  fp="$(/usr/bin/printf '%s\n' "${FTC_COMMIT}" "${SDK_PACKAGES[@]}" "${VERIFY_APK_BUILD}" \
    "$(/bin/cat "${JDK_HOME}/release")" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')"
  [[ ! -f "${stamp}" ]] || old="$(/bin/cat "${stamp}")"

  # Existing projects and their configuration are not rewritten on later runs.
  if [[ ! -e "${project}" && ! -L "${project}" ]]; then
    /bin/mkdir -p "${home}/FTC"
    stage="${WORK_DIR}/project"
    copy_template "${stage}"
    /usr/bin/git -C "${stage}" switch -c student-work
    write_local_config "${stage}" "${sdk}"
    /bin/mv "${stage}" "${project}"
    created=1
    log "Created student's FTC project at ${project}"
  else
    [[ -d "${project}" && ! -L "${project}" ]] || fail "Existing project path is not a real directory: ${project}"
    log "Existing project preserved: ${project}"
  fi

  line='[ ! -r "/Library/Application Support/The Island/FTC/environment.sh" ] || . "/Library/Application Support/The Island/FTC/environment.sh"'
  for profile_file in "${home}/.zprofile" "${home}/.zshrc"; do
    if [[ -L "${profile_file}" ]]; then
      log "WARN: ${profile_file} is a symlink; leaving it unchanged; source ${ENV_FILE} manually"
    else
      [[ ! -e "${profile_file}" || -f "${profile_file}" ]] || fail "Not a regular shell profile: ${profile_file}"
      /usr/bin/grep -Fqx "${line}" "${profile_file}" 2>/dev/null || /usr/bin/printf '\n%s\n' "${line}" >>"${profile_file}"
    fi
  done
  [[ -f "${sdk}/platforms/android-30/android.jar" && -x "${sdk}/build-tools/35.0.0/aapt" && \
     -x "${sdk}/platform-tools/adb" && -f "${sdk}/ndk/21.3.6528147/source.properties" ]] || missing=1
  if [[ "${refresh}" != "--refresh" && "${old}" == "${fp}" && ${missing} -eq 0 && ${created} -eq 0 ]]; then
    log "READY: already provisioned; no downloads or builds"
    return
  fi
  if /usr/bin/pgrep -u "${EUID}" -x 'java|javac|javadoc' >/dev/null; then
    log "DEFER: close Java/Gradle builds before SDK maintenance"; exit 75
  fi
  [[ ${ACCEPT_ANDROID_LICENSES} -eq 1 ]] || fail "School approval for Android SDK licences is required"
  [[ ! -L "${sdk}" ]] || fail "Android SDK is a symlink; migrate it deliberately to a user-owned directory"
  /bin/mkdir -p "${sdk}" "${home}/.android" "${home}/.gradle"
  [[ -w "${sdk}" && -w "${home}/.android" && -w "${home}/.gradle" ]] || fail "SDK or user caches are not writable; inspect previous root-owned installations"
  input="${WORK_DIR}/licence-answers"
  /usr/bin/awk 'BEGIN {for(i=0;i<256;i++) print "y"}' >"${input}"
  run "Accept Android SDK licences" "${TIMEOUT_SDK}" "${SDKMANAGER}" --sdk_root="${sdk}" --licenses <"${input}" || fail "SDK licence acceptance failed"
  run "Install pinned SDK packages and current platform-tools" "${TIMEOUT_SDK}" \
    "${SDKMANAGER}" --sdk_root="${sdk}" --channel=0 "${SDK_PACKAGES[@]}" <"${input}" || fail "SDK component installation failed"
  [[ -f "${sdk}/platforms/android-30/android.jar" && -x "${sdk}/build-tools/35.0.0/aapt" && \
     -x "${sdk}/platform-tools/adb" && -f "${sdk}/ndk/21.3.6528147/source.properties" ]] || fail "SDK verification failed"

  /bin/cat >"${WORK_DIR}/FtcInstallCheck.java" <<'JAVA_END'
public final class FtcInstallCheck {
    public static void main(String[] args) {
        double seconds = 1500 / 1000.0;
        if (seconds != 1.5) throw new AssertionError("fraction lost");
        System.out.println("FTC Java 8 compilation and student execution OK");
    }
}
JAVA_END
  run "Compile Java 8 as student" 120 "${JDK_HOME}/bin/javac" --release 8 -d "${WORK_DIR}" "${WORK_DIR}/FtcInstallCheck.java" || fail "Java compilation failed"
  run "Run Java as student" 120 "${JDK_HOME}/bin/java" -cp "${WORK_DIR}" FtcInstallCheck || fail "Java execution failed"
  if [[ ${VERIFY_APK_BUILD} -eq 1 && "${old}" != "${fp}" ]]; then
    # Build a pristine copy, NEVER the student's working tree or a root process.
    stage="${WORK_DIR}/apk-check"
    copy_template "${stage}"
    write_local_config "${stage}" "${sdk}"
    run "Online FTC APK build as student" "${TIMEOUT_BUILD}" /bin/bash "${stage}/gradlew" \
      --project-dir "${stage}" --no-daemon --max-workers=2 --console=plain assembleDebug || fail "Online APK build failed"
    run "Clean offline FTC APK build as student" "${TIMEOUT_BUILD}" /bin/bash "${stage}/gradlew" \
      --project-dir "${stage}" --offline --no-daemon --max-workers=2 --console=plain clean assembleDebug || fail "Offline APK build failed"
    [[ -n "$(/usr/bin/find "${stage}" -name '*.apk' -type f -print -quit)" ]] || fail "Build reported success without an APK"
  fi
  /usr/bin/printf '%s\n' "${fp}" >"${stamp}"
  log "SUCCESS: user SDK, caches, Java 8 compilation and FTC profile ready; project=${project}"
}

copy_template() {
  local target="$1"
  # APFS copy-on-write when supported; no hard links between student projects.
  if ! /bin/cp -cR "${TEMPLATE}" "${target}" 2>/dev/null; then
    /bin/rm -rf "${target}"
    /usr/bin/ditto "${TEMPLATE}" "${target}"
  fi
  /usr/bin/find -P "${target}" ! -type l -exec /bin/chmod -h u+rwX {} +
}

write_local_config() {
  local project="$1" sdk="$2"
  /usr/bin/printf 'sdk.dir=%s\n' "${sdk}" >"${project}/local.properties"
  /bin/mkdir -p "${project}/.gradle"
  /usr/bin/printf 'java.home=%s\n' "${JDK_HOME}" >"${project}/.gradle/config.properties"
  # Terminal builds use JAVA_HOME; Android Studio uses GRADLE_LOCAL_JAVA_HOME.
}

root_main() {
  local user uid home shell failures=0 rc free services user_count=0
  [[ ${EUID} -eq 0 ]] || fail "Run this installer through Jamf as root"
  [[ "$(/usr/bin/uname -s)" == Darwin && "$(/usr/bin/uname -m)" == arm64 ]] || fail "Native Apple Silicon macOS is required"
  [[ -x /usr/bin/perl && -x "${BREW}" && -x "${JQ}" ]] || fail "Run brew_and_xcode.sh and jamf-software-tlf.sh first"
  [[ ! -L "${BREW_PREFIX}" && "$(/usr/bin/stat -f '%Su' "${BREW_PREFIX}")" == "${ADMIN_USER}" ]] || fail "Homebrew must be owned by admin"
  /usr/bin/id "${ADMIN_USER}" >/dev/null || fail "Missing admin account"
  LOG_FILE="/var/log/theisland-software-ftc.log"
  [[ ! -L "${LOG_FILE}" && ( ! -e "${LOG_FILE}" || -f "${LOG_FILE}" ) ]] || fail "Unsafe log path"
  if [[ -f "${LOG_FILE}" ]] && (( $(/usr/bin/stat -f '%z' "${LOG_FILE}") > 10485760 )); then
    /bin/mv -f "${LOG_FILE}" "${LOG_FILE}.1"
  fi
  /usr/bin/touch "${LOG_FILE}"
  /usr/sbin/chown root:wheel "${LOG_FILE}"
  /bin/chmod 0640 "${LOG_FILE}"
  WORK_DIR="$(/usr/bin/mktemp -d /private/var/tmp/theisland-ftc.XXXXXX)"
  /bin/chmod 0700 "${WORK_DIR}"
  log "START: FTC add-on; JDK 21.x; SDK ${FTC_TAG} at ${FTC_COMMIT}"
  if exam_is_near; then log "DEFER: exam network lock is active or imminent"; exit 75; fi
  acquire_root_lock
  /usr/bin/caffeinate -i -w "$$" </dev/null >/dev/null 2>&1 &
  CAFFEINATE_PID=$!
  free="$(/bin/df -g / | /usr/bin/awk 'NR==2 {print $4}')"
  [[ "${free}" =~ ^[0-9]+$ && ${free} -ge ${MIN_FREE_GB} ]] || fail "At least ${MIN_FREE_GB} GB free space is required"
  for home in "/Library/Application Support/The Island" "/Library/Application Support/The Island/Jamf" \
      "/Library/Application Support/The Island/Jamf/Brewfiles" "${FTC_ROOT}" /Library/LaunchAgents /Library/Java /Library/Java/JavaVirtualMachines; do
    safe_root_dir "${home}"
  done
  cd "${ADMIN_HOME}"
  install_apps
  install_temurin
  if [[ ! -e /Library/Apple/usr/libexec/oah/libRosettaRuntime ]] && \
      ! /usr/sbin/pkgutil --pkg-info com.apple.pkg.RosettaUpdateAuto >/dev/null 2>&1; then
    run "Install Rosetta for older Android native tools" 900 /usr/sbin/softwareupdate --install-rosetta --agree-to-license || fail "Rosetta installation failed"
  fi
  install_template
  publish_helpers
  # Do not grant group/other writes; the daily updater's policy remains intact.
  services="$(admin_exec "${BREW}" command services 2>/dev/null || true)"
  if [[ "${services}" == "${BREW_PREFIX}"/* && -f "${services}" && ! -L "${services}" ]]; then
    /bin/chmod 0600 "${services}"
  fi
  # Inspect accounts, not only /Users directory names. Skip service and admin users.
  while IFS=$' \t' read -r user uid; do
    case "${user}" in admin|root|Guest|_*) continue ;; esac
    [[ "${uid}" =~ ^[0-9]+$ && ${uid} -ge 501 && ${uid} -lt 65534 ]] || continue
    home="$(/usr/bin/dscl . -read "/Users/${user}" NFSHomeDirectory | /usr/bin/sed 's/^NFSHomeDirectory: //')"
    shell="$(/usr/bin/dscl . -read "/Users/${user}" UserShell 2>/dev/null | /usr/bin/awk '{print $2}')"
    case "${shell}" in ""|/usr/bin/false|/sbin/nologin) continue ;; esac
    [[ "${home}" == /Users/* && -d "${home}" && ! -L "${home}" ]] || continue
    [[ "$(/usr/bin/stat -f '%u' "${home}")" == "${uid}" ]] || fail "Unexpected home owner: ${home}"
    user_count=$((user_count+1))
    rc=0
    run "Provision FTC for ${user}" "${TIMEOUT_USER}" /usr/bin/sudo -n -u "${user}" -H /usr/bin/env -i \
      HOME="${home}" USER="${user}" LOGNAME="${user}" \
      PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
      LC_ALL=en_US.UTF-8 /bin/bash "${SELF_INSTALLED}" --user-setup --refresh </dev/null || rc=$?
    if [[ ${rc} -eq 75 ]]; then DEFERRED=1
    elif [[ ${rc} -ne 0 ]]; then failures=$((failures+1)); fi
  done < <(/usr/bin/dscl . -list /Users UniqueID)
  log "Personal accounts processed: ${user_count}; failures=${failures}"
  [[ ${user_count} -ne 0 ]] || log "No personal account yet: SDK and APK verification will run at the first student login"
  [[ ${failures} -eq 0 ]] || fail "${failures} user setup(s) failed; inspect their ftc-setup.log"
  if [[ ${DEFERRED} -ne 0 ]]; then log "DEFER: installation/maintenance incomplete; retry outside Java sessions"; exit 75; fi
  log "SUCCESS: FTC installed; applications update through the existing daily policy"
  log "Schedule this same FTC profile weekly for Temurin 21.x and Android platform-tools updates"
}

# Sourcing is reserved for the repository's non-destructive unit tests.
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then return 0; fi
trap cleanup EXIT
trap 'fail "Unexpected failure at line ${LINENO} (exit $?)"' ERR
trap 'log "Interrupted"; exit 143' INT TERM HUP
if [[ "${1:-}" == "--user-setup" ]]; then
  MODE="user"
  setup_user "${2:-}"
else
  root_main
fi
