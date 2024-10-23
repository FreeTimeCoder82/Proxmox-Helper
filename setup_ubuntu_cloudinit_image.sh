#!/bin/bash

# =============================================================================
# Script to create a cloud-init enabled Ubuntu 24.04 template on Proxmox VE
# =============================================================================

# Function to display usage information
usage() {
    echo "Usage: $0 [-i VMID] [-n VMNAME] [-s STORAGE] [-b BRIDGE]"
    echo
    echo "Options:"
    echo "  -i VMID          Set the VM ID (e.g., 9999)"
    echo "  -n VMNAME        Set the VM name (e.g., ubuntu-2404-template)"
    echo "  -s STORAGE       Set the storage name (e.g., local-lvm)"
    echo "  -b BRIDGE        Set the network bridge (e.g., vmbr0)"
    echo "  -h               Show this help message"
    exit 1
}

# Function to validate VM ID (must be a number)
is_valid_vmid() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

# Function to validate VM Name (must be a valid DNS name)
is_valid_vmname() {
    [[ "$1" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]{0,62}$ ]]
}

# Default values
VMID_DEFAULT="9999"
VMNAME_DEFAULT="ubuntu-2404-template"
STORAGE_DEFAULT="local-lvm"
BRIDGE_DEFAULT="vmbr0"

# Parse command-line arguments
while getopts ":i:n:s:b:h" opt; do
    case "${opt}" in
        i)
            VMID=${OPTARG}
            ;;
        n)
            VMNAME=${OPTARG}
            ;;
        s)
            STORAGE=${OPTARG}
            ;;
        b)
            BRIDGE=${OPTARG}
            ;;
        h)
            usage
            ;;
        *)
            echo "Invalid option: -${OPTARG}"
            usage
            ;;
    esac
done

shift $((OPTIND -1))

# Use environment variables or defaults if not set
VMID=${VMID:-${VMID_ENV:-$VMID_DEFAULT}}
VMNAME=${VMNAME:-${VMNAME_ENV:-$VMNAME_DEFAULT}}
STORAGE=${STORAGE:-${STORAGE_ENV:-$STORAGE_DEFAULT}}
BRIDGE=${BRIDGE:-${BRIDGE_ENV:-$BRIDGE_DEFAULT}}

# Prompt for any variables still not set
if [ -z "$VMID" ]; then
    read -p "Enter VM ID (default $VMID_DEFAULT): " VMID
    VMID=${VMID:-$VMID_DEFAULT}
fi

while ! is_valid_vmid "$VMID"; do
    echo "Invalid VM ID. Please enter a numeric value."
    read -p "Enter VM ID (default $VMID_DEFAULT): " VMID
    VMID=${VMID:-$VMID_DEFAULT}
done

if [ -z "$VMNAME" ]; then
    read -p "Enter VM Name (default $VMNAME_DEFAULT): " VMNAME
    VMNAME=${VMNAME:-$VMNAME_DEFAULT}
fi

while ! is_valid_vmname "$VMNAME"; do
    echo "Invalid VM Name. Use letters, numbers, hyphens, and periods only (max 63 characters)."
    read -p "Enter VM Name (default $VMNAME_DEFAULT): " VMNAME
    VMNAME=${VMNAME:-$VMNAME_DEFAULT}
done

if [ -z "$STORAGE" ]; then
    read -p "Enter Storage Name (default $STORAGE_DEFAULT): " STORAGE
    STORAGE=${STORAGE:-$STORAGE_DEFAULT}
fi

if [ -z "$BRIDGE" ]; then
    read -p "Enter Network Bridge (default $BRIDGE_DEFAULT): " BRIDGE
    BRIDGE=${BRIDGE:-$BRIDGE_DEFAULT}
fi

# Define other variables
IMAGEPATH="https://cloud-images.ubuntu.com/noble/current/"
IMAGENAME="noble-server-cloudimg-amd64.img"

# Display configuration
echo "Using the following configuration:"
echo "VM ID: $VMID"
echo "VM Name: $VMNAME"
echo "Storage: $STORAGE"
echo "Bridge: $BRIDGE"
echo "Image Path: $IMAGEPATH$IMAGENAME"

# Download Ubuntu cloud image disk
echo "Downloading Ubuntu cloud image..."
wget -q "${IMAGEPATH}${IMAGENAME}" -O "${IMAGENAME}"

# Verify the image was downloaded successfully
if [ ! -s "${IMAGENAME}" ]; then
    echo "Download failed or file is empty."
    exit 1
fi
echo "Download completed successfully."

# Ensure the storage exists
echo "Checking if storage '${STORAGE}' exists..."
if ! pvesm status | grep -q "${STORAGE}"; then
    echo "Storage '${STORAGE}' does not exist."
    exit 1
fi
echo "Storage '${STORAGE}' is available."

# Create a new virtual machine
echo "Creating VM with ID ${VMID}..."
qm create "${VMID}" --name "${VMNAME}" --memory 2048 --cores 1 --net0 virtio,bridge="${BRIDGE}",firewall=1

# Import the downloaded Ubuntu disk to storage
echo "Importing the disk image to storage..."
qm importdisk "${VMID}" "${IMAGENAME}" "${STORAGE}"

# Configure the VM
echo "Configuring the VM..."
qm set "${VMID}" \
    --scsihw virtio-scsi-single \
    --scsi0 "${STORAGE}":vm-"${VMID}"-disk-0,discard=on,iothread=1 \
    --ide2 "${STORAGE}":cloudinit \
    --boot order=scsi0 \
    --serial0 socket \
    --vga serial0 \
    --ostype l26 \
    --agent enabled=1,fstrim_cloned_disks=1 \
    --balloon 1024 \
    --bios ovmf \
    --machine q35

# Resize disk / add 10GB more disk space
echo "Resizing the disk..."
qm resize "${VMID}" scsi0 +10G

# Clean up the downloaded image
echo "Cleaning up the downloaded image..."
rm -f "${IMAGENAME}"

# (Optional) Set additional cloud-init user data or network configuration here
# Example: qm set "${VMID}" --ciuser <username> --sshkeys "<public_key>"

# Convert the VM to a template
echo "Converting VM to a template..."
qm template "${VMID}"

echo "Template creation completed successfully."
