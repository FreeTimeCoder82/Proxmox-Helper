#!/bin/bash

# Default values
VMID_DEFAULT="100"
VMNAME_DEFAULT="ubuntu-2404-template"
STORAGE_DEFAULT="vms"
BRIDGE_DEFAULT="vmbr0"

# Function to display usage information
usage() {
    echo "Usage: $0 [-i VMID] [-n VMNAME] [-s STORAGE] [-b BRIDGE]"
    echo
    echo "Options:"
    echo "  -i VMID          Set the VM ID (e.g., 100)"
    echo "  -n VMNAME        Set the VM name (e.g., ubuntu-2404-template)"
    echo "  -s STORAGE       Set the storage name (e.g., vms)"
    echo "  -b BRIDGE        Set the network bridge (e.g., vmbr0)"
    echo "  -h               Show this help message"
    exit 1
}

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
            echo "Invalid option: -$OPTARG"
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

if [ -z "$VMNAME" ]; then
    read -p "Enter VM Name (default $VMNAME_DEFAULT): " VMNAME
    VMNAME=${VMNAME:-$VMNAME_DEFAULT}
fi

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

# Proceed with the rest of the script using the variables above
echo "Using the following configuration:"
echo "VM ID: $VMID"
echo "VM Name: $VMNAME"
echo "Storage: $STORAGE"
echo "Bridge: $BRIDGE"

# Download Ubuntu cloud image disk
echo "Downloading Ubuntu cloud image..."
wget -q $IMAGEPATH$IMAGENAME -O $IMAGENAME

# Verify the image was downloaded successfully
if [ ! -s $IMAGENAME ]; then
    echo "Download failed or file is empty."
    exit 1
fi
echo "Download completed successfully."

# Ensure the storage exists
echo "Checking if storage '$STORAGE' exists..."
pvesm list $STORAGE > /dev/null 2>&1
if [ $? -ne 0 ]; then
    echo "Storage '$STORAGE' does not exist."
    exit 1
fi
echo "Storage '$STORAGE' is available."

# Create a new virtual machine
echo "Creating VM with ID $VMID..."
qm create $VMID --name $VMNAME

# Import the downloaded Ubuntu disk to storage
echo "Importing the disk image to storage..."
qm importdisk $VMID $IMAGENAME $STORAGE

# Configure the VM
echo "Configuring the VM..."
qm set $VMID \
    --memory 1024 \
    --cores 1 \
    --net0 virtio,bridge=$BRIDGE,firewall=1 \
    --virtio0 $STORAGE:vm-$VMID-disk-0,discard=on,ssd=1,iothread=1 \
    --ide2 $STORAGE:cloudinit \
    --boot order=virtio0 \
    --serial0 socket \
    --vga serial0 \
    --ostype l26 \
    --agent enabled=1,fstrim_cloned_disks=1 \
    --balloon 512 \
    --bios ovmf \
    --machine q35

# Resize disk / add 10GB more disk space
echo "Resizing the disk..."
qm resize $VMID virtio0 +10G

# Clean up the downloaded image
echo "Cleaning up the downloaded image..."
rm $IMAGENAME

# (Optional) Set additional cloud-init user data or network configuration here
# Example: qm set $VMID --ciuser <username> --cipassword <password>

# Create template
echo "Converting VM to a template..."
qm template $VMID

echo "Template creation completed successfully."
