#!/bin/bash -e

VIRTCTL=/usr/local/harvester-upgrade/upgrade-helpers/bin/virtctl

stop_all_vms() {
  kubectl get vmi -A -o json |
    jq -r  '.items[].metadata | [.name, .namespace] | @tsv' |
    while IFS=$'\t' read -r name namespace; do
    echo "Stop ${namespace}/${name}"
    $VIRTCTL stop $name -n $namespace
    done
}


get_running_vm_count()
{
  local count

  count=$(kubectl get vmi -A -ojson | jq '.items | length' || true)
  echo $count
}

wait_all_vms_gone() {
  vm_count="$(get_running_vm_count)"
  until [ "$vm_count" = "0" ]
  do
    echo "Waiting for VMs to be shut down...($vm_count left)"
    sleep 5
    vm_count="$(get_running_vm_count)"
  done

  echo "Ther is no running VMs."
}


stop_all_vms
wait_all_vms_gone

