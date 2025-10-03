#!/usr/bin/env bash

set -euo pipefail

# Convenience installer for Aeternity node using Docker Compose.
# - Downloads a .tar.zst archive and extracts into a local directory
# - Downloads a docker compose file and aeternity.yaml from a public repo
# - Generates a docker-compose.override.yml to map host data dir and config file into the container
# - Optionally starts the service via docker compose
#
# Usage:
#   Interactive (default):
#     ./get-aeternity.sh
#
#   Non-interactive via environment variables:
#     TARBALL_URL=... AETERNITY_YAML_URL=... INSTALL_DIR=/path \
#     RUN_NOW=true ./get-aeternity.sh --yes
#
# Flags:
#   -y, --yes, --non-interactive  Run without prompts, using ENV/defaults
#   --no-start                    Do not start the compose service after setup
#   -h, --help                    Show help
#
# ENV variables (all optional; script will prompt when missing unless non-interactive):
#   TARBALL_URL            URL to the node .tar.zst file (optional if NETWORK/DB_VARIANT provided)
#   MDW_TARBALL_URL        URL to the MDW .tar.zst file (optional; defaults by NETWORK)
#   NETWORK                Network to support: mainnet or testnet/uat (default: mainnet)
#   DB_VARIANT             Database variant to download: full or light (default: full; env-only, no prompt)
#   DOWNLOAD_NODE_DB       If 'false', skip node DB download/extract (default: true)
#   DOWNLOAD_MDW_DB        If 'false', skip MDW DB download/extract (default: true)
#   AETERNITY_YAML_URL     URL to the aeternity.yaml (optional; defaults to GitHub template, env override available)
#   COMPOSE_URL            URL to docker-compose.yml (optional; defaults to GitHub template, env override available)
#   INSTALL_DIR            Local directory for installation (default: current working directory)
#   RUN_NOW                If set to 'false', will not start the service (default: true)

VERSION="0.1.0"

info() { echo -e "\033[1;34m[INFO]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
err()  { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; }

usage() {
  cat <<EOF
get-aeternity.sh v${VERSION}

Convenience installer for Aeternity node using Docker Compose.

Options:
  -y, --yes, --non-interactive  Run without prompts, using ENV/defaults
      --no-start                Do not start the compose service after setup
  -h, --help                    Show this help and exit

Environment variables:
  TARBALL_URL, MDW_TARBALL_URL, NETWORK, DB_VARIANT, DOWNLOAD_NODE_DB, DOWNLOAD_MDW_DB,
  AETERNITY_YAML_URL, COMPOSE_URL, INSTALL_DIR, RUN_NOW

EOF
}

NON_INTERACTIVE=false
START_AFTER=true

while [[ ${1:-} ]]; do
  case "$1" in
    -y|--yes|--non-interactive)
      NON_INTERACTIVE=true; shift ;;
    --no-start)
      START_AFTER=false; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      err "Unknown option: $1"; usage; exit 1 ;;
  esac
done

# Defaults
DEFAULT_AETERNITY_YAML_URL="https://raw.githubusercontent.com/aeternity/get-aeternity/master/templates/aeternity.yaml"
DEFAULT_COMPOSE_URL="https://raw.githubusercontent.com/aeternity/get-aeternity/master/templates/docker-compose.yml"
INSTALL_DIR_DEFAULT="$(pwd)"
:

# Detect if NETWORK was provided via env before applying default (to avoid set -u errors)
NETWORK_FROM_ENV="${NETWORK-}"

# Read env or set defaults
TARBALL_URL="${TARBALL_URL:-}"
MDW_TARBALL_URL="${MDW_TARBALL_URL:-}"
NETWORK="${NETWORK:-mainnet}"

# Remember URL overrides (non-empty means provided)
TARBALL_URL_FROM_ENV="${TARBALL_URL}"
MDW_TARBALL_URL_FROM_ENV="${MDW_TARBALL_URL}"
DB_VARIANT="${DB_VARIANT:-full}"
AETERNITY_YAML_URL="${AETERNITY_YAML_URL:-$DEFAULT_AETERNITY_YAML_URL}"
COMPOSE_URL="${COMPOSE_URL:-$DEFAULT_COMPOSE_URL}"
INSTALL_DIR="${INSTALL_DIR:-$INSTALL_DIR_DEFAULT}"
DOWNLOAD_NODE_DB="${DOWNLOAD_NODE_DB:-true}"
DOWNLOAD_MDW_DB="${DOWNLOAD_MDW_DB:-true}"
:

