#!/bin/bash

# Verify all Longhorn pods on the storage network can communicate with each other.
# Automation of step 4 from https://docs.harvesterhci.io/latest/advanced/storagenetwork#step-4
# Requires kubectl and an active context for the harvester cluster.
# Can be run on a harvester management node.

set -eo pipefail

NAMESPACE=longhorn-system
SELECTOR='longhorn.io/component in (instance-manager,backing-image-manager,backing-image-data-source)'
STORAGE_NIC=lhnet1
WEBSERVER_DIR=/tmp/storage-network-check
# Backing image pods already listen on 8000-8002.
WEBSERVER_PORT=9000

get_pod_records() {
  kubectl get pods -n "$NAMESPACE" -l "$SELECTOR" -o json |
    jq -r --arg nic "$STORAGE_NIC" '
      .items[] |
      . as $pod |
      ($pod.metadata.annotations["k8s.v1.cni.cncf.io/network-status"] // "[]" | fromjson) as $netstatus |
      ($netstatus | map(select(.interface == $nic))) as $storage |
      if $pod.status.phase != "Running" then
        [$pod.metadata.name, $pod.status.phase] | @tsv
      elif ($storage | length) != 1 then
        error("\($pod.metadata.name): expected exactly 1 storage network attachment, found \($storage | length)")
      else
        [$pod.metadata.name, $pod.status.phase, $pod.spec.nodeName, $storage[0].ips[0], ($storage[0].mac | ascii_downcase)] | @tsv
      end
    '
}

get_storage_network_mtu() {
  kubectl exec -n "$NAMESPACE" "$1" -- \
    ip -o link show dev "$STORAGE_NIC" |
    awk '{for(i=1;i<=NF;i++) if($i=="mtu"){print $(i+1); exit}}'
}

describe_pod() {
  echo "${POD_NAMES[$1]} (${POD_NODES[$1]})"
}

start_webservers() {
  WEBSERVER_DIRS=()
  for i in "${!POD_NAMES[@]}"; do
    local pod_name="${POD_NAMES[$i]}"
    local pod_ip="${POD_IPS[$i]}"
    local server_dir
    if ! server_dir="$(kubectl exec -n "$NAMESPACE" "$pod_name" -- \
      mktemp -d "$WEBSERVER_DIR.XXXXXX")"; then
      echo "Could not create webserver directory on $(describe_pod "$i")"
      FAILED=1
      continue
    fi
    WEBSERVER_DIRS[$i]="$server_dir"
    echo "Starting webserver on $pod_name"
    kubectl exec -n "$NAMESPACE" "$pod_name" -- sh -c '
      mkdir "$1/www" || exit 1
      cd "$1/www" || exit 1
      printf "%s\n" "$$" > "$1/server.pid" || exit 1
      exec python3 -m http.server "$3" --bind "$2"
    ' sh "$server_dir" "$pod_ip" "$WEBSERVER_PORT" &>/dev/null &
    WEBSERVER_PIDS[$i]="$!"
  done
}

stop_webservers() {
  echo ""
  echo "Stopping webservers"
  for pid in "${WEBSERVER_PIDS[@]}"; do
    kill "$pid" &>/dev/null || true
  done
  for i in "${!WEBSERVER_DIRS[@]}"; do
    local pod_name="${POD_NAMES[$i]}"
    local server_dir="${WEBSERVER_DIRS[$i]}"
    echo "Stopping webserver on $pod_name"
    kubectl exec -n "$NAMESPACE" "$pod_name" -- sh -c '
      pid="$(cat "$1/server.pid")" || exit 0
      [ "$(readlink "/proc/$pid/cwd")" = "$1/www" ] || exit 0
      kill "$pid"
    ' sh "$server_dir" &>/dev/null || true
    kubectl exec -n "$NAMESPACE" "$pod_name" -- \
      rm -rf "$server_dir" &>/dev/null || true
  done
}

check_webservers_running() {
  for i in "${!WEBSERVER_PIDS[@]}"; do
    if ! kill -0 "${WEBSERVER_PIDS[$i]}" &>/dev/null; then
      echo "Webserver failed to start on $(describe_pod "$i")"
      FAILED=1
    fi
  done
}

verify_connectivity() {
  echo ""
  echo "Verifying connectivity between webservers"
  for i in "${!POD_NAMES[@]}"; do
    for j in "${!POD_IPS[@]}"; do
      echo "Checking $(describe_pod "$i") <-> $(describe_pod "$j")"
      if ! kubectl exec -n $NAMESPACE "${POD_NAMES[$i]}" -- curl "${POD_IPS[$j]}:$WEBSERVER_PORT" -m 1 &>/dev/null; then
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
      echo "Checking $(describe_pod "$i") <-> $(describe_pod "$j")"
      # shellcheck disable=SC1010 # -M do is a literal ping flag, not a shell keyword
      if ! kubectl exec -n $NAMESPACE "${POD_NAMES[$i]}" -- /tmp/ping -c 4 -i 0.2 -w 4 -M do -s "$ping_size" "${POD_IPS[$j]}" -t 4 &>/dev/null; then
        echo "Connection failed"
        FAILED=1
      fi
    done
  done
}

check_duplicates() {
  echo ""
  echo "Checking for duplicate storage network IPs and MACs"
  local dupe
  while read -r dupe; do
    echo "Duplicate $dupe on:"
    for i in "${!POD_NAMES[@]}"; do
      if [ "${POD_IPS[$i]}" = "$dupe" ] || [ "${POD_MACS[$i]}" = "$dupe" ]; then
        echo "  $(describe_pod "$i")"
      fi
    done
    FAILED=1
  done < <(printf '%s\n' "${POD_IPS[@]}" "${POD_MACS[@]}" | sort | uniq -d)
}

# Detects another host, such as a second cluster on the same VLAN, answering for a pod IP.
verify_neighbour_macs() {
  echo ""
  echo "Verifying neighbour MACs match pod MACs"
  for i in "${!POD_NAMES[@]}"; do
    local neighbours
    if ! neighbours="$(kubectl exec -n "$NAMESPACE" "${POD_NAMES[$i]}" -- ip neigh show dev "$STORAGE_NIC")"; then
      echo "Could not read neighbours on $(describe_pod "$i")"
      FAILED=1
      continue
    fi
    for j in "${!POD_IPS[@]}"; do
      [ "$i" -eq "$j" ] && continue
      local mac
      mac="$(awk -v ip="${POD_IPS[$j]}" '$1 == ip {for(k=2;k<=NF;k++) if($k=="lladdr"){print tolower($(k+1)); exit}}' <<<"$neighbours")"
      if [ "$mac" != "${POD_MACS[$j]}" ]; then
        echo "$(describe_pod "$i") sees ${POD_IPS[$j]} at ${mac:-no MAC}, expected ${POD_MACS[$j]} for $(describe_pod "$j")"
        FAILED=1
      fi
    done
  done
}

echo "Getting Longhorn storage network pod records"
pod_records="$(get_pod_records)"

POD_NAMES=()
POD_NODES=()
POD_IPS=()
POD_MACS=()
mapfile -t pod_record_lines <<<"$pod_records"
for line in "${pod_record_lines[@]}"; do
  [ -z "$line" ] && continue
  IFS=$'\t' read -r name phase node ip mac <<<"$line"
  if [ "$phase" != "Running" ]; then
    echo "Skipping $name: $phase"
    continue
  fi
  POD_NAMES+=("$name")
  POD_NODES+=("$node")
  POD_IPS+=("$ip")
  POD_MACS+=("$mac")
done
if [ "${#POD_NAMES[@]}" -eq 0 ]; then
  echo "No running Longhorn storage network pods found" >&2
  exit 1
fi

if [ -z "${MTU:-}" ]; then
  POD_MTUS=()
  for pod_name in "${POD_NAMES[@]}"; do
    pod_mtu="$(get_storage_network_mtu "$pod_name")"
    echo "$STORAGE_NIC MTU on $pod_name: ${pod_mtu:-unknown}"
    POD_MTUS+=("$pod_mtu")
  done
  mapfile -t unique_mtus < <(printf '%s\n' "${POD_MTUS[@]}" | sort -u)
  if [ "${#unique_mtus[@]}" -ne 1 ] || [ -z "${unique_mtus[0]}" ]; then
    echo "$STORAGE_NIC MTU is not the same on every pod" >&2
    exit 1
  fi
  MTU="${unique_mtus[0]}"
fi
echo "Using MTU $MTU"

echo "Debug info"
for i in "${!POD_NAMES[@]}"; do
  echo -e "${POD_NAMES[$i]}\t${POD_MACS[$i]}\t${POD_IPS[$i]}\t${POD_NODES[$i]}"
done

FAILED=0
check_duplicates

WEBSERVER_PIDS=()
trap stop_webservers EXIT

echo ""
echo "Starting webservers"
start_webservers
sleep 6

check_webservers_running
verify_connectivity

trap - EXIT
stop_webservers

trap remove_ping EXIT
copy_ping
check_mtu
verify_neighbour_macs

echo ""
if [ "$FAILED" -ne 0 ]; then
  echo "Finished: storage network check FAILED"
  exit 1
fi
echo "Finished: storage network check passed"
