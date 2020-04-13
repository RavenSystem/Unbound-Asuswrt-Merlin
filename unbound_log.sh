#!/bin/sh 
##
# ____ ___     ___.                            .___ .____                  
#|    |   \____\_ |__   ____  __ __  ____    __| _/ |    |    ____   ____  
#|    |   /    \| __ \ /  _ \|  |  \/    \  / __ |  |    |   /  _ \ / ___\ 
#|    |  /   |  \ \_\ (  <_> )  |  /   |  \/ /_/ |  |    |__(  <_> ) /_/  >
#|______/|___|  /___  /\____/|____/|___|  /\____ |  |_______ \____/\___  / 
#             \/    \/                  \/      \/          \/    /_____/  
## @juched - Process logs into SQLite3 for stats generation
##unbound_log.sh
## - v1.0 - March 24 2020 - Initial version doing both nx_domains and reply_domains
## - v1.1 - April 5 2020 - Add support for tracking client IP
## - v1.2 - April 13 2020 - Added header and no errors if log doesn't exist
readonly SCRIPT_VERSION="v1.2"

Say(){
   echo -e $$ $@ | logger -st "($(basename $0))"
}

ScriptHeader(){
	printf "\\n"
	printf "##\\n"
	printf "# ____ ___     ___.                            .___ .____                  \\n"
	printf "#|    |   \____\_ |__   ____  __ __  ____    __| _/ |    |    ____   ____  \\n"
	printf "#|    |   /    \| __ \ /  _ \|  |  \/    \  / __ |  |    |   /  _ \ / ___\ \\n"
	printf "#|    |  /   |  \ \_\ (  <_> )  |  /   |  \/ /_/ |  |    |__(  <_> ) /_/  >\\n"
	printf "#|______/|___|  /___  /\____/|____/|___|  /\____ |  |_______ \____/\___  / \\n"
	printf "#             \/    \/                  \/      \/          \/    /_____/  \\n"
	printf "## by @juched - Process logs into SQLite3 for stats generation - %s                      \\n" "$SCRIPT_VERSION"
	printf "\\n"
	printf "unbound_log.sh\\n"
}

ScriptHeader

# $1 logfile
unbound_logfile="/opt/var/lib/unbound/unbound.log"
if [ -f "/opt/etc/syslog-ng.d/unbound" ]; then
  unbound_logfile="/opt/var/log/unbound.log";
fi

# can pass in a log file name if desired
if [ ! -z "$1" ]; then
  unbound_logfile="$1";
fi
echo "Logfile used is $unbound_logfile"

#other variables
tmpSQL="/tmp/unbound_log.sql"
dbLogFile="/opt/var/lib/unbound/unbound_log.db"
dateString=$(date '+%F')
#dateString="2020-03-22"
olddateString=$(date -D %s -d $(( $(date +%s) - 7*86400)) '+%F')
echo "Date used is $dateString (7 days ago is $olddateString)"

#create table to track adblocked domains from log-local-actions if needed
echo "Creating nx_domain table if needed..."
printf "CREATE TABLE IF NOT EXISTS [nx_domains] ([domain] VARCHAR(255) NOT NULL, [date] DATE NOT NULL, [count] INTEGER NOT NULL, PRIMARY KEY(domain,date));" | sqlite3 $dbLogFile

#delete old records > 7 days ago
echo "Deleting old nx_domain records older than 7 days..."
printf "DELETE FROM nx_domains WHERE date < '$olddateString';" | sqlite3 $dbLogFile

