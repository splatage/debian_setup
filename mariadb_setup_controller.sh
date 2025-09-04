#!/bin/bash
#
# MariaDB Primary/Multi-Replica Controller Script
#
# This script orchestrates the setup and management of a MariaDB primary/replica
# cluster. It is designed to be run from a dedicated controller (admin
# workstation/bastion) and configures the PRIMARY and REPLICA servers remotely
# via SSH.
#
# v1.3: Implements a direct ssh-to-ssh pipe for efficient backup streaming,
#       avoiding intermediate storage on the controller.
#
# PREREQUISITES:
#   - The controller machine must have passwordless SSH (key-based) access as
#     'root' to the PRIMARY and ALL REPLICA servers.
#

set -euo pipefail

# --- !! CONFIGURE THESE VARIABLES !! ---
readonly PRIMARY_IP="192.168.1.221"
# Add all replica IPs to this array.
readonly REPLICA_IP_LIST=(
  "192.168.1.222"
  "192.168.1.223"
)
# All remote operations will be performed as this user.
readonly SSH_USER="root"

# The MariaDB replication user. The password will be prompted for securely.
readonly REPL_USER="repl"

# ZFS and MariaDB settings (assuming they are uniform across all nodes).
readonly ZFS_DEVICE="/dev/nvme0n1"
readonly ZFS_POOL_NAME="mariadb_data"
readonly MARIADB_BASE_DIR="/var/lib/mysql"
readonly BACKUP_BASE_DIR="${MARIADB_BASE_DIR}/backups"
# --- END OF CONFIGURATION ---

# --- Helper Functions ---
readonly C_BOLD=$(tput bold)
readonly C_GREEN=$(tput setaf 2)
readonly C_YELLOW=$(tput setaf 3)
readonly C_RESET=$(tput sgr0)

# Prints an informational message.
# Args:
#   $1: The message string to print.
info() {
  echo -e "${C_BOLD}INFO:${C_RESET} ${1}"
}

# Prints a warning message.
# Args:
#   $1: The message string to print.
warn() {
  echo -e "${C_YELLOW}${C_BOLD}WARN:${C_RESET} ${1}"
}

# Prints a success message.
# Args:
#   $1: The message string to print.
success() {
  echo -e "${C_GREEN}${C_BOLD}SUCCESS:${C_RESET} ${1}"
}

