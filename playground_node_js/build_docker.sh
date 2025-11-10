#!/usr/bin/env bash
# ------------------------------------------------------------
# [+] Docker development environment for Node.js
#     - Host directory is bind‑mounted into /app inside the container
#     - Changes on host are visible instantly (real‑time)
# ------------------------------------------------------------

set -euo pipefail               # abort on error, undefined vars, pipeline failures
IFS=$'\n\t'                     # sane field splitting

# --------------------------------------------------------------------
# Configuration
# --------------------------------------------------------------------
readonly IMAGE_NAME="playground_node_js"
readonly CONTAINER_NAME="node_sandbox"

# Default host source directory (relative to script location)
readonly DEFAULT_HOST_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/node.work"

# --------------------------------------------------------------------
# Helper functions for prefixed output
# --------------------------------------------------------------------
info() { echo -e "\e[32m[+] $*\e[0m"; }   # green
warn() { echo -e "\e[31m[-] $*\e[0m" >&2; } # red
ok()   { echo -e "\e[34][*] $*\e[0m"; }   # blue

# --------------------------------------------------------------------
# Usage / argument handling
# --------------------------------------------------------------------
if [[ $# -gt 1 ]]; then
    warn "Usage: ${0##*/} [host_source_directory]"
    exit 1
fi

HOST_SRC="${1:-$DEFAULT_HOST_SRC}"

# --------------------------------------------------------------------
# Verify Docker is reachable
# --------------------------------------------------------------------
if ! docker version >/dev/null 2>&1; then
    warn "Docker daemon does not appear to be running or you are not in the 'docker' group."
    exit 1
fi

# --------------------------------------------------------------------
# Ensure host source directory exists
# --------------------------------------------------------------------
if [[ ! -d "$HOST_SRC" ]]; then
    info "Creating host source directory at '$HOST_SRC' ..."
    mkdir -p "$HOST_SRC"
    ok "Directory created."
else
    ok "Using existing host source directory: $HOST_SRC"
fi

# --------------------------------------------------------------------
# Build the Docker image (only if needed)
# --------------------------------------------------------------------
info "Building Docker image '${IMAGE_NAME}' ..."
docker build -t "${IMAGE_NAME}" . >/dev/null
ok "Image built successfully."

# --------------------------------------------------------------------
# Remove any stale container with the same name (just in case)
# --------------------------------------------------------------------
if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    info "Removing leftover container '${CONTAINER_NAME}' ..."
    docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
    ok "Old container removed."
fi

# --------------------------------------------------------------------
# Function: start the container (detached) and remember its ID
# --------------------------------------------------------------------
start_container() {
    info "Starting container '${CONTAINER_NAME}' ..."
    # --rm → Docker automatically deletes it when the main process exits.
    # --init → tiny init that forwards signals correctly.
    CONTAINER_ID=$(docker run -d \
        --name "${CONTAINER_NAME}" \
        --init \
        --rm \
        -v "${HOST_SRC}:/app:cached" \
        -w /app \
        -p 3000:3000 \
        "${IMAGE_NAME}" tail -F /dev/null)

    ok "Container is running (ID=${CONTAINER_ID})."
}

# --------------------------------------------------------------------
# Function: clean‑up – stop the container if it is still alive
# --------------------------------------------------------------------
cleanup() {
    info "Cleaning up ..."
    # This function may be called multiple times; guard against errors.
    if docker ps --format '{{.ID}}' --no-trunc | grep -q "^${CONTAINER_ID}$"; then
        info "Stopping container '${CONTAINER_NAME}' ..."
        docker stop "${CONTAINER_ID}" >/dev/null 2>&1 || true
        # Because we used --rm the container disappears automatically.
        ok "Container stopped and removed."
    fi
}
# Ensure cleanup runs on script exit, interrupt or termination.
trap cleanup EXIT SIGINT SIGTERM

# --------------------------------------------------------------------
# Main flow
# --------------------------------------------------------------------
start_container

info "Attaching bash shell inside the container ..."
docker exec -it "${CONTAINER_NAME}" bash

# When the user exits Bash, control returns here → trap will fire and clean up.
ok "Shell exited – container will be removed automatically."