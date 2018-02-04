POOL_START=$(grep $(hostname -s) /net/mtrlabfs01/vol/QA/qa/qa/cloudx/ip-pool.txt | grep floating | cut -d',' -f3)
POOL_END=$(grep $(hostname -s) /net/mtrlabfs01/vol/QA/qa/qa/cloudx/ip-pool.txt | grep floating | cut -d',' -f4)

openstack network create public --external --provider-network-type flat --provider-physical-network datacentre
openstack subnet create public --network public --dhcp --allocation-pool start=${POOL_START},end=${POOL_END} --gateway 10.209.86.1 --subnet-range 10.209.86.0/24
openstack subnet pool create shared-default-subnetpool-v4 --default-prefix-length 26 --pool-prefix 10.0.0.0/22 --share --default
openstack router create external
openstack router set --external-gateway public external

openstack flavor create --id 1 --ram 512 --disk 1 --vcpus 1 m1.tiny
openstack flavor create --id 2 --ram 2048 --disk 20 --vcpus 1 m1.small
openstack flavor create --id 3 --ram 4096 --disk 40 --vcpus 2 m1.medium
openstack flavor create --id 4 --ram 8192 --disk 80 --vcpus 4 m1.large
openstack flavor create --id 5 --ram 16384 --disk 160 --vcpus 8 m1.xlarge
openstack quota set admin --ram -1 --instances -1 --fixed-ips -1 --cores -1 --gigabytes -1 --volumes -1 --ports -1 --subnets -1 --networks -1 --floating-ips -1 --routers -1
