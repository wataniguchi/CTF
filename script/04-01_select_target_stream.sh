#!/bin/bash

usage_exit(){
  echo "usage:" 1>&2
  echo "  $0 -i input_file_path \\" 1>&2
  echo "      [-c cutoff_time] \\" 1>&2
  echo "      -p output_file_prefix -t target_string \\" 1>&2
  echo "      [-s sender_address]" 1>&2
  echo
  echo "    -i path to pcap file to analyze" 1>&2
  echo "    -c cutoff time in epoch" 1>&2
  echo "    -p prefix added to TCP stream dump file(s)" 1>&2
  echo "       that contain the target string" 1>&2
  echo "    -t target string in regular expression form" 1>&2
  echo "    -s IP address that may send the target string" 1>&2
  echo "       in communication" 1>&2
  echo
  echo "  $0 selects TCP stream(s)" 1>&2
  echo "  containing the given target string" 1>&2
  echo "  (in regular expression) from the specified pcap file." 1>&2
  echo
  echo "example:" 1>&2
  echo "  $0 -i input.pcap -p breach \\" 1>&2
  echo "      -c 1743989606.212466000 \\" 1>&2
  echo "      -t 'FLAG_[0-9a-zA-Z]+' 192.168.1.1" 1>&2
  echo
  echo "  it produces the following stream dump file" 1>&2
  echo "  if 192.168.1.1 sends the target string in TCP stream 1" 1>&2
  echo "  after 20250407-103326." 1>&2
  echo "    breach_1_input.pcap" 1>&2
  exit 1
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

process_stream_dump(){
    if [ "$4" = "" ]; then
      MATCHED=$(tshark -r $1 -V | grep -oE $3 | head -n 1)
    else
      MATCHED=$(tshark -r $1 -Y "ip.src eq $4" -V | grep -oE $3 | head -n 1)
    fi
    if [ $MATCHED ]; then
      FRAME_TIME=$(tshark -r $1 -T fields -e frame.time_epoch | head -n 1 | awk '{ cmd="date -d @"$1" +\"%Y%m%d-%H%M%S\""; cmd | getline t; close(cmd); print t }')
      DUMP_DIR=$(dirname "$1")
      if [ "$4" = "" ]; then
        # Process all packets in the breach record sequentially until 
        tshark -r $1 -T fields -e _ws.col.number | sort -n | uniq | while read PACKET; do
          MATCHED_PKT=$(tshark -r $1 -Y "_ws.col.number eq $PACKET" -V | grep -oE $3 | head -n 1)
          if [ $MATCHED_PKT ]; then
            RECEIVER_IP=$(tshark -r $1 -Y "_ws.col.number eq $PACKET" -T fields -e ip.dst | uniq)
            SENDER_IP=$(tshark -r $1 -Y "_ws.col.number eq $PACKET" -T fields -e ip.src | uniq)
            SENDER_PORT=$(tshark -r $1 -Y "_ws.col.number eq $PACKET" -T fields -e tcp.srcport | uniq)
            # the below part looks redundant but is necessary.
            # because this while loop involves a pipe, "| while read PACKET",
            # the loop is not running in the same bash process as the rest of the script,
            # meaning that all these variables set above cannot be seen after the loop.
            # everything have to be completed within the loop.
            message "=== TARGET STRING $MATCHED SENT from $SENDER_IP:$SENDER_PORT to $RECEIVER_IP at $FRAME_TIME"
            BREACH_DUMP=${DUMP_DIR}/${2}-${SENDER_PORT}_${FRAME_TIME}.pcap
            mv $1 $BREACH_DUMP
            message "=== stream dump kept as: $BREACH_DUMP"
            break
          fi
        done
      else
        RECEIVER_IP=$(tshark -r $1 -Y "ip.src eq $4" -T fields -e ip.dst | uniq)
        SENDER_IP=$4
        SENDER_PORT=$(tshark -r $1 -Y "ip.src eq $4" -T fields -e tcp.srcport | uniq)
        message "=== TARGET STRING $MATCHED SENT from $SENDER_IP:$SENDER_PORT to $RECEIVER_IP at $FRAME_TIME"
        BREACH_DUMP=${DUMP_DIR}/${2}-${SENDER_PORT}_${FRAME_TIME}.pcap
        mv $1 $BREACH_DUMP
        message "=== stream dump kept as: $BREACH_DUMP"
      fi
    else
      rm $1
      message "deleted: $1"
    fi
}

STREAM_PREFIX="stream"

# default values for argements able to set by command line
BREACH_PREFIX=""
FLAG_REGEX=""
SENDER_IP=""
CUTOFF=0

while getopts i:c:p:t:s:h OPT
do
  case $OPT in
    i)  PCAP_PATH=$OPTARG
        ;;
    c)  CUTOFF=$OPTARG
        ;;
    p)  BREACH_PREFIX=$OPTARG
        ;;
    t)  FLAG_REGEX=$OPTARG
        ;;
    s)  SENDER_IP=$OPTARG
        ;;
    h)  usage_exit
        ;;
    \?) usage_exit
        ;;
  esac
done

shift $((OPTIND - 1))

# check the validitity of argument
if [ ! -f "$PCAP_PATH" ]; then
  message "pcap file $PCAP_PATH does not exist"
  exit 1
fi
if [ $CUTOFF != 0 ]; then
  CUTOFF_S=$(echo $CUTOFF | awk '{ cmd="date -d @"$1" +\"%Y%m%d-%H%M%S\""; cmd | getline t; close(cmd); print t }')
  message "TCP traffic more recent than $CUTOFF_S will be analyzed"
fi
if [ "$BREACH_PREFIX" = "$STREAM_PREFIX" ]; then
  message "$STREAM_PREFIX is reserved.  specify a different prefix."
  exit 1
elif [ "$BREACH_PREFIX" = "" ]; then
  message "specify a valid prefix with -p option"
  exit 1
fi
if [ "$FLAG_REGEX" = "" ]; then
  message "specify a valid target string with -t option"
  exit 1
fi
if [ "$SENDER_IP" = "" ]; then
  message "=== WARNING: sender IP not specified and all TCP traffic will be analyzed"
elif [[ ! "$SENDER_IP" =~ ^(([1-9]?[0-9]|1[0-9][0-9]|2([0-4][0-9]|5[0-5]))\.){3}([1-9]?[0-9]|1[0-9][0-9]|2([0-4][0-9]|5[0-5]))$ ]]; then
  message "$SENDER_IP is not a valid IP address"
  exit 1
fi

check_command tshark

PCAP_DIR=$(dirname $PCAP_PATH)
PCAP_FILE=$(basename $PCAP_PATH)

# Identify all TCP streams in the merged pcap file, and process each of them
tshark -r $PCAP_PATH -Y "frame.time_epoch >= $CUTOFF" -T fields -e tcp.stream | sort -n | uniq | while read STREAM; do
  STREAM_DUMP=${PCAP_DIR}/${STREAM_PREFIX}-${STREAM}_${PCAP_FILE}
  message "extracting a stream: $STREAM_DUMP"
  tshark -r $PCAP_PATH -Y "tcp.stream eq $STREAM" -w $STREAM_DUMP 
  process_stream_dump $STREAM_DUMP $BREACH_PREFIX $FLAG_REGEX $SENDER_IP
done
