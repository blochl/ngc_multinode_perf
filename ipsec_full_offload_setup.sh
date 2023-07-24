#!/bin/bash
# NGC Certification IPsec full offload setup v0.4
# Owner: dorko@nvidia.com
#

# host ip should be already configured
CLIENT_TRUSTED=$1
CLIENT_DEVICE=$2
SERVER_TRUSTED=$3
SERVER_DEVICE=$4
LOCAL_BF=$5
REMOTE_BF=$6
MTU_SIZE=$7

PF0=p0
VF0_REP='pf0hpf'
KEY1=0x6b58214a0ded001ed0fec88131addb4eba92301e8afa50287dd75e4ed89d7521070831e4
KEY2=0xe7276f90cbbdfc8ca1d86fdb22f99c69da3c524f28ef4fddbcc0606f202d47828b7ddfa6
REQID1=0x0d2425dd
REQID2=0xb17c0ba5

scriptdir="$(dirname "$0")"
source "${scriptdir}/common.sh"
source "${scriptdir}/ipsec_configuration.sh"

setup_bf() {
    local local_IP remote_IP in_key out_key in_reqid out_reqid bf_name mtu
    local_IP=$1
    remote_IP=$2
    in_key=$3
    out_key=$4
    in_reqid=$5
    out_reqid=$6
    bf_name=$7
    mtu=$8

    # Restricting host and setting interfaces
    # To revert privilges (host restriction) use the following command:
    # mlxprivhost -d /dev/mst/${pciconf} p
    ssh "${bf_name}" sudo -i /bin/bash mst start
    pciconf=$(ssh "${bf_name}" sudo -i find /dev/mst/ | grep -G  "pciconf0$")
    ssh "${bf_name}" sudo -i /bin/bash mlxprivhost -d "${pciconf}" r --disable_port_owner
    ssh "${bf_name}" sudo -i ip l set "${PF0}" mtu "${MTU_SIZE}"

    # Enable IPsec full offload
    remove_ipsec_rules "${bf_name}"
    ssh "${bf_name}" sudo -i /bin/bash << 'EOF'
ovs-appctl exit --cleanup
/sbin/mlnx-sf -a show | grep -q 'UUID:' && \
{
    echo "Remove Pre-set Subfunctions (by UUID)";
    for sf_uuid in $(/sbin/mlnx-sf -a show | awk '/UUID:/{print $2}' 2>/dev/null)
    do
        /sbin/mlnx-sf -a remove --uuid "${sf_uuid}"
    done
}

/sbin/mlnx-sf -a show | grep -q 'SF Index:' && \
{
    echo "Remove Pre-set Subfunctions (By Index)";
    for sf_index in $(/sbin/mlnx-sf -a show | awk '/SF Index:/{print $3}' 2>/dev/null)
    do
        /sbin/mlnx-sf -a delete --sfindex "${sf_index}"
        SF_REMOVED=1
    done
}
devlink dev eswitch set pci/0000:03:00.0 mode legacy
echo full > /sys/class/net/p0/compat/devlink/ipsec_mode
echo dmfs > /sys/bus/pci/devices/0000\:03\:00.0/net/p0/compat/devlink/steering_mode
devlink dev eswitch set pci/0000:03:00.0 mode switchdev
systemctl restart openvswitch-switch.service
EOF

    echo setting IPsec rules
    # Add states and policies on ARM host for IPsec.
    set_ipsec_rules "${bf_name}" "p0" "${local_IP}" "${remote_IP}" "${in_key}" \
        "${out_key}" "${in_reqid}" "${out_reqid}" "full_offload"
}

get_server_client_ips_and_ifs

REMOTE_BF_IP="${SERVER_IP[0]}"
LOCAL_BF_IP="${CLIENT_IP[0]}"

echo configure ipsec
setup_bf "${LOCAL_BF_IP}" "${REMOTE_BF_IP}" "${KEY1}" "${KEY2}" "${REQID1}" "${REQID2}" "${LOCAL_BF}" "${MTU_SIZE}"
setup_bf "${REMOTE_BF_IP}" "${LOCAL_BF_IP}" "${KEY2}" "${KEY1}" "${REQID2}" "${REQID1}" "${REMOTE_BF}" "${MTU_SIZE}"

ssh "${CLIENT_TRUSTED}" "ip l set ${CLIENT_NETDEV} up; ip l set ${CLIENT_NETDEV} mtu $(( MTU_SIZE - 500 ))"
ssh "${SERVER_TRUSTED}" "ip l set ${SERVER_NETDEV} up; ip l set ${SERVER_NETDEV} mtu $(( MTU_SIZE - 500 ))"
