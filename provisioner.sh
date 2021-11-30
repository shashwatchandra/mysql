#!/usr/bin/env bash
# sudo ./provisioner.sh --role replica -i 2 --orch-ipaddress 172.16.1.9 --source-ipaddress 172.16.1.8

##### HOW TO USE ######
#
# TO DEPLOY A SOURCE
# sudo ./provisioner.sh --role source -i 1 --orch-ipaddress 172.16.1.9
#
# TO DEPLOY A REPLICA
# sudo ./provisioner.sh --role replica -i 2 --orch-ipaddress 172.16.1.9 --source-ipaddress 172.16.1.8
#
# TO DEPLOY A RELAY
# sudo ./provisioner.sh --role replica -i 2 --orch-ipaddress 172.16.1.9 --source-ipaddress 172.16.1.8

set -Eeuo pipefail
trap cleanup SIGINT SIGTERM ERR EXIT

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)

usage() {
  cat << EOF # remove the space between << and EOF, this is due to web plugin issue
Usage: $(basename "${BASH_SOURCE[0]}") [-h] [-v] [-f] -p param_value arg1 [arg2...]

Script description here.

Available options:

-h, --help              Print this help and exit
-v, --verbose           Print script debug info
-r, --role              Role of the MySQL instance to be provisioned [source|replica|relay]. Default: source
    --repl-password     Password for replication. Required if role is replica or relay. Default: replpass 
    --orch-password     Password for OpenArk orchestrator autodiscover. Default: orchpass
-o, --orch-ipaddress    Orchestrator IP address. Required for orchestrator discover
-s, --source-ipaddress  IP address of the source. Required for replica and relay roles.
-i, --id                Server-Id for MySQL replication. 
EOF
  exit
}

cleanup() {
  trap - SIGINT SIGTERM ERR EXIT
  # script cleanup here
}

setup_colors() {
  if [[ -t 2 ]] && [[ -z "${NO_COLOR-}" ]] && [[ "${TERM-}" != "dumb" ]]; then
    NOFORMAT='\033[0m' RED='\033[0;31m' GREEN='\033[0;32m' ORANGE='\033[0;33m' BLUE='\033[0;34m' PURPLE='\033[0;35m' CYAN='\033[0;36m' YELLOW='\033[1;33m'
  else
    NOFORMAT='' RED='' GREEN='' ORANGE='' BLUE='' PURPLE='' CYAN='' YELLOW=''
  fi
}

msg() {
  echo >&2 -e "${1-}"
}

die() {
  local msg=$1
  local code=${2-1} # default exit status 1
  msg "$msg"
  exit "$code"
}

parse_params() {
  # default values of variables set from params
  role=source
  repl_password=replpass 
  orch_password=orchpass
  orch_ipaddress=""
  source_ipaddress=""

  while :; do
    case "${1-}" in
    -h | --help) usage ;;
    -v | --verbose) set -x ;;
    --no-color) NO_COLOR=1 ;;
    -r | --role) # Role of the Mysql instance
      role="${2-}"
      [[ ! "${role}" =~ ^(source|relay|replica)$ ]] && die "${role} is not a recognized role"
      shift
      ;;
    --repl-password) # Password for replication
      repl_password="${2-}"
      shift
      ;;
    --orch-password) # Password for orchestration discovery
      orch_password="${2-}"
      shift
      ;;
    -o | --orch-ipaddress) # Orchestrator address
      orch_ipaddress="${2-}"
      shift
      ;;
    --source-ipaddress) # Password for replication
      source_ipaddress="${2-}"
      [[ "${role}" == "source" && ! -z "${source_ipaddress}" ]] && die "${role} does not require a source_ipaddress"
      shift
      ;;
    -i | --id) # Password for replication
      id="${2-}"
      shift
      ;;
    -?*) die "Unknown option: $1" ;;
    *) break ;;
    esac
    shift
  done

  args=("$@")

  # check required params and arguments
  [[ "${role}" != "source" && ! "${source_ipaddress}" ]] && die "Non-source roles require source_ipaddress"  
  [[ "${orch_ipaddress}" == "" ]] && die "Orchestrator ip address cannot be empty"
  [[ ! ${id+"1"} ]] && die "Id cannot be empty"
  
  return 0
}

parse_params "$@"
setup_colors

my_ip=$(ip addr show eth0 | grep "inet\b" | awk '{print $2}' | cut -d/ -f1)

# script logic here

msg "${RED}Parameters:${NOFORMAT}"
msg "- role: ${role}"
msg "- source_ipaddress: \"${source_ipaddress}\""
msg "- orch_ipaddress: \"${orch_ipaddress}\""
msg "- my_ip: \"${my_ip}\""

