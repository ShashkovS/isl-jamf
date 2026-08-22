#!/usr/bin/env bash
# macOS classroom deploy: install shared tools & keep Homebrew writable by admin only.

set -euo pipefail
IFS=$'\n\t'

# --- Settings you may toggle ---
INSTALL_OH_MY_ZSH=0   # 0 = skip; 1 = unattended install for each local user
ADMIN_USER="admin"
SHARED_VENV_DIR="/opt/edupy"  # shared Python environment with DS/ML stack
BREW="/opt/homebrew/bin/brew"
PY_VER="3.14"         # Homebrew python formula/version to install/use

# --- Must be root (manual sudo or Jamf) ---
if [[ "${EUID}" -ne 0 ]]; then
  echo "Please run this script as root (sudo or Jamf)."
  exit 1
fi

# Jamf runs scripts as root, so SUDO_USER is not available there.
ADMIN_HOME="/Users/${ADMIN_USER}"
if ! id "${ADMIN_USER}" >/dev/null 2>&1 || [[ ! -d "${ADMIN_HOME}" ]]; then
  echo "Managed admin account ${ADMIN_USER} with home ${ADMIN_HOME} does not exist."
  exit 1
fi
echo "Admin user: ${ADMIN_USER}"

# --- Confirm Homebrew exists ---
if [[ ! -x "${BREW}" ]]; then
  echo "Homebrew not found at ${BREW}. Install the official Homebrew .pkg for ${ADMIN_USER} first."
  exit 1
fi

# Run Homebrew as the managed admin, never as root.
run_brew() {
  sudo -u "${ADMIN_USER}" -H \
    env HOME="${ADMIN_HOME}" USER="${ADMIN_USER}" LOGNAME="${ADMIN_USER}" \
      PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
      NONINTERACTIVE=1 \
    "${BREW}" "$@"
}

