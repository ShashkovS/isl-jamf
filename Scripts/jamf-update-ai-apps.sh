#!/bin/bash
# Jamf School, Apple Silicon. Install/update the two GUI apps in /Applications.
set -uo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C
umask 022

apps=/Applications
lock=/private/var/run/theisland-homebrew.lock
active_work=""

download() {
  curl -q --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
    --connect-timeout 15 --max-time 3600 --speed-limit 1024 --speed-time 90 --retry 2 --output "$2" "$1"
}

version() {
  /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$1/Contents/Info.plist" 2>/dev/null
}

signed_by() {
  local developer_id="certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13]"
  codesign --verify --deep --strict -R \
    "=anchor apple generic and $developer_id and identifier \"$2\" and certificate leaf[subject.OU] = \"$3\"" "$1"
}

has_arm64() {
  local exe archs
  exe=$(plutil -extract CFBundleExecutable raw "$1/Contents/Info.plist") || return 1
  archs=$(file -b "$1/Contents/MacOS/$exe") || return 1
  [[ $archs == *arm64* ]]
}

idle() {
  local processes
  processes=$(ps -axww -o comm=) || return 1
  if printf '%s\n' "$processes" | awk -v prefix="$1/Contents/" \
      'index($0, prefix) == 1 {busy=1} END {exit !busy}'; then
    echo "DEFER: $1 is open; retry after it closes"
    return 1
  fi
}

# One APFS operation. On failure the original app remains at its original path.
publish() {
  /usr/bin/ruby --disable-gems -rfiddle/import - "$1" "$2" <<'RUBY'
module Darwin
  extend Fiddle::Importer
  dlload Fiddle.dlopen(nil)
  extern 'int renamex_np(const char *, const char *, unsigned int)'
end
source, target = ARGV
flags = File.exist?(target) || File.symlink?(target) ? 2 : 4 # RENAME_SWAP / RENAME_EXCL
abort SystemCallError.new('renamex_np', Fiddle.last_error).message unless Darwin.renamex_np(source, target, flags).zero?
RUBY
}

