#!/usr/bin/env bash
#
# @bekcpear
#


REPO='/home/ryan/Git/ryans-repos'

BASE_DIR='/mnt/gentoo-test'
BINDDIR='/home/ryan/Git/testEbuilds/_test_conf_root'

BASE="${BASE_DIR}/stage3"
WITH_GIT="${BASE_DIR}/stage3-with-git"
WITH_X="${BASE_DIR}/stage3-with-profile-desktop"
#WITH_X_GIT="${BASE_DIR}/stage3-with-X-git"

SRCPATH=$(realpath "${0}")
SRCPATH=${SRCPATH%/.tool/*}
. ${SRCPATH}/_log.sh

eval "BASE_CMD=\"'${SRCPATH}'/testEbuilds.sh \\\\
-d '${BINDDIR}' \\\\
-r ${REPO}\""

_log n "BASE"
echo "FSBASEPATH=\"${BASE}\" \\
${BASE_CMD} \\
app-text/ydcv-rs \\
'<dev-libs/v2ray-domain-list-community-9999' \\
'<dev-libs/v2ray-domain-list-community-bin-9999' \\
'<dev-libs/v2ray-geoip-bin-9999' \\
net-proxy/v2ray-core \\
sys-apps/openrazer-driver"

echo
_log n "WITH_GIT"
echo "FSBASEPATH=\"${WITH_GIT}\" \\
${BASE_CMD} \\
app-admin/z16 \\
dev-util/v2ray-geoip-generator \\
sys-apps/openrazer_test \\
dev-libs/v2ray-domain-list-community"

echo
_log n "WITH_X"
echo "FSBASEPATH=\"${WITH_X}\" \\
${BASE_CMD} \\
'app-misc/razergenie sys-apps/openrazer' \\
dev-libs/libopenrazer \\
media-sound/qqmusic-bin \\
net-im/linuxqq-bin"

#_log n "WITH_X_GIT"
#echo "FSBASEPATH=\"${WITH_X_GIT}\" ${BASE_CMD} \
#app-misc/razergenie \
#dev-libs/libopenrazer"
