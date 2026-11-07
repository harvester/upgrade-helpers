#!/bin/bash

# Verify all Longhorn pods on the storage network can communicate with each other.
# Automation of step 4 from https://docs.harvesterhci.io/latest/advanced/storagenetwork#step-4
# Requires kubectl and an active context for the harvester cluster.
# Run it on a harvester management node: ping and arping (iputils) are copied from the
# machine running the script into the pods, so they must be compatible with the pod images.
#
# Environment overrides:
#   MTU           storage network MTU to test; defaults to the MTU of lhnet1 in the pods
#   MAX_PARALLEL  maximum concurrent kubectl exec calls (default 20)
#
# Checks:
#   - duplicate storage network IPs and MACs between the pods
#   - other hosts answering ARP for a pod's storage IP (arping duplicate address detection)
#   - plain ping, full MTU don't fragment ping and HTTP between every pair of pods, both ways
#   - HTTP answers come from the expected pod, and neighbour MACs match pod MACs
#   - running v1 engines use the storage IP of each replica's instance manager, and can
#     open TCP connections to each replica's control and data ports; other replicas of
#     the volume can reach its sync agent port

# shellcheck disable=SC2016 # sh -c scripts are expanded in the pod, not here
set -eo pipefail

NAMESPACE=longhorn-system
SELECTOR='longhorn.io/component in (instance-manager,backing-image-manager,backing-image-data-source)'
STORAGE_NIC=lhnet1
WORK_DIR_PREFIX=/tmp/storage-network-check
# Backing image pods already listen on 8000-8002.
WEBSERVER_PORT=9000
WEBSERVER_START_TIMEOUT=20
MAX_PARALLEL="${MAX_PARALLEL:-20}"

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
      elif (($storage[0].ips[0] // "") == "") or (($storage[0].mac // "") == "") then
        error("\($pod.metadata.name): storage network attachment has no IP or MAC")
      else
        [$pod.metadata.name, $pod.status.phase, $pod.spec.nodeName, $storage[0].ips[0], ($storage[0].mac | ascii_downcase)] | @tsv
      end
    '
}

describe_pod() {
  echo "${POD_NAMES[$1]} (${POD_NODES[$1]})"
}

pod_exec() {
  local i="$1"
  shift
  kubectl exec -n "$NAMESPACE" "${POD_NAMES[$i]}" -- "$@"
}

count_running() {
  local count=0 pid
  for pid in "$@"; do
    if kill -0 "$pid" &>/dev/null; then
      count=$((count + 1))
    fi
  done
  echo "$count"
}

# Run "$1 <pod index>" for every pod, at most MAX_PARALLEL at a time.
# Output for each pod goes to $RESULTS_DIR/<function>.<index>.
# Indexes of pods where the function failed are left in FAILED_PODS.
for_each_pod() {
  local fn="$1" i
  local -a pids=()
  FAILED_PODS=()
  for i in "${!POD_NAMES[@]}"; do
    while [ "$(count_running "${pids[@]}")" -ge "$MAX_PARALLEL" ]; do
      sleep 0.2
    done
    "$fn" "$i" >"$RESULTS_DIR/$fn.$i" 2>&1 &
    pids[i]=$!
  done
  for i in "${!pids[@]}"; do
    if ! wait "${pids[$i]}"; then
      FAILED_PODS+=("$i")
    fi
  done
}

result_file() {
  echo "$RESULTS_DIR/$1.$2"
}

# Create a work directory in the pod, report the storage NIC MTU and copy ping and arping into it.
# www/ok holds the pod name so the HTTP checks can tell which pod answered.
setup_pod() {
  local output dir
  output="$(pod_exec "$1" sh -c '
    dir="$(mktemp -d "$1.XXXXXX")" || exit 1
    echo "dir $dir"
    mkdir "$dir/www" || exit 1
    printf "%s\n" "$3" > "$dir/www/ok" || exit 1
    ip -o link show dev "$2" || exit 1
  ' sh "$WORK_DIR_PREFIX" "$STORAGE_NIC" "${POD_NAMES[$1]}")" || {
    echo "$output"
    return 1
  }
  echo "$output"
  dir="$(sed -n 's/^dir //p' <<<"$output")"
  kubectl -n "$NAMESPACE" cp "$PING_BIN" "${POD_NAMES[$1]}:$dir/ping"
  kubectl -n "$NAMESPACE" cp "$ARPING_BIN" "${POD_NAMES[$1]}:$dir/arping"
}

