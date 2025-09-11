#!/bin/bash
set -euo pipefail

# --- Config ---
USERS_URL="https://raw.githubusercontent.com/splatage/debian_setup/refs/heads/main/users.keys"

# --- Key validation regex ---
VALID_KEY_REGEX='^(ssh-(rsa|ed25519|dss|ecdsa|sk-))'

declare -a default_keys=()
declare -A user_keys
current_user=""

# --- Stream + Parse INI ---
curl -fsSL "$USERS_URL" | while IFS= read -r line; do
  [[ -z "$line" || "$line" =~ ^# ]] && continue

  if [[ "$line" =~ ^\[.*\]$ ]]; then
    current_user="${line#[}"
    current_user="${current_user%]}"
  else
    if [[ ! "$line" =~ $VALID_KEY_REGEX ]]; then
      echo "!! Invalid SSH key format detected in $USERS_URL"
      exit 1
    fi

    if [[ "$current_user" == "default" ]]; then
      default_keys+=("$line")
    else
      user_keys["$current_user"]+="$line"$'\n'
    fi
  fi
done

# --- Provision users ---
for user in "${!user_keys[@]}"; do
  echo ">>> Configuring user: $user"

  if ! id -u "$user" &>/dev/null; then
    adduser --disabled-password --gecos "" "$user"
  fi

  homedir=$(eval echo "~$user")
  sshdir="$homedir/.ssh"
  authfile="$sshdir/authorized_keys"

  mkdir -p "$sshdir"
  chmod 700 "$sshdir"
  chown -R "$user:$user" "$sshdir"

  # Build expected key list
  expected_keys=("${default_keys[@]}")
  while IFS= read -r key; do
    [[ -z "$key" ]] && continue
    expected_keys+=("$key")
  done <<< "${user_keys[$user]}"

  # De-dupe + sort in memory
  IFS=$'\n' read -r -d '' -a sorted_expected < <(printf "%s\n" "${expected_keys[@]}" | sort -u && printf '\0')

  # Read current keys (if any)
  if [[ -f "$authfile" ]]; then
    IFS=$'\n' read -r -d '' -a sorted_current < <(sort -u "$authfile" && printf '\0')
  else
    sorted_current=()
  fi

  # Compare
  if diff <(printf "%s\n" "${sorted_current[@]}") <(printf "%s\n" "${sorted_expected[@]}") >/dev/null; then
    echo "    ✓ Keys already up to date"
  else
    echo "    ! Key drift detected"
    echo "      - Removed:"
    comm -23 <(printf "%s\n" "${sorted_current[@]}") <(printf "%s\n" "${sorted_expected[@]}") | sed 's/^/        /'
    echo "      + Added:"
    comm -13 <(printf "%s\n" "${sorted_current[@]}") <(printf "%s\n" "${sorted_expected[@]}") | sed 's/^/        /'

    # Enforce new keys
    printf "%s\n" "${sorted_expected[@]}" > "$authfile"
    chmod 600 "$authfile"
    chown "$user:$user" "$authfile"
    echo "    ✓ Updated authorized_keys"
  fi
done
