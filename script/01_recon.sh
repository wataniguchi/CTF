#!/usr/bin/env bash
DIR_WRITE="portscan.out"
MAX_JOBS=4

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

# block until number of jobs gets less than $1
wait_until_jobn_lt () {
  local max_jobn=$1
  while [[ "$(jobs | wc -l)" -ge "$max_jobn" ]] ; do
    sleep 1
  done
}

wait_background(){
  message "waiting background jobs to finish..."
  local jobs=`jobs -p`
  for job in $jobs; do
    wait $job
  done
}

check_command(){
  if ! command -v $1 2>&1 >/dev/null
  then
    message "$1 could not be found"
    exit 1
  fi
}

touch_dir() {
  if [ ! -d $1 ]
  then
    message "create_dir $1"
    mkdir $1
  fi
}

scan_host() {
  message "scanning ports on $1"
  RUSTSCAN_OUT=$(rustscan --ulimit 5000 --greppable -a "$1")
  if echo "$RUSTSCAN_OUT" | grep ' -> ' 2>&1 >/dev/null; then
    message "$RUSTSCAN_OUT"
    echo "$RUSTSCAN_OUT" |\
      awk -F' -> |[][]' '{print "nmap -sV -A --reason -p", $3, $1}' |\
      /bin/sh > "${DIR_WRITE}"/rustscan-"$1".txt
  fi
}

if [ "$#" -ne 1 ]; then
  message "usage: $0 <network>/<prefix>"
  exit 1
fi

NETWORK=$1
check_command ipcalc
check_command rustscan
touch_dir $DIR_WRITE
IPCALC_OUT=$(ipcalc -n "$NETWORK")

if echo "$IPCALC_OUT" | grep -i invalid 2>&1 >/dev/null; then
  message "$IPCALC_OUT"
  exit 1
fi

HOSTS=$(echo "$IPCALC_OUT" | grep Hosts | awk '{print $2}')
if [ "$HOSTS" = '1' ]; then
  HOST=$(echo "$IPCALC_OUT" | grep Address | awk '{print $2}')
  scan_host $HOST
else
  HOST_MIN=$(echo "$IPCALC_OUT" | grep HostMin | awk '{print $2}')
  IFS=. read -r I1 I2 I3 I4 <<< "$HOST_MIN"
  HOST_MAX=$(echo "$IPCALC_OUT" | grep HostMax | awk '{print $2}')
  IFS=. read -r J1 J2 J3 J4 <<< "$HOST_MAX"
  # convert IP address into an integer
  ADDR_MIN=$(( ("$I1" << 24) + ("$I2" << 16) + ("$I3" << 8) + "$I4" ))
  ADDR_MAX=$(( ("$J1" << 24) + ("$J2" << 16) + ("$J3" << 8) + "$J4" ))
  # Enumerate all IPs in range
  for ((A = "$ADDR_MIN"; A <= "$ADDR_MAX"; A++)) ; do
    HOST=$(printf "%d.%d.%d.%d\n" $(( ("$A" >> 24) & 255 )) $(( ("$A" >> 16) & 255 )) $(( ("$A" >> 8) & 255 )) $(( "$A" & 255 )))
    wait_until_jobn_lt "$MAX_JOBS"
    scan_host $HOST &
  done
fi

wait_background
grep -E '^[^ ]+ +open ' "${DIR_WRITE}"/rustscan-*.txt 2>/dev/null \
  > "${DIR_WRITE}"/All_discovered_ports.txt
message "completed"
exit 0
