#!/usr/bin/env bash
# clone.sh - Repository cloning module
# Handles cloning repositories with logging and idempotency

# Ensure common.sh is sourced
if [[ -z "${WORK_DIR:-}" ]]; then
  source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
fi

# ============================================================================
# Clone operations
# ============================================================================

# Clone a repository or update if it already exists
# Usage: clone_repo <url> <project_key>
# Returns: 0 on success, 1 on failure
clone_repo() {
  local url="$1"
  local key="$2"
  local target_dir="${WORK_DIR}/${key}"
  local log_dir="${LOG_DIR}/${key}"
  local log_file="${log_dir}/clone.log"
  
  ensure_dir "$log_dir"
  
  log_info "Cloning repository: $url"
  
  # Check if directory already exists
  if [[ -d "$target_dir" ]]; then
    # Verify it's the correct repository
    local existing_remote=""
    if [[ -d "${target_dir}/.git" ]]; then
      existing_remote="$(git -C "$target_dir" remote get-url origin 2>/dev/null || echo "")"
    fi
    
    if [[ "$existing_remote" == "$url" ]]; then
      log_info "Repository already cloned, fetching latest..."
      
      if run_logged "$log_file" git -C "$target_dir" fetch --depth 1 origin; then
        if run_logged "$log_file" git -C "$target_dir" reset --hard origin/HEAD; then
          log_success "Updated existing clone: $key"
          return 0
        fi
      fi
      
      # Fetch failed, try fresh clone
      log_warn "Fetch failed, attempting fresh clone..."
      rm -rf "$target_dir"
    else
      # Different repository or corrupted, remove and re-clone
      log_warn "Directory exists but has different remote, re-cloning..."
      rm -rf "$target_dir"
    fi
  fi
  
  # Fresh clone
  ensure_dir "$(dirname "$target_dir")"
  
  if run_logged "$log_file" git clone --depth 1 "$url" "$target_dir"; then
    log_success "Cloned repository: $key"
    return 0
  else
    log_error "Failed to clone repository: $url"
    return 1
  fi
}

# Remove a cloned repository
# Usage: clone_cleanup <project_key>
clone_cleanup() {
  local key="$1"
  local target_dir="${WORK_DIR}/${key}"
  
  if [[ -d "$target_dir" ]]; then
    log_info "Cleaning up: $target_dir"
    rm -rf "$target_dir"
  fi
}

# Check if a repository is already cloned
# Usage: clone_exists <project_key>
# Returns: 0 if exists, 1 if not
clone_exists() {
  local key="$1"
  local target_dir="${WORK_DIR}/${key}"
  
  [[ -d "$target_dir" && -d "${target_dir}/.git" ]]
}

# Get the path to a cloned repository
# Usage: clone_get_path <project_key>
clone_get_path() {
  local key="$1"
  echo "${WORK_DIR}/${key}"
}
