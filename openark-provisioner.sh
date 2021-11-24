#!/usr/bin/env bash

set -Eeuo pipefail
trap cleanup SIGINT SIGTERM ERR EXIT

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)

usage() {
  cat << EOF # remove the space between << and EOF, this is due to web plugin issue
Usage: $(basename "${BASH_SOURCE[0]}") [-h] [-v] [-f] -p param_value arg1 [arg2...]

Script description here.

Available options:

-h, --help                 Print this help and exit
-v, --verbose              Print script debug info
    --discover-username    Username for OpenArk orchestrator autodiscover. 
    --discover-password    Password for OpenArk orchestrator autodiscover.
    --orch-password	   UI Password for admin user
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
  while :; do
    case "${1-}" in
    -h | --help) usage ;;
    -v | --verbose) set -x ;;
    --no-color) NO_COLOR=1 ;;
    --discover-username) # Password for orchestration discovery
      discover_username="${2-}"
      shift
      ;;
    --discover-password) # Password for orchestration discovery
      discover_password="${2-}"
      shift
      ;;
    --orch-password) # Password for orchestration discovery
      orch_password="${2-}"
      shift
      ;;

    -?*) die "Unknown option: $1" ;;
    *) break ;;
    esac
    shift
  done

  args=("$@")

  return 0
}

parse_params "$@"
setup_colors

my_ip=$(ip addr show eth0 | grep "inet\b" | awk '{print $2}' | cut -d/ -f1)

# script logic here

exec_or_dry() {
    [[ $dry_run == 0 ]] && $@ || echo "- $@"
}

restart_orchestrator() {
    msg "Restarting orchestrator server"
    systemctl restart orchestrator
}


deploy_orchestrator() {
    msg "Deploying orchestrator"
    apt-get update
    wget https://github.com/openark/orchestrator/releases/download/v3.2.6/orchestrator-client-sysv-3.2.6_amd64.deb
    wget https://github.com/openark/orchestrator/releases/download/v3.2.6/orchestrator-cli_3.2.6_amd64.deb
    wget https://github.com/openark/orchestrator/releases/download/v3.2.6/orchestrator-sysv-3.2.6_amd64.deb
    apt install -f ./orchestrator-client-sysv-3.2.6_amd64.deb -y
    apt install -f ./orchestrator-cli_3.2.6_amd64.deb -y
    apt install -f ./orchestrator-sysv-3.2.6_amd64.deb -y
    mkdir -p /var/lib/orchestrator
    systemctl enable orchestrator
}

deploy_orchestrator_topology_config() {
	cat << END_HEREDOC > /etc/orchestrator-topology.cnf
[client]
user=${discover_username}
password=${discover_password}
END_HEREDOC
}