#######################################
# Retrieves the full MariaDB configuration template.
#######################################
get_config_template() {
  cat << EOF
[mariadbd]

#################################################################
# REPLICATION / BINLOG (ROLE: {{ROLE}})

## PRIMARY
# server-id                     = {{SERVER_ID}}
# binlog_format                 = ROW
# binlog_row_image              = FULL
# sync_binlog                   = 0                   # perf; raise to 1 if you need crash-safe binlog
# gtid_strict_mode              = ON
# innodb_flush_log_at_trx_commit= 2                   # 1 = safest; 2 = faster

## Replica
# server-id                     = {{SERVER_ID}}
# read_only                     = ON
# skip_slave_start              = ON         # start manually first time
# log_slave_updates             = ON         # good for promotion later (keeps binlog chain)
# gtid_strict_mode              = ON
# If you set a non-zero domain on primary, match it here:
# gtid_domain_id                = 0
# Crash-safe relay logs
# relay_log_recovery            = ON
##################################################################

# GENERAL
user                          = mysql
bind-address                  = {{BIND_IP}}
port                          = 3306
skip-name-resolve
max_connections               = 1500
wait_timeout                  = 900
interactive_timeout           = 900
max_allowed_packet            = 256M
tmpdir                        = /tmp
performance_schema            = ON
socket                        = /var/run/mysqld/mysqld.sock

# CHARACTER SET
character-set-server          = utf8mb4
collation-server              = utf8mb4_general_ci  # keep unless you need stricter Unicode sort order

# DATA & LOGS
basedir                       = /usr
datadir                       = /var/lib/mysql/data
pid-file                      = /run/mysqld/mysqld.pid
log-error                     = /var/lib/mysql/log/error.log
slow_query_log_file           = /var/lib/mysql/log/slow-query.log
general_log_file              = /var/lib/mysql/log/mariadb.log
relay_log                     = /var/lib/mysql/log/relay-bin
log_bin                       = /var/lib/mysql/log/binlog
innodb_log_group_home_dir     = /var/lib/mysql/log
expire_logs_days              = 10

# SLOW LOGGING  (reduce overhead vs your current settings)
slow_query_log                = ON
log_queries_not_using_indexes = OFF                 # too noisy/costly at scale
long_query_time               = 0.05                # was 0.001; sample instead:
log_slow_rate_limit           = 10                  # log ~1 in 10 slow queries
log_slow_verbosity            = query_plan,innodb  # "ALL" is heavy

# CONNECTION / THREAD POOL
thread_handling               = pool-of-threads
thread_pool_size              = 8                  # start ≈ num physical cores; tune by test
thread_pool_stall_limit       = 60                  # use sane default; 10 can cause churn
thread_pool_max_threads       = 1000
thread_cache_size             = 256

# INNODB ENGINE
default-storage-engine        = InnoDB
innodb_file_per_table         = 1
innodb_flush_method           = O_DIRECT            # avoids double caching; ZFS may ignore, harmless
innodb_doublewrite            = 0                   # OK on ZFS (CoW + checksums)
innodb_use_native_aio         = 0
innodb_use_atomic_writes      = 0
innodb_log_file_size          = 4096M               # total redo = 8G; good for write bursts
innodb_log_files_in_group     = 2
innodb_log_buffer_size        = 64M
innodb_buffer_pool_size       = 16G                 # raise (you had 32G); fits your 128G box plan
innodb_buffer_pool_instances  = 8
innodb_io_capacity            = 20000
innodb_io_capacity_max        = 30000
innodb_flush_neighbors        = 0
innodb_checksum_algorithm     = crc32
innodb_compression_algorithm  = none
innodb_compression_level      = 0
innodb_autoinc_lock_mode      = 2
innodb_stats_on_metadata      = OFF
innodb_purge_threads          = 4
innodb_lru_scan_depth         = 4096                # (replace non-standard lru_flush_size)
innodb_log_write_ahead_size   = 16k
innodb_page_size              = 16384

# TEMP / PER-CONNECTION BUFFERS (safer caps)
tmp_table_size                = 256M                # was 512M; reduce bloat risk
max_heap_table_size           = 256M
join_buffer_size              = 4M                  # was 24M; large per-conn buffers = RAM spikes
sort_buffer_size              = 4M

# TABLE / FILE CACHES
table_open_cache              = 8000
table_definition_cache        = 8000
open_files_limit              = 200000

# QUERY CACHE OFF (good)
query_cache_type              = 0
query_cache_size              = 0

# MONITORING (keep moderate)
plugin_load_add               = query_response_time
query-response-time-stats     = 1
EOF
}

