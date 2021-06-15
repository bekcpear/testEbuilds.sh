#!/usr/bin/env bash
#
# @bekcpear
#

MAXJOBS=8

# 0 --> disable
# 1 --> remove corresponding snapshot and command file
# 2 --> remove corresponding log
# 3 --> remove corresponding all resources
REMOVE_WHEN_SUCCESSED=3

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
Usage: ${0##*/} [-b <dir-path>] [-d <path>] <repo-name> <atom>...

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

declare -a STATUS
declare -a ATOMS
for atom; do
  ATOMS+=( "${atom}" )
  STATUS+=( "WAITING" )
done

declare -r CURRENTID=${REPONAME}-$(date -d @${STARTTIME} +%Y_%m_%d-%H_%M)-$(uuidgen | cut -d'-' -f1)
declare -r WORKPATH="${FSBASEPATH%/*}"/_testEbuilds-${CURRENTID}
declare -r MERGECMD="ACCEPT_KEYWORDS='${ACCEPT_KEYWORDS:-amd64}' \
                     ACCEPT_LICENSES='${ACCEPT_LICENSES:-*}' \
                     emerge --autounmask --autounmask-write -v1"

# handle binding files/directories
declare -r TMPPATH=/tmp/_testEbuilds-${CURRENTID}
mkdir -p ${TMPPATH}
cp ${SRCPATH%/*}/repos.conf ${TMPPATH}/repos.conf
eval "sed -i 's/#REPONAME#/${REPONAME_RAW}/' ${TMPPATH}/repos.conf"
for binding in ${BINDINGS[@]}; do
  BINDING_OPTS+=" --ro-bind '${binding}' '${binding}'"
done
if [[ -d ${BINDFDIR} ]]; then
  while read -r path; do
    BINDING_OPTS+=" --ro-bind '${path}' '${path#${BINDFDIR}}'"
  done <<<$(find ${BINDFDIR} -type f)
fi

# FDs
REWIND=${SRCPATH%/*}/rewind
exec {FD_JOBS}<>${TMPPATH}/JOBS
exec {FD_LOG}>${TMPPATH}/LOG
exec {FD_ERR}>${TMPPATH}.err.log
exec 1>&${FD_LOG}
exec 2>&${FD_ERR}
exec {lockfd}>${TMPPATH}/LOCK
function _close_fd() {
  eval "exec ${FD_JOBS}>&-"
  eval "exec ${FD_LOG}>&-"
  eval "exec ${FD_ERR}>&-"
  eval "exec ${lockfd}>&-"
}

# remove tmp files and notify something when shell exits
trap 'exec &>/dev/tty
_close_fd
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
  --bind 'EACHBASEPATH' / \
  --ro-bind /etc/resolv.conf /etc/resolv.conf \
  --ro-bind ${TMPPATH}/repos.conf /etc/portage/repos.conf \
  --ro-bind ${REPO_gentoo} /var/db/repos/gentoo \
  --ro-bind ${!REPONAME} /var/db/repos/local \
  ${BINDING_OPTS} \
  --dev /dev \
  --proc /proc \
  --tmpfs /var/tmp"

echo -n >${TMPPATH}/RUNNING

# show status of all jobs
WAITING='WAITING'
RUNNING='\e[94mRUNNING\e[0m'
SUCCESS='\e[96mSUCCESS\e[0m'
  ERROR='\e[91mERROR  \e[0m'
function _show_status() {
  local _id _state
  local -i maxlen=0 i j
  local -a jobs logs
  for _atom in ${ATOMS[@]}; do
    if [[ ${#_atom} -gt ${maxlen} ]]; then
      maxlen=${#_atom}
    fi
  done
  for (( i = 0; i < ${#ATOMS[@]}; ++i )) do
    local -i _diff=$(( ${maxlen} - ${#ATOMS[i]} ))
    local _space=''
    for (( j = 0; j < ${_diff}; ++j )); do
      _space+=' '
    done
    eval "jobs[${i}]=\"${_space}\${ATOMS[${i}]}\""
  done
  while true; do
    read -r _id _state _log _
    if [[ ${_id} == "_" ]]; then
      break
    fi
    if [[ ${_id} =~ ^[[:digit:]]+$ ]]; then
      eval "STATUS[${_id}]='${_state}'"
      if [[ -n ${_log} ]]; then
        eval "logs[${_id}]='  LOG: ${_log}'"
      fi
    fi
    exec &>/dev/tty
    echo -ne '\e[H\e[J\e[40m'
    echo "testEbuilds.sh information"
    echo -ne '\e[0m'
    _log n "[      LOG] '${TMPPATH}/LOG'"
    _log n "[ERROR LOG] '${TMPPATH}.err.log'"
    echo $'\n'"Job list:"
    for (( i = 0; i < ${#jobs[@]}; ++i )); do
      eval "echo -e \"  ${jobs[i]}: \${${STATUS[i]}}${logs[i]}\""
    done
  done
}
exec {FD_STATUS}> >(_show_status)
echo "A WAITING" >&${FD_STATUS}

# $1: EACHBASEPATH
# $2: the testing atom
# $3: EACHLOGPATH
# $4: EACHCMDPATH
# $5: JOB ID
function _test() {
  local ret=0
  eval "${BWRAPCMD_U/EACHBASEPATH/${1}} /bin/bash -c '${MERGECMD} \"${2}\"' &>'${3}'" || ret=1
  if [[ ${ret} -ne 0 ]]; then
    echo "${5} ERROR ${3}" >&${FD_STATUS}
    _log e "'${2}' error!"
    _log w "LOG: ${3}"
  else
    echo "${5} SUCCESS" >&${FD_STATUS}
    case ${REMOVE_WHEN_SUCCESSED} in
      [13])
        _log i "removing snapshot '${1}' ..."
        btrfs subvolume delete "${1}"
        _log i "removing command file '${4}' ..."
        rm -f "${4}"
        ;;&
      [23])
        _log i "removing log '${3}' ..."
        rm -f "${3}"
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
  eval "${REWIND} ${FD_JOBS}"
  local __jobs=$(( $(cat <&${FD_JOBS}) - 1 ))
  eval "${REWIND} ${FD_JOBS}"
  echo -n ${__jobs}' ' >&${FD_JOBS}
  flock -u "${lockfd}"
}

LOGLEVEL=1
declare -i JOB=0
for atom in ${ATOMS[@]}; do
  JOBS_NOTIFY=0
  while [[ $(eval "${REWIND} ${FD_JOBS}"; cat <&${FD_JOBS}) -ge ${MAXJOBS} ]]; do
    if [[ ${JOBS_NOTIFY} == 0 ]]; then
      _log i "Too many jobs. wait ..."
      JOBS_NOTIFY=1
    fi
    sleep 1
  done
  _log i "JOB: ${JOB}"
  _log i "Creating snapshot for ${atom} ..."
  patom=${atom//\//_}
  mkdir -p "${WORKPATH}"
  EACHBASEPATH="${WORKPATH}"/"${patom}".snapshot
  EACHLOGPATH="${EACHBASEPATH%.snapshot}".log
  EACHCMDPATH="${EACHBASEPATH%.snapshot}".cmd
  btrfs subvolume snapshot "${FSBASEPATH}" "${EACHBASEPATH}"
  _log i "Snapshot ${EACHBASEPATH} created."
  _log i "Testing '${atom}' ..."
  _test "${EACHBASEPATH}" "${atom}" "${EACHLOGPATH}" "${EACHCMDPATH}" "${JOB}" &
  echo "${JOB} RUNNING" >&${FD_STATUS}
  flock -x -w 3 "${lockfd}" || _fatal 1 "flock error!"
  eval "${REWIND} ${FD_JOBS}"
  _jobs=$(( $(cat <&${FD_JOBS}) + 1 ))
  eval "${REWIND} ${FD_JOBS}"
  echo -n ${_jobs} >&${FD_JOBS}
  JOB+=1
  flock -u "${lockfd}"
  echo -n "${BWRAPCMD_U/EACHBASEPATH/${EACHBASEPATH}} /bin/bash --login" >"${EACHCMDPATH}"
  echo "run"
  _log n "  tail -f '${EACHLOGPATH}'"
  echo "to see the log, and can run command in the following file"
  _log n "  ${EACHCMDPATH}"
  echo "to enter the test environment interactively."
  echo
done

wait
exec &>/dev/tty
_close_fd
rmdir --ignore-fail-on-non-empty ${WORKPATH}
while read -p 'All jobs are finished, exit?[y/N]' choice; do
  [[ ${choice} =~ ^y|Y$ ]] && exit 0
done
