# ISL Jamf Homebrew profiles

`Scripts/` contains the Jamf School scripts. `Brewfiles/` contains the editable package lists.

The scripts use these public raw URLs:

- `https://raw.githubusercontent.com/shashkovs/isl-jamf/main/Brewfiles/student.Brewfile`
- `https://raw.githubusercontent.com/shashkovs/isl-jamf/main/Brewfiles/tlf.Brewfile`
- `https://raw.githubusercontent.com/shashkovs/isl-jamf/main/Brewfiles/teacher.Brewfile`

Until the repository is published, each script uses its embedded Brewfile. A remote Brewfile may add simple official `brew` and `cask` entries but cannot remove the embedded baseline.

Publish from this directory:

```bash
git init -b main
git add .
git commit -m "Initial Jamf Homebrew profiles"
gh repo create shashkovs/isl-jamf --public --source=. --remote=origin --push
```

Run step 0 (Command Line Tools plus Homebrew bootstrap) before any profile script. Scope the three scripts to mutually exclusive Jamf School device groups.

Full logs:

- `/var/log/theisland-software-student.log`
- `/var/log/theisland-software-tlf.log`
- `/var/log/theisland-software-teacher.log`
- `/var/log/theisland-homebrew-update.log`

The teacher Brewfile must retain the required formulae, but its `cask` lines are freely editable. The student and TLF Brewfiles must retain their complete embedded baseline.

## Daily updates

`Scripts/jamf-daily-update.sh` updates admin-owned Homebrew on student and TLF Macs. Do not scope it to teacher-owned installations.

- It updates every outdated formula and cask, except pinned packages and casks with a pkg or custom installer.
- It pins `FROZEN_FORMULAE` (`python@3.14`, `python-tk@3.14`, `tcl-tk`) to keep `/opt/edupy` unchanged. Formulae that need newer versions of them, such as `pipx` and `mupdf`, are skipped. To thaw, empty the list and run `brew unpin` for each formula on every Mac.
- A running app is skipped. On `FORCE_QUIT_WEEKDAY` between `FORCE_QUIT_START_TIME` and `FORCE_QUIT_END_TIME` (Friday, 16:30–23:59 local time), the update is downloaded first, the app is closed without warning and reopened in the background for the student at the console. Unsaved work can be lost. A Mac that does not run the script in this window keeps the running app until a later run finds it closed or the next window.
- It waits up to `JITTER_MAX_SECONDS` before starting and exits successfully from `EXAM_MARGIN_SECONDS` before a scheduled exam lock until its end.
- It runs `brew cleanup --prune=30` before updating, keeps old Python kegs and stops below `MIN_FREE_GB` of free space.
- Exit code 1 means a package failed, a command timed out, Homebrew permissions were not restored, a lock looks hung or `/opt/edupy` fails to import its native packages. Skipped packages do not fail the run.
- The `SUMMARY` line shows `app management=missing` if Homebrew reported that it lacks the App Management permission.
