#!/bin/bash

# Interface to watch
IF="eth0"
IP_LOCAL=$(ip -4 addr show $IF | grep -oP '(?<=inet\s)\d+(\.\d+){3}')

# Directory where capture files are stored (change if needed)
DIR_WRITE="pcap.out"
PCAP_PREFIX="pcap"

# Time duration to roll over the dump file (in seconds)
ROLLOVER_SEC=300

# Maximum size of a dump file (in Mbytes)
MAX_DUMPSIZE=16

# Keep directory part of the command line for later use
COMMAND_DIR=$(dirname $0)

trap 'kill_background > /dev/null 2>&1' EXIT

kill_background(){
  local jobs=`jobs -p`
  for job in $jobs; do
    kill_pstree $job
  done
}

kill_pstree(){
  local children=`pgrep -P $1`
  for child in $children; do
    kill_pstree $child
  done
  # Flush the paccket buffer into the output file forcibly sending SIGUSR2 to the tcpdump process
  kill -12 $1
  sleep 1
  kill $1
}

message(){
  echo "$(date +'%Y-%m-%d %T') " $@
}

check_command(){
  if ! command -v $1 2>&1 >/dev/null; then
    message "$1 could not be found"
    exit 1
  fi
}

touch_dir(){
  if [ ! -d $1 ]; then
    message "create_dir $1"
    mkdir $1
  fi
}

# Get sudo password for later use
sudo echo
touch_dir $DIR_WRITE
message "local IP address: $IP_LOCAL"
sudo tcpdump -i $IF -w ${DIR_WRITE}/${PCAP_PREFIX}-%Y%m%d-%H%M%S.pcap -G $ROLLOVER_SEC -C $MAX_DUMPSIZE -Z $USER tcp &
# option -U forces tcpdump to write packets immediately and is useful for test purposes
#sudo tcpdump -i $IF -U -w ${DIR_WRITE}/${PCAP_PREFIX}-%m%d-%H%M%S.pcap -G $ROLLOVER_SEC -C $MAX_DUMPSIZE -Z $USER tcp &
PID_TCPDUMP=$!
sleep 1
message "started capturing tcp packets in rolling dump files in $DIR_WRITE (seconds to roll over = $ROLLOVER_SEC, maximum dump size = $MAX_DUMPSIZE Mbytes)"

while true; do
  sleep $ROLLOVER_SEC
  if [ -n "$(ps -p $PID_TCPDUMP -o pid=)" ]; then
    message "dump files in $DIR_WRITE:"
    ls -l ${DIR_WRITE}/${PCAP_PREFIX}-*.pcap
  else
    message "tcpdump (PID = $PID_TCPDUMP) is gone. exiting..."
    break
  fi
done
