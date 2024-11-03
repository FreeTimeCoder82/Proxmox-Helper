#!/bin/bash

# =============================================================================
# Script to create a cloud-init enabled Ubuntu 24.04 template on Proxmox VE
# Version: 2.0
# =============================================================================

set -euo pipefail  # Enable strict error handling
trap 'error_exit "Script interrupted"' INT TERM

# Define constants
readonly LOG_FILE="/var/log/proxmox-template-creator.log"
readonly SCRIPT_NAME=$(basename "$0")
readonly LOCK_FILE="/var/run/proxmox-template-creator.lock"
readonly TEMP_DIR=$(mktemp -d)
readonly RETRY_COUNT=3
readonly WAIT_TIME=5

# Logging function with log levels and rotation
log() {
    local level=$1
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Rotate log if larger than 10MB
    if [ -f "$LOG_FILE" ] && [ $(stat -f%z "$LOG_FILE" 2>/dev/null || stat -c%s "$LOG_FILE") -gt 10485760 ]; then
        mv "$LOG_FILE" "$LOG_FILE.old"
    fi
    
    echo "[$timestamp] [$level] $message" | tee -a "$LOG_FILE"
}

# Enhanced error handling function
error_exit() {
    local message=$1
    log "ERROR" "$message"
    
    # Cleanup
    cleanup
    
    # Release lock
    rm -f "$LOCK_FILE"
    
    exit 1
}

# Cleanup function
cleanup() {
    log "INFO" "Performing cleanup..."
    
    # Remove temporary files
    [ -d "$TEMP_DIR" ] && rm -rf "$TEMP_DIR"
    [ -f "${IMAGENAME:-}" ] && rm -f "${IMAGENAME}"
    
    # Cleanup VM if it was partially created
    if [ -n "${VMID:-}" ] && qm status "$VMID" &>/dev/null; then
        log "INFO" "Removing partially created VM ${VMID}..."
        qm destroy "$VMID" &>/dev/null || true
    fi
}

# Function to acquire lock
acquire_lock() {
    if [ -e "$LOCK_FILE" ]; then
        local pid=$(cat "$LOCK_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            error_exit "Another instance is running with PID $pid"
        else
            log "WARN" "Removing stale lock file"
            rm -f "$LOCK_FILE"
        fi
    fi
    echo $$ > "$LOCK_FILE"
}

# Function to check available resources
check_resources() {
    local required_memory=$1
    local required_cores=$2
    local required_storage=$3
    
    # Check available memory
    local available_memory=$(free -m | awk '/^Mem:/{print $7}')
    if [ "$available_memory" -lt "$required_memory" ]; then
        error_exit "Insufficient memory. Required: ${required_memory}MB, Available: ${available_memory}MB"
    fi
    
    # Check CPU cores
    local available_cores=$(nproc)
    if [ "$available_cores" -lt "$required_cores" ]; then
        error_exit "Insufficient CPU cores. Required: $required_cores, Available: $available_cores"
    fi
    
    # Check storage space
    local available_storage=$(df -BG "$TEMP_DIR" | awk 'NR==2 {print $4}' | sed 's/G//')
    if [ "$available_storage" -lt "$required_storage" ]; then
        error_exit "Insufficient storage space. Required: ${required_storage}GB, Available: ${available_storage}GB"
    fi
}

# Function to verify network connectivity
verify_network() {
    local bridge=$1
    if ! ip link show "$bridge" &>/dev/null; then
        error_exit "Network bridge $bridge does not exist"
    fi
    
    # Test internet connectivity
    for i in {1..3}; do
        if ping -c 1 cloud-images.ubuntu.com &>/dev/null; then
            return 0
        fi
        sleep 2
    done
    error_exit "No internet connectivity to download Ubuntu images"
}

# Enhanced usage function with colorized output
usage() {
    cat <<EOF
$(tput bold)Usage: $SCRIPT_NAME [-i VMID] [-n VMNAME] [-s STORAGE] [-b BRIDGE] [-m MEMORY] [-c CORES] [-d DISK_SIZE]$(tput sgr0)

Options:
  $(tput setaf 2)-i VMID$(tput sgr0)          Set the VM ID (e.g., 9999)
  $(tput setaf 2)-n VMNAME$(tput sgr0)        Set the VM name (e.g., ubuntu-2404-template)
  $(tput setaf 2)-s STORAGE$(tput sgr0)       Set the storage name (e.g., local-lvm)
  $(tput setaf 2)-b BRIDGE$(tput sgr0)        Set the network bridge (e.g., vmbr0)
  $(tput setaf 2)-m MEMORY$(tput sgr0)        Set the memory in MB (default: 2048)
  $(tput setaf 2)-c CORES$(tput sgr0)         Set the number of CPU cores (default: 1)
  $(tput setaf 2)-d DISK_SIZE$(tput sgr0)     Additional disk size in GB (default: 10)
  $(tput setaf 2)-h$(tput sgr0)               Show this help message
EOF
    exit 1
}

# Enhanced input validation functions
is_valid_vmid() {
    local id=$1
    if [[ ! "$id" =~ ^[0-9]+$ ]] || [ "$id" -lt 100 ] || [ "$id" -gt 999999999 ]; then
        return 1
    fi
    
    # Check if ID is already in use
    if qm status "$id" &>/dev/null; then
        return 1
    fi
    return 0
}

is_valid_vmname() {
    [[ "$1" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]{0,62}$ ]] && ! qm list | grep -q " $1 "
}

