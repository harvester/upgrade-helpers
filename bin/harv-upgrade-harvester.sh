#!/bin/bash -e

export HARVESTER_CHART_VERSION="$(yq e '.harvesterChart' /etc/harvester-release.yaml)"
export MONITORING_CHART_VERSION="$(yq e '.monitoringChart' /etc/harvester-release.yaml)"
VIP_SPEC=$(kubectl get helmchartconfig harvester -n kube-system -o yaml | yq -e e '.spec.valuesContent' - | yq -e e '.service.vip' - )

network_controller_fix() {
  kubectl get deployment -n harvester-system harvester-network-controller-manager -o yaml | sed 's/app.kubernetes.io\/name: harvester-network-controller/app.kubernetes.io\/name: harvester-network-controller-manager/g' | kubectl replace --force -f -
}

# https://github.com/harvester/harvester/issues/1549
remove_user_attributes () {
  kubectl delete crd userattributes.management.cattle.io
}

get_managed_chart_modified() {
  kubectl get ManagedChart $1 -n fleet-local -o yaml | yq -e e '.status.summary.modified' -
}

get_managed_chart_ready() {
  kubectl get ManagedChart $1 -n fleet-local -o yaml | yq -e e '.status.summary.ready' -
}

wait_managed_chart_modified() {
  until [ "$(get_managed_chart_modified $1)" = "1" ]
  do
    echo "waiting for ManagedChart $1 to be modified."
    sleep 2
  done
}

wait_managed_chart_ready() {
  until [ "$(get_managed_chart_ready $1)" = "1" ]
  do
    echo "waiting for ManagedChart $1 to be ready."
    sleep 2
  done
}

upgrade_harvester() {
  kubectl apply -f /usr/local/harvester-upgrade/upgrade-helpers/manifests/10-harvester-0.yaml
  kubectl apply -f /usr/local/harvester-upgrade/upgrade-helpers/manifests/10-harvester-1.yaml

  # ingress configs, these two MUST be applied before upgrading rancher to prevent port conflict
  # kubectl apply -f /usr/local/harvester-upgrade/upgrade-helpers/manifests/10-harvester-2.yaml
  # kubectl apply -f /usr/local/harvester-upgrade/upgrade-helpers/manifests/10-harvester-3.yaml

  kubectl apply -f /usr/local/harvester-upgrade/upgrade-helpers/manifests/10-harvester-4.yaml

  # harvester mc
  yq -e e '.spec.version = strenv(HARVESTER_CHART_VERSION)' /usr/local/harvester-upgrade/upgrade-helpers/manifests/10-harvester-5.yaml -i
  VIP_SPEC="$VIP_SPEC" yq -e e '.spec.values.service.vip = env(VIP_SPEC)' /usr/local/harvester-upgrade/upgrade-helpers/manifests/10-harvester-5.yaml -i
  kubectl apply -f /usr/local/harvester-upgrade/upgrade-helpers/manifests/10-harvester-5.yaml
  wait_managed_chart_modified "harvester" 
  kubectl -n harvester-system rollout status -w deployment/harvester
  kubectl -n harvester-system rollout status -w deployment/harvester-webhook

  # harvester-crd mc
  kubectl apply -f /usr/local/harvester-upgrade/upgrade-helpers/manifests/10-harvester-6.yaml
  wait_managed_chart_ready "harvester-crd" 
}

upgrade_monitoring() {
  yq -e e '.spec.version = strenv(MONITORING_CHART_VERSION)' /usr/local/harvester-upgrade/upgrade-helpers/manifests/11-monitoring-crd-0.yaml -i
  kubectl apply -f /usr/local/harvester-upgrade/upgrade-helpers/manifests/11-monitoring-crd-0.yaml
  wait_managed_chart_ready "rancher-monitoring-crd"

  kubectl apply -f /usr/local/harvester-upgrade/upgrade-helpers/manifests/12-monitoring-dashboard-0.yaml
  kubectl apply -f /usr/local/harvester-upgrade/upgrade-helpers/manifests/12-monitoring-dashboard-1.yaml
  kubectl apply -f /usr/local/harvester-upgrade/upgrade-helpers/manifests/12-monitoring-dashboard-2.yaml

  yq -e e '.spec.version = strenv(MONITORING_CHART_VERSION)' /usr/local/harvester-upgrade/upgrade-helpers/manifests/13-monitoring-0.yaml -i
  kubectl apply -f /usr/local/harvester-upgrade/upgrade-helpers/manifests/13-monitoring-0.yaml
  wait_managed_chart_modified "rancher-monitoring"
}


network_controller_fix || true
remove_user_attributes || true
upgrade_harvester
upgrade_monitoring