#######################################
# Remotely configures a single node with ZFS and MariaDB.
#######################################
configure_node() {
  local node_ip="${1}"
  local role="${2}"
  info "Configuring node ${node_ip} as a ${role}..."

  local server_id
  server_id=$(echo "${node_ip}" | awk -F. '{printf "%d%03d", $3, $4}')

  local bind_ip
  if [[ "${role}" == "Replica" ]]; then
    bind_ip="127.0.0.1"
    info "Role is Replica, setting bind-address to localhost."
  else
    bind_ip="${node_ip}"
  fi

  local config_content
  config_content=$(get_config_template | \
    sed "s/{{ROLE}}/${role}/g" | \
    sed "s/{{SERVER_ID}}/${server_id}/g" | \
    sed "s/{{BIND_IP}}/${bind_ip}/g")

  if [[ "${role}" == "Primary" ]]; then
    config_content=$(echo "${config_content}" | \
      sed -e '/## PRIMARY/,/## Replica/{ s/^# //; }')
  else
    config_content=$(echo "${config_content}" | \
      sed -e '/## Replica/,/##################################################################/{ s/^# //; }')
  fi

  ssh "${SSH_USER}@${node_ip}" "bash -s" -- << EOF
set -e
info() { echo "[REMOTE] INFO: \$1"; }
warn() { echo "[REMOTE] WARN: \$1"; }
success() { echo "[REMOTE] SUCCESS: \$1"; }

info "Running initial setup on ${node_ip}"
if zpool list "${ZFS_POOL_NAME}" &>/dev/null; then
  warn "ZFS pool '${ZFS_POOL_NAME}' already exists. Skipping creation."
else
  info "Creating ZFS pool ${ZFS_POOL_NAME} on ${ZFS_DEVICE}"
  zpool create "${ZFS_POOL_NAME}" "${ZFS_DEVICE}" -f
fi

zfs set mountpoint="${MARIADB_BASE_DIR}" "${ZFS_POOL_NAME}"
zfs set compression=lz4 atime=off logbias=throughput "${ZFS_POOL_NAME}"
zfs create -o mountpoint="${MARIADB_BASE_DIR}/data" \
  -o recordsize=16k -o primarycache=metadata \
  "${ZFS_POOL_NAME}/data" 2>/dev/null || warn "Data dataset exists."
zfs create -o mountpoint="${MARIADB_BASE_DIR}/log" \
  "${ZFS_POOL_NAME}/log" 2>/dev/null || warn "Log dataset exists."
success "ZFS setup complete."

info "Installing MariaDB..."
apt-get update >/dev/null
apt-get install -y curl >/dev/null
curl -LsSO https://r.mariadb.com/downloads/mariadb_repo_setup
chmod +x mariadb_repo_setup
./mariadb_repo_setup --mariadb-server-version="mariadb-11.4"
apt-get install -y mariadb-server mariadb-backup
success "MariaDB installed."

info "Stopping MariaDB to apply configuration..."
systemctl stop mariadb

info "Writing new configuration file..."
cat > /etc/mysql/mariadb.conf.d/50-server.cnf << CONFIG_EOF
${config_content}
CONFIG_EOF

if [ ! -d "${MARIADB_BASE_DIR}/data/mysql" ]; then
  info "Initializing new MariaDB data directory..."
  mariadb-install-db --user=mysql --datadir="${MARIADB_BASE_DIR}/data"
fi
chown -R mysql:mysql "${MARIADB_BASE_DIR}"
systemctl start mariadb
success "Node ${node_ip} successfully configured as a ${role}."
EOF
}

