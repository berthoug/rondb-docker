#!/bin/bash
set -e

get_option () {
    local section=$1
    local option=$2
    local default=$3
    ret=$(/usr/bin/my_print_defaults $section | grep '^--'${option}'=' | cut -d= -f2-)
    [ -z $ret ] && ret=$default
    echo $ret
}

if [ "${1:0:1}" = '-' ]; then
	set -- mysqld "$@"
fi

if [ "$1" = 'mysqld' ]; then
	# Get config
	DATADIR="$("$@" --verbose --help 2>/dev/null | awk '$1 == "datadir" { print $2; exit }')"
        SOCKET=$(get_option  mysqld socket "$datadir/mysql.sock")
        PIDFILE=$(get_option mysqld pid-file "/var/run/mysqld/mysqld.pid")

	if [ ! -d "$DATADIR/mysql" ]; then
		if [ -z "$MYSQL_ROOT_PASSWORD" -a -z "$MYSQL_ALLOW_EMPTY_PASSWORD" ]; then
			echo >&2 'error: database is uninitialized and MYSQL_ROOT_PASSWORD not set'
			echo >&2 '  Did you forget to add -e MYSQL_ROOT_PASSWORD=... ?'
			exit 1
		fi
		if [ ! -d "$DATADIR" ]; then
			mkdir -p $DATADIR
		fi
		echo 'Running mysql_install_db'
		mysql_install_db --user=mysql --datadir=$DATADIR --insecure
		echo 'Finished mysql_install_db'

		mysqld --user=mysql --datadir=$DATADIR --skip-networking &
                for i in $(seq 30 -1 0); do
		    [ -S $SOCKET ] && break
		    echo 'MySQL init process in progress...'
		    sleep 1
		done
                if [ $i = 0 ]; then
                    echo >&2 'MySQL init process failed.'
                    exit 1
                fi
                
		# These statements _must_ be on individual lines, and _must_ end with
		# semicolons (no line breaks or comments are permitted).
		# TODO proper SQL escaping on ALL the things D:
		
		tempSqlFile=$(mktemp /tmp/mysql-first-time.XXXXXX.sql)
		cat > "$tempSqlFile" <<-EOSQL
			DELETE FROM mysql.user ;
			CREATE USER 'root'@'%' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}' ;
			GRANT ALL ON *.* TO 'root'@'%' WITH GRANT OPTION ;
			DROP DATABASE IF EXISTS test ;
		EOSQL
		
		if [ "$MYSQL_DATABASE" ]; then
			echo "CREATE DATABASE IF NOT EXISTS \`"$MYSQL_DATABASE"\` ;" >> "$tempSqlFile"
		fi
		
		if [ "$MYSQL_USER" -a "$MYSQL_PASSWORD" ]; then
			echo "CREATE USER '"$MYSQL_USER"'@'%' IDENTIFIED BY '"$MYSQL_PASSWORD"' ;" >> "$tempSqlFile"
			
			if [ "$MYSQL_DATABASE" ]; then
				echo "GRANT ALL ON \`"$MYSQL_DATABASE"\`.* TO '"$MYSQL_USER"'@'%' ;" >> "$tempSqlFile"
			fi
		fi
		
		echo 'FLUSH PRIVILEGES ;' >> "$tempSqlFile"
		
		chown -R mysql:mysql "$DATADIR"
		mysql -uroot < $tempSqlFile
		sed -i -e '/^log-error/d' /etc/my.cnf
		cat /etc/my.cnf
		rm -f $tempSqlFile
		kill $(cat $PIDFILE)

		# Wait to ensure server is stopped (below check doesn't work right for 5.7.5)
		sleep 10
                for i in $(seq 30 -1 0); do
		    [ -S $SOCKET ] || break
		    echo 'MySQL init process in progress...'
		    sleep 1
		done
                if [ $i = 0 ]; then
                    echo >&2 'MySQL hangs during init process.'
                    exit 1
                fi
		echo 'MySQL init process done. Ready for start up.'
	fi
fi

exec "$@"

