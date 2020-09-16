#!/usr/bin/env bash

if [ `whoami` != 'root' ]; then
  echo "No root, exiting...";
  exit 2
fi

cd /srv/red/Red-DiscordBot;
source ./venv/bin/activate;

git remote update

GIT_LOCAL=$(git rev-parse HEAD);
GIT_REMOTE=$(git rev-parse V3/master);

if [[ "$GIT_LOCAL" == "$GIT_REMOTE" ]]; then
  echo "No changes to Red, $GIT_LOCAL is the latest.";
  YTDL_LOCAL=$(pip list | grep youtube-dl | awk '{print $2}')
  YTDL_CHECK=$(pip list --local --outdated | grep youtube-dl)

  if echo $YTDL_CHECK | grep -q youtube-dl; then
    YTDL_REMOTE=$(echo $YTDL_CHECK | awk '{print $3}')
    echo "Found updated version of youtube-dl, $YTDL_LOCAL -> $YTDL_REMOTE , updating requirements..."
    /bin/systemctl stop red
    pip install --upgrade -r requirements.txt
    /bin/systemctl start red
  else
    echo "No changes to youtube-dl, $YTDL_LOCAL is the latest"
  fi
else
  echo "Changes detected, Currently: $GIT_LOCAL, going to: $GIT_REMOTE";
  /bin/systemctl stop red;
  git pull origin develop
  pip install --upgrade -r requirements.txt
  /bin/systemctl start red;
fi
