#!/bin/bash

# Debug Session
if [ "${DEBUG_TRACE}" == "true" ]; then
    set -x
    RC_DIR=""
fi

# Error Handling
set -eu
set -o pipefail

# Globals
TEST_NAME=test_networking
IMAGE_PATH=/net/mtrlabfs01/vol/QA/qa/qa/cloudx/images/rhel_7.4_inbox_driver.qcow2
#IMAGE_PATH=/net/mtrlabfs01/vol/QA/qa/qa/cloudx/images/fedora_26_inbox_driver.qcow2
#IMAGE_PATH=/qa/qa/cloudx/images/fedora_26_ofed_last_release.qcow2
#IMAGE_PATH=/qa/qa/cloudx/images/ubuntu_xenial_inbox_driver.qcow2
IMAGE_NAME=$(basename ${IMAGE_PATH} .qcow2)
PORT1_TYPE=$1
PORT2_TYPE=$2
export SETUP_NEO=${SETUP_NEO:-false}
export SETUP_OVS_OFFLOAD=${SETUP_OVS_OFFLOAD:-false}
export SETUP_NETWORK_TYPE=${SETUP_NETWORK_TYPE:-vlan}

# Functions
break_point (){
    echo  "INFO: Break point hit any key to continue.."
    read
}

clean_neutron_log (){
    echo "INFO: Clean neutron log."
    > ~/logs/q-svc.log
}

clean_sdn_journal_db (){
    if [ "${SETUP_NEO}" == "true" ]; then
        echo "INFO: Clean SDN journal DB."
        if [ -n "$(mysql -e "use neutron; truncate sdn_journal; select * from sdn_journal")" ]; then
            echo "ERROR: Could not clean sdn_journal db.";
            exit 1
        fi
    fi
}

check_for_networking_mlnx_errors (){
    echo "INFO: Check no networking_mlnx related errors in neutron log."
    if grep -q "ERROR networking_mlnx" < ~/logs/q-svc.log; then
        echo "ERROR: Found some error in q-svc.log."
        grep "ERROR networking_mlnx" < ~/logs/q-svc.log
        exit 1
    fi
}

check_no_sdn_journal_processing (){
    echo "INFO: Check no records in sdn_journal in processing state."
	for i in {1..10}
	do
		if [ -z "$(mysql -e "use neutron; select * from sdn_journal where state='processing';")" ]; then
			echo "INFO: No processing records in sdn_journal."
			return
		fi
		sleep 10
	done
	echo "ERROR: SDN journal got some processing jobs. exiting.."
	mysql -e "use neutron; select * from sdn_journal where state='processing';"
	#check_for_networking_mlnx_errors
	exit 1
}

check_sdn (){
    if [ "${SETUP_NEO}" == "true" ]; then
        check_no_sdn_journal_processing
        #check_for_networking_mlnx_errors
    fi
}

clean_floating_ips (){
    echo "INFO: Delete floating ips."
	for id in $(openstack floating ip list -f value -c ID); do openstack floating ip delete "$id"; done
}

clean_network (){
    echo "INFO: Clean created networking elements."
    if [ -n "$(openstack subnet list --name ${TEST_NAME}_subnet -f value -c ID)" ]; then
        local subnet_id=$(openstack subnet show ${TEST_NAME}_subnet -f value -c id)
        if [ -n "$(openstack port list --long --device-owner network:router_interface --network test_networking_network -f value)" ]; then
            openstack router remove subnet "${ROUTER_ID}" ${TEST_NAME}_subnet
        fi
        for port_id in $(openstack port list -f value --long | grep ${subnet_id} | grep -v "router" | awk '{print $1}'); do
            openstack port delete ${port_id}
        done
        openstack subnet delete ${TEST_NAME}_subnet
    fi
    if [ -n "$(openstack network list --name ${TEST_NAME}_network -f value -c ID)" ]; then
        openstack network delete ${TEST_NAME}_network
    fi
}

clean_servers (){
	echo "INFO: Clean created servers."
	for id in $(openstack server list -f value | grep ${TEST_NAME} | cut -d' ' -f1); do openstack server delete $id; done
}

