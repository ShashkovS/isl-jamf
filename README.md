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
- A running app is skipped. On `FORCE_QUIT_WEEKDAY` (Friday by default) within `FORCE_QUIT_START_HOUR`–`FORCE_QUIT_END_HOUR`, the update is downloaded first, the app is closed without warning and reopened for the student at the console. Unsaved work can be lost.
- It waits up to `JITTER_MAX_SECONDS` before starting and exits successfully from `EXAM_MARGIN_SECONDS` before a scheduled exam lock until its end.
- It runs `brew cleanup --prune=30` before updating, keeps old Python kegs and stops below `MIN_FREE_GB` of free space.
- Exit code 1 means a package failed, a command timed out, Homebrew permissions were not restored, a lock looks hung or `/opt/edupy` needs repair. Skipped packages do not fail the run.
- The `SUMMARY` line shows `app management=missing` if Homebrew reported that it lacks the App Management permission.
