#!/bin/sh
########################
#
VERSION="1.27"
#
########################
#echo "WIP"
#exit 0
#set -v
PROGNAME=`basename $0`
ADMIN=mstan@asesoft.ro

COMMAND=process
FREQ="daily"
BASE=/var/backup
CONFIGS=/etc/backup.d
LOCKFILE="/tmp/backup.backup.lock"
LOCKFILE2="/reboot-needed"
NUMDAYS=2
DEFBWLIMIT=10000
# Used for signalling:
GOSERVER=1
GOFOLDER=1
SEP="================================================================="
DEPS="/usr/bin/rsync /bin/nice /usr/bin/ionice /usr/bin/mysqldump"
NICE="nice -n 19 ionice -c3"

print_usage() {
	echo "usage $PROGNAME <command>"
	echo -e "commands:\t process [daily|weekly]: starts processing the daily or weekly queue"
	echo -e "\t\t backup <servername>: backups only <servername>"
	echo -e "\t\t resync <servername>: resyncs failed folders in <servername> without rotating folders"
	echo -e "\t\t mysqldump <servername>: backups only databases on <servername>"
}

if [ $# -lt 1 ]; then
    print_usage
    exit 1;
fi

for D in $DEPS; do
    if [ ! -x $D ]; then
	echo "Missing $D"
	exit 1
    fi
done

case $1 in
    process)
	COMMAND=process
	FREQ=$2
	if [ $FREQ != "daily" -a $FREQ != "weekly" ]; then
	    echo "Unknown interval: $FREQ"
	    print_usage
	    exit 1
	fi
	LOCKFILE="/tmp/backup.$FREQ.lock"
	;;
    resync)
	COMMAND=resync
	ONLYSERVER=$2
	if [ "x$ONLYSERVER" = "x" ]; then
	    echo "Unspecified server for resync"
	    print_usage
	    exit 1
	fi
	LOCKFILE="/tmp/backup.resync.$ONLYSERVER.lock"
	;;
    backup)
	COMMAND=backup
	ONLYSERVER=$2
	if [ "x$ONLYSERVER" = "x" ]; then
	    echo "Unspecified server for backup"
	    print_usage
	    exit 1
	fi
	LOCKFILE="/tmp/backup.backup.lock"
	;;
    mysqldump)
	COMMAND=mysqldump
	ONLYSERVER=$2
	if [ "x$ONLYSERVER" = "x" ]; then
	    echo "Unspecified server for mysqldump"
	    print_usage
	    exit 1
	fi
	LOCKFILE="/tmp/backup.mysqldump.$ONLYSERVER.lock"
	;;
    *)
	echo "Unknown command: $1"
	print_usage
	exit 1
	;;
esac

# See if an instance is already running
if [ -f $LOCKFILE ]; then
    echo "Backup script already running with lock $LOCKFILE"
    exit 1
fi

# See if marius wants reboot
if [ -f $LOCKFILE2 ]; then
    echo "A reboot is programmed, won't run unless you remove $LOCKFILE2"
    exit 1
fi

echo "Starting backup ver $VERSION process at `date`"
echo "Command: $1 $2 $3"

trap stopserver USR1
trap stopfolder USR2
trap stopall SIGINT

stopserver() {
    echo "USR1 received, exiting after current server"
    GOSERVER=0 
}

stopfolder() {
    echo "USR2 received, exiting after current folder"
    GOSERVER=0
    GOFOLDER=0
}

stopall() {
    echo "Exiting on CTRL^C"
    exit 0
}

backup_path() {
    
    local FOLDER=$1
    echo "`date` Backing up path $SHORTNAME:$FOLDER"
    if [ "x$BWLIMIT" = "x" ]; then
	BWLIMIT=$DEFBWLIMIT
    fi
    #OPTS="-razvvHx --delete --backup --bwlimit=512 --backup-dir=$BASE/$SHORTNAME/$FOLDER-$TAG"
    #OPTS="-aHx --timeout=3600 --contimeout=3600 --bwlimit=10240  --delete-during --numeric-ids --exclude-from=/etc/backup.d/$SHORTNAME.exclude --delete-excluded"
    #OPTS="-aHxv --timeout=3600 --contimeout=3600 --bwlimit=$BWLIMIT --delete-during --numeric-ids --exclude-from=/etc/backup.d/$SHORTNAME.exclude --delete-excluded"
    local OPTS="-aHx --timeout=1200 --delete-during --numeric-ids --exclude-from=$CONFIGS/$SHORTNAME.exclude --delete-excluded"
    local RSYNC="$NICE rsync"
    
    #echo "`date` Starting rsync process"
    local RET=1
    for r in `seq 1 5`; do
	echo "Command: $RSYNC $OPTS rsync://$SERVER/$FOLDER/ $BASE/$BDIR/$SHORTNAME/$NUMDAYS/$FOLDER"
	$RSYNC $OPTS rsync://$SERVER/$FOLDER/ $BASE/$BDIR/$SHORTNAME/$NUMDAYS/$FOLDER
        if [ $? = 0 ]; then
	    echo "SUCCESS on retry $r"
	    RET=0
	    break
        else
    	    echo "FAILED on retry $r"
	fi
    done
    return $RET
}