#######################################
# Seeds a chosen replica with a fresh backup from the primary.
#######################################
seed_replica() {
  info "Which replica do you want to seed?"
  PS3="Please choose a target replica: "
  select target_replica_ip in "${REPLICA_IP_LIST[@]}"; do
    if [[ -n "${target_replica_ip}" ]]; then
      break
    else
      echo "Invalid selection."
    fi
  done
  info "Starting seed from PRIMARY (${PRIMARY_IP}) to REPLICA (${target_replica_ip})."

  local repl_password
  read -sp "Enter the password for the '${REPL_USER}' replication user: " \
    repl_password
  echo ""
  if [[ -z "${repl_password}" ]]; then
    echo "Error: Password cannot be empty." >&2
    exit 1
  fi
  local repl_password_b64
  repl_password_b64=$(echo -n "${repl_password}" | base64)

  info "Step 1: Ensuring replication user '${REPL_USER}' exists on Primary..."
  ssh "${SSH_USER}@${PRIMARY_IP}" "bash -s" -- << EOF
set -e
readonly DECODED_PASSWORD="\$(echo '${repl_password_b64}' | base64 -d)"
cat << SQL | mariadb
CREATE OR REPLACE USER '${REPL_USER}'@'%' IDENTIFIED BY '\${DECODED_PASSWORD}';
GRANT REPLICATION SLAVE ON *.* TO '${REPL_USER}'@'%';
FLUSH PRIVILEGES;
SQL
EOF
  success "Replication user configured on Primary."

  local now; now=$(date +%F_%H-%M)
  local backdir_name="backup-${now}"
  local backdir_path="${BACKUP_BASE_DIR}/${backdir_name}"
  info "Step 2: Taking backup on Primary using mariabackup..."
  ssh "${SSH_USER}@${PRIMARY_IP}" "bash -s" -- << EOF
set -e
mkdir -p '${backdir_path}'
mariabackup --backup --target-dir='${backdir_path}' --parallel=4
mariabackup --prepare --target-dir='${backdir_path}'
EOF
  success "Backup created and prepared on Primary in ${backdir_path}."

  local gtid
  gtid=$(ssh "${SSH_USER}@${PRIMARY_IP}" \
    "awk '{print \$3}' '${backdir_path}/mariadb_backup_binlog_info'")
  info "Captured GTID position for seeding: ${C_GREEN}${C_BOLD}${gtid}${C_RESET}"

  info "Step 3: Streaming backup from Primary to Replica via tar pipe..."
  ssh "${SSH_USER}@${PRIMARY_IP}" \
    "tar -c -C '${BACKUP_BASE_DIR}' '${backdir_name}'" \
    | \
  ssh "${SSH_USER}@${target_replica_ip}" \
    "mkdir -p '${BACKUP_BASE_DIR}' && tar -x -C '${BACKUP_BASE_DIR}'"
  success "Backup streamed and extracted on replica."
  
  info "Step 4: Applying backup and configuring replication on Replica..."
  ssh "${SSH_USER}@${target_replica_ip}" "bash -s" -- << EOF
set -e
info() { echo "[REMOTE] INFO: \$1"; }
success() { echo "[REMOTE] SUCCESS: \$1"; }
readonly DECODED_PASSWORD="\$(echo '${repl_password_b64}' | base64 -d)"

info "Stopping MariaDB service on replica..."
systemctl stop mariadb

info "Clearing existing data and log directories..."
rm -rf "${MARIADB_BASE_DIR:?}/data/"*
rm -rf "${MARIADB_BASE_DIR:?}/log/"*

info "Restoring from backup..."
mariabackup --copy-back --target-dir="${BACKUP_BASE_DIR}/${backdir_name}"
chown -R mysql:mysql "${MARIADB_BASE_DIR}"

info "Starting MariaDB service..."
systemctl start mariadb
success "Restore complete. MariaDB started."

info "Configuring replication..."
cat << SQL | mariadb
STOP SLAVE;
SET GLOBAL gtid_slave_pos='${gtid}';
CHANGE MASTER TO
    MASTER_HOST='${PRIMARY_IP}',
    MASTER_USER='${REPL_USER}',
    MASTER_PASSWORD='\${DECODED_PASSWORD}',
    MASTER_USE_GTID=slave_pos;
START SLAVE;
SQL
success "Replication configured and started."

info "Verifying slave status (check for Yes/Yes):"
mariadb -e "SHOW SLAVE STATUS\G"
EOF
  success "Replica seed process complete for ${target_replica_ip}."
}

