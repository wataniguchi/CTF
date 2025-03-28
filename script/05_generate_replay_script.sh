#!/bin/bash

# IP address for server
# ($IF is used only for determine the server IP address
#  assuming that the server resides locally.
#  if the server resides remotely, you can hardcord its IP address.
IF="eth0"
IP_SERVER=$(ip -4 addr show $IF | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
#IP_SERVER="160.16.127.224"

# Flag expressed in regular expression for grep
FLAG_REGEX="FLAG_[0-9a-zA-Z]+"

# Directory where capture files are stored (change if needed)
DIR_READ="pcap.out"
BREACH_PREFIX="breach"

# Directory where replay files are stored (change if needed)
DIR_WRITE="replay.out"
RECORD_PREFIX="record"
PROMPT_PREFIX="prompt"
REPLAY_PREFIX="replay"

# Prompt template for ChatGPT
PROMPT_TEMPLATE="05_prompt.txt"

# How often to check for new files (in seconds)
CHECK_INTERVAL=60

# Keep directory part of the command line for later use
COMMAND_DIR=$(dirname $0)

# Location of chatGPT-shell-cli
GPT_CLI_DIR="${COMMAND_DIR}/../external/chatGPT-shell-cli"
GPT_CLI_BASE="chatgpt.sh"

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

usage_exit(){
  echo "usage:" 1>&2
  echo "  $0" 1>&2
  echo
  echo "  $0 reads pcap TCP stream dump(s)" 1>&2 
  echo "  and produces a readable record of interactions" 1>&2
  echo "  and also a ChatGPT prompt for generating" 1>&2
  echo "  a replay script for each stream." 1>&2
  echo "  when API key set as environment variable OPENAI_API_KEY," 1>&2
  echo "  it speaks to ChatGPT to generate the replay script as well." 1>&2
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

touch_dir(){
  if [ ! -d $1 ]; then
    message "create_dir $1"
    mkdir $1
  fi
}

format_breach(){
  PORT_SERVER=$(tshark -r $1 -Y "ip.src eq $IP_SERVER" -T fields -e tcp.srcport | uniq)
  # Process all packets in the breach record sequentially
  tshark -r $1 -T fields -e _ws.col.number | sort -n | uniq | while read PACKET; do
    SERVER_TO_CLIENT=$(tshark -r $1 -Y "_ws.col.number eq $PACKET && ip.src eq $IP_SERVER" -T fields -e tcp.payload)
    if [ -n "$SERVER_TO_CLIENT" ]; then
      echo $SERVER_TO_CLIENT | xxd -r -p | sed "s/^/server: /" >> $2
      #echo $SERVER_TO_CLIENT | sed "s/^/server-hex: /" >> $2
      echo >> $2
    else
      CLIENT_TO_SERVER=$(tshark -r $1 -Y "_ws.col.number eq $PACKET && ip.dst eq $IP_SERVER" -T fields -e tcp.payload)
      if [ -n "$CLIENT_TO_SERVER" ]; then
        echo $CLIENT_TO_SERVER | xxd -r -p | sed "s/^/client: /" >> $2
        echo $CLIENT_TO_SERVER | sed "s/^/client-hex: /" >> $2
        echo >> $2
      fi
    fi
  done
}

generate_prompt(){
  # Start with the body of the prompt
  cat $1 | sed s/\$FLAG_REGEX/\"$FLAG_REGEX\"/ > $3
  # Append the recorded TCP stream
  cat $2 >> $3
  # Unquote the TCP stream part
  echo "\`\`\`" >> $3
}

# default values for argements able to set by command line
API_KEY=""

while getopts h OPT
do
  case $OPT in
    h)  usage_exit
        ;;
    \?) usage_exit
        ;;
  esac
done

shift $((OPTIND - 1))

# check the validitity of argument
if [ -z "$OPENAI_KEY" ]; then
  message "=== WARNING: API key for ChatGPT missing. replay script will NOT be generated."
  message "=== WARNING: API key can be given as environment variable OPENAI_KEY."
fi

check_command tshark
if [ ! -z "$OPENAI_KEY" ]; then
  check_command curl
  check_command jq
  message "=== POWERED BY chatGPT-shell-cli: https://github.com/0xacx/chatGPT-shell-cli" 2>&1
  if [ ! -f ${GPT_CLI_DIR}/${GPT_CLI_BASE} ]; then
    pushd "${GPT_CLI_DIR}"
    message "${GPT_CLI_BASE} is being cloned from GitHub..."
    git submodule update --init --recursive
    popd
  fi
fi
if [ ! -d "${DIR_READ}" ]; then
  message "$DIR_READ does not exist.  exiting..."
  exit 1
fi
message "waiting for breach record in $DIR_READ"
touch_dir $DIR_WRITE

#shopt -s nullglob
while true; do
  # Process all breach record files
  for f in "${DIR_READ}/${BREACH_PREFIX}"*.pcap; do
    if [ ! -f $f ]; then
      continue
    fi
    BREACH_BASE=$(basename $f)
    RECORD_BASE=$(echo $BREACH_BASE | sed s/${BREACH_PREFIX}/${RECORD_PREFIX}/ | sed s/\.pcap$/\.txt/)
    RECORD=${DIR_WRITE}/${RECORD_BASE}
    PROMPT_BASE=$(echo $RECORD_BASE | sed s/${RECORD_PREFIX}/${PROMPT_PREFIX}/)
    PROMPT=${DIR_WRITE}/${PROMPT_BASE}
    REPLAY_BASE=$(echo $BREACH_BASE | sed s/${BREACH_PREFIX}/${REPLAY_PREFIX}/ | sed s/\.pcap$/\.py/)
    REPLAY=${DIR_WRITE}/${REPLAY_BASE}
    if [ -z "$OPENAI_KEY" ]; then
      FINAL=$PROMPT
    else
      FINAL=$REPLAY
    fi
    if [ ! -f "$FINAL" ]; then
      message "processing $f..."
      rm $RECORD >/dev/null 2>&1
      format_breach $f $RECORD
      message "readable stream record generated: $RECORD"

      generate_prompt ${COMMAND_DIR}/${PROMPT_TEMPLATE} $RECORD $PROMPT
      message "ChatGPT prompt generated: $PROMPT"

      if [ ! -z "$OPENAI_KEY" ]; then
        # 1. Extract only Python code part from ChatGPT response
        # 2. Fix up code ChatGPT generated, first by replacing newlines literally embedded in strings with escaped ASCII sequence...
        # 3. Then, second by removing newlines within double quotes
        cat $PROMPT | ${GPT_CLI_DIR}/${GPT_CLI_BASE} -m gpt-4-turbo \
          | awk '/^```python$/{flag=1; next} /^```$/{flag=0} flag' \
          | perl -0777 -pne 's/\r\n(?=\")/\\r\\n/g' \
          | perl -0777 -pne 's/\n(?=\")/\\n/g' \
          | gawk -v RS='"' 'NR % 2 == 0 { gsub(/\n/, "") } { printf("%s%s", $0, RT) }' > $REPLAY
        message "replay script generated: $REPLAY"
      fi
    fi
  done
  # Wait before checking again
  sleep $CHECK_INTERVAL
done
