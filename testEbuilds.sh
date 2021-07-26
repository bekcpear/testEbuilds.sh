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
PRESERVE_TMP_ERR_LOG=1

EMERGE_OPTS='--autounmask=y --keep-going -jtv1'

# SHOULD BE ABSOLUTE PATHES
#   the FSBASEPATH can be set via environment variable when
#   running this script to satisfy a specific test environment.
: ${FSBASEPATH:=/mnt/gentoo-test/stage3}
REPO_gentoo='/var/db/repos/gentoo'
DISTFILES_PATH='/var/cache/distfiles'
# SHOULD BE ABSOLUTE PATHES





#############################################
#############################################
# SHOULD NOT MODIFY THE FOLLOWING CODES
#############################################
#############################################
#############################################
set -eE

STARTTIME=$(date +%s)
FSBASEPATH="${FSBASEPATH%/}"
SRCPATH="${0}"
PRINTCMD=0
RUNNINGMODE='P'
EXTRAOPTS=
PRETEND_FLAG=0
declare -a EXTRAREPOS EXTRAREPOS_NAME EXTRAREPOS_BRANCH BINDINGS BINDINGDIRS
if [[ -L "${SRCPATH}" ]]; then
  eval "SRCPATH=\$(readlink '${SRCPATH}')"
fi
. "${SRCPATH%/*}"/_log.sh

function _help() {
  cat <<EOF
Usage: ${0##*/} [<opts>] <atom>...

  -b <path>         bind the file/dir to the same path in the environment readonly
  -c <ID>           continue to test in parallel mode with this specified ID
  -d <dir-path>     all files under this path will be binded to the test
                    environment readonly. (directories will be ignored)
                    e.g.: <dir-path>/a/bc will be binded to /a/bc
  -g                print the final executing command for interactive mode and exit
  -i[<ID>]          interactive mode, ignore all atoms and '-p' option
                    if <id> provided, script will enter the specified previous one
  -m                maintain mode, enter the base snapshot, no other files
  -o <opts>         opts to emerge
  -p                print emerge pretend information to the log only
  -r <repo-path>    add an overlay

EOF
}

if [[ ${EUID} -ne 0 ]]; then
  _fatal 1 "root user only!"
fi

if ! btrfs subvolume show ${FSBASEPATH} &>/dev/null; then
  _fatal 1 "Cannot detect such subvolume '${FSBASEPATH}'"
fi

# handle options
set +e
unset GETOPT_COMPATIBLE
getopt -T
if [[ ${?} != 4 ]]; then
  _fatal 1 "The command 'getopt' of Linux version is necessory to parse parameters."
fi
ARGS=$(getopt -o 'b:c:d:hgi::mo:pr:' -l 'help' -n 'testEbuilds.sh' -- "$@")
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
    -c)
      shift
      if [[ ${RUNNINGMODE} != 'P' ]]; then
        _fatal "'-c' cannot be used with '-m' or '-g' or '-i'"
      fi
      if [[ ${1} =~ ^PARALLEL_[-_a-z0-9]+$ ]]; then
        CONTINUE_ID=${1}
      else
        _fatal 1 "'${1}' is not a valid ID."
      fi
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
    -g)
      if [[ -n ${CONTINUE_ID} || ${RUNNINGMODE} == 'M' ]]; then
        _fatal "'-g' cannot be used with '-c' or '-m'"
      fi
      PRINTCMD=1
      RUNNINGMODE='I'
      shift
      ;;
    -i)
      if [[ -n ${CONTINUE_ID} || ${RUNNINGMODE} == 'M' ]]; then
        _fatal "'-i' cannot be used with '-c' or '-m'"
      fi
      RUNNINGMODE='I'
      shift
      if [[ ${1} =~ ^INTERACTIVE_[-a-z0-9]+$ ]]; then
        INTERACTIVE_ID=${1}
      elif [[ -n ${1} ]]; then
        _fatal "'${1}' is not a valid ID."
      fi
      shift
      ;;
    -m)
      shift
      if [[ ${RUNNINGMODE} == 'I' || -n ${CONTINUE_ID} ]]; then
        _fatal "'-m' cannot be used with '-c' or '-g' or '-i'"
      fi
      RUNNINGMODE="M"
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
        _fatal 1 "'${1}' is not an ebuilds repository."
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
case ${RUNNINGMODE} in
  P)
    if [[ -z ${CONTINUE_ID} ]]; then
      declare -r CURRENTID=PARALLEL_$(date -d @${STARTTIME} +%Y_%m_%d-%H_%M)-$(uuidgen | cut -d'-' -f1)
    else
      declare -r CURRENTID=${CONTINUE_ID}
    fi
    ;;
  I)
    if [[ -z ${INTERACTIVE_ID} ]]; then
      declare -r CURRENTID=INTERACTIVE_$(uuidgen | cut -d'-' -f1)
    else
      declare -r CURRENTID=${INTERACTIVE_ID}
    fi
    ;;
  M)
    declare -r CURRENTID="MAINTEANANCE_MODE"
    ;;