create_security_rules (){
	local ADMIN_SECURITY_GROUP_ID
	ADMIN_SECURITY_GROUP_ID=$(openstack security group list --project admin -f value -c ID)
    echo "INFO: Create security rules."
    if [ -z "$(openstack security group rule list -f value | grep "${ADMIN_SECURITY_GROUP_ID}" | grep "icmp 0.0.0.0/0")" ]; then
        openstack security group rule create --protocol icmp --dst-port -1 --remote-ip 0.0.0.0/0 "${ADMIN_SECURITY_GROUP_ID}"
    fi
    if [ -z "$(openstack security group rule list -f value | grep "${ADMIN_SECURITY_GROUP_ID}" | grep "tcp 0.0.0.0/0 22:22")" ]; then
        openstack security group rule create --protocol tcp --dst-port 22:22 --remote-ip 0.0.0.0/0 "${ADMIN_SECURITY_GROUP_ID}"
    fi
    if [ -z "$(openstack security group rule list -f value | grep "${ADMIN_SECURITY_GROUP_ID}" | grep "udp 0.0.0.0/0 53:53")" ]; then
        openstack security group rule create --protocol udp --dst-port 53:53 --remote-ip 0.0.0.0/0 "${ADMIN_SECURITY_GROUP_ID}"
    fi
}

create_network (){
    echo "INFO: Prepare required networking."
    export NETWORK_ID
    export SUBNET_ID
    NETWORK_ID=$(openstack network create ${TEST_NAME}_network --provider-network-type ${SETUP_NETWORK_TYPE} -f value -c id)
    SUBNET_ID=$(openstack subnet create --use-default-subnet-pool --network "${NETWORK_ID}" ${TEST_NAME}_subnet -f value -c id)
    openstack router add subnet "${ROUTER_ID}" "${SUBNET_ID}"
}

check_vm_status (){
    name=$1
    for i in {1..10}
    do
        vm_status=$(openstack server show ${name} | grep " status " | awk '{print $4}')
		if [ $vm_status == "BUILD" ]; then
			echo "VM Creation In Progress..."
            sleep 5
		elif [ $vm_status == "ACTIVE" ]; then
			echo "VM is ACTIVE!"
			return 0
		elif [ $vm_status == "ERROR" ]; then
			echo "VM Creation Failed!"
            return 1
		fi
    done
    return 1
}

create_key_pair (){
    echo "INFO: Create key pair."
    if [ -z "$(openstack keypair list -f value -c Name | grep ${TEST_NAME}_key)" ]; then
        openstack keypair create --public-key ~/.ssh/id_rsa.pub ${TEST_NAME}_key
    fi
}

server_create (){
    local port_id=$1
    local hypervisor_name=$2
    local vm_name=$3
    openstack server create --flavor 2 --image ${IMAGE_NAME} --key-name ${TEST_NAME}_key --nic port-id=${port_id} --availability-zone nova:${hypervisor_name} ${vm_name}
}

wait_for_servers_active (){
    local sleep_time=10
    local max_cycle=20
    local cycle=0
    echo "INFO: Wait for servers to become active."
    while [ -n "$(openstack server list --name ${TEST_NAME} -f value | grep -v ACTIVE)" ]; do
        if [ $cycle == $max_cycle ]; then
            echo "ERROR: Not All servers are active."
            exit 1
        fi
        sleep $sleep_time
        cycle=$(($cycle +1))
	done
    openstack server list --name ${TEST_NAME}
    echo "INFO: All servers are active."
}

check_ssh_to_vm(){
    local ip=$1
    local sleep_time=10
    local max_cycle=30
    local cycle=0
    for i in $(seq 1 $max_cycle); do
	 if sshpass -p "3tango" ssh -q -o "StrictHostKeyChecking no" root@$ip "cat /etc/os-release > allout.txt 2>&1"; then
	     echo "SUCCESS: Server $ip SSH connected."
	     return
	 fi
	 sleep $sleep_time
    done
    echo "ERROR: Timeout trying to ssh to server."
    exit 1
    #while [ $(sshpass -p "3tango" ssh -q -o "StrictHostKeyChecking no" root@${ip} "cat /etc/os-release > /dev/null"; echo $?) != 0 ] && [ $cycle != $max_cycle ]; do
#		if [ $cycle == $max_cycle ]; then
#            echo "ERROR: Timeout trying to ssh to server."
#            exit 1
#         fi
#         sleep $sleep_time
#         cycle=$(($cycle +1))
#    done
}