exec_or_dry() {
    [[ $dry_run == 0 ]] && $@ || echo "- $@"
}

restart_mysql() {
    msg "Restarting mysql server"
    systemctl restart mysql
}

hosts_fix() {
    msg "Patching /etc/hosts"
    cat << END_HEREDOC >> /etc/hosts
$orch_ipaddress openark
END_HEREDOC

}

deploy_mysql_server() {
    msg "Deploying mysql server"
    apt-get update
    apt-get install mysql-server -y
}

configure_mysql_for_replication() {
    msg "Configuring mysql for replication"
    sed -i "s/^bind-address.*/bind-address = $my_ip/" /etc/mysql/mysql.conf.d/mysqld.cnf
    sed -i "s/^# server-id.*/server-id = $id/" /etc/mysql/mysql.conf.d/mysqld.cnf
}

configure_mysql_cnf_source_plugins() {
    msg "Configuring mysql source plugins"

    cat << END_HEREDOC >> /etc/mysql/mysql.conf.d/mysqld.cnf
plugin-load-add=semisync_source.so
rpl_semi_sync_source=1
END_HEREDOC
}

configure_mysql_cnf_replica_plugins(){
msg "Configuring mysql replica plugins"

    cat << END_HEREDOC >> /etc/mysql/mysql.conf.d/mysqld.cnf
plugin-load-add=semisync_replica.so
rpl_semi_sync_replica_enabled=1

END_HEREDOC
}

configure_mysql_cnf_relay_plugins(){
msg "Configuring mysql relay plugins"

    cat << END_HEREDOC >> /etc/mysql/mysql.conf.d/mysqld.cnf
plugin-load-add=semisync_replica.so
plugin-load-add=semisync_source.so
rpl_semi_sync_replica_enabled=1
rpl_semi_sync_source_enabled=1
log-replica-updates

END_HEREDOC
}


configure_mysql_cnf_ignores(){
    msg "Configuring mysql ignores"
    cat << END_HEREDOC >> /etc/mysql/mysql.conf.d/mysqld.cnf
binlog-ignore-db=test
binlog-ignore-db=information_schema

replicate-ignore-db=test
replicate-ignore-db=information_schema

END_HEREDOC

}

mysql_provision_users() {
    msg "Creating repl and orch users"
    mysql -uroot -e "create user 'repluser'@'%' identified by '$repl_password';"
    mysql -uroot -e "grant replication slave,replication client on *.* to 'repluser'@'%';"
    mysql -uroot -e "create user 'orchestrator'@'%' identified by '$orch_password';"
    mysql -uroot -e "grant super,process,replication slave,replication client,reload on *.* to 'orchestrator'@'%';"
    mysql -uroot -e "grant select on meta.* to 'orchestrator'@'%'";
    mysql -uroot -e "flush privileges;"
}

mysql_get_master_coordinates() {
    master_status=$(mysql -urepluser -p$repl_password --host ${source_ipaddress} -e "show master status" -s)
    binfile=$(echo ${master_status} | awk {'print $1'})
    location=$(echo ${master_status} | awk {'print $2'})
}

configure_mysql_replication_to_source() {
    mysql -uroot -e "CHANGE REPLICATION SOURCE TO SOURCE_HOST='$source_ipaddress',SOURCE_USER='repluser',SOURCE_PASSWORD='$repl_password',SOURCE_LOG_FILE='$binfile',SOURCE_LOG_POS=$location,SOURCE_SSL=1;"
    mysql -uroot -e "start replica"
}

deploy_source() {
    hosts_fix
    deploy_mysql_server 
    configure_mysql_for_replication
    configure_mysql_cnf_source_plugins
    configure_mysql_cnf_ignores
    restart_mysql 
    msg "Sleeping for 10 secs."
    sleep 10
    mysql_provision_users
}

deploy_replica(){
    hosts_fix
    deploy_mysql_server
    configure_mysql_for_replication
    configure_mysql_cnf_replica_plugins
    configure_mysql_cnf_ignores
    restart_mysql
    msg "Sleeping for 10 secs."
    sleep 10
    mysql_provision_users
    mysql_get_master_coordinates
    configure_mysql_replication_to_source
}

deploy_relay(){
    hosts_fix
    deploy_mysql_server
    configure_mysql_for_replication
    configure_mysql_cnf_relay_plugins
    configure_mysql_cnf_ignores
    restart_mysql
    msg "Sleeping for 10 secs."
    sleep 10
    mysql_provision_users
    mysql_get_master_coordinates
    configure_mysql_replication_to_source
}

msg "Deploying role: ${role}"
sleep 60
case "${role}" in 
    "source") 
        deploy_source
    ;;
    "replica")
        deploy_replica
    ;;
    "relay")
	deploy_relay
    ;;
esac