#######################################
# Rotates the replication password on the primary and all configured replicas.
#######################################
re_auth_replicas() {
  info "Starting replication credential rotation."
  local new_repl_password
  read -sp "Enter the NEW password for the '${REPL_USER}' user: " new_repl_password
  echo ""
  if [[ -z "${new_repl_password}" ]]; then
    echo "Error: Password cannot be empty." >&2
    exit 1
  fi
  local new_repl_password_b64
  new_repl_password_b64=$(echo -n "${new_repl_password}" | base64)
  
  info "Step 1: Updating password on the PRIMARY server..."
  ssh "${SSH_USER}@${PRIMARY_IP}" "bash -s" -- << EOF
set -e
readonly DECODED_PASSWORD="\$(echo '${new_repl_password_b64}' | base64 -d)"
cat << SQL | mariadb
CREATE OR REPLACE USER '${REPL_USER}'@'%' IDENTIFIED BY '\${DECODED_PASSWORD}';
GRANT REPLICATION SLAVE ON *.* TO '${REPL_USER}'@'%';
FLUSH PRIVILEGES;
SQL
EOF
  success "Password updated on Primary."
  
  info "Step 2: Rolling out new password to all replicas..."
  for replica_ip in "${REPLICA_IP_LIST[@]}"; do
    info "Updating replica ${replica_ip}..."
    ssh "${SSH_USER}@${replica_ip}" "bash -s" -- << EOF
set -e
readonly DECODED_PASSWORD="\$(echo '${new_repl_password_b64}' | base64 -d)"
cat << SQL | mariadb
STOP SLAVE;
CHANGE MASTER TO MASTER_PASSWORD='\${DECODED_PASSWORD}';
START SLAVE;
SQL
EOF
    success "Replica ${replica_ip} updated."
  done
  success "Credential rotation complete for all replicas."
}

