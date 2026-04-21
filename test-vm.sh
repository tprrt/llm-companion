#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Thomas Perrot <thomas.perrot@tupi.fr>
# SPDX-License-Identifier: GPL-3.0-only

# =============================================================================
# test-vm.sh — Spin up a QEMU/KVM VM to test the llm-companion stack
#
# Run as a regular user with sudo access (NOT as root).
#
# Usage:
#   ./test-vm.sh <subcommand> [OPTIONS]
#
# Subcommands:
#   start     Start the VM, stream console logs, exit when ready
#   stop      Stop the running VM
#   reset     Stop + delete overlay disk (keeps downloaded base image)
#   status    Show whether the VM is running and its connection info
#   logs      Stream the VM console log (tail -f)
#   console   Open an SSH session into the running VM
#
# Options (start only):
#   --distro DISTRO   Target distribution: fedora or debian  (default: fedora)
#   --ram GB          VM RAM in gigabytes (≥ 1)              (default: 8)
#   --cpus N          Number of vCPUs                        (default: 4)
#   --disk GB         Overlay disk size in GB                (default: 40)
#   --ssh-port PORT   Host port → guest:22                   (default: 2222)
#   --web-port PORT   Host port → guest:8080                 (default: 8080)
#   --image PATH      Cloud Base qcow2 image                 (auto-downloaded if absent)
#   --vm-dir DIR      Directory for VM artifacts             (default: ./vm-test)
#
# What 'start' does:
#   1.  Downloads the Cloud Base image if not already cached
#   2.  Creates a qcow2 overlay disk backed by that image
#   3.  Generates cloud-init seed that:
#         a. Mounts the project directory via 9p virtfs (read-only)
#         b. Installs ansible-core
#         c. Runs the Ansible playbook (local connection) — this handles:
#            host prerequisites, firewall, Podman install, image build,
#            secret generation, Quadlet unit install, and service start
#         d. Reboots — loginctl linger then starts the llm-companion service
#   4.  Launches QEMU with KVM, shared project dir, and port forwards
#   5.  Streams console log to stdout until the VM is fully ready, then exits
#       (QEMU keeps running in the background)
#
# Systemd integration (Type=forking):
#   ExecStart = /path/to/test-vm.sh start
#   ExecStop  = /path/to/test-vm.sh stop
#   PIDFile   = /path/to/vm-test/qemu.pid
#
# After the VM is ready (≈ 10-20 min — package upgrade + podman pull):
#   Web UI:     http://localhost:8080
#   Console:    ./test-vm.sh console
#   Logs:       ./test-vm.sh logs
#
# NOTE: No models are pulled by default. To pull models in the VM:
#         ./test-vm.sh console
#         ./llm-companion/pull-models.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Defaults ──────────────────────────────────────────────────────────────────
VM_DIR="${SCRIPT_DIR}/vm-test"
RAM_GB=8
CPUS=4
DISK_GB=40
SSH_PORT=2222
WEB_PORT=8080
DISTRO="fedora"
FEDORA_VERSION=43
DEBIAN_VERSION=13
VM_IMAGE=""

# ── Subcommand ────────────────────────────────────────────────────────────────
SUBCMD="${1:-start}"
shift || true

case "${SUBCMD}" in
    start|stop|reset|status|logs|console) ;;
    --help|-h)
        sed -n '/^# Usage:/,/^# =/{ /^# =/d; s/^# \{0,1\}//; p }' "$0"
        exit 0
        ;;
    *) echo "Unknown subcommand: ${SUBCMD}. Use: start stop reset status logs console"; exit 1 ;;
esac

# ── Load persisted distro (written by 'start', read by all other subcommands) ─
# Loaded before option parsing so --distro can override it.
DISTRO_FILE="${VM_DIR}/distro"
if [[ "${SUBCMD}" != "start" && -f "${DISTRO_FILE}" ]]; then
    DISTRO=$(cat "${DISTRO_FILE}")