backup_database() {
    local DATABASE=$1
    echo "`date` Dumping database $SHORTNAME:$DATABASE"
    local OPTS="--compress --host=$SERVER --user=$MYSQLUSERNAME --password=$MYSQLPASSWORD --opt --single-transaction "
    local RET=1
    for r in `seq 1 5`; do
	mysqldump $OPTS $DATABASE | gzip > $BASE/$BDIR/$SHORTNAME/$NUMDAYS/sql/$DATABASE.gz
        if [ $? = 0 ]; then
	    echo "SUCCESS on retry $r"
	    RET=0
	    break
        else
    	    echo "FAILED on retry $r"
	fi
    done
    return $RET
}

backup_mysql() {
    echo "`date` Backing up Mysql databases "
    [ -d $BASE/$BDIR/$SHORTNAME/$NUMDAYS/sql ] || mkdir $BASE/$BDIR/$SHORTNAME/$NUMDAYS/sql
    DATABASES=`echo "show databases;" | mysql --host=$SERVER --user=$MYSQLUSERNAME --password=$MYSQLPASSWORD`
    for D in $DATABASES; do
	if [ $D != 'Database' ]; then
	    backup_database $D
    	    if [ $? = 0 ]; then
		echo "sql:$D SUCCESS" >> $BASE/$BDIR/$SHORTNAME/$NUMDAYS/FINISHED
    	    else
    		echo "sql:$D FAILED" >> $BASE/$BDIR/$SHORTNAME/$NUMDAYS/FINISHED
    	    fi
	fi
    done
}

rotate_folders() {
    echo "`date` Rotating folders "

    for f in `seq 1 $NUMDAYS`; do
        # Make sure folders exist
	[ -d $BASE/$BDIR/$SHORTNAME/$f ] || mkdir $BASE/$BDIR/$SHORTNAME/$f
	# rotate folders
        mv -T $BASE/$BDIR/$SHORTNAME/$f $BASE/$BDIR/$SHORTNAME/$[$f-1]
    done
    
	# if oldest backup is valid reuse it
	if [ -f $BASE/$BDIR/$SHORTNAME/0/FINISHED ]; then
		mv -T $BASE/$BDIR/$SHORTNAME/0 $BASE/$BDIR/$SHORTNAME/$NUMDAYS
	else
		# oldest backup must go
		$NICE rm -rf $BASE/$BDIR/$SHORTNAME/0
		# duplicate newest backup
		$NICE cp -al $BASE/$BDIR/$SHORTNAME/$[$NUMDAYS-1] $BASE/$BDIR/$SHORTNAME/$NUMDAYS
	fi
    
    rm -f $BASE/$BDIR/$SHORTNAME/$NUMDAYS/FINISHED
    echo "`date` Done rotating folders "
}

backup_server() {
    echo -e "$SEP\n$SEP\n"
    echo "`date` Backing up server $SHORTNAME"
    echo -e "$SEP\n$SEP\n"

    [ -d $BASE/$BDIR/$SHORTNAME ] || mkdir $BASE/$BDIR/$SHORTNAME
    
    ping -c1 $SERVER
    if [ $? != 0 ]; then
	echo -e "$SERVER not responding\n"
	return 1
    fi
    
    local SERVERLOCK=$BASE/$BDIR/$SHORTNAME/server.lock
    if [ -f $SERVERLOCK ]; then
	echo "Server is locked, remove $SERVERLOCK to continue"
	mail -s "$SHORTNAME is locked" $ADMIN
        return 1
    fi
    touch $SERVERLOCK
    
    rotate_folders
    for f in $FOLDERS; do
	if [ $GOFOLDER -eq 1 ]; then
    	    backup_path $f
    	    if [ $? = 0 ]; then
		echo "$f SUCCESS" >> $BASE/$BDIR/$SHORTNAME/$NUMDAYS/FINISHED
    	    else
    		echo "$f FAILED" >> $BASE/$BDIR/$SHORTNAME/$NUMDAYS/FINISHED
    	    fi
    	else
        	echo "$f SKIPPED " >> $BASE/$BDIR/$SHORTNAME/$NUMDAYS/FINISHED
	fi
    done
    if [ "$MYSQLBACKUP" = "yes" ]; then
	backup_mysql
    fi
    echo "FINISHED $SHORTNAME at `date`"
    echo "FINISHED $SHORTNAME at `date`" >> $BASE/$BDIR/$SHORTNAME/$NUMDAYS/FINISHED
    rm -f $SERVERLOCK
}

