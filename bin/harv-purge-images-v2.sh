#!/bin/bash -e

# ==============================================================================
# LOGIC SUMMARY:
# 1. Registry-Agnostic: Matches "name:version" regardless of the registry URL.
#    Example: 'shell:v0.5.0' matches 'docker.io/shell:v0.5.0' and local repos.
#
# 2. Ghost Cleanup: Automatically identifies and removes "dangling" images
#    (those with <none> tags) to maximize reclaimed disk space.
#
# 3. Air-Gap/Proxy Flow: Use '--download-only' to fetch official manifests for
#    BOTH amd64 and arm64 architectures. You can then manually edit these
#    files before transferring them to your air-gapped nodes.
#
# 4. Security: Validates list size (<100KB), MIME-type (text), and strictly
#    validates that arguments (like --version) are provided.
#
# SAFETY TIP: ALWAYS run with '--dry-run' first! Verify exactly which images
#             (including your custom additions) will be purged.
# ==============================================================================

# --- Global Constants ---
BASE_URL="https://raw.githubusercontent.com/w13915984028/upgrade-helpers/enh8667/manifests/image-lists/lists"
CRICTL="/var/lib/rancher/rke2/bin/crictl"
CONTAINERD_SOCK="unix:///var/run/k3s/containerd/containerd.sock"

# ANSI Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
NC='\033[0m'

usage() {
  local exit_code="${1:-0}"
  echo -e "${YELLOW}Usage: $0 --version <v1.x.x> [options]${NC}"
  echo "Options:"
  echo "  --version <v1.x.x>     REQUIRED: The current Harvester version of your cluster"
  echo "  --download-only        Download official lists for BOTH amd64 and arm64 and exit"
  echo "  --dry-run              Simulate removal and show targets (STRONGLY RECOMMENDED)"
  echo "  --debug                Show detailed JSON snapshots and logic logs"
  echo "  --images-list <path>   Path to a local file or URL. Use this to provide your"
  echo "                         edited list containing third-party image tags."
  echo "  -h, --help             Show this help menu"
  echo ""
  exit "$exit_code"
}

# 2. Export Endpoints & Config
export IMAGE_SERVICE_ENDPOINT="$CONTAINERD_SOCK"
export RUNTIME_SERVICE_ENDPOINT="$CONTAINERD_SOCK"

# Silence crictl "Config does not exist" warnings
if [[ -f "/var/lib/rancher/rke2/agent/etc/crictl.yaml" ]]; then
  export CRI_CONFIG_FILE="/var/lib/rancher/rke2/agent/etc/crictl.yaml"
fi

# --- Global Setup ---
TARGET_ARCH="amd64"
DEBUG=false
DOWNLOAD_ONLY=false
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# At running time, figure out the ARCH on this node
get_arch() {
  local arch=$(uname -m)
  case "$arch" in
    aarch64)
      TARGET_ARCH="arm64"
      ;;
    x86_64)
      TARGET_ARCH="amd64"
      ;;
    *)
      echo -e "${RED}Error: Unsupported architecture: $arch${NC}"
      exit 1
      ;;
  esac
}

get_avail_kb() {
  df -k /usr/local | awk 'NR==2 {print $4}'
}

log_cri_disk_usage() {
  if [[ "$DRY_RUN" == "true" ]]; then
    return 0
  fi
  local label=$1
  echo -e "${BLUE}--- Disk Usage: $label ---${NC}"
  df -h /usr/local
}

# --- Dedicated Download Function, both supported ARCH related files are downloaded ---
# user could edit the file manually to add more images to-be-purged
download_official_lists() {
  local archs=("amd64" "arm64")
  local success_count=0

  echo -e " ${BLUE}[INFO]${NC} Downloading official manifests for Version: ${VERSION}..."

  for arch in "${archs[@]}"; do
    local remote_fname="${VERSION}-${arch}-images-list.txt"
    local url="${BASE_URL}/${remote_fname}"
    local output_file="./${remote_fname}"

    if curl -fsSL --max-time 10 -o "$output_file" "$url"; then
      echo -e "  ${GREEN}[SAVED]${NC} $output_file"
      ((success_count++))
    else
      echo -e "  ${RED}[SKIP]${NC} $remote_fname not found on server."
    fi
  done

  if [[ $success_count -gt 0 ]]; then
    echo -e "\n${GREEN}[SUCCESS] Downloaded $success_count manifest(s).${NC}"
    echo -e "${YELLOW}[TIP] Transfer the file matching your node's architecture and run:${NC}"
    echo -e "      $0 --version $VERSION --images-list ./<filename>"
  else
    echo -e "${RED}[ERROR] No manifests found. Check if version '$VERSION' is correct.${NC}"
    exit 1
  fi
  exit 0
}

