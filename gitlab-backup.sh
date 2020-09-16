#!/bin/bash -e
# vim: st=2 sts=2 sw=2 et ai

# Do the heavy lifiting on a different host!
# Keeps a local sync of all GitLab data and packs it up in a format friendly to
# gitlab:backup:restore
#
# NOTE: This depends on frequent database-only backups on the GitLab host itself!
# Alike native backups, many components are encrypted, you are expected to
# maintain a separate backup of gitlab-secrets.json!

REMOTE_USER=backup_user
REMOTE_HOST=remote.gitlab.host
WORK="/home/backup_user/gitlab-backup/work"
FINAL="/home/backup_user/gitlab-backup/"
HEALTHCHECKS_API="https://healthchecks.io/"
latest=
R=$(tput setaf 1 || echo "")
G=$(tput setaf 2 || echo "")
H=$(tput setaf 6 || echo "")
Y=$(tput setaf 3 || echo "")
B=$(tput bold || echo "")
CL=$(tput sgr0 || echo "")


Debug() {
  printf "${H}${B}[ INFO ]${CL} - $1\n" $*
}
Fail() {
  printf "${R}${B}[ FAIL ]${CL} - $1\n" $*
}
Warn() {
  printf "${Y}${B}[ WARN ]${CL} - $1\n" $*
}
Done() {
  printf "${G}${B}[ DONE ]${CL} - $1\n" $*
}

do_clone() {
  # Try to rsync
  Debug "Cloning down: ${1##*/}"
  rsync \
    -aHAXxr \
    --numeric-ids \
    --delete \
    --rsync-path="sudo rsync" \
    -e "ssh -T -o Compression=no -x" \
    --exclude +gitaly \
    ${REMOTE_USER}@${REMOTE_HOST}:${1} ${2};

  RESULT=$?

  # Check the results
  if [ $RESULT -eq 30 ]; then
    Fail "rsync failed, got result: %d" "$RESULT"
    if [ $1 -le 5 ]; then
      Warn "retrying... attempt $1/5";
      do_backup $(($1+1));
    else
      Warn "failed... attempt $1/5";
    fi
    return 1
  elif [ $RESULT -ne 0 ]; then
    Debug "rsync failed, got result: %d" "$RESULT"
    Fail "unhanlded error, exiting...\n"
    return $RESULT
  fi
  Done "Completed clone of: ${B}${G}${1##*/}${CL}"
}

do_archive() {
  Debug "Archiving: $1"
  tar -C $1 -cf $2 .
  Done "Created: $2"
}

db_backup() {
  # Try to rsync
  Debug "Pulling latest database backups"
  rsync \
    -aHAXxr \
    --numeric-ids \
    --rsync-path="sudo rsync" \
    --remove-source-files \
    -e "ssh -T -o Compression=no -x" \
    --include '*.tar' \
    --exclude '*' \
    ${REMOTE_USER}@${REMOTE_HOST}:/var/opt/gitlab/backups/ \
    $WORK/db/;

  RESULT=$?

  # Check the results
  if [ $RESULT -eq 30 ]; then
    Fail "rsync failed, got result: %d" "$RESULT"
    if [ $1 -le 5 ]; then
      Warn "retrying... attempt $1/5\n";
      do_backup $(($1+1));
    else
      Warn "failed... attempt $1/5\n";
    fi
    return 1
  elif [ $RESULT -ne 0 ]; then
    Fail "rsync failed, got result: %d" "$RESULT"
    Fail "unhanlded error, exiting..."
    return $RESULT
  fi

  # With the file cloned, find latest and re-archive
  latest=$(basename $(ls -t $WORK/db/*.tar | cat | head -n1))
  Debug "Found latest as ${B}${H}${latest}${CL}"
  Debug "Extracting database backup to $WORK/intake/"
  tar xf $WORK/db/$latest -C $WORK/intake/
  Done "Finished preparing database backup"
}

pack_backup() {
  local result=
  Debug "Packing backup to $FINAL/$1"

  tar cf $FINAL/$1 -C $WORK/intake .
  result=$?
  if [ $result -ne 0 ]; then
    Fail "Failed packaging backup, got RC: $result";
    return 1;
  fi

  Done "Packed backup to $FINAL/$1"
}

raise() {
  curl -s --retry 3 $HEALTHCHECKS_API/fail
}
  

main() {
  # Stage directories
  curl -s --retry 3 $HEALTHCHECKS_API/start
  mkdir -p $WORK/{intake,artifacts,uploads,builds,lfs,pages}

  do_clone /srv/gitlab/git-data/repositories           $WORK/intake     || raise  # Database
  do_clone /var/opt/gitlab/gitlab-rails/uploads        $WORK/uploads    || raise  # Uploads
  do_clone /var/opt/gitlab/gitlab-ci/builds            $WORK/builds     || raise  # Builds
  do_clone /srv/gitlab/gitlab-rails/shared/artifacts   $WORK/artifacts  || raise  # Artifacts
  do_clone /srv/gitlab/gitlab-rails/shared/registry    $WORK/registry   || raise  # Registry
  do_clone /srv/gitlab/gitlab-rails/shared/pages       $WORK/pages      || raise  # Pages
  do_clone /srv/gitlab/gitlab-rails/shared/lfs-objects $WORK/lfs        || raise  # LFS

  do_archive $WORK/uploads/uploads       $WORK/intake/uploads.tar.gz    || raise
  do_archive $WORK/builds/builds         $WORK/intake/builds.tar.gz     || raise
  do_archive $WORK/artifacts/artifacts   $WORK/intake/artifacts.tar.gz  || raise
  do_archive $WORK/registry/registry     $WORK/intake/registry.tar.gz   || raise
  do_archive $WORK/pages/pages           $WORK/intake/pages.tar.gz      || raise
  do_archive $WORK/lfs                   $WORK/intake/lfs.tar.gz        || raise

  db_backup || raise
  pack_backup "$latest" || raise
  curl -s --retry 3 $HEALTHCHECKS_API


}

main
