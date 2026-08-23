# Math-teacher SchoolTeX layer

This layer is scoped only to mathematics teachers and runs after the ordinary
teacher profile.

## Files to add to the repository

```text
Brewfiles/teacher-math.Brewfile
SchoolTeX/2026/install.profile.example
SchoolTeX/2026/packages.txt
SchoolTeX/2026/vscode-settings.json
Scripts/jamf-software-teacher-math.sh
Scripts/jamf-update-schooltex.sh
```

## Result on a teacher Mac

```text
/Users/<teacher>/Library/SchoolTeX/2026
/Users/<teacher>/Library/SchoolTeX/current -> .../2026
/Library/TeX/texbin -> .../SchoolTeX/current/bin/universal-darwin
```

The complete TeX Live installation is owned by the personal teacher account.
Therefore the teacher can use normal `tlmgr` without `sudo`; no `tlmgr
--usermode` tree is involved.

The install script:

1. downloads the three data files from this repository;
2. installs Ghostscript, TeX Live Utility, Skim and VS Code through Homebrew;
3. downloads and verifies the official `install-tl` archive;
4. installs TeX Live 2026 `scheme-small` into the teacher's home;
5. applies `SchoolTeX/2026/packages.txt`;
6. creates the stable `/Library/TeX/texbin` link;
7. installs LaTeX Workshop and configures VS Code;
8. configures TeX Live Utility to use `/Library/TeX/texbin`.

## Jamf School

Create two macOS scripts:

```text
40 | Software | Teacher | Mathematics
90 | Update | SchoolTeX 2026
```

Paste the corresponding files from `Scripts/`.

Scope the first script to a static group containing mathematics-teacher Macs.
Use `Just once`. The following profiles must already have completed:

```text
00 | Command Line Tools + Homebrew
30 | Software | Teacher
```

The update script runs `tlmgr update --self --all`, then reapplies the current
package manifest. Run it manually or on a deliberate update cadence; do not
run it on every device check-in.

## Adding packages

Edit only:

```text
SchoolTeX/2026/packages.txt
```

Commit and push, then rerun the mathematics profile or the SchoolTeX update
script. Existing packages are not removed when a line disappears.

## Logs

```text
/var/log/theisland-software-teacher-math.log
/var/log/theisland-schooltex-update.log
```

Both scripts also return a compact result to Jamf School. On failure they add
the last 100 local-log lines to the Jamf result.

## TeX Live 2027

Do not update a 2026 installation across a yearly release. Create a new
`SchoolTeX/2027` directory and script revision, install it beside 2026, apply
the manifest and move `~/Library/SchoolTeX/current` to 2027.

## TeXstudio

TeXstudio is not included in the managed Brewfile because its current Homebrew
cask is being disabled after failed Gatekeeper checks. `texshop` is left as a
commented supported alternative. VS Code + LaTeX Workshop remains the primary
editor configuration.
