#!/bin/bash -e

REPO_VERSION=$(yq -e e '.harvester' /etc/harvester-release.yaml)

create_repo() {
  sed -i "s,rancher/harvester-cluster-repo.*,rancher/harvester-cluster-repo:$REPO_VERSION," /usr/local/harvester-upgrade/upgrade-helpers/manifests/repo.yaml
  kubectl create -f /usr/local/harvester-upgrade/upgrade-helpers/manifests/repo.yaml
}

wait_repo() {
  kubectl -n cattle-system rollout status -w deployment/harvester-cluster-repo
}

create_repo
wait_repo
