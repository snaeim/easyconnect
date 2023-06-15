#!/bin/bash
set -eo pipefail

########## Check requirement ################################################################################

# exit if has no root acess
[[ "${EUID:-$(id -u)}" -eq 0 ]] || { echo >&2 "script must be run as root."; exit 1; }

# exit if openconnect is not installed
command -v openconnect > /dev/null 2>&1 || { echo >&2 "OpenConnect is not installed."; exit 1; }

########## Variables ########################################################################################

IFNAME="tun0"
LOG_TIMEZONE="Asia/Tehran"
SCRIPT_NAME="$(basename $0)"
LOG_FILE="/var/log/${SCRIPT_NAME}.log"
PID_FILE="/run/openconnect_${IFNAME}.pid"

########## Functions ########################################################################################

function parse_arguments() {
  # define short and long options
  local SHORTOPT=s:u:p:f:en:d
  local LONGOPT=server:,username:,password:,file:,enable,restart-network,line:,disable,force
  # validate arguments
  local VALID_ARGS=$(getopt -o ${SHORTOPT} --long ${LONGOPT} -n "$SCRIPT_NAME" -- "$0" "$@")
  [[ $? -eq 0 ]] || exit 1
  # evaluates the string $VALID_ARGS, which contains the arguments, as shell code
  eval set -- "$VALID_ARGS"
  # loop on arguments
  while [ : ]; do
    case "$1" in
      -s | --server)
        VPN_SERVER="$2"
        shift 2
        ;;
      -u | --username)
        VPN_USER="$2"
        shift 2
        ;;
      -p | --password)
        VPN_PWD="$2"
        shift 2
        ;;
      -f | --file)
        VPN_FILE="$2"
        shift 2
        ;;
      -e | --enable)
        ENABLE_KEEPALIVE=true
        shift
        ;;
      --restart-network)
        RESTART_NETWORK=true
        shift
        ;;
      -n | --line)
        LOG_LINE="$2"
        shift 2
        ;;
      -d | --disable)
        DISABLE_KEEPALIVE=true
        shift
        ;;
      --force)
        REPLACE_KEEPALIVE=true
        shift
        ;;
      --)
        shift
        break
        ;;
    esac
  done
}

# remove all default routes, then restart network system to restore default route
function restart_network {
  while true; do { ip route del default > /dev/null 2>&1; [[ $? == 0 ]] || break; }; done; sleep 1;
  systemctl restart systemd-networkd || { echo "Restarting the network service failed."; return 1; }
  echo "The network service was restarted."; sleep 1;
  return 0
}

# read VPN_FILE if exist then set VPN_SERVER, VPN_USER, VPN_PASS variables
function read_vpn_file {
  [[ -f $VPN_FILE ]] || { echo "File does not exist."; return 1; }
  VPN_SERVER=$(grep -i "^server=" $VPN_FILE | cut -d '=' -f2-)
  VPN_USER=$(grep -i "^username=" $VPN_FILE | cut -d '=' -f2-)
  VPN_PWD=$(grep -i "^password=" $VPN_FILE | cut -d '=' -f2-)
}

# check for requirement to connect to vpn server, VPN_SERVER, VPN_USER and VPN_PWD is stored properly
function validate_user_input {
  [[ -n $VPN_SERVER && -n $VPN_USER && -n $VPN_PWD ]] && return 0
  echo "Required informaion is missing."
  return 1
}

# split VPN_SERVER by ':' and store VPN_DOMAIN and VPN_PORT
function split_domain_port {
  # remove http:// or https:// from server address if exist then split vpn domain and port
  IFS=: read -r VPN_DOMAIN VPN_PORT <<< $(echo "$VPN_SERVER" | sed -E 's/^\s*.*:\/\///g')
  # if vpn domain is not define return with error code
  [[ -n $VPN_DOMAIN ]] || { echo "VPN domain is not defined."; return 1; }
  # default port is 443 if is not defined by user
  [[ -n $VPN_PORT ]] || VPN_PORT=443
  return 0
}