pod_dir() {
  local file
  if [ -n "${POD_DIRS[$1]}" ]; then
    echo "${POD_DIRS[$1]}"
  else
    # Setup may have been interrupted before POD_DIRS was filled in.
    file="$(result_file setup_pod "$1")"
    [ -f "$file" ] && sed -n 's/^dir //p' "$file"
  fi
  return 0
}

cleanup_pod() {
  local dir
  dir="$(pod_dir "$1")"
  [ -n "$dir" ] || return 0
  pod_exec "$1" sh -c '
    if pid="$(cat "$1/server.pid" 2>/dev/null)" && [ "$(readlink "/proc/$pid/cwd")" = "$1/www" ]; then
      kill "$pid"
    fi
    rm -rf "$1"
  ' sh "$dir"
}

# Runs in a subshell so that set +e does not leak into the rest of the script.
cleanup() (
  set +e
  echo ""
  echo "Cleaning up"
  local pid
  for pid in "${WEBSERVER_PIDS[@]}"; do
    kill "$pid" &>/dev/null
  done
  if [ "$SETUP_STARTED" -eq 1 ]; then
    for_each_pod cleanup_pod
    for i in "${FAILED_PODS[@]}"; do
      echo "Cleanup failed on $(describe_pod "$i"), remove $(pod_dir "$i") manually"
    done
  fi
  rm -rf "$RESULTS_DIR"
)

# Remove the pods at the given indexes from the pod arrays.
drop_pods() {
  local i
  local -a names=() nodes=() ips=() macs=() dirs=() mtus=()
  for i in "${!POD_NAMES[@]}"; do
    [[ " $* " == *" $i "* ]] && continue
    names+=("${POD_NAMES[$i]}")
    nodes+=("${POD_NODES[$i]}")
    ips+=("${POD_IPS[$i]}")
    macs+=("${POD_MACS[$i]}")
    dirs+=("${POD_DIRS[$i]}")
    mtus+=("${POD_MTUS[$i]}")
  done
  POD_NAMES=("${names[@]}")
  POD_NODES=("${nodes[@]}")
  POD_IPS=("${ips[@]}")
  POD_MACS=("${macs[@]}")
  POD_DIRS=("${dirs[@]}")
  POD_MTUS=("${mtus[@]}")
}

# A pod that fails setup is left out of the check. Pods that stopped since they were
# listed, such as finished backing-image-data-source pods, are skipped without failing.
prepare_pods() {
  echo ""
  echo "Preparing pods"
  local i output phase
  SETUP_STARTED=1
  for_each_pod setup_pod
  for i in "${!POD_NAMES[@]}"; do
    output="$(cat "$(result_file setup_pod "$i")")"
    POD_DIRS[i]="$(sed -n 's/^dir //p' <<<"$output")"
    POD_MTUS[i]="$(awk '{for(k=1;k<=NF;k++) if($k=="mtu"){print $(k+1); exit}}' <<<"$output")"
  done
  local -a failed=("${FAILED_PODS[@]}")
  [ "${#failed[@]}" -gt 0 ] || return 0
  for i in "${failed[@]}"; do
    if ! phase="$(kubectl get pod -n "$NAMESPACE" "${POD_NAMES[$i]}" --ignore-not-found -o jsonpath='{.status.phase}')"; then
      phase="Running"
    fi
    if [ "$phase" != "Running" ]; then
      echo "Skipping $(describe_pod "$i"): ${phase:-deleted} since it was listed"
      continue
    fi
    echo "Could not prepare $(describe_pod "$i"):"
    sed 's/^/  /' "$(result_file setup_pod "$i")"
    FAILED=1
    cleanup_pod "$i" &>/dev/null || echo "Cleanup failed on $(describe_pod "$i"), remove ${POD_DIRS[$i]:-its work directory} manually"
  done
  drop_pods "${failed[@]}"
  rm -f "$RESULTS_DIR"/setup_pod.*
  if [ "${#POD_NAMES[@]}" -eq 0 ]; then
    echo "No Longhorn storage network pods could be prepared" >&2
    exit 1
  fi
}

