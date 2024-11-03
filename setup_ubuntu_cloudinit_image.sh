#!/bin/bash

# =============================================================================
# Script to create a cloud-init enabled Ubuntu 24.04 template on Proxmox VE
# =============================================================================

set -euo pipefail  # Enable strict error handling

# Define log file
readonly LOG_FILE="/var/log/proxmox-template-creator.log"
readonly SCRIPT_NAME=$(basename "$0")

# Logging function
log() {
    local level=$1
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $message" | tee -a "$LOG_FILE"
}

# Error handling function
error_exit() {
    local message=$1
    log "ERROR" "$message"
    # Cleanup if temporary files exist
    [ -f "${IMAGENAME:-}" ] && rm -f "${IMAGENAME}"
    # Cleanup VM if it was partially created
    if [ -n "${VMID:-}" ] && qm status "$VMID" &>/dev/null; then
        qm destroy "$VMID" &>/dev/null || true
    fi
    exit 1
}

# Function to display usage information
usage() {
    cat <<EOF
Usage: $SCRIPT_NAME [-i VMID] [-n VMNAME] [-s STORAGE] [-b BRIDGE] [-m MEMORY] [-c CORES] [-d DISK_SIZE]

Options:
  -i VMID          Set the VM ID (e.g., 9999)
  -n VMNAME        Set the VM name (e.g., ubuntu-2404-template)
  -s STORAGE       Set the storage name (e.g., local-lvm)
  -b BRIDGE        Set the network bridge (e.g., vmbr0)
  -m MEMORY        Set the memory in MB (default: 2048)
  -c CORES         Set the number of CPU cores (default: 1)
  -d DISK_SIZE     Additional disk size in GB (default: 10)
  -h               Show this help message
EOF
    exit 1
}

# Function to validate VM ID
is_valid_vmid() {
    [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 100 ] && [ "$1" -le 999999999 ]
}

# Function to validate VM Name
is_valid_vmname() {
    [[ "$1" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]{0,62}$ ]]
}

# Function to check system requirements
check_requirements() {
    local required_commands=("wget" "qm" "pvesm")
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            error_exit "Required command '$cmd' not found"
        fi
    done

    # Check if running as root
    if [ "$(id -u)" -ne 0 ]; then
        error_exit "This script must be run as root"
    fi
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

# Validate inputs
while ! is_valid_vmid "$VMID"; do
    log "WARN" "Invalid VM ID. Please enter a numeric value between 100 and 999999999."
    read -p "Enter VM ID (default ${VMID_DEFAULT}): " VMID
    VMID=${VMID:-$VMID_DEFAULT}
done

while ! is_valid_vmname "$VMNAME"; do
    log "WARN" "Invalid VM Name. Use letters, numbers, hyphens, and periods only (max 63 characters)."
    read -p "Enter VM Name (default ${VMNAME_DEFAULT}): " VMNAME
    VMNAME=${VMNAME:-$VMNAME_DEFAULT}
done

# Define image variables
readonly IMAGEPATH="https://cloud-images.ubuntu.com/noble/current/"
readonly IMAGENAME="noble-server-cloudimg-amd64.img"
readonly CHECKSUMURL="${IMAGEPATH}SHA256SUMS"

# Display and log configuration
log "INFO" "Configuration:"
log "INFO" "VM ID: $VMID"
log "INFO" "VM Name: $VMNAME"
log "INFO" "Storage: $STORAGE"
log "INFO" "Bridge: $BRIDGE"
log "INFO" "Memory: $MEMORY MB"
log "INFO" "Cores: $CORES"
log "INFO" "Additional Disk Size: $DISK_SIZE GB"
log "INFO" "Image Path: ${IMAGEPATH}${IMAGENAME}"

# Main execution
main() {
    check_requirements

    # Check if VM ID already exists
    if qm status "$VMID" &>/dev/null; then
        error_exit "VM ID $VMID already exists on this Proxmox node"
    fi

    # Download and verify Ubuntu cloud image
    log "INFO" "Downloading Ubuntu cloud image and checksum..."
    wget -q "${IMAGEPATH}${IMAGENAME}" -O "${IMAGENAME}" || error_exit "Failed to download image"
    wget -q "${CHECKSUMURL}" -O SHA256SUMS || error_exit "Failed to download checksum"
    
    # Verify checksum
    log "INFO" "Verifying image checksum..."
    if ! sha256sum -c --ignore-missing SHA256SUMS; then
        error_exit "Checksum verification failed"
    fi

    # Create and configure VM
    log "INFO" "Creating VM with ID ${VMID}..."
    qm create "${VMID}" \
        --name "${VMNAME}" \
        --memory "$MEMORY" \
        --cores "$CORES" \
        --net0 "virtio,bridge=${BRIDGE},firewall=1" || error_exit "Failed to create VM"

    log "INFO" "Importing disk image..."
    qm importdisk "${VMID}" "${IMAGENAME}" "${STORAGE}" || error_exit "Failed to import disk"

    log "INFO" "Configuring VM..."
    qm set "${VMID}" \
        --scsihw virtio-scsi-single \
        --scsi0 "${STORAGE}:vm-${VMID}-disk-0,discard=on,iothread=1" \
        --ide2 "${STORAGE}:cloudinit" \
        --boot order=scsi0 \
        --serial0 socket \
        --vga serial0 \
        --ostype l26 \
        --agent enabled=1,fstrim_cloned_disks=1 \
        --balloon 1024 \
        --bios ovmf \
        --machine q35 || error_exit "Failed to configure VM"

    log "INFO" "Resizing disk..."
    qm resize "${VMID}" "scsi0" "+${DISK_SIZE}G" || error_exit "Failed to resize disk"

    log "INFO" "Converting to template..."
    qm template "${VMID}" || error_exit "Failed to convert to template"

    # Cleanup
    log "INFO" "Cleaning up temporary files..."
    rm -f "${IMAGENAME}" SHA256SUMS

    log "INFO" "Template creation completed successfully"
}

# Execute main function
main "$@"