#!/usr/bin/env bash
#

set -e

BASE_DIR='/mnt/gentoo-test'

SRCPATH=$(realpath "${0}")
SRCPATH=${SRCPATH%/.tool/*}
. ${SRCPATH}/_log.sh

_log n ">> umount -fv ${BASE_DIR}/_testEbuilds:*/**/TMPFS"
if ls ${BASE_DIR}/_testEbuilds:*/**/TMPFS &>/dev/null; then
  umount -fv ${BASE_DIR}/_testEbuilds:*/**/TMPFS
else
  echo "<NONE>"
fi

echo
_log n ">> btrfs subvolume delete ${BASE_DIR}/_testEbuilds:*/**/SNAPSHOT"
if ls ${BASE_DIR}/_testEbuilds:*/**/SNAPSHOT &>/dev/null; then
  btrfs subvolume delete ${BASE_DIR}/_testEbuilds:*/**/SNAPSHOT
else
  echo "<NONE>"
fi

echo
_log n ">> rm -rfv ${BASE_DIR}/_testEbuilds:*"
if ls ${BASE_DIR}/_testEbuilds:* &>/dev/null; then
  rm -rfv ${BASE_DIR}/_testEbuilds:*
else
  echo "<NONE>"
fi

echo
_log n ">> rm -v /tmp/_testEbuilds:*"
if ls /tmp/_testEbuilds:* &>/dev/null; then
  rm -v /tmp/_testEbuilds:*
else
  echo "<NONE>"
fi