# resolve domain name stored in $VPN_DOMAIN into ip address
# after call this function ip will be store in $VPN_ADDR
# to make sure we get ip address check it from multiple dns server
function resolve_vpn_domain {
  local -ar DNS_LIST=("8.8.8.8" "1.1.1.1" "46.224.1.43" "194.225.62.80")
  for DNS in ${DNS_LIST[@]}; do
    VPN_ADDR="$(dig +time=3 +short $VPN_DOMAIN @$DNS | grep -E -o '([0-9]{1,3}[\.]){3}[0-9]{1,3}' | head -n 1)"
    [[ $VPN_ADDR =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && return 0
  done
  echo "Can not resolve vpn ip address."
  return 1
}

# get ip address from ip api and store in $PUBLIC_IP
# to make sure we get ip address check it from multiple ip apis
function get_public_ip {
  local -ar IP_APIS=("http://ip-api.com/line?fields=query" "http://icanhazip.com" "http://ident.me" "http://checkip.amazonaws.com")
  for API in ${IP_APIS[@]}; do
    PUBLIC_IP="$(curl -m 3 -s $API)"
    [[ $PUBLIC_IP =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && return 0
  done
  return 1
}

# looking for vpn domain record in hosts file to update vpn server ip address or create record if not exist    
function update_host_file {
  local HOST_RECORD=$(grep -i "$VPN_DOMAIN" /etc/hosts)
  [[ -n $HOST_RECORD ]] && sed -i "s/$HOST_RECORD/$VPN_ADDR $VPN_DOMAIN/g" /etc/hosts || echo "$VPN_ADDR $VPN_DOMAIN" >> /etc/hosts
}

# make request to connect to vpn server using OpenConnect
function openconnect_connect {
  echo "$VPN_PWD" | sudo openconnect -b -q --passwd-on-stdin --pid-file=$PID_FILE -i $IFNAME -u $VPN_USER https://$VPN_DOMAIN:$VPN_PORT
  OPENCONNECT_EXIT_CODE=$?
  return $OPENCONNECT_EXIT_CODE
}

# checking for PID_FILE if exist return PID stored in to file
function get_openconnect_pid {
  OPENCONNECT_PID=""
  if [[ -f $PID_FILE ]]; then
    OPENCONNECT_PID=$(cat $PID_FILE)
    return 0
  fi
  return 1
}

# cheking for running OpenConnect and kill the process
function terminate_openconnect {
  if get_openconnect_pid; then
    kill -9 $OPENCONNECT_PID && rm $PID_FILE
    echo "OpenConnect process is terminated."; sleep 1;
    return 0
  fi
  echo "OpenConnect is not running."
  return 1
}

# get the time in second and print the time in human readable format
function seconds_to_human_readable() {
  local -i T=$1
  local -i D=$((T/60/60/24))
  local -i H=$((T/60/60%24))
  local -i M=$((T/60%60))
  local -i S=$((T%60))
  if [[ $D -gt 0 ]]; then
    [[ $D -eq 1 ]] && printf "%d day" "$D"
    [[ $D -gt 1 ]] && printf "%d days" "$D"
    [[ $H -eq 1 ]] && printf " and %d hour" "$H"
    [[ $H -gt 1 ]] && printf " and %d hours" "$H"
  elif [[ $H -gt 0 ]]; then
    [[ $H -eq 1 ]] && printf "%d hour" "$H"
    [[ $H -gt 1 ]] && printf "%d hours" "$H"
    [[ $M -eq 1 ]] && printf " and %d minute" "$M"
    [[ $M -gt 1 ]] && printf " and %d minutes" "$M"
  elif [[ $M -gt 0 ]]; then
    [[ $M -eq 1 ]] && printf "%d minute" "$M"
    [[ $M -gt 1 ]] && printf "%d minutes" "$M"
    [[ $S -eq 1 ]] && printf " and %d second" "$S"
    [[ $S -gt 1 ]] && printf " and %d seconds" "$S"
  else
    [[ $S -eq 1 ]] && printf "%d second" "$S"
    [[ $S -gt 1 ]] && printf "%d seconds" "$S"
  fi
}

# get vpn server from crontab record if exixt; then store as array in $VPN_INFO
function has_keepalive {
  local CRONJOB="$(crontab -l | grep -i $SCRIPT_NAME)"
  [[ -n $CRONJOB ]] || return 1
  IFS=' ' read -a VPN_INFO <<< $(echo $CRONJOB | awk -F' connect ' '{print $2}')
  return 0
}

# remove any easyconnect cronjob exist
function remove_keepalive {
  crontab -l | grep -i -v "$SCRIPT_NAME" | crontab -
  return 0
}

# generate a cronjob record call every minute, require vpn server info, call function like blow
# create_keepalive "-f /path/to/vpn/info"
# create_keepalive "-s vpn.example.com:443 -u username -p password"
function create_keepalive {
  [[ -n ${1} ]] || { echo "Pass server info to function."; return 1; }
  (crontab -l; echo "* * * * * sudo ${SCRIPT_NAME} keepalive connect ${1}") | crontab -
  return 0
}

# check internet connection with multiple website
function has_internet_connection {
  local -ar DOMAINS=("google.com" "bing.com" "yahoo.com" "wikipedia.org")
  for DOMAIN in ${DOMAINS[@]}; do
    nc -zw3 $DOMAIN 443 > /dev/null 2>&1 && return 0
  done
  return 1
}

# store any parameters passed to function with date
function log() {
  echo "$(TZ=$LOG_TIMEZONE date "+%Y-%m-%d %H:%M:%S")    $1" >> $LOG_FILE
}

function main_usage {
  echo -e "Usage:  $SCRIPT_NAME connect [-e] [-s vpn.example.com:443 -u username -p password] [-f /path/to/vpn/info]"
  echo -e "        $SCRIPT_NAME disconnect [-d]"
  echo -e "        $SCRIPT_NAME status"
  echo -e "        $SCRIPT_NAME keepalive [SUBCOMMAND]"
  echo -e "        $SCRIPT_NAME help"
}

function keepalive_usage {
  echo -e "Usage:  $SCRIPT_NAME keepalive enable [-s vpn.example.com:443 -u username -p password] [-f /path/to/vpn/info]"
  echo -e "        $SCRIPT_NAME keepalive disable"
  echo -e "        $SCRIPT_NAME keepalive status"
  echo -e "        $SCRIPT_NAME keepalive log [-n 10]"
}

function easyconnect_help {
  echo -e "Manage and automate AnyConnect VPN client."
  echo -e "Usage: $SCRIPT_NAME [COMMAND] [OPTIONS]\n"
  echo -e "Available comamnds and options\n"
  echo -e "connect                 Connect to a VPN server; provide VPN server information using falgs or a file"
  echo -e "    -e, --enable        Enable auto-connection for VPN connections"
  echo -e "    -s, --server        Server address and port, separated by a colon"
  echo -e "    -u, --username      VPN client username"
  echo -e "    -p, --password      VPN client password"
  echo -e "    -f, --file          The key=value file contains the server, username, password each on a separate line"
  echo -e "    --restart-network   Restart the network service before trying to connect to the VPN server\n"
  echo -e "disconnect              Disconnect VPN connection"
  echo -e "    -d, --disable       Disable auto-connection if it is set up\n"
  echo -e "status                  Show the status of the VPN connection\n"
  echo -e "keepalive [SUBCOMMAND]  Automate AnyConnect VPN client to be reconnect on connection interrupt"
  echo -e "  enable                Enable auto-connection; provide VPN server information using falgs or a file"
  echo -e "    -s, --server        Server address and port, separated by a colon"
  echo -e "    -u, --username      VPN client username"
  echo -e "    -p, --password      VPN client password"
  echo -e "    -f, --file          The key=value file contains the server, username, password each on a separate line"
  echo -e "    --force             Force to replace with existing auto-connection"
  echo -e "  disable               Disable auto-connection"
  echo -e "  status                Verify that auto-connection is configured"
  echo -e "  log                   Show the logs and errors for the auto-connection retry."
  echo -e "    -n, --line          Define the number of last lines you want to see, by default it's 10\n"
  echo -e "help                    Show script usage and documentation\n"
  echo -e "This script uses OpenConnect for connecting to a VPN server and Crontab for keeping the connection alive."
}

########## Main #############################################################################################

MAIN_COMMAND=$1; shift;
case $MAIN_COMMAND in

  connect)
    parse_arguments "${@}"
    # restart network service by user request
    if [[ $RESTART_NETWORK == true ]]; then
      get_openconnect_pid && terminate_openconnect
      restart_network || exit 1
    fi
    # trying to get vpn info from file if is defined by user 
    [[ -n $VPN_FILE ]] && ! read_vpn_file && exit 1
    # checking to have reqiured information for connect to vpn server
    validate_user_input || exit 1
    # split VPN_SERVER by ":" to get VPN domain and port
    split_domain_port || exit 1
    # trying to get vpn server ip address
    resolve_vpn_domain || exit 1
    # if user requsted to make keepalive connection for this server
    if [[ $ENABLE_KEEPALIVE == true ]]; then
      # remove any other cronjob if exists
      has_keepalive && remove_keepalive
      [[ -n $VPN_FILE ]] && create_keepalive "-f $VPN_FILE" || create_keepalive "-s $VPN_SERVER -u $VPN_USER -p $VPN_PWD"
      echo "Auto-connection was set up."
    fi
    # checking for if already connected to vpn server exit with error
    get_openconnect_pid && get_public_ip && [[ $PUBLIC_IP == $VPN_ADDR ]] && { echo "Already connected to: $PUBLIC_IP."; exit 1; }
    # if already have OpenConnect process but its not this server we want to
    get_openconnect_pid && terminate_openconnect && ! restart_network && exit 1
    # to prevent openconnect "failure in name resolution" error
    # before trying to connect vpn, should resolve vpn ip then add record to /etc/hosts with vpn server info
    update_host_file
    # make request for connect to vpn server
    openconnect_connect
    ;;

  status)
    # checking for OpenConnect process is running
    if get_openconnect_pid; then
      # get openconnect run time and parse for show to user
      OPENCONNECT_UPTIME_SEC=$(ps -p $OPENCONNECT_PID -o etimes=)
      OPENCONNECT_UPTIME=$(seconds_to_human_readable "$OPENCONNECT_UPTIME_SEC")
      echo "OpenConnect has been connected for $OPENCONNECT_UPTIME."
    else
      echo "OpenConnect is not running."
    fi
    ;;

  disconnect)
    parse_arguments "${@}"
    # kill openconnect process and restart network to get back default route
    terminate_openconnect && restart_network
    # remove the keepalive cronjob if requested by user
    if [[ $DISABLE_KEEPALIVE == true ]]; then
      has_keepalive && remove_keepalive && echo "Auto-connection was removed." || echo "Auto-connection does not exist."
    fi
    ;;

  keepalive)
    KEEPALIVE_ACTION=$1; shift;
    case $KEEPALIVE_ACTION in
      connect)
        parse_arguments "${@}"
        # check for internet connection and restart network service if we haven't
        if ! has_internet_connection; then
          get_openconnect_pid && { terminate_openconnect > /dev/null; log "terminate openconnect process"; }
          restart_network > /dev/null && log "restart network" || { log "restart network failed"; exit 1; }
        fi
        [[ -n $VPN_FILE ]] && ! read_vpn_file > /dev/null && { log "getting info from file failed"; exit 1; }
        validate_user_input > /dev/null || { log "validate user input failed"; exit 1; }
        split_domain_port > /dev/null || { log "get domain and port failed"; exit 1; }
        resolve_vpn_domain > /dev/null || { log "resolve vpn ip address failed"; exit 1; }
        get_openconnect_pid && get_public_ip && [[ $PUBLIC_IP == $VPN_ADDR ]] && exit 0
        if get_openconnect_pid; then
          terminate_openconnect > /dev/null && log "terminate openconnect process"
          restart_network > /dev/null && log "restart network" || { log "restart network failed"; exit 1; }
        fi
        update_host_file
        openconnect_connect
        log "openconnect exit code = $OPENCONNECT_EXIT_CODE"
        # waiting for establish vpn connection
        sleep 10;
        get_public_ip && log "Connected to: $PUBLIC_IP" || log "Failed to get ip address"
        ;;
    	enable)
        parse_arguments "${@}"
        # check for not having keepalive cronjob or user request to replace it
        ! has_keepalive || [[ $REPLACE_KEEPALIVE == true ]] || { echo "Auto-connection already exist."; exit 1; };
        [[ -n $VPN_FILE ]] && read_vpn_file
        validate_user_input || exit 1
        split_domain_port || exit 1
        resolve_vpn_domain || exit 1
        # remove if we have existed cronjob to prevent conflicts
        has_keepalive && remove_keepalive
        [[ -n $VPN_FILE ]] && create_keepalive "-f $VPN_FILE" || create_keepalive "-s $VPN_SERVER -u $VPN_USER -p $VPN_PWD"
        echo "Auto-connection was set up."
        ;;
      status)
        has_keepalive || { echo "Auto-connection was not set up."; exit 0;}
        # parse vpn info into variables
        parse_arguments "${VPN_INFO[@]}"
        [[ -n $VPN_FILE ]] && KEEPALIVE_FOR=$VPN_FILE || KEEPALIVE_FOR=$(echo "$VPN_SERVER" | awk -F':' '{print $1}')
        echo "For $KEEPALIVE_FOR, an automatic connection was set up."
        ;;
      disable)
        has_keepalive && remove_keepalive && echo "Auto-connection was removed." || echo "Auto-connection does not exist."
        ;;
      log)
        parse_arguments "${@}"
        # create log file if not exist
        [[ -f $LOG_FILE ]] || touch $LOG_FILE
        # define line if not defined
        [[ -n $LOG_LINE ]] || LOG_LINE=10
        tail -n $LOG_LINE $LOG_FILE
        ;;
      *)
        keepalive_usage
        ;;
    esac
    ;;

  help | --help | -h)
    easyconnect_help
    ;;

  *)
    main_usage
    ;;

esac