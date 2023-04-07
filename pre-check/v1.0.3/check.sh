#!/bin/bash -e

check_failed=0

record_fail()
{
    check_failed=$((check_failed+1))
}


check_bundles()
{
    echo ">>> Check all bundles ready..."

    # fleet bundles should be ready
    # except mcc-harvester, which has Modified status in 1.0.3
    bundles=$(kubectl get bundles.fleet.cattle.io -A -o yaml)
    pending=$(echo "$bundles" | yq '.items | any_c(.metadata.name != "mcc-harvester" and .spec.helm != null and .status.summary.ready == 0)')

    if [ "$pending" = "false" ]; then
      echo "All Helm bundles are ready."
      return
    fi

    echo "There are non-ready Helm bundles:"
    echo "$bundles" | yq '.items[] | select(.spec.helm != null and .status.summary.ready == 0) | .metadata.namespace + "/" + .metadata.name'
    record_fail
}

check_harvester_bundle()
{
    echo ">>> Check the Harvester bundle is ready..."

    current_summary=$(mktemp)
    kubectl get bundles.fleet.cattle.io/mcc-harvester -n fleet-local -o yaml | yq '.status.summary' > $current_summary

    expected_summary=$(mktemp)
cat > $expected_summary <<EOF
desiredReady: 1
modified: 1
nonReadyResources:
  - bundleState: Modified
    modifiedStatus:
      - apiVersion: v1
        kind: ConfigMap
        missing: true
        name: longhorn-storageclass
        namespace: longhorn-system
    name: fleet-local/local
ready: 0
EOF

    if ! diff <(yq -P 'sort_keys(..)' $current_summary) <(yq -P 'sort_keys(..)' $expected_summary); then
        echo "Harvester bundle is not ready!"
        cat $current_summary
        record_fail
        return
    fi

    echo "The Harvester bundle is ready."
}

check_nodes()
{
    local failed="false"
    echo ">>> Check all nodes are ready..."

    # Use a file to store the node state becuase we can't set the global variable inside the piped scope
    # The file is removed in the piped scope if there are not-ready nodes.
    node_ready_state=$(mktemp)

    # nodes should not be cordoned
    nodes=$(kubectl get nodes -o yaml)
    unschedulable=$(echo "$nodes" | yq '.items | any_c(.spec.unschedulable == true)')

    if [ "$unschedulable" = "true" ]; then
        echo "There are unschedulable nodes:"
        echo "$nodes" | yq '.items[] | select(.spec.unschedulable == true)  | .metadata.name'
        rm -f $node_ready_state
    fi

    # nodes should be ready
    echo "$nodes" | yq .items[].metadata.name |
        while read -r node_name; do
            node_ready=$(kubectl get nodes $node_name -o yaml | yq '.status.conditions | any_c(.type == "Ready" and .status == "True")')

            if [ "$node_ready" = "false" ]; then
                echo "Node $node_name is not ready!"
                rm -f $node_ready_state
            fi
        done

    if [ -e $node_ready_state ]; then
        echo "All nodes are ready."
        rm $node_ready_state
    else
        echo "There are non-ready nodes."
        record_fail
    fi
}

check_cluster()
{
    echo ">>> Check the CAPI cluster is provisioned..."
    cluster_phase=$(kubectl get clusters.cluster.x-k8s.io/local -n fleet-local -o yaml | yq '.status.phase')

    # cluster should be in provisioned
    if [ "$cluster_phase" != "Provisioned" ]; then
        echo "Cluster is not provisioned ($cluster_phase)"
        record_fail
        return
    fi

    echo "The CAPI cluster is provisioned."
}

check_machines()
{
    local failed="false"
    echo ">>> Check the CAPI machines count..."

    # machine count should be equal to node counts
    machine_count=$(kubectl get machines.cluster.x-k8s.io -n fleet-local -o yaml | yq '.items | length')
    node_count=$(kubectl get nodes -o yaml | yq '.items | length')
    if [ $machine_count -ne $node_count ]; then
        echo "CAPI machine count is not equal to node count. There are orphan machines."
        kubectl get nodes
        kubectl get machines.cluster.x-k8s.io -n fleet-local
        record_fail
    else
        echo "CAPI machine count is equal to node count."
    fi

    echo ">>> Check the CAPI machines are running..."

    # Use a file to store the machine state becuase we can't set the global variable inside the piped scope
    # The file is removed in the piped scope if there are not-ready machines.
    machine_ready_state=$(mktemp)

    # all machines need to be provisioned
    kubectl get machines.cluster.x-k8s.io -n fleet-local -o yaml | yq '.items[].metadata.name' |
        while read -r machine_name; do
            machine_phase=$(kubectl get machines.cluster.x-k8s.io/$machine_name -n fleet-local -o yaml | yq '.status.phase')

            if [ "$machine_phase" != "Running" ]; then
                echo "CAPI machine $machine_name phase is not Running ($machine_phase)."
                rm -f $machine_ready_state
            fi
        done

    if [ -e $machine_ready_state  ]; then
        echo "The CAPI machines are provisioned."
        rm $machine_ready_state
    else
        echo "There are non-ready CAPI machines."
        record_fail
    fi
}