# Function to verify storage
verify_storage() {
    local storage=$1
    if ! pvesm status | grep -q "^$storage"; then
        error_exit "Storage '$storage' not found"
    fi
}

# Enhanced system requirements check
check_requirements() {
    log "INFO" "Checking system requirements..."
    
    local required_commands=("wget" "qm" "pvesm" "sha256sum" "ping" "ip")
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            error_exit "Required command '$cmd' not found"
        fi
    done

    # Check if running as root
    if [ "$(id -u)" -ne 0 ]; then
        error_exit "This script must be run as root"
    fi

    # Check Proxmox version
    if ! pveversion &>/dev/null; then
        error_exit "This script must be run on a Proxmox VE system"
    fi
}

# Function to wait for LVM operations
wait_for_lvm() {
    local volume=$1
    local max_attempts=30
    local attempt=1
    
    log "INFO" "Waiting for LVM operation to complete..."
    while [ $attempt -le $max_attempts ]; do
        if lvs "$volume" &>/dev/null; then
            sleep 1  # Extra safety pause
            return 0
        fi
        sleep 1
        ((attempt++))
    done
    error_exit "Timeout waiting for LVM operation on $volume"
}

# Function to ensure disk operations are complete
ensure_disk_ready() {
    local vmid=$1
    local storage=$2
    
    log "INFO" "Ensuring disk operations are complete..."
    
    # Wait for LVM changes to settle
    sync
    sleep 2
    
    # Wait for volume to be ready
    wait_for_lvm "${storage}/vm-${vmid}-disk-0" || \
    wait_for_lvm "${storage}/base-${vmid}-disk-0"  # Try alternate name format
}

# Default values
VMID_DEFAULT="9999"
VMNAME_DEFAULT="ubuntu-2404-template"
STORAGE_DEFAULT="local-lvm"
BRIDGE_DEFAULT="vmbr0"
MEMORY_DEFAULT="2048"
CORES_DEFAULT="1"
DISK_SIZE_DEFAULT="10"

# Parse command-line arguments
while getopts ":i:n:s:b:m:c:d:h" opt; do
    case "${opt}" in
        i) VMID=${OPTARG} ;;
        n) VMNAME=${OPTARG} ;;
        s) STORAGE=${OPTARG} ;;
        b) BRIDGE=${OPTARG} ;;
        m) MEMORY=${OPTARG} ;;
        c) CORES=${OPTARG} ;;
        d) DISK_SIZE=${OPTARG} ;;
        h) usage ;;
        *) error_exit "Invalid option: -${OPTARG}" ;;
    esac
done

# Use environment variables if set, otherwise use defaults
VMID=${VMID:-${VMID_ENV:-$VMID_DEFAULT}}
VMNAME=${VMNAME:-${VMNAME_ENV:-$VMNAME_DEFAULT}}
STORAGE=${STORAGE:-${STORAGE_ENV:-$STORAGE_DEFAULT}}
BRIDGE=${BRIDGE:-${BRIDGE_ENV:-$BRIDGE_DEFAULT}}
MEMORY=${MEMORY:-${MEMORY_ENV:-$MEMORY_DEFAULT}}
CORES=${CORES:-${CORES_ENV:-$CORES_DEFAULT}}
DISK_SIZE=${DISK_SIZE:-${DISK_SIZE_ENV:-$DISK_SIZE_DEFAULT}}

