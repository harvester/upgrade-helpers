#!/bin/bash -e

OLD_MANIFESTS=(
/var/lib/rancher/rke2/server/manifests/harvester.yaml
/var/lib/rancher/rke2/server/manifests/monitoring-crd.yaml
/var/lib/rancher/rke2/server/manifests/monitoring-dashboard.yaml
/var/lib/rancher/rke2/server/manifests/monitoring.yaml
/var/lib/rancher/rke2/server/static/charts/harvester-*.tgz
/var/lib/rancher/rke2/server/static/charts/rancher-monitoring-*.tgz
)

check_old_manifests() {

  for f in ${OLD_MANIFESTS[@]}; do
    if ls $f &> /dev/null; then
      echo "Old manifest "$f" exists!"
      echo "Please run 'sudo -i /usr/local/harvester-upgrade/upgrade-helpers/bin/harv-clean-old-manifests.sh' to remove them!"
      exit 1
    fi
  done

}

check_os_versions() {
  echo ""
  echo "============================"
  echo "Harvester version: $(yq -e e .harvester /etc/harvester-release.yaml)"
  echo "OS version: $(yq -e e .os /etc/harvester-release.yaml)"
  echo "============================"
}


check_old_manifests
check_os_versions
