#!/bin/bash -e

VIP=$(yq e '.install.vip' /oem/harvester.config)
RKE2_VERSION=$(yq -e e '.kubernetes ' /etc/harvester-release.yaml)

if [ -z $VIP ]; then
  echo "Fail to find VIP in OEM config file."
  exit 1
fi

if [ -z $RKE2_VERSION ]; then
  echo "Fail to find RKE2 version."
  exit 1
fi

fix_vip() {
  kubectl annotate secrets -n cattle-system tls-rancher-internal listener.cattle.io/cn-$VIP=$VIP || true
}

upgrade_rke2() {
  mkdir -p /usr/local/harvester-upgrade/rke2
  cd /usr/local/harvester-upgrade/rke2

  cat > patch.yaml <<EOF
spec:
  kubernetesVersion: $RKE2_VERSION
EOF

  kubectl patch clusters.provisioning.cattle.io local -n fleet-local --patch-file patch.yaml --type merge
}

fix_vip
upgrade_rke2