install_release() {
  local token=$1 name=$2 id=$3 team=$4 dest="$apps/$2.app"
  local work=$5 meta latest installed url sha actual candidate min_os available_kib
  meta="$work/cask.json"
  download "https://formulae.brew.sh/api/cask/$token.json" "$meta" || return 1
  latest=$(plutil -extract version raw "$meta") || return 1
  latest=${latest%%,*} # Claude appends the release commit to its cask version.
  [[ $latest =~ ^[0-9]+(\.[0-9]+)+$ ]] || { echo "Unexpected $name version: $latest"; return 1; }

  installed=$(version "$dest") || installed=""
  if [[ $installed =~ ^[0-9]+(\.[0-9]+)+$ ]] &&
     [[ $(printf '%s\n' "$installed" "$latest" | sort -V | tail -1) == "$installed" ]] &&
     has_arm64 "$dest" && signed_by "$dest" "$id" "$team"; then
    echo "OK: $name $installed (catalog $latest)"
    return 0
  fi

  idle "$dest" || return 1
  available_kib=$(df -Pk "$apps" | awk 'NR == 2 {print $4}') || return 1
  [[ $available_kib =~ ^[0-9]+$ ]] || { echo "Cannot determine free space on $apps"; return 1; }
  if (( available_kib < 5 * 1024 * 1024 )); then
    echo "DEFER: $name needs 5 GiB free to start updating; $((available_kib / 1024)) MiB available"
    return 1
  fi
  echo "Updating $name: ${installed:-missing} -> $latest"
  url=$(plutil -extract url raw "$meta") || return 1
  sha=$(plutil -extract sha256 raw "$meta") || return 1
  [[ $url == https://*.zip && $sha =~ ^[0-9a-f]{64}$ ]] || { echo "Unexpected $name archive metadata"; return 1; }
  case "$url" in
    *-x64-*|*-x86_64-*) echo "$name catalog points to an Intel build"; return 1 ;;
  esac
  download "$url" "$work/release.zip" || return 1
  actual=$(shasum -a 256 "$work/release.zip") || return 1
  [[ ${actual%% *} == "$sha" ]] || { echo "$name checksum mismatch"; return 1; }
  ditto -x -k --noacl "$work/release.zip" "$work/unpacked" || return 1
  rm -f "$work/release.zip" || return 1
  candidate="$work/unpacked/$name.app"
  [[ -d $candidate && ! -L $candidate && $(version "$candidate") == "$latest" ]] ||
    { echo "Unexpected $name bundle or version"; return 1; }
  has_arm64 "$candidate" || { echo "$name has no Apple Silicon executable"; return 1; }
  # A vendor ZIP can carry its builder's numeric UID and write permissions.
  find -P "$candidate" \( ! -user root -o ! -group wheel \) -exec chown -h root:wheel {} + || return 1
  find -P "$candidate" ! -type l \( -perm -0020 -o -perm -0002 \) -exec chmod go-w {} + || return 1
  signed_by "$candidate" "$id" "$team" || return 1
  min_os=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$candidate/Contents/Info.plist" 2>/dev/null) || min_os=""
  if [[ -n $min_os && $(printf '%s\n' "$min_os" "$(sw_vers -productVersion)" | sort -V | head -1) != "$min_os" ]]; then
    echo "$name requires macOS $min_os"
    return 1
  fi
  idle "$dest" || return 1
  publish "$candidate" "$dest" || return 1
  echo "OK: installed $name $latest"
}

update_app() {
  local rc=0 dir
  for dir in "$apps"/.school-update-"$2".??????; do
    [[ -d $dir && ! -L $dir && -O $dir ]] || continue
    rm -rf "$dir" || { echo "INCOMPLETE: cannot clean $dir; deferring $2"; return 1; }
  done
  active_work=$(mktemp -d "$apps/.school-update-$2.XXXXXX") || return 1
  install_release "$@" "$active_work" || rc=$?
  if ! rm -rf "$active_work"; then
    echo "INCOMPLETE: cannot clean $active_work"
    rc=1
  fi
  active_work=""
  return "$rc"
}

retire_codex() {
  local legacy="$apps/Codex.app"
  [[ -d $legacy ]] || return 0
  signed_by "$legacy" com.openai.codex 2DC432GLL2 || { echo "WARN: unrecognized $legacy retained"; return 0; }
  idle "$legacy" || return 1
  rm -rf "$legacy" && echo "OK: removed legacy $legacy"
}

acquire_lock() {
  local modified
  if mkdir -m 700 "$lock" 2>/dev/null; then
    echo "$$" > "$lock/pid" || { rmdir "$lock"; return 1; }
  else
    # Reclaim the PID file in place, keeping the directory used by other school scripts.
    (
      [[ -d $lock && ! -L $lock && -O $lock ]] && cd "$lock" || exit 1
      if [[ ! -s pid ]]; then
        modified=$(stat -f %m .) || exit 1
        (( $(date +%s) - modified > 60 )) || exit 1
      fi
      # Serialize simultaneous takeovers on the existing PID file.
      lockf -k -t 0 pid /bin/bash -s -- "$lock" "$$" <<'LOCK'
[[ . -ef $1 ]] || exit 1
owner=$(cat pid) || exit 1
if [[ $owner =~ ^[1-9][0-9]*$ ]] && kill -0 "$owner" 2>/dev/null; then exit 1; fi
echo "$2" > pid
LOCK
    ) || return 1
  fi
}

cleanup() {
  [[ -z $active_work ]] || rm -rf "$active_work"
  if [[ $(cat "$lock/pid" 2>/dev/null) == "$$" ]]; then
    rm -f "$lock/pid" && rmdir "$lock"
  fi
}

main() {
  local rc=0
  [[ $EUID == 0 ]] || { echo "Run as root from Jamf"; return 1; }
  [[ $(sysctl -n hw.optional.arm64) == 1 ]] || { echo "Requires Apple Silicon"; return 1; }
  [[ -x /usr/bin/ruby ]] || { echo "Missing system Ruby for atomic app replacement"; return 1; }
  trap cleanup EXIT
  trap 'exit 1' HUP INT TERM
  acquire_lock || { echo "Cannot take school deployment lock; retry later"; return 1; }

  if update_app chatgpt ChatGPT com.openai.codex 2DC432GLL2; then
    retire_codex || rc=1
  else
    echo "INCOMPLETE: ChatGPT"
    rc=1
  fi
  update_app claude Claude com.anthropic.claudefordesktop Q6L2SF6YDW || { echo "INCOMPLETE: Claude"; rc=1; }
  return "$rc"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