load_config() {
    unset SERVER
    unset SHORTNAME
    unset FOLDERS
    unset BWLIMIT
    unset BDIR
    unset INTERVAL
    unset MYSQLBACKUP
    unset MYSQLUSERNAME
    unset MYSQLPASSWORD
    . $1
    if [ "x$BDIR" = "x" ]; then
        BDIR="noraid"
    fi
    if [ "x$INTERVAL" = "x" ]; then
        INTERVAL="daily"
    fi
}








touch $LOCKFILE

if [ $COMMAND = "process" ]; then
    for i in `ls $CONFIGS/*.conf`; do
	load_config $i
	if [ $GOSERVER -eq 1 ]; then
	    if [ $INTERVAL = $FREQ ]; then
    	        backup_server
    	    else
    		echo $SEP
    		echo "Skipping $SHORTNAME, wrong INTERVAL: $INTERVAL"
    	    fi
	fi
    done


elif [ $COMMAND = "resync" ]; then
    if [ -f $CONFIGS/$ONLYSERVER.conf ]; then
	load_config $CONFIGS/$ONLYSERVER.conf

	SERVERLOCK=$BASE/$BDIR/$SHORTNAME/server.lock
	if [ -f $SERVERLOCK ]; then
	    echo "Server is locked, remove $SERVERLOCK to continue"
	    mail -s "$SHORTNAME is locked" $ADMIN
    	    rm -f $LOCKFILE
    	    exit 1
	fi
	touch $SERVERLOCK

	sed -i '/^FINISHED/d' $BASE/$BDIR/$SHORTNAME/$NUMDAYS/FINISHED
	for f in `grep FAILED $BASE/$BDIR/$SHORTNAME/$NUMDAYS/FINISHED | grep -v 'sql:' | awk '{ print \$1 }'`; do
	    if [ $GOFOLDER -eq 1 ]; then
		sed -i '/^'$f' /d' $BASE/$BDIR/$SHORTNAME/$NUMDAYS/FINISHED
		#exit
    		
    		backup_path $f
    		if [ $? = 0 ]; then
		    echo "$f SUCCESS" >> $BASE/$BDIR/$SHORTNAME/$NUMDAYS/FINISHED
    		else
    		    echo "$f FAILED" >> $BASE/$BDIR/$SHORTNAME/$NUMDAYS/FINISHED
    		fi
    	    else
        	echo "$f SKIPPED " >> $BASE/$BDIR/$SHORTNAME/$NUMDAYS/FINISHED
	    fi
	done
	echo "FINISHED $SHORTNAME at `date`" >> $BASE/$BDIR/$SHORTNAME/$NUMDAYS/FINISHED
	rm -f $SERVERLOCK

    else
	echo "Config not found for server $ONLYSERVER in $CONFIGS"
    fi


elif [ $COMMAND = "backup" ]; then
    if [ -f $CONFIGS/$ONLYSERVER.conf ]; then
	load_config $CONFIGS/$ONLYSERVER.conf
	backup_server
    else
	echo "Config not found for server $ONLYSERVER in $CONFIGS"
    fi


elif [ $COMMAND = "mysqldump" ]; then
    if [ -f $CONFIGS/$ONLYSERVER.conf ]; then
	load_config $CONFIGS/$ONLYSERVER.conf
	if [ "$MYSQLBACKUP" = "yes" ]; then
	    backup_mysql
	else
	    echo "MYSQL backups disabled on server $SHORTNAME" 
	fi
    else
	echo "Config not found for server $ONLYSERVER in $CONFIGS"
    fi
else 
    echo "unhandled command $COMMAND"
fi

rm -f $LOCKFILE
echo -e "$SEP\n$SEP\n"
echo "Finished backup process at `date`";
