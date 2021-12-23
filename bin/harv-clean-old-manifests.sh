#!/bin/bash -e

rm -f /var/lib/rancher/rke2/server/manifests/harvester.yaml
rm -f /var/lib/rancher/rke2/server/manifests/monitoring-crd.yaml
rm -f /var/lib/rancher/rke2/server/manifests/monitoring-dashboard.yaml
rm -f /var/lib/rancher/rke2/server/manifests/monitoring.yaml

rm -f /var/lib/rancher/rke2/server/static/charts/harvester-*.tgz
rm -f /var/lib/rancher/rke2/server/static/charts/rancher-monitoring-*.tgz

echo "Old manifests are deleted."

# Enable RKE2 ingress
if [ -e /etc/rancher/rke2/config.yaml.d/90-harvester-server.yaml ]; then
  /usr/local/harvester-upgrade/upgrade-helpers/bin/yq -e e 'del(.disable)' /etc/rancher/rke2/config.yaml.d/90-harvester-server.yaml -i
fi

sed -i '/disable: rke2-ingress-nginx/d' /oem/99_custom.yaml
