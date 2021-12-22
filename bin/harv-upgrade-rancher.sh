#!/bin/bash -e

export RANCHER_VERSION=$(yq -e e '.rancher' /etc/harvester-release.yaml)

upgrade() {
  mkdir -p /usr/local/harvester-upgrade/rancher
  cd /usr/local/harvester-upgrade/rancher
  wharfie --images-dir /var/lib/rancher/agent/images/ rancher/system-agent-installer-rancher:$RANCHER_VERSION /usr/local/harvester-upgrade/rancher

  ./helm get values rancher -n cattle-system -o yaml > values.yaml

  yq -e e '.rancherImageTag = strenv(RANCHER_VERSION)' values.yaml -i
  ./helm upgrade rancher ./*.tgz --namespace cattle-system -f values.yaml

  kubectl -n cattle-system rollout status -w deployment/rancher
}

fix_ingress() {
  # ingress configs, these two MUST be applied before upgrading rancher to prevent port conflict
  kubectl apply -f /usr/local/harvester-upgrade/upgrade-helpers/manifests/10-harvester-2.yaml
  kubectl apply -f /usr/local/harvester-upgrade/upgrade-helpers/manifests/10-harvester-3.yaml
}

fix_ingress
upgrade
