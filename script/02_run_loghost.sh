#!/usr/bin/env bash
NAME_CONTAINER="syslog-ng"
NAME_IMAGE="lscr.io/linuxserver/syslog-ng"
DIR_CONFIG="syslog.config"
DIR_WRITE="syslog.out"
DIR_EXEC="02_syslog"

message(){
  echo "$(date +'%Y-%m-%d %T') " $@
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

cd `dirname $0`
check_command docker
touch_dir $DIR_CONFIG
message cp ${DIR_EXEC}/syslog-ng.conf ${DIR_CONFIG}/
cp ${DIR_EXEC}/syslog-ng.conf ${DIR_CONFIG}/
touch_dir $DIR_WRITE
cd $DIR_EXEC

# if an image with the name does NOT exist
if [ ! "$(sudo docker image ls -q "$NAME_IMAGE")" ]; then
  # build a new image
  sudo docker build -t "$NAME_IMAGE" .
fi

# if container exists
if [ "$(sudo docker ps -aq -f name="$NAME_CONTAINER")" ]; then
  message container $NAME_CONTAINER exists
  # and if running...
  if [ "$(sudo docker ps -q -f name="$NAME_CONTAINER")" ]; then
    message container $NAME_CONTAINER running
    # stop it
    sudo docker stop "$NAME_CONTAINER"
  fi
  # then remove it
  sudo docker rm "$NAME_CONTAINER"
fi

# run
sudo docker-compose up -d
# exec
sudo docker exec -it "$NAME_CONTAINER" /bin/bash

# help
echo "sudo docker ps"
echo "sudo docker stop (id)"
echo "sudo docker rm (id)"
echo "sudo docker image ls"
echo "sudo docker rmi (name)"