# Add to SQLite all blocked domains (log-local-actions must be yes)
if [ -f "$unbound_logfile" ]; then # only if log exists
  echo "BEGIN;" > $tmpSQL
  cat $unbound_logfile | awk -v vardate="$dateString" '/always_nxdomain/{print "INSERT OR IGNORE INTO nx_domains ([domain],[date],[count]) VALUES (\x27" substr($8, 1, length($8)-1) "\x27, \x27" vardate "\x27, 0);\nUPDATE nx_domains SET count = count + 1 WHERE domain = \x27" substr($8, 1, length($8)-1) "\x27 AND date = \x27" vardate "\x27;"}' >> $tmpSQL
  echo "COMMIT;" >> $tmpSQL
  echo "Running SQLite to import new nx records..."
  sqlite3 $dbLogFile < $tmpSQL

  # log out the processed nodes
  nxdomain_count=$(grep -c "always_nxdomain" $unbound_logfile)
  Say "Processed $nxdomain_count nx_domains..."

  #cleanup
  if [ -f $tmpSQL ]; then rm $tmpSQL; fi
fi

# create table to track replies from log-replies 'yes'
echo "Creating reply_domain table if needed..."
printf "CREATE TABLE IF NOT EXISTS [reply_domains] ([domain] VARCHAR(255) NOT NULL, [date] DATE NOT NULL, [reply] VARCHAR(32), [client_ip] VARCHAR(16) NOT NULL, [count] INTEGER NOT NULL, PRIMARY KEY(domain,date,reply,client_ip));" | sqlite3 $dbLogFile

#delete old records > 7 days ago
echo "Deleting old reply_domain records older than 7 days..."
printf "DELETE FROM reply_domains WHERE date < '$olddateString';" | sqlite3 $dbLogFile

# Add to SQLite all reply domains (log-replies must be yes)
if [ -f "$unbound_logfile" ]; then # only if log exists
  echo "BEGIN;" > $tmpSQL
  #cat $unbound_logfile | awk -v vardate="$dateString" '/reply: 127.0.0.1/{print "INSERT OR IGNORE INTO reply_domains ([domain],[date],[reply],[count]) VALUES (\x27" substr($9, 1, length($9)-1) "\x27, \x27" vardate "\x27, \x27" $12 "\x27, 0);\nUPDATE reply_domains SET count = count + 1 WHERE domain = \x27" substr($9, 1, length($9)-1)"\x27 AND reply = \x27" $12 "\x27 AND date = \x27" vardate "\x27;"}' >> $tmpSQL
  cat $unbound_logfile | awk -v vardate="$dateString" '/reply: [0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/{print "INSERT OR IGNORE INTO reply_domains ([domain],[date],[reply],[client_ip],[count]) VALUES (\x27" substr($9, 1, length($9)-1) "\x27, \x27" vardate "\x27, \x27" $12 "\x27, \x27" $8 "\x27, 0);\nUPDATE reply_domains SET count = count + 1 WHERE domain = \x27" substr($9, 1, length($9)-1)"\x27 AND reply = \x27" $12 "\x27 AND date = \x27" vardate "\x27 AND client_ip = \x27" $8 "\x27;"}' >> $tmpSQL
  echo "COMMIT;" >> $tmpSQL
  echo "Running SQLite to import new reply records..."
  sqlite3 $dbLogFile < $tmpSQL

  # log out the processed nodes
  #reply_domaincount=$(grep -c "reply: 127.0.0.1" $unbound_logfile)
  reply_domaincount=$(grep -c "reply: \([0-9]\{1,3\}\.\)\{3\}" $unbound_logfile)
  Say "Processed $reply_domaincount reply_domains..."

  #cleanup
  if [ -f $tmpSQL ]; then rm $tmpSQL; fi

  echo "Removing always_nxdomain lines from log file..."
  sed -i '\~always_nxdomain~d' $unbound_logfile

  echo "Removing reply lines from log file..."
  #sed -i '\~reply: 127.0.0.1~d' $unbound_logfile
  sed -i '\~reply: \([0-9]\{1,3\}\.\)\{3\}[0-9]\{1,3\}~d' $unbound_logfile

  # if syslog-ng running, need to restart it so logging continues
  if [ -f "/opt/etc/syslog-ng.d/unbound" ]; then killall -HUP syslog-ng; fi
fi

echo "All done!"
