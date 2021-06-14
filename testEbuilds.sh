#!/usr/bin/env bash
#
# @bekcpear
#

set -e

MAXJOBS=2
FSBASEPATH='/mnt/gentoo-test/stage3'
REPO_ryans='/home/ryan/Git/ryans-repos'
REPO_gentoo='/var/db/repos/gentoo.git/gentoo'
REPO_gentoo_zh='/home/ryan/Git/gentoo-zh'


#############################################
#############################################
#############################################
STARTTIME=$(date +%s)
FSBASEPATH="${FSBASEPATH%/}"
SRCPATH="${0}"
if [[ -L "${SRCPATH}" ]]; then
  eval "SRCPATH=\$(readlink '${SRCPATH}')"
fi
. "${SRCPATH%/*}"/_log.sh

function _help() {
  cat <<EOF
Usage: ${0##*/} [-b <dir-path>] [-d <path>] <repo-name> <pkgname/setname>...

-b <path>         bind the file/dir to the same path in the environment readonly
-d <dir-path>     all files under this path will be binded to the test
                  environment readonly. (directories will be ignored)
                  e.g.: <dir-path>/a/bc will be binded to /a/bc

ATTENTION: <repo-name> should be setted in this shell at first few lines
                       with its absolute path, the format:
                          REPO_<repo-name>='<absolute-path>'
                       and, all '-' in the name should be replaced to '_'.
EOF
}

if [[ ${1} =~ ^--?h(elp)? ]]; then
  _help
  exit 0
fi

if [[ ${EUID} -ne 0 ]]; then
  _fatal 1 "root user only!"
fi

if ! btrfs subvolume show ${FSBASEPATH} &>/dev/null; then
  _fatal 1 "Cannot detect such subvolume '${FSBASEPATH}'"
fi

declare -a BINDINGS
BINDFDIR=''
for arg; do
  case ${arg} in
    -b)
      shift
      [[ -e ${1} ]] || _fatal 1 "${1} not exists."
      [[ ${1} != '/' ]] || _fatal 1 "${1} is root(/)."
      BINDINGS+=( "${1}" )
      shift
      ;;
    -d)
      shift
      [[ -d ${1} ]] || _fatal 1 "${1} is not a directory."
      [[ ${1} != '/' ]] || _fatal 1 "${1} is root(/)."
      BINDFDIR="${1}"
      shift
      ;;
  esac
done
declare -r BINDFDIR=${BINDFDIR%/}

REPONAME_RAW="${1}"
REPONAME="${1//-/_}"
if eval "declare -p REPO_${REPONAME} &>/dev/null"; then
  REPONAME="REPO_${REPONAME}"
else
  _fatal 1 "Unknown repo name '${1}'"
fi
shift

declare -a SETNAMES
declare -a PKGNAMES
for atom; do
  if [[ ${atom} =~ ^@ ]]; then
    SETNAMES+=( "${atom}" )
  else
    PKGNAMES+=( "${atom}" )
  fi
done

declare -r CURRENTID=${REPONAME}_$(date -d @${STARTTIME} +%Y_%m_%d-%H_%M)_$(uuidgen | cut -d'-' -f1)
declare -r WORKPATH="${FSBASEPATH%/*}"/_testEbuilds_${CURRENTID}
declare -r MERGECMD="ACCEPT_KEYWORDS='${ACCEPT_KEYWORDS:-amd64}' \
                     ACCEPT_LICENSES='${ACCEPT_LICENSES:-*}' \
                     emerge --autounmask --autounmask-write -v1"

# handle binding files/directories
declare -r TMPPATH=/tmp/_testEbuilds_${CURRENTID}
mkdir -p ${TMPPATH}
cp ${SRCPATH%/*}/repos.conf ${TMPPATH}/repos.conf
eval "sed -i 's/#REPONAME#/${REPONAME_RAW}/' ${TMPPATH}/repos.conf"
for binding in ${BINDINGS[@]}; do
  BINDING_OPTS+=" --ro-bind '${binding}' '${binding}'"
done
if [[ -d ${BINDFDIR} ]]; then
  BINDING_OPTS+=$(while read -r path; do
      echo -n " --ro-bind '${path}' '${path#${BINDFDIR}}'"
    done <<<$(find ${BINDFDIR} -type f))
fi
declare -r BWRAPCMD_U="bwrap \
  --bind EACHBASEPATH / \
  --ro-bind /etc/resolv.conf /etc/resolv.conf \
  --ro-bind ${TMPPATH}/repos.conf /etc/portage/repos.conf \
  --ro-bind ${REPO_gentoo} /var/db/repos/gentoo \
  --ro-bind ${!REPONAME} /var/db/repos/local \
  ${BINDING_OPTS} \
  --dev /dev \
  --proc /proc \
  --tmpfs /var/tmp"

echo -n 0 >${TMPPATH}/JOBS
exec {lockfd}> ${TMPPATH}/LOCK
# $1: EACHBASEPATH
# $2: the testing pkgname
# $3: EACHLOGPATH
function _test() {
  set +e
  eval "${BWRAPCMD_U/EACHBASEPATH/${1}} /bin/bash -c '${MERGECMD} ${2}' &>${3}"
  if [[ $? -ne 0 ]]; then
    _log e "'${2}' error!"
    _log w "LOG: ${3}"
  fi
  flock -x -w 3 "${lockfd}" || _fatal 1 "flock error!"
  echo -n $(( $(cat ${TMPPATH}/JOBS) - 1 )) >${TMPPATH}/JOBS
  flock -u "${lockfd}"
  set -e
}

trap '_log i "removing ${TMPPATH} ..."
rm -rf ${TMPPATH}
_log n "You can run
  # btrfs subvolume delete ${WORKPATH}/*.snapshot
  # rm -rf ${WORKPATH}
to delete files."' EXIT

LOGLEVEL=1
declare -i JOB=0
for name in ${SETNAMES[@]} ${PKGNAMES[@]}; do
  JOBS_NOTIFY=0
  while [[ $(cat ${TMPPATH}/JOBS) -ge ${MAXJOBS} ]]; do
    if [[ ${JOBS_NOTIFY} == 0 ]]; then
      _log i "Too many jobs. wait ..."
      JOBS_NOTIFY=1
    fi
    sleep 1
  done
  JOB+=1
  _log i "JOB: ${JOB}"
  _log i "Creating snapshot for ${name} ..."
  pname=${name//\//_}
  mkdir -p "${WORKPATH}"
  EACHBASEPATH="${WORKPATH}"/"${pname}".snapshot
  EACHLOGPATH="${EACHBASEPATH%.snapshot}".log
  btrfs subvolume snapshot "${FSBASEPATH}" "${EACHBASEPATH}"
  _log i "Snapshot ${EACHBASEPATH} created."
  _log i "Testing '${name}' ..."
  _test "${EACHBASEPATH}" "${name}" "${EACHLOGPATH}" &
  flock -x -w 3 "${lockfd}" || _fatal 1 "flock error!"
  echo -n $(( $(cat ${TMPPATH}/JOBS) + 1 )) >${TMPPATH}/JOBS
  flock -u "${lockfd}"
  echo "run"
  _log n "  tail -f ${EACHLOGPATH}"
  echo "to see the log, and run"
  _log n "  ${BWRAPCMD_U/EACHBASEPATH/${EACHBASEPATH}} /bin/bash --login"
  echo "to enter the test environment interactively."
  echo
done

wait
