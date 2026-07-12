#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Thomas Perrot <thomas.perrot@tupi.fr>
# SPDX-License-Identifier: GPL-3.0-only

# =============================================================================
# vm.sh — Manage QEMU/KVM VMs for the llm-companion stack
#
# Run as a regular user with sudo access (NOT as root).
#
# Usage:
#   ./vm.sh <subcommand> [OPTIONS]
#
# Subcommands:
#   build     One-time provisioning: download base image, run Ansible via
#             cloud-init, bake a golden qcow2 image, and write <name>.conf.
#   start     Start the VM from the golden image; stream logs until ready
#   stop      Stop the running VM
#   clean     Stop + delete overlay/seed/golden + unit file for one VM (--name) or all
#   mrproper  Like clean, but also delete the downloaded base image(s)
#   status    Show whether the VM is running and its connection info
#   logs      Stream the VM console log (tail -f)
#   console   Open an SSH session into the running VM
#   check     Check that all services are up and healthy (requires running VM)
#   enable    Install the systemd user unit, enable it, and activate linger
#   disable   Disable the systemd user unit (unit file is kept)
#
# Options (all subcommands):
#   --name NAME         VM name; selects <name>.conf in --vm-dir.
#                       Auto-detected when exactly one .conf exists.
#   --vm-dir DIR        Directory for VM artifacts             (default: ./vm-test)
#   --host HOST                Remote server: run the subcommand on HOST via SSH
#   --user USER                SSH user for --host                  (default: $USER)
#   --remote-project-dir DIR   Project directory on the remote host (default: $HOME/llm-companion)
#   --remote-vm-dir DIR        vm-dir to use on the remote host     (default: $HOME/vm-test)
#
# Build-only options (only valid with 'build'):
#   --distro DISTRO     Target distribution: fedora or debian  (default: fedora)
#   --ram GB            VM RAM in gigabytes (≥ 1)              (default: 8)
#   --cpus N            Number of vCPUs                        (default: 4)
#   --disk GB           Overlay disk size in GB                (default: 40)
#   --ssh-port PORT     Host port → guest:22                   (default: 2222)
#   --web-port PORT     Host port → guest:8080                 (default: 8080)
#   --image PATH        Cloud Base qcow2 image (auto-downloaded if absent)
#
# Typical workflow:
#   First build:
#     ./vm.sh build                                    # name defaults to 'fedora'
#     ./vm.sh build --distro fedora --name fedora-gpu --ram 32 --cpus 8
#   Run:
#     ./vm.sh start           # auto-detected when only one VM exists
#     ./vm.sh start --name fedora-gpu
#   Systemd:
#     ./vm.sh enable          # writes + enables the unit, activates linger
#     systemctl --user start llm-companion-vm-<name>
#   Rebuild:
#     ./vm.sh clean && ./vm.sh build && ./vm.sh start
#
# What 'build' does:
#   1.  Downloads the Cloud Base image if not already cached
#   2.  Creates a qcow2 overlay disk backed by that image
#   3.  Generates a cloud-init seed that:
#         a. Mounts the project directory via 9p virtfs (read-only)
#         b. Installs ansible-core
#         c. Runs the Ansible playbook (local connection) — installs
#            prerequisites, firewall, Podman, builds the container image,
#            generates secrets, installs Quadlet units, and enables the service
#   4.  Launches QEMU with KVM, shared project dir, and port forwards
#   5.  Waits for provisioning to complete, then shuts down the VM gracefully
#   6.  Converts the overlay to a self-contained golden qcow2 image
#   7.  Writes <name>.conf (stores build settings) and a systemd user unit file
#
# What 'start' does (requires a golden image from 'build'):
#   1.  Creates a thin qcow2 overlay backed by the golden image
#   2.  Generates a minimal cloud-init seed (SSH key only, no setup script)
#   3.  Launches QEMU — the VM boots directly into the provisioned state
#   4.  Streams console log to stdout until the llm-companion service is ready,
#       then exits (QEMU keeps running in the background)
#
# Systemd integration (Type=notify) — run on the machine where QEMU runs:
#   [Service]
#   Type=notify
#   NotifyAccess=all
#   ExecStart=/path/to/vm.sh start --name <name>
#   ExecStop=/path/to/vm.sh stop  --name <name>
#
#   When started as a service, vm.sh signals readiness once the VM is up, then
#   stays alive forwarding llm-companion logs from the VM to stdout → journald.
#   Interactive invocations (no NOTIFY_SOCKET) exit after printing the banner.
#
# Remote mode (--host HOST):
#   Forwards the subcommand to HOST via SSH. 'build' also rsyncs the project
#   directory to HOST first. For systemd integration, deploy vm.sh on the
#   remote host and run it there directly (without --host).
#
# After the VM is ready:
#   Web UI:     http://localhost:8080
#   Console:    ./vm.sh console
#   Logs:       ./vm.sh logs
#
# NOTE: No models are pulled by default. To pull models in the VM:
#         ./vm.sh console
#         pull-models.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ── Defaults ──────────────────────────────────────────────────────────────────
VM_DIR="${PROJECT_DIR}/vm-test"
NAME=""
# Build-only defaults:
DISTRO="fedora"
FEDORA_VERSION=44
DEBIAN_VERSION=13
RAM_GB=8
CPUS=4
DISK_GB=40
SSH_PORT=2222
WEB_PORT=8080
VM_IMAGE=""
# Remote options:
REMOTE_HOST=""
REMOTE_USER="${USER}"
REMOTE_PROJECT_DIR="\$HOME/llm-companion"
REMOTE_VM_DIR="\$HOME/vm-test"

# ── Subcommand ────────────────────────────────────────────────────────────────
SUBCMD="${1:-start}"
shift || true

case "${SUBCMD}" in
    build|start|stop|clean|mrproper|status|logs|console|check|enable|disable) ;;
    --help|-h)
        sed -n '/^# Usage:/,/^# =/{ /^# =/d; s/^# \{0,1\}//; p }' "$0"
        exit 0
        ;;
    *) echo "Unknown subcommand: ${SUBCMD}. Use: build start stop clean mrproper status logs console check enable disable"; exit 1 ;;
esac

