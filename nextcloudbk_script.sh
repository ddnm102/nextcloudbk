#!/bin/bash

############# Basic settings ##########################################################

MODE="backup" # mode of operation: backup, restore

BACKUP_DIR="/mnt/user/nextcloud_backup"

# File name of the backup file for restore only
RESTORE_FILE_NAME="" # change this one to your backup file (created by nextcloud_backup script)
RESTORE_FILE_NAME_AUTO="yes" # yes/no -> set to yes if you want to auto choose the last backup file

BACKUP_BEFORE_RESTORE="yes" # yes/no -> set to yes if you want to backup before restore process

MYSQL_USER="nextcloud_user"
MYSQL_PASSWORD="nextcloud_password"
MYSQL_DB="nextcloud_db_name"

REMOVE_BACKUP_BEFORE_DAYS=30 # remove backup before 30 days old


############# Advanced/optional settings ##############################################

APPDATA_DIR="/mnt/user/appdata/nextcloud"

TIMESTAMP=`date +"%Y%m%d-%H%M%S"`

BACKUP_FILE="$BACKUP_DIR/$TIMESTAMP.tar.gz"

RESTORE_FILE="$BACKUP_DIR/$RESTORE_FILE_NAME"

LOG_FILE="$BACKUP_DIR/log.txt"

TEMP_DIR="/tmp/nextcloud_bk_rs_script_$TIMESTAMP"


#############  Functions ##############################################################


# last_modified_file
# auto choose the newest one from the backup list
# Here, i have all backup file (.tar.gz) and one log.txt file, so
# i use ls -t dir | head -2 to display 2 item return by ls with sorted by time (default is newest first). look like: `log.txt *.tar.gz`
# log.txt will display first because the modify value is newest than .tar.gz, of course, because we close log.txt after we create .tar.gz
# i just want to get .tar.gz file, so, i use sed to replace 'log.txt ' (have space seperated beween two items) with empty string,
# so, the str will be only the file name i want
last_modified_file () {
    two_files_sort_by_time=$(ls -t /mnt/user/nextcloud_backup/ | head -2)
    RESTORE_FILE_NAME=$(echo $two_files_sort_by_time | sed 's/log.txt //')
}

log() {
    echo "$1" | tee --append $LOG_FILE
}

root_checker () {
    if [[ ! $UID -eq 0 ]];
    then
    	echo "Please run this script as root"
    	exit 1
    fi
}

lock_backup_dir () {
    chattr +i $BACKUP_DIR
}

unlock_backup_dir () {
    chattr -i $BACKUP_DIR
}

clean_temp_dir () {
    log "remove tmp folder: $TEMP_DIR"
    rm -rf $TEMP_DIR
}

nextcloud_maintainence_on () {
    log "[nextcloud] turn on maintanence mode"
    docker exec -u 99 nextcloud /config/www/nextcloud/occ maintenance:mode --on
}

nextcloud_maintainence_off () {
    log "[nextcloud ]turn OFF maintenance mode"
    docker exec --user 99 nextcloud /config/www/nextcloud/occ maintenance:mode --off
}

nextcloud_appdata_backup () {
    log "[nextcloud] backup application data dir: $APPDATA_DIR to $TEMP_DIR"
    rsync --quiet --delete -asz "$APPDATA_DIR" "$TEMP_DIR"
}

nextcloud_appdata_restore () {
    log "[nextcloud] backup application data dir: $APPDATA_DIR"
    rsync --quiet --delete -asz "$TEMP_DIR/nextcloud/" "$APPDATA_DIR/"
}

compress_backup_dir () {
    log "compress backup to $BACKUP_FILE"
    tar -czf $BACKUP_FILE -C $TEMP_DIR .
}

extract_restore_file () {
    log "extract backup file: $RESTORE_FILE to: $TEMP_DIR/"
    tar -xf $RESTORE_FILE --directory $TEMP_DIR # --directory same as -C
}

mariadb_backup () {
    log "[mariadb] backup mariadb with database name: $MYSQL_DB"
    docker exec -u 99 mariadb mysqldump --single-transaction --host=localhost --user=$MYSQL_USER --password=$MYSQL_PASSWORD $MYSQL_DB > "$TEMP_DIR/$MYSQL_DB.sql"
}

mariadb_restore () {
    log "[mariadb] restore mariadb from sql file"
    if [[ -f $TEMP_DIR/$MYSQL_DB.sql ]] ; then
        cat $TEMP_DIR/$MYSQL_DB.sql | docker exec -i -u 99 mariadb mysql --user=$MYSQL_USER --password="$MYSQL_PASSWORD" "$MYSQL_DB"
    else
        log "[mariadb] nextcloud.sql file does not exist in $TEMP_DIR"
    fi
}

remove_old_backup() {
    log "remove old backups more than $REMOVE_BACKUP_BEFORE_DAYS days old (removed the backups from $(($REMOVE_BACKUP_BEFORE_DAYS+1)) (or more) days old)"
    find $BACKUP_DIR/ -maxdepth 1 -iname "*.tar.gz" -mtime +$REMOVE_BACKUP_BEFORE_DAYS -exec echo {} \; -exec rm {} \;
}

backup_process () {
    nextcloud_maintainence_on
    mariadb_backup
    nextcloud_appdata_backup
    compress_backup_dir
    nextcloud_maintainence_off
}

restore_process () {
    nextcloud_maintainence_on
    extract_restore_file
    mariadb_restore
    nextcloud_appdata_restore
    nextcloud_maintainence_off
}

############################# start process ###################################

root_checker

#unlock_backup_dir

# init log file
if [[ -f $LOG_FILE ]] ; then
    echo "$LOG_FILE already exist -> append log to this file!"
else
    touch $LOG_FILE
fi

log ""
log "=== starting nextcloud $MODE process at $(date) =================================================="
log ""

rm -rf $TEMP_DIR
mkdir -p $TEMP_DIR

# checking operation mode
if [ $MODE == "restore" ] ; then
    # check if user not specify restore file name
    if [[ $RESTORE_FILE_NAME == "" ]] && [[ $RESTORE_FILE_NAME_AUTO == "no" ]] ; then
        echo "you need to setup backup file first"
        exit 1
    fi
    
    # check if auto select last backup file for restore process
    if [[ $RESTORE_FILE_NAME_AUTO == "yes" ]] ; then
        last_modified_file
        log "auto selected backup file: $RESTORE_FILE_NAME"
    fi
    
    # check if need to backup before restore
    if [[ $BACKUP_BEFORE_RESTORE == "yes" ]] ; then
        BACKUP_FILE="$BACKUP_DIR/$TIMESTAMP--auto.tar.gz" # change backup file name in auto backup
        log "backup before restore starting...$BACKUP_FILE"
        backup_process
    fi
    
    # start restore process
    restore_process
    
elif [[ $MODE == "backup" ]] ; then

    backup_process

else
    log "MODE is only accept 2 values: backup or restore"
fi

clean_temp_dir

remove_old_backup

log ""
log "=== finished nextcloud $MODE process at $(date) =================================================="
log ""
exit 0
