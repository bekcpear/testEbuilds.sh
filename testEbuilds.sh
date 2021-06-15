#!/usr/bin/env bash
#
# @bekcpear
#

MAXJOBS=10

# 0 --> disable
# 1 --> remove corresponding snapshot and command file
# 2 --> remove corresponding log
# 3 --> remove corresponding all
REMOVE_WHEN_SUCCESSED=0

# 0 --> not preserve
# 1 --> preserve
PRESERVE_TMP_ERR_LOG=1

# SHOULD BE ABSOLUTE PATHES
#   the FSBASEPATH can be set via environment variable when
#   running this script to satisfy a specific test environment.
: ${FSBASEPATH:=/mnt/gentoo-test/stage3}
REPO_ryans='/home/ryan/Git/ryans-repos'
REPO_gentoo='/var/db/repos/gentoo.git/gentoo'
REPO_gentoo_zh='/home/ryan/Git/gentoo-zh'
# SHOULD BE ABSOLUTE PATHES





#############################################
#############################################
# SHOULD NOT MODIFY THE FOLLOWING CODES
#############################################
#############################################
#############################################
set -e
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
      [[ -e ${1} ]] || _fatal 1 "'${1}' not exists."
      [[ ${1} != '/' ]] || _fatal 1 "'${1}' is root(/)."
      [[ ${1} =~ ^/ ]] || _fatal 1 "'${1}' must be an absolute path."
      BINDINGS+=( "${1}" )
      shift
      ;;
    -d)
      shift
      [[ -d ${1} ]] || _fatal 1 "'${1}' is not a directory."
      [[ ${1} != '/' ]] || _fatal 1 "'${1}' is root(/)."
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
  eval "${REPONAME}=\${${REPONAME}%/}"
  [[ -d ${!REPONAME} ]] && [[ $(cat ${!REPONAME}/profiles/repo_name) == ${REPONAME_RAW} ]] \
    || _fatal 1 "'${!REPONAME}' is not a repo directory for '${REPONAME_RAW}'."
else
  _fatal 1 "Unknown repo name '${REPONAME_RAW}'"
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

# remove tmp files and notify something when shell exits
trap 'exec &>/dev/tty
echo
echo "removing ${TMPPATH} ..."
rm -rf ${TMPPATH}
if [[ ${PRESERVE_TMP_ERR_LOG} == 0 ]]; then
  echo "removing ${TMPPATH}.err.log ..."
  rm -rf ${TMPPATH}.err.log
fi
echo "You can run"
_log n "  # btrfs subvolume delete ${WORKPATH}/*.snapshot"
_log n "  # rm -rf ${WORKPATH}"
echo "to delete remaining files."' EXIT

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

echo -n >${TMPPATH}/RUNNING
# $1: stacked running job's name
function _status() {
  :
}

echo -n 0 >${TMPPATH}/JOBS
exec {lockfd}> ${TMPPATH}/LOCK
# $1: EACHBASEPATH
# $2: the testing pkgname
# $3: EACHLOGPATH
# $4: EACHCMDPATH
function _test() {
  set +e
  eval "${BWRAPCMD_U/EACHBASEPATH/${1}} /bin/bash -c '${MERGECMD} ${2}' &>${3}"
  if [[ $? -ne 0 ]]; then
    _log e "'${2}' error!"
    _log w "LOG: ${3}"
  else
    case ${REMOVE_WHEN_SUCCESSED} in
      [13])
        _log i "removing snapshot '${1}' ..."
        btrfs subvolume delete ${1}
        _log i "removing command file '${4}' ..."
        rm -f ${4}
        ;;&
      [23])
        _log i "removing log '${3}' ..."
        rm -f ${3}
        ;;
      [0123])
        :
        ;;
      *)
        _log w "invalid value(${REMOVE_WHEN_SUCCESSED}) of 'REMOVE_WHEN_SUCCESSED', ignore it."
        ;;
    esac
  fi
  flock -x -w 3 "${lockfd}" || _fatal 1 "flock error!"
  echo -n $(( $(cat ${TMPPATH}/JOBS) - 1 )) >${TMPPATH}/JOBS
  flock -u "${lockfd}"
  set -e
}

LOGLEVEL=1
_log n "[      LOG] '${TMPPATH}/LOG'"
_log n "[ERROR LOG] '${TMPPATH}.err.log'"
exec 1>>${TMPPATH}/LOG
exec 2>>${TMPPATH}.err.log
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
  EACHCMDPATH="${EACHBASEPATH%.snapshot}".cmd
  btrfs subvolume snapshot "${FSBASEPATH}" "${EACHBASEPATH}"
  _log i "Snapshot ${EACHBASEPATH} created."
  _log i "Testing '${name}' ..."
  _test "${EACHBASEPATH}" "${name}" "${EACHLOGPATH}" "${EACHCMDPATH}"&
  flock -x -w 3 "${lockfd}" || _fatal 1 "flock error!"
  echo -n $(( $(cat ${TMPPATH}/JOBS) + 1 )) >${TMPPATH}/JOBS
  flock -u "${lockfd}"
  echo -n "${BWRAPCMD_U/EACHBASEPATH/${EACHBASEPATH}} /bin/bash --login" >${EACHCMDPATH}
  echo "run"
  _log n "  tail -f ${EACHLOGPATH}"
  echo "to see the log, and can run command in the following file"
  _log n "  ${EACHCMDPATH}"
  echo "to enter the test environment interactively."
  echo
done

wait
while read -p 'All jobs are finished, exit?[y/N]' choice; do
  [[ ${choice} =~ ^y|Y$ ]] && exit 0
done