#######################################
# Performs a live role switchover between the primary and a chosen replica.
#######################################
switchover_roles() {
  info "Which replica do you want to promote to be the new Primary?"
  PS3="Please choose a target replica: "
  select promoted_replica_ip in "${REPLICA_IP_LIST[@]}"; do
    if [[ -n "${promoted_replica_ip}" ]]; then
      break
    else
      echo "Invalid selection."
    fi
  done

  local other_replica_ips=()
  for ip in "${REPLICA_IP_LIST[@]}"; do
    if [[ "${ip}" != "${promoted_replica_ip}" ]]; then
      other_replica_ips+=("${ip}")
    fi
  done

  local repl_password
  read -sp "Enter the password for the '${REPL_USER}' replication user: " \
    repl_password
  echo ""
  if [[ -z "${repl_password}" ]]; then
    echo "Error: Password cannot be empty." >&2
    exit 1
  fi
  local repl_password_b64
  repl_password_b64=$(echo -n "${repl_password}" | base64)

  warn "!!! STARTING LIVE ROLE SWITCHOVER !!!"
  warn "  - This will PROMOTE  : ${promoted_replica_ip}"
  warn "  - This will DEMOTE   : ${PRIMARY_IP}"
  if [[ ${#other_replica_ips[@]} -gt 0 ]]; then
    warn "  - This will RE-POINT : ${other_replica_ips[*]}"
  fi

  read -rp "Are you sure you want to continue? [y/N]: " choice
  if [[ ! "${choice}" =~ ^[Yy]$ ]]; then
    echo "Aborting."
    exit 0
  fi

  info "Step 1: Ensuring ALL replicas are fully synchronized..."
  for replica_ip in "${REPLICA_IP_LIST[@]}"; do
    local behind=1
    local count=0
    info "Checking sync status of ${replica_ip}..."
    while [[ ${behind} -ne 0 && ${count} -lt 60 ]]; do
      behind=$(ssh "${SSH_USER}@${replica_ip}" \
        "mariadb -e 'SHOW SLAVE STATUS\G'" | \
        grep 'Seconds_Behind_Master:' | awk '{print $2}')
      if [[ "${behind}" == "0" ]]; then
        break
      fi
      echo "  - ${replica_ip} is ${behind} seconds behind master. Waiting..."
      sleep 1
      ((count++))
    done
    if [[ ${behind} -ne 0 ]]; then
      echo "Error: Replica ${replica_ip} did not catch up. Aborting." >&2
      exit 1
    fi
    success "Replica ${replica_ip} is synchronized."
  done

  info "Step 2: Putting old Primary (${PRIMARY_IP}) into read-only mode..."
  ssh "${SSH_USER}@${PRIMARY_IP}" \
    "mariadb -e 'SET GLOBAL read_only = ON; FLUSH TABLES WITH READ LOCK;'"
  success "Old Primary is now read-only."

  info "Step 3: Promoting Replica (${promoted_replica_ip}) to be new Primary..."
  ssh "${SSH_USER}@${promoted_replica_ip}" \
    "mariadb -e 'STOP SLAVE; RESET MASTER; SET GLOBAL read_only = OFF;'"
  success "New Primary is live. Point applications to ${promoted_replica_ip} NOW."

  info "Step 4: Reconfiguring old Primary (${PRIMARY_IP}) to new Primary..."
  ssh "${SSH_USER}@${PRIMARY_IP}" "bash -s" -- << EOF
set -e
readonly DECODED_PASSWORD="\$(echo '${repl_password_b64}' | base64 -d)"
cat << SQL | mariadb
UNLOCK TABLES;
CHANGE MASTER TO
    MASTER_HOST='${promoted_replica_ip}',
    MASTER_USER='${REPL_USER}',
    MASTER_PASSWORD='\${DECODED_PASSWORD}',
    MASTER_USE_GTID=slave_pos;
START SLAVE;
SQL
EOF
  success "Old Primary is now a replica of the new Primary."

  if [[ ${#other_replica_ips[@]} -gt 0 ]]; then
    info "Step 5: Re-pointing all other replicas to the new Primary..."
    for replica_ip in "${other_replica_ips[@]}"; do
      info "  - Re-pointing ${replica_ip}..."
      ssh "${SSH_USER}@${replica_ip}" "bash -s" -- << EOF
set -e
cat << SQL | mariadb
STOP SLAVE;
CHANGE MASTER TO MASTER_HOST='${promoted_replica_ip}';
START SLAVE;
SQL
EOF
      success "    Replica ${replica_ip} is now following ${promoted_replica_ip}."
    done
  fi

  info "Step 6: Verifying replication status on all new replicas..."
  info "--- Status for new replica ${PRIMARY_IP} ---"
  ssh "${SSH_USER}@${PRIMARY_IP}" "mariadb -e 'SHOW SLAVE STATUS\G'"
  for replica_ip in "${other_replica_ips[@]}"; do
    info "--- Status for replica ${replica_ip} ---"
    ssh "${SSH_USER}@${replica_ip}" "mariadb -e 'SHOW SLAVE STATUS\G'"
  done
  
  warn " SWITCHOVER COMPLETE. ROLES ARE NOW RECONFIGURED."
  warn "   - New Primary: ${promoted_replica_ip}"
  warn "   - New Replicas: ${PRIMARY_IP} ${other_replica_ips[*]}"
  warn "   - You MUST update this script's configuration variables"
  warn "     (PRIMARY_IP, REPLICA_IP_LIST) to reflect the new reality"
  warn "     before running it again."
}

#######################################
# Main execution logic for the script.
#######################################
main() {
  if [[ -z "${1:-}" ]]; then
    echo "Usage: $0 --action <ACTION>"
    echo "Actions:"
    echo "  setup-node        -- Configure a node as Primary or Replica."
    echo "  seed-replica      -- Wipes a chosen Replica and seeds it with a"
    echo "                       fresh backup from the Primary."
    echo "  re-auth           -- Rotates the replication password on the Primary"
    echo "                       and all Replicas."
    echo "  switchover        -- Interactively promotes a chosen Replica to be the"
    echo "                       new Primary."
    exit 1
  fi
  case "${1}" in
    --action)
      case "${2:-}" in
        setup-node)
          local node_ip
          local node_role
          read -rp "Enter IP of the node to set up: " node_ip
          read -rp "Enter role for this node (Primary/Replica): " node_role
          configure_node "${node_ip}" "${node_role}"
          ;;
        seed-replica)
          seed_replica
          ;;
        re-auth)
          re_auth_replicas
          ;;
        switchover)
          switchover_roles
          ;;
        *)
          echo "Error: Unknown action '${2:-}'" >&2
          exit 1
          ;;
      esac
      ;;
    *)
      echo "Error: Unknown argument '${1}'" >&2
      exit 1
      ;;
  esac
}

main "$@"
