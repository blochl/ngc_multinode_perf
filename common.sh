#!/bin/bash
# NGC Certification common functions v0.1
# Owner: dorko@nvidia.com
#

scriptdir="$(dirname "$0")"

check_connection() {
    if ! ssh "${CLIENT_TRUSTED}" ping "${SERVER_IP}" -c 5
    then
        echo "No ping from client to server, test aborted"
        exit 1
    fi
}

change_mtu() {
    if [ "${LINK_TYPE}" -eq 1 ]; then
        MTU=9000
    elif [ "${LINK_TYPE}" -eq 32 ]; then
        MTU=4092
    fi
    ssh "${CLIENT_TRUSTED}" "echo ${MTU} > /sys/class/infiniband/${CLIENT_DEVICE}/device/net/*/mtu"
    ssh "${SERVER_TRUSTED}" "echo ${MTU} > /sys/class/infiniband/${SERVER_DEVICE}/device/net/*/mtu"
    CURR_MTU="$(ssh "${CLIENT_TRUSTED}" "cat /sys/class/infiniband/${CLIENT_DEVICE}/device/net/*/mtu")"
    ((CURR_MTU == MTU)) || echo 'Warning, MTU was not configured correctly on Client'
    CURR_MTU="$(ssh "${SERVER_TRUSTED}" "cat /sys/class/infiniband/${SERVER_DEVICE}/device/net/*/mtu")"
    ((CURR_MTU == MTU)) || echo 'Warning, MTU was not configured correctly on Server'
}

run_iperf2() {
    ssh "${SERVER_TRUSTED}" pkill iperf
    ssh "${SERVER_TRUSTED}" iperf -s &
    sleep 5
    ssh "${CLIENT_TRUSTED}" iperf -c "${SERVER_IP}" -P "${MAX_PROC}" -t 30
    ssh "${SERVER_TRUSTED}" pkill iperf
}

get_average() {
    local count total
    count=0
    total=0

    for i in "$@"
    do
            total=$(echo $total+$i | bc )
            ((count++))
    done
    echo "scale=2; $total / $count" | bc
}