deploy_orchestrator_config() {
	cat << END_HEREDOC > /etc/orchestrator.conf.json
{
  "Debug": true,
  "EnableSyslog": false,
  "ListenAddress": ":3000",
  "BackendDB": "sqlite",
  "SQLITE3DataFile": "/var/lib/orchestrator/orchestrator.db",
  "MySQLTopologyCredentialsConfigFile": "/etc/orchestrator-topology.cnf",
  "DefaultInstancePort": 3306,
  "DiscoverByShowSlaveHosts": true,
  "InstancePollSeconds": 5,
  "DiscoveryIgnoreReplicaHostnameFilters": [
    "a_host_i_want_to_ignore[.]example[.]com",
    ".*[.]ignore_all_hosts_from_this_domain[.]example[.]com",
    "a_host_with_extra_port_i_want_to_ignore[.]example[.]com:3307"
  ],
  "UnseenInstanceForgetHours": 240,
  "SnapshotTopologiesIntervalHours": 0,
  "InstanceBulkOperationsWaitTimeoutSeconds": 10,
  "HostnameResolveMethod": "default",
  "MySQLHostnameResolveMethod": "@@hostname",
  "SkipBinlogServerUnresolveCheck": true,
  "ExpiryHostnameResolvesMinutes": 60,
  "RejectHostnameResolvePattern": "",
  "ReasonableReplicationLagSeconds": 10,
  "ProblemIgnoreHostnameFilters": [],
  "VerifyReplicationFilters": false,
  "ReasonableMaintenanceReplicationLagSeconds": 20,
  "CandidateInstanceExpireMinutes": 60,
  "AuditLogFile": "",
  "AuditToSyslog": false,
  "RemoveTextFromHostnameDisplay": ".mydomain.com:3306",
  "ReadOnly": false,
  "AuthenticationMethod": "basic",
  "HTTPAuthUser": "admin",
  "HTTPAuthPassword": "${orch_password}",
  "AuthUserHeader": "",
  "PowerAuthUsers": [
    "*"
  ],
  "ClusterNameToAlias": {
    "127.0.0.1": "test suite"
  },
  "ReplicationLagQuery": "select absolute_lag from meta.heartbeat_view",
  "DetectClusterAliasQuery": "select ifnull(max(cluster_name), '') as cluster_alias from meta.cluster where anchor=1",
  "DetectClusterDomainQuery": "select ifnull(max(cluster_domain), '') as cluster_domain from meta.cluster where anchor=1",
  "DetectInstanceAliasQuery": "",
  "DetectDataCenterQuery": "select substring_index(substring_index(@@hostname, '-',3), '-', -1) as dc",
  "DetectPromotionRuleQuery": "",
  "DataCenterPattern": "",
  "PhysicalEnvironmentPattern": "",
  "PromotionIgnoreHostnameFilters": [],
  "DetectSemiSyncEnforcedQuery": "",
  "ServeAgentsHttp": false,
  "AgentsServerPort": ":3001",
  "AgentsUseSSL": false,
  "AgentsUseMutualTLS": false,
  "AgentSSLSkipVerify": false,
  "AgentSSLPrivateKeyFile": "",
  "AgentSSLCertFile": "",
  "AgentSSLCAFile": "",
  "AgentSSLValidOUs": [],
  "UseSSL": false,
  "UseMutualTLS": false,
  "SSLSkipVerify": false,
  "SSLPrivateKeyFile": "",
  "SSLCertFile": "",
  "SSLCAFile": "",
  "SSLValidOUs": [],
  "URLPrefix": "",
  "StatusEndpoint": "/api/status",
  "StatusSimpleHealth": true,
  "StatusOUVerify": false,
  "AgentPollMinutes": 60,
  "UnseenAgentForgetHours": 6,
  "StaleSeedFailMinutes": 60,
  "SeedAcceptableBytesDiff": 8192,
  "PseudoGTIDPattern": "",
  "PseudoGTIDPatternIsFixedSubstring": false,
  "PseudoGTIDMonotonicHint": "asc:",
  "DetectPseudoGTIDQuery": "",
  "BinlogEventsChunkSize": 10000,
  "SkipBinlogEventsContaining": [],
  "ReduceReplicationAnalysisCount": true,
  "FailureDetectionPeriodBlockMinutes": 60,
  "FailMasterPromotionOnLagMinutes": 0,
  "RecoveryPeriodBlockSeconds": 3600,
  "RecoveryIgnoreHostnameFilters": [],
  "RecoverMasterClusterFilters": [
    "_master_pattern_"
  ],
  "RecoverIntermediateMasterClusterFilters": [
    "_intermediate_master_pattern_"
  ],
  "OnFailureDetectionProcesses": [
    "echo 'Detected {failureType} on {failureCluster}. Affected replicas: {countSlaves}' >> /tmp/recovery.log"
  ],
  "PreGracefulTakeoverProcesses": [
    "echo 'Planned takeover about to take place on {failureCluster}. Master will switch to read_only' >> /tmp/recovery.log"
  ],
  "PreFailoverProcesses": [
    "echo 'Will recover from {failureType} on {failureCluster}' >> /tmp/recovery.log"
  ],
  "PostFailoverProcesses": [
    "echo '(for all types) Recovered from {failureType} on {failureCluster}. Failed: {failedHost}:{failedPort}; Successor: {successorHost}:{successorPort}' >> /tmp/recovery.log"
  ],
  "PostUnsuccessfulFailoverProcesses": [],
  "PostMasterFailoverProcesses": [
    "echo 'Recovered from {failureType} on {failureCluster}. Failed: {failedHost}:{failedPort}; Promoted: {successorHost}:{successorPort}' >> /tmp/recovery.log"
  ],
  "PostIntermediateMasterFailoverProcesses": [
    "echo 'Recovered from {failureType} on {failureCluster}. Failed: {failedHost}:{failedPort}; Successor: {successorHost}:{successorPort}' >> /tmp/recovery.log"
  ],
  "PostGracefulTakeoverProcesses": [
    "echo 'Planned takeover complete' >> /tmp/recovery.log"
  ],
  "CoMasterRecoveryMustPromoteOtherCoMaster": true,
  "DetachLostSlavesAfterMasterFailover": true,
  "ApplyMySQLPromotionAfterMasterFailover": true,
  "PreventCrossDataCenterMasterFailover": false,
  "PreventCrossRegionMasterFailover": false,
  "MasterFailoverDetachReplicaMasterHost": false,
  "MasterFailoverLostInstancesDowntimeMinutes": 0,
  "PostponeReplicaRecoveryOnLagMinutes": 0,
  "OSCIgnoreHostnameFilters": [],
  "GraphiteAddr": "",
  "GraphitePath": "",
  "GraphiteConvertHostnameDotsToUnderscores": true,
  "ConsulAddress": "",
  "ConsulAclToken": "",
  "ConsulKVStoreProvider": "consul"
}
END_HEREDOC

}

msg "Deploying"
deploy_orchestrator
deploy_orchestrator_topology_config
deploy_orchestrator_config
restart_orchestrator
