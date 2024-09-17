#!/bin/bash -e

usage() {
 echo "Usage: $0 -hvy -l path/to/file.log"
 echo "Options:"
 echo " -h,	Display this help message"
 echo " -v,	Enable verbose mode"
 echo " -l,	Specify path to a log file."
 echo " -y,     Assume 'y' to all answers and continue without asking."
}


while getopts "hvyl:" flag; do
 case $flag in
   h) # Handle the -h flag
   # Display script help information
   usage
   exit 0 
   ;;
   l) # Handle the -l with an argument
   log_file=$OPTARG
   ;;
   v) # Handle the -v flag
   # Enable verbose mode
   verbose=true
   ;;
   y) # Handle the -y flag
   # Assumes a 'y' answer to all prompts to continue. 
   answer=true
   ;;
   \?)
   # Handle invalid options
   usage
   exit 1
   ;;
 esac
done

#Set failure counter to 0. 
check_failed=0

record_fail()
{
    check_failed=$((check_failed+1))
    failed_check_names=$((failed_check_names+"$1 "))
    log_info "${1} Test: Failed"
    echo -e "\n==============================\n"
}

#Log verbose messages, but don't echo them unless the -v flag is used.
log_verbose()
{
    if [ $log_file ]; then
        echo -e "[$(date +'%Y-%m-%d %H:%M:%S')] ${1}" >> "$log_file"
    fi
    if [ "$verbose" = true ]; then 
        echo -e "${1}"
    fi
}

#Log Info/Error Messages and always echo them. 
log_info()
{
    if [ $log_file ]; then
        echo -e "[$(date +'%Y-%m-%d %H:%M:%S')] ${1}" >> "$log_file"
    fi
    echo -e "${1}"
}



check_bundles()
{
    log_info "Starting helm bundle status check... "

    # fleet bundles should be ready
    # except mcc-harvester, which has Modified status in 1.0.3
    bundles=$(kubectl get bundles.fleet.cattle.io -A -o yaml)
    pending=$(echo "$bundles" | yq '.items | any_c(.metadata.name != "mcc-harvester" and .spec.helm != null and .status.summary.ready == 0)')

    if [ "$pending" = "false" ]; then
      log_verbose "All Helm bundles are ready."
      log_info "Helm-Bundles Test: Pass"
      echo -e "\n==============================\n"
      return
    fi
    # These are failures so send them to the info log
    log_info "There are non-ready Helm bundles:"
    log_info "$(echo "$bundles" | yq '.items[] | select(.spec.helm != null and .status.summary.ready == 0) | .metadata.namespace + "/" + .metadata.name')"
    echo -e "\n"
    record_fail "Helm-Bundles"
}

check_harvester_bundle()
{
    log_info "Starting Harvester bundle status check..."

    current_summary=$(mktemp)
    kubectl get bundles.fleet.cattle.io/mcc-harvester -n fleet-local -o yaml | yq '.status.summary' > $current_summary

    expected_summary=$(mktemp)
cat > $expected_summary <<EOF
desiredReady: 1
ready: 1
EOF

    if ! diff <(yq -P 'sort_keys(..)' $current_summary) <(yq -P 'sort_keys(..)' $expected_summary); then
        log_info "Harvester bundle is not ready!"
        record_fail "Harvester-Bundles"
        return
    fi
    log_verbose "All Harvester bundles are ready."
    log_info "Harvester-Bundles Test: Pass"
    echo -e "\n==============================\n"
}

