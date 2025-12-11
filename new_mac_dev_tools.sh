#!/usr/bin/env bash
set -euo pipefail

# ---------- Logging ----------
log() { printf "\n==> %s\n" "$*"; }

# ---------- Homebrew ----------
detect_brew_prefix() {
  if [ -d "/opt/homebrew" ]; then
    echo "/opt/homebrew"
  elif [ -d "/usr/local/Homebrew" ] || [ -d "/usr/local/Cellar" ] || [ -x "/usr/local/bin/brew" ]; then
    echo "/usr/local"
  else
    echo "/opt/homebrew"
  fi
}

ensure_xcode_clt() {
  if ! xcode-select -p >/dev/null 2>&1; then
    log "Installerer Xcode Command Line Tools..."
    xcode-select --install || true
    log "Fullfør installasjonen og kjør skriptet på nytt."
  else
    log "Xcode Command Line Tools er allerede installert."
  fi
}

ensure_homebrew() {
  if command -v brew >/dev/null 2>&1; then
    log "Oppdaterer Homebrew..."
    brew update
  else
    log "Installerer Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  fi

  local BREW_PREFIX
  BREW_PREFIX="$(detect_brew_prefix)"
  eval "$("$BREW_PREFIX/bin/brew" shellenv)"
  brew analytics off >/dev/null 2>&1 || true
}

brew_install_or_upgrade() {
  local name="$1"
  local kind="${2:-formula}"

  if [ "$kind" = "cask" ]; then
    if brew list --cask --versions "$name" >/dev/null 2>&1; then
      log "Oppgraderer cask '$name'..."
      brew upgrade --cask "$name" || true
    else
      log "Installerer cask '$name'..."
      brew install --cask "$name"
    fi
  else
    if brew list --versions "$name" >/dev/null 2>&1; then
      log "Oppgraderer formula '$name'..."
      brew upgrade "$name" || true
    else
      log "Installerer formula '$name'..."
      brew install "$name"
    fi
  fi
}

# ---------- Python ----------
ensure_python_and_pip() {
  brew_install_or_upgrade "python"

  if ! command -v python3 >/dev/null 2>&1; then
    log "Advarsel: 'python3' ikke funnet etter installasjon."
    return
  fi

  log "Oppgraderer pip/setuptools/wheel med --break-system-packages..."
  python3 -m ensurepip --upgrade >/dev/null 2>&1 || true
  python3 -m pip install --user --upgrade pip setuptools wheel --break-system-packages || true

  USER_BASE="$(python3 -m site --user-base)"
  if ! echo "$PATH" | grep -q "$USER_BASE/bin"; then
    log "Legger ${USER_BASE}/bin i PATH via ~/.zshrc"
    echo 'export PATH="'"$USER_BASE"'/bin:$PATH"' >> ~/.zshrc
  fi

  log "Python: $(python3 --version)"
  log "pip: $(python3 -m pip --version)"
}

# ---------- Node.js ----------
ensure_node_and_npm() {
  brew_install_or_upgrade "node"

  if command -v node >/dev/null 2>&1; then
    log "Node.js: $(node -v)"
    log "npm: $(npm -v)"
  else
    log "Advarsel: 'node' ikke funnet etter installasjon."
  fi
}

install_npm_packages() {
  local packages=(
    typescript
    eslint
    prettier
    nodemon
    ts-node
    http-server
    wscat
    npm-check-updates
  )

  if ! command -v npm >/dev/null 2>&1; then
    log "npm ikke tilgjengelig – hopper over globale npm-pakker."
    return
  fi

  for pkg in "${packages[@]}"; do
    if npm list -g --depth=0 "$pkg" >/dev/null 2>&1; then
      log "npm-pakke '$pkg' er allerede installert."
    else
      log "Installerer global npm-pakke '$pkg'..."
      npm install -g "$pkg" || true
    fi
  done
}

# ---------- PowerShell ----------
ensure_powershell() {
  brew_install_or_upgrade "powershell" "cask"

  if ! command -v pwsh >/dev/null 2>&1 && [ -x "/Applications/PowerShell.app/Contents/MacOS/pwsh" ]; then
    ln -sf "/Applications/PowerShell.app/Contents/MacOS/pwsh" "/usr/local/bin/pwsh" || true
  fi

  if command -v pwsh >/dev/null 2>&1; then
    log "Installerer Az-moduler i PowerShell..."
    pwsh -NoProfile -NonInteractive -Command '
      Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue;
      $installed = Get-Module -ListAvailable Az | Select-Object -First 1
      if ($installed) {
        try {
          Update-Module Az -Force -ErrorAction Stop
        } catch {
          Uninstall-Module Az -AllVersions -Force -ErrorAction SilentlyContinue
          Install-Module Az -Scope CurrentUser -Force -AllowClobber
        }
      } else {
        Install-Module Az -Scope CurrentUser -Force -AllowClobber
      }
      $v = (Get-Module -ListAvailable Az | Sort-Object Version -Descending | Select-Object -First 1).Version
      Write-Host "Az-moduler installert. Versjon: $v"
    '
  else
    log "PowerShell ikke funnet – start nytt terminalvindu og kjør skriptet igjen."
  fi
}

# ---------- Azure CLI ----------
ensure_azure_cli() {
  brew_install_or_upgrade "azure-cli"

  if command -v az >/dev/null 2>&1; then
    log "Oppgraderer Azure CLI via 'az upgrade'..."
    az upgrade --yes --only-show-errors || true

    log "Azure CLI versjon:"
    az version --output json 2>/dev/null || az --version

    local EXTENSIONS=()  # legg til ønskede extensions her, f.eks. EXTENSIONS=(resource-graph aks-preview)

    if [ "${#EXTENSIONS[@]}" -gt 0 ]; then
      for ext in "${EXTENSIONS[@]}"; do
        log "Installerer extension '$ext'..."
        az extension add --name "$ext" --upgrade --only-show-errors || true
      done
    fi
  else
    log "Advarsel: 'az' ikke funnet etter installasjon."
  fi
}

# ---------- Terraform ----------
ensure_terraform() {
  # HashiCorp anbefaler eget tap
  brew tap hashicorp/tap >/dev/null 2>&1 || true

  # Installer eller oppgrader Terraform
  brew_install_or_upgrade "hashicorp/tap/terraform"

  if command -v terraform >/dev/null 2>&1; then
    # Første linje holder (resten er plugins, osv.)
    local tfv
    tfv="$(terraform -version | head -n1)"
    log "Terraform installert: ${tfv}"
  else
    log "Advarsel: 'terraform' ikke funnet etter installasjon."
  fi
}

# ---------- terraform-docs ----------
ensure_terraform_docs() {
  # terraform-docs ligger i core
  brew_install_or_upgrade "terraform-docs"

  if command -v terraform-docs >/dev/null 2>&1; then
    # Print kun første linje
    local tdv
    tdv="$(terraform-docs --version 2>&1 | head -n1)"
    log "terraform-docs installert: ${tdv}"
  else
    log "Advarsel: 'terraform-docs' ikke funnet etter installasjon."
  fi
}

# ---------- Main ----------
main() {
  log "Starter utviklermiljø-setup for macOS"
  ensure_xcode_clt
  ensure_homebrew
  ensure_python_and_pip
  ensure_node_and_npm
  install_npm_packages
  ensure_powershell
  ensure_azure_cli
  ensure_terraform
  ensure_terraform_docs
  log "Ferdig!"
}

main "$@"
