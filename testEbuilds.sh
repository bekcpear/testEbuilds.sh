#!/usr/bin/env bash
#
# @bekcpear
#

MAXJOBS=8
MAXJOBS_FOR_PRETEND=20

# 0 --> disable
# 1 --> remove corresponding snapshot, tmpfs and command file
# 2 --> remove corresponding log
# 3 --> remove corresponding all resources
REMOVE_WHEN_SUCCESSED=3

# 0 --> not preserve
# 1 --> preserve
PRESERVE_TMP_ERR_LOG=0

EMERGE_OPTS='--autounmask=y -jv1'

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
PRETEND_FLAG=0
if [[ -L "${SRCPATH}" ]]; then
  eval "SRCPATH=\$(readlink '${SRCPATH}')"
fi
. "${SRCPATH%/*}"/_log.sh

function _help() {
  cat <<EOF
Usage: ${0##*/} [-b <dir-path>] [-d <path>] [-p] <repo-name> <atom>...

  -b <path>         bind the file/dir to the same path in the environment readonly
  -d <dir-path>     all files under this path will be binded to the test
                    environment readonly. (directories will be ignored)
                    e.g.: <dir-path>/a/bc will be binded to /a/bc
  -p                print emerge pretend information to the log only

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
    -p)
      PRETEND_FLAG=1
      MAXJOBS=${MAXJOBS_FOR_PRETEND}
      shift
      ;;
  esac
done
declare -r BINDFDIR=${BINDFDIR%/}

REPOBRANCH='<NONE>' # for git only at present
REPONAME_RAW="${1}"
REPONAME="${1//-/_}"
if eval "declare -p REPO_${REPONAME} &>/dev/null"; then
  REPONAME="REPO_${REPONAME}"
  eval "${REPONAME}=\${${REPONAME}%/}"
  [[ -d ${!REPONAME} ]] && [[ $(cat ${!REPONAME}/profiles/repo_name) == ${REPONAME_RAW} ]] \
    || _fatal 1 "'${!REPONAME}' is not a repo directory for '${REPONAME_RAW}'."
  pushd "${!REPONAME}"
  REPOBRANCH=$(git branch --show-current 2>/dev/null)
  popd
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

MERGEENVS="ACCEPT_LICENSE='*'"
[[ -z ${ACCEPT_KEYWORDS} ]] || MERGEENVS+=" ACCEPT_KEYWORDS='${ACCEPT_KEYWORDS:-amd64}'"
[[ -z ${MAKEOPTS} ]] || MERGEENVS+=" MAKEOPTS='${MAKEOPTS:--j1}'"
[[ -z ${USE} ]] || MERGEENVS+=" USE='${USE}'"
declare -r CURRENTID=${REPONAME}-$(date -d @${STARTTIME} +%Y_%m_%d-%H_%M)-$(uuidgen | cut -d'-' -f1)
declare -r WORKPATH="${FSBASEPATH%/*}"/_testEbuilds-${CURRENTID}
declare -r TMPPATH=/tmp/_testEbuilds-${CURRENTID}
declare -r MERGEARGS
declare -r MERGECMD="${MERGEENVS} emerge ${EMERGE_OPTS}"

# prepare directories
mkdir -p ${WORKPATH}
mkdir -p ${TMPPATH}

# handle binding files/directories
cp ${SRCPATH%/*}/repos.conf ${WORKPATH}/repos.conf
eval "sed -i 's/#REPONAME#/${REPONAME_RAW}/' ${WORKPATH}/repos.conf"
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
function _close_fd() {
  eval "exec ${FD_JOBS}>&-"
  eval "exec ${FD_LOG}>&-"
  eval "exec ${FD_ERR}>&-"
}

# remove tmp files and notify something when shell exits
trap 'exec &>/dev/tty
set +e
_close_fd
echo
echo "removing ${TMPPATH} ..."
rm -rf ${TMPPATH}
if [[ ${PRESERVE_TMP_ERR_LOG} == 0 ]]; then
  echo "removing ${TMPPATH}.err.log ..."
  rm -rf ${TMPPATH}.err.log
fi
if [[ $(ls -A ${WORKPATH}) == "repos.conf" ]]; then
  rm ${WORKPATH}/repos.conf
  rmdir --ignore-fail-on-non-empty ${WORKPATH}
fi
if [[ -d ${WORKPATH} ]]; then
  echo "You can run"
  ls ${WORKPATH}/**/SNAPSHOT &>/dev/null && \
  _log n "  # btrfs subvolume delete ${WORKPATH}/**/SNAPSHOT"
  ls ${WORKPATH}/**/TMPFS &>/dev/null && \
  _log n "  # umount ${WORKPATH}/**/TMPFS"
  _log n "  # rm -rf ${WORKPATH}"
  echo "to delete remaining files."
fi' EXIT

declare -r BWRAPCMD_U="bwrap \
  --bind 'EACHBASEPATH' / \
  --bind 'TMPFSPATH' /var/tmp \
  --ro-bind /etc/resolv.conf /etc/resolv.conf \
  --ro-bind ${WORKPATH}/repos.conf /etc/portage/repos.conf \
  --ro-bind ${REPO_gentoo} /var/db/repos/gentoo \
  --ro-bind ${!REPONAME} /var/db/repos/local \
  ${BINDING_OPTS} \
  --dev /dev \
  --proc /proc"

# show status of all jobs
WAITING='WAITING'
RUNNING='\e[94mRUNNING\e[0m'
PRETEND='\e[36mPRETEND\e[0m'
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
    echo " testEbuilds.sh "
    echo -ne '\e[0m'
    echo "[          LOG] '${TMPPATH}/LOG'"
    echo "[    ERROR LOG] '${TMPPATH}.err.log'"
    echo "[BASE SNAPSHOT] '${FSBASEPATH}'"
    echo
    _log n "[         REPO] ᚠ ${REPOBRANCH} '${!REPONAME}'"
    _log n "[ WORKING PATH] '${WORKPATH}'"
    echo $'\n'"Job list:"
    for (( i = 0; i < ${#jobs[@]}; ++i )); do
      eval "echo -e \"  ${jobs[i]}: \${${STATUS[i]}}${logs[i]}\""
    done
  done
}
exec {FD_STATUS}> >(_show_status)
echo "A WAITING" >&${FD_STATUS}

# store the current jobs count
function _store_jobs() {
  local _counted=0
  local -i _counts=0
  while true; do
    read -r _op _
    eval "_counts=\$(( ${_counts} ${_op} 1 ))"
    flock -w 2 ${FD_JOBS} || _fatal 1 "flock error!"
    eval "${REWIND} ${FD_JOBS}"
    echo -n ${_counts}' ' >&${FD_JOBS}
    flock -u ${FD_JOBS}
    if [[ ${_counted} -eq 0 ]]; then
      _counted=1
    elif [[ ${_counts} -le 0 ]]; then
      echo "_" >&${FD_STATUS}
      break
    fi
  done
}
exec {FD_JOBS_STORE}> >(_store_jobs)

# $1: EACHBASEPATH
# $2: EACHTMPPATH
# $3: the testing atom
# $4: EACHLOGPATH
# $5: EACHCMDPATH
# $6: JOB ID
function _test() {
  local ret=0
  local _arg _this_log _success_state='SUCCESS'
  if [[ ${PRETEND_FLAG} == 1 ]]; then
    _arg='-p'
    _this_log="${4}"
    _success_state='PRETEND'
  fi
  local _cmd="${BWRAPCMD_U/EACHBASEPATH/${1}}"
  eval "${_cmd/TMPFSPATH/${2}} /bin/bash -c '${MERGECMD} ${_arg} \"${3}\"' &>'${4}'" || ret=1
  if [[ ${ret} -ne 0 ]]; then
    echo "${6} ERROR ${4}" >&${FD_STATUS}
    _log e "'${3}' error!"
    _log w "LOG: ${4}"
  else
    echo "${6} ${_success_state} ${_this_log}" >&${FD_STATUS}
    case ${REMOVE_WHEN_SUCCESSED} in
      [13])
        _log i "removing snapshot '${1}' ..."
        btrfs subvolume delete "${1}"
        _log i "umounting '${2}' ..."
        umount -f "${2}"
        rmdir --ignore-fail-on-non-empty "${2}"
        _log i "removing command file '${5}' ..."
        rm -f "${5}"
        ;;&
      [23])
        if [[ ${PRETEND_FLAG} == 0 ]]; then
          _log i "removing log '${4}' ..."
          rm -f "${4}"
        fi
        rmdir --ignore-fail-on-non-empty "${1%/*}"
        ;;
      [0123])
        :
        ;;
      *)
        _log w "invalid value(${REMOVE_WHEN_SUCCESSED}) of 'REMOVE_WHEN_SUCCESSED', ignore it."
        ;;
    esac
  fi
  echo "-" >&${FD_JOBS_STORE}
}

