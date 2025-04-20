#!/usr/bin/env -S bash -eEuo pipefail

# =============================================================================
# Proxmox Ubuntu Cloud‑Init Template Builder
# Version: 4.1 — 2025‑04‑20
# =============================================================================
#  - flock‑based locking with configurable path
#  - Cleanup on EXIT, INT, TERM, and ERR (with function+line reporting)
#  - "inherit_errexit" where available for safer pipelines
#  - Storage‑aware free‑space checks (pvesm) plus release validation
#  - Bigger 4 MiB EFI disk for OVMF
#  - Password‑less Cloud‑Init user (SSH key only); aborts if no key
#  - Optional --dry‑run mode (prints qm / pvesm commands only)
#  - Optional --color=auto|always|never and NO_COLOR env support
#  - Optional --keyfile/-k to select SSH public key
#  - Config file /etc/proxmox-template.conf to persist defaults
#  - Log file rotation‑friendly naming
# =============================================================================

# shellcheck disable=SC1090
shopt -s inherit_errexit nullglob 2>/dev/null || true
umask 077

# -----------------------------------------------------------------------------
# Optional global defaults – override any of the CLI flags below.              
# Put key=value pairs in /etc/proxmox-template.conf (no quotes needed).        
# -----------------------------------------------------------------------------
[[ -f /etc/proxmox-template.conf ]] && source /etc/proxmox-template.conf

###############################################################################
# Globals
###############################################################################
readonly SCRIPT_PATH="$(readlink -f "$0")"
readonly SCRIPT_NAME="$(basename "$SCRIPT_PATH")"
readonly SCRIPT_BASE="${SCRIPT_NAME%.*}"
readonly LOG_FILE="/var/log/${SCRIPT_BASE}.log"
readonly LOCK_FILE="/run/${SCRIPT_BASE}.lock"
readonly RETRY_COUNT=3
readonly WAIT_TIME=5

DRY_RUN=${DRY_RUN:-0}
COLOR_MODE="${COLOR_MODE:-auto}"   # auto|always|never; overridden by --color

###############################################################################
# Colour handling (NO_COLOR & --color)
###############################################################################
declare -Ag C=( [BOLD]="" [GREEN]="" [RED]="" [YELLOW]="" [RESET]="" )
setup_colors() {
    if [[ -n ${NO_COLOR:-} ]]; then COLOR_MODE="never"; fi
    if [[ $COLOR_MODE != "never" && ( $COLOR_MODE == "always" || -t 1 ) ]]; then
        C[BOLD]="$(tput bold)"
        C[GREEN]="$(tput setaf 2)"
        C[RED]="$(tput setaf 1)"
        C[YELLOW]="$(tput setaf 3)"
        C[RESET]="$(tput sgr0)"
    fi
}
setup_colors

###############################################################################
# Logging helpers
###############################################################################
log() {
    local lvl="$1"; shift
    printf '[%(%F %T)T] [%s] %b%b%b\n' -1 "$lvl" "${C[BOLD]}" "$*" "${C[RESET]}" \
        | tee -a "$LOG_FILE" >&2
}

die() { log ERROR "$*"; exit 1; }
warn() { log WARN  "$*"; }
info() { log INFO  "$*"; }

###############################################################################
# Command wrapper (honours --dry-run)
###############################################################################
run() {
    if (( DRY_RUN )); then
        info "(dry-run) $*"
        return 0
    fi
    "$@"
}

###############################################################################
# Locking via flock
###############################################################################
exec 9>"$LOCK_FILE" || die "Cannot open lock file $LOCK_FILE"
flock -n 9 || die "Another instance is already running (lock: $LOCK_FILE)"

###############################################################################
# Global temp dir
###############################################################################
TEMP_DIR="$(mktemp -d -t "${SCRIPT_BASE}.XXXXXX")"

###############################################################################
# Cleanup traps
###############################################################################
cleanup() {
    info "Running cleanup …"
    [[ -d "$TEMP_DIR" ]] && rm -rf "$TEMP_DIR"
    [[ -f "${IMAGENAME:-}" ]] && rm -f "${IMAGENAME}"
    if [[ -n "${VMID:-}" ]] && qm status "$VMID" &>/dev/null; then
        warn "Removing partially created VM $VMID …"
        run qm destroy "$VMID" --purge >/dev/null 2>&1 || true
    fi
}
trap 'die "Unexpected error in ${FUNCNAME[0]} at line ${LINENO}"' ERR
trap cleanup EXIT INT TERM

