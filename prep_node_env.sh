#!/usr/bin/env bash
# prep_node_env.sh
# Purpose: PREPARE environment only (NVM, Node.js, PM2) for a specific user.
# No app cloning, no .env, no services, no PM2 startup units.

set -euo pipefail

# ---------------------- Defaults (overridable by flags) -----------------------
TARGET_USER=""
NODE_VERSION="lts/*"              # default: latest LTS release; use --node node for latest current
NVM_INSTALL_URL="https://raw.githubusercontent.com/nvm-sh/nvm/refs/heads/master/install.sh"  # always latest installer
QUIET=0

# ---------------------- Helpers ----------------------------------------------
log()  { printf "%s\n" "INFO: $*"; }
warn() { printf "%s\n" "WARN: $*" >&2; }
err()  { printf "%s\n" "ERROR: $*" >&2; exit 1; }

need_root() { [[ $EUID -eq 0 ]] || err "Please run as root (sudo)."; }
have_cmd()  { command -v "$1" >/dev/null 2>&1; }

as_user() {
  local user="$1"; shift
  su - "$user" -c "bash -lc \"$*\""
}

# Always source NVM before using it (fixes 'nvm: command not found')
# Always source NVM before using it (fixes 'nvm: command not found')
nvm_run() {
  local user="$1"; shift
  local nvm_dir="$2"; shift
  su - "$user" -c "bash -lc '
    set -e
    # Prefer explicit path; fall back to HOME/.nvm
    if [ -s \"${nvm_dir}/nvm.sh\" ]; then
      . \"${nvm_dir}/nvm.sh\"
    elif [ -s \"\$HOME/.nvm/nvm.sh\" ]; then
      . \"\$HOME/.nvm/nvm.sh\"
    else
      echo \"ERROR: nvm.sh not found at ${nvm_dir}/nvm.sh or \$HOME/.nvm/nvm.sh\" >&2
      exit 1
    fi
    # (optional) bash_completion if present
    [ -s \"${nvm_dir}/bash_completion\" ] && . \"${nvm_dir}/bash_completion\" || true
    $*'"
}

append_once() {
  local file="$1"; shift
  local marker="$1"; shift
  local text="$*"

  if [[ -f "$file" ]] && grep -Fq "$marker" "$file"; then
    [[ $QUIET -eq 1 ]] || log "Marker present in $file; skipping."
    return 0
  fi

  install -m 0644 -D "$file" "$file" 2>/dev/null || true
  {
    echo ""
    echo "# $marker"
    echo "$text"
  } >> "$file"
  [[ $QUIET -eq 1 ]] || log "Appended NVM profile snippet to $file"
}

print_help() {
cat <<'EOF'
Usage:
  sudo bash prep_node_env.sh --user <username> [--node <version>] [--quiet] [--help]

Flags:
  --user <name>          Target Linux user that will own NVM/Node/PM2 (required).
  --node <version>       Node.js version (default: lts/*). Examples: lts/*, node, 22.16.0
  --quiet                Reduce output
  --help                 Show this help message

Does:
  - Installs latest NVM for the user.
  - Installs Node.js via NVM and sets it as default.
  - Installs PM2 for that user (npm -g).
  - Adds a minimal shell snippet to load NVM on login.

Does NOT:
  - Git clone, create app dirs, write .env/credentials.
  - Create services or PM2 startup units.
  - Change system-wide tuning.

Idempotent: safe to re-run.
EOF
}

# ---------------------- Parse args -------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --user)         TARGET_USER="${2:-}"; shift 2 ;;
    --node)         NODE_VERSION="${2:-}"; shift 2 ;;
    --quiet)        QUIET=1; shift ;;
    --help|-h)      print_help; exit 0 ;;
    *)              err "Unknown argument: $1 (use --help)";;
  esac
done

# ---------------------- Validations ------------------------------------------
need_root
[[ -n "$TARGET_USER" ]] || err "--user is required (e.g., --user tradebid)"
id "$TARGET_USER" >/dev/null 2>&1 || err "User '$TARGET_USER' does not exist."

USER_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
[[ -n "$USER_HOME" && -d "$USER_HOME" ]] || err "Cannot resolve home for '$TARGET_USER'"

NVM_DIR_USER="${USER_HOME}/.nvm"
BASHRC_USER="${USER_HOME}/.bashrc"

# ---------------------- Stage 1: prerequisites -------------------------------
if ! have_cmd curl; then
  [[ $QUIET -eq 1 ]] || log "Installing curl (and ca-certificates) ..."
  if have_cmd apt-get; then
    apt-get update -y
    apt-get install -y curl ca-certificates
  else
    err "curl not found and apt-get not available. Install curl first."
  fi
fi

# ---------------------- Stage 2: NVM install (latest) ------------------------
if [[ ! -s "${NVM_DIR_USER}/nvm.sh" ]]; then
  [[ $QUIET -eq 1 ]] || log "Installing NVM (latest) for ${TARGET_USER} ..."
  as_user "$TARGET_USER" "curl -fsSL '${NVM_INSTALL_URL}' | bash"
else
  [[ $QUIET -eq 1 ]] || log "NVM already present at ${NVM_DIR_USER}"
fi

# ---------------------- Stage 3: Shell profile snippet -----------------------
PROFILE_MARKER="<<< node-env: nvm loader >>>"
PROFILE_SNIPPET=$(cat <<'SNIP'
export NVM_DIR="$HOME/.nvm"
# shellcheck disable=SC1091
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
# shellcheck disable=SC1091
[ -s "$NVM_DIR/bash_completion" ] && . "$NVM_DIR/bash_completion"
if command -v nvm >/dev/null 2>&1; then
  nvm use default >/dev/null 2>&1 || true
fi
SNIP
)
append_once "$BASHRC_USER" "$PROFILE_MARKER" "$PROFILE_SNIPPET"
chown "$TARGET_USER":"$TARGET_USER" "$BASHRC_USER" || true

# ---------------------- Stage 4: Node.js via NVM -----------------------------
[[ $QUIET -eq 1 ]] || log "Installing Node.js '${NODE_VERSION}' for ${TARGET_USER} ..."
nvm_run "$TARGET_USER" "$NVM_DIR_USER" "nvm install '${NODE_VERSION}'"
nvm_run "$TARGET_USER" "$NVM_DIR_USER" "nvm alias default '${NODE_VERSION}'"
nvm_run "$TARGET_USER" "$NVM_DIR_USER" "nvm use default"

# ---------------------- Stage 5: PM2 (no startup config) ---------------------
[[ $QUIET -eq 1 ]] || log "Installing PM2 (user-global) for ${TARGET_USER} ..."
nvm_run "$TARGET_USER" "$NVM_DIR_USER" "npm install -g pm2"

# ---------------------- Verification (optional) -------------------------------
nvm_run "$TARGET_USER" "$NVM_DIR_USER" "node -v && npm -v && pm2 -v" || true

# ---------------------- Completion -------------------------------------------
log "===== PREPARED: environment ready for user '$TARGET_USER' ====="
log "nvm dir: ${NVM_DIR_USER}"
log "node default: ${NODE_VERSION}"
log "pm2 installed for: ${TARGET_USER}"
log "Next steps (manual, out of scope of this script):"
log "  1) Populate app from git (your repo)"
log "  2) Create .env and credentials"
log "  3) Define a service (systemd or pm2 startup) and run app"