fi

# ── Options (only meaningful for 'start') ─────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --distro)   DISTRO="$2";    shift 2 ;;
        --ram)      RAM_GB="$2";    shift 2 ;;
        --cpus)     CPUS="$2";      shift 2 ;;
        --disk)     DISK_GB="$2";   shift 2 ;;
        --ssh-port) SSH_PORT="$2";  shift 2 ;;
        --web-port) WEB_PORT="$2";  shift 2 ;;
        --image)    VM_IMAGE="$2";  shift 2 ;;
        --vm-dir)   VM_DIR="$2";    shift 2 ;;
        --help|-h)
            sed -n '/^# Usage:/,/^# =/{ /^# =/d; s/^# \{0,1\}//; p }' "$0"
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# ── Validate distro and derive per-distro settings ────────────────────────────
case "${DISTRO}" in
    fedora)
        VM_USER="fedora"
        ;;
    debian)
        VM_USER="debian"
        ;;
    *)
        echo "Unknown distro: ${DISTRO}. Supported values: fedora, debian" >&2
        exit 1
        ;;
esac

# ── RAM: validate range and convert to MB ────────────────────────────────────
if ! [[ "${RAM_GB}" =~ ^[0-9]+$ ]] || [[ "${RAM_GB}" -lt 1 ]]; then
    echo -e "\033[0;31m[ERR]\033[0m   --ram must be an integer ≥ 1 (GB). Got: ${RAM_GB}" >&2
    exit 1
fi
RAM_MB=$(( RAM_GB * 1024 ))

# ── Paths derived from VM_DIR (available to all subcommands) ──────────────────
# Distro-suffixed artifacts allow multiple distros to coexist under the same
# vm-test directory; switching distros with 'start --distro X' never clobbers
# another distro's overlay or seed.
PID_FILE="${VM_DIR}/qemu.pid"
CONSOLE_LOG="${VM_DIR}/console-${DISTRO}.log"
OVERLAY="${VM_DIR}/overlay-${DISTRO}.qcow2"
SEED_ISO="${VM_DIR}/seed-${DISTRO}.iso"
VM_SSH_KEY="${VM_DIR}/vm_key"

# ── Colours ───────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()   { echo -e "${RED}[ERR]${NC}   $*" >&2; exit 1; }
step()  { echo -e "${CYAN}[STEP]${NC}  $*"; }

# ── Helpers ───────────────────────────────────────────────────────────────────
vm_is_running() {
    [[ -f "${PID_FILE}" ]] && kill -0 "$(cat "${PID_FILE}")" 2>/dev/null
}

vm_stop() {
    if vm_is_running; then
        info "Stopping VM (pid $(cat "${PID_FILE}"))..."
        kill "$(cat "${PID_FILE}")"
        rm -f "${PID_FILE}"
        info "VM stopped."
    else
        warn "No running VM found."
        rm -f "${PID_FILE}" 2>/dev/null || true
    fi
}

ssh_q() {
    local opts="-o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes -p ${SSH_PORT}"
    [[ -f "${VM_SSH_KEY}" ]] && opts="${opts} -i ${VM_SSH_KEY}"
    # shellcheck disable=SC2086,SC2029
    # 127.0.0.1 (not localhost) to avoid IPv6 — QEMU user-net only binds IPv4.
    ssh ${opts} "${VM_USER}@127.0.0.1" "$@"
}

# ── stop ──────────────────────────────────────────────────────────────────────
if [[ "${SUBCMD}" == "stop" ]]; then
    vm_stop
    exit 0
fi

# ── reset ─────────────────────────────────────────────────────────────────────
if [[ "${SUBCMD}" == "reset" ]]; then
    vm_stop
    if [[ -f "${OVERLAY}" ]]; then
        rm -f "${OVERLAY}" "${SEED_ISO}" \
              "${VM_DIR}/user-data-${DISTRO}" "${VM_DIR}/meta-data-${DISTRO}" \
              "${VM_DIR}/llm-setup-${DISTRO}.sh" "${VM_DIR}/console-${DISTRO}.log"
        info "Overlay and seed for ${DISTRO} deleted. Run 'start --distro ${DISTRO}' for a fresh VM."
    else
        info "Nothing to reset for ${DISTRO}."
    fi
    exit 0