esac
declare -r WORKPATH="${FSBASEPATH%/*}"/_testEbuilds:${CURRENTID}
declare -r TMPPATH=/tmp/_testEbuilds:${CURRENTID}
declare -r MERGEARGS
declare -r MERGECMD="${MERGEENVS} emerge ${EMERGE_OPTS} ${EXTRAOPTS}"

# prepare directories
mkdir -p ${WORKPATH}
mkdir -p ${TMPPATH}

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
if [[ ${RUNNINGMODE} == P ]]; then
  _create_fd
  exec 1>&${FD_LOG}
  exec 2>&${FD_ERR}
fi

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

# remove tmp files and notify something when shell exits
function _clean() {
  set +e
  if [[ -e ${TMPPATH}/_IS_ABORTED ]]; then
    echo $'\n'"aborting ..."
  elif [[ ${RUNNINGMODE} == P ]]; then
    exec </dev/tty
    echo
    while read -p "All jobs are done. exit? [y/N] " -r _choice; do
      [[ ${_choice} =~ ^y|Y$ ]] && break
    done
  fi
  echo
  if [[ -d "${TMPPATH}" ]]; then
    echo "removing ${TMPPATH} ..."
    rm -rf ${TMPPATH}
  fi
  if [[ ${PRESERVE_TMP_ERR_LOG} == 0 ]]; then
    if [[ -e "${TMPPATH}".err.log ]]; then
      echo "removing ${TMPPATH}.err.log ..."
      rm -f ${TMPPATH}.err.log
    fi
  fi
  if [[ $(ls -A ${WORKPATH} 2>/dev/null) == "repos.conf" ]]; then
    rm -rf ${WORKPATH}/repos.conf
    rmdir --ignore-fail-on-non-empty ${WORKPATH}
  fi
  if [[ -d ${WORKPATH} ]]; then
    echo "You can run"
    find "${WORKPATH}"/ -maxdepth 2 -name "SNAPSHOT" &>/dev/null && \
    _log n "  # btrfs subvolume delete ${WORKPATH}/*/SNAPSHOT"
    find "${WORKPATH}"/ -maxdepth 2 -name "TMPFS" &>/dev/null && \
    _log n "  # umount ${WORKPATH}/*/TMPFS"
    _log n "  # rm -rf ${WORKPATH}"
    echo "to delete remaining files."
  fi
  _log n "ID: ${CURRENTID}"
}

trap 'exec &>/dev/tty
_close_fd
if [[ ${RUNNINGMODE} != P ]]; then
  _clean
fi
' EXIT
trap 'exec &>/dev/tty
set +e
echo >${TMPPATH}/_IS_ABORTED
trap SIGINT
kill -INT 0' SIGINT SIGTERM
trap '_lineno=$(( ${LINENO} - 1 ))
exec &>/dev/tty
set +e
echo >${TMPPATH}/_IS_ABORTED
echo "${JOB} FATAL [ERROR:L${_lineno};CALLER:L$(caller)]" >&${FD_STATUS}
trap SIGINT
kill -INT 0' ERR

declare -r BWRAPCMD_U="bwrap \
  --bind 'EACHBASEPATH' / \
  --bind 'TMPFSPATH' /var/tmp \
  --bind ${DISTFILES_PATH} /var/cache/distfiles \
  --ro-bind /etc/resolv.conf /etc/resolv.conf \
  --ro-bind ${REPO_gentoo} /var/db/repos/gentoo \
  ${BINDING_OPTS} \
  --dev /dev \
  --proc /proc \
  --tmpfs /dev/shm"

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

function _exit_parallel() {
  exec &>/dev/tty
  trap '' SIGINT
  trap '_clean' EXIT
  while true; do
    read -r _signal _
    if [[ ${_signal} == "exit" ]]; then
      break
    fi
  done
}