# ── Options ───────────────────────────────────────────────────────────────────
BUILD_ONLY_OPTS_USED=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --name)          NAME="$2";          shift 2 ;;
        --vm-dir)        VM_DIR="$2";        shift 2 ;;
        --host)                REMOTE_HOST="$2";        shift 2 ;;
        --user)                REMOTE_USER="$2";        shift 2 ;;
        --remote-project-dir)  REMOTE_PROJECT_DIR="$2"; shift 2 ;;
        --remote-vm-dir)       REMOTE_VM_DIR="$2";      shift 2 ;;
        --distro)   DISTRO="$2";   BUILD_ONLY_OPTS_USED+=(--distro);   shift 2 ;;
        --ram)      RAM_GB="$2";   BUILD_ONLY_OPTS_USED+=(--ram);      shift 2 ;;
        --cpus)     CPUS="$2";     BUILD_ONLY_OPTS_USED+=(--cpus);     shift 2 ;;
        --disk)     DISK_GB="$2";  BUILD_ONLY_OPTS_USED+=(--disk);     shift 2 ;;
        --ssh-port) SSH_PORT="$2"; BUILD_ONLY_OPTS_USED+=(--ssh-port); shift 2 ;;
        --web-port) WEB_PORT="$2"; BUILD_ONLY_OPTS_USED+=(--web-port); shift 2 ;;
        --image)    VM_IMAGE="$2"; BUILD_ONLY_OPTS_USED+=(--image);    shift 2 ;;
        --help|-h)
            sed -n '/^# Usage:/,/^# =/{ /^# =/d; s/^# \{0,1\}//; p }' "$0"
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