start_webservers() {
  echo ""
  echo "Starting webservers"
  local i
  for i in "${!POD_NAMES[@]}"; do
    pod_exec "$i" sh -c '
      cd "$1/www" || exit 1
      printf "%s\n" "$$" > "$1/server.pid" || exit 1
      exec python3 -m http.server "$3" --bind "$2"
    ' sh "${POD_DIRS[$i]}" "${POD_IPS[$i]}" "$WEBSERVER_PORT" &>/dev/null &
    WEBSERVER_PIDS[i]=$!
  done
}

wait_for_webserver() {
  pod_exec "$1" sh -c '
    deadline=$(($(date +%s) + $3))
    until curl -sf -o /dev/null -m 1 "http://$1:$2/ok"; do
      [ "$(date +%s)" -ge "$deadline" ] && exit 1
      sleep 0.5
    done
  ' sh "${POD_IPS[$1]}" "$WEBSERVER_PORT" "$WEBSERVER_START_TIMEOUT"
}

wait_for_webservers() {
  local i
  for_each_pod wait_for_webserver
  for i in "${FAILED_PODS[@]}"; do
    echo "Webserver failed to start on $(describe_pod "$i")"
    FAILED=1
  done
}

# Every other pod, starting after pod $1 and wrapping round, so that pods checking in
# parallel do not all hit the same webserver at once. Its listen backlog is only 5.
pair_targets() {
  local count="${#POD_NAMES[@]}" offset j
  for ((offset = 1; offset < count; offset++)); do
    j=$((($1 + offset) % count))
    echo "$j=${POD_IPS[$j]}=${POD_NAMES[$j]}"
  done
}

# From one pod, to every other pod: a plain ping, a full MTU don't fragment ping, and an
# HTTP request that must be answered by the expected pod.
# Each pair is checked from both ends, so a rule that only blocks connections started from
# one side is caught.
check_pairs_from() {
  local -a targets
  mapfile -t targets < <(pair_targets "$1")
  [ "${#targets[@]}" -gt 0 ] || return 0
  pod_exec "$1" sh -c '
    dir="$1" port="$2" size="$3"
    shift 3
    for target in "$@"; do
      j="${target%%=*}" rest="${target#*=}"
      ip="${rest%%=*}" name="${rest#*=}"
      if "$dir/ping" -c 2 -i 0.2 -W 1 -w 2 -t 4 "$ip" >/dev/null 2>&1; then
        echo "$j icmp ok"
      else
        echo "$j icmp fail"
      fi
      if "$dir/ping" -c 2 -i 0.2 -W 1 -w 2 -M do -s "$size" -t 4 "$ip" >/dev/null 2>&1; then
        echo "$j mtu ok"
      else
        echo "$j mtu fail"
      fi
      if answer="$(curl -sf -m 1 "http://$ip:$port/ok")"; then
        if [ "$answer" = "$name" ]; then
          echo "$j http ok"
        else
          echo "$j http wrong $(printf "%s" "$answer" | head -c 100 | tr -c "[:alnum:]._-" "?")"
        fi
      else
        echo "$j http fail"
      fi
    done
  ' sh "${POD_DIRS[$1]}" "$WEBSERVER_PORT" "$((MTU - 28))" "${targets[@]}"
}

