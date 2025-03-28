#!/bin/bash

# Interface to watch
IF="eth0"
IP_SERVER=$(ip -4 addr show $IF | grep -oP '(?<=inet\s)\d+(\.\d+){3}')

# Flag expressed in regular expression for grep
FLAG_REGEX="FLAG_[0-9a-zA-Z]+"

# Directory where capture files are stored (change if needed)
DIR_WRITE="pcap.out"
PCAP_PREFIX="pcap"
MERGED_PREFIX="merged"
BREACH_PREFIX="breach"
CHECKPOINT_FILE="${DIR_WRITE}/.checkpoint.txt"

# How often to check for new streams (in seconds)
CHECK_INTERVAL=60

# Offset to checkpoint (in seconds),
# i.e., time_epoch of the last packet analyzed in the previous execution process,
# to ensure TCP stream cut off in the middle to be fully captured in the current cycle.
CHECKPOINT_OFFSET=10

# Keep directory part of the command line for later use
COMMAND_DIR=$(dirname $0)

trap 'clean_up' EXIT

clean_up(){
  delete_work_files
  make_checkpoint
}

delete_work_files(){
  rm $MERGED > /dev/null 2>&1
}

make_checkpoint(){
  echo $CHECKPOINT > $CHECKPOINT_FILE
  message "checkpoint $CHECKPOINT_S has been taken and exiting..."
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

check_command tshark
check_command mergecap
check_command bc
touch_dir $DIR_WRITE

if [ -f $CHECKPOINT_FILE ]; then
  CHECKPOINT=$(cat $CHECKPOINT_FILE)
  CHECKPOINT_S=$(echo $CHECKPOINT | awk '{ cmd="date -d @"$1" +\"%Y%m%d-%H%M%S\""; cmd | getline t; close(cmd); print t }')
  message "checkpoint restored from $CHECKPOINT_FILE: $CHECKPOINT_S"
else
  CHECKPOINT=0
fi

while true; do
  # Process sorted list of files from older to newer
  FILES=()
  while IFS= read -r FILE; do
    FILES+=("$FILE")
  done < <(find $DIR_WRITE -maxdepth 1 -name "${PCAP_PREFIX}-*.pcap" -type f | sort)

  FILES_TO_MERGE=""
  CUTOFF=$(echo "$CHECKPOINT - $CHECKPOINT_OFFSET" | bc)
  CUTOFF_S=$(echo $CUTOFF | awk '{ cmd="date -d @"$1" +\"%Y%m%d-%H%M%S\""; cmd | getline t; close(cmd); print t }')

  # Merge files packet records newer than $CUTOFF
  for ((i=0; i<${#FILES[@]}; i++)); do
    FILE="${FILES[$i]}"
    LAST_TS=$(tshark -r $FILE -T fields -e frame.time_epoch | tail -n 1)
    #echo "*debug* $FILE --- $LAST_TS"
    if [[ -n $LAST_TS && "$(bc <<< "$LAST_TS > $CUTOFF")" == 1 ]]; then
      FILES_TO_MERGE+=" $FILE"
    fi
  done

  if [ "$FILES_TO_MERGE" != "" ]; then
    message "merging $FILES_TO_MERGE..."
    FILE_BASE=$(basename $FILE)
    MERGED=${DIR_WRITE}/$(echo $FILE_BASE | sed s/${PCAP_PREFIX}/${MERGED_PREFIX}/)
    mergecap -a -w $MERGED $FILES_TO_MERGE

    # Invoke another script to detect breach of flags from $IP_SERVER
    LAST_TS=$(tshark -r $MERGED -T fields -e frame.time_epoch | tail -n 1)
    LAST_TS_S=$(echo $LAST_TS | awk '{ cmd="date -d @"$1" +\"%Y%m%d-%H%M%S\""; cmd | getline t; close(cmd); print t }')
    message "processing the merged file (cutoff=$CUTOFF_S, last timestamp=$LAST_TS_S)..."
    ${COMMAND_DIR}/04-01_select_target_stream.sh -i $MERGED -c $CUTOFF -p $BREACH_PREFIX -s $IP_SERVER -t $FLAG_REGEX
    CHECKPOINT=$LAST_TS
    rm $MERGED
  fi

  # Wait before checking again
  sleep $CHECK_INTERVAL
done