generate_kill_list() {
  local snapshot="$1"
  local images_list="$2"
  local debug_mode="$3"

  # Step A: Create a simple flat file of "short" tags to purge
  local purge_tags="$TMP_DIR/purge_tags.txt"
  grep -vE '^\s*(#|$)' "$images_list" | sed 's/\r//g' | awk -F'/' '{print $NF}' | sort -u > "$purge_tags"

  if [[ "$debug_mode" == "true" ]]; then
     echo -e "${MAGENTA}[DEBUG] Purge List unique count: $(wc -l < "$purge_tags")${NC}" >&2
  fi

  # Step B: Extract all local images into a flat ID|Tag format
  # We handle named images and dangling images separately for speed
  local local_images="$TMP_DIR/local_images.txt"
  jq -r '.images[] | select(.pinned != true) | . as $img |
    if (.repoTags | length > 0) then
      .repoTags[] | "\($img.id)|\(.)"
    else
      "\($img.id)|<dangling/ghost>"
    end' "$snapshot" > "$local_images"

  # Step C: The actual matching logic
  # 1. Always include dangling/ghost images
  grep "|<dangling/ghost>" "$local_images" || true

  # 2. Match named images against our purge list
  # We use awk to check if the 'name:tag' part of the local image exists in our purge list
  awk -F'|' 'NR==FNR{a[$1];next} {
    split($2, parts, "/");
    short=parts[length(parts)];
    if (short in a) print $0
  }' "$purge_tags" "$local_images"
}