check_nodes()
{
    local failed="false"
    log_info "Starting Node-Status check... "

    # Use a file to store the node state becuase we can't set the global variable inside the piped scope
    # The file is removed in the piped scope if there are not-ready nodes.
    node_ready_state=$(mktemp)

    # nodes should not be cordoned
    nodes=$(kubectl get nodes -o yaml)
    unschedulable=$(echo "$nodes" | yq '.items | any_c(.spec.unschedulable == true)')

    if [ "$unschedulable" = "true" ]; then
        log_info "There are unschedulable nodes:"
        log_info "$(echo "$nodes" | yq '.items[] | select(.spec.unschedulable == true)  | .metadata.name')"
        rm -f $node_ready_state
    fi

    # nodes should not be tainted
    tainted=$(echo "$nodes" | yq '.items | any_c(.spec.taints != null)')
    if [ "$tainted" = "true" ]; then
        log_info "There are tainted nodes:"
        log_info "$(echo "$nodes" | yq '.items[] | select(.spec.taints != null)  | .metadata.name')"
        rm -f $node_ready_state
    fi

    # nodes should be ready
    echo "$nodes" | yq .items[].metadata.name |
        while read -r node_name; do
            node_ready=$(kubectl get nodes $node_name -o yaml | yq '.status.conditions | any_c(.type == "Ready" and .status == "True")')
            if [ "$node_ready" = "false" ]; then
                log_info "Node $node_name is not ready!"
                rm -f $node_ready_state
            fi
        done

    if [ -e $node_ready_state ]; then
        log_verbose "All nodes are ready."
        log_info "Node-Status Test: Pass"
        echo -e "\n==============================\n"
        rm $node_ready_state
    else
        log_verbose "There are non-ready nodes."
        record_fail "Node-Status"
    fi
}

check_cluster()
{
    log_info "Starting CAPI Cluster State check..."
    cluster_phase=$(kubectl get clusters.cluster.x-k8s.io/local -n fleet-local -o yaml | yq '.status.phase')

    # cluster should be in provisioned
    if [ "$cluster_phase" != "Provisioned" ]; then
        log_info "Cluster is not provisioned ($cluster_phase)"
        record_fail "CAPI-Cluster-State"
        return
    fi

    log_verbose "The CAPI cluster is provisioned."
    log_info "CAPI-Cluster-State Test: Pass"
    echo -e "\n==============================\n"
}

check_machines()
{
    local failed="false"
    log_info "Starting CAPI Machine Count check..."

    # machine count should be equal to node counts
    machine_count=$(kubectl get machines.cluster.x-k8s.io -n fleet-local -o yaml | yq '.items | length')
    node_count=$(kubectl get nodes -o yaml | yq '.items | length')
    if [ $machine_count -ne $node_count ]; then
        log_info "CAPI machine count (${machine_count}) is not equal to node count (${node_count}). Check the log or verbose mode (-l or -v) for more details. "
        log_verbose "There are orphan machines:"
        log_verbose "$(kubectl get nodes)"
        log_verbose "$(kubectl get machines.cluster.x-k8s.io -n fleet-local)"
        record_fail "CAPI-Machine-Count"
    else
        log_verbose "CAPI machine count is equal to node count."
        log_info "CAPI-Machine-Count Test: Pass"
        echo -e "\n==============================\n"
    fi

    log_info "Starting CAPI Machine State check..."

    # Use a file to store the machine state becuase we can't set the global variable inside the piped scope
    # The file is removed in the piped scope if there are not-ready machines.
    machine_ready_state=$(mktemp)

    # all machines need to be provisioned
    kubectl get machines.cluster.x-k8s.io -n fleet-local -o yaml | yq '.items[].metadata.name' |
        while read -r machine_name; do
            machine_phase=$(kubectl get machines.cluster.x-k8s.io/$machine_name -n fleet-local -o yaml | yq '.status.phase')

            if [ "$machine_phase" != "Running" ]; then
                log_info "CAPI machine $machine_name phase is not 'Running' but is: $machine_phase."
                rm -f $machine_ready_state
            fi
        done

    if [ -e $machine_ready_state  ]; then
        log_verbose "The CAPI machines are provisioned."
        log_info "CAPI-Machine-State Test: Pass"
        rm $machine_ready_state
    else
        log_verbose "There are non-ready CAPI machines."
        record_fail "CAPI-Machine-State"
    fi
}

