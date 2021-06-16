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

EMERGE_OPTS='--autounmask=y --keep-going -jv1'

# SHOULD BE ABSOLUTE PATHES
#   the FSBASEPATH can be set via environment variable when
#   running this script to satisfy a specific test environment.
: ${FSBASEPATH:=/mnt/gentoo-test/stage3}
REPO_gentoo='/var/db/repos/gentoo.git/gentoo'
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
INTERACTIVE=0
EXTRAOPTS=
PRETEND_FLAG=0
declare -a EXTRAREPOS EXTRAREPOS_NAME EXTRAREPOS_BRANCH BINDINGS BINDINGDIRS
if [[ -L "${SRCPATH}" ]]; then
  eval "SRCPATH=\$(readlink '${SRCPATH}')"
fi
. "${SRCPATH%/*}"/_log.sh

function _help() {
  cat <<EOF
Usage: ${0##*/} <opts> <atom>...

  -b <path>         bind the file/dir to the same path in the environment readonly
  -d <dir-path>     all files under this path will be binded to the test
                    environment readonly. (directories will be ignored)
                    e.g.: <dir-path>/a/bc will be binded to /a/bc
  -i[<id>]          interactive mode, ignore all atoms and '-p' option
                    if <id> provided, script will enter the specified previous one
  -o <opts>         opts to emerge
  -p                print emerge pretend information to the log only
  -r <repo-path>    add an overlay
EOF
}

# handle options
set +e
unset GETOPT_COMPATIBLE
getopt -T
if [[ ${?} != 4 ]]; then
  _fatal 1 "The command 'getopt' of Linux version is necessory to parse parameters."
fi
ARGS=$(getopt -o 'b:d:hi::o:pr:' -l 'help' -n 'testEbuilds.sh' -- "$@")
if [[ ${?} != 0 ]]; then
  _help
  exit 0
fi
set -e
eval "set -- ${ARGS}"
while true; do
  case ${1} in
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
      BINDINGDIRS+=( "${1%/}" )
      shift
      ;;
    -h|--help)
      _help
      exit 0
      ;;
    -i)
      INTERACTIVE=1
      shift
      if [[ ${1} =~ INTERACTIVE_[a-z0-9]+ ]]; then
        INTERACTIVE_ID=${1}
      fi
      shift
      ;;
    -o)
      shift
      EXTRAOPTS+=" ${1}"
      shift
      ;;
    -p)
      PRETEND_FLAG=1
      MAXJOBS=${MAXJOBS_FOR_PRETEND}
      shift
      ;;
    -r)
      shift
      if [[ -d "${1}" && -f "${1}"/profiles/repo_name ]]; then
        EXTRAREPOS+=( "${1}" )
        pushd "${1}" >/dev/null
        EXTRAREPOS_NAME+=( "$(head -1 profiles/repo_name)" )
        EXTRAREPOS_BRANCH+=( "$(git branch --show-current 2>/dev/null)" )
        popd >/dev/null
      else
        _info w "'${1}' is not an ebuilds repository, ignore it."
      fi
      shift
      ;;
    --)
      shift
      break
      ;;
    *)
      _fatal "unknown error!"
      ;;
  esac
done

if [[ ${EUID} -ne 0 ]]; then
  _fatal 1 "root user only!"
fi

if ! btrfs subvolume show ${FSBASEPATH} &>/dev/null; then
  _fatal 1 "Cannot detect such subvolume '${FSBASEPATH}'"
fi

declare -a ATOMS
declare -a STATUS
for atom; do
  ATOMS+=( "${atom}" )
  STATUS+=( "WAITING" )
done

MERGEENVS="ACCEPT_LICENSE='*'"
[[ -z ${ACCEPT_KEYWORDS} ]] || MERGEENVS+=" ACCEPT_KEYWORDS='${ACCEPT_KEYWORDS:-amd64}'"
[[ -z ${MAKEOPTS} ]] || MERGEENVS+=" MAKEOPTS='${MAKEOPTS:--j1}'"
[[ -z ${USE} ]] || MERGEENVS+=" USE='${USE}'"
if [[ ${INTERACTIVE} == 0 ]]; then
  declare -r CURRENTID=$(date -d @${STARTTIME} +%Y_%m_%d-%H_%M)-$(uuidgen | cut -d'-' -f1)
else
  if [[ -n ${INTERACTIVE_ID} ]]; then
    declare -r CURRENTID=${INTERACTIVE_ID}
  else
    declare -r CURRENTID=INTERACTIVE_$(uuidgen | cut -d'-' -f1)
  fi
fi
declare -r WORKPATH="${FSBASEPATH%/*}"/_testEbuilds-${CURRENTID}
declare -r TMPPATH=/tmp/_testEbuilds-${CURRENTID}
declare -r MERGEARGS
declare -r MERGECMD="${MERGEENVS} emerge ${EMERGE_OPTS} ${EXTRAOPTS}"