# Define image variables
readonly IMAGEPATH="https://cloud-images.ubuntu.com/noble/current/"
readonly IMAGENAME="noble-server-cloudimg-amd64.img"
readonly CHECKSUMURL="${IMAGEPATH}SHA256SUMS"

# Main execution with progress tracking
main() {
    local start_time=$(date +%s)
    
    # Acquire lock
    acquire_lock
    
    # Initial checks
    check_requirements
    verify_network "$BRIDGE"
    verify_storage "$STORAGE"
    check_resources "$MEMORY" "$CORES" "$DISK_SIZE"
    
    # Create temporary directory
    cd "$TEMP_DIR"
    
    # Display configuration
    log "INFO" "Starting template creation with configuration:"
    log "INFO" "VM ID: $VMID"
    log "INFO" "VM Name: $VMNAME"
    log "INFO" "Storage: $STORAGE"
    log "INFO" "Bridge: $BRIDGE"
    log "INFO" "Memory: $MEMORY MB"
    log "INFO" "Cores: $CORES"
    log "INFO" "Additional Disk Size: $DISK_SIZE GB"
    
    # Download and verify Ubuntu cloud image with retry logic
    local attempt=1
    while [ $attempt -le $RETRY_COUNT ]; do
        log "INFO" "Downloading Ubuntu cloud image (attempt $attempt/$RETRY_COUNT)..."
        if wget -q "${IMAGEPATH}${IMAGENAME}" -O "${IMAGENAME}" && \
           wget -q "${CHECKSUMURL}" -O SHA256SUMS && \
           sha256sum -c --ignore-missing SHA256SUMS; then
            break
        fi
        
        [ $attempt -eq $RETRY_COUNT ] && error_exit "Failed to download or verify image after $RETRY_COUNT attempts"
        
        log "WARN" "Attempt $attempt failed, retrying in $WAIT_TIME seconds..."
        sleep $WAIT_TIME
        ((attempt++))
    done
    
    # Create and configure VM
    log "INFO" "Creating VM with ID ${VMID}..."
    qm create "${VMID}" \
        --name "${VMNAME}" \
        --memory "$MEMORY" \
        --cores "$CORES" \
        --net0 "virtio,bridge=${BRIDGE},firewall=1" || error_exit "Failed to create VM"
        
    # Import disk with proper waiting period
    log "INFO" "Importing disk image..."
    qm importdisk "${VMID}" "${IMAGENAME}" "${STORAGE}" || error_exit "Failed to import disk"
    ensure_disk_ready "${VMID}" "${STORAGE}"
    
    # Configure VM storage and settings
    log "INFO" "Configuring VM storage and settings..."
    qm set "${VMID}" \
        --scsihw virtio-scsi-single || error_exit "Failed to set SCSI hardware"
    
    sleep 2
    
    # Use both possible volume names in the configuration
    if lvs "${STORAGE}/base-${VMID}-disk-0" &>/dev/null; then
        DISK_VOLUME="base-${VMID}-disk-0"
    else
        DISK_VOLUME="vm-${VMID}-disk-0"
    fi
    
    qm set "${VMID}" \
        --scsi0 "${STORAGE}:${DISK_VOLUME},discard=on,iothread=1" \
        --ide2 "${STORAGE}:cloudinit" \
        --boot order=scsi0 \
        --serial0 socket \
        --vga serial0 \
        --ostype l26 \
        --agent enabled=1,fstrim_cloned_disks=1 \
        --balloon 1024 \
        --bios ovmf \
        --machine q35 || error_exit "Failed to configure VM settings"
    
    ensure_disk_ready "${VMID}" "${STORAGE}"
    
    # Resize disk with proper waiting period
    log "INFO" "Resizing disk..."
    qm resize "${VMID}" "scsi0" "+${DISK_SIZE}G" || error_exit "Failed to resize disk"
    ensure_disk_ready "${VMID}" "${STORAGE}"
    
    # Convert to template
    log "INFO" "Converting to template..."
    qm template "${VMID}" || error_exit "Failed to convert to template"
    
    # Calculate execution time
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    
    # Cleanup and finish
    cleanup
    rm -f "$LOCK_FILE"
    
    log "INFO" "Template creation completed successfully in ${duration} seconds"
}

# Execute main function with error handling
main "$@"