check_volumes()
{
    log_info "Starting Longhorn Volume Health Status check..."

    node_count=$(kubectl get nodes -o yaml | yq '.items | length')

    if [ $node_count -eq 1 ]; then
        log_info "Skip checking for single node cluster."
        log_info "Longhorn-Volume-Health-Status Test: Skipped"
        echo -e "\n==============================\n"
        return
    fi

    # Use a file to store the healthy state becuase we can't set the global variable inside the piped scope
    # The file is removed in the piped scope if there are any degraded volumes.
    healthy_state=$(mktemp)

    # For each running engine and its volume
    kubectl get engines.longhorn.io -n longhorn-system -o json |
        jq -r '.items | map(select(.status.currentState == "running")) | map(.metadata.name + " " + .metadata.labels.longhornvolume) | .[]' | {
            while read -r lh_engine lh_volume; do
                log_verbose "Checking running engine: ${lh_engine}"

                if [ $node_count -gt 2 ];then
                    volume_json=$(kubectl get volumes.longhorn.io/$lh_volume -n longhorn-system -o json)
                    # single-replica volumes should be handled exclusively
                    volume_replicas=$(echo $volume_json | jq -r '.spec.numberOfReplicas')
                    if [ $volume_replicas -eq 1 ]; then
                        log_info "Volume ${lh_volume} is a single-replica volume. Please consider shutting down the corresponding workload or adjusting its replica count before upgrading."
                        rm -f $healthy_state
                    else
                        robustness=$(echo $volume_json | jq -r '.status.robustness')
                        if [ "$robustness" = "healthy" ]; then
                            log_verbose "Volume ${lh_volume} is healthy."
                        else
                            log_info "Degraded Longhorn Volume found: ${lh_volume}"
                            rm -f $healthy_state
                        fi
                    fi
                else
                    # This is a two node situation since we skip this in single nodes and the previous section is 3 or more. 
                    # Make sure maximum two replicas are healthy.
                    expected_replicas=2

                    # Replica 1 case
                    volume_replicas=$(kubectl get volumes.longhorn.io/$lh_volume -n longhorn-system -o jsonpath='{.spec.numberOfReplicas}')
                    if [ $volume_replicas -eq 1 ]; then
                        expected_replicas=1
                    fi

                    ready_replicas=$(kubectl get engines.longhorn.io/$lh_engine -n longhorn-system -o json |
                                    jq -r '.status.replicaModeMap | to_entries | map(select(.value == "RW")) | length')
                    if [ $ready_replicas -ge $expected_replicas ]; then
                        log_verbose "Volume ${lh_volume} is healthy."
                    else
                        log_info "Degraded Longhorn Volume found: ${lh_volume}"
                        rm -f $healthy_state
                    fi
                fi
                sleep 0.5
            done
        }

    if [ -e $healthy_state ]; then
        log_verbose "All volumes are healthy."
        log_info "Longhorn-Volume-Health-Status Test: Pass"
        echo -e "\n==============================\n"
        rm $healthy_state
    else
        log_info "There are volumes that need your attention!"
        record_fail "Longhorn-Volume-Health-Status"
    fi
}

# https://github.com/harvester/harvester/issues/3648
check_attached_volumes()
{
    log_info "Starting Stale Longhorn Volumes check..."

    # Use a file to store the clean state becuase we can't set the global variable inside the piped scope
    # The file is removed in the piped scope if any volume is stale.
    clean_state=$(mktemp)

    volumes=$(kubectl get volumes.longhorn.io -A -o yaml)
    # for each attached volume
    echo "$volumes" | yq '.items[] | select(.status.state == "attached") | .metadata.namespace + " " + .metadata.name' | {
        while read -r vol_namespace vol_name; do
            log_verbose "Checking volume: ${vol_namespace}/${vol_name}"

            # check .status.kubernetesStatus.workloadStatus is nil
            workloads=$(kubectl get volumes.longhorn.io/$vol_name -n $vol_namespace -o yaml | yq '.status.kubernetesStatus.workloadsStatus | length')
            if [ "$workloads" = "0" ]; then
                log_info "Volume $vol_namespace/$vol_name is attached but has no workload."
                rm -f $clean_state
                continue
            fi

            # check .status.kubernetesStatus.workloadStatus has non-running workload. e.g.,
            # workloadsStatus:
            #   - podName: virt-launcher-ubuntu-h9cfq
            #     podStatus: Succeeded
            #     workloadName: ubuntu
            #     workloadType: VirtualMachineInstance
            is_stale=$(kubectl get volumes.longhorn.io/$vol_name -n $vol_namespace -o yaml | yq '.status.kubernetesStatus.workloadsStatus | any_c(.podStatus != "Running")')
            if [ "$is_stale" = "true" ]; then
                log_info "Volume ${vol_namespace}/${vol_name} is attached but its workload is not running." 
                rm -f $clean_state
            fi
            sleep 0.5
        done
    }

    if [ -e $clean_state ]; then
        log_verbose "There is no stale Longhorn volume."
        rm $clean_state
        log_info "Stale-Longhorn-Volumes Test: Pass"
        echo -e "\n==============================\n"
    else
        log_verbose "There are stale volumes."
        record_fail "Stale-Longhorn-Volumes"
    fi
}

