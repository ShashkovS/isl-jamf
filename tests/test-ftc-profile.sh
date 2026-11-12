#!/bin/bash
# Non-destructive tests. No installation, sudo, or network required.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${ROOT}/Scripts/jamf-software-ftc.sh"
/bin/bash -n "${SCRIPT}"
# Sourcing only defines constants and functions; it does not provision anything.
# shellcheck source=../Scripts/jamf-software-ftc.sh
source "${SCRIPT}"
TMP_TEST="$(mktemp -d)"
trap 'rm -rf "${TMP_TEST}"' EXIT
LOG_FILE="${TMP_TEST}/test.log"
touch "${LOG_FILE}"
count=0
ok() { count=$((count+1)); printf 'ok %s - %s\n' "${count}" "$*"; }

write_brewfile >"${TMP_TEST}/Brewfile"
cmp "${TMP_TEST}/Brewfile" "${ROOT}/Brewfiles/ftc.Brewfile"
ok 'embedded Brewfile matches repository file'

for pair in '21.0.13+9-LTS 21.0.13+9' '21.0.13+9 21.0.12.1+1' '21.0.13+10 21.0.13+9'; do
  IFS=' ' read -r current minimum <<<"${pair}"
  version_at_least "${current}" "${minimum}"
done
if version_at_least '21.0.12+9' '21.0.13+1'; then exit 1; fi
if version_at_least '21.0.13+8' '21.0.13+9'; then exit 1; fi
ok 'Java version/build comparisons and no-downgrade policy'

set +e
/usr/bin/perl -e "${WATCHDOG}" 5 /bin/sh -c 'exit 7'
rc=$?
set -e
[[ ${rc} -eq 7 ]]
ok 'watchdog preserves failure exit code'

printf 'licence-answer\n' >"${TMP_TEST}/stdin"
run 'stdin probe' 5 /bin/sh -c 'read -r value; test "$value" = licence-answer' <"${TMP_TEST}/stdin"
ok 'background watchdog preserves redirected SDK licence stdin'

# The special admin dispatch must expand into external argv before Perl exec.
# Substitute env here: the test must not execute sudo or change accounts.
AS_ADMIN=(/usr/bin/env TEST_FTC_ADMIN_DISPATCH=yes)
run 'admin dispatch probe' 5 admin_exec /bin/sh -c 'test "$TEST_FTC_ADMIN_DISPATCH" = yes'
ok 'run expands admin_exec without trying to exec a Bash function'

capture 'JSON capture probe' 5 "${TMP_TEST}/metadata.json" /bin/sh -c 'printf '"'"'{"ok":true}\n'"'"'; printf '"'"'diagnostic\n'"'"' >&2'
[[ "$(cat "${TMP_TEST}/metadata.json")" == '{"ok":true}' ]]
grep -q diagnostic "${LOG_FILE}"
ok 'captured machine output is separate from diagnostic logging'

set +e
/usr/bin/perl -e "${WATCHDOG}" 1 /bin/sh -c 'sleep 30'
rc=$?
set -e
[[ ${rc} -eq 124 ]]
ok 'watchdog terminates a timed-out process group'

write_local_config "${TMP_TEST}" '/Users/student/Library/Android/sdk'
grep -Fx 'sdk.dir=/Users/student/Library/Android/sdk' "${TMP_TEST}/local.properties"
grep -Fx "java.home=${JDK_HOME}" "${TMP_TEST}/.gradle/config.properties"
ok 'project-local SDK and Gradle JDK paths'

# Catch Bash IFS regressions in dscl records (the installer uses newline/tab IFS).
parsed=''
while IFS=$' \t' read -r name uid; do parsed="${name}:${uid}"; done <<'USERS_END'
student       501
USERS_END
[[ "${parsed}" == 'student:501' ]]
ok 'Directory Services user/UID parsing'

# Validate the emitted LaunchAgent XML without requiring macOS plutil.
if command -v python3 >/dev/null; then
  python3 - "${SCRIPT}" <<'PY'
import pathlib, plistlib, re, sys
text = pathlib.Path(sys.argv[1]).read_text()
xml = re.search(r"<<'AGENT_END'\n(.*?)\nAGENT_END", text, re.S).group(1)
p = plistlib.loads(xml.encode())
assert p['ProgramArguments'] == ['/bin/bash', '/Library/Application Support/The Island/FTC/ftc-deploy.sh', '--user-setup']
assert p['RunAtLoad'] and p['StartInterval'] == 3600
assert 'UserName' not in p
assert 'chmod 777' not in text and 'NOPASSWD' not in text
assert 'sdkmanager --update' not in text
assert 'e14c2aeb33e84d4ea21697beeea9ac49557be870' in text
PY
  ok 'LaunchAgent runs in user context; no privilege grants or SDK-wide update'
fi
printf '\n%s non-destructive tests passed. macOS/Jamf rollout still needs a pilot.\n' "${count}"
