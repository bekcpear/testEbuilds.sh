# @bekcpear

# @VARIABLE: LOGLEVEL
# #DEFAULT: 2
# @DESCRIPTION:
# Used to control output level of messages. Should only be setted
# by shell itself.
# 0 -> DEBUG; 1 -> INFO; 2 -> NORMAL; 3 -> WARNNING; 4 -> ERROR
LOGLEVEL=2

# @VARIABLE: FD_STD_OUT
# #DEFAULT: 1
# @DESCRIPTION:
# The STDOUT file descriptor
FD_STD_OUT=1

# @VARIABLE: FD_STD_OUT
# #DEFAULT: 2
# @DESCRIPTION:
# The STDERR file descriptor
FD_STD_ERR=2

# @FUNCTION: _log
# @USAGE: <[dinwe]> <message>
# @INTERNAL
# @DESCRIPTION:
# Echo messages with a unified format.
#  'd' means showing in    DEBUG level;
#  'i' means showing in     INFO level;
#  'n' means showing in   NORMAL level;
#  'w' means showing in WARNNING level;
#  'e' means showing in    ERROR level;
# Msg will be printed to the standard output normally
# when this function is called without any option.
function _log() {
  local color='\e[0m'
  local reset='\e[0m'
  local ofd="&${FD_STD_OUT}"
  local -i lv=2
  if [[ ! ${1} =~ ^[dinwe]+$ ]]; then
    echo "UNRECOGNIZED OPTIONS OF INTERNAL <_log> FUNCTION!" >&2
    exit 1
  fi
  case ${1} in
    *e*)
      lv=4
      color='\e[31m'
      ofd="&${FD_STD_ERR}"
      ;;
    *w*)
      lv=3
      color='\e[33m'
      ofd="&${FD_STD_ERR}"
      ;;
    *n*)
      lv=2
      color='\e[36m'
      ;;
    *i*)
      lv=1
      ;;
    *d*)
      lv=0
      ;;
  esac
  if [[ ${lv} -ge ${LOGLEVEL} ]]; then
    shift
    local prefix=""
    local msg="${@}"
    if [[ ${lv} != 2 ]]; then
      prefix="[$(date '+%Y-%m-%d %H:%M:%S')] " || true
    fi
    eval ">${ofd} echo -e '${color}${prefix}${msg//\'/\'\\\'\'}${reset}'"
  fi
}

# @FUNCTION: _fatal
# @USAGE: <exit-code> <message>
# @INTERNAL
# @DESCRIPTION:
# Print an error message and exit shell.
function _fatal() {
  if [[ ${1} =~ ^[[:digit:]]+$ ]]; then
    local exit_code=${1}
    shift
  else
    local exit_code=1
  fi
  _log e "${@}"
  exit ${exit_code}
}