check_pairs() {
  echo ""
  echo "Checking ICMP, MTU $MTU and HTTP between pods"
  local i j check result detail expected file pairs
  local -A icmp_failed
  for_each_pod check_pairs_from
  for i in "${!POD_NAMES[@]}"; do
    file="$(result_file check_pairs_from "$i")"
    expected=$((${#POD_NAMES[@]} - 1))
    if [ "$(grep -cE '^[0-9]+ (icmp ok|icmp fail|mtu ok|mtu fail|http ok|http fail|http wrong .*)$' "$file")" -ne $((expected * 3)) ]; then
      echo "Checks did not complete from $(describe_pod "$i"):"
      sed 's/^/  /' "$file"
      FAILED=1
      continue
    fi
    while read -r j check result detail; do
      [ "$result" = "ok" ] && continue
      case "$check $result" in
        "icmp fail")
          icmp_failed[$j]=1
          echo "Ping failed: $(describe_pod "$i") <-> $(describe_pod "$j")"
          ;;
        "mtu fail")
          if [ -z "${icmp_failed[$j]}" ]; then
            echo "MTU $MTU ping failed, plain ping works: $(describe_pod "$i") <-> $(describe_pod "$j")"
          fi
          ;;
        "http fail") echo "HTTP failed: $(describe_pod "$i") <-> $(describe_pod "$j")" ;;
        "http wrong") echo "HTTP answered by '$detail', expected $(describe_pod "$j"): from $(describe_pod "$i")" ;;
      esac
      FAILED=1
    done < <(grep -E '^[0-9]+ (icmp|mtu|http) ' "$file")
    icmp_failed=()
  done
  pairs=$((${#POD_NAMES[@]} * (${#POD_NAMES[@]} - 1) / 2))
  echo "Checked $pairs pod pairs in both directions"
}

# Duplicate address detection: any ARP reply for a pod's own storage IP means another host,
# such as a node in a second cluster on the same VLAN, is using it.
detect_address_owner() {
  pod_exec "$1" sh -c '
    "$1/arping" -D -I "$2" -c 2 -w 3 "$3"
    echo "exit $?"
  ' sh "${POD_DIRS[$1]}" "$STORAGE_NIC" "${POD_IPS[$1]}"
}

check_address_conflicts() {
  echo ""
  echo "Checking for other hosts using pod storage IPs"
  local i file macs
  for_each_pod detect_address_owner
  for i in "${!POD_NAMES[@]}"; do
    file="$(result_file detect_address_owner "$i")"
    case "$(sed -n 's/^exit //p' "$file")" in
      0) ;;
      1)
        macs="$(grep -oiE 'reply from [0-9.]+ \[[0-9a-f:]+\]' "$file" | grep -oiE '[0-9a-f]{2}(:[0-9a-f]{2}){5}' | tr 'A-F' 'a-f' | sort -u | paste -sd ' ' - || true)"
        echo "${POD_IPS[$i]} of $(describe_pod "$i") is also answered by ${macs:-another host}"
        FAILED=1
        ;;
      *)
        echo "Could not run duplicate address detection on $(describe_pod "$i"):"
        sed 's/^/  /' "$file"
        FAILED=1
        ;;
    esac
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