get_min() {
    local distances min_idx min_val
    distances=($@)
    min_idx=0
    min_val=$1
    for i in $(seq 0 $((${#distances[@]}-1))); do
        if (( ${distances[$i]} < min_val )); then
            min_idx=$i
            min_val=${distances[$i]}
        fi
    done
    echo "${min_idx}"
}

get_n_min_distances() {
    local n distances mins flag_min_is_first
    n=$1
    distances=(${@:2})
    mins=()
    flag_min_is_first=0
    for i in $(seq 0 $((n-1))); do
        MIN_IDX=$(get_min ${distances[@]})
        TMP_MIN_IDX=MIN_IDX
        if (( flag_min_is_first == 1 )); then
            MIN_IDX=$((MIN_IDX+1))
        fi
        if (( TMP_MIN_IDX == 0 )); then
            flag_min_is_first=1
        else
            flag_min_is_first=0
        fi
        mins=(${mins[@]} ${MIN_IDX})
        unset distances[$MIN_IDX]
        distances=(${distances[@]})
    done
    echo "${mins[@]}"
}

prep_for_tune_and_iperf_test() {

    ssh "${CLIENT_TRUSTED}" pkill iperf3
    ssh "${SERVER_TRUSTED}" pkill iperf3

    CLIENT_NUMA_NODE="$(ssh "${CLIENT_TRUSTED}" "cat /sys/class/infiniband/${CLIENT_DEVICE}/device/numa_node")"
    ((CLIENT_NUMA_NODE != -1)) || CLIENT_NUMA_NODE="0"
    SERVER_NUMA_NODE="$(ssh "${SERVER_TRUSTED}" "cat /sys/class/infiniband/${SERVER_DEVICE}/device/numa_node")"
    ((SERVER_NUMA_NODE != -1)) || SERVER_NUMA_NODE="0"

    CLIENT_NETDEV="$(ssh "${CLIENT_TRUSTED}" "ls /sys/class/infiniband/${CLIENT_DEVICE}/device/net")"
    SERVER_NETDEV="$(ssh "${SERVER_TRUSTED}" "ls /sys/class/infiniband/${SERVER_DEVICE}/device/net")"

    SERVER_IP=($(ssh "${SERVER_TRUSTED}" "ip a sh ${SERVER_NETDEV} | grep -ioP  '(?<=inet )\d+\.\d+\.\d+\.\d+'"))
    CLIENT_IP=($(ssh "${CLIENT_TRUSTED}" "ip a sh ${CLIENT_NETDEV} | grep -ioP  '(?<=inet )\d+\.\d+\.\d+\.\d+'"))

    if [ -z "$SERVER_IP" ]; then
        echo "Can't find server IP, did you set IPv4 address in server ?"
        exit 1
    fi
    if [ -z "$CLIENT_IP" ]; then
        echo "Can't find server IP, did you set IPv4 address in client ?"
        exit 1
    fi

    ssh "${CLIENT_TRUSTED}" iperf3 -v
    ssh "${SERVER_TRUSTED}" iperf3 -v
    ssh "${CLIENT_TRUSTED}" cat /proc/cmdline
    ssh "${SERVER_TRUSTED}" cat /proc/cmdline
    ssh "${CLIENT_TRUSTED}" iperf -v
    ssh "${SERVER_TRUSTED}" iperf -v

    MAX_PROC=16
    THREADS=1
    TIME=120
    TCP_PORT_ID="$(echo "${CLIENT_DEVICE}" | cut -d '_' -f 2)"
    TCP_PORT_ADDITION=$((TCP_PORT_ID * 100))
    BASE_TCP_PORT=$((5200 + TCP_PORT_ADDITION))
    NUMACTL_HW=("numactl" "--hardware" "|" "grep" "-v" "node")
    NUM_SOCKETS_CMD=("lscpu" "|" "grep" "'Socket'" "|" "cut" "-d':'" "-f2")
    NUM_NUMAS_CMD=("lscpu" "|" "grep" "'NUMA node(s)'" "|" "cut" "-d':'" "-f2")

    # Get Client NUMA topology
    CLIENT_NUMA_DISTS=( $(ssh "${CLIENT_TRUSTED}" "${NUMACTL_HW[*]} | sed -n 's/${CLIENT_NUMA_NODE}://p'") )
    CLIENT_NUM_SOCKETS=$(ssh "${CLIENT_TRUSTED}" "${NUM_SOCKETS_CMD[*]}")
    CLIENT_NUM_NUMAS=$(ssh "${CLIENT_TRUSTED}" "${NUM_NUMAS_CMD[*]}")
    CLIENT_LOGICAL_NUMA_PER_SOCKET=$(( (CLIENT_NUM_NUMAS + CLIENT_NUM_SOCKETS - 1) / CLIENT_NUM_SOCKETS ))
    CLIENT_FIRST_SIBLING_NUMA=( $(get_n_min_distances "${CLIENT_LOGICAL_NUMA_PER_SOCKET}" ${CLIENT_NUMA_DISTS[@]}) )
    MIN_IDX=$(get_min ${CLIENT_FIRST_SIBLING_NUMA[@]})
    CLIENT_BASE_NUMA=${CLIENT_FIRST_SIBLING_NUMA[$MIN_IDX]}

    echo "MIN_IDX $MIN_IDX, CLIENT_FIRST_SIBLING_NUMA ${CLIENT_FIRST_SIBLING_NUMA[*]} CLIENT_BASE_NUMA ${CLIENT_BASE_NUMA} CLIENT_NUMA_DISTS ${CLIENT_NUMA_DISTS[*]} CLIENT_NUMA_NODE ${CLIENT_NUMA_NODE}"

    # Get Server NUMA topology
    SERVER_NUMA_DISTS=( $(ssh "${SERVER_TRUSTED}" "${NUMACTL_HW[*]} | sed -n 's/${SERVER_NUMA_NODE}://p'") )
    SERVER_NUM_SOCKETS=$(ssh "${SERVER_TRUSTED}" "${NUM_SOCKETS_CMD[*]}")
    SERVER_NUM_NUMAS=$(ssh "${SERVER_TRUSTED}" "${NUM_NUMAS_CMD[*]}")
    SERVER_LOGICAL_NUMA_PER_SOCKET=$(( (SERVER_NUM_NUMAS + SERVER_NUM_SOCKETS - 1) / SERVER_NUM_SOCKETS ))
    SERVER_FIRST_SIBLING_NUMA=( $(get_n_min_distances "${SERVER_LOGICAL_NUMA_PER_SOCKET}" ${SERVER_NUMA_DISTS[@]}) )
    MIN_IDX=$(get_min ${SERVER_FIRST_SIBLING_NUMA[@]})
    SERVER_BASE_NUMA=${SERVER_FIRST_SIBLING_NUMA[$MIN_IDX]}

}

run_iperf3() {
    RESULT_FILE=/tmp/ngc_run_result.log

    PROC=$(printf "%s\n" "${CLIENT_AFFINITY_IRQ_COUNT}" "${SERVER_AFFINITY_IRQ_COUNT}" "${MAX_PROC}" | sort -h | head -n1)
    #check amount of IPs for interface asked, and run iperf3 mutli proccess each on another ip.
    IP_AMOUNT=$(printf "%s\n" ${#SERVER_IP[@]} ${#CLIENT_IP[@]} | sort -h | head -n1)

    echo "-- starting iperf with ${PROC} processes ${THREADS} threads --"

    CLIENT_ACTIVE_CORES_LIST=()
    SERVER_ACTIVE_CORES_LIST=()
    for P in $(seq 0 $((PROC-1)))
    do
        index=$((P%CLIENT_LOGICAL_NUMA_PER_SOCKET*CLIENT_PHYSICAL_CORE_COUNT+P/CLIENT_LOGICAL_NUMA_PER_SOCKET))
        CLIENT_ACTIVE_CORES_LIST=(${CLIENT_ACTIVE_CORES_LIST[@]} ${CLIENT_PHYSICAL_CORES[$index]})
        index=$((P%SERVER_LOGICAL_NUMA_PER_SOCKET*SERVER_PHYSICAL_CORE_COUNT+P/SERVER_LOGICAL_NUMA_PER_SOCKET))
        SERVER_ACTIVE_CORES_LIST=(${SERVER_ACTIVE_CORES_LIST[@]} ${SERVER_PHYSICAL_CORES[$index]})

    done
    CLIENT_ACTIVE_CORES_LIST=(${CLIENT_ACTIVE_CORES_LIST[@]})
    SERVER_ACTIVE_CORES_LIST=(${SERVER_ACTIVE_CORES_LIST[@]})

    readarray -t sorted < <(for a in "${CLIENT_ACTIVE_CORES_LIST[@]}"; do echo "${a}"; done | sort -n)
    CLIENT_ACTIVE_CORES_LIST_STRING=$(printf ",%s" "${sorted[@]}")
    CLIENT_ACTIVE_CORES_LIST_STRING=${CLIENT_ACTIVE_CORES_LIST_STRING:1}
    sorted=()
    readarray -t sorted < <(for a in "${SERVER_ACTIVE_CORES_LIST[@]}"; do echo "${a}"; done | sort -n)
    SERVER_ACTIVE_CORES_LIST_STRING=$(printf ",%s" "${sorted[@]}")
    SERVER_ACTIVE_CORES_LIST_STRING=${SERVER_ACTIVE_CORES_LIST_STRING:1}

    ssh "${SERVER_TRUSTED}" "bash -s" -- < "${scriptdir}/run_iperf3_servers.sh" \
        "${PROC}" "${SERVER_NUMA_NODE}" "${SERVER_LOGICAL_NUMA_PER_SOCKET}" \
        "${SERVER_BASE_NUMA}" "${BASE_TCP_PORT}" &
    if [ "${DUPLEX}" = "FULL" ]; then
        ssh "${CLIENT_TRUSTED}" "bash -s" -- < "${scriptdir}/run_iperf3_servers.sh" \
            "${PROC}" "${CLIENT_NUMA_NODE}" "${CLIENT_LOGICAL_NUMA_PER_SOCKET}" \
            "${CLIENT_BASE_NUMA}" "${BASE_TCP_PORT}" &
    fi

    check_connection

    ssh "${CLIENT_TRUSTED}" "bash -s" -- < "${scriptdir}/run_iperf3_clients.sh" \
        "${PROC}" "${CLIENT_NUMA_NODE}" "${CLIENT_LOGICAL_NUMA_PER_SOCKET}" \
        "${CLIENT_BASE_NUMA}" "${SERVER_IP[$((P%IP_AMOUNT))]}" \
        "${BASE_TCP_PORT}" "${THREADS}" "${TIME}" &
    if [ "${DUPLEX}" = "FULL" ]; then
        sleep 0.1
        ssh "${SERVER_TRUSTED}" "bash -s" -- < "${scriptdir}/run_iperf3_clients.sh" \
            "${PROC}" "${SERVER_NUMA_NODE}" "${SERVER_LOGICAL_NUMA_PER_SOCKET}" \
            "${SERVER_BASE_NUMA}" "${CLIENT_IP[$((P%IP_AMOUNT))]}" \
            "${BASE_TCP_PORT}" "${THREADS}" "${TIME}" &
    fi

    DURATION=$((TIME - 1))
    ssh "${CLIENT_TRUSTED}" "sar -u -P ${CLIENT_ACTIVE_CORES_LIST_STRING},all ${DURATION} 1 | grep 'Average' | head -n $((PROC + 1)) > ${CLIENT_CORE_USAGES_FILE}$$" &
    ssh "${SERVER_TRUSTED}" "sar -u -P ${SERVER_ACTIVE_CORES_LIST_STRING},all ${DURATION} 1 | grep 'Average' | head -n $((PROC + 1)) > ${SERVER_CORE_USAGES_FILE}$$" &
    wait

    IPERF_TPUT=$(cat $RESULT_FILE | grep sum_sent -A7 | grep bits_per_second | tr "," " " | awk '{ SUM+=$NF } END { print SUM } ')
    BITS=$(printf '%.0f' $IPERF_TPUT)
    echo "Throughput is: $(awk "BEGIN {printf \"%.2f\n\",${BITS}/1000000000}") Gb/s"

    echo "${CLIENT_TRUSTED} Active cores: ${CLIENT_ACTIVE_CORES_LIST_STRING}"
    echo "Active core usages on ${CLIENT_TRUSTED}"
    ssh "${CLIENT_TRUSTED}" "cat ${CLIENT_CORE_USAGES_FILE}$$" | sed 's/|/ /' | awk '{print $2 "\t" $5}'
    USAGES=($(ssh "${CLIENT_TRUSTED}" "cat ${CLIENT_CORE_USAGES_FILE}$$" | tail -n +2 | sed 's/|/ /' | awk '{print $5}'))
    TOTAL_ACTIVE_AVERAGE=$(get_average ${USAGES[@]})
    paste <(echo "Overall Active: ${TOTAL_ACTIVE_AVERAGE}") <(echo "Overall All cores: ") \
        <(ssh "${CLIENT_TRUSTED}" "cat ${CLIENT_CORE_USAGES_FILE}$$" | grep all | sed 's/|/ /' | awk '{print $5}')

    echo "${SERVER_TRUSTED} Active cores: ${SERVER_ACTIVE_CORES_LIST_STRING}"
    echo "Active core usages on ${SERVER_TRUSTED}"
    ssh "${SERVER_TRUSTED}" "cat ${SERVER_CORE_USAGES_FILE}$$" | sed 's/|/ /' | awk '{print $2 "\t" $5}'
    USAGES=($(ssh "${SERVER_TRUSTED}" "cat ${SERVER_CORE_USAGES_FILE}$$" | tail -n +2 | sed 's/|/ /' | awk '{print $5}'))
    TOTAL_ACTIVE_AVERAGE=$(get_average ${USAGES[@]})
    paste <(echo "Overall Active: ${TOTAL_ACTIVE_AVERAGE}") <(echo "Overall All cores: ") \
        <(ssh "${SERVER_TRUSTED}" "cat ${SERVER_CORE_USAGES_FILE}$$" | grep all | sed 's/|/ /' | awk '{print $5}')

}