fi

# ── status ────────────────────────────────────────────────────────────────────
if [[ "${SUBCMD}" == "status" ]]; then
    if vm_is_running; then
        info "VM is running (pid $(cat "${PID_FILE}"))."
        echo ""
        echo "  Web UI:   http://localhost:${WEB_PORT}"
        echo "  Console:  ./test-vm.sh console"
        echo "  Logs:     ./test-vm.sh logs"
        echo "  Stop:     ./test-vm.sh stop"
    else
        warn "VM is not running."
    fi
    exit 0
fi

# ── logs ──────────────────────────────────────────────────────────────────────
if [[ "${SUBCMD}" == "logs" ]]; then
    # After setup: journalctl --user -f  (llm-companion service logs)
    # During setup: sudo journalctl -f   (cloud-init + Ansible output)
    # While VM is unreachable: fall back to raw console log
    if vm_is_running && ssh_q true 2>/dev/null; then
        SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=5 -p ${SSH_PORT}"
        [[ -f "${VM_SSH_KEY}" ]] && SSH_OPTS="${SSH_OPTS} -i ${VM_SSH_KEY}"
        if ssh_q 'test -f ~/.llm-companion-setup-done' 2>/dev/null; then
            # shellcheck disable=SC2086
            exec ssh ${SSH_OPTS} "${VM_USER}@127.0.0.1" 'journalctl --user -f --no-pager'
        else
            # shellcheck disable=SC2086
            exec ssh ${SSH_OPTS} "${VM_USER}@127.0.0.1" 'sudo journalctl -f --no-pager'
        fi
    fi
    [[ -f "${CONSOLE_LOG}" ]] || die "No console log found. Has the VM been started?"
    exec tail -f "${CONSOLE_LOG}"
fi

# ── console ───────────────────────────────────────────────────────────────────
if [[ "${SUBCMD}" == "console" ]]; then
    vm_is_running || die "VM is not running."
    SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=5 -p ${SSH_PORT}"
    [[ -f "${VM_SSH_KEY}" ]] && SSH_OPTS="${SSH_OPTS} -i ${VM_SSH_KEY}"
    # shellcheck disable=SC2086
    exec ssh ${SSH_OPTS} "${VM_USER}@127.0.0.1"
fi

# ── start ─────────────────────────────────────────────────────────────────────

[[ $(id -u) -eq 0 ]] && die "Do NOT run as root."

# ISO creation tool (tried in order of preference)
ISO_TOOL=""
for t in genisoimage mkisofs xorriso; do
    command -v "$t" &>/dev/null && { ISO_TOOL="$t"; break; }
done
[[ -n "${ISO_TOOL}" ]] || \
    die "No ISO creation tool found. Install one: sudo dnf install genisoimage"

for cmd in qemu-system-x86_64 qemu-img wget curl ssh ssh-keygen; do
    command -v "${cmd}" &>/dev/null || die "Required tool not found: ${cmd}"
done

# KVM acceleration
KVM_FLAGS=()
if [[ -w /dev/kvm ]]; then
    KVM_FLAGS=(-enable-kvm -cpu host)
else
    warn "/dev/kvm not writable — KVM acceleration disabled (will be very slow)."
    warn "To fix: sudo usermod -aG kvm \$(whoami) && newgrp kvm"
fi

mkdir -p "${VM_DIR}"
echo "${DISTRO}" > "${DISTRO_FILE}"

