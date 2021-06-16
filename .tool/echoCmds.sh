#!/usr/bin/env bash
#
# @bekcpear
#


REPO='ryans'

BASE_DIR='/mnt/gentoo-test'
BINDDIR='/home/ryan/Git/testEbuilds/_test_conf_root'

BASE="${BASE_DIR}/stage3"
WITH_GIT="${BASE_DIR}/stage3-with-git"
WITH_X="${BASE_DIR}/stage3-with-X"
WITH_X_GIT="${BASE_DIR}/stage3-with-X-git"

SRCPATH=$(realpath "${0}")
SRCPATH=${SRCPATH%/.tool/*}
. ${SRCPATH}/_log.sh

eval "BASE_CMD=\"'${SRCPATH}'/testEbuilds.sh -d '${BINDDIR}' ${REPO}\""

_log n "BASE"
echo "FSBASEPATH=\"${BASE}\" ${BASE_CMD} \
app-text/ydcv-rs \
'<dev-libs/v2ray-domain-list-community-9999' \
'<dev-libs/v2ray-domain-list-community-bin-9999' \
'<dev-libs/v2ray-geoip-bin-9999' \
net-proxy/v2ray-core \
sys-apps/openrazer-driver"

_log n "WITH_GIT"
echo "FSBASEPATH=\"${WITH_GIT}\" ${BASE_CMD} \
app-admin/z16 \
dev-util/v2ray-geoip-generator \
sys-apps/openrazer_test \
dev-libs/v2ray-domain-list-community"

_log n "WITH_X"
echo "FSBASEPATH=\"${WITH_X}\" ${BASE_CMD} \
media-sound/qqmusic-bin \
net-im/linuxqq-bin \
sys-apps/openrazer"

_log n "WITH_X_GIT"
echo "FSBASEPATH=\"${WITH_X_GIT}\" ${BASE_CMD} \
app-misc/razergenie \
dev-libs/libopenrazer"