LOGLEVEL=1
BWRAPCMD_EACH=''
declare -i JOB=0
for atom in ${ATOMS[@]}; do
  JOBS_NOTIFY=0
  flock -w 2 ${FD_JOBS} || _fatal 1 "flock error!"
  while [[ $(eval "${REWIND} ${FD_JOBS}"; cat <&${FD_JOBS}) -ge ${MAXJOBS} ]]; do
    if [[ ${JOBS_NOTIFY} == 0 ]]; then
      _log i "Too many jobs. wait ..."
      JOBS_NOTIFY=1
    fi
    sleep 1
  done
  flock -u ${FD_JOBS}
  _log i "JOB: ${JOB}"
  patom=${atom//\//:}
  EACHWORKPATH="${WORKPATH}"/"${patom}"
  EACHBASEPATH="${EACHWORKPATH}"/SNAPSHOT
  EACHTMPPATH="${EACHWORKPATH}"/TMPFS
  EACHLOGPATH="${EACHWORKPATH}"/LOG
  EACHCMDPATH="${EACHWORKPATH}"/CMD
  _log i "Creating workdir for ${atom} ..."
  mkdir ${EACHWORKPATH}
  _log i "Creating snapshot for ${atom} ..."
  btrfs subvolume snapshot "${FSBASEPATH}" "${EACHBASEPATH}"
  _log i "Snapshot ${EACHBASEPATH} created."
  _log i "Mounting tmpfs for ${atom} ..."
  mkdir "${EACHTMPPATH}"
  mount -t tmpfs tmpfs "${EACHTMPPATH}"
  _log i "Tmpfs has been mounted at ${EACHTMPPATH}."
  _log i "Patching portage ..."
  sed -i 's/0o660/0o644/' "${EACHBASEPATH}"/usr/lib/python*/site-packages/portage/util/_async/PipeLogger.py
  sed -i 's/0o700/0o755/' "${EACHBASEPATH}"/usr/lib/python*/site-packages/portage/package/ebuild/prepare_build_dirs.py
  sed -i 's/0700/0755/' "${EACHBASEPATH}"/usr/share/portage/config/make.globals
  _log i "Testing '${atom}' ..."
  _test "${EACHBASEPATH}" "${EACHTMPPATH}" "${atom}" "${EACHLOGPATH}" "${EACHCMDPATH}" "${JOB}" &
  echo "${JOB} RUNNING" >&${FD_STATUS}
  echo "+" >&${FD_JOBS_STORE}
  JOB+=1
  BWRAPCMD_EACH="${BWRAPCMD_U/EACHBASEPATH/${EACHBASEPATH}}"
  echo -n "${BWRAPCMD_EACH/TMPFSPATH/${EACHTMPPATH}} /bin/bash --login" >"${EACHCMDPATH}"
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
echo
while read -p 'All jobs are finished, exit?[y/N] ' choice; do
  [[ ${choice} =~ ^y|Y$ ]] && exit 0
done