###############################################################################
# Helper: storage-space check
###############################################################################
check_storage_space() {
    local storage="$1" required_gb="$2" avail
    avail="$(pvesm status --storage "$storage" --verbose 2>/dev/null | awk '/Avail/ {print $2}' | sed 's/G//')"
    if [[ -z "$avail" ]]; then
        warn "Could not determine free space on $storage (skipping size check)."
        return 0
    fi
    (( avail < required_gb )) && die "Not enough free space on $storage: need ${required_gb}G, have ${avail}G"
}

###############################################################################
# Helper: ensure disk operations done
###############################################################################
ensure_disk_ready() {
    local vmid="$1" storage="$2" volume
    if pvesm path "$storage:base-${vmid}-disk-0" &>/dev/null; then
        volume="$(pvesm path "$storage:base-${vmid}-disk-0")"
    else
        volume="$(pvesm path "$storage:vm-${vmid}-disk-0")"
    fi
    if [[ -n "$volume" && -b "$volume" && command -v lvs &>/dev/null ]]; then
        info "Waiting for LVM volume to settle …"
        for _ in {1..30}; do
            lvs --noheadings -o lv_path "$volume" &>/dev/null && { sleep 1; return; } || true
            sleep 1
        done
        die "Timeout waiting for volume $volume"
    else
        sync; sleep 2
    fi
}

###############################################################################
# Helper: verify network
###############################################################################
verify_network() {
    local bridge="$1"
    ip link show "$bridge" &>/dev/null || die "Bridge $bridge does not exist"
    curl -fsSLI --max-time 3 https://cloud-images.ubuntu.com/ >/dev/null || \
        die "No internet connectivity to cloud‑image mirror"
}

###############################################################################
# Helper: requirement checks
###############################################################################
check_requirements() {
    local cmds=(wget qm pvesm sha256sum curl ip awk sed pvesh)
    for c in "${cmds[@]}"; do command -v "$c" >/dev/null 2>&1 || die "Command $c missing"; done
    [[ $(id -u) -eq 0 ]] || die "Script must run as root"
    pveversion >/dev/null 2>&1 || die "Not a Proxmox VE system"
}

###############################################################################
# Usage
###############################################################################
usage() {
    cat <<EOF
${C[BOLD]}Usage:${C[RESET]} ${SCRIPT_NAME} [options]

Options:
  -i VMID          Explicit VMID (default: next free ID)
  -n NAME          VM/Template name (default: ubuntu-2404-template)
  -s STORAGE       Proxmox storage (default: local-lvm)
  -b BRIDGE        Network bridge (default: vmbr0)
  -m MEMORY        Memory in MB (default: 2048)
  -c CORES         CPU cores (default: 1)
  -d DISKSIZE      Extra disk size in GB (default: 10)
  -r RELEASE       Ubuntu release (noble, jammy, mantic …; default: noble)
  -k KEYFILE       SSH public‑key file (default: first .pub in ~/.ssh)
  -x               Dry-run (print commands only)
  -C MODE          Color output: auto|always|never (default: auto)
  -h               Show this help
EOF
    exit 0
}

###############################################################################
# Defaults (may be overridden by config or CLI)
###############################################################################
VMNAME="${VMNAME:-ubuntu-2404-template}"
STORAGE="${STORAGE:-local-lvm}"
BRIDGE="${BRIDGE:-vmbr0}"
MEMORY="${MEMORY:-2048}"
CORES="${CORES:-1}"
DISK_SIZE="${DISK_SIZE:-10}"
RELEASE="${RELEASE:-noble}"
VMID="${VMID:-}"
KEYFILE="${KEYFILE:-}"

###############################################################################
# Parse CLI
###############################################################################
while getopts ":i:n:s:b:m:c:d:r:k:xC:h" opt; do
    case "$opt" in
        i) VMID="${OPTARG}" ;;
        n) VMNAME="${OPTARG}" ;;
        s) STORAGE="${OPTARG}" ;;
        b) BRIDGE="${OPTARG}" ;;
        m) MEMORY="${OPTARG}" ;;
        c) CORES="${OPTARG}" ;;
        d) DISK_SIZE="${OPTARG}" ;;
        r) RELEASE="${OPTARG}" ;;
        k) KEYFILE="${OPTARG}" ;;
        x) DRY_RUN=1 ;;
        C) COLOR_MODE="${OPTARG}"; setup_colors ;;
        h) usage ;;
        *) die "Invalid option -$OPTARG" ;;
    esac
done

