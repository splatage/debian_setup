#!/bin/bash
#
# MariaDB Primary/Multi-Replica Controller Script
#
# This script orchestrates the setup and management of a MariaDB primary/replica cluster.
# It is designed to be run from the PRIMARY server (or an admin host) and configures
# REPLICA servers remotely via SSH.
#
# Features:
#   - Manages multiple replicas.
#   - Can provision replicas individually.
#   - Includes a credential rotation ('re-auth') function.
#   - Includes a live role switchover function (for single-replica scenarios).
#

set -euo pipefail

# --- !! CONFIGURE THESE VARIABLES !! ---
readonly PRIMARY_IP="192.168.1.221"
# Add all replica IPs to this array
readonly REPLICA_IP_LIST=(
    "192.168.1.223"
    "192.168.1.224"
    # "192.168.1.225"
)
readonly REPLICA_SSH_USER="root" # User on the replica with root/sudo access

# The MariaDB replication user. The password will be prompted for securely.
readonly REPL_USER="repl"

# ZFS and MariaDB settings (assuming they are uniform)
readonly ZFS_DEVICE="/dev/nvme0n1" # Device for ZFS pool on the target server
readonly ZFS_POOL_NAME="mariadb_data"
readonly MARIADB_BASE_DIR="/var/lib/mysql"
readonly BACKUP_BASE_DIR="${MARIADB_BASE_DIR}/backups"
# --- END OF CONFIGURATION ---

# --- Helper Functions ---
c_bold=$(tput bold)
c_green=$(tput setaf 2)
c_yellow=$(tput setaf 3)
c_reset=$(tput sgr0)
info() { echo -e "${c_bold}INFO:${c_reset} $1"; }
warn() { echo -e "${c_yellow}${c_bold}WARN:${c_reset} $1"; }
success() { echo -e "${c_green}${c_bold}SUCCESS:${c_reset} $1"; }

# --- CORE FUNCTIONS ---

