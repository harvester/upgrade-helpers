#!/bin/bash -e

# Verify all harvester nodes can communicate to all other harvester nodes over the storage network.
# Automation of step 4 from https://docs.harvesterhci.io/latest/advanced/storagenetwork#step-4
# Requires kubectl and an active context for the harvester cluster.
# Can be run on a harvester management node.

set -o pipefail

NAMESPACE=longhorn-system
SELECTOR=longhorn.io/component=instance-manager
STORAGE_NIC=lhnet1

get_pod_records() {
  kubectl get pods -n "$NAMESPACE" -l "$SELECTOR" -o json |
    jq -r '
      .items[] |
      . as $pod |
      ($pod.metadata.annotations["k8s.v1.cni.cncf.io/network-status"] // "[]" | fromjson) as $netstatus |
      ($netstatus | map(select(.name | startswith("harvester-system")))) as $storage |
      if ($storage | length) != 1 then
        error("\($pod.metadata.name): expected exactly 1 storage network attachment, found \($storage | length)")
      else
        [$pod.metadata.name, $pod.spec.nodeName, $storage[0].ips[0], $storage[0].mac] | @tsv
      end
    '
}

get_storage_network_mtu() {
  kubectl exec -n "$NAMESPACE" "${POD_NAMES[0]}" -- \
    ip -o link show dev "$STORAGE_NIC" |
    awk '{for(i=1;i<=NF;i++) if($i=="mtu"){print $(i+1); exit}}'
}

start_webservers() {
  for i in "${!POD_NAMES[@]}"; do
    local pod_name="${POD_NAMES[$i]}"
    local pod_ip="${POD_IPS[$i]}"
    echo "Starting webserver on $pod_name"
    kubectl exec -n $NAMESPACE "$pod_name" -- python3 -m http.server 8000 --bind "$pod_ip" &>/dev/null &
    WEBSERVER_PIDS+=("$!")
  done
}

stop_webservers() {
  echo ""
  echo "Stopping webservers"
  for pid in "${WEBSERVER_PIDS[@]}"; do
    kill "$pid" &>/dev/null || true
  done
  for pod_name in "${POD_NAMES[@]}"; do
    echo "Killing webserver on $pod_name"
    kubectl exec -n $NAMESPACE "$pod_name" -- pkill -f 'python3 -m http.server 8000' &>/dev/null || true
  done
}

verify_connectivity() {
  echo ""
  echo "Verifying connectivity between webservers"
  for i in "${!POD_NAMES[@]}"; do
    for j in "${!POD_IPS[@]}"; do
      echo "Checking ${POD_NODES[$i]} <-> ${POD_NODES[$j]}"
      if ! kubectl exec -n $NAMESPACE "${POD_NAMES[$i]}" -- curl "${POD_IPS[$j]}:8000" -m 1 &>/dev/null; then
        echo "Connection failed"
        FAILED=1
      fi
    done
  done
}

copy_ping() {
  echo ""
  echo "Copying ping"
  local ping_bin
  ping_bin="$(readlink -f "$(which ping)")"
  for pod_name in "${POD_NAMES[@]}"; do
    kubectl -n $NAMESPACE cp "$ping_bin" "$pod_name:/tmp/ping"
  done
  wait
}

remove_ping() {
  echo ""
  for pod_name in "${POD_NAMES[@]}"; do
    echo "Removing ping on $pod_name"
    kubectl exec -n $NAMESPACE "$pod_name" -- rm /tmp/ping &>/dev/null || true
  done
}

check_mtu() {
  echo ""
  echo "Checking MTU $MTU"
  local ping_size=$((MTU - 28)) # 28 for packet headers in ping
  for i in "${!POD_NAMES[@]}"; do
    for j in "${!POD_IPS[@]}"; do
      echo "Checking ${POD_NODES[$i]} <-> ${POD_NODES[$j]}"
      # shellcheck disable=SC1010 # -M do is a literal ping flag, not a shell keyword
      if ! kubectl exec -n $NAMESPACE "${POD_NAMES[$i]}" -- /tmp/ping -c 4 -w 4 -M do -s "$ping_size" "${POD_IPS[$j]}" -t 4 &>/dev/null; then
        echo "Connection failed"
        FAILED=1
      fi
    done
  done
}

echo "Getting instance manager pod records"
pod_records="$(get_pod_records)"

POD_NAMES=()
POD_NODES=()
POD_IPS=()
POD_MACS=()
mapfile -t pod_record_lines <<<"$pod_records"
for line in "${pod_record_lines[@]}"; do
  IFS=$'\t' read -r name node ip mac <<<"$line"
  POD_NAMES+=("$name")
  POD_NODES+=("$node")
  POD_IPS+=("$ip")
  POD_MACS+=("$mac")
done

if [ -z "${MTU:-}" ]; then
  echo "Deriving MTU from $STORAGE_NIC on ${POD_NAMES[0]}"
  MTU="$(get_storage_network_mtu)"
fi
echo "Using MTU $MTU"

echo "Debug info"
for i in "${!POD_NAMES[@]}"; do
  echo -e "${POD_NAMES[$i]}\t${POD_MACS[$i]}\t${POD_IPS[$i]}\t${POD_NODES[$i]}"
done

FAILED=0
WEBSERVER_PIDS=()
trap stop_webservers EXIT

echo ""
echo "Starting webservers"
start_webservers
sleep 6

verify_connectivity

trap - EXIT
stop_webservers

trap remove_ping EXIT
copy_ping
check_mtu

echo ""
if [ "$FAILED" -ne 0 ]; then
  echo "Finished: storage network check FAILED"
  exit 1
fi
echo "Finished: storage network check passed"
