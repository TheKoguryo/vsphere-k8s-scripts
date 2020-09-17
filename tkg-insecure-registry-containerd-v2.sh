#!/bin/bash
# This script is used to add an insecure registry
# to a vSphere with Kubernetes Tanzu Kubernetes 
# cluster. After adding the registry, it will restart
# the Docker daemon in every node.
#
# USAGE: tkg-insecure-registry.sh $name-cluster $namespace $url-registry-cert
# 
# Author: José Manzaneque (jmanzaneque@vmware.com)
# Dependencies: curl, jq, sshpass
curl --version
jq --version

SV_IP='10.213.208.46' #VIP for the Supervisor Cluster
VC_IP='pacific-vcsa.haas-401.pez.vmware.com' #URL for the vCenter
VC_ADMIN_USER='administrator@vsphere.local' #User for the Supervisor Cluster
VC_ADMIN_PASSWORD='VMware1!' #Password for the Supervisor Cluster user

TKG_CLUSTER_NAME=$1 # Name of the TKG cluster
TKG_CLUSTER_NAMESPACE=$2 # Namespace where the TKG cluster is deployed
# harbor v1 : https://harbor.domain.com/api/systeminfo/getcert
# harbor v2 : https://harbor.domain.com/api/v2.0/systeminfo/getcert
URL_REGISTRY_CERT=$3 # URL of the Registry to be added 
URL_REGISTRY_TRIM=$(echo "${URL_REGISTRY_CERT}" | sed 's~http[s]*://~~g' | sed 's/\/.*//' ) # Sanitize registry URL to remove http/https

# Logging function that will redirect to stderr with timestamp:
logerr() { echo "$(date) ERROR: $@" 1>&2; }
# Logging function that will redirect to stdout with timestamp
loginfo() { echo "$(date) INFO: $@" ;}

# Verify if required arguments are met

if [[ -z "$1" || -z "$2" || -z "$3" ]]
  then
    logerr "Invalid arguments. Exiting..."
    exit 2
fi