cleanup_images() {
  local dry_run=$1
  local images_list=$2

  echo -e "${GREEN}>>> IMAGE CLEANUP START${NC}"

  # --- Disk Usage Tracking ---
  local start_kb=$(get_avail_kb)
  log_cri_disk_usage "BEFORE"
  # ----------------------------------

  local snapshot="$TMP_DIR/crictl_snap.json"
  # Capture snapshot once
  if ! "$CRICTL" images -o json > "$snapshot" 2>/dev/null; then
    echo -e "${RED}[ERROR] $CRICTL is unresponsive.${NC}"
    return 1
  fi

  echo -e "${YELLOW}>>> Analyzing system images ...${NC}"

  # Run the generator and save to file
  local kill_file="$TMP_DIR/final_kill.list"
  generate_kill_list "$snapshot" "$images_list" "$DEBUG" > "$kill_file"

  local ids_to_kill=()
  # Process the results
  while IFS='|' read -r img_id img_tag; do
    [[ -z "$img_id" ]] && continue
    ids_to_kill+=("$img_id")

    if [[ "$dry_run" == "true" ]]; then
      echo -e "  ${BLUE}[DRY-RUN]${NC} Would remove: $img_tag ($img_id)"
    else
      echo -e "  ${RED}[TARGET]${NC} $img_tag ($img_id)"
    fi
  done < <(sort -u "$kill_file")

  if [[ ${#ids_to_kill[@]} -gt 0 ]]; then
    if [[ "$dry_run" == "true" ]]; then
      echo -e "\n${YELLOW}[DRY-RUN] Found ${#ids_to_kill[@]} unique images to purge.${NC}"
    else
      echo -e "\n${GREEN}[ACTION] Removing ${#ids_to_kill[@]} images...${NC}"
      # Chunk the IDs to prevent "Argument list too long" if there are hundreds
      echo "${ids_to_kill[@]}" | xargs -n 50 "$CRICTL" rmi >/dev/null 2>&1 || true
    fi
  else
    echo -e "  ${GREEN}[INFO] Nothing to do, no images match purge criteria.${NC}"
  fi

# --- ADDED: After Report ---
  local end_kb=$(get_avail_kb)
  local diff_mb=$(( (end_kb - start_kb) / 1024 ))

  echo ""
  log_cri_disk_usage "AFTER"

  if [[ "$dry_run" != "true" && $diff_mb -gt 0 ]]; then
    echo -e "${GREEN}----------------------------------------------"
    echo -e "RECLAIMED SPACE: ${diff_mb} MB"
    echo -e "----------------------------------------------${NC}"
  fi
  # ---------------------------

  echo -e "${GREEN}>>> IMAGE CLEANUP FINISHED${NC}"
}

prepare_images_list() {
  local input_path="$1"
  local tmp_file="$TMP_DIR/working_image_list.txt"

  if [[ ! "$input_path" =~ ^http ]]; then
    if [[ ! -f "$input_path" ]]; then
      echo -e "${RED}[ERROR] Local file '$input_path' not found.${NC}" >&2
      return 1
    fi
    tmp_file="$input_path"
  else
    echo -e " ${BLUE}[INFO]${NC} Fetching remote list: $input_path..." >&2
    if ! curl -fsSL --max-time 15 -o "$tmp_file" "$input_path"; then
      echo -e "${RED}[ERROR] Download failed for: $input_path${NC}" >&2
      return 1
    fi
  fi

  local file_size=$(stat -c%s "$tmp_file" 2>/dev/null || stat -f%z "$tmp_file")
  if [[ $file_size -gt 102400 ]]; then
    echo -e "${RED}[ERROR] File too large ($((file_size/1024))KB). Max 100KB.${NC}" >&2
    return 1
  fi

  if [[ "$(file -b --mime-type "$tmp_file")" != text/* ]]; then
    echo -e "${RED}[ERROR] File is not text.${NC}" >&2
    return 1
  fi

  if ! grep -vE '^\s*#' "$tmp_file" | grep -qE "[^#]+:[^#]+"; then
    echo -e "${RED}[ERROR] File missing image tags (repo:tag).${NC}" >&2
    return 1
  fi

  echo "$tmp_file"
}

parse_params() {
  local _dry_run=false
  local _version=""
  local _images_list=""
  local _debug=false
  local _download_only=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --version)
        if [[ -z "$2" || "$2" == --* ]]; then
          echo -e "${RED}Error: --version requires a value (e.g., v1.9.0)${NC}"
          usage 1
        fi
        _version="$2"
        shift 2
        ;;
      --images-list)
        if [[ -z "$2" || "$2" == --* ]]; then
          echo -e "${RED}Error: --images-list requires a file path or URL${NC}"
          usage 1
        fi
        _images_list="$2"
        shift 2
        ;;
      --dry-run)
        _dry_run=true
        shift
        ;;
      --debug)
        _debug=true
        shift
        ;;
      --download-only)
        _download_only=true
        shift
        ;;
      -h|--help)
        usage 0
        ;;
      *)
        echo -e "${RED}Error: Invalid option '$1'${NC}"
        usage 1
        ;;
    esac
  done

  if [[ -z "$_version" ]]; then
    echo -e "${RED}Error: Missing current cluster version (--version)${NC}"
    usage 1
  fi

  get_arch
  DRY_RUN="$_dry_run"
  DEBUG="$_debug"
  VERSION="$_version"
  DOWNLOAD_ONLY="$_download_only"

  # Use the BASE_URL constant for the default fallback
  IMAGES_LIST="${_images_list:-${BASE_URL}/${VERSION}-${TARGET_ARCH}-images-list.txt}"

  if [[ "$DOWNLOAD_ONLY" == "false" ]]; then
    echo -e "${MAGENTA}Parameters accepted:"
    echo "  Cluster Version: $VERSION"
    echo "  Dry Run:         $DRY_RUN"
    echo "  Debug:           $DEBUG"
    echo -e "  Images List:     $IMAGES_LIST${NC}"
  fi
}

main() {
  parse_params "$@"

  if [[ "$EUID" -ne 0 ]]; then
    echo -e "${RED}Error: This script must be run as root.${NC}" >&2
    exit 1
  fi

  if [[ "$DOWNLOAD_ONLY" == "true" ]]; then
    download_official_lists
  fi

  if [[ ! -x "$CRICTL" ]]; then
    echo -e "${RED}Error: crictl binary not found at $CRICTL${NC}" >&2
    exit 1
  fi

  local final_list_path
  if ! final_list_path=$(prepare_images_list "$IMAGES_LIST"); then
    echo -e "${RED}>>> Aborting execution.${NC}" >&2
    exit 1
  fi

  cleanup_images "$DRY_RUN" "$final_list_path"
}

main "$@"
