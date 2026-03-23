#!/bin/bash
set -e

# Defaults
VERSIONS_FILE="./versions.yaml"
TARGET_VERSION=""
TARGET_VERSION_IMAGES=""
DEBUG=false
ARCHS=("amd64" "arm64")
TARGET_FILE_NAME="images-list.txt"

TMP_DIR=$(mktemp -d)
CURRENT_PATH=$(pwd)

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

usage()
{
  echo "Usage: $0 [OPTIONS]"
  echo ""
  echo "Options:"
  echo "  --versions-file <path>             Path to versions.yaml which lists all Harvester version in order"
  echo "  --target-harvester-version <ver>   Target Harvester version (e.g., v1.7.0)"
  echo "  --target-version-images <path>     (Optional) Manual image list when a version is not released (e.g. v1.8.0)"
  echo "  --debug                            Enable verbose logging and curl output"
  echo ""
  exit 1
}

# ./generate-image-lists.sh --versions-file ./versions.yaml --target-harvester-version v1.7.0
# ./generate-image-lists.sh --versions-file ./versions.yaml --target-harvester-version v1.7.0 --debug

# when a new version is not available yet, add a local file and it will not fetch remote
# ./generate-image-lists.sh --versions-file ./versions.yaml --target-harvester-version v1.8.0 --target-version-images ./v180-images-lists.txt

parse_params()
{
  while [[ "$#" -gt 0 ]]; do
    case $1 in
      --versions-file)
        if [[ -n "$2" && "$2" != --* ]]; then
          VERSIONS_FILE="$2"
          shift
        else
          echo "Error: --versions-file requires a value."
          usage
        fi
        ;;
      --target-harvester-version)
        if [[ -n "$2" && "$2" != --* ]]; then
          TARGET_VERSION="$2"
          shift
        else
          echo "Error: --target-harvester-version requires a value."
          usage
        fi
        ;;
      --target-version-images)
        if [[ -n "$2" && "$2" != --* ]]; then
          TARGET_VERSION_IMAGES="$2"
          shift
        else
          echo "Error: --target-version-images requires a value."
          usage
        fi
        ;;
      --debug)
        DEBUG=true
        set -x
        ;;
      *)
        usage
        ;;
    esac
    shift
  done
}

process_and_report()
{
  local input_file=$1
  local label=$2
  local output_file="$input_file.processed"

  local total_count=$(wc -l < "$input_file")
  local qualified_count=$(grep -vE '^(#|$)' "$input_file" | wc -l)
  local unqualified_count=$((total_count - qualified_count))

  # Normalize and Sort
  grep -vE '^(#|$)' "$input_file" | awk -F'/' '{print $NF}' | LC_ALL=C sort -u > "$output_file"
  
  local unique_count=$(wc -l < "$output_file")
  local duplicated_count=$((qualified_count - unique_count))

  printf "[%s] Total lines: %d | Qualified: %d | Duplicated: %d | Comments/Blank: %d\n" \
    "$label" "$total_count" "$qualified_count" "$duplicated_count" "$unqualified_count" >&2

  echo "$output_file"
}

get_remote_tar_content()
{
  local version=$1
  local arch=$2
  local append_to=$3
  local remote="https://releases.rancher.com/harvester/$version/image-lists-$arch.tar.gz"
  local local_tar="$TMP_DIR/${version}_${arch}.tar.gz"

  local curl_opts="-fL"
  if [[ "$DEBUG" = false ]]; then
    curl_opts="-sfL"
  fi

  # Strict check: Fail out if curl fails (404, network error, etc.)
  if curl $curl_opts "$remote" -o "$local_tar"; then
    local extract_path="$TMP_DIR/extract/$version-$arch"
    mkdir -p "$extract_path"
    tar -zxf "$local_tar" -C "$extract_path"
    cat "$extract_path"/image-lists/*.txt >> "$append_to"
  else
    echo "Error: Failed to download $remote. Aborting." >&2
    exit 1
  fi
}

run_arch_pipeline()
{
  local arch=$1
  local arch_tmp="$TMP_DIR/$arch"
  mkdir -p "$arch_tmp"

  local target_raw="$arch_tmp/target-raw.txt"
  local past_raw="$arch_tmp/past-raw.txt"
  touch "$target_raw" "$past_raw"

  echo "--- Starting Pipeline for Architecture: $arch ---"

  # 1. Collect Target Data
  if [[ -n "$TARGET_VERSION_IMAGES" ]]; then
    if [[ -f "$TARGET_VERSION_IMAGES" ]]; then
      cat "$TARGET_VERSION_IMAGES" > "$target_raw"
    else
      echo "Error: $TARGET_VERSION_IMAGES not found."
      exit 1
    fi
  else
    get_remote_tar_content "$TARGET_VERSION" "$arch" "$target_raw"
  fi

  # 2. Collect Past Data
  local past_versions=$(yq -r ".versions.active | (to_entries | .[] | select(.value == \"$TARGET_VERSION\") | .key) as \$idx | .[(\$idx + 1):] | .[]" "$VERSIONS_FILE")
  
  for v in $past_versions; do
    get_remote_tar_content "$v" "$arch" "$past_raw"
  done

  # 3. Process and Report
  echo "Processing target images..."
  local target_sorted=$(process_and_report "$target_raw" "TARGET-$arch")
  
  echo "Processing past images..."
  local past_sorted=$(process_and_report "$past_raw" "PAST-COMBINED-$arch")

  # 4. Final Diff
  local output_dir="$CURRENT_PATH/lists"
  mkdir -p "$output_dir"
  local final_output="$output_dir/$TARGET_VERSION-$arch-$TARGET_FILE_NAME"

  # Compare the combined past images against the target version images.
  # -2: Suppress lines appearing only in the target file (File 2).
  # -3: Suppress lines appearing in both files (common images).
  # Result: Only images that existed in the past but ARE NOT in the target version
  LC_ALL=C comm -23 "$past_sorted" "$target_sorted" > "$final_output"
  
  echo "Done: $final_output contains $(wc -l < "$final_output") images to remove."
  echo "$final_output" >> "$TMP_DIR/summary_paths.txt"
}

main()
{
  parse_params "$@"

  if [[ -z "$TARGET_VERSION" ]]; then
    usage
  fi

  for ARCH in "${ARCHS[@]}"; do
    run_arch_pipeline "$ARCH"
  done

  echo ""
  echo "========================================================="
  echo " FINAL SUMMARY"
  echo "========================================================="
  if [[ -f "$TMP_DIR/summary_paths.txt" ]]; then
    while read -r path; do
      printf "File: %s | Images: %d\n" "$(basename "$path")" "$(wc -l < "$path")"
    done < "$TMP_DIR/summary_paths.txt"
  fi
}

main "$@"