# Exit the script if the supervisor cluster is not up
if [ $(curl -m 15 -k -s -o /dev/null -w "%{http_code}" https://"${SV_IP}") -ne "200" ]; then
    logerr "Supervisor cluster not ready. Exiting..."
    exit 2
fi

# If the supervisor cluster is ready, get the token for TKG cluster
loginfo "Supervisor cluster is ready!"
loginfo "Getting TKC Kubernetes API token..."

# Get the TKG Kubernetes API token by login into the Supervisor Cluster
TKC_API=$(curl -XPOST -s -u "${VC_ADMIN_USER}":"${VC_ADMIN_PASSWORD}" https://"${SV_IP}":443/wcp/login -k -d '{"guest_cluster_name":"'"${TKG_CLUSTER_NAME}"'", "guest_cluster_namespace":"'"${TKG_CLUSTER_NAMESPACE}"'"}' -H "Content-Type: application/json" | jq -r '.guest_cluster_server')
TOKEN=$(curl -XPOST -s -u "${VC_ADMIN_USER}":"${VC_ADMIN_PASSWORD}" https://"${SV_IP}":443/wcp/login -k -d '{"guest_cluster_name":"'"${TKG_CLUSTER_NAME}"'", "guest_cluster_namespace":"'"${TKG_CLUSTER_NAMESPACE}"'"}' -H "Content-Type: application/json" | jq -r '.session_id')
# I'm sure there is a better way to store the JSON in two variables in a single pipe execution. But I can't be bothered to search on StackOverflow right now.

# Verify if the token is valid
if [ $(curl -k -s -o /dev/null -w "%{http_code}" https://"${TKC_API}":6443/ --header "Authorization: Bearer "${TOKEN}"") -ne "200" ]
then
      logerr "TKC Kubernetes API token is not valid. Exiting..."
      exit 2
else
      loginfo "TKC Kubernetes API token is valid!"
fi

#Get the list of nodes in the cluster
curl -XGET -k --fail -s https://"${TKC_API}":6443/api/v1/nodes --header 'Content-Type: application/json' --header "Authorization: Bearer "${TOKEN}"" >> /dev/null
if [ $? -eq 0 ] ;
then      
      loginfo "Getting the IPs of the nodes in the cluster..."
      curl -XGET -k --fail -s https://"${TKC_API}":6443/api/v1/nodes --header 'Content-Type: application/json' --header "Authorization: Bearer "${TOKEN}"" | jq -r '.items[].status.addresses[] | select(.type=="InternalIP").address' > ./ip-nodes-tkg
      loginfo "The nodes IPs are: "$(column ./ip-nodes-tkg | sed 's/\t/,/g')""
else
      logerr "There was an error processing the IPs of the nodes. Exiting..."
      exit 2
fi

#Get Supervisor Cluster token to get the TKC nodes SSH Password
loginfo "Getting Supervisor Cluster Kubernetes API token..."
SV_TOKEN=$(curl -XPOST -s --fail -u "${VC_ADMIN_USER}":"${VC_ADMIN_PASSWORD}" https://"${SV_IP}":443/wcp/login -k -H "Content-Type: application/json" | jq -r '.session_id')

# Verify if the Supervisor Cluster token is valid
# Health check in /api/v1 (Supervisor Cluster forbids accessing / directly (TKC cluster allows it))
if [ $(curl -k -s -o /dev/null -w "%{http_code}" https://"${SV_IP}":6443/api/v1 --header "Authorization: Bearer "${SV_TOKEN}"") -ne "200" ]
then
      logerr "Supervisor Cluster Kubernetes API token is not valid. Exiting..."
      exit 2
else
      loginfo "Supervisor Cluster Kubernetes API token is valid!"
fi

# Get the TKC nodes SSH private key from the Supervisor Cluster
curl -XGET -k --fail -s https://"${SV_IP}":6443/api/v1/namespaces/"${TKG_CLUSTER_NAMESPACE}"/secrets/"${TKG_CLUSTER_NAME}"-ssh --header 'Content-Type: application/json' --header "Authorization: Bearer "${SV_TOKEN}"" >> /dev/null 
if [ $? -eq 0 ] ;
then      
      loginfo "Getting the TKC nodes SSH private key from the supervisor cluster..."
      curl -XGET -k --fail -s https://"${SV_IP}":6443/api/v1/namespaces/"${TKG_CLUSTER_NAMESPACE}"/secrets/"${TKG_CLUSTER_NAME}"-ssh --header 'Content-Type: application/json' --header "Authorization: Bearer "${SV_TOKEN}"" | jq -r '.data."ssh-privatekey"' | base64 -d > ./tkc-ssh-privatekey
      #Set correct permissions for TKC SSH private key
      chmod 600 ./tkc-ssh-privatekey
      loginfo "TKC SSH private key retrieved successfully!"
else
      logerr "There was an error getting the TKC nodes SSH private key. Exiting..."
      exit 2
fi

# SSH to every node and verify if the registry does not exist in /etc/docker/daemon.json. If it does not exist, add it

while read -r IPS_NODES_READ;
do
loginfo "Adding registry to the node '"${IPS_NODES_READ}"'..."
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i ./tkc-ssh-privatekey -t -q vmware-system-user@"${IPS_NODES_READ}" << EOF
sudo -i
curl ${URL_REGISTRY_CERT} -k -o "${URL_REGISTRY_TRIM}".crt
cp "${URL_REGISTRY_TRIM}".crt /etc/ssl/certs/
/usr/bin/rehash_ca_certificates.sh
EOF
if [ $? -eq 0 ] ;
then  
      loginfo "Registry added successfully!"
else
      logerr "There was an error writing the registry to /etc/docker/daemon.json. Exiting..."
      exit 2
fi
done < "./ip-nodes-tkg"

# Restart the Docker daemon
while read -r IPS_NODES_READ;
do
loginfo "Restarting ContainerD on node '"${IPS_NODES_READ}"'..."
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i ./tkc-ssh-privatekey -t -q vmware-system-user@"${IPS_NODES_READ}" << EOF
sudo -i
systemctl restart containerd
EOF
if [ $? -eq 0 ] ;
then  
      loginfo "ContainerD daemon restarted successfully!"
else
      logerr "There was an error restarting the ContainerD daemon. Exiting..."
      exit 2
fi
done < "./ip-nodes-tkg"

# Cleaning up
loginfo "Cleaning up temporary files..."
rm -rf ./tkc-ssh-privatekey
rm -rf ./sv-cluster-creds
rm -rf ./ip-nodes-tkg
