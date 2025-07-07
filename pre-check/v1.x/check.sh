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
failed_check_name=''

record_fail()
{
    check_failed=$((check_failed+1))
    failed_check_names="${failed_check_names} ${1}"
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
    log_info "Starting Helm Bundle status check... "

    # fleet bundles should be ready
    # except mcc-harvester, which has Modified status in 1.0.3
    bundles=$(kubectl get bundles.fleet.cattle.io -A -o yaml)
    pending=$(echo "$bundles" | yq '.items | any_c(.metadata.name != "mcc-harvester" and .spec.helm != null and .status.summary.ready == 0)')

    if [ "$pending" = "false" ]; then
      log_verbose "All Helm Bundles are ready."
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
    log_info "Starting Harvester Bundle status check..."

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
    log_verbose "All Harvester Bundles are ready."
    log_info "Harvester-Bundles Test: Pass"
    echo -e "\n==============================\n"
}

check_nodes()
{
    local failed="false"
    log_info "Starting Node Status check... "

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

    if [ -e "$node_ready_state" ]; then
        log_verbose "All nodes are ready."
        log_info "Node-Status Test: Pass"
        echo -e "\n==============================\n"
        rm $node_ready_state
    else
        log_verbose "There are non-ready nodes."
        record_fail "Node-Status"
    fi


    # We should check if the Longhorn node has the EvictionRequested flag. If setted to true, will cause a Race Condition.
    # For more info, see https://github.com/harvester/harvester/issues/7717
    log_info "Verifying Longhorn node and disk eviction status..."
    evacuation_found=false
    for node in $(kubectl get nodes.longhorn.io -n longhorn-system -o jsonpath='{.items[*].metadata.name}'); do
        node_eviction_requested=$(kubectl get nodes.longhorn.io -n longhorn-system "$node" -o jsonpath='{.spec.evictionRequested}')

        if [ "$node_eviction_requested" = "true" ]; then
            log_error "Node '$node' has EvictionRequested set to true."
            evacuation_found=true
        fi

        disks_with_eviction=$(kubectl get nodes.longhorn.io -n longhorn-system "$node" -o yaml | yq e '.spec.disks | to_entries | .[] | select(.value.evictionRequested == true) | .key')
        
        if [ -z "$disks_with_eviction"]; then
            log_info "No disks with eviction requested were found on node $node.."
        else
            log_error "The following disks have 'evictionRequetested' set to 'true' on node $node.:"
            echo "$disks_with_eviction"
            evacuation_found=true
        fi
    done

    if [ "$evacuation_found" = "false" ]; then
        log_info "No nodes or disks with EvictionRequested=true found. It is safe to proceed with the upgrade."
    else
        echo "Error: One or more nodes or disks have EvictionRequested set to true. Please resolve this before upgrading."
        exit 1
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

    if [ -e "$machine_ready_state"  ]; then
        log_verbose "The CAPI machines are provisioned."
        log_info "CAPI-Machine-State Test: Pass"
        echo -e "\n==============================\n"
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
        jq -r '.items | map(.metadata.name + " " + .metadata.labels.longhornvolume) | .[]' | {
            while read -r lh_engine lh_volume; do
                log_verbose "Checking engine: ${lh_engine}"

                volume_json=$(kubectl get volumes.longhorn.io/$lh_volume -n longhorn-system -o json 2>/dev/null || true)
                if [ -z "$volume_json" ]; then
                    log_info "Volume ${lh_volume} not found."
                    continue
                fi
                # single-replica volumes should be handled exclusively
                volume_replicas=$(echo $volume_json | jq -r '.spec.numberOfReplicas')
                if [ $volume_replicas -eq 1 ]; then
                    state=$(echo $volume_json | jq -r '.status.state')
                    if [ "$state" = "create" ] || [ "$state" = "attaching" ] || [ "$state" = "attached" ]; then
                        log_info "Volume ${lh_volume} is a single-replica volume in running state, it will block node drain. Please consider adjusting its replica count before upgrading."
                    else
                        log_info "Volume ${lh_volume} is a single-replica volume in detached state, it will block node drain before v1.4.0. For upgrades starting from v1.4.0, though node draining will not be blocked, the upgrade may still have potential data integrity concerns. Please consider adjusting its replica count before upgrading."
                    fi
                    rm -f $healthy_state
                else
                    robustness=$(echo $volume_json | jq -r '.status.robustness')
                    state=$(echo $volume_json | jq -r '.status.state')
                    if [ "$robustness" = "healthy" ]; then
                        log_verbose "Volume ${lh_volume} is healthy."
                    elif [ "$state" = "detached" ]; then
                        replica_count=$(kubectl get replicas -n longhorn-system -l longhornvolume=$lh_volume -o json | jq '.items | length')
                        if [ $replica_count -lt $volume_replicas ]; then
                            log_info "Detached Longhorn Volume: ${lh_volume} should have ${volume_replicas} replicas, but only has ${replica_count}."
                            rm -f $healthy_state
                        else
                            log_verbose "Detached Longhorn Volume found: ${lh_volume}"
                        fi
                    else
                        log_info "Degraded Longhorn Volume found: ${lh_volume}"
                        rm -f $healthy_state
                    fi
                fi
                sleep 0.5
            done
        }

    if [ -e "$healthy_state" ]; then
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
                log_info "Volume $vol_name is attached but has no workload."
                rm -f $clean_state
                sleep 0.5
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
                log_info "Volume ${vol_name} is attached, but one or more of its workloads is not running."
                log_verbose "Details of the workloads:\n$(kubectl get volumes.longhorn.io/$vol_name -n $vol_namespace -o yaml | yq '.status.kubernetesStatus.workloadsStatus')"
                rm -f $clean_state
            fi
            sleep 0.5
        done
    }
    if [ -e "$clean_state" ]; then
        log_verbose "There are no stale Longhorn volumes."
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
    no_ok=$(echo "$pods" | yq '.items[] | select(.status.conditions | any_c(.type == "Ready" and .status == "False" and .reason != "PodCompleted"))')

    if [ -z "$no_ok" ]; then
        log_verbose "All pods are OK."
        log_info "Pod-Status Test: Pass"
        echo -e "\n==============================\n"
        return
    fi

    log_info "There are non-ready pods:"
    log_info "$(echo "$pods" | yq '.items[] | select(.status.conditions | any_c(.type == "Ready" and .status == "False" and .reason != "PodCompleted")) | .metadata.namespace + "/" + .metadata.name')"
    record_fail "Pod-Status"
}

