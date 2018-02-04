#!/bin/bash
set -eux
set -o pipefail
exec 1> >(logger -s -t $(basename $0)) 2>&1

ENV_FILES=""
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

NETWORK_TYPE=$(cat ${SCRIPT_DIR}/network-environment.yaml | grep NeutronNetworkType | cut -d"'" -f2)
POOL_START=$(grep $(hostname -s) /net/mtrlabfs01/vol/QA/qa/qa/cloudx/ip-pool.txt | grep nodes | cut -d',' -f3)
POOL_END=$(grep $(hostname -s) /net/mtrlabfs01/vol/QA/qa/qa/cloudx/ip-pool.txt | grep nodes | cut -d',' -f4)
sed -i "s/ExternalAllocationPools.*/ExternalAllocationPools: [{'start': '${POOL_START}', 'end': '${POOL_END}'}]/g" ${SCRIPT_DIR}/network-environment.yaml

#OSP# env file containing path's to docker containers (should be first).
#ENV_FILES+="-e ${SCRIPT_DIR}/overcloud_images.yaml"

#TripleO# env file for deploying overcloud containerized
#ENV_FILES+=" -e /usr/share/openstack-tripleo-heat-templates/environments/docker.yaml"

#TripleO# env file for deploying overcloud containerized
#ENV_FILES+=" -e /usr/share/openstack-tripleo-heat-templates/environments/docker-ha.yaml"

#TripleO# env file for deploying overcloud containerized
#ENV_FILES+=" -e ${SCRIPT_DIR}/docker_registry.yaml"

# env file for network isolation with vlans.
ENV_FILES+=" -e /usr/share/openstack-tripleo-heat-templates/environments/network-isolation.yaml"

# env file for enabling SR-IOV legacy
#ENV_FILES+=" -e /usr/share/openstack-tripleo-heat-templates/environments/neutron-sriov.yaml"

# env file for enabling hw offload - ASAP^2.
#ENV_FILES+=" -e /usr/share/openstack-tripleo-heat-templates/environments/neutron-ovs-hw-offload.yaml"

# env file for enabling opendaylight with ASAP^2
ENV_FILES+=" -e /usr/share/openstack-tripleo-heat-templates/environments/neutron-opendaylight-hw-offload.yaml"

# env file for appending kernel boot params (used for SR-IOV)
ENV_FILES+=" -e /usr/share/openstack-tripleo-heat-templates/environments/host-config-and-reboot.yaml"

# env file containging all network paramters and other configurations (should be last).
ENV_FILES+=" -e ${SCRIPT_DIR}/network-environment.yaml"

openstack overcloud roles generate -o ${SCRIPT_DIR}/roles_date.yaml Controller ComputeSriov
if [[ "${ENV_FILES}" =~ "docker.yaml" ]]; then
  ${SCRIPT_DIR}/docker.sh "${SCRIPT_DIR}/roles_date.yaml" "${ENV_FILES}"
fi
openstack overcloud deploy --templates $(echo "${ENV_FILES}") -r ${SCRIPT_DIR}/roles_date.yaml
. ./overcloudrc
./post_overcloud_deploy.sh
if [[ "${ENV_FILES}" =~ "neutron-ovs-hw-offload.yaml" ]]; then
  SETUP_NETWORK_TYPE=${NETWORK_TYPE} SETUP_OVS_OFFLOAD=true ${SCRIPT_DIR}/overcloud_verify.sh direct direct
else
  SETUP_NETWORK_TYPE=${NETWORK_TYPE} SETUP_OVS_OFFLOAD=false ${SCRIPT_DIR}/overcloud_verify.sh direct direct
fi