# One line per replica of each running engine:
# volume, engine instance manager, replica, address the engine uses,
# replica instance manager, replica storage IP and port as the replica reports them.
# Engines on other data engines are reported as "skip <engine> <data engine>".
get_replica_endpoints() {
  kubectl get engines.longhorn.io -n "$NAMESPACE" -o json >"$RESULTS_DIR/engines.json"
  kubectl get replicas.longhorn.io -n "$NAMESPACE" -o json >"$RESULTS_DIR/replicas.json"
  jq -rn --slurpfile engines "$RESULTS_DIR/engines.json" --slurpfile replicas "$RESULTS_DIR/replicas.json" '
    def field: if . == null or . == "" then "-" else tostring end;
    ($replicas[0].items | map({key: .metadata.name, value: .}) | from_entries) as $replica_by_name |
    $engines[0].items[] |
    select(.status.currentState == "running") |
    . as $engine |
    if ($engine.spec.dataEngine // "v1") != "v1" then
      ["skip", $engine.metadata.name, ($engine.spec.dataEngine | field)] | @tsv
    else
      ($engine.status.currentReplicaAddressMap // {}) | to_entries[] |
      $replica_by_name[.key] as $replica |
      [
        "endpoint",
        ($engine.spec.volumeName | field),
        ($engine.status.instanceManagerName | field),
        .key,
        (.value | field | sub("^tcp://"; "")),
        ($replica.status.instanceManagerName | field),
        ($replica.status.storageIP | field),
        ($replica.status.port | field)
      ] | @tsv
    end
  '
}

# Add "<address> <description>" to the TCP targets of the pod at index $1.
add_tcp_target() {
  local key="$1 $2"
  [ -n "${TCP_TARGET_SEEN[$key]}" ] && return 0
  TCP_TARGET_SEEN[$key]=1
  TCP_TARGETS[$1]+="$2 $3"$'\n'
}

connect_tcp_targets() {
  local -a addresses
  [ -n "${TCP_TARGETS[$1]}" ] || return 0
  mapfile -t addresses < <(printf '%s' "${TCP_TARGETS[$1]}" | cut -d' ' -f1)
  pod_exec "$1" python3 -c '
import socket
import sys

for address in sys.argv[1:]:
    host, port = address.rsplit(":", 1)
    try:
        socket.create_connection((host, int(port)), timeout=1).close()
        print(address, "ok")
    except OSError as error:
        print(address, "fail", type(error).__name__)
' "${addresses[@]}"
}

# The engine connects to each replica on its control port, data port (port + 1) and sync
# agent (port + 2). During a rebuild, the other replicas of the volume connect to its sync
# agent too. The file transfer ports above port + 2 only listen during a transfer, so they
# are not checked.
check_replica_endpoints() {
  echo ""
  echo "Checking engine and replica endpoints"
  local kind volume engine_manager replica address replica_manager replica_ip replica_port
  local engine_index replica_index ip port description i peer file result detail
  local endpoints=0 skipped=0
  local -A pod_index replicas_by_volume
  local -a records
  declare -gA TCP_TARGET_SEEN=()
  TCP_TARGETS=()
  for i in "${!POD_NAMES[@]}"; do
    pod_index[${POD_NAMES[$i]}]="$i"
  done
  if ! get_replica_endpoints >"$RESULTS_DIR/endpoints" 2>"$RESULTS_DIR/endpoints.err"; then
    echo "Could not read Longhorn engines and replicas:"
    sed 's/^/  /' "$RESULTS_DIR/endpoints.err"
    FAILED=1
    return
  fi
  mapfile -t records <"$RESULTS_DIR/endpoints"
  for line in "${records[@]}"; do
    [ -n "$line" ] || continue
    IFS=$'\t' read -r kind volume engine_manager replica address replica_manager replica_ip replica_port <<<"$line"
    if [ "$kind" = "skip" ]; then
      skipped=$((skipped + 1))
      continue
    fi
    endpoints=$((endpoints + 1))
    ip="${address%:*}"
    port="${address##*:}"
    engine_index="${pod_index[$engine_manager]}"
    replica_index="${pod_index[$replica_manager]}"
    description="volume $volume replica $replica"
    if [ -z "$replica_index" ]; then
      echo "$description: replica instance manager $replica_manager is not a running storage network pod"
      FAILED=1
    else
      description+=" on ${POD_NODES[$replica_index]}"
      if [ "$ip" != "${POD_IPS[$replica_index]}" ]; then
        echo "$description: engine uses $address, but $replica_manager has storage IP ${POD_IPS[$replica_index]}"
        FAILED=1
      fi
    fi
    # Older Longhorn versions do not report the replica storage IP.
    if [ "$replica_ip" != "-" ] && [ "$replica_ip:$replica_port" != "$address" ]; then
      echo "$description: engine uses $address, but the replica reports $replica_ip:$replica_port"
      FAILED=1
    fi
    if ! [[ "$port" =~ ^[0-9]+$ ]]; then
      echo "$description: engine uses unexpected address $address"
      FAILED=1
      continue
    fi
    if [ -z "$engine_index" ]; then
      echo "$description: engine instance manager $engine_manager is not a running storage network pod"
      FAILED=1
    else
      add_tcp_target "$engine_index" "$address" "$description control port"
      add_tcp_target "$engine_index" "$ip:$((port + 1))" "$description data port"
      add_tcp_target "$engine_index" "$ip:$((port + 2))" "$description sync agent port"
    fi
    replicas_by_volume[$volume]+="$replica_index=$ip:$((port + 2))=$description"$'\n'
  done
  # Every replica of a volume must reach the sync agent of every other replica.
  for volume in "${!replicas_by_volume[@]}"; do
    mapfile -t records < <(printf '%s' "${replicas_by_volume[$volume]}")
    for i in "${records[@]}"; do
      for peer in "${records[@]}"; do
        [ "$i" = "$peer" ] && continue
        replica_index="${i%%=*}"
        [ -n "$replica_index" ] || continue
        detail="${peer#*=}"
        add_tcp_target "$replica_index" "${detail%%=*}" "${detail#*=} sync agent port"
      done
    done
  done
  echo "Found $endpoints replica endpoints on running v1 engines"
  if [ "$skipped" -gt 0 ]; then
    echo "Skipped $skipped running engines that do not use the v1 data engine"
  fi

  for_each_pod connect_tcp_targets
  for i in "${!POD_NAMES[@]}"; do
    [ -n "${TCP_TARGETS[$i]}" ] || continue
    file="$(result_file connect_tcp_targets "$i")"
    if [ "$(grep -cE '^[^ ]+:[0-9]+ (ok|fail [A-Za-z]+)$' "$file")" -ne "$(printf '%s' "${TCP_TARGETS[$i]}" | grep -c '')" ]; then
      echo "TCP checks did not complete from $(describe_pod "$i"):"
      sed 's/^/  /' "$file"
      FAILED=1
      continue
    fi
    while read -r address result detail; do
      [ "$result" = "ok" ] && continue
      description="$(printf '%s' "${TCP_TARGETS[$i]}" | awk -v a="$address" '$1 == a {sub(/^[^ ]+ /, ""); print; exit}')"
      echo "TCP connect to $address failed ($detail) from $(describe_pod "$i"): $description"
      FAILED=1
    done < <(grep -E '^[^ ]+:[0-9]+ (ok|fail [A-Za-z]+)$' "$file")
  done
}

read_neighbours() {
  pod_exec "$1" ip neigh show dev "$STORAGE_NIC"
}

# Detects another host, such as a second cluster on the same VLAN, answering for a pod IP.
# Run after check_pairs so every pod has a neighbour entry for every other pod.
verify_neighbour_macs() {
  echo ""
  echo "Verifying neighbour MACs match pod MACs"
  local i j mac file
  for_each_pod read_neighbours
  for i in "${FAILED_PODS[@]}"; do
    echo "Could not read neighbours on $(describe_pod "$i")"
    FAILED=1
  done
  for i in "${!POD_NAMES[@]}"; do
    [[ " ${FAILED_PODS[*]} " == *" $i "* ]] && continue
    file="$(result_file read_neighbours "$i")"
    for j in "${!POD_IPS[@]}"; do
      [ "$i" -eq "$j" ] && continue
      mac="$(awk -v ip="${POD_IPS[$j]}" '$1 == ip {for(k=2;k<=NF;k++) if($k=="lladdr"){print tolower($(k+1)); exit}}' "$file")"
      if [ "$mac" != "${POD_MACS[$j]}" ]; then
        echo "$(describe_pod "$i") sees ${POD_IPS[$j]} at ${mac:-no MAC}, expected ${POD_MACS[$j]} for $(describe_pod "$j")"
        FAILED=1
      fi
    done
  done
}

if ! [[ "$MAX_PARALLEL" =~ ^[1-9][0-9]*$ ]]; then
  echo "MAX_PARALLEL must be a positive integer, got '$MAX_PARALLEL'" >&2
  exit 1
fi
if [ -n "${MTU:-}" ] && ! [[ "$MTU" =~ ^[1-9][0-9]*$ && "$MTU" -ge 68 ]]; then
  echo "MTU must be an integer of at least 68, got '$MTU'" >&2
  exit 1
fi
if ! PING_BIN="$(command -v ping)"; then
  echo "ping not found on PATH, it is needed to copy into the pods" >&2
  exit 1
fi
PING_BIN="$(readlink -f "$PING_BIN")"
if ! ARPING_BIN="$(command -v arping)"; then
  echo "arping not found on PATH, it is needed to copy into the pods" >&2
  exit 1
fi
ARPING_BIN="$(readlink -f "$ARPING_BIN")"
# Duplicate address detection relies on the iputils arping options and exit codes.
if ! "$ARPING_BIN" -V 2>&1 | grep -q iputils; then
  echo "$ARPING_BIN is not the iputils arping" >&2
  exit 1
fi

# Short lived pods, such as backing-image-data-source, can finish during the check.
# Failures involving them are not storage network faults.
report_stopped_pods() {
  local i phase
  for i in "${!POD_NAMES[@]}"; do
    phase="$(kubectl get pod -n "$NAMESPACE" "${POD_NAMES[$i]}" --ignore-not-found -o jsonpath='{.status.phase}' 2>/dev/null)" || continue
    if [ "$phase" != "Running" ]; then
      echo ""
      echo "$(describe_pod "$i") is ${phase:-deleted} now, failures involving it may be caused by that"
    fi
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

RESULTS_DIR="$(mktemp -d)"
POD_DIRS=()
POD_MTUS=()
WEBSERVER_PIDS=()
FAILED_PODS=()
FAILED=0
SETUP_STARTED=0
trap cleanup EXIT

check_duplicates
prepare_pods

echo ""
for i in "${!POD_NAMES[@]}"; do
  echo "$STORAGE_NIC MTU on ${POD_NAMES[$i]}: ${POD_MTUS[$i]:-unknown}"
done
if [ -z "${MTU:-}" ]; then
  mapfile -t unique_mtus < <(printf '%s\n' "${POD_MTUS[@]}" | sort -u)
  if [ "${#unique_mtus[@]}" -ne 1 ] || [ -z "${unique_mtus[0]}" ]; then
    echo "$STORAGE_NIC MTU is not the same on every pod" >&2
    exit 1
  fi
  MTU="${unique_mtus[0]}"
fi
echo "Using MTU $MTU"

echo ""
echo "Debug info"
for i in "${!POD_NAMES[@]}"; do
  echo -e "${POD_NAMES[$i]}\t${POD_MACS[$i]}\t${POD_IPS[$i]}\t${POD_NODES[$i]}"
done

start_webservers
wait_for_webservers
check_address_conflicts
check_pairs
verify_neighbour_macs
check_replica_endpoints

cleanup
trap - EXIT

if [ "$FAILED" -ne 0 ]; then
  report_stopped_pods
fi

echo ""
if [ "$FAILED" -ne 0 ]; then
  echo "Finished: storage network check FAILED"
  exit 1
fi
echo "Finished: storage network check passed"
