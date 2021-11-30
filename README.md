# mysql

[![Deploy To Azure](https://raw.githubusercontent.com/Azure/azure-quickstart-templates/master/1-CONTRIBUTION-GUIDE/images/deploytoazure.svg?sanitize=true)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fshashwatchandra%2Fmysql%2Fmain%2Fmysql-resources.json){:target="_blank" rel="noopener"}

Mysql Cluster deployment.

These set of ARM template deploy a cluster of Mysql Servers, including a source server, a replica to act as a backup and at lease one replica.
The script can be modify to launch more than one read-only replica is needed.
The solution comes bundle with an OpenArk/Orchestrator to allow the operatator to modify the role of the mysql servers (Source, Replica) to aid in a manual failover.

The scripts lack the use of a front side load balancer to allow a unique entry point to the overall service.