# --- Enumerate local (non-admin) users under /Users ---
declare -a LOCAL_USERS=()
for dir in /Users/*; do
  [[ -d "${dir}" ]] || continue
  user="$(basename "${dir}")"
  case "${user}" in
    "${ADMIN_USER}"|"Shared"|"Guest"|"root") continue ;;
  esac
  if id -u "${user}" &>/dev/null; then
    shell="$(dscl . -read "/Users/${user}" UserShell 2>/dev/null | awk '{print $2}')"
    [[ -n "${shell}" && -x "${shell}" ]] || continue
    LOCAL_USERS+=("${user}")
  fi
done
echo "Detected local users: ${LOCAL_USERS[*]:-<none>}"

# --- Install Rosetta on Apple silicon without prompting ---
if [[ "$(uname -m)" == "arm64" ]]; then
  echo "Ensuring Rosetta 2 is installed..."
  softwareupdate --install-rosetta --agree-to-license || \
    echo "WARNING: Rosetta installation failed; continuing with native tools."
fi

# --- Configure Homebrew defaults and PATH for all users ---
echo "Configuring Homebrew and PATH for all users..."
install -d -m 0755 /etc/homebrew /etc/paths.d
cat >/etc/homebrew/brew.env <<'EOF_BREW_ENV'
HOMEBREW_SYSTEM_ENV_TAKES_PRIORITY=1
HOMEBREW_NO_ANALYTICS=1
HOMEBREW_NO_ASK=1
HOMEBREW_NO_AUTO_UPDATE=1
HOMEBREW_NO_ENV_HINTS=1
HOMEBREW_NO_UPGRADE_QUIT_CASKS=1
EOF_BREW_ENV
chown root:wheel /etc/homebrew/brew.env
chmod 0644 /etc/homebrew/brew.env

cat >/etc/paths.d/00-edupy <<EOF_EDUPY_PATH
${SHARED_VENV_DIR}/bin
EOF_EDUPY_PATH
cat >/etc/paths.d/10-homebrew <<'EOF_HOMEBREW_PATH'
/opt/homebrew/bin
/opt/homebrew/sbin
EOF_HOMEBREW_PATH
chown root:wheel /etc/paths.d/00-edupy /etc/paths.d/10-homebrew
chmod 0644 /etc/paths.d/00-edupy /etc/paths.d/10-homebrew

# --- Update/upgrade brew once under admin context ---
echo "Updating Homebrew..."
run_brew update
run_brew upgrade

# --- Install CLI formulae system-wide ---
echo "Installing core CLI formulae..."
run_brew install \
  git \
  "python@${PY_VER}" \
  "python-tk@${PY_VER}" \
  uv pipx \
  node cmake sqlite jq bat p7zip \
  ripgrep fd yq ffmpeg playwright-cli coreutils findutils gnu-sed grep
# run_brew install rust kotlin swift
# run_brew install ollama

# --- Install GUI apps for all users (into /Applications) ---
echo "Installing GUI apps into /Applications..."
run_brew install --cask --appdir="/Applications" \
  iterm2 visual-studio-code jetbrains-toolbox
# run_brew install --cask --appdir="/Applications" bitwarden

# --- Create a shared Python environment with DS/ML stack ---
echo "Creating shared Python venv at ${SHARED_VENV_DIR}..."
PY_PREFIX="$(run_brew --prefix "python@${PY_VER}")"
PY_BIN="${PY_PREFIX}/bin/python${PY_VER}"

if [[ ! -x "${PY_BIN}" ]]; then
  echo "Cannot find ${PY_BIN}. Check the Python installation above."
  exit 1
fi

rm -rf "${SHARED_VENV_DIR}"

# The venv remains read-only for students. --system-site-packages enables each
# user's site-packages, so plain `pip install` can write into the user's home.
"${PY_BIN}" -m venv --system-site-packages "${SHARED_VENV_DIR}"

PIP_CONFIG_FILE=/dev/null PIP_DISABLE_PIP_VERSION_CHECK=1 \
  "${SHARED_VENV_DIR}/bin/python" -m pip install --no-input --upgrade \
  pip setuptools wheel

PIP_CONFIG_FILE=/dev/null PIP_DISABLE_PIP_VERSION_CHECK=1 \
  "${SHARED_VENV_DIR}/bin/python" -m pip install --no-input \
  numpy scipy pandas matplotlib scikit-learn xgboost catboost \
  ipython jupyter jupyterlab ruff ipykernel

# Future `pip install ...` commands install packages into the current user's
# site-packages, while still using the shared edupy interpreter.
cat >"${SHARED_VENV_DIR}/pip.conf" <<'EOF_PIP_CONFIG'
[global]
disable-pip-version-check = true
no-input = true

[install]
user = true
EOF_PIP_CONFIG

# Register the same interpreter as a named Jupyter kernel.
"${SHARED_VENV_DIR}/bin/python" -m ipykernel install \
  --name "edupy" --display-name "edupy" --prefix /usr/local

# Admin may update the shared environment; students may only read and execute it.
chmod -RN "${SHARED_VENV_DIR}" 2>/dev/null || true
chown -R "${ADMIN_USER}:wheel" "${SHARED_VENV_DIR}"
chmod -R u+rwX,go-w "${SHARED_VENV_DIR}"

# --- Make edupy the default Python in terminals ---
echo "Installing Python command wrappers in /usr/local/bin..."
install -d -m 0755 /usr/local/bin

for command_name in python python3 "python${PY_VER}"; do
  cat >"/usr/local/bin/${command_name}" <<EOF_PYTHON_WRAPPER
#!/usr/bin/env bash
unset PYTHONHOME PYTHONNOUSERSITE
exec "${SHARED_VENV_DIR}/bin/python" "\$@"
EOF_PYTHON_WRAPPER
  chown root:wheel "/usr/local/bin/${command_name}"
  chmod 0755 "/usr/local/bin/${command_name}"
done

for command_name in pip pip3 "pip${PY_VER}"; do
  cat >"/usr/local/bin/${command_name}" <<EOF_PIP_WRAPPER
#!/usr/bin/env bash
unset PYTHONHOME PYTHONNOUSERSITE
exec "${SHARED_VENV_DIR}/bin/python" -m pip "\$@"
EOF_PIP_WRAPPER
  chown root:wheel "/usr/local/bin/${command_name}"
  chmod 0755 "/usr/local/bin/${command_name}"
done

for command_name in ipython jupyter jupyter-lab ruff; do
  cat >"/usr/local/bin/${command_name}" <<EOF_TOOL_WRAPPER
#!/usr/bin/env bash
unset PYTHONHOME PYTHONNOUSERSITE
exec "${SHARED_VENV_DIR}/bin/${command_name}" "\$@"
EOF_TOOL_WRAPPER
  chown root:wheel "/usr/local/bin/${command_name}"
  chmod 0755 "/usr/local/bin/${command_name}"
done

# ~/.virtualenvs/edupy gives VS Code and PyCharm a conventional interpreter path.
for u in "${LOCAL_USERS[@]}"; do
  user_home="/Users/${u}"
  user_group="$(id -gn "${u}")"
  venvs_dir="${user_home}/.virtualenvs"
  venv_link="${venvs_dir}/edupy"

  mkdir -p "${venvs_dir}"
  chown "${u}:${user_group}" "${venvs_dir}"

  if [[ -L "${venv_link}" ]]; then
    rm -f "${venv_link}"
  elif [[ -e "${venv_link}" ]]; then
    echo "WARNING: ${venv_link} exists and is not a symlink; leaving it unchanged."
    continue
  fi

  ln -s "${SHARED_VENV_DIR}" "${venv_link}"
  chown -h "${u}:${user_group}" "${venv_link}"

  # Configure a fresh VS Code profile without overwriting existing settings.
  vscode_dir="${user_home}/Library/Application Support/Code/User"
  vscode_settings="${vscode_dir}/settings.json"
  if [[ ! -e "${vscode_settings}" ]]; then
    mkdir -p "${vscode_dir}"
    cat >"${vscode_settings}" <<EOF_VSCODE_SETTINGS
{
  "python.defaultInterpreterPath": "${venv_link}/bin/python",
  "python-envs.globalSearchPaths": [
    "${venvs_dir}"
  ]
}
EOF_VSCODE_SETTINGS
    chown -R "${u}:${user_group}" "${user_home}/Library/Application Support/Code"
  else
    echo "VS Code settings already exist for ${u}; interpreter remains available at ${venv_link}/bin/python."
  fi
done

# --- Optional: Oh My Zsh per local user (unattended) ---
if [[ "${INSTALL_OH_MY_ZSH}" -eq 1 && "${#LOCAL_USERS[@]}" -gt 0 ]]; then
  echo "Installing Oh My Zsh unattended for local users..."
  for u in "${LOCAL_USERS[@]}"; do
    if ! su -l "${u}" -c 'export RUNZSH=no CHSH=no KEEP_ZSHRC=yes; \
      sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"'; then
      echo "WARNING: Oh My Zsh installation failed for ${u}."
    fi
  done
fi

# --- Lock Homebrew: admin may write; everyone else may read/execute ---
echo "Locking Homebrew writes to ${ADMIN_USER}..."
chmod -RN /opt/homebrew 2>/dev/null || true
chown -R "${ADMIN_USER}:wheel" /opt/homebrew
chmod -R u+rwX,go-w /opt/homebrew

# brew services changes per-user launchd state outside /opt/homebrew. Make the
# whole services subcommand admin-only; this lock is reapplied after brew update.
BREW_SERVICES_COMMAND="$(run_brew command services)"
if [[ ! -f "${BREW_SERVICES_COMMAND}" ]]; then
  echo "Cannot locate the brew services command to restrict it."
  exit 1
fi
chown "${ADMIN_USER}:wheel" "${BREW_SERVICES_COMMAND}"
chmod u+rwX,go-rwx "${BREW_SERVICES_COMMAND}"

# --- Final checks ---
echo "Verifying student access and permissions..."
for u in "${LOCAL_USERS[@]}"; do
  sudo -u "${u}" -H "${BREW}" --version >/dev/null

  if sudo -u "${u}" -H test -w /opt/homebrew; then
    echo "ERROR: ${u} can write to /opt/homebrew."
    exit 1
  fi

  if sudo -u "${u}" -H "${BREW}" services list >/dev/null 2>&1; then
    echo "ERROR: ${u} can run brew services."
    exit 1
  fi

  sudo -u "${u}" -H /usr/local/bin/python -c \
    'import site, sys; assert sys.prefix == "/opt/edupy"; assert site.ENABLE_USER_SITE'
  sudo -u "${u}" -H /usr/local/bin/pip config get install.user | grep -qx true
done

echo
echo "Done. Homebrew is writable only by ${ADMIN_USER}; students retain read-only brew access."
echo "python/pip/ipython/jupyter/ruff use ${SHARED_VENV_DIR}; pip installs into each user's home."