ping_vm_to_vm(){
    local vm_external_ip=$1
    local peer_vm_internal_ip=$2
    r_cmd="ping ${peer_vm_internal_ip} -c 4"
    #ssh-keygen -f "~/.ssh/known_hosts" -R ${vm_external_ip}
    if sshpass -p "3tango" ssh -q -o "StrictHostKeyChecking no" root@${vm_external_ip} "${r_cmd}"; then
        echo "SUCCESS: Run ping from ${vm_external_ip} to ${peer_vm_internal_ip}."
    else
        echo "ERROR: failed to run ping from ${vm_external_ip} to ${peer_vm_internal_ip}."
        exit 1
    fi
}

clean_all_resources(){
    clean_servers
    clean_floating_ips
    clean_network
}

# Main
export ROUTER_ID
export PUBLID_NETWORK_ID
ROUTER_ID=$(openstack router list -f value -c ID)
PUBLID_NETWORK_ID=$(openstack network list -f value | grep public | awk '{print $1}')

clean_all_resources
#clean_neutron_log
clean_sdn_journal_db
check_sdn
create_security_rules
create_network
check_sdn
create_key_pair

# if
if [ -z "$(openstack image list --name "${IMAGE_NAME}")" ]; then
    openstack image create --public --file ${IMAGE_PATH} --disk-format qcow2 --container-format bare ${IMAGE_NAME}
fi

HYPERVISOR_LIST=$(openstack hypervisor list -f value -c "Hypervisor Hostname")
vm1_name="${TEST_NAME}_vm_1"
vm2_name="${TEST_NAME}_vm_2"

# Create Port on private networka
if [ "${SETUP_OVS_OFFLOAD}" == "true" ] && [ "${PORT1_TYPE}" == "direct" ] && [ "${PORT2_TYPE}" == "direct" ]; then
    port1_id=$(openstack port create --vnic-type ${PORT1_TYPE} --binding-profile '{"capabilities": ["switchdev"]}' --network ${NETWORK_ID} ${PORT1_TYPE} | grep " id " | awk '{print $4}')
    port2_id=$(openstack port create --vnic-type ${PORT2_TYPE} --binding-profile '{"capabilities": ["switchdev"]}' --network ${NETWORK_ID} ${PORT2_TYPE} | grep " id " | awk '{print $4}')
else
    port1_id=$(openstack port create --vnic-type ${PORT1_TYPE} --network ${NETWORK_ID} ${PORT1_TYPE} | grep " id " | awk '{print $4}')
    port2_id=$(openstack port create --vnic-type ${PORT2_TYPE} --network ${NETWORK_ID} ${PORT2_TYPE} | grep " id " | awk '{print $4}')
fi

# Port IP  Address
port1_ip_address=$(openstack port show ${port1_id} -c fixed_ips -f value | cut -d',' -f1 | cut -d"'" -f2)
port2_ip_address=$(openstack port show ${port2_id} -c fixed_ips -f value | cut -d',' -f1 | cut -d"'" -f2)

# Create First Instance
server_create ${port1_id} $(echo "${HYPERVISOR_LIST}" | sed -n 1p) ${vm1_name}

# Create Second Instance
server_create ${port2_id} $(echo "${HYPERVISOR_LIST}" | sed -n 2p) ${vm2_name}

wait_for_servers_active
check_sdn

# Create Floating IP
floating_ip1_address=$(openstack floating ip create "${PUBLID_NETWORK_ID}" -f value -c floating_ip_address)
floating_ip2_address=$(openstack floating ip create "${PUBLID_NETWORK_ID}" -f value -c floating_ip_address)

openstack server add floating ip "${vm1_name}" "${floating_ip1_address}"
openstack server add floating ip "${vm2_name}" "${floating_ip2_address}"

openstack server list

check_ssh_to_vm ${floating_ip1_address}
check_ssh_to_vm ${floating_ip2_address}

ping_vm_to_vm ${floating_ip1_address} ${port2_ip_address}
ping_vm_to_vm ${floating_ip2_address} ${port1_ip_address}

#break_point
#clean_all_resources
#break_point
check_sdn
