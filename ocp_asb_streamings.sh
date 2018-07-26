#!/bin/bash

#
# Minimal example for deploying latest built 'Ansible Service Broker'
# on oc cluster up
#

PUBLIC_IP=${PUBLIC_IP:-"192.168.42.1"}
HOSTNAME=${PUBLIC_IP}.nip.io
ROUTING_SUFFIX="${HOSTNAME}"

if [ -z ${1} ];
  then
    echo "Starting OpenShift host data directory: " + ${1};
    oc cluster up --service-catalog=true --routing-suffix=${ROUTING_SUFFIX} --public-hostname=${PUBLIC_IP} --host-data-dir=${1};
  else
    echo "Starting OpenShift without host data directory";
    oc cluster up --service-catalog=true --routing-suffix=${ROUTING_SUFFIX} --public-hostname=${PUBLIC_IP};
fi

#
# Logging in as system:admin so we can create a clusterrolebinding and
# creating ansible-service-broker project
#
oc login -u system:admin
oc new-project ansible-service-broker

#
# A valid dockerhub username/password is required so the broker may
# authenticate with dockerhub to:
#
#  1) inspect the available repositories in an organization
#  2) read the manifest of each repository to determine metadata about
#     the images
#
# This is how the Ansible Service Broker determines what content to
# expose to the Service Catalog
#
# Note:  dockerhub API requirements require an authenticated user only,
# the user does not need any special access beyond read access to the
# organization.
#
# By default, the Ansible Service Broker will look at the
# 'ansibleplaybookbundle' organization, this can be overridden with the
# parameter DOCKERHUB_ORG being passed into the template.
#
TEMPLATE_URL=${TEMPLATE_URL:-"https://raw.githubusercontent.com/openshift/ansible-service-broker/ansible-service-broker-1.1.17-1/templates/deploy-ansible-service-broker.template.yaml"}
DOCKERHUB_ORG=${DOCKERHUB_ORG:-"streamzicatalog"} # DocherHub org where APBs can be found, default 'ansibleplaybookbundle'
ENABLE_BASIC_AUTH="false"
VARS="-p BROKER_CA_CERT=$(oc get secret -n kube-service-catalog -o go-template='{{ range .items }}{{ if eq .type "kubernetes.io/service-account-token" }}{{ index .data "service-ca.crt" }}{{end}}{{"\n"}}{{end}}' | tail -n 1)"
TAG="latest"
# Creating openssl certs to use.
mkdir -p /tmp/etcd-cert
openssl req -nodes -x509 -newkey rsa:4096 -keyout /tmp/etcd-cert/key.pem -out /tmp/etcd-cert/cert.pem -days 365 -subj "/CN=asb-etcd.ansible-service-broker.svc"
openssl genrsa -out /tmp/etcd-cert/MyClient1.key 2048 \
&& openssl req -new -key /tmp/etcd-cert/MyClient1.key -out /tmp/etcd-cert/MyClient1.csr -subj "/CN=client" \
&& openssl x509 -req -in /tmp/etcd-cert/MyClient1.csr -CA /tmp/etcd-cert/cert.pem -CAkey /tmp/etcd-cert/key.pem -CAcreateserial -out /tmp/etcd-cert/MyClient1.pem -days 1024

ETCD_CA_CERT=$(cat /tmp/etcd-cert/cert.pem | base64)
BROKER_CLIENT_CERT=$(cat /tmp/etcd-cert/MyClient1.pem | base64)
BROKER_CLIENT_KEY=$(cat /tmp/etcd-cert/MyClient1.key | base64)

curl -s $TEMPLATE_URL \
  | oc process \
  -n ansible-service-broker \
  -p DOCKERHUB_ORG="$DOCKERHUB_ORG" \
  -p TAG="$TAG" \
  -p SANDBOX_ROLE="admin" \
  -p ROUTING_SUFFIX="${PUBLIC_IP}.${WILDCARD_DNS}" \
  -p ENABLE_BASIC_AUTH="$ENABLE_BASIC_AUTH" \
  -p ETCD_TRUSTED_CA_FILE=/var/run/etcd-auth-secret/ca.crt \
  -p BROKER_CLIENT_CERT_PATH=/var/run/asb-etcd-auth/client.crt \
  -p BROKER_CLIENT_KEY_PATH=/var/run/asb-etcd-auth/client.key \
  -p ETCD_TRUSTED_CA="$ETCD_CA_CERT" \
  -p BROKER_CLIENT_CERT="$BROKER_CLIENT_CERT" \
  -p BROKER_CLIENT_KEY="$BROKER_CLIENT_KEY" \
  -p NAMESPACE=ansible-service-broker \
  -p AUTO_ESCALATE="true" \
  -p LAUNCH_APB_ON_BIND="true" \
  $VARS -f - | oc create -f -
if [ "$?" -ne 0 ]; then
  echo "Error processing template and creating deployment"
  exit
fi

# Set some permissions:
oc adm policy add-cluster-role-to-user access-asb-role developer
oc adm policy add-cluster-role-to-user cluster-admin developer

oc login -u developer -p developer