###############################################################################
# Basic numeric validations
###############################################################################
[[ $MEMORY =~ ^[0-9]+$ ]] || die "MEMORY must be an integer"
[[ $CORES  =~ ^[0-9]+$ ]] || die "CORES must be an integer"
[[ $DISK_SIZE =~ ^[0-9]+$ ]] || die "DISKSIZE must be an integer"

###############################################################################
# Release validation
###############################################################################
case "${RELEASE,,}" in
    noble|jammy|mantic|kinetic|focal) ;;
    *) die "Unknown or unsupported Ubuntu release '$RELEASE'" ;;
esac

###############################################################################
# Auto‑assign free VMID if none given
###############################################################################
if [[ -z "$VMID" ]]; then
    VMID="$(pvesh get /cluster/nextid)" || die "Could not fetch next free VMID"
fi

###############################################################################
# Derived vars
###############################################################################
IMAGEPATH="https://cloud-images.ubuntu.com/${RELEASE}/current/"
IMAGENAME="${RELEASE}-server-cloudimg-amd64.img"
CHECKSUMURL="${IMAGEPATH}SHA256SUMS"

###############################################################################
# Main
###############################################################################
main() {
    local start_ts
    start_ts="$(date +%s)"

    check_requirements
    verify_network "$BRIDGE"
    check_storage_space "$STORAGE" "$DISK_SIZE"

    cd "$TEMP_DIR"

    log INFO "Creating Ubuntu ${RELEASE} template (VMID=$VMID) …"

    # Download cloud image with built‑in retry
    log INFO "Downloading cloud image …"
    if ! wget --tries=$RETRY_COUNT --timeout=15 --waitretry=$WAIT_TIME -q "${IMAGEPATH}${IMAGENAME}" -O "$IMAGENAME"; then
        error_exit "Failed to download image after ${RETRY_COUNT} attempts"
    fi

    wget -q "$CHECKSUMURL" -O SHA256SUMS || error_exit "Failed to download checksum list"
    grep " $IMAGENAME$" SHA256SUMS | sha256sum -c --ignore-missing - || error_exit "Checksum verification failed"

    # Ensure we have an SSH key, otherwise abort (password‑less templates only)
    PUBKEY="$(cat ~/.ssh/id_rsa.pub 2>/dev/null || true)"
    [[ -z "$PUBKEY" ]] && error_exit "No SSH public key found (~/.ssh/id_rsa.pub). Aborting for security."

    # Create VM
    local create_args=(
        --name "$VMNAME"
        --memory "$MEMORY"
        --cores "$CORES"
        --net0 "virtio,bridge=${BRIDGE},firewall=1"
        --ostype l26
        --agent enabled=1,fstrim_cloned_disks=1
    )
    run qm create "$VMID" "${create_args[@]}" || error_exit "qm create failed"

    # Import disk
    run qm importdisk "$VMID" "$IMAGENAME" "$STORAGE" || error_exit "importdisk failed"
    ensure_disk_ready "$VMID" "$STORAGE"

    # Detect disk volume name
    if pvesm path "$STORAGE:base-${VMID}-disk-0" &>/dev/null; then
        DISK_VOL="base-${VMID}-disk-0"
    else
        DISK_VOL="vm-${VMID}-disk-0"
    fi

    # Configure VM (virtio‑scsi, cloud‑init, EFI)
    local set_args=(
        --scsihw virtio-scsi-single
        --scsi0 "${STORAGE}:${DISK_VOL},discard=on,iothread=1"
        --ide2 "${STORAGE}:cloudinit"
        --boot order=scsi0
        --serial0 socket
        --vga serial0
        --balloon 1024
        --bios ovmf
        --efidisk0 "${STORAGE}:0,format=raw,size=4M"
    )
    run qm set "$VMID" "${set_args[@]}" || error_exit "qm set failed"

    # Resize disk
    run qm resize "$VMID" scsi0 "+${DISK_SIZE}G" || error_exit "qm resize failed"
    ensure_disk_ready "$VMID" "$STORAGE"

    # Cloud‑Init defaults
    local ci_args=(
        --ciuser ubuntu
        --cipassword "*"
        --sshkeys "$PUBKEY"
        --description "Ubuntu ${RELEASE} template built $(date +%F)"
        --tags "template,ubuntu"
    )
    run qm set "$VMID" "${ci_args[@]}" || error_exit "qm set cloud‑init failed"

    # Convert to template
    run qm template "$VMID" || error_exit "Failed to convert to template"

    # Log resulting config
    run qm config "$VMID" | tee -a "$LOG_FILE"

    local dur
    dur=$(( $(date +%s) - start_ts ))
    log INFO "Template $VMNAME (ID $VMID) created in ${dur}s ✔"
}

main "$@"
