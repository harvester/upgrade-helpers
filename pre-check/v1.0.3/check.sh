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

    # nodes should not be cordoned
    nodes=$(kubectl get nodes -o yaml)
    unschedulable=$(echo "$nodes" | yq '.items | any_c(.spec.unschedulable == true)')

    if [ "$unschedulable" = "true" ]; then
        echo "There are unschedulable nodes:"
        echo "$nodes" | yq '.items[] | select(.spec.unschedulable == true)  | .metadata.name'
        failed="true"
    fi

    # nodes should be ready
    echo "$nodes" | yq .items[].metadata.name |
        while read -r node_name; do
            node_ready=$(kubectl get nodes $node_name -o yaml | yq '.status.conditions | any_c(.type == "Ready" and .status == "True")')

            if [ "$node_ready" = "false" ]; then
                echo "Node $node_name is not ready!"
                failed="true"
            fi
        done

    if [ "$failed" = "true" ]; then
        record_fail
    else
        echo "All nodes are ready."
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
    echo ">>> Check the CAPI machines are running..."

    # all machines need to be provisioned
    kubectl get machines.cluster.x-k8s.io -n fleet-local -o yaml | yq '.items[].metadata.name' |
        while read -r machine_name; do
            machine_phase=$(kubectl get machines.cluster.x-k8s.io/$machine_name -n fleet-local -o yaml | yq '.status.phase')

            if [ "$machine_phase" != "Running" ]; then
                echo "CAPI machine $machine_name phase is not Running ($machine_phase)."
                failed="true"
            fi
        done

    if [ "$failed" = "true" ]; then
        record_fail
    else
        echo "The CAPI machines are provisioned."
    fi
}

check_volumes()
{
    echo ">>> Check Longhorn volumes..."

    volumes=$(kubectl get volumes.longhorn.io -A -o yaml)

    # all volumes should be healthy
    degraded=$(echo "$volumes" | yq '.items | any_c(.status.state == "attached" and .status.robustness != "healthy")')

    if [ "$degraded" = "false" ]; then
        echo "All volumes are healthy."
        return
    fi

    echo "There are non-healthy Longhorn volumes:"
    echo "$volumes" | yq '.items[] | select(.status.state == "attached" and .status.robustness != "healthy") | .metadata.namespace + "/" + .metadata.name'
    record_fail
}

# https://github.com/harvester/harvester/issues/3648
check_attached_volumes()
{
    echo ">>> Check stale Longhorn volumes..."

    volumes=$(kubectl get volumes.longhorn.io -A -o yaml)
    # for each attached volume
    echo "$volumes" | yq '.items[] | select(.status.state == "attached") | .metadata.namespace + " " + .metadata.name' | {
        while read -r vol_namespace vol_name; do
            echo "Checking volume $vol_namespace/$vol_name..."

            # check .status.kubernetesStatus.workloadStatus is nil
            workloads=$(kubectl get volumes.longhorn.io/$vol_name -n $vol_namespace -o yaml | yq '.status.kubernetesStatus.workloadsStatus | length')
            if [ "$workloads" = "0" ]; then
                echo "Volume $vol_namespace/$vol_name is attached but has no workload."
                has_stale="true"
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
                has_stale="true"
            fi

            sleep 1
        done

        if [ -n "$has_stale" ]; then
            record_fail
            return
        fi
    }

    echo "There is no stale Longhorn volume."
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
