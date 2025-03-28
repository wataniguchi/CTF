#!/bin/bash

# Interface to watch
IF="eth0"
IP_LOCAL=$(ip -4 addr show $IF | grep -oP '(?<=inet\s)\d+(\.\d+){3}')

# Flag expressed in regular expression for grep
FLAG_REGEX="a2dis[a-z]+d"

# Directory where capture files are stored (change if needed)
DIR_WRITE="pcap.out"
PCAP_PREFIX="capture"
STREAM_PREFIX="stream"

# Time duration to rotate the dump file (in seconds)
ROTATE_SEC=60
# Max dump files to keep
MAX_GEN=3

# How often to check for new files (in seconds)
CHECK_INTERVAL=$ROTATE_SEC

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

process_stream_dump(){
  if [ -f $1 ]; then
    #tshark -r $1 -T fields -e ip.src -e tcp.srcport -e ip.dst -e tcp.dstport
    if tshark -r $1 -Y "ip.src eq $IP_LOCAL" -V | grep -qE $FLAG_REGEX; then
      IP_REMOTE=$(tshark -r $1 -Y "ip.src eq $IP_LOCAL" -T fields -e ip.dst | uniq)
      message "=== FLAG COMPROMIZED to $IP_REMOTE ===: $1"
    else
      rm $1
      message "deleted: $1"
    fi
  fi
}

check_command tshark
check_command mergecap
touch_dir $DIR_WRITE
message "local IP address: $IP_LOCAL"
message "start capturing tcp packets in rolling dump files in $DIR_WRITE (seconds to rorate = $ROTATE_SEC, maximum generation = $MAX_GEN)"
sudo tcpdump -i $IF -w ${DIR_WRITE}/${PCAP_PREFIX}-%m-%d-%H-%M-%S-%s.pcap -G $ROTATE_SEC -Z $USER tcp &

while true; do
  # Get the two most recent rolling files (sorted by modification time)
  NEWEST=$(ls ${DIR_WRITE}/${PCAP_PREFIX}*.pcap 2>/dev/null | sort -r | head -n 1)
  SECOND_NEWEST=$(ls ${DIR_WRITE}/${PCAP_PREFIX}*.pcap 2>/dev/null | sort -r | sed -n '2p')

  # If both files exist, process them with tshark
  if [[ -n "$NEWEST" && -n "$SECOND_NEWEST" ]]; then
    message "processing latest files: $NEWEST and $SECOND_NEWEST"
    mergecap -a -w ${DIR_WRITE}/merged.pcap $SECOND_NEWEST $NEWEST
    # Identify all TCP streams in the merged pcap file, and process each of them
    tshark -r ${DIR_WRITE}/merged.pcap -T fields -e tcp.stream | sort -n | uniq | while read STREAM; do
      STREAM_DUMP=$(echo $NEWEST | sed s/${PCAP_PREFIX}-/${STREAM_PREFIX}-${STREAM}_/)
      message "extracting a stream: $STREAM_DUMP"
      tshark -r ${DIR_WRITE}/merged.pcap -Y "tcp.stream eq $STREAM" -w ${STREAM_DUMP} 
      process_stream_dump ${STREAM_DUMP}
    done
  else
    message "waiting for enough capture files..."
  fi

  # Delete all old dump files but the $MAX_GEN newest ones
  ls $DIR_WRITE/${PCAP_PREFIX}*.pcap 2>/dev/null | sort -r | tail -n +$MAX_GEN | xargs rm -f
  # Wait before checking again
  sleep $CHECK_INTERVAL
done