# ── Cloud Base image ──────────────────────────────────────────────────────────
if [[ -z "${VM_IMAGE}" ]]; then
    case "${DISTRO}" in
        fedora)
            IMAGES_URL="https://download.fedoraproject.org/pub/fedora/linux/releases/${FEDORA_VERSION}/Cloud/x86_64/images"
            step "Discovering Fedora ${FEDORA_VERSION} Cloud Base image filename..."
            IMAGE_NAME=$(curl -sL --max-time 15 "${IMAGES_URL}/" \
                | grep -oP 'Fedora-Cloud-Base-Generic[^"]+\.qcow2' \
                | head -1)
            [[ -n "${IMAGE_NAME}" ]] || \
                die "Could not discover image filename from ${IMAGES_URL}/. Use --image <path>."
            info "Found: ${IMAGE_NAME}"
            VM_IMAGE="${VM_DIR}/${IMAGE_NAME}"
            ;;
        debian)
            IMAGES_URL="https://cloud.debian.org/images/cloud/trixie/latest"
            IMAGE_NAME="debian-${DEBIAN_VERSION}-generic-amd64.qcow2"
            info "Using Debian ${DEBIAN_VERSION} Cloud image: ${IMAGE_NAME}"
            VM_IMAGE="${VM_DIR}/${IMAGE_NAME}"
            ;;
    esac
fi

if [[ ! -f "${VM_IMAGE}" ]]; then
    case "${DISTRO}" in
        fedora)
            IMAGE_URL="${IMAGES_URL}/$(basename "${VM_IMAGE}")"
            step "Downloading Fedora ${FEDORA_VERSION} Cloud Base image (~550 MB)..."
            ;;
        debian)
            IMAGE_URL="${IMAGES_URL}/$(basename "${VM_IMAGE}")"
            step "Downloading Debian ${DEBIAN_VERSION} Cloud Base image (~400 MB)..."
            ;;
    esac
    if wget --show-progress -O "${VM_IMAGE}.tmp" "${IMAGE_URL}"; then
        mv "${VM_IMAGE}.tmp" "${VM_IMAGE}"
    else
        rm -f "${VM_IMAGE}.tmp"
        die "Download failed. Use --image <path> to specify a local image."
    fi
    info "Image saved: ${VM_IMAGE}"
fi

# ── qcow2 overlay disk ────────────────────────────────────────────────────────
if [[ ! -f "${OVERLAY}" ]]; then
    step "Creating ${DISK_GB}G overlay disk..."
    qemu-img create -f qcow2 -b "$(realpath "${VM_IMAGE}")" -F qcow2 "${OVERLAY}" "${DISK_GB}G"
fi

# ── SSH key ───────────────────────────────────────────────────────────────────
SSH_PUB_KEY=""

for candidate in ~/.ssh/id_ed25519.pub ~/.ssh/id_rsa.pub ~/.ssh/id_ecdsa.pub; do
    if [[ -f "${candidate}" ]]; then
        SSH_PUB_KEY=$(cat "${candidate}")
        info "Using existing SSH public key: ${candidate}"
        break
    fi
done

if [[ -z "${SSH_PUB_KEY}" ]]; then
    if [[ ! -f "${VM_SSH_KEY}" ]]; then
        info "No SSH key found — generating a throwaway key for this VM..."
        ssh-keygen -t ed25519 -N "" -f "${VM_SSH_KEY}" -C "llm-companion-test-vm"
    fi
    SSH_PUB_KEY=$(cat "${VM_SSH_KEY}.pub")
    info "Using generated key: ${VM_SSH_KEY}"
fi

# ── cloud-init seed (created once, paired with the overlay disk) ──────────────
# Regenerated only when the overlay doesn't exist (i.e. on first start or after
# reset). On stop+start the existing seed is reused so cloud-init sees the same
# instance-id and skips once-per-instance modules.
if [[ ! -f "${SEED_ISO}" ]]; then

# ── cloud-init: in-VM setup script ───────────────────────────────────────────
# Written to a file first, then base64-encoded into the cloud-init user-data.
# Runs as root (cloud-init runcmd); user-facing commands run via sudo -u <user>.