# prepare directories
mkdir -p ${WORKPATH}
mkdir -p ${TMPPATH}

# handle binding files/directories
for _binding in ${BINDINGS[@]}; do
  BINDING_OPTS+=" --ro-bind '${_binding}' '${_binding}'"
done
for _bindingdir in ${BINDINGDIRS[@]}; do
  if [[ -d ${_bindingdir} ]]; then
    while read -r path; do
      BINDING_OPTS+=" --ro-bind '${path}' '${path#${_bindingdir}}'"
    done <<<$(find ${_bindingdir} -type f)
  fi
done
if [[ ${#EXTRAREPOS[@]} -gt 0 ]]; then
  mkdir -p ${WORKPATH}/repos.conf
  for (( i = 0; i < ${#EXTRAREPOS[@]}; ++i )); do
    cp ${SRCPATH%/*}/repos.conf/template.conf ${WORKPATH}/repos.conf/${EXTRAREPOS_NAME[i]}
    eval "sed -i 's/#REPONAME#/${EXTRAREPOS_NAME[i]}/' ${WORKPATH}/repos.conf/${EXTRAREPOS_NAME[i]}"
    BINDING_OPTS+=" --ro-bind "${EXTRAREPOS[i]}" /var/db/repos/${EXTRAREPOS_NAME[i]}"
  done
  BINDING_OPTS+=" --ro-bind ${WORKPATH}/repos.conf /etc/portage/repos.conf"
fi

# FDs
function _create_fd() {
  REWIND=${SRCPATH%/*}/rewind
  exec {FD_JOBS}<>${TMPPATH}/JOBS
  exec {FD_LOG}>${TMPPATH}/LOG
  exec {FD_ERR}>${TMPPATH}.err.log
}
function _close_fd() {
  [[ -n ${REWIND} ]] || return
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
fi
if [[ ${INTERACTIVE} == 1 ]]; then
  _log n "ID: ${CURRENTID}"
fi' EXIT

declare -r BWRAPCMD_U="bwrap \
  --bind 'EACHBASEPATH' / \
  --bind 'TMPFSPATH' /var/tmp \
  --ro-bind /etc/resolv.conf /etc/resolv.conf \
  --ro-bind ${REPO_gentoo} /var/db/repos/gentoo \
  ${BINDING_OPTS} \
  --dev /dev \
  --proc /proc"

function _print_config() {
  echo "[          LOG] '${TMPPATH}/LOG'"
  echo "[    ERROR LOG] '${TMPPATH}.err.log'"
  echo "[BASE SNAPSHOT] '${FSBASEPATH}'"
  echo
  for (( i = 0; i < ${#EXTRAREPOS[@]}; ++i )); do
    _log n "[   EXTRA REPO] ᚠ ${EXTRAREPOS_BRANCH[i]} '${EXTRAREPOS[i]}'"
  done
  _log n "[ WORKING PATH] '${WORKPATH}'"
}

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
    _print_config
    echo $'\n'"Job list:"
    for (( i = 0; i < ${#jobs[@]}; ++i )); do
      eval "echo -e \"  ${jobs[i]}: \${${STATUS[i]}}${logs[i]}\""
    done
  done
}

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
if [[ ${INTERACTIVE} == 1 ]]; then
  #interactive mode
  EACHWORKPATH="${WORKPATH}"/INTERACTIVE
  EACHBASEPATH="${EACHWORKPATH}"/SNAPSHOT
  EACHTMPPATH="${EACHWORKPATH}"/TMPFS
  if [[ -z ${INTERACTIVE_ID} ]]; then
    _log i "Creating workdir ..."
    mkdir ${EACHWORKPATH}
    _log i "Creating snapshot ..."
    btrfs subvolume snapshot "${FSBASEPATH}" "${EACHBASEPATH}"
    _log i "Snapshot ${EACHBASEPATH} created."
    _log i "Mounting tmpfs ..."
    mkdir "${EACHTMPPATH}"
    mount -t tmpfs tmpfs "${EACHTMPPATH}"
    _log i "Tmpfs has been mounted at ${EACHTMPPATH}."
  fi
  _print_config
  echo
  _log n "ID: ${CURRENTID}"
  BWRAPCMD_EACH="${BWRAPCMD_U/EACHBASEPATH/${EACHBASEPATH}}"
  eval "${BWRAPCMD_EACH/TMPFSPATH/${EACHTMPPATH}} /bin/bash --login"
else
  #parallel mode
  _create_fd
  exec 1>&${FD_LOG}
  exec 2>&${FD_ERR}
  BWRAPCMD_EACH=''
  exec {FD_STATUS}> >(_show_status)
  exec {FD_JOBS_STORE}> >(_store_jobs)
  echo "A WAITING" >&${FD_STATUS}

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
  echo
  while read -p 'All jobs are finished, exit?[y/N] ' choice; do
    [[ ${choice} =~ ^y|Y$ ]] && exit 0
  done
fi