# Helpers
have_cmd() { command -v "$1" >/dev/null 2>&1; }

need_cmd() {
  if ! have_cmd "$1"; then
    err "Required command '$1' not found. Please install it and re-run."
    exit 1
  fi
}

detect_compose_cmd() {
  if have_cmd docker && docker compose version >/dev/null 2>&1; then
    echo "docker compose"
  elif have_cmd docker-compose; then
    echo "docker-compose"
  else
    err "Docker Compose not found. Install Docker with Compose plugin (docker compose) or docker-compose."
    exit 1
  fi
}

normalize_network() {
  local n="${1,,}"
  case "$n" in
    mainnet) echo "mainnet" ;;
    testnet|uat) echo "uat" ;;
    *) err "Invalid NETWORK '$1'. Allowed: mainnet, testnet (uat)."; exit 1 ;;
  esac
}

normalize_variant() {
  local v="${1,,}"
  case "$v" in
    full|light) echo "$v" ;;
    *) err "Invalid DB_VARIANT '$1'. Allowed: full, light."; exit 1 ;;
  esac
}

compute_tarball_url() {
  local net="$1" var="$2"
  local base="https://aeternity-database-backups.s3.eu-central-1.amazonaws.com"
  case "$net:$var" in
    mainnet:full)  echo "$base/main_v1_full_latest.tar.zst" ;;
    mainnet:light) echo "$base/main_v1_light_latest.tar.zst" ;;
    uat:full)      echo "$base/uat_v1_full_latest.tar.zst" ;;
    uat:light)     echo "$base/uat_v1_light_latest.tar.zst" ;;
    *) err "Unknown network/variant combination: $net/$var"; exit 1 ;;
  esac
}

compute_mdw_tarball_url() {
  local net="$1"
  local base="https://aeternity-database-backups.s3.eu-central-1.amazonaws.com"
  case "$net" in
    mainnet) echo "$base/mdw_main_latest.tar.zst" ;;
    uat)     echo "$base/mdw_uat_latest.tar.zst" ;;
    *) err "Unknown network for MDW archive: $net"; exit 1 ;;
  esac
}

download() {
  local url="$1" out="$2"
  if have_cmd curl; then
    curl -fsSL "$url" -o "$out"
  elif have_cmd wget; then
    wget -qO "$out" "$url"
  else
    err "Neither curl nor wget found. Please install one."
    exit 1
  fi
}

# Retrieve content length (bytes) of a remote URL using HEAD; returns empty on failure
get_content_length() {
  local url="$1" headers="" cl=""
  if have_cmd curl; then
    headers=$(curl -fsIL "$url" 2>/dev/null || true)
  elif have_cmd wget; then
    headers=$(wget --spider --server-response -O /dev/null "$url" 2>&1 || true)
  fi
  cl=$(printf '%s' "$headers" | awk 'tolower($1)=="content-length:" {cl=$2} END{gsub("\r","",cl); if(cl!="") print cl}')
  echo "$cl"
}

# Format bytes into human readable size (MB / GB)
human_size() {
  local bytes="$1"
  if [[ -z "$bytes" ]] || ! [[ "$bytes" =~ ^[0-9]+$ ]] || [[ "$bytes" -eq 0 ]]; then
    printf "%s" "unknown"; return
  fi
  if (( bytes > 1073741824 )); then
    awk -v b="$bytes" 'BEGIN { printf "%.2f GB", b/1073741824 }'
  else
    awk -v b="$bytes" 'BEGIN { printf "%.2f MB", b/1048576 }'
  fi
}

prompt_var() {
  local var_name="$1" prompt_text="$2" default_val="$3"
  local current_val
  # shellcheck disable=SC2223
  current_val="${!var_name:-}"
  if [[ "$NON_INTERACTIVE" == true ]]; then
    if [[ -z "$current_val" && -n "$default_val" ]]; then
      printf -v "$var_name" '%s' "$default_val"
    fi
    return
  fi
  local prompt="$prompt_text"
  if [[ -n "$default_val" ]]; then
    prompt+=" [$default_val]"
  fi
  read -r -p "$prompt" input || true
  if [[ -n "$input" ]]; then
    printf -v "$var_name" '%s' "$input"
  elif [[ -z "$current_val" && -n "$default_val" ]]; then
    printf -v "$var_name" '%s' "$default_val"
  fi
}

