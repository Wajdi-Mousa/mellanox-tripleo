#!/bin/bash
set -eux
set -o pipefail
exec 1> >(logger -s -t $(basename $0)) 2>&1

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# SOURCE - https://docs.openstack.org/tripleo-docs/latest/install/containers_deployment/overcloud.html#prepare-environment-containers

LOCAL_IP=$(ip a sh br-ctlplane | grep "inet " | awk '{print $2}' | cut -d'/' -f1)
# List tags by date (if needed more up to date containers **may be less stable)
#openstack overcloud container image tag discover --image trunk.registry.rdoproject.org/master/centos-binary-base:current-tripleo-rdo --tag-from-label build-date
TAG="current-tripleo-rdo"
openstack overcloud container image prepare --namespace trunk.registry.rdoproject.org/master --tag ${TAG} --push-destination ${LOCAL_IP}:8787 --output-env-file ${SCRIPT_DIR}/docker_registry.yaml --output-images-file ${SCRIPT_DIR}/overcloud_containers.yaml --roles-file $1 $2
openstack overcloud container image upload --config-file ${SCRIPT_DIR}/overcloud_containers.yaml
