#!/usr/bin/env bash
#

set -e

BASE_DIR='/mnt/gentoo-test'

SRCPATH=$(realpath "${0}")
SRCPATH=${SRCPATH%/.tool/*}
. ${SRCPATH}/_log.sh

_log n ">> umount -fv ${BASE_DIR}/_testEbuilds-REPO_*/**/TMPFS"
if ls ${BASE_DIR}/_testEbuilds-REPO_*/**/TMPFS &>/dev/null; then
  umount -fv ${BASE_DIR}/_testEbuilds-REPO_*/**/TMPFS
else
  echo "<NONE>"
fi

echo
_log n ">> btrfs subvolume delete ${BASE_DIR}/_testEbuilds-REPO_*/**/SNAPSHOT"
if ls ${BASE_DIR}/_testEbuilds-REPO_*/**/SNAPSHOT &>/dev/null; then
  btrfs subvolume delete ${BASE_DIR}/_testEbuilds-REPO_*/**/SNAPSHOT
else
  echo "<NONE>"
fi

echo
_log n ">> rm -rfv ${BASE_DIR}/_testEbuilds-REPO_*"
if ls ${BASE_DIR}/_testEbuilds-REPO_* &>/dev/null; then
  rm -rfv ${BASE_DIR}/_testEbuilds-REPO_*
else
  echo "<NONE>"
fi

echo
_log n ">> rm -v /tmp/_testEbuilds-REPO_*"
if ls /tmp/_testEbuilds-REPO_* &>/dev/null; then
  rm -v /tmp/_testEbuilds-REPO_*
else
  echo "<NONE>"
fi