if [[ "${SUBCMD}" != "build" && ${#BUILD_ONLY_OPTS_USED[@]} -gt 0 ]]; then
    echo "Error: ${BUILD_ONLY_OPTS_USED[*]} are only valid for 'build'. Other subcommands load settings from <name>.conf." >&2
    exit 1
fi

# VM_SSH_KEY is shared across all VMs under the same vm-dir (computed once).
VM_SSH_KEY="${VM_DIR}/vm_key"

# ── Colours ───────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()   { echo -e "${RED}[ERR]${NC}   $*" >&2; exit 1; }
step()  { echo -e "${CYAN}[STEP]${NC}  $*"; }

# ── VM name / conf helpers ────────────────────────────────────────────────────

# Sets NAME to the single existing VM in VM_DIR, or errors.
auto_detect_name() {
    shopt -s nullglob
    local confs=( "${VM_DIR}"/*.conf )
    shopt -u nullglob
    if [[ ${#confs[@]} -eq 1 ]]; then
        NAME="$(basename "${confs[0]}" .conf)"
        info "Auto-detected VM: ${NAME}"
    elif [[ ${#confs[@]} -eq 0 ]]; then
        die "No VM found in ${VM_DIR}. Run './vm.sh build' first."
    else
        echo -e "${RED}[ERR]${NC}   Multiple VMs in ${VM_DIR}. Specify one with --name:" >&2
        for c in "${confs[@]}"; do echo "  $(basename "${c}" .conf)" >&2; done
        exit 1
    fi
}

# Sources <name>.conf; populates DISTRO, RAM_GB, CPUS, DISK_GB, SSH_PORT,
# WEB_PORT, VM_USER, VM_GROUPS from the file.
load_conf() {
    local name="$1"
    local conf="${VM_DIR}/${name}.conf"
    [[ -f "${conf}" ]] || die "VM '${name}' not found: ${conf}\nRun './vm.sh build --name ${name}' first."
    # shellcheck source=/dev/null
    source "${conf}"
}

# Writes <name>.conf after a successful build.
write_conf_file() {
    local conf="${VM_DIR}/${NAME}.conf"
    cat > "${conf}" << CONF
# llm-companion VM configuration — auto-generated by vm.sh build
DISTRO=${DISTRO}
RAM_GB=${RAM_GB}
CPUS=${CPUS}
DISK_GB=${DISK_GB}
SSH_PORT=${SSH_PORT}
WEB_PORT=${WEB_PORT}
VM_USER=${VM_USER}
VM_GROUPS=${VM_GROUPS}
CONF
    info "VM config written: ${conf}"
}

# Computes per-VM artifact paths. Call after NAME is set.
setup_vm_paths() {
    PID_FILE="${VM_DIR}/qemu-${NAME}.pid"
    CONSOLE_LOG="${VM_DIR}/console-${NAME}.log"
    OVERLAY="${VM_DIR}/overlay-${NAME}.qcow2"
    SEED_ISO="${VM_DIR}/seed-${NAME}.iso"
    GOLDEN_IMAGE="${VM_DIR}/golden-${NAME}.qcow2"
    MONITOR_SOCK="${VM_DIR}/monitor-${NAME}.sock"
}

# ── VM operation helpers ──────────────────────────────────────────────────────
vm_is_running() {
    [[ -f "${PID_FILE}" ]] && kill -0 "$(cat "${PID_FILE}")" 2>/dev/null
}

vm_stop() {
    if vm_is_running; then
        info "Stopping VM '${NAME}' (pid $(cat "${PID_FILE}"))..."
        kill "$(cat "${PID_FILE}")"
        rm -f "${PID_FILE}"
        info "VM stopped."
    else
        warn "No running VM '${NAME}' found."
        rm -f "${PID_FILE}" 2>/dev/null || true
    fi
}

ssh_q() {
    local opts="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o BatchMode=yes -p ${SSH_PORT}"
    [[ -f "${VM_SSH_KEY}" ]] && opts="${opts} -i ${VM_SSH_KEY}"
    # shellcheck disable=SC2086,SC2029
    # 127.0.0.1 (not localhost) to avoid IPv6 — QEMU user-net only binds IPv4.
    ssh ${opts} "${VM_USER}@127.0.0.1" "$@"
}

check_services() {
    vm_is_running || die "VM '${NAME}' is not running."
    step "Service health checks (via SSH)..."
    ssh_q "\$HOME/.local/bin/check-services.sh"
}

wait_for_services() {
    local timeout=300 interval=15 elapsed=0 out
    step "Waiting for all services to be healthy..."
    while true; do
        out=$(ssh_q "\$HOME/.local/bin/check-services.sh" 2>/dev/null) && { echo "${out}"; return 0; }
        elapsed=$((elapsed + interval))
        if [[ ${elapsed} -ge ${timeout} ]]; then
            echo "${out}"
            warn "Some services are not healthy after ${timeout}s — run './vm.sh check' to inspect."
            return 1
        fi
        info "Not all services ready yet (${elapsed}s / ${timeout}s)..."
        sleep ${interval}
    done
}

wait_for_ssh() {
    local timeout=300 interval=5 elapsed=0
    step "Waiting for VM to boot (SSH)..."
    until ssh_q true 2>/dev/null; do
        elapsed=$((elapsed + interval))
        [[ ${elapsed} -ge ${timeout} ]] && \
            die "VM did not become reachable over SSH after ${timeout}s. Check './vm.sh console' for boot errors."
        sleep ${interval}
    done
    info "SSH is up."
}

wait_for_service() {
    local timeout=600 interval=10 elapsed=0
    step "Waiting for llm-companion service to become active..."
    local state running
    while true; do
        # shellcheck disable=SC2016
        state=$(ssh_q 'XDG_RUNTIME_DIR=/run/user/$(id -u) systemctl --user is-active llm-companion' 2>/dev/null || true)
        case "${state}" in
            active)
                info "llm-companion is active."
                return 0
                ;;
            failed)
                warn "llm-companion failed to start. Recent journal:"
                # shellcheck disable=SC2016
                ssh_q 'XDG_RUNTIME_DIR=/run/user/$(id -u) journalctl --user -u llm-companion -n 20 --no-pager' \
                    2>/dev/null || true
                die "Service failed to start. Run './vm.sh logs' for details."
                ;;
            *)
                running=$(ssh_q 'podman ps --format "{{.Names}}"' 2>/dev/null | tr '\n' ' ' || true)
                if [[ -n "${running// /}" ]]; then
                    info "${state:-unknown} — containers up: ${running}"
                else
                    info "${state:-unknown} — no containers yet (image pull in progress)"
                fi
                elapsed=$((elapsed + interval))
                [[ ${elapsed} -ge ${timeout} ]] && \
                    die "llm-companion service did not become active after ${timeout}s. Run './vm.sh logs' for details."
                sleep ${interval}
                ;;
        esac
    done
}

# ── Remote helpers ────────────────────────────────────────────────────────────
remote_rsync() {
    step "Syncing project to ${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PROJECT_DIR}..."
    rsync -az --delete \
        --exclude='.git/' \
        --exclude='vm-test/' \
        --exclude='*.qcow2' \
        --exclude='*.iso' \
        "${PROJECT_DIR}/" \
        "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PROJECT_DIR}/"
}

# Forwards the current subcommand and relevant options to the remote host.
remote_vm() {
    local tty_flag=""
    [[ "${SUBCMD}" == "console" || "${SUBCMD}" == "logs" ]] && tty_flag="-t"
    local fwd_cmd="${REMOTE_PROJECT_DIR}/scripts/vm.sh ${SUBCMD}"
    [[ -n "${NAME}" ]] && fwd_cmd+=" --name ${NAME}"
    fwd_cmd+=" --vm-dir ${REMOTE_VM_DIR}"
    if [[ "${SUBCMD}" == "build" ]]; then
        fwd_cmd+=" --distro ${DISTRO}"
        fwd_cmd+=" --ram ${RAM_GB} --cpus ${CPUS} --disk ${DISK_GB}"
        fwd_cmd+=" --ssh-port ${SSH_PORT} --web-port ${WEB_PORT}"
        [[ -n "${VM_IMAGE}" ]] && fwd_cmd+=" --image ${VM_IMAGE}"
    fi
    # shellcheck disable=SC2029,SC2086
    ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 ${tty_flag} \
        "${REMOTE_USER}@${REMOTE_HOST}" "${fwd_cmd}"
}

# ── Unit file helpers ─────────────────────────────────────────────────────────
write_unit_file() {
    local unit_name="llm-companion-vm-${NAME}.service"
    local unit_dir="${HOME}/.config/systemd/user"
    local script_abs; script_abs="$(realpath "$0")"
    local vm_dir_abs; vm_dir_abs="$(realpath "${VM_DIR}" 2>/dev/null || echo "${VM_DIR}")"
    local exec_opts="--name ${NAME} --vm-dir ${vm_dir_abs}"
    [[ -n "${REMOTE_HOST}" ]] && exec_opts+=" --host ${REMOTE_HOST} --user ${REMOTE_USER}"

    mkdir -p "${unit_dir}"
    cat > "${unit_dir}/${unit_name}" << UNIT
[Unit]
Description=llm-companion QEMU/KVM VM (${NAME})
After=network.target

[Service]
Type=notify
NotifyAccess=all
ExecStart=${script_abs} start ${exec_opts}
ExecStop=${script_abs} stop --name ${NAME} --vm-dir ${vm_dir_abs}

[Install]
WantedBy=default.target
UNIT
    info "Unit file written: ${unit_dir}/${unit_name}"
}

do_enable() {
    local unit_name="llm-companion-vm-${NAME}.service"
    write_unit_file
    systemctl --user daemon-reload
    systemctl --user enable "${unit_name}"
    # loginctl linger allows the user's systemd instance to start at boot
    # without an active login session.
    loginctl enable-linger 2>/dev/null || \
        warn "loginctl enable-linger failed — service may not start at boot without a session."
    info "Service enabled: ${unit_name}"
    echo ""
    echo "  Start:    systemctl --user start  ${unit_name}"
    echo "  Stop:     systemctl --user stop   ${unit_name}"
    echo "  Logs:     journalctl --user -u ${unit_name} -f"
    echo "  Disable:  ./vm.sh disable [--name ${NAME}]"
    echo ""
}

# ── Remote mode dispatch ──────────────────────────────────────────────────────
if [[ -n "${REMOTE_HOST}" ]]; then
    [[ "${SUBCMD}" == "build" ]] && remote_rsync
    remote_vm
    exit $?
fi

# ── stop ──────────────────────────────────────────────────────────────────────
if [[ "${SUBCMD}" == "stop" ]]; then
    [[ -z "${NAME}" ]] && auto_detect_name
    setup_vm_paths
    vm_stop
    exit 0
fi

# ── clean / mrproper helpers ──────────────────────────────────────────────────
clean_one() {
    local n="$1"
    rm -f "${VM_DIR}/overlay-${n}.qcow2" \
          "${VM_DIR}/seed-${n}.iso" \
          "${VM_DIR}/golden-${n}.qcow2" \
          "${VM_DIR}/user-data-${n}" \
          "${VM_DIR}/meta-data-${n}" \
          "${VM_DIR}/llm-setup-${n}.sh" \
          "${VM_DIR}/monitor-${n}.sock"
}

remove_unit() {
    local n="$1"
    local unit="llm-companion-vm-${n}.service"
    local unit_file="${HOME}/.config/systemd/user/${unit}"
    [[ -f "${unit_file}" ]] || return 0
    systemctl --user is-active "${unit}" &>/dev/null && systemctl --user stop "${unit}"
    systemctl --user disable "${unit}" 2>/dev/null || true
    rm -f "${unit_file}"
    systemctl --user daemon-reload
    info "Unit file removed: ${unit_file}"
}

vm_has_artifacts() {
    local n="$1"
    [[ -f "${VM_DIR}/overlay-${n}.qcow2" ]] || \
    [[ -f "${VM_DIR}/seed-${n}.iso" ]] || \
    [[ -f "${VM_DIR}/golden-${n}.qcow2" ]]
}

distro_has_base_image() {
    local d="$1"
    case "${d}" in
        fedora) compgen -G "${VM_DIR}/Fedora-Cloud-Base-*.qcow2" > /dev/null 2>&1 ;;
        debian) compgen -G "${VM_DIR}/debian-*.qcow2" > /dev/null 2>&1 ;;
        *) false ;;
    esac
}

delete_base_image() {
    local d="$1"
    case "${d}" in
        fedora) rm -f "${VM_DIR}"/Fedora-Cloud-Base-*.qcow2 ;;
        debian) rm -f "${VM_DIR}"/debian-*.qcow2 ;;
        *) ;;
    esac
}

# ── clean ─────────────────────────────────────────────────────────────────────
if [[ "${SUBCMD}" == "clean" ]]; then
    if [[ -n "${NAME}" ]]; then
        setup_vm_paths
        if vm_is_running; then vm_stop; fi
        if vm_has_artifacts "${NAME}" || [[ -f "${CONSOLE_LOG}" ]]; then
            clean_one "${NAME}"
            rm -f "${CONSOLE_LOG}"
            remove_unit "${NAME}"
            info "Artifacts for '${NAME}' deleted."
        else
            info "Nothing to clean for '${NAME}'."
        fi
    else
        shopt -s nullglob
        all_confs=( "${VM_DIR}"/*.conf )
        shopt -u nullglob
        if [[ ${#all_confs[@]} -eq 0 ]]; then
            info "Nothing to clean."
        else
            for _conf in "${all_confs[@]}"; do
                _n="$(basename "${_conf}" .conf)"
                _pid="${VM_DIR}/qemu-${_n}.pid"
                if [[ -f "${_pid}" ]] && kill -0 "$(cat "${_pid}")" 2>/dev/null; then
                    info "Stopping VM '${_n}'..."
                    kill "$(cat "${_pid}")"
                    rm -f "${_pid}"
                fi
                clean_one "${_n}"
                rm -f "${VM_DIR}/console-${_n}.log"
                remove_unit "${_n}"
                info "Artifacts for '${_n}' deleted."
            done
        fi
    fi
    exit 0
fi

# ── mrproper ──────────────────────────────────────────────────────────────────
if [[ "${SUBCMD}" == "mrproper" ]]; then
    if [[ -n "${NAME}" ]]; then
        load_conf "${NAME}"
        setup_vm_paths
        if vm_is_running; then vm_stop; fi
        clean_one "${NAME}"
        rm -f "${CONSOLE_LOG}" "${VM_DIR}/${NAME}.conf"
        delete_base_image "${DISTRO}"
        info "All artifacts and base image for '${NAME}' deleted."
    else
        shopt -s nullglob
        all_confs=( "${VM_DIR}"/*.conf )
        shopt -u nullglob
        declare -A _seen_distros=()
        for _conf in "${all_confs[@]}"; do
            _n="$(basename "${_conf}" .conf)"
            _pid="${VM_DIR}/qemu-${_n}.pid"
            if [[ -f "${_pid}" ]] && kill -0 "$(cat "${_pid}")" 2>/dev/null; then
                info "Stopping VM '${_n}'..."
                kill "$(cat "${_pid}")"
                rm -f "${_pid}"
            fi
            _d="$(grep '^DISTRO=' "${_conf}" | cut -d= -f2-)"
            _seen_distros["${_d}"]=1
            clean_one "${_n}"
            rm -f "${VM_DIR}/console-${_n}.log" "${_conf}"
            info "Artifacts for '${_n}' deleted."
        done
        for _d in "${!_seen_distros[@]}"; do
            delete_base_image "${_d}"
        done
        info "All artifacts and base images deleted."
    fi
    exit 0
fi

# ── Load conf for all remaining subcommands ───────────────────────────────────
# start, status, logs, console, check, enable, disable all need the conf.
# build handles its own NAME defaulting and setup_vm_paths call.
if [[ "${SUBCMD}" != "build" ]]; then
    [[ -z "${NAME}" ]] && auto_detect_name
    load_conf "${NAME}"
    setup_vm_paths
fi

# ── status ────────────────────────────────────────────────────────────────────
if [[ "${SUBCMD}" == "status" ]]; then
    if vm_is_running; then
        info "VM '${NAME}' is running (pid $(cat "${PID_FILE}"))."
        echo ""
        echo "  Web UI:   http://localhost:${WEB_PORT}"
        echo "  Console:  ./vm.sh console [--name ${NAME}]"
        echo "  Logs:     ./vm.sh logs    [--name ${NAME}]"
        echo "  Stop:     ./vm.sh stop    [--name ${NAME}]"
    else
        warn "VM '${NAME}' is not running."
    fi
    exit 0
fi

# ── logs ──────────────────────────────────────────────────────────────────────
if [[ "${SUBCMD}" == "logs" ]]; then
    if vm_is_running && ssh_q true 2>/dev/null; then
        SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -p ${SSH_PORT}"
        [[ -f "${VM_SSH_KEY}" ]] && SSH_OPTS="${SSH_OPTS} -i ${VM_SSH_KEY}"
        if ssh_q "test -f \$HOME/.llm-companion-setup-done" 2>/dev/null; then
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
    vm_is_running || die "VM '${NAME}' is not running."
    SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -p ${SSH_PORT}"
    [[ -f "${VM_SSH_KEY}" ]] && SSH_OPTS="${SSH_OPTS} -i ${VM_SSH_KEY}"
    # shellcheck disable=SC2086
    exec ssh ${SSH_OPTS} "${VM_USER}@127.0.0.1"
fi

# ── check ─────────────────────────────────────────────────────────────────────
if [[ "${SUBCMD}" == "check" ]]; then
    check_services
    exit $?
fi

# ── enable ────────────────────────────────────────────────────────────────────
if [[ "${SUBCMD}" == "enable" ]]; then
    do_enable
    exit 0
fi

# ── disable ───────────────────────────────────────────────────────────────────
if [[ "${SUBCMD}" == "disable" ]]; then
    DISABLE_UNIT="llm-companion-vm-${NAME}.service"
    if systemctl --user is-active "${DISABLE_UNIT}" &>/dev/null; then
        step "Stopping ${DISABLE_UNIT}..."
        systemctl --user stop "${DISABLE_UNIT}"
    fi
    systemctl --user disable "${DISABLE_UNIT}" 2>/dev/null || warn "Service was not enabled."
    systemctl --user daemon-reload
    info "Service disabled: ${DISABLE_UNIT}"
    info "Unit file kept at: ${HOME}/.config/systemd/user/${DISABLE_UNIT}"
    exit 0
fi

# ── Common pre-checks for build and start ────────────────────────────────────
[[ $(id -u) -eq 0 ]] && die "Do NOT run as root."

for _cmd in qemu-system-x86_64 qemu-img ssh ssh-keygen; do
    command -v "${_cmd}" &>/dev/null || die "Required tool not found: ${_cmd}"
done

KVM_FLAGS=()
if [[ -w /dev/kvm ]]; then
    KVM_FLAGS=(-enable-kvm -cpu host)
else
    warn "/dev/kvm not writable — KVM acceleration disabled (will be very slow)."
    warn "To fix: sudo usermod -aG kvm \$(whoami) && newgrp kvm"
fi

mkdir -p "${VM_DIR}"

# ── build ─────────────────────────────────────────────────────────────────────
if [[ "${SUBCMD}" == "build" ]]; then
    [[ -z "${NAME}" ]] && NAME="${DISTRO}"

    case "${DISTRO}" in
        fedora) VM_USER="fedora"; VM_GROUPS="wheel" ;;
        debian) VM_USER="debian"; VM_GROUPS="sudo"  ;;
        *) die "Unknown distro: ${DISTRO}. Supported values: fedora, debian" ;;
    esac

    if ! [[ "${RAM_GB}" =~ ^[0-9]+$ ]] || [[ "${RAM_GB}" -lt 1 ]]; then
        die "--ram must be an integer ≥ 1 (GB). Got: ${RAM_GB}"
    fi
    RAM_MB=$(( RAM_GB * 1024 ))

    setup_vm_paths

    [[ -f "${GOLDEN_IMAGE}" ]] && {
        warn "Golden image already exists: ${GOLDEN_IMAGE}"
        warn "Run './vm.sh clean --name ${NAME}' to delete it before rebuilding."
        exit 0
    }

    vm_is_running && \
        die "A QEMU instance for '${NAME}' is already running (pid $(cat "${PID_FILE}")).\n  This is likely a provisioning VM left over from an interrupted build.\n  Stop it first: ./vm.sh stop --name ${NAME}"

    ISO_TOOL=""
    for t in genisoimage mkisofs xorriso; do
        command -v "$t" &>/dev/null && { ISO_TOOL="$t"; break; }
    done
    [[ -n "${ISO_TOOL}" ]] || die "No ISO creation tool found. Install one: sudo dnf install genisoimage"

    for _cmd in wget curl; do
        command -v "${_cmd}" &>/dev/null || die "Required tool not found: ${_cmd}"
    done

    # ── Cloud Base image ──────────────────────────────────────────────────────
    IMAGES_URL=""
    if [[ -z "${VM_IMAGE}" ]]; then
        case "${DISTRO}" in
            fedora)
                IMAGES_URL="https://download.fedoraproject.org/pub/fedora/linux/releases/${FEDORA_VERSION}/Cloud/x86_64/images"
                step "Discovering Fedora ${FEDORA_VERSION} Cloud Base image filename..."
                IMAGE_NAME=$(curl -sL --proto '=https' --max-time 15 "${IMAGES_URL}/" \
                    | grep -oP 'Fedora-Cloud-Base-Generic[^"]+\.qcow2' | head -1)
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
        [[ -n "${IMAGES_URL}" ]] || \
            die "Image '${VM_IMAGE}' not found and no URL to download from.\nRemove --image to auto-download, or provide a valid local path."
        IMAGE_URL="${IMAGES_URL}/$(basename "${VM_IMAGE}")"
        case "${DISTRO}" in
            fedora) step "Downloading Fedora ${FEDORA_VERSION} Cloud Base image (~550 MB)..." ;;
            debian) step "Downloading Debian ${DEBIAN_VERSION} Cloud Base image (~400 MB)..." ;;
        esac
        if wget --https-only --show-progress -O "${VM_IMAGE}.tmp" "${IMAGE_URL}"; then # NOSONAR — wget --https-only already enforces HTTPS; S6506 does not recognise this flag
            mv "${VM_IMAGE}.tmp" "${VM_IMAGE}"
        else
            rm -f "${VM_IMAGE}.tmp"
            die "Download failed. Use --image <path> to specify a local image."
        fi
        info "Image saved: ${VM_IMAGE}"
    fi

    # ── SSH public key ────────────────────────────────────────────────────────
    SSH_PUB_KEY=""
    for _candidate in $HOME/.ssh/id_ed25519.pub $HOME/.ssh/id_rsa.pub $HOME/.ssh/id_ecdsa.pub; do
        if [[ -f "${_candidate}" ]]; then
            SSH_PUB_KEY=$(cat "${_candidate}")
            info "Using existing SSH public key: ${_candidate}"
            break
        fi
    done
    if [[ -z "${SSH_PUB_KEY}" ]]; then
        if [[ ! -f "${VM_SSH_KEY}" ]]; then
            info "No SSH key found — generating a throwaway key for this VM..."
            ssh-keygen -t ed25519 -N "" -f "${VM_SSH_KEY}" -C "llm-companion-vm"
        fi
        SSH_PUB_KEY=$(cat "${VM_SSH_KEY}.pub")
        info "Using generated key: ${VM_SSH_KEY}"
    fi

    # ── qcow2 overlay disk ────────────────────────────────────────────────────
    rm -f "${OVERLAY}"
    step "Creating ${DISK_GB}G overlay disk..."
    qemu-img create -f qcow2 -b "$(realpath "${VM_IMAGE}")" -F qcow2 "${OVERLAY}" "${DISK_GB}G"

    # ── cloud-init: in-VM setup script ───────────────────────────────────────
    SETUP_SCRIPT="${VM_DIR}/llm-setup-${NAME}.sh"

    if [[ "${DISTRO}" == "fedora" ]]; then
    cat > "${SETUP_SCRIPT}" << 'SETUP'
#!/usr/bin/env bash
# Auto-generated by vm.sh — do not edit.
set -euo pipefail
LOG=/home/fedora/llm-setup.log
exec > >(tee -a "${LOG}") 2>&1
ts() { echo "[$(date '+%H:%M:%S')]"; }
echo "$(ts) ── llm-companion VM setup starting ────────────────────────────"
echo "$(ts) Mounting 9p share..."
modprobe 9pnet_virtio
mkdir -p /mnt/llm-companion
mount -t 9p -o trans=virtio,version=9p2000.L,msize=104857600 \
    llm-companion /mnt/llm-companion
echo "$(ts) 9p share mounted at /mnt/llm-companion"
echo "$(ts) Copying project files..."
cp -r /mnt/llm-companion /home/fedora/llm-companion
rm -rf /home/fedora/llm-companion/.??* \
       /home/fedora/llm-companion/scripts/vm.sh \
       /home/fedora/llm-companion/vm-test
chown -R fedora:fedora /home/fedora/llm-companion
chmod +x /home/fedora/llm-companion/scripts/*.sh
echo "$(ts) Project files ready at /home/fedora/llm-companion"
echo "$(ts) Installing ansible-core..."
dnf install -y ansible-core
echo "$(ts) ansible-core installed"
echo "$(ts) Running Ansible playbook..."
sudo -u fedora bash -c '
    cd $HOME/llm-companion
    ansible-playbook -c local -i "localhost," -e "ansible_user=fedora" ansible/site.yml
'
echo "$(ts) Ansible playbook complete"
touch /home/fedora/.llm-companion-setup-done
chown fedora:fedora /home/fedora/.llm-companion-setup-done
echo "$(ts) ── Setup complete ──────────────────────────────────────────────"
SETUP
    else
    cat > "${SETUP_SCRIPT}" << 'SETUP'
#!/usr/bin/env bash
# Auto-generated by vm.sh — do not edit.
set -euo pipefail
LOG=/home/debian/llm-setup.log
exec > >(tee -a "${LOG}") 2>&1
ts() { echo "[$(date '+%H:%M:%S')]"; }
echo "$(ts) ── llm-companion VM setup starting ────────────────────────────"
echo "$(ts) Mounting 9p share..."
modprobe 9pnet_virtio
mkdir -p /mnt/llm-companion
mount -t 9p -o trans=virtio,version=9p2000.L,msize=104857600 \
    llm-companion /mnt/llm-companion
echo "$(ts) 9p share mounted at /mnt/llm-companion"
echo "$(ts) Copying project files..."
cp -r /mnt/llm-companion /home/debian/llm-companion
rm -rf /home/debian/llm-companion/.??* \
       /home/debian/llm-companion/scripts/vm.sh \
       /home/debian/llm-companion/vm-test
chown -R debian:debian /home/debian/llm-companion
chmod +x /home/debian/llm-companion/scripts/*.sh
echo "$(ts) Project files ready at /home/debian/llm-companion"
echo "$(ts) Installing ansible-core..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y ansible
echo "$(ts) ansible-core installed"
echo "$(ts) Running Ansible playbook..."
sudo -u debian bash -c '
    cd $HOME/llm-companion
    ansible-playbook -c local -i "localhost," -e "ansible_user=debian" ansible/site.yml
'
echo "$(ts) Ansible playbook complete"
touch /home/debian/.llm-companion-setup-done
chown debian:debian /home/debian/.llm-companion-setup-done
echo "$(ts) ── Setup complete ──────────────────────────────────────────────"
SETUP
    fi
    chmod +x "${SETUP_SCRIPT}"

    # ── cloud-init user-data ──────────────────────────────────────────────────
    USERDATA="${VM_DIR}/user-data-${NAME}"
    SETUP_B64=$(base64 -w0 "${SETUP_SCRIPT}")
    cat > "${USERDATA}" << YAML
#cloud-config

users:
  - name: ${VM_USER}
    groups: ${VM_GROUPS}
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: false
    plain_text_passwd: ${VM_USER}
    ssh_authorized_keys:
      - ${SSH_PUB_KEY}

write_files:
  - path: /root/llm-setup.sh
    permissions: '0755'
    encoding: b64
    content: ${SETUP_B64}

runcmd:
  - /root/llm-setup.sh

power_state:
  mode: reboot
  delay: 0
  message: "llm-companion setup complete — rebooting to start service"
YAML

    METADATA="${VM_DIR}/meta-data-${NAME}"
    INSTANCE_ID="llm-companion-build-$(date +%s)"
    cat > "${METADATA}" << YAML
instance-id: ${INSTANCE_ID}
local-hostname: llm-companion-build
YAML

    # ── cloud-init seed ISO ───────────────────────────────────────────────────
    step "Creating cloud-init seed ISO..."
    case "${ISO_TOOL}" in
        genisoimage|mkisofs)
            "${ISO_TOOL}" -output "${SEED_ISO}" -volid cidata -joliet -rock \
                -graft-points "user-data=${USERDATA}" "meta-data=${METADATA}" 2>/dev/null ;;
        xorriso)
            xorriso -as mkisofs -output "${SEED_ISO}" -volid cidata -joliet -rock \
                -graft-points "user-data=${USERDATA}" "meta-data=${METADATA}" 2>/dev/null ;;
        *) die "No supported ISO tool found (tried genisoimage, mkisofs, xorriso)." ;;
    esac

    # ── Launch QEMU for provisioning ──────────────────────────────────────────
    QEMU_CMD=(
        qemu-system-x86_64
        -name     "llm-companion-build-${NAME}"
        -machine  "q35"
        -m        "${RAM_MB}"
        -smp      "${CPUS}"
        -drive    "file=${OVERLAY},format=qcow2,if=virtio"
        -drive    "file=${SEED_ISO},format=raw,if=virtio,readonly=on"
        -smbios   "type=1,serial=ds=nocloud"
        -virtfs   "local,path=${PROJECT_DIR},mount_tag=llm-companion,security_model=none,readonly=on"
        -netdev   "user,id=net0,hostfwd=tcp::${SSH_PORT}-:22,hostfwd=tcp::${WEB_PORT}-:8080"
        -device   "virtio-net-pci,netdev=net0"
        -display  none
        -serial   "file:${CONSOLE_LOG}"
        -monitor  "unix:${MONITOR_SOCK},server,nowait"
        -daemonize
        -pidfile  "${PID_FILE}"
    )
    [[ ${#KVM_FLAGS[@]} -gt 0 ]] && QEMU_CMD+=("${KVM_FLAGS[@]}")

    step "Launching QEMU VM for provisioning (${DISTRO} / ${NAME})..."
    "${QEMU_CMD[@]}"
    info "QEMU started (pid $(cat "${PID_FILE}"))"

    tail -f "${CONSOLE_LOG}" | sed -u 's/\x1b\[[0-9;]*[A-Za-z]//g; s/\x1b[()]//g' &
    TAIL_PID=$!
    # The provisioning QEMU instance is meant to be short-lived within this
    # build run (it's shut down gracefully below once setup completes), so
    # kill it here too on an abnormal exit (e.g. Ctrl-C mid-provisioning) —
    # otherwise -daemonize leaves it running, holding the overlay disk and
    # SSH_PORT/WEB_PORT, and colliding with the next `build` invocation.
    trap 'kill "${TAIL_PID}" 2>/dev/null || true; [[ -f "${PID_FILE}" ]] && kill "$(cat "${PID_FILE}")" 2>/dev/null || true; stty sane 2>/dev/null || true' EXIT

    wait_for_ssh
    info "SSH is up — cloud-init setup is running (package upgrade + podman build, 10–20 min)."

    step "Waiting for Ansible provisioning to complete (polls every 20 s)..."
    _setup_elapsed=0; _setup_timeout=2400
    until ssh_q "test -f \$HOME/.llm-companion-setup-done" 2>/dev/null; do
        _setup_elapsed=$((_setup_elapsed + 20))
        [[ ${_setup_elapsed} -ge ${_setup_timeout} ]] && \
            die "Provisioning did not finish after ${_setup_timeout}s. Check \$HOME/llm-setup.log in the VM (./vm.sh console)."
        sleep 20
    done
    info "Setup done — VM is rebooting to start llm-companion service."

    sleep 20
    wait_for_ssh
    wait_for_service

    step "Shutting down VM gracefully to bake the golden image..."
    ssh_q 'sudo shutdown -h now' 2>/dev/null || true
    SHUTDOWN_DEADLINE=$(( SECONDS + 90 ))
    while vm_is_running && [[ ${SECONDS} -lt ${SHUTDOWN_DEADLINE} ]]; do sleep 3; done
    if vm_is_running; then
        warn "VM did not shut down in time; forcing stop..."
        kill "$(cat "${PID_FILE}")" 2>/dev/null || true
    fi
    rm -f "${PID_FILE}"
    kill "${TAIL_PID}" 2>/dev/null || true
    trap - EXIT

    step "Converting overlay to golden image (this may take a few minutes)..."
    qemu-img convert -p -O qcow2 "${OVERLAY}" "${GOLDEN_IMAGE}"
    rm -f "${OVERLAY}" "${SEED_ISO}" "${USERDATA}" "${METADATA}" "${SETUP_SCRIPT}"

    echo ""
    echo -e "${GREEN}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}  Golden image ready: ${GOLDEN_IMAGE}${NC}"
    echo -e "${GREEN}══════════════════════════════════════════════════════════════${NC}"
    echo ""

    write_conf_file
    write_unit_file

    echo "  Enable service:  ./vm.sh enable [--name ${NAME}]"
    echo "  Start now:       ./vm.sh start  [--name ${NAME}]"
    echo ""
    exit 0
fi

# ── start ─────────────────────────────────────────────────────────────────────
# At this point NAME, DISTRO, RAM_GB, SSH_PORT, WEB_PORT, VM_USER, VM_GROUPS
# and all artifact paths are set by the conf-loading block above.

RAM_MB=$(( RAM_GB * 1024 ))

[[ -f "${GOLDEN_IMAGE}" ]] || \
    die "Golden image not found: ${GOLDEN_IMAGE}\nRun './vm.sh build --name ${NAME}' first."

# ── Overlay disk (backed by the golden image) ─────────────────────────────────
if [[ ! -f "${OVERLAY}" ]]; then
    step "Creating overlay from golden image..."
    qemu-img create -f qcow2 -b "$(realpath "${GOLDEN_IMAGE}")" -F qcow2 "${OVERLAY}" "${DISK_GB}G"
fi

# ── Minimal cloud-init seed (SSH key only, no setup script) ───────────────────
if [[ ! -f "${SEED_ISO}" ]]; then
    ISO_TOOL=""
    for t in genisoimage mkisofs xorriso; do
        command -v "$t" &>/dev/null && { ISO_TOOL="$t"; break; }
    done
    [[ -n "${ISO_TOOL}" ]] || die "No ISO creation tool found. Install one: sudo dnf install genisoimage"

    SSH_PUB_KEY=""
    for _candidate in $HOME/.ssh/id_ed25519.pub $HOME/.ssh/id_rsa.pub $HOME/.ssh/id_ecdsa.pub; do
        if [[ -f "${_candidate}" ]]; then
            SSH_PUB_KEY=$(cat "${_candidate}")
            break
        fi
    done
    if [[ -z "${SSH_PUB_KEY}" ]]; then
        [[ -f "${VM_SSH_KEY}.pub" ]] || die "No SSH key found. Run './vm.sh build --name ${NAME}' to regenerate."
        SSH_PUB_KEY=$(cat "${VM_SSH_KEY}.pub")
    fi

    USERDATA="${VM_DIR}/user-data-${NAME}"
    METADATA="${VM_DIR}/meta-data-${NAME}"
    INSTANCE_ID="llm-companion-run-$(date +%s)"

    cat > "${USERDATA}" << YAML
#cloud-config

users:
  - name: ${VM_USER}
    groups: ${VM_GROUPS}
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: false
    plain_text_passwd: ${VM_USER}
    ssh_authorized_keys:
      - ${SSH_PUB_KEY}

# Set the hostname early via bootcmd, bypassing hostnamectl which requires
# D-Bus. On Fedora 44 the system bus socket is not ready when cloud-init's
# set_hostname module runs, causing it to fail and marking cloud-init-main
# as failed. preserve_hostname suppresses that module entirely so only the
# bootcmd path runs.
preserve_hostname: true
bootcmd:
  - [/bin/sh, -c, "echo 'llm-companion' > /etc/hostname"]
  - [/usr/bin/hostname, llm-companion]
YAML

    cat > "${METADATA}" << YAML
instance-id: ${INSTANCE_ID}
local-hostname: llm-companion
YAML

    step "Creating minimal cloud-init seed ISO..."
    case "${ISO_TOOL}" in
        genisoimage|mkisofs)
            "${ISO_TOOL}" -output "${SEED_ISO}" -volid cidata -joliet -rock \
                -graft-points "user-data=${USERDATA}" "meta-data=${METADATA}" 2>/dev/null ;;
        xorriso)
            xorriso -as mkisofs -output "${SEED_ISO}" -volid cidata -joliet -rock \
                -graft-points "user-data=${USERDATA}" "meta-data=${METADATA}" 2>/dev/null ;;
        *) die "No supported ISO tool found (tried genisoimage, mkisofs, xorriso)." ;;
    esac
fi

# ── Check if already running ──────────────────────────────────────────────────
if vm_is_running; then
    warn "VM '${NAME}' already running (pid $(cat "${PID_FILE}"))."
    echo ""
    echo "  Web UI:   http://localhost:${WEB_PORT}"
    echo "  Console:  ./vm.sh console [--name ${NAME}]"
    echo "  Stop:     ./vm.sh stop    [--name ${NAME}]"
    exit 0
fi

# ── Launch QEMU ───────────────────────────────────────────────────────────────
QEMU_CMD=(
    qemu-system-x86_64
    -name     "llm-companion-${NAME}"
    -machine  "q35"
    -m        "${RAM_MB}"
    -smp      "${CPUS}"
    -drive    "file=${OVERLAY},format=qcow2,if=virtio"
    -drive    "file=${SEED_ISO},format=raw,if=virtio,readonly=on"
    -smbios   "type=1,serial=ds=nocloud"
    -netdev   "user,id=net0,hostfwd=tcp::${SSH_PORT}-:22,hostfwd=tcp::${WEB_PORT}-:8080"
    -device   "virtio-net-pci,netdev=net0"
    -display  none
    -serial   "file:${CONSOLE_LOG}"
    -monitor  "unix:${MONITOR_SOCK},server,nowait"
    -daemonize
    -pidfile  "${PID_FILE}"
)
[[ ${#KVM_FLAGS[@]} -gt 0 ]] && QEMU_CMD+=("${KVM_FLAGS[@]}")

step "Launching VM '${NAME}' (${DISTRO})..."
"${QEMU_CMD[@]}"
info "QEMU started (pid $(cat "${PID_FILE}"))"

tail -f "${CONSOLE_LOG}" | sed -u 's/\x1b\[[0-9;]*[A-Za-z]//g; s/\x1b[()]//g' &
TAIL_PID=$!
trap 'kill "${TAIL_PID}" 2>/dev/null || true; stty sane 2>/dev/null || true' EXIT

wait_for_ssh
wait_for_service

wait_for_services || true

API_KEY=$(ssh_q "grep OLLAMA_API_KEY \$HOME/.config/ollama/api-key.env 2>/dev/null | cut -d= -f2-" 2>/dev/null \
          || echo "(not found — check $HOME/llm-setup.log in the VM)")

echo ""
echo -e "${GREEN}══════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  llm-companion VM is ready! (${NAME})${NC}"
echo -e "${GREEN}══════════════════════════════════════════════════════════════${NC}"
echo ""
echo "  Open WebUI:   http://localhost:${WEB_PORT}"
echo "                (create your admin account on first visit)"
echo ""
echo "  Ollama API:   http://localhost:${WEB_PORT}/ollama/v1"
echo "  API key:      ${API_KEY}"
echo ""
echo "  Console:      ./vm.sh console [--name ${NAME}]"
echo "  Logs:         ./vm.sh logs    [--name ${NAME}]"
echo "  Status:       ./vm.sh status  [--name ${NAME}]"
echo "  Stop:         ./vm.sh stop    [--name ${NAME}]"
echo "  Clean:        ./vm.sh clean   [--name ${NAME}]  (keeps downloaded base image)"
echo "  Mr. Proper:   ./vm.sh mrproper [--name ${NAME}]"
echo ""
echo "  Pull models:  ./vm.sh console"
echo "                  pull-models.sh"
echo ""

# ── Systemd log forwarding ────────────────────────────────────────────────────
# When running as a systemd service (NOTIFY_SOCKET set by NotifyAccess=all),
# signal readiness and stay alive forwarding VM logs to stdout → journald.
# Interactive invocations (no NOTIFY_SOCKET) exit here; QEMU keeps running.
if [[ -n "${NOTIFY_SOCKET:-}" ]]; then
    systemd-notify --ready 2>/dev/null || true
    SSH_LOG_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -p ${SSH_PORT}"
    [[ -f "${VM_SSH_KEY}" ]] && SSH_LOG_OPTS="${SSH_LOG_OPTS} -i ${VM_SSH_KEY}"
    # exec replaces this shell's process image, so the EXIT trap never fires
    # here — kill the console-log tail pipeline explicitly first, otherwise
    # it's orphaned on every service (re)start.
    kill "${TAIL_PID}" 2>/dev/null || true
    # shellcheck disable=SC2086
    exec ssh ${SSH_LOG_OPTS} "${VM_USER}@127.0.0.1" 'journalctl --user -f --no-pager'
fi