SETUP_SCRIPT="${VM_DIR}/llm-setup-${DISTRO}.sh"

if [[ "${DISTRO}" == "fedora" ]]; then
cat > "${SETUP_SCRIPT}" << 'SETUP'
#!/usr/bin/env bash
# Auto-generated by test-vm.sh — do not edit.
# Runs inside the VM as root via cloud-init runcmd.

set -euo pipefail

LOG=/home/fedora/llm-setup.log
exec > >(tee -a "${LOG}") 2>&1

ts() { echo "[$(date '+%H:%M:%S')]"; }

echo "$(ts) ── llm-companion VM setup starting ────────────────────────────"

# ── 1. Mount project directory from 9p virtfs share ──────────────────────────
echo "$(ts) Mounting 9p share..."
modprobe 9pnet_virtio
mkdir -p /mnt/llm-companion
mount -t 9p \
    -o trans=virtio,version=9p2000.L,msize=104857600 \
    llm-companion /mnt/llm-companion
echo "$(ts) 9p share mounted at /mnt/llm-companion"

# ── 2. Copy project files to a writable location ─────────────────────────────
echo "$(ts) Copying project files..."
cp -r /mnt/llm-companion /home/fedora/llm-companion
chown -R fedora:fedora /home/fedora/llm-companion
chmod +x /home/fedora/llm-companion/*.sh
echo "$(ts) Project files ready at /home/fedora/llm-companion"

# ── 3. Install ansible-core ───────────────────────────────────────────────────
echo "$(ts) Installing ansible-core..."
dnf install -y ansible-core
echo "$(ts) ansible-core installed"

# ── 4. Run Ansible playbook (local connection, against localhost) ──────────────
echo "$(ts) Running Ansible playbook..."
sudo -u fedora bash -c '
    cd ~/llm-companion
    ansible-playbook \
        -c local \
        -i "localhost," \
        -e "ansible_user=fedora" \
        ansible/site.yml
'
echo "$(ts) Ansible playbook complete"

# ── 5. Mark setup complete ────────────────────────────────────────────────────
touch /home/fedora/.llm-companion-setup-done
chown fedora:fedora /home/fedora/.llm-companion-setup-done
echo "$(ts) ── Setup complete. Rebooting to start llm-companion service ─────"
SETUP
else
cat > "${SETUP_SCRIPT}" << 'SETUP'
#!/usr/bin/env bash
# Auto-generated by test-vm.sh — do not edit.
# Runs inside the VM as root via cloud-init runcmd.

set -euo pipefail

LOG=/home/debian/llm-setup.log
exec > >(tee -a "${LOG}") 2>&1

ts() { echo "[$(date '+%H:%M:%S')]"; }

echo "$(ts) ── llm-companion VM setup starting ────────────────────────────"

# ── 1. Mount project directory from 9p virtfs share ──────────────────────────
echo "$(ts) Mounting 9p share..."
modprobe 9pnet_virtio
mkdir -p /mnt/llm-companion
mount -t 9p \
    -o trans=virtio,version=9p2000.L,msize=104857600 \
    llm-companion /mnt/llm-companion
echo "$(ts) 9p share mounted at /mnt/llm-companion"

# ── 2. Copy project files to a writable location ─────────────────────────────
echo "$(ts) Copying project files..."
cp -r /mnt/llm-companion /home/debian/llm-companion
chown -R debian:debian /home/debian/llm-companion
chmod +x /home/debian/llm-companion/*.sh
echo "$(ts) Project files ready at /home/debian/llm-companion"

# ── 3. Install ansible-core ───────────────────────────────────────────────────
echo "$(ts) Installing ansible-core..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y ansible
echo "$(ts) ansible-core installed"

# ── 4. Run Ansible playbook (local connection, against localhost) ──────────────
echo "$(ts) Running Ansible playbook..."
sudo -u debian bash -c '
    cd ~/llm-companion
    ansible-playbook \
        -c local \
        -i "localhost," \
        -e "ansible_user=debian" \
        ansible/site.yml
'
echo "$(ts) Ansible playbook complete"

# ── 5. Mark setup complete ────────────────────────────────────────────────────
touch /home/debian/.llm-companion-setup-done
chown debian:debian /home/debian/.llm-companion-setup-done
echo "$(ts) ── Setup complete. Rebooting to start llm-companion service ─────"
SETUP
fi
chmod +x "${SETUP_SCRIPT}"

# ── cloud-init user-data ──────────────────────────────────────────────────────
USERDATA="${VM_DIR}/user-data-${DISTRO}"

# Embed the setup script as base64 to avoid YAML escaping issues.
SETUP_B64=$(base64 -w0 "${SETUP_SCRIPT}")

# Fedora uses the 'wheel' group for sudo; Debian uses 'sudo'.
[[ "${DISTRO}" == "fedora" ]] && VM_GROUPS="wheel" || VM_GROUPS="sudo"

cat > "${USERDATA}" << YAML
#cloud-config

# ── Users ─────────────────────────────────────────────────────────────────────
users:
  - name: ${VM_USER}
    groups: ${VM_GROUPS}
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: false
    plain_text_passwd: ${VM_USER}
    ssh_authorized_keys:
      - ${SSH_PUB_KEY}

# ── Setup script ─────────────────────────────────────────────────────────────
write_files:
  - path: /root/llm-setup.sh
    permissions: '0755'
    encoding: b64
    content: ${SETUP_B64}

# ── Run setup ─────────────────────────────────────────────────────────────────
runcmd:
  - /root/llm-setup.sh

# ── Reboot after setup ────────────────────────────────────────────────────────
# loginctl linger (enabled by the Ansible common role) causes user@1000.service
# to start on the next boot. The llm-companion service (WantedBy=default.target)
# will then start automatically.
power_state:
  mode: reboot
  delay: 0
  message: "llm-companion setup complete — rebooting to start llm-companion service"
YAML

METADATA="${VM_DIR}/meta-data-${DISTRO}"
# Unique instance-id per overlay: cloud-init skips once-per-instance modules
# if it recognises the id from a previous boot of the same overlay.
INSTANCE_ID="llm-companion-$(date +%s)"
cat > "${METADATA}" << YAML
instance-id: ${INSTANCE_ID}
local-hostname: llm-companion-test
YAML

# ── cloud-init seed ISO ───────────────────────────────────────────────────────
step "Creating cloud-init seed ISO..."
case "${ISO_TOOL}" in
    genisoimage|mkisofs)
        "${ISO_TOOL}" -output "${SEED_ISO}" -volid cidata -joliet -rock \
            "${USERDATA}" "${METADATA}" 2>/dev/null ;;
    xorriso)
        xorriso -as mkisofs -output "${SEED_ISO}" -volid cidata -joliet -rock \
            "${USERDATA}" "${METADATA}" 2>/dev/null ;;
esac

fi # end: seed ISO creation (skipped on stop+start)

# ── Check if already running ──────────────────────────────────────────────────
if vm_is_running; then
    warn "VM already running (pid $(cat "${PID_FILE}"))."
    echo ""
    echo "  Web UI:   http://localhost:${WEB_PORT}"
    echo "  Console:  ./test-vm.sh console"
    echo "  Stop:     ./test-vm.sh stop"
    exit 0
fi

# ── Launch QEMU ───────────────────────────────────────────────────────────────
MONITOR_SOCK="${VM_DIR}/monitor.sock"

QEMU_CMD=(
    qemu-system-x86_64
    -name     "llm-companion-test"
    -machine  "q35"
    -m        "${RAM_MB}"
    -smp      "${CPUS}"
    -drive    "file=${OVERLAY},format=qcow2,if=virtio"
    -drive    "file=${SEED_ISO},format=raw,if=virtio,readonly=on"
    # Share the project directory read-only via 9p virtfs.
    # The VM mounts this at /mnt/llm-companion and copies files from there.
    -virtfs   "local,path=${SCRIPT_DIR},mount_tag=llm-companion,security_model=none,readonly=on"
    # User-mode networking: no root needed; port-forwards for SSH and WebUI.
    -netdev   "user,id=net0,hostfwd=tcp::${SSH_PORT}-:22,hostfwd=tcp::${WEB_PORT}-:8080"
    -device   "virtio-net-pci,netdev=net0"
    -display  none
    -serial   "file:${CONSOLE_LOG}"
    -monitor  "unix:${MONITOR_SOCK},server,nowait"
    -daemonize
    -pidfile  "${PID_FILE}"
)
# Append KVM flags only when available (array may be empty)
[[ ${#KVM_FLAGS[@]} -gt 0 ]] && QEMU_CMD+=("${KVM_FLAGS[@]}")

step "Launching QEMU VM (distro: ${DISTRO})..."
"${QEMU_CMD[@]}"

info "QEMU started (pid $(cat "${PID_FILE}"))"

# Stream console log to stdout — killed automatically when this script exits.
# Strip ANSI escape sequences to prevent cursor-position query responses
# from leaking as raw text onto the caller's terminal.
tail -f "${CONSOLE_LOG}" | sed -u 's/\x1b\[[0-9;]*[A-Za-z]//g; s/\x1b[()]//g' &
TAIL_PID=$!
trap 'kill "${TAIL_PID}" 2>/dev/null || true; stty sane 2>/dev/null || true' EXIT

# ── Wait for first SSH (VM boot) ──────────────────────────────────────────────
step "Waiting for VM to boot..."
until ssh_q true 2>/dev/null; do sleep 5; done
info "SSH is up — cloud-init setup is running (package upgrade + podman pull, 10–20 min)."

# ── Wait for setup completion marker ─────────────────────────────────────────
step "Waiting for setup to complete (polls every 20 s)..."
until ssh_q 'test -f ~/.llm-companion-setup-done' 2>/dev/null; do sleep 20; done
info "Setup done — VM is rebooting to start llm-companion service."

# ── Wait for reboot and second SSH ───────────────────────────────────────────
sleep 20
step "Waiting for VM to come back after reboot..."
until ssh_q true 2>/dev/null; do sleep 5; done
sleep 15   # give systemd a moment to start the llm-companion service

# ── Service status ────────────────────────────────────────────────────────────
info "Checking service status..."
# shellcheck disable=SC2016  # $(id -u) is intentionally expanded on the remote
ssh_q 'XDG_RUNTIME_DIR=/run/user/$(id -u) systemctl --user status llm-companion --no-pager -l' 2>/dev/null || true

# ── Read back the generated API key ──────────────────────────────────────────
API_KEY=$(ssh_q 'grep OLLAMA_API_KEY ~/.config/ollama/api-key.env 2>/dev/null | cut -d= -f2-' 2>/dev/null \
          || echo "(not found — check ~/llm-setup.log in the VM)")

# ── Done ─────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}══════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  llm-companion test VM is ready! (${DISTRO})${NC}"
echo -e "${GREEN}══════════════════════════════════════════════════════════════${NC}"
echo ""
echo "  Open WebUI:   http://localhost:${WEB_PORT}"
echo "                (create your admin account on first visit)"
echo ""
echo "  Ollama API:   http://localhost:${WEB_PORT}/ollama/v1"
echo "  API key:      ${API_KEY}"
echo ""
echo "  Console:      ./test-vm.sh console"
echo "  Logs:         ./test-vm.sh logs"
echo "  Status:       ./test-vm.sh status"
echo "  Stop:         ./test-vm.sh stop"
echo "  Fresh reset:  ./test-vm.sh reset  (keeps downloaded ${DISTRO} image)"
echo ""
echo "  Pull models:  ./test-vm.sh console"
echo "                  ./llm-companion/pull-models.sh"
echo ""