check_volumes()
{
    echo ">>> Check Longhorn volumes..."

    node_count=$(kubectl get nodes -o yaml | yq '.items | length')

    if [ $node_count -eq 1 ]; then
        echo "Skip checking for single node cluster."
        return
    fi

    # Use a file to store the healthy state becuase we can't set the global variable inside the piped scope
    # The file is removed in the piped scope if there are any degraded volumes.
    healthy_state=$(mktemp)

    # For each running engine and its volume
    kubectl get engines.longhorn.io -n longhorn-system -o json |
        jq -r '.items | map(select(.status.currentState == "running")) | map(.metadata.name + " " + .metadata.labels.longhornvolume) | .[]' | {
            while read -r lh_engine lh_volume; do
                echo checking running engine "${lh_engine}..."

                if [ $node_count -gt 2 ];then
                    robustness=$(kubectl get volumes.longhorn.io/$lh_volume -n longhorn-system -o jsonpath='{.status.robustness}')
                    if [ "$robustness" = "healthy" ]; then
                        echo "Volume $lh_volume is healthy."
                    else
                        echo "Volume $lh_volume is degraded."
                        rm -f $healthy_state
                    fi
                else
                    # two node situation, make sure maximum two replicas are healthy
                    expected_replicas=2

                    # replica 1 case
                    volume_replicas=$(kubectl get volumes.longhorn.io/$lh_volume -n longhorn-system -o jsonpath='{.spec.numberOfReplicas}')
                    if [ $volume_replicas -eq 1 ]; then
                        expected_replicas=1
                    fi

                    ready_replicas=$(kubectl get engines.longhorn.io/$lh_engine -n longhorn-system -o json |
                                    jq -r '.status.replicaModeMap | to_entries | map(select(.value == "RW")) | length')
                    if [ $ready_replicas -ge $expected_replicas ]; then
                        echo "Volume $lh_volume is healthy."
                    else
                        echo "Volume $lh_volume is degraded."
                        rm -f $healthy_state
                    fi
                fi
                sleep 0.5
            done
        }

    if [ -e $healthy_state ]; then
        echo "All volumes are healthy."
        rm $healthy_state
    else
        echo "There are degraded volumes."
        record_fail
    fi
}

# https://github.com/harvester/harvester/issues/3648
check_attached_volumes()
{
    echo ">>> Check stale Longhorn volumes..."

    # Use a file to store the clean state becuase we can't set the global variable inside the piped scope
    # The file is removed in the piped scope if any volume is stale.
    clean_state=$(mktemp)

    volumes=$(kubectl get volumes.longhorn.io -A -o yaml)
    # for each attached volume
    echo "$volumes" | yq '.items[] | select(.status.state == "attached") | .metadata.namespace + " " + .metadata.name' | {
        while read -r vol_namespace vol_name; do
            echo "Checking volume $vol_namespace/$vol_name..."

            # check .status.kubernetesStatus.workloadStatus is nil
            workloads=$(kubectl get volumes.longhorn.io/$vol_name -n $vol_namespace -o yaml | yq '.status.kubernetesStatus.workloadsStatus | length')
            if [ "$workloads" = "0" ]; then
                echo "Volume $vol_namespace/$vol_name is attached but has no workload."
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
                echo "Volume $vol_namespace/$vol_name is attached but its workload is not running." 
                rm -f $clean_state
            fi
            sleep 0.5
        done
    }

    if [ -e $clean_state ]; then
        echo "There is no stale Longhorn volume."
        rm $clean_state
    else
        echo "There are stale volumes."
        record_fail
    fi
}

check_error_pods()
{
    echo ">>> Check error pods..."

    pods=$(kubectl get pods -A -o yaml)
    no_ok=$(echo "$pods" | yq '.items | any_c(.status.phase != "Running" and .status.phase != "Succeeded")')

    if [ "$no_ok" = "false" ]; then
        echo "All pods are OK."
        return
    fi

    echo "There are non-ready pods:"
    echo "$pods" | yq '.items[] | select(.status.phase != "Running" and .status.phase != "Succeeded") | .metadata.namespace + "/" + .metadata.name'
    record_fail
}

# only works in Harvester nodes
check_free_space()
{
    prom_ip=$(kubectl get services/rancher-monitoring-prometheus -n cattle-monitoring-system -o yaml | yq -e '.spec.clusterIP')
    result=$(curl -sg "http://$prom_ip:9090/api/v1/query?query=node_filesystem_avail_bytes{mountpoint=\"/usr/local\"}<32212254720" | jq '.data.result')

    length=$(echo "$result" | jq 'length')

    if [ "$length" == "0" ]; then
        echo "All nodes have more than 30GB free space."
        return
    fi

    echo "Nodes doesn't have enough free space:"
    echo "$result" | jq -r '.[].metric.instance'
    record_fail
}

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
    echo ""
    echo "There are $check_failed failing checks!"
    exit 1
else
    echo ""
    echo "All checks pass."
fi
