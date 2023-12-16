#!/usr/bin/env sh

set -e

CRICTL="/var/lib/rancher/rke2/bin/crictl"
CONTAINERD_SOCK="unix:///var/run/k3s/containerd/containerd.sock"

TMP_DIR=$(mktemp -d)

trap cleanup EXIT

cleanup() {
    rm -rf "$TMP_DIR"
}

show_help_msg() {
  echo 'To purge all container images that no longer required by the current Harvester version.'
  echo ''
  echo 'Note: for airgap we expect their to be a folder with the current version on the web server - as well as a folder with the previous version on the web server.'
  echo 'Nested inside each of these folders should be a file called image-lists.tar.gz, which contains a list of all the images that are required for that version of Harvester.'
  echo '                                                                                       '
  echo 'Usage:                                                                                 '
  echo '  ./harv-purge-images.sh <previous_version> <current_version>                          '
  echo '  ./harv-purge-images.sh <previous_version> <current_version> <airgap-url>                         '
  echo '                                                                                       '
  echo 'Example:                                                                               '
  echo '  # This will purge all images introduced by v1.1.2 but no longer required by v1.2.0   '
  echo '  ./harv-purge-images.sh v1.1.2 v1.2.0                                                 '
  echo 'Example Airgap:                                                                               '
  echo '  # This will purge all images introduced by v1.1.2 but no longer required by v1.2.0 using airgap url to fetch image-lists.tar.gz for respective versions under their respective directories   '
  echo '  ./harv-purge-images.sh v1.1.2 v1.2.0 http://192.168.12.202:5000/harvester/                                                '
  echo 'Note: if airgap-url is provided but is https, you will need to prepare the CA for the file-server/web-server and place on each node in /etc/pki/trust/anchors/ then run update-ca-certificates'
}

collect_image_list() {
  prev_ver=$1
  cur_ver=$2
  airgap_url=$3

  mkdir "$TMP_DIR"/"$prev_ver"
  mkdir "$TMP_DIR"/"$cur_ver"

  echo "Fetching $prev_ver image lists..."
  if [ -z $airgap_url ]
  then
    curl -fL https://releases.rancher.com/harvester/"$prev_ver"/image-lists.tar.gz -o "$TMP_DIR"/"$prev_ver"/image-lists.tar.gz
  else
    curl -fL $airgap_url/"$prev_ver"/image-lists.tar.gz -o "$TMP_DIR"/"$prev_ver"/image-lists.tar.gz
  fi
  tar -zxvf "$TMP_DIR"/"$prev_ver"/image-lists.tar.gz -C "$TMP_DIR"/"$prev_ver"/
  echo "Fetching $cur_ver image lists..."
  if [ -z $airgap_url ]
  then
    curl -fL https://releases.rancher.com/harvester/"$cur_ver"/image-lists.tar.gz -o "$TMP_DIR"/"$cur_ver"/image-lists.tar.gz
  else
    curl -fL $airgap_url/"$cur_ver"/image-lists.tar.gz -o "$TMP_DIR"/"$cur_ver"/image-lists.tar.gz
  fi
  tar -zxvf "$TMP_DIR"/"$cur_ver"/image-lists.tar.gz -C "$TMP_DIR"/"$cur_ver"/

  prev_image_list="$TMP_DIR"/prev_image_list.txt
  cur_image_list="$TMP_DIR"/cur_image_list.txt

  cat "$TMP_DIR"/"$prev_ver"/image-lists/*.txt | sort | uniq > "$prev_image_list"
  cat "$TMP_DIR"/"$cur_ver"/image-lists/*.txt | sort | uniq > "$cur_image_list"

  echo '+------------------------------------------------------+'
  echo '| Images that are going to be REMOVED are listed BELOW |'
  echo '+------------------------------------------------------+'
  comm -23 "$prev_image_list" "$cur_image_list" | tee "$TMP_DIR"/image_list_diff.txt
  echo '+------------------------------------------------------+'
  echo '| Images that are going to be REMOVED are listed ABOVE |'
  echo '+------------------------------------------------------+'
}

main() {
  # Sanity check
  if [ $# -ne 2 ] | [ $# -ne 3 ]; then
    show_help_msg
    exit 1
  fi

  # Root permission required to execute crictl
  if [ "$EUID" -ne 0 ]; then
    echo 'Please run as root.'
    exit 1
  fi

  collect_image_list "$@"

  echo 'Current disk usage of /usr/local: '
  df -h /usr/local
  printf 'Delete the images listed above (y/n)? '
  read -r answer
  if [ "$answer" != "${answer#[Yy]}" ]; then
    if [ ! -x "$CRICTL" ]; then
      echo "crictl executable could not be found."
      exit 1
    fi

    IMAGE_SERVICE_ENDPOINT="$CONTAINERD_SOCK" "$CRICTL" rmi $(cat "$TMP_DIR"/image_list_diff.txt) || true
    echo 'Disk usage of /usr/local after removing the images: '
    df -h /usr/local
  else
    echo 'Abort.'
  fi
}

main "$@"
