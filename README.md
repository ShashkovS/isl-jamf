# ISL Jamf Homebrew profiles

`Scripts/` contains the three Jamf School scripts. `Brewfiles/` contains the editable package lists.

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

The teacher Brewfile must retain the required formulae, but its `cask` lines are freely editable. The student and TLF Brewfiles must retain their complete embedded baseline.