check_error_pods()
{
    log_info "Starting Pod Status check..."

    pods=$(kubectl get pods -A -o yaml)
    no_ok=$(echo "$pods" | yq '.items | any_c(.status.phase != "Running" and .status.phase != "Succeeded")')

    if [ "$no_ok" = "false" ]; then
        log_verbose "All pods are OK."
        log_info "Pod-Status Test: Pass"
        echo -e "\n==============================\n"
        return
    fi

    log_info "There are non-ready pods:"
    log_info "$(echo "$pods" | yq '.items[] | select(.status.phase != "Running" and .status.phase != "Succeeded") | .metadata.namespace + "/" + .metadata.name')"
    record_fail "Pod-Status"
}

# Only works in Harvester nodes.
check_free_space()
{
    prom_ip=$(kubectl get services/rancher-monitoring-prometheus -n cattle-monitoring-system -o yaml | yq -e '.spec.clusterIP')
    result=$(curl -sg "http://$prom_ip:9090/api/v1/query?query=node_filesystem_avail_bytes{mountpoint=\"/usr/local\"}<32212254720" | jq '.data.result')

    length=$(echo "$result" | jq 'length')

    if [ "$length" == "0" ]; then
        log_verbose "All nodes have more than 30GB free space."
        log_info "Node-Free-Space Test: Pass"
        echo -e "\n==============================\n"
        return
    fi

    log_info "Nodes doesn't have enough free space:"
    log_info "$(echo "$result" | jq -r '.[].metric.instance')"
    record_fail "Node-Free-Space"
}

#If a log file exists ask users if they want to clear it, or exit. 
check_log_file()
{
    if [ -e $log_file ]; then
        # Just clear the file if run with -y
        if [ "$answer" = true ]; then
            echo -e "[$(date +'%Y-%m-%d %H:%M:%S')] Cleared Previous Log File" >> "$log_file"
            return
        fi
        read -r -p "The file $log_file exists. Are you sure that you want to overwrite/clear the contents of that file? [Y/N]" response
        if [[ "$response" =~ ^([yY][eE][sS]|[yY])$ ]]; then
            echo "Cleared Stale Log File" > $log_file
            return
        else
            echo -e "Choose a different filename for the log flag (-l) or move/rename the file and run the script again. \nExiting."
            exit 1
        fi
    fi
}

# Are we running the script on a control-plane node?
check_host()
{
    log_info "Starting Host check... "
    cp_nodes=$(kubectl get nodes |grep control-plane |awk '{ print $1 }')
    log_verbose "The hostname is: $(hostname)"
    log_verbose "Controlplane nodes are:\n${cp_nodes}"
    log_verbose "The OS release is: $(awk -F= '$1=="PRETTY_NAME" { print $2 ;}' /etc/os-release)"
    # Just continue if -y was supplied
    if [  "$answer" = true ]; then
        log_info "Host Test: Skipped"
        echo -e "\n==============================\n"
        return
    fi
    # Ask the user if they want to contine if the host isn't one of the cp nodes. 
    if [[ $cp_nodes == *"$(hostname)"* ]]; then
        log_info "Host Test: Passed"    
    else
        log_info "This script is intended to be run from one of the Harvester cluster's Control Plane nodes."
        log_info "It seems like you're running this script from $(hostname) and not one of the following nodes:\n${cp_nodes}"
        read -r -p "Do you want to contiue running this script even though it seems like you're not on a node? [Y/N] " response
        if [[ "$response" =~ ^([yY][eE][sS]|[yY])$ ]]; then
            log_info "Host Test: Skipped"
            echo -e "\n==============================\n"
        else
            log_info "Run this script again from one of the nodes listed above."
            exit 1
        fi
    fi
}

check_log_file

log_verbose "Script has started"
echo -e "==============================\n"
check_host
check_bundles
check_harvester_bundle
check_nodes
check_cluster
check_machines
check_volumes
check_attached_volumes
check_error_pods
check_free_space

if [ $check_failed -gt 0 ]; then
    log_info "WARN: There are $check_failed failing checks: ${failed_check_names}"
    exit 1
else
    log_info "All checks have pass."
fi
