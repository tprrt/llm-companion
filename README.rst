.. SPDX-FileCopyrightText: 2026 Thomas Perrot <thomas.perrot@tupi.fr>
.. SPDX-License-Identifier: CC-BY-SA-4.0

.. image:: https://circleci.com/gh/tprrt/llm-companion.svg?style=svg
    :alt: Circle badge
    :target: https://app.circleci.com/pipelines/github/tprrt/llm-companion

.. image:: https://sonarcloud.io/api/project_badges/measure?project=tprrt_llm-companion&metric=alert_status
    :alt: Quality Gate Status
    :target: https://sonarcloud.io/dashboard?id=tprrt_llm-companion

llm-companion — Podman Kubernetes Pod stack for Fedora Server
=============================================================

Rootless Ollama server for **Fedora Server 41+** and **Debian 12+**, managed via
a single Kubernetes Pod manifest (``stack.yml``) deployed by Ansible.
Multi-arch ready: x86-64 (CPU + AMD ROCm GPU) and ARM64.

----

Stack architecture
------------------

.. code-block::

   Internet / LAN / VPN
           │
        :8080  ← firewalld / ufw opens only this port
           │
   ┌───────────────────────────────────────┐
   │  llm-companion Pod                     │
   │  (shared network namespace)            │
   │                                        │
   │  ┌──────────────────────────────────┐  │
   │  │  caddy  :8080 (hostPort)         │  │
   │  │  Bearer token auth on            │  │
   │  │  /ollama/api/* /ollama/v1/*      │  │
   │  │  Passes / to Open WebUI          │  │
   │  └────────────┬─────────────────────┘  │
   │               │ localhost              │
   │  ┌────────────▼──────┐  ┌──────────┐  │
   │  │  ollama :11434    │  │open-webui│  │
   │  │  (internal)       │  │  :3000   │  │
   │  └───────────────────┘  └──────────┘  │
   └───────────────────────────────────────┘

- All three containers share the same **network namespace** (single Pod)
- Containers communicate via **localhost**, not DNS names
- **Caddy** is the only container with a port published to the host (``:8080``)
- **Open WebUI** runs on port **3000** internally (not 8080, to avoid conflicting with Caddy)
- **Caddy** enforces a Bearer token on all ``/ollama/api/*`` and ``/ollama/v1/*`` requests

.. warning::

   TLS is **disabled by default** (plain HTTP). Do **not** expose port 8080
   to the public internet without enabling TLS in the Caddyfile — the Open
   WebUI login page and Bearer token would be transmitted in clear text.
   This default configuration is safe only on a LAN or VPN.

----

Deployment roadmap
------------------

.. list-table::
   :header-rows: 1

   * - Phase
     - Host
     - RAM
     - GPU
     - Models available
   * - **Step 0**
     - QEMU/KVM VM (any x86-64 Linux host)
     - ≥ 1 GB
     - —
     - Same as Phase 1 — full stack in an isolated VM
   * - **Step 1**
     - ARM64
     - ≤ 4 GB
     - —
     - Qwen2.5-Coder 1.5B · Qwen3 1.7B · Ministral-3 3B (4 GB only)
   * - **Step 2**
     - x86-64, CPU-only
     - 8 GB
     - —
     - Ministral-3 3B/8B · Qwen3 8B · Qwen2.5-Coder 7B
   * - **Step 3**
     - x86-64, AMD Radeon
     - ≥ 16 GB
     - Radeon (ROCm)
     - \+ Ministral-3 14B · Devstral-Small-2 24B

----

Directory layout
----------------

.. code-block::

   .
   ├── Dockerfile                    # Multi-stage: cpu + rocm targets
   │
   ├── Kubernetes Pod manifest
   │   ├── stack.yml                 # PVCs + ConfigMap + Pod (CPU variant)
   │   └── stack-rocm.yml            # Same, AMD ROCm GPU variant (Phase 2)
   │
   ├── Quadlet unit (Fedora)
   │   └── llm-companion.kube        # Quadlet .kube unit — manages the pod via systemd
   │
   ├── Ansible
   │   ├── site.yml                  # Top-level playbook
   │   ├── group_vars/all.yml        # Stack-wide variables
   │   ├── inventory/
   │   │   └── hosts.yml.example     # Example inventory — copy and fill in
   │   └── roles/
   │       ├── common/               # Dirs, linger, subuid/subgid
   │       ├── firewall/             # firewalld (Fedora) or ufw (Debian)
   │       ├── podman/               # Install Podman, SELinux boolean, build image
   │       └── llm-stack/            # Copy manifest, generate secrets, enable service
   │
   ├── Caddy
   │   └── Caddyfile                 # Reference copy — embedded in stack.yml ConfigMap
   │
   ├── Modelfiles (manual alternatives to pull-models.sh)
   │   ├── Modelfile.ministral-3-8b
   │   ├── Modelfile.ministral-3-14b
   │   ├── Modelfile.qwen3-8b        # Thinking mode disabled for agentic use
   │   ├── Modelfile.qwen2.5-coder
   │   └── Modelfile.devstral-small-2
   │
   └── Scripts
       ├── test-vm.sh                # Phase 0 — spin up a QEMU/KVM test VM
       ├── pull-models.sh            # Hardware-aware model pull + variant creation
       └── generate-api-key.sh       # Create Bearer token for the Caddy proxy

----

Model catalogue
---------------

All models are Apache 2.0 licensed. Sizes are at Q4_K_M quantization.

``pull-models.sh`` auto-detects your architecture, GPU, and available RAM, then
selects the **best fitting model per category** (coding, vision, general, embedding).
Run ``./pull-models.sh --list`` to preview what would be selected on your hardware.

Coding — agentic tool use, multi-file edits
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

.. list-table::
   :header-rows: 1

   * - Variant created
     - Base model
     - Disk
     - Gate
     - Strength
   * - ``devstral-small-2-32k``
     - ``devstral-small-2:24b``
     - ~15 GB
     - GPU ≥ 16 GB VRAM
     - SWE-bench leader; purpose-built agentic coding
   * - ``qwen2.5-coder-14b-32k``
     - ``qwen2.5-coder:14b``
     - ~9 GB
     - GPU ≥ 10 GB VRAM
     - Reliable tool-call format; mid-GPU tier
   * - ``qwen3-8b-16k``
     - ``qwen3:8b``
     - ~5 GB
     - x86_64 CPU, 8 GB RAM
     - Best agentic tool-use at 8 GB; ``/no_think`` baked in
   * - ``qwen2.5-coder-7b-16k``
     - ``qwen2.5-coder:7b``
     - ~4.5 GB
     - x86_64 CPU, 6 GB RAM
     - Most reliable tool-call format; Qwen3 fallback
   * - ``qwen2.5-coder-1.5b-16k``
     - ``qwen2.5-coder:1.5b``
     - ~1 GB
     - any CPU, 2 GB RAM
     - Best code + tool-call at sub-2 GB (ARM64)

Vision — image / schematic input, multilingual
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

.. list-table::
   :header-rows: 1

   * - Variant created
     - Base model
     - Disk
     - Gate
     - Strength
   * - ``ministral-3-14b-16k``
     - ``ministral-3:14b``
     - ~9 GB
     - GPU ≥ 14 GB VRAM
     - High-quality vision + multilingual on GPU
   * - ``ministral-3-8b-16k``
     - ``ministral-3:8b``
     - ~5 GB
     - x86_64 CPU, 8 GB RAM
     - Vision; strong instruction following; multilingual
   * - ``ministral-3-3b-16k``
     - ``ministral-3:3b``
     - ~2 GB
     - any CPU, 4 GB RAM
     - Vision; 40+ languages; fast fallback
   * - ``moondream-1.8b-2k``
     - ``moondream:1.8b``
     - ~1.1 GB
     - any CPU, 2 GB RAM
     - Smallest vision model; image Q&A on constrained devices

General — chat, reasoning, quick one-shot questions
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

.. list-table::
   :header-rows: 1

   * - Variant created
     - Base model
     - Disk
     - Gate
     - Strength
   * - ``ministral-3-14b-16k``
     - ``ministral-3:14b``
     - ~9 GB
     - GPU ≥ 14 GB VRAM
     - High-quality general + vision on GPU
   * - ``qwen3-8b-16k``
     - ``qwen3:8b``
     - ~5 GB
     - x86_64 CPU, 8 GB RAM
     - Best general + agentic tool-use at 8 GB; ``/no_think`` baked in
   * - ``deepseek-r1-7b-16k``
     - ``deepseek-r1:7b``
     - ~5 GB
     - x86_64 CPU, 6 GB RAM
     - Best CPU reasoning; native chain-of-thought
   * - ``ministral-3-8b-16k``
     - ``ministral-3:8b``
     - ~5 GB
     - x86_64 CPU, 8 GB RAM
     - Vision; strong instruction following; multilingual
   * - ``gemma3-4b-8k``
     - ``gemma3:4b``
     - ~3 GB
     - any CPU, 4 GB RAM
     - Strong Google model; any arch; outperforms Qwen3 1.7B
   * - ``ministral-3-3b-16k``
     - ``ministral-3:3b``
     - ~2 GB
     - any CPU, 4 GB RAM
     - Vision; 40+ languages; fast fallback
   * - ``qwen3-1.7b-16k``
     - ``qwen3:1.7b``
     - ~1.1 GB
     - any CPU, 2 GB RAM
     - Best reasoning at sub-2 GB; ``/no_think`` baked in

Embedding — RAG / document search (Open WebUI)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

.. list-table::
   :header-rows: 1

   * - Variant created
     - Base model
     - Disk
     - Gate
     - Strength
   * - ``nomic-embed-text-8k``
     - ``nomic-embed-text``
     - ~274 MB
     - any CPU, 1 GB RAM
     - Open WebUI document upload and semantic search

.. note::

   ``nomic-embed-text`` is not a chat model — it converts text to vectors for
   Open WebUI's RAG feature (document upload + semantic search). It runs silently
   in the background and is pulled on any hardware.

.. note::

   **Qwen3 thinking mode:** ``qwen3`` variants bake in ``/no_think`` via a SYSTEM
   prompt, disabling chain-of-thought blocks for faster, more predictable agentic
   responses. Use the base ``qwen3:8b`` or ``qwen3:1.7b`` tag directly if you want
   thinking mode.

Switch models inside OpenCode at any time with ``/models``.

----

Phase 0 — Test in a QEMU/KVM VM
--------------------------------

Before deploying to real hardware, ``test-vm.sh`` provisions a throwaway Fedora VM
that runs the full stack — same Ansible playbook, same ``stack.yml``, same build
process. Use it to validate the setup end-to-end without touching production.

Host prerequisites
~~~~~~~~~~~~~~~~~~

.. code-block:: bash

   sudo dnf install qemu-kvm qemu-img wget curl genisoimage

Ensure your user can use KVM:

.. code-block:: bash

   sudo usermod -aG kvm $USER && newgrp kvm   # or log out/in

Run the VM
~~~~~~~~~~

.. code-block:: bash

   ./test-vm.sh          # 8 GB RAM · 4 vCPUs · 40 GB disk — all defaults

The script will:

1. Download the Fedora 43 Cloud Base image (~700 MB, cached in ``vm-test/``)
2. Create a qcow2 overlay disk
3. Launch QEMU with the project directory shared read-only via 9p virtfs
4. Run the full setup inside the VM via cloud-init:
   install ``ansible-core`` → run ``ansible-playbook ansible/site.yml`` (local)
5. Reboot the VM so that the ``llm-companion`` service starts via ``loginctl linger``
6. Wait and print connection info when ready

Expect **10–20 minutes** on the first run (``dnf upgrade`` + ``podman pull``).
Watch live progress with:

.. code-block:: bash

   ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -p 2222 fedora@127.0.0.1 'tail -f llm-setup.log'

Connection info
~~~~~~~~~~~~~~~

.. list-table::
   :header-rows: 1

   * - Service
     - URL / command
   * - Open WebUI
     - ``http://localhost:8080``
   * - Ollama API
     - ``http://localhost:8080/ollama/v1``  (Bearer token printed at the end)
   * - SSH
     - ``ssh -p 2222 fedora@127.0.0.1``

Pull models inside the VM
~~~~~~~~~~~~~~~~~~~~~~~~~

SSH into the VM and run the pull script directly:

.. code-block:: bash

   ./test-vm.sh console
   ./llm-companion/pull-models.sh

Tear down
~~~~~~~~~

.. code-block:: bash

   ./test-vm.sh stop     # kill the QEMU process
   ./test-vm.sh reset    # stop + delete overlay disk (keeps Fedora image)

Options
~~~~~~~

.. code-block:: bash

   ./test-vm.sh --ram 12         # 12 GB RAM  (unit: GB, no upper limit)
   ./test-vm.sh --cpus 8         # 8 vCPUs
   ./test-vm.sh --disk 60        # 60 GB overlay disk
   ./test-vm.sh --ssh-port 2222  # host SSH port  (default: 2222)
   ./test-vm.sh --web-port 8080  # host web port  (default: 8080)
   ./test-vm.sh --image /path/to/Fedora-Cloud-Base-Generic.x86_64-43-1.1.qcow2

----

Phase 1 — Setup (x86-64, CPU only, 8 GB)
-----------------------------------------

Step 1 — Clone and configure inventory
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

.. code-block:: bash

   git clone https://github.com/tprrt/llm-companion
   cd llm-companion

   # Copy the example inventory and fill in your server's details:
   cp ansible/inventory/hosts.yml.example ansible/inventory/hosts.yml
   $EDITOR ansible/inventory/hosts.yml

Minimum inventory entry:

.. code-block:: yaml

   all:
     children:
       llm_companion:
         hosts:
           my-server:
             ansible_host: 192.168.1.100
             ansible_user: fedora
             ansible_ssh_private_key_file: ~/.ssh/id_ed25519

Step 2 — Run the Ansible playbook
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

.. code-block:: bash

   ansible-playbook -i ansible/inventory/hosts.yml ansible/site.yml

The playbook handles everything in order:

- **common**: creates required directories, enables ``loginctl linger``, sets up subuid/subgid
- **firewall**: opens port 8080 (firewalld on Fedora, ufw on Debian)
- **podman**: installs Podman + buildah, sets SELinux boolean, builds the Ollama image
- **llm-stack**: copies ``stack.yml``, generates API key and WebUI secret, installs and starts the service

Step 3 — Pull models
~~~~~~~~~~~~~~~~~~~~~

.. code-block:: bash

   ./pull-models.sh               # best model per category (coding, vision, general, embedding)
   ./pull-models.sh --list        # dry run — show what would be pulled
   ./pull-models.sh --all         # pull all models that fit the hardware
   ./pull-models.sh --reserve 4   # reserve 4 GB instead of the default 2 GB

``pull-models.sh`` auto-detects your architecture (x86_64 / aarch64), GPU (AMD ROCm
/ NVIDIA CUDA), and available RAM, then selects the **best fitting model per category**.
Hardware gate is based on total RAM minus a configurable reserve (default: 2 GB).

On an 8 GB x86_64 CPU host (2 GB reserved), selects:
``qwen3-8b-16k`` (coding), ``ministral-3-8b-16k`` (vision), ``qwen3-8b-16k`` (general, shared),
``nomic-embed-text-8k`` (embedding)

Step 4 — Verify the proxy
~~~~~~~~~~~~~~~~~~~~~~~~~~

.. code-block:: bash

   # Read your key
   KEY=$(grep OLLAMA_API_KEY ~/.config/ollama/api-key.env | cut -d= -f2-)

   # Should return model list JSON
   curl -s -H "Authorization: Bearer $KEY" http://localhost:8080/ollama/api/tags | python3 -m json.tool

   # Should return 401
   curl -s http://localhost:8080/ollama/api/tags

   # Open WebUI (no auth at proxy level — Open WebUI has its own login)
   curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/
   # Expected: 200

Step 5 — Configure OpenCode
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

``~/.config/opencode/opencode.json`` on the **client**:

.. code-block:: json

   {
     "$schema": "https://opencode.ai/config.json",
     "model": "ollama/qwen3-8b-16k",
     "provider": {
       "ollama": {
         "npm": "@ai-sdk/openai-compatible",
         "name": "Ollama",
         "options": {
           "baseURL": "http://<server-ip>:8080/ollama/v1",
           "headers": {
             "Authorization": "Bearer sk-ollama-<your-key>"
           }
         },
         "models": {
           "qwen3-8b-16k":         { "name": "Qwen3 8B — agentic (16k)",         "tools": true },
           "qwen2.5-coder-7b-16k": { "name": "Qwen2.5-Coder 7B — reliable (16k)", "tools": true },
           "ministral-3-8b-16k":   { "name": "Ministral-3 8B — vision (16k)",     "tools": true },
           "ministral-3-3b-16k":   { "name": "Ministral-3 3B — fast (16k)",       "tools": true }
         }
       }
     }
   }

Replace ``<server-ip>`` with your LAN IP or Tailscale/WireGuard address.

----

Phase 2 — AMD Radeon GPU host
------------------------------

Additional prerequisites
~~~~~~~~~~~~~~~~~~~~~~~~

.. code-block:: bash

   sudo usermod -aG render,video $USER   # logout/login required after

   sudo dnf install rocm-hip rocm-opencl rocm-smi
   rocm-smi --showproductname
   rocminfo | grep gfx   # note your gfx version

Run the playbook with the ROCm build target
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

.. code-block:: bash

   ansible-playbook -i ansible/inventory/hosts.yml ansible/site.yml \
       -e "ollama_build_target=rocm"

This builds ``localhost/ollama-rocm:latest`` and deploys ``stack-rocm.yml``
(which sets ``ROCR_VISIBLE_DEVICES=all`` and ``securityContext.privileged: true``
for ``/dev/kfd`` + ``/dev/dri`` access) as the active stack manifest.

.. warning::

   ``stack-rocm.yml`` runs the Ollama container in **privileged mode**.
   This is required for AMD GPU access (``/dev/kfd``, ``/dev/dri``) but
   bypasses most kernel namespace isolation — a compromised container
   process can affect the host. Only deploy the ROCm variant on a
   dedicated, trusted host that is not shared with other workloads.

Set ``HSA_OVERRIDE_GFX_VERSION`` in ``stack-rocm.yml`` if your card needs it
(uncomment the env var and set the value to your gfx version string).

Pull GPU models
~~~~~~~~~~~~~~~

.. code-block:: bash

   ./pull-models.sh --all   # bypass RAM check — pull everything

Adds ``ministral-3-14b-16k`` and ``devstral-small-2-32k``.

Add to ``opencode.json`` models block:

.. code-block:: json

   "ministral-3-14b-16k":   { "name": "Ministral-3 14B — vision (16k)",    "tools": true },
   "devstral-small-2-32k":  { "name": "Devstral Small 2 — agentic (32k)",  "tools": true }

Change default: ``"model": "ollama/devstral-small-2-32k"``

----

Phase 3 — ARM64
----------------

No code changes needed — the same Dockerfile ``cpu`` target, ``stack.yml``,
Ansible playbook, and scripts work unchanged on ARM64.

.. code-block:: bash

   # Run the playbook targeting your ARM64 host:
   ansible-playbook -i ansible/inventory/hosts.yml ansible/site.yml

   # Cross-build from x86-64 (if needed):
   sudo dnf install qemu-user-static
   podman build --platform linux/arm64 --target cpu -t ollama-cpu:arm64 .

Then pull models with RAM auto-detection:

.. code-block:: bash

   ./pull-models.sh

On a 2 GB device, ``pull-models.sh`` will pull ``qwen2.5-coder:1.5b`` and
``qwen3:1.7b`` only. On a 4 GB device it will also pull ``ministral-3:3b``.
The 6 GB+ models from Phase 1 are automatically skipped.

----

Updating the stack
------------------

.. code-block:: bash

   # Re-run the playbook to pick up any changes (idempotent):
   ansible-playbook -i ansible/inventory/hosts.yml ansible/site.yml

   # Pull latest Caddy and Open WebUI images and replace the pod:
   podman pull docker.io/library/caddy:latest
   podman pull ghcr.io/open-webui/open-webui:latest
   systemctl --user restart llm-companion

``AutoUpdate=registry`` in ``llm-companion.kube`` also enables automatic updates via:

.. code-block:: bash

   podman auto-update   # manual trigger
   # Or install the systemd timer:
   systemctl --user enable --now podman-auto-update.timer

----

Rotating the API key
--------------------

.. code-block:: bash

   ./generate-api-key.sh            # generates a new key, overwrites api-key.env
   # Then re-run Ansible to update the Secret and restart the pod:
   ansible-playbook -i ansible/inventory/hosts.yml ansible/site.yml
   # Update opencode.json on all client machines

----

Useful commands
---------------

.. code-block:: bash

   # Service status
   systemctl --user status llm-companion

   # Logs
   journalctl --user -u llm-companion -f

   # Restart the pod (all containers)
   systemctl --user restart llm-companion

   # List installed models
   podman exec llm-companion-ollama ollama list

   # Pull a model manually
   podman exec -it llm-companion-ollama ollama pull ministral-3:8b

   # Reload Caddy config without restart (after updating stack.yml ConfigMap)
   podman exec llm-companion-caddy caddy reload --config /etc/caddy/Caddyfile

   # Test auth
   KEY=$(grep OLLAMA_API_KEY ~/.config/ollama/api-key.env | cut -d= -f2-)
   curl -s -H "Authorization: Bearer $KEY" http://localhost:8080/ollama/api/tags

   # SELinux denials
   sudo ausearch -m avc -ts recent | tail -30

   # Check running pod and containers
   podman pod ps
   podman ps --pod

----

Troubleshooting
---------------

**Caddy fails to start — secrets not found**

The ``llm-companion-secrets`` Kubernetes Secret must exist before the pod starts.
Re-run the Ansible playbook — it generates and applies the secret automatically:

.. code-block:: bash

   ansible-playbook -i ansible/inventory/hosts.yml ansible/site.yml

**Ollama API returns 401 from OpenCode**

Check that the ``Authorization`` header in ``opencode.json`` matches the key in
``~/.config/ollama/api-key.env``. Keys are case-sensitive.

**Open WebUI can't reach Ollama ("Connection refused")**

All containers share the pod network namespace — Ollama must be listening on
``0.0.0.0:11434`` within the pod. Check the Ollama container logs:

.. code-block:: bash

   podman logs llm-companion-ollama

If Ollama has not yet started, wait and retry. If it crashed, check:

.. code-block:: bash

   journalctl --user -u llm-companion -n 100

**Pulling models inside the VM**

SSH into the VM and run the pull script directly:

.. code-block:: bash

   ./test-vm.sh console
   ./llm-companion/pull-models.sh

**``systemctl --user`` fails over SSH ("Failed to connect to bus")**

.. code-block:: bash

   export XDG_RUNTIME_DIR=/run/user/$(id -u)
   systemctl --user status llm-companion

**Port 8080 unreachable from LAN**

.. code-block:: bash

   sudo firewall-cmd --list-ports        # should show 8080/tcp
   curl http://localhost:8080/           # verify Caddy responds

**Models lost after service restart on Debian 12**

This is a known limitation of Podman 4.3.x (shipped with Debian 12). The
``llm-companion`` systemd service must prune unused volumes before each start
to work around a bug where ``podman play kube`` fails with "volume already
exists" if volumes from a previous run are still present. As a result,
named volumes (``ollama-models``, ``open-webui-data``) are pruned on every
restart and any pulled models must be re-downloaded.

To retain models across restarts, upgrade to Podman 5.x (available via the
`official Podman PPA <https://github.com/containers/podman/blob/main/install.md>`_
or by upgrading to Debian 13+).

**Qwen3 8B produces** ``<think>…</think>`` **blocks inside OpenCode**

You are using the base ``qwen3:8b`` tag instead of ``qwen3-8b-16k``.
Check the ``"model"`` field in ``opencode.json``.
