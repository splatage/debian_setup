## Uniform setup for mariadb

zpool create mariadb_data /dev/nvme0n1 -f
zfs set mountpoint=/var/lib/mysql mariadb_data
zfs set compression=lz4 atime=off logbias=throughput mariadb_data
zfs create -o mountpoint=/var/lib/mysql/data -o recordsize=16k -o primarycache=metadata mariadb_data/data
zfs create -o mountpoint=/var/lib/mysql/log mariadb_data/log

apt install curl
wget https://downloads.mariadb.com/MariaDB/mariadb_repo_setup
chmod +x mariadb_repo_setup
./mariadb_repo_setup --mariadb-server-version="mariadb-11.4.8"
apt install -y mariadb-server mariadb-backup

##################################################
## Copy config and setup replica


PRIMARY=192.168.1.221
REPLICA=192.168.1.223
# On PRIMARY

# Setup replica user
$maraidb 
SHOW MASTER STATUS;
# RENAME USER 'repl'@'192.168.1.225' TO 'repl'@'%';
GRANT REPLICATION SLAVE ON *.* TO 'repl'@'%';
FLUSH PRIVILEGES;


# Setup the dir
NOW=$(date +%F_%H-%M)
BASE_DIR=/var/lib/mysql/backups
BACKDIR=${BASE_DIR}/backup-${NOW}
mkdir -p "$BACKDIR"
cd ${BASE_DIR}

# 1) Backup (parallel optional)
mariabackup --backup --target-dir=${BACKDIR} --parallel=4

# 2) Prepare (must run on the SAME dir you backed up)
mariabackup --prepare --target-dir=${BACKDIR}

# 3) Confirm snapshot coordinates (for GTID seeding later)
cat "$BACKDIR/mariadb_backup_binlog_info"
# => binlog.000030  43665  0-1-540  (example; the 3rd field is the GTID to use)
GTID=$(awk '{print $3}' "$BACKDIR/mariadb_backup_binlog_info")
echo ${GTID}

# Copy across
rsync -auv backup-${NOW} ${REPLICA}:${BASE_DIR}/


# Prep the replica
ssh ${REPLICA} << EOF
service mariadb stop
service mariadb status
cd /var/lib/mysql
rm -rf data/* log/*
mariadb-backup --copy-back --target-dir=/var/lib/mysql/backups/backup-${NOW}/
chown -R mysql:mysql /var/lib/mysql 
service mariadb start
service mariadb status
echo "STOP SLAVE; SET GLOBAL gtid_slave_pos='${GTID}';
    CHANGE MASTER TO
    MASTER_HOST='${PRIMARY}',
    MASTER_USER='repl',
    MASTER_PASSWORD='XuHfgRu1Te0oXrkA5Gc',
    MASTER_USE_GTID=slave_pos;
    START SLAVE;
    SHOW SLAVE STATUS\G;
    SELECT * from tradebidder.jobs ORDER BY created_at DESC LIMIT 1;
" | mariadb
EOF

## If there is a duplicate entry error:
STOP SLAVE SQL_THREAD;
SET GLOBAL SQL_SLAVE_SKIP_COUNTER = 1;
START SLAVE SQL_THREAD;
SHOW SLAVE STATUS\G


## Tradebid
rsync -auv tradebidder 192.168.1.223:/home/tradebid/
apt install redis npm wrk
sudo npm install pm2 -g

# Copy over redis.conf and restart

# Edit .env to point to correct redis cache and streams servers