get_config_template() {
    # This heredoc contains your full, unmodified configuration template.
    # Placeholders like {{ROLE}}, {{SERVER_ID}}, {{BIND_IP}} will be replaced.
    cat << 'EOF'
[mariadbd]

#################################################################
# REPLICATION / BINLOG (ROLE: {{ROLE}})

## PRIMARY
# server-id                     = {{SERVER_ID}}
# binlog_format                 = ROW
# binlog_row_image              = FULL
# expire_logs_days              = 10
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
expire_logs_days              = 7

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
innodb_compression_level      =
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

configure_node() {
    local node_ip=$1
    local role=$2 # Primary or Replica
    local ssh_user=$3

    info "Configuring node ${node_ip} as a ${role}..."

    local server_id
    server_id=$(echo "$node_ip" | awk -F. '{printf "%d%03d", $3, $4}')

    local bind_ip
    if [ "$role" = "Replica" ]; then
        bind_ip="127.0.0.1"
        info "Role is Replica, setting bind-address to localhost."
    else
        bind_ip="$node_ip"
    fi

    local config_content
    config_content=$(get_config_template | \
        sed "s/{{ROLE}}/${role}/g" | \
        sed "s/{{SERVER_ID}}/${server_id}/g" | \
        sed "s/{{BIND_IP}}/${bind_ip}/g")

    if [ "$role" = "Primary" ]; then
        config_content=$(echo "$config_content" | sed -e '/## PRIMARY/,/## Replica/{ s/^# //; }')
    else
        config_content=$(echo "$config_content" | sed -e '/## Replica/,/##################################################################/{ s/^# //; }')
    fi
    
    ssh "${ssh_user}@${node_ip}" "bash -s" -- << EOF
set -e
info() { echo "[REMOTE] INFO: \$1"; }
warn() { echo "[REMOTE] WARN: \$1"; }
success() { echo "[REMOTE] SUCCESS: \$1"; }

info "Running initial setup on ${node_ip}"
zpool list ${ZFS_POOL_NAME} &>/dev/null || {
    info "Creating ZFS pool ${ZFS_POOL_NAME} on ${ZFS_DEVICE}"
    zpool create ${ZFS_POOL_NAME} ${ZFS_DEVICE} -f
}
zfs set mountpoint=${MARIADB_BASE_DIR} ${ZFS_POOL_NAME}
zfs set compression=lz4 atime=off logbias=throughput ${ZFS_POOL_NAME}
zfs create -o mountpoint=${MARIADB_BASE_DIR}/data -o recordsize=16k -o primarycache=metadata ${ZFS_POOL_NAME}/data 2>/dev/null || warn "Data dataset exists."
zfs create -o mountpoint=${MARIADB_BASE_DIR}/log ${ZFS_POOL_NAME}/log 2>/dev/null || warn "Log dataset exists."
success "ZFS setup complete."

info "Installing MariaDB..."
apt-get update >/dev/null
apt-get install -y curl >/dev/null
curl -sO https://downloads.mariadb.com/MariaDB/mariadb_repo_setup
chmod +x mariadb_repo_setup
./mariadb_repo_setup --mariadb-server-version="mariadb-11.4"
apt-get install -y mariadb-server mariadb-backup
success "MariaDB installed."

info "Stopping MariaDB to apply configuration..."
systemctl stop mariadb

info "Writing new configuration file..."
cat > /etc/mysql/mariadb.conf.d/50-server.cnf << 'CONFIG_EOF'
${config_content}
CONFIG_EOF

if [ ! -d "${MARIADB_BASE_DIR}/data/mysql" ]; then
    info "Initializing new MariaDB data directory..."
    mariadb-install-db --user=mysql --datadir="${MARIADB_BASE_DIR}/data"
fi
chown -R mysql:mysql ${MARIADB_BASE_DIR}
systemctl start mariadb
success "Node ${node_ip} successfully configured as a ${role}."
EOF
}

seed_replica() {
    info "Which replica do you want to seed?"
    PS3="Please choose a target replica: "
    select target_replica_ip in "${REPLICA_IP_LIST[@]}"; do
        if [[ -n "$target_replica_ip" ]]; then break; else echo "Invalid selection."; fi
    done

    info "Starting replica seed from PRIMARY (${PRIMARY_IP}) to REPLICA (${target_replica_ip})."
    
    read -sp "Enter the password for the '${REPL_USER}' replication user: " REPL_PASSWORD
    echo ""
    if [ -z "$REPL_PASSWORD" ]; then echo "Error: Password cannot be empty." >&2; exit 1; fi

    info "Step 1: Ensuring replication user '${REPL_USER}' exists on Primary..."
    mariadb -e "CREATE OR REPLACE USER '${REPL_USER}'@'%' IDENTIFIED BY '${REPL_PASSWORD}'; GRANT REPLICATION SLAVE ON *.* TO '${REPL_USER}'@'%'; FLUSH PRIVILEGES;"
    success "Replication user configured."

    local NOW
    NOW=$(date +%F_%H-%M)
    local BACKDIR="${BACKUP_BASE_DIR}/backup-${NOW}"
    mkdir -p "$BACKDIR"
    
    info "Step 2: Taking backup on Primary using mariabackup..."
    mariabackup --backup --target-dir="$BACKDIR" --parallel=4
    mariabackup --prepare --target-dir="$BACKDIR"
    success "Backup created and prepared in ${BACKDIR}."

    local GTID
    GTID=$(awk '{print $3}' "$BACKDIR/mariadb_backup_binlog_info")
    info "Captured GTID position for seeding: ${c_green}${c_bold}${GTID}${c_reset}"

    info "Step 3: Copying backup to Replica via rsync..."
    rsync -auv --info=progress2 "$BACKDIR" "${REPLICA_SSH_USER}@${target_replica_ip}:${BACKUP_BASE_DIR}/"
    success "Backup copied to replica."
    
    info "Step 4: Applying backup and configuring replication on Replica..."
    ssh "${REPLICA_SSH_USER}@${target_replica_ip}" "bash -s" -- << EOF
set -e
info() { echo "[REMOTE] INFO: \$1"; }
success() { echo "[REMOTE] SUCCESS: \$1"; }

info "Stopping MariaDB service on replica..."
systemctl stop mariadb

info "Clearing existing data and log directories..."
rm -rf "${MARIADB_BASE_DIR:?}/data/"* "${MARIADB_BASE_DIR:?}/log/"*

info "Restoring from backup..."
mariabackup --copy-back --target-dir="${BACKUP_BASE_DIR}/backup-${NOW}"
chown -R mysql:mysql "${MARIADB_BASE_DIR}"

info "Starting MariaDB service..."
systemctl start mariadb
success "Restore complete. MariaDB started."

info "Configuring replication..."
mariadb -e "
    STOP SLAVE;
    SET GLOBAL gtid_slave_pos='${GTID}';
    CHANGE MASTER TO
        MASTER_HOST='${PRIMARY_IP}',
        MASTER_USER='${REPL_USER}',
        MASTER_PASSWORD='${REPL_PASSWORD}',
        MASTER_USE_GTID=slave_pos;
    START SLAVE;
"
success "Replication configured and started."

info "Verifying slave status (check for Yes/Yes):"
mariadb -e "SHOW SLAVE STATUS\G"
EOF
    success "Replica seed process complete for ${target_replica_ip}."
}

re_auth_replicas() {
    info "Starting replication credential rotation."
    
    read -sp "Enter the NEW password for the '${REPL_USER}' user: " NEW_REPL_PASSWORD
    echo ""
    if [ -z "$NEW_REPL_PASSWORD" ]; then echo "Error: Password cannot be empty." >&2; exit 1; fi
    
    info "Step 1: Updating password on the PRIMARY server..."
    mariadb -e "CREATE OR REPLACE USER '${REPL_USER}'@'%' IDENTIFIED BY '${NEW_REPL_PASSWORD}'; GRANT REPLICATION SLAVE ON *.* TO '${REPL_USER}'@'%'; FLUSH PRIVILEGES;"
    success "Password updated on Primary."
    
    info "Step 2: Rolling out new password to all replicas..."
    for replica_ip in "${REPLICA_IP_LIST[@]}"; do
        info "Updating replica ${replica_ip}..."
        ssh "${REPLICA_SSH_USER}@${replica_ip}" "bash -s" -- << EOF
set -e
mariadb -e "
    STOP SLAVE;
    CHANGE MASTER TO MASTER_PASSWORD='${NEW_REPL_PASSWORD}';
    START SLAVE;
"
EOF
        success "Replica ${replica_ip} updated."
    done
    
    success "Credential rotation complete for all replicas."
}

switchover_roles() {
    if [ ${#REPLICA_IP_LIST[@]} -ne 1 ]; then
        warn "Switchover is designed for a simple Primary <-> single Replica scenario."
        warn "You have multiple replicas configured. This automated switchover is disabled."
        exit 1
    fi
    local target_replica_ip=${REPLICA_IP_LIST[0]}
    read -sp "Enter the password for the '${REPL_USER}' replication user: " REPL_PASSWORD
    echo ""

    warn "!!! STARTING LIVE ROLE SWITCHOVER !!!"
    warn "This will promote ${target_replica_ip} to Primary and demote ${PRIMARY_IP} to Replica."
    read -rp "Are you sure you want to continue? [y/N]: " choice
    if [[ ! "$choice" =~ ^[Yy]$ ]]; then echo "Aborting."; exit 0; fi

    info "Step 1: Ensuring replica is fully synchronized..."
    local behind=1; local count=0
    while [[ $behind -ne 0 && $count -lt 60 ]]; do
        behind=$(ssh "${REPLICA_SSH_USER}@${target_replica_ip}" "mariadb -e 'SHOW SLAVE STATUS\G'" | grep 'Seconds_Behind_Master:' | awk '{print $2}')
        if [[ "$behind" == "0" ]]; then break; fi
        echo "Replica is $behind seconds behind master. Waiting..."
        sleep 1; ((count++))
    done
    if [[ $behind -ne 0 ]]; then echo "Error: Replica did not catch up. Aborting." >&2; exit 1; fi
    success "Replica is fully synchronized."

    info "Step 2: Putting old Primary (${PRIMARY_IP}) into read-only mode..."
    mariadb -e "SET GLOBAL read_only = ON; FLUSH TABLES WITH READ LOCK;"
    success "Old Primary is now read-only."

    info "Step 3: Promoting Replica (${target_replica_ip}) to be the new Primary..."
    ssh "${REPLICA_SSH_USER}@${target_replica_ip}" "mariadb -e 'STOP SLAVE; RESET MASTER; SET GLOBAL read_only = OFF;'"
    success "New Primary is live. Point your applications to ${target_replica_ip} NOW."

    info "Step 4: Reconfiguring old Primary (${PRIMARY_IP}) to replicate from new Primary..."
    mariadb -e "
        UNLOCK TABLES;
        CHANGE MASTER TO
            MASTER_HOST='${target_replica_ip}',
            MASTER_USER='${REPL_USER}',
            MASTER_PASSWORD='${REPL_PASSWORD}',
            MASTER_USE_GTID=slave_pos;
        START SLAVE;
    "
    success "Old Primary is now a replica of the new Primary."

    info "Step 5: Verifying replication status on the new replica (${PRIMARY_IP})..."
    mariadb -e "SHOW SLAVE STATUS\G"
    
    warn " SWITCHOVER COMPLETE. ROLES ARE NOW REVERSED. You MUST update this script's variables to reflect the new reality."
}

# --- Main CLI Logic ---
if [ -z "${1:-}" ]; then
    echo "Usage: $0 --action <ACTION>"
    echo "Actions:"
    echo "  setup-node        -- Interactively configure a node as Primary or Replica."
    echo "  seed-replica      -- Wipes a chosen Replica and seeds it with a fresh backup from the Primary."
    echo "  re-auth           -- Rotates the replication password on the Primary and all Replacas."
    echo "  switchover        -- Promotes the Replica to Primary (only for single-replica setups)."
    exit 1
fi

case "$1" in
    --action)
        case "${2:-}" in
            setup-node)
                read -rp "Enter IP of the node to set up: " node_ip
                read -rp "Enter role for this node (Primary/Replica): " node_role
                configure_node "$node_ip" "$node_role" "$REPLICA_SSH_USER"
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
                echo "Error: Unknown action '$2'" >&2
                exit 1
                ;;
        esac
        ;;
    *)
        echo "Error: Unknown argument '$1'" >&2
        exit 1
        ;;
esac
