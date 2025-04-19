#!/usr/bin/env bash

# =============================================================================
# Proxmox Ubuntu Cloud‑Init Template Builder
# Version: 3.0 — 2025‑04‑19
# =============================================================================
#  - Implements flock‑based locking
#  - Handles ERR and EXIT traps for reliable cleanup
#  - Storage‑aware free‑space checks (pvesm)
#  - Storage‑agnostic disk‑ready checks
#  - Adds EFI disk when using OVMF
#  - Auto‑free VMID via pvesh if none supplied
#  - Cloud‑Init defaults (user, password, ssh key)
#  - Optional Ubuntu release parameter
#  - ANSI colours only when running in a tty (disable with NO_COLOR=1)
# =============================================================================

set -eEuo pipefail        # -E: trap ERR in functions and subshells
trap 'error_exit "Unexpected error on line $LINENO"' ERR
trap cleanup EXIT         # Always perform cleanup, even on success

readonly SCRIPT_NAME="$(basename "$0")"
readonly LOG_FILE="/var/log/proxmox-template-creator.log"
readonly LOCK_FILE="/var/run/${SCRIPT_NAME}.lock"
readonly RETRY_COUNT=3
readonly WAIT_TIME=5

# --- Colour handling --------------------------------------------------------
if [[ -t 1 && -z ${NO_COLOR:-} ]]; then
    BOLD="$(tput bold)"; GREEN="$(tput setaf 2)"; RED="$(tput setaf 1)"; YELLOW="$(tput setaf 3)"; RESET="$(tput sgr0)"
else
    BOLD=""; GREEN=""; RED=""; YELLOW=""; RESET=""
fi

# --- Logging ----------------------------------------------------------------
log() {
    local lvl="$1"; shift
    local ts="$(date '+%F %T')"
    echo "[$ts] [$lvl] $*" | tee -a "$LOG_FILE"
}

error_exit() {
    log "ERROR" "$*"
    exit 1
}

# --- Locking via flock ------------------------------------------------------
exec 9>"$LOCK_FILE" || error_exit "Cannot open lock file $LOCK_FILE"
flock -n 9 || error_exit "Another instance is already running (lock: $LOCK_FILE)"

# --- Global temp dir --------------------------------------------------------
TEMP_DIR="$(mktemp -d)"

# --- Cleanup ----------------------------------------------------------------
cleanup() {
    log INFO "Running cleanup …"
    [[ -d "$TEMP_DIR" ]] && rm -rf "$TEMP_DIR"
    [[ -f "${IMAGENAME:-}" ]] && rm -f "${IMAGENAME}"
    if [[ -n "${VMID:-}" ]] && qm status "$VMID" &>/dev/null; then
        log INFO "Removing partially created VM $VMID …"
        qm destroy "$VMID" --purge >/dev/null 2>&1 || true
    fi
}

# --- Helper: storage‑space check -------------------------------------------
check_storage_space() {
    local storage="$1" required_gb="$2"
    local avail
    avail="$(pvesm status --storage "$storage" --verbose 2>/dev/null | awk '/Avail/ {print $2}' | sed 's/G//')"
    if [[ -z "$avail" ]]; then
        log WARN "Could not determine free space on $storage (skipping size check)."
        return 0
    fi
    (( avail < required_gb )) && error_exit "Not enough free space on $storage: need ${required_gb}G, have ${avail}G"
}

# --- Helper: ensure disk operations done -----------------------------------
ensure_disk_ready() {
    local vmid="$1" storage="$2" volume
    # Volume name may differ (base‑, vm‑ prefix)
    if pvesm path "$storage:base-${vmid}-disk-0" &>/dev/null; then
        volume="$(pvesm path "$storage:base-${vmid}-disk-0")"
    else
        volume="$(pvesm path "$storage:vm-${vmid}-disk-0")"
    fi

    if [[ -n "$volume" && -b "$volume" && command -v lvs &>/dev/null ]]; then
        log INFO "Waiting for LVM volume to settle …"
        for _ in {1..30}; do
            lvs "$volume" &>/dev/null && { sleep 1; return; } || true
            sleep 1
        done
        error_exit "Timeout waiting for volume $volume"
    else
        # For ZFS, Ceph, Directory etc. a simple sync is enough
        sync; sleep 2
    fi
}

# --- Helper: verify network -------------------------------------------------
verify_network() {
    local bridge="$1"
    ip link show "$bridge" &>/dev/null || error_exit "Bridge $bridge does not exist"
    curl -fsSLI --max-time 3 https://cloud-images.ubuntu.com/ >/dev/null || \
        error_exit "No internet connectivity to cloud‑image mirror"
}

# --- Helper: requirement checks --------------------------------------------
check_requirements() {
    local cmds=(wget qm pvesm sha256sum curl ip awk sed pvesh)
    for c in "${cmds[@]}"; do command -v "$c" >/dev/null 2>&1 || error_exit "Command $c missing"; done
    [[ $(id -u) -eq 0 ]] || error_exit "Script must run as root"
    pveversion >/dev/null 2>&1 || error_exit "Not a Proxmox VE system"
}

