#!/usr/bin/env bash
#
#

set -e

SNAPSHOTS=(
  '/mnt/gentoo-test/stage3*'
)
GENTOOBASE="/var/db/repos/gentoo.git/gentoo"

SRCPATH=$(realpath "${0}")
SRCPATH=${SRCPATH%/.tool/*}
. ${SRCPATH}/_log.sh

for snapshot in ${SNAPSHOTS[@]}; do
  while read -r path; do
    echo
    _log n "udpating ${path} ..."
    echo
    bwrap --bind "${path}" / \
      --ro-bind /etc/resolv.conf /etc/resolv.conf \
      --ro-bind ${GENTOOBASE} /var/db/repos/gentoo \
      --dev /dev \
      --proc /proc \
      --tmpfs /var/tmp \
      /bin/bash -c 'emerge -jvuDN @world'
  done <<<$(ls -1d ${snapshot})
done