# Only works in Harvester nodes.
check_free_space()
{
    log_info "Starting Node Free Space check..."

    # Get all secrets in the cattle-system namespace and filter the first one with "generateName: rancher-token-"
    secret=$(kubectl get secrets -n cattle-system -o yaml | yq '.items[] | select(.metadata.generateName == "rancher-token-") | .data.token' | head -n 1)

    if [[ -z "$secret" ]]; then
        log_info "WARN: The script wasn't able to find a valid rancher-token secret, so it could not validate that there is sufficent freespace to complete the upgrade. To verify this test manually, log into each of the nodes and run 'df -h /usr/local' to ensure there's more than 30 GB of free space available."
        log_info "Node-Free-Space Test: SKIPPED"
        echo -e "\n==============================\n"
        return
    fi

    token=$(echo "$secret" | base64 -d)

    # Use a file to store the disk space state becuase we can't set the global variable inside the piped scope
    # The file is removed in the piped scope if there are any node without enough disk space.
    disk_space_state=$(mktemp)

    # For each running engine and its volume
    kubectl get nodes -o json |
        jq -r '.items | map(.metadata.name + " " + (.metadata.annotations["rke2.io/internal-ip"] // "null") + " " + (.status.daemonEndpoints.kubeletEndpoint.Port | tostring)) | .[]' | {
            while read -r node_name node_ip kubelet_port; do
                log_verbose "Checking node: ${node_name} with IP: ${node_ip} and Kubelet Port: ${kubelet_port}"

                # Skip the test if the variable is empty or literal "null"
                if [[ -z "$node_ip" ||  "$node_ip" == "null" || -z "$kubelet_port" ]]; then
                    log_info "WARN: The script wasn't able to find a valid IP/Port for the node ${node_name}, so it could not validate that there is sufficent freespace to complete the upgrade. To verify this test manually, log into each of the nodes and run 'df -h /usr/local' to ensure there's more than 30 GB of free space available."
                    continue
                fi

                stat_summary=$(curl -sk https://${node_ip}:${kubelet_port}/stats/summary -H "Authorization: Bearer ${token}" | jq .node.fs)
                used_bytes=$(echo "$stat_summary" | jq '.usedBytes')
                capacity_bytes=$(echo "$stat_summary" | jq '.capacityBytes')

                if [ -z "$used_bytes" ] || [ -z "$capacity_bytes" ]; then
                    log_info "WARN: The script wasn't able to get valid response from the API for the node ${node_name}, so it could not validate that there is sufficent freespace to complete the upgrade. To verify this test manually, log into each of the nodes and run 'df -h /usr/local' to ensure there's more than 30 GB of free space available."
                    continue
                fi

                # New images usage will be around 13GB (13 * 1024 * 1024 * 1024 bytes).
                # If used space + 13GB is more than 85% of the capacity, then the node doesn't have enough free space.
                if awk -v used="$used_bytes" -v cap="$capacity_bytes" 'BEGIN {exit !(((used + 13958643712) / cap) > 0.85)}'; then
                    log_info "Node ${node_name} doesn't have enough free space."
                    log_info "Used: $(awk -v used="$used_bytes" 'BEGIN {printf "%.2f", used/1024/1024/1024}') GB"
                    log_info "Capacity: $(awk -v cap="$capacity_bytes" 'BEGIN {printf "%.2f", cap/1024/1024/1024}') GB"
                    rm -f $disk_space_state
                fi
            done
        }

    if [ -e "$disk_space_state" ]; then
        log_verbose "All nodes have enough free space to load new images."
        log_info "Node-Free-Space Test: Pass"
        echo -e "\n==============================\n"
        rm $disk_space_state
    else
        log_info "There are nodes without enough free space to load new images!"
        record_fail "Node-Free-Space"
    fi
}

#If a log file exists ask users if they want to clear it, or exit.
check_log_file()
{
    if [ -e "$log_file" ]; then
        # Just clear the file if run with -y
        if [ "$answer" = true ]; then
            echo -e "[$(date +'%Y-%m-%d %H:%M:%S')] Cleared Previous Log File" > "$log_file"
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
    cp_nodes=$(kubectl get nodes -l node-role.kubernetes.io/control-plane=true -o name | cut -d'/' -f2)
    log_verbose "The hostname is: $(hostname)"
    log_verbose "Controlplane nodes are:\n${cp_nodes}"
    log_verbose "The OS release is: $(awk -F= '$1=="PRETTY_NAME" { print $2 ;}' /etc/os-release)"
    # Ask the user if they want to continue if the host isn't one of the cp nodes.
    if [[ $cp_nodes == *"$(hostname)"* ]]; then
        log_info "Host Test: Pass"
            echo -e "\n==============================\n"
    # Just continue if -y was supplied
    elif [  "$answer" = true ]; then
        log_info "Host Test: Skipped"
        echo -e "\n==============================\n"
        return
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

# Check that local-kubeconfig secret has a label to avoid a known issue where the upgrade gets stuck.
# https://docs.harvesterhci.io/v1.3/upgrade/v1-2-2-to-v1-3-1#known-issues
check_kubeconfig_secret()
{
    log_info "Starting Kubeconfig Secret check..."
    # Get all the secrets with the label selector.
    secrets=$(kubectl get secrets -n fleet-local --selector cluster.x-k8s.io/cluster-name=local)
    # If  local-kubeconfig is in the list, the test passed.
    if [[ $secrets == *"local-kubeconfig"* ]]; then
        log_info "Kubeconfig Secret Test: Pass"
        echo -e "\n==============================\n"
    else
        log_info "Couldn't find the appropriate label on the local-kubeconfig secret.\nThere is a known issue, where the missing label causes upgrades to stall:\n https://docs.harvesterhci.io/v1.3/upgrade/v1-2-2-to-v1-3-1#known-issues\nHINT: This can be resolved by running\n'kubectl label secret local-kubeconfig -n fleet-local cluster.x-k8s.io/cluster-name=local'"
        record_fail "Kubeconfig-Secret"
    fi
}

# https://github.com/harvester/harvester/issues/3863
# Certs might be expired if the services have not restarted and auto-updated.
# This will ONLY work from the current node.
check_certs()
{
    log_info "Starting Certificates check..."
    log_verbose "NOTE: This only checks certs on the current node. Typically certs rotate automatically before they're set to expire when the RKE service restarts or the node is rebooted."
    # If the cert directory doesn't exist, then we're not on CP node.
    if [ ! -d "/var/lib/rancher/rke2/server/tls" ]; then
        log_info "WARN: The cert directory could not be found. This script should be run from one of the controlplane nodes. Are you sure you're on a CP node?"
        record_fail "Certificates"
        return
    fi
    # Set this to "false"
    expired_certs=1
    # Get a list of all the RKE certs.
    certs_list=$(find /var/lib/rancher/rke2/server/tls/ -name *.crt)
    log_verbose "Found the following certs: ${certs_list}"
    if [[ -z ${certs_list} ]]; then
        log_info "WARN: No certs found to be checked. Are you sure you're on a CP node?"
        record_fail "Certificates"
        return
    fi
    for cert in $certs_list; do
        # If the cert is expired, fail the test and report the info.
        if ! openssl x509 -in $cert -noout -checkend 0 > /dev/null ; then
            log_info "$cert has already expired."
            # Set the var to "true"
            expired_certs=0
            log_verbose "${cert} info:\n$(openssl x509 -text -in $cert | grep -A 2 Validity)"
        else
            log_verbose "${cert} is valid."
        fi
    done
    # If expired_certs is 'true' ( 0 ) then fail the test.
    if [[ ${expired_certs} == 0 ]]; then
        # Give possible solution from GitHub issue and fail the test.
        log_info "One or more of your certificates have already expired. \nTypically certs should auto-renew when the RKE service is restarted (This can also happen when you reboot a node) \nYou can also trigger a rotation of all a nodes' service certificates by running: \nkubectl edit clusters.provisioning.cattle.io local -n fleet-local \nand adding +=1 to the spec.rkeConfig.rotateCertificates.generation field or set it to 1 if it's missing. \nThis should be done before an upgrade. If an upgrade is already in process you might follow the workaround listed in this GitHub Issue: \nhttps://github.com/harvester/harvester/issues/3863#issuecomment-1539681311"
        record_fail "Certificates"
        return
    fi
    # Check to see if any certs are expiring in the next 10 days and throw a warning.
    for cert in $certs_list; do
        # If the cert will expire in 10 days, Throw a warning.
        if ! openssl x509 -in $cert -noout -checkend 864000 > /dev/null ; then
            log_info "WARN: $cert will expire in less than 10 days. Check logs/verbose for additional information."
            # Set the var to "true"
            log_verbose "${cert} info:\n$(openssl x509 -text -in $cert | grep -A 2 Validity)"
            log_verbose "Please remember that this ONLY checks certs on the node that you're running the script on. \nOther nodes may already have expired scripts. \nTypically certs should auto-renew when the RKE service is restarted (This can also happen when you reboot a node) \nYou can also trigger a rotation of all a nodes' service certificates by running: \nkubectl edit clusters.provisioning.cattle.io local -n fleet-local \nand adding +=1 to the spec.rkeConfig.rotateCertificates.generation field or set it to 1 if it's missing. \nThis should be done before an upgrade. If an upgrade is already in process you might follow the workaround listed in this GitHub Issue: \nhttps://github.com/harvester/harvester/issues/3863#issuecomment-1539681311"
        else
            log_verbose "${cert} is valid and does not expire soon."
        fi
    done
    log_info "Certificates Test: Pass"
    echo -e "\n==============================\n"
}

check_backup_target()
{
    log_info "Starting Backup Target check..."

    version=$(kubectl get settings.harvesterhci.io server-version -o json | jq -r '.value')

    if [ "$version" == "v1.4.1" ] || [ "$version" == "v1.4.2" ]; then
        type=$(kubectl get settings.harvesterhci.io backup-target -o json | jq -r '.value' | jq -r '.type')
        if [ $type == "null" ] || [ -z "$type" ]; then
            log_info "Backup Target Test: Pass"
            echo -e "\n==============================\n"
            return
        fi

        refreshIntervalInSeconds=$(kubectl get settings.harvesterhci.io backup-target -o json | jq -r '.value' | jq -r '.refreshIntervalInSeconds')
        if [ $refreshIntervalInSeconds == "null" ] || [ -z "$refreshIntervalInSeconds" ] || [ "$refreshIntervalInSeconds" -eq 0 ]; then
            log_info "The refreshIntervalInSeconds is either 0 or empty. Please configure it to a bigger integer like 300 before proceeding."
            record_fail "Backup-Target"
            return
        fi
    else
        log_info "The current version ($version) is not v1.4.1 or v1.4.2. Skip the Backup Target check."
        log_info "Backup Target Test: Skipped"
        echo -e "\n==============================\n"
        return
    fi

    log_info "Backup Target Test: Pass"
    echo -e "\n==============================\n"
}

# This throws a warning if the minimum number of copies for a backing image is less than the default (3) 
# Or if the minimum number of copies is set to '0' - it fails the test. VMs won't start if the backing image isn't available after upgrade.
check_images()
{
    log_info "Starting Longhorn Backing Images check..."

    version=$(kubectl get settings.harvesterhci.io server-version -o json | jq -r '.value')

    # Check if version is empty
    if [[ -z "$version" ]]; then
        log_error "Failed to retrieve server version. Exiting Longhorn Backing Images check."
        log_info "Longhorn-Backing-Images Test: Skipped"
        echo -e "\n==============================\n"
        return
    fi
    # If version is before v1.4.x, print a message and return
    if [[ $version =~ ^v(1\.[0-3])\..* ]]; then
        log_info "Current version ($version) is before v1.4.x. This check is not applicable."
        log_info "Longhorn-Backing-Images Test: Skipped"
        echo -e "\n==============================\n"
        return
    fi

    log_verbose "NOTE: This test will throw a warning if less than the default value and fail if minimum number of copies is set to 0."
    backingImageList=$(kubectl get backingImage -A  -o yaml | yq -r '.items[] | .metadata.name ')
    backingImageLowCount=$(kubectl get backingImage -A -ojsonpath='{.items[?(@.spec.minNumberOfCopies<3)].metadata.name}')
    backingImageNoMinCount=$(kubectl get backingImage -A -ojsonpath='{.items[?(@.spec.minNumberOfCopies==0)].metadata.name}')
    log_verbose "All the backingImages found: ${backingImageList}"
    log_verbose "Images with no min copies: ${backingImageNoMinCount}"
    log_verbose "Images with less than 3 copies: ${backingImageLowCount}"
    if [ -n "$backingImageNoMinCount" ]; then
        log_info "Some Backing images have no miniumum copies set: ${backingImageNoMinCount}"
        record_fail "Longhorn-Backing-Images"
    elif [ -n "$backingImageLowCount" ]; then
        log_info "Some images have less than the recommended minimum number of copies: ${backingImageLowCount}"
        log_info "Longhorn-Backing-Images Test: WARNING"
        echo -e "\n==============================\n"
    else
        log_verbose "All images have a minimum of 3 or more copies."
        rm -f $clean_state
        log_info "Longhorn-Backing-Images Test: Pass"
        echo -e "\n==============================\n"
    fi
}


check_log_file

log_verbose "Script has started"
echo -e "==============================\n"
check_host
check_certs
check_free_space
check_bundles
check_harvester_bundle
check_nodes
check_cluster
check_machines
check_volumes
check_attached_volumes
check_images
check_error_pods
check_kubeconfig_secret
check_backup_target

if [ $check_failed -gt 0 ]; then
    log_info "WARN: There are $check_failed failing checks:${failed_check_names}"
    exit 1
else
    log_info "All checks have passed."
fi