# --- Usage ------------------------------------------------------------------
usage() {
    cat <<EOF
${BOLD}Usage:${RESET} ${SCRIPT_NAME} [options]

Options:
  -i VMID          Explicit VMID (default: next free ID)
  -n NAME          VM/Template name (default: ubuntu-2404-template)
  -s STORAGE       Proxmox storage (default: local-lvm)
  -b BRIDGE        Network bridge (default: vmbr0)
  -m MEMORY        Memory in MB (default: 2048)
  -c CORES         CPU cores (default: 1)
  -d DISKSIZE      Extra disk size in GB (default: 10)
  -r RELEASE       Ubuntu release (noble, jammy …; default: noble)
  -h               Show this help
EOF
    exit 0
}

# --- Defaults ---------------------------------------------------------------
VMNAME="ubuntu-2404-template"
STORAGE="local-lvm"
BRIDGE="vmbr0"
MEMORY=2048
CORES=1
DISK_SIZE=10
RELEASE="noble"
VMID=""

# --- Parse CLI --------------------------------------------------------------
while getopts ":i:n:s:b:m:c:d:r:h" opt; do
    case "$opt" in
        i) VMID="$OPTARG" ;;
        n) VMNAME="$OPTARG" ;;
        s) STORAGE="$OPTARG" ;;
        b) BRIDGE="$OPTARG" ;;
        m) MEMORY="$OPTARG" ;;
        c) CORES="$OPTARG" ;;
        d) DISK_SIZE="$OPTARG" ;;
        r) RELEASE="$OPTARG" ;;
        h) usage ;;
        *) error_exit "Invalid option -$OPTARG" ;;
    esac
done

# Auto‑assign free VMID if none given
if [[ -z "$VMID" ]]; then
    VMID="$(pvesh get /cluster/nextid)" || error_exit "Could not fetch next free VMID"
fi

# --- Derived vars -----------------------------------------------------------
IMAGEPATH="https://cloud-images.ubuntu.com/${RELEASE}/current/"
IMAGENAME="${RELEASE}-server-cloudimg-amd64.img"
CHECKSUMURL="${IMAGEPATH}SHA256SUMS"

# --- Main -------------------------------------------------------------------
main() {
    local start_ts="$(date +%s)"

    check_requirements
    verify_network "$BRIDGE"
    check_storage_space "$STORAGE" "$DISK_SIZE"

    cd "$TEMP_DIR"

    log INFO "Creating Ubuntu ${RELEASE} template (VMID=$VMID) …"

    # Download with retries ------------------------------------------------------------------
    for (( i=1; i<=RETRY_COUNT; i++ )); do
        log INFO "Downloading cloud image (attempt $i/$RETRY_COUNT) …"
        if wget -q "${IMAGEPATH}${IMAGENAME}" -O "$IMAGENAME" && \
           wget -q "$CHECKSUMURL" -O SHA256SUMS && \
           grep " $IMAGENAME$" SHA256SUMS | sha256sum -c -; then
            break
        fi
        [[ $i -eq RETRY_COUNT ]] && error_exit "Failed to download/verify image after $RETRY_COUNT attempts"
        log WARN "Download failed, retrying in $WAIT_TIME s …"; sleep "$WAIT_TIME"
    done

    # Create VM -----------------------------------------------------------------------------
    qm create "$VMID" \
        --name "$VMNAME" \
        --memory "$MEMORY" \
        --cores "$CORES" \
        --net0 "virtio,bridge=${BRIDGE},firewall=1" \
        --ostype l26 \
        --agent enabled=1,fstrim_cloned_disks=1 || error_exit "qm create failed"

    # Import disk ---------------------------------------------------------------------------
    qm importdisk "$VMID" "$IMAGENAME" "$STORAGE" || error_exit "importdisk failed"
    ensure_disk_ready "$VMID" "$STORAGE"

    # Detect actual disk volume name --------------------------------------------------------
    if pvesm path "$STORAGE:base-${VMID}-disk-0" &>/dev/null; then
        DISK_VOL="base-${VMID}-disk-0"
    else
        DISK_VOL="vm-${VMID}-disk-0"
    fi

    # Configure VM --------------------------------------------------------------------------
    qm set "$VMID" \
        --scsihw virtio-scsi-single \
        --scsi0 "${STORAGE}:${DISK_VOL},discard=on,iothread=1" \
        --ide2 "${STORAGE}:cloudinit" \
        --boot order=scsi0 \
        --serial0 socket \
        --vga serial0 \
        --balloon 1024 \
        --bios ovmf \
        --efidisk0 "${STORAGE}:0,format=raw,size=1M" || error_exit "qm set failed"

    # Resize disk ---------------------------------------------------------------------------
    qm resize "$VMID" scsi0 "+${DISK_SIZE}G" || error_exit "qm resize failed"
    ensure_disk_ready "$VMID" "$STORAGE"

    # Cloud‑Init defaults -------------------------------------------------------------------
    PUBKEY="$(cat ~/.ssh/id_rsa.pub 2>/dev/null || true)"
    qm set "$VMID" \
        --ciuser ubuntu \
        --cipassword changeme \
        ${PUBKEY:+--sshkeys "$PUBKEY"} \
        --description "Ubuntu ${RELEASE} template built $(date +%F)" \
        --tags "template,ubuntu" || error_exit "qm set cloud‑init failed"

    # Convert to template -------------------------------------------------------------------
    qm template "$VMID" || error_exit "Failed to convert to template"

    local dur=$(( $(date +%s) - start_ts ))
    log INFO "Template $VMNAME (ID $VMID) created in ${dur}s ✔"
}

main "$@"