# show status of all jobs
WAITING='WAITING'
RUNNING='\e[94mRUNNING\e[0m'
PRETEND='\e[36mPRETEND\e[0m'
SUCCESS='\e[96mSUCCESS\e[0m'
  ERROR='\e[91mERROR  \e[0m'
ABORTED='\e[93mABORTED\e[0m'
  FATAL='\e[91m\e[107m\e[7m FATAL \e[0m'
function _show_status() {
  local _id _state
  local -i maxlen=0 i j
  local -a jobs job_ids logs
  trap '' SIGINT
  trap 'echo "exit" >&${FD_EXIT}' EXIT
  for _atom in "${ATOMS[@]}"; do
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
      # the normal exit place
      break
    fi
    if [[ ${_id} =~ ^[[:digit:]]+$ ]]; then
      if [[ ${_state} != 'ABORTED' ]]; then
        if [[ ${_state} =~ RUNNING ]]; then
          eval "job_ids[${_id}]=${_state#RUNNING}"
          eval "STATUS[${_id}]='${_state%G*}G'"
        else
          eval "STATUS[${_id}]='${_state}'"
        fi
      else
        if [[ ${STATUS[${_id}]} =~ RUNNING|WAITING ]]; then
          eval "STATUS[${_id}]='${_state}'"
        fi
      fi
      if [[ -n ${_log} ]]; then
        eval "logs[${_id}]='  LOG: ${_log}'"
      else
        eval "logs[${_id}]=''"
      fi
    fi
    exec &>/dev/tty
    echo -ne '\e[H\e[J\e[40m'
    echo " testEbuilds.sh [PID: $$] "
    echo -ne '\e[0m'
    _print_config
    echo $'\n'"Job list:"
    for (( i = 0; i < ${#jobs[@]}; ++i )); do
      eval "echo -e \"  ${jobs[i]} [${job_ids[i]}]: \${${STATUS[i]}}${logs[i]}\""
    done
  done
}

# store the current jobs count
function _store_jobs() {
  local _counted=0
  local -i _counts=0
  trap '' SIGINT
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
  local -i ret=0 i
  local _atoms=( ${3} )
  local _atom _arg _this_log _state='SUCCESS'
  trap '_aborted=1' SIGINT
  trap 'echo "${6} ${_state} ${_this_log}" >&${FD_STATUS}' EXIT
  if [[ ${PRETEND_FLAG} == 1 ]]; then
    _arg='-p'
    _this_log="${4}"
    _state='PRETEND'
  fi
  local _cmd="${BWRAPCMD_U/EACHBASEPATH/${1}}"
  for (( i = 0; i < ${#_atoms[@]}; ++i )); do
    _atom+=" \"${_atoms[i]}\""
  done
  eval "${_cmd/TMPFSPATH/${2}} /bin/bash --login -c '${MERGECMD} ${_arg} ${_atom}' &>>'${4}'" || ret=1
  if [[ ${ret} -ne 0 ]]; then
    _this_log=${4}
    [[ -n ${_aborted} ]] && _state="ABORTED" || _state="ERROR"
    _log e "'${3}' ${_state}!"
    _log w "LOG: ${4}"
  else
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
  echo "-" >&${FD_JOBS_STORE} # will be executed even if a SIGINT got
}

# bug: https://github.com/containers/bubblewrap/issues/329
# bug: https://bugs.gentoo.org/496328
# pr: https://github.com/containers/bubblewrap/pull/406
function _workaround() {
  _log i "Setting a workaround to fix /dev/shm permission ..."
  echo "chmod 1777 /dev/shm" >"${1}"/etc/profile.d/99-bwrap.sh
}

# $1: ATOM NAME
# $2: BASEPATH
# $3: EACHBASEPATH
# $4: EACHTMPPATH
function _prepare_env() {
  _log i "Creating snapshot for '${1}' ..."
  if btrfs subvolume show ${3} 2>/dev/null; then
    _log i "Snapshot exists, reuse it ..."
  else
    mkdir -p ${3%/*}
    btrfs subvolume snapshot "${2}" "${3}"
    _log i "Snapshot '${3}' created."
    _workaround "${3}"
    _log i "Patching portage ..."
    sed -i 's/0o660/0o644/' "${3}"/usr/lib/python*/site-packages/portage/util/_async/PipeLogger.py
    sed -i 's/0o700/0o755/' "${3}"/usr/lib/python*/site-packages/portage/package/ebuild/prepare_build_dirs.py
    sed -i 's/0700/0755/' "${3}"/usr/share/portage/config/make.globals
  fi
  _log i "Mounting tmpfs for '${1}' ..."
  if [[ $(findmnt -T "${4}" -o SOURCE -P | cut -d'"' -f2) != "tmpfs" ]]; then
    mkdir -p "${4}"
    mount -t tmpfs tmpfs "${4}"
    _log i "Tmpfs has been mounted at '${4}'."
  else
    _log i "Tmpfs exists, reuse it ..."
  fi
}

function _humanize_cmd() {
  echo -n "$(sed -E 's/\s+\-/ \\\n-/g' <<<${*})"
}

LOGLEVEL=1
case ${RUNNINGMODE} in
  M)
    _log n "Enter maintenance mode ..."
    _log n "[BASE SNAPSHOT] '${FSBASEPATH}'"
    BWRAPCMD_EACH="${BWRAPCMD_U/EACHBASEPATH/${FSBASEPATH}}"
    BWRAPCMD_EACH="$(_humanize_cmd ${BWRAPCMD_EACH})"
    BWRAPCMD_EACH="${BWRAPCMD_EACH/--bind[[:space:]]\'TMPFSPATH\'/--tmpfs}"
    echo "RUN: ${BWRAPCMD_EACH} /bin/bash --login"
    _log n "Don't forget to execute: chmod 1777 /dev/shm"
    eval "${BWRAPCMD_EACH} /bin/bash --login" || true
    _log n "Leave maintenance mode ..."
    ;;
  I)
    #interactive mode
    _log n "ID: ${CURRENTID}"
    EACHWORKPATH="${WORKPATH}"/INTERACTIVE
    EACHBASEPATH="${EACHWORKPATH}"/SNAPSHOT
    EACHTMPPATH="${EACHWORKPATH}"/TMPFS
    if [[ ${PRINTCMD} == 0 ]]; then
      _prepare_env 'INTERACTIVE' "${FSBASEPATH}" "${EACHBASEPATH}" "${EACHTMPPATH}"
    fi
    _print_config
    echo
    BWRAPCMD_EACH="${BWRAPCMD_U/EACHBASEPATH/${EACHBASEPATH}}"
    if [[ ${PRINTCMD} == 1 ]]; then
      echo "CMD: $(_humanize_cmd ${BWRAPCMD_EACH/TMPFSPATH/${EACHTMPPATH}}) /bin/bash --login"
      echo
    else
      eval "${BWRAPCMD_EACH/TMPFSPATH/${EACHTMPPATH}} /bin/bash --login"
    fi
    ;;
  P)
    #parallel mode
    exec {FD_EXIT}> >(_exit_parallel)
    exec {FD_STATUS}> >(_show_status)
    exec {FD_JOBS_STORE}> >(_store_jobs)
    echo "A WAITING" >&${FD_STATUS}

    declare -i JOB=0
    for atom in "${ATOMS[@]}"; do
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
      patom=${patom//[[:space:]]/@@}
      EACHWORKPATH="${WORKPATH}"/"${patom}"
      EACHBASEPATH="${EACHWORKPATH}"/SNAPSHOT
      EACHTMPPATH="${EACHWORKPATH}"/TMPFS
      EACHLOGPATH="${EACHWORKPATH}"/LOG
      EACHCMDPATH="${EACHWORKPATH}"/CMD
      _prepare_env "${atom}" "${FSBASEPATH}" "${EACHBASEPATH}" "${EACHTMPPATH}"
      _log i "Testing '${atom}' ..."
      _test "${EACHBASEPATH}" "${EACHTMPPATH}" "${atom}" "${EACHLOGPATH}" "${EACHCMDPATH}" "${JOB}" &
      echo "${JOB} RUNNING${!} ${EACHLOGPATH}" >&${FD_STATUS}
      echo "+" >&${FD_JOBS_STORE}
      JOB+=1
      BWRAPCMD_EACH="${BWRAPCMD_U/EACHBASEPATH/${EACHBASEPATH}}"
      BWRAPCMD_EACH="${BWRAPCMD_EACH/TMPFSPATH/${EACHTMPPATH}}"
      echo "$(_humanize_cmd ${BWRAPCMD_EACH}) /bin/bash --login" >>"${EACHCMDPATH}"
      echo "run"
      _log n "  tail -f '${EACHLOGPATH}'"
      echo "to see the log, and can run command in the following file"
      _log n "  ${EACHCMDPATH}"
      echo "to enter the test environment interactively."
      echo
    done
    wait
    ;;
esac