confirm() {
  local msg="$1"
  if [[ "$NON_INTERACTIVE" == true ]]; then
    return 0
  fi
  read -r -p "$msg [Y/n]: " ans || true
  case "$ans" in
    ""|y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

ensure_prereqs() {
  need_cmd tar
  need_cmd docker
  detect_compose_cmd >/dev/null
  if ! tar --help 2>/dev/null | grep -q "zstd"; then
    if ! have_cmd unzstd; then
      warn "Your tar may not support zstd, and 'unzstd' is missing. Install 'zstd' package if extraction fails."
    fi
  fi
}

extract_tar_zst() {
  local archive="$1" dest_dir="$2"
  mkdir -p "$dest_dir"
  if tar --help 2>/dev/null | grep -q "zstd"; then
    info "Extracting (tar --zstd) to $dest_dir ..."
    tar --zstd -xf "$archive" -C "$dest_dir"
  else
    if have_cmd unzstd; then
      info "Decompressing with unzstd ..."
      local tmp_tar
      tmp_tar="${archive%.zst}"
      unzstd -f -q "$archive" -o "$tmp_tar"
      info "Extracting tar to $dest_dir ..."
      tar -xf "$tmp_tar" -C "$dest_dir"
      rm -f "$tmp_tar"
    else
      err "Cannot extract: tar has no zstd support and 'unzstd' is not available. Install 'zstd' and retry."
      exit 1
    fi
  fi
}

main() {
  ensure_prereqs

  # Always normalize DB_VARIANT from env (env-only with default 'full')
  DB_VARIANT="$(normalize_variant "$DB_VARIANT")"

  if [[ "$NON_INTERACTIVE" == true ]]; then
    # Non-interactive mode: use env values, compute URLs if not provided
    NETWORK="$(normalize_network "$NETWORK")"
    
    # Compute TARBALL_URL if not provided via env
    if [[ -z "$TARBALL_URL" ]]; then
      TARBALL_URL="$(compute_tarball_url "$NETWORK" "$DB_VARIANT")"
    fi
    
    # Compute MDW_TARBALL_URL if not provided via env
    if [[ -z "$MDW_TARBALL_URL" ]]; then
      MDW_TARBALL_URL="$(compute_mdw_tarball_url "$NETWORK")"
    fi
  else
    # Interactive mode: structured flow

    prompt_var INSTALL_DIR "Installation directory (empty for current)" "$INSTALL_DIR"
    
    # Step 1: Ask for network if not overridden by env
    if [[ -n "$NETWORK_FROM_ENV" ]]; then
      # NETWORK was provided via env, just normalize it
      NETWORK="$(normalize_network "$NETWORK")"
    else
      # No env override, prompt for network
      prompt_var NETWORK "Network (mainnet|testnet/uat)" "$NETWORK"
      NETWORK="$(normalize_network "$NETWORK")"
    fi
    
    # Step 2: Prepare candidate URLs (compute if not overridden) to probe sizes
    local _candidate_node_url _candidate_mdw_url
    if [[ -n "$TARBALL_URL_FROM_ENV" ]]; then
      _candidate_node_url="$TARBALL_URL_FROM_ENV"
    else
      _candidate_node_url="$(compute_tarball_url "$NETWORK" "$DB_VARIANT")"
    fi
    if [[ -n "$MDW_TARBALL_URL_FROM_ENV" ]]; then
      _candidate_mdw_url="$MDW_TARBALL_URL_FROM_ENV"
    else
      _candidate_mdw_url="$(compute_mdw_tarball_url "$NETWORK")"
    fi

    info "Probing remote archive sizes ..."
    local node_cl mdw_cl node_h mdw_h total_bytes="" total_h=""
    node_cl="$(get_content_length "$_candidate_node_url")"
    mdw_cl="$(get_content_length "$_candidate_mdw_url")"
    node_h="$(human_size "$node_cl")"
    mdw_h="$(human_size "$mdw_cl")"
    if [[ -n "$node_cl" && -n "$mdw_cl" ]]; then
      total_bytes=$(( node_cl + mdw_cl ))
      total_h="$(human_size "$total_bytes")"
    fi

    echo "  Node DB archive: $_candidate_node_url (${node_h})"
    echo "  MDW  DB archive: $_candidate_mdw_url (${mdw_h})"
    if [[ -n "$total_h" ]]; then
      info "  Combined compressed size: ${total_h}"
      # Calculate 2.5x estimated required free space (bytes * 2.5)
      # Using awk to avoid bash integer overflow for very large numbers
      local required_bytes required_h
      required_bytes="$(awk -v t="$total_bytes" 'BEGIN { printf "%.0f", t * 2.5 }')"
      required_h="$(human_size "$required_bytes")"
      warn "  Estimated required space (2.5x compressed total): ${required_h} (approx)"
    else
      warn "  (One or both sizes could not be determined; ensure you have ample disk space.)"
    fi

    # Step 3: Ask once if they want to download both snapshots/tarballs
    if confirm "Download and extract the databases (node + MDW) now?"; then
      DOWNLOAD_NODE_DB=true
      DOWNLOAD_MDW_DB=true
      # Persist the computed URLs if they were not provided via env
      if [[ -z "$TARBALL_URL_FROM_ENV" ]]; then
        TARBALL_URL="$_candidate_node_url"
      fi
      if [[ -z "$MDW_TARBALL_URL_FROM_ENV" ]]; then
        MDW_TARBALL_URL="$_candidate_mdw_url"
      fi
      info "Large downloads starting – this may take a while. Please be patient while archives download and extract."
    else
      DOWNLOAD_NODE_DB=false
      DOWNLOAD_MDW_DB=false
      # Even if not downloading we still retain URLs for summary display (already set if env overrides)
      if [[ -z "$TARBALL_URL_FROM_ENV" ]]; then
        TARBALL_URL="$_candidate_node_url"
      fi
      if [[ -z "$MDW_TARBALL_URL_FROM_ENV" ]]; then
        MDW_TARBALL_URL="$_candidate_mdw_url"
      fi
    fi
  fi


  # Do not prompt for COMPOSE_URL; env-only

  info "Summary:"
  echo "  NETWORK               = $NETWORK"
  echo "  DOWNLOAD_NODE_DB      = $DOWNLOAD_NODE_DB"
  echo "  TARBALL_URL           = $TARBALL_URL"
  echo "  DOWNLOAD_MDW_DB       = $DOWNLOAD_MDW_DB"
  echo "  MDW_TARBALL_URL       = $MDW_TARBALL_URL"
  echo "  DB_VARIANT            = $DB_VARIANT"
  echo "  AETERNITY_YAML_URL    = $AETERNITY_YAML_URL"
  echo "  COMPOSE_URL           = $COMPOSE_URL"
  echo "  INSTALL_DIR           = $INSTALL_DIR"
  # Service name is fixed by template; no legacy container path variables
  echo "  START_AFTER           = $START_AFTER"

  if ! confirm "Proceed with these settings?"; then
    info "Aborted by user."; exit 0
  fi

  mkdir -p "$INSTALL_DIR"
  local downloads_dir="$INSTALL_DIR/downloads"
  mkdir -p "$downloads_dir"

  # Derive host network label for paths (mainnet|testnet)
  local HOST_NETWORK_LABEL
  if [[ "$NETWORK" == "uat" ]]; then HOST_NETWORK_LABEL="testnet"; else HOST_NETWORK_LABEL="mainnet"; fi

  # Defaults for host paths used by compose
  local HOST_DATA_ROOT_DEFAULT="$INSTALL_DIR/data/${HOST_NETWORK_LABEL}"
  local HOST_APP_ROOT_DEFAULT="$INSTALL_DIR/app/${HOST_NETWORK_LABEL}"

  # Allow override via env if provided
  local HOST_DATA_ROOT="${HOST_DATA_ROOT:-$HOST_DATA_ROOT_DEFAULT}"
  local HOST_APP_ROOT="${HOST_APP_ROOT:-$HOST_APP_ROOT_DEFAULT}"

  # Prepare host directories
  mkdir -p "$HOST_DATA_ROOT/mnesia" "$HOST_DATA_ROOT/mdw.db" "$HOST_APP_ROOT/log"

  # Node DB
  if [[ "$DOWNLOAD_NODE_DB" == true ]]; then
    local tar_name
    tar_name="$(basename "$TARBALL_URL")"
    local tar_path="$downloads_dir/$tar_name"
    info "Downloading node archive ..."
    download "$TARBALL_URL" "$tar_path"
    info "Extracting node archive ..."
    extract_tar_zst "$tar_path" "$HOST_DATA_ROOT"
  else
    info "Skipping node DB download."
  fi

  # MDW DB
  if [[ "$DOWNLOAD_MDW_DB" == true && -n "$MDW_TARBALL_URL" ]]; then
    local mdw_tar_name mdw_tar_path
    mdw_tar_name="$(basename "$MDW_TARBALL_URL")"
    mdw_tar_path="$downloads_dir/$mdw_tar_name"
    info "Downloading MDW archive ..."
    download "$MDW_TARBALL_URL" "$mdw_tar_path"
    info "Extracting MDW archive ..."
    extract_tar_zst "$mdw_tar_path" "$HOST_DATA_ROOT"
  else
    info "Skipping MDW DB download."
  fi

  local compose_path="$INSTALL_DIR/docker-compose.yml"
  local config_path="$HOST_APP_ROOT/aeternity.yaml"

  # docker-compose.yml: keep if exists; else download if COMPOSE_URL provided, otherwise copy local template
  local SCRIPT_DIR TEMPLATE_DIR_DEFAULT
  SCRIPT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
  TEMPLATE_DIR_DEFAULT="$SCRIPT_DIR/templates"
  if [[ -f "$compose_path" ]]; then
    info "docker-compose.yml already exists; leaving it unchanged."
  else
    if [[ -n "$COMPOSE_URL" ]]; then
      info "Downloading docker-compose.yml ..."
      download "$COMPOSE_URL" "$compose_path"
    else
      info "Copying docker-compose.yml from local template"
      local tpl_compose="$TEMPLATE_DIR_DEFAULT/docker-compose.yml"
      if [[ ! -f "$tpl_compose" ]]; then err "Template not found: $tpl_compose"; exit 1; fi
      cp "$tpl_compose" "$compose_path"
    fi
  fi

  # Ensure aeternity.yaml exists; keep if present, else download if env URL provided, otherwise copy local template
  if [[ -f "$config_path" ]]; then
    info "aeternity.yaml already exists; leaving it unchanged."
  else
    if [[ -n "$AETERNITY_YAML_URL" ]]; then
      info "Downloading aeternity.yaml ..."
      download "$AETERNITY_YAML_URL" "$config_path"
    else
      info "Copying aeternity.yaml from local template"
      local tpl_ay="$TEMPLATE_DIR_DEFAULT/aeternity.yaml"
      if [[ ! -f "$tpl_ay" ]]; then err "Template not found: $tpl_ay"; exit 1; fi
      cp "$tpl_ay" "$config_path"
    fi
  fi

  # Now patch the two unique lines based on NETWORK and DB_VARIANT
  if [[ "$(normalize_network "$NETWORK")" == "mainnet" ]]; then
    # Replace ae_uat -> ae_mainnet on the exact network_id line
    sed -i 's/^\(\s*network_id:\s*\)ae_uat$/\1ae_mainnet/' "$config_path"
  else
    # Ensure ae_uat (default) remains if coming from custom yaml
    sed -i 's/^\(\s*network_id:\s*\)ae_mainnet$/\1ae_uat/' "$config_path"
  fi

  if [[ "$(normalize_variant "$DB_VARIANT")" == "full" ]]; then
    sed -i 's/^\(\s*enabled:\s*\)false$/\1true/' "$config_path"
  else
    sed -i 's/^\(\s*enabled:\s*\)true$/\1false/' "$config_path"
  fi

  # Compose environment variables (.env)
  local env_path="$INSTALL_DIR/.env"
  local elixir_opts_default="-sbwt none -sbwtdcpu none -sbwtdio none"
  local log_file_path_default="/home/aeternity/ae_mdw/log/info.log"
  info "Writing compose .env at $env_path ..."
  cat > "$env_path" <<ENV
# Generated by get-aeternity.sh
HOST_NETWORK_LABEL=${HOST_NETWORK_LABEL}
HOST_DATA_ROOT=${HOST_DATA_ROOT}
HOST_APP_ROOT=${HOST_APP_ROOT}
ELIXIR_ERL_OPTIONS=${ELIXIR_OPTS:-$elixir_opts_default}
LOG_FILE_PATH=${LOG_FILE_PATH:-$log_file_path_default}
ENV

  local compose_cmd
  compose_cmd="$(detect_compose_cmd)"

  info "Docker Compose files prepared:\n  - $compose_path\n  - $env_path"

  if [[ "$START_AFTER" == true ]]; then
  info "Pulling latest images ..."
    (cd "$INSTALL_DIR" && $compose_cmd pull)
  info "Starting services ..."
    (cd "$INSTALL_DIR" && $compose_cmd up -d)
  info "Services started. Use: (cd '$INSTALL_DIR' && $compose_cmd ps)"
  else
    info "Skipping start. To run later: (cd '$INSTALL_DIR' && $(detect_compose_cmd) up -d)"
  fi

  info "Done. Data dir: $HOST_DATA_ROOT | App dir: $HOST_APP_ROOT"
}

main "$@"
