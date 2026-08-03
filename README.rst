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

Rootless Ollama server for **Fedora Server 41+** and **Debian 13+**, managed via
a single Kubernetes Pod manifest (``kube/stack.yml``) deployed by Ansible.
Multi-arch ready: x86-64 (CPU + AMD ROCm GPU) and ARM64.

----

Stack architecture
------------------

.. code-block::

   Internet / LAN / VPN
           │
        :8080  ← firewalld / ufw opens only this port
           │
   ┌────────────────────────────────────────────────────────┐
   │  llm-companion Pod  (shared network namespace)         │
   │                                                        │
   │  ┌──────────────────────────────────────────────────┐  │
   │  │  caddy  :8080 (hostPort)                         │  │
   │  │  Bearer token auth on /ollama/api/* /ollama/v1/* │  │
   │  │  Passes /searxng/* to SearXNG (Bearer token)     │  │
   │  │  Passes / to Open WebUI                          │  │
   │  └───────────────────┬──────────────────────────────┘  │
   │                      │ localhost                       │
   │  ┌───────────────────▼──┐  ┌───────────────────────┐   │
   │  │  ollama :11434       │  │  open-webui :3000     │   │
   │  │  (internal)          │  └────────┬──────────┬───┘   │
   │  └──────────────────────┘           │          │       │
   │                              ┌──────▼──┐  ┌────▼──────┐│
   │                              │ searxng │  │   open-   ││
   │                              │  :8888  │  │ terminal  ││
   │                              │         │  │  :8000    ││
   │                              └─────────┘  └───────────┘│
   └────────────────────────────────────────────────────────┘

- All five containers share the same **network namespace** (single Pod)
- Containers communicate via **localhost**, not DNS names
- **Caddy** is the only container with a port published to the host (``:8080``)
- **Open WebUI** runs on port **3000** internally (not 8080, to avoid conflicting with Caddy)
- **SearXNG** runs on port **8888** internally — used by Open WebUI for web search; also reachable externally at ``:8080/searxng/`` via Caddy (same Bearer token as the Ollama API)
- **Open Terminal** runs on port **8000** internally — gives Open WebUI agents a sandboxed shell, never exposed outside the pod
- **Caddy** enforces a Bearer token on ``/ollama/api/*``, ``/ollama/v1/*``, and ``/searxng/*``

.. warning::

   TLS is **disabled by default** (plain HTTP). Do **not** expose port 8080
   to the public internet without enabling TLS in the Caddyfile — the Open
   WebUI login page and Bearer token would be transmitted in clear text.
   This default configuration is safe only on a LAN or VPN.

----

Directory layout
----------------

.. code-block::

   .
   ├── Dockerfile                    # Multi-stage: cpu + rocm targets
   │
   ├── kube/                         # Kubernetes Pod manifests and Quadlet unit
   │   ├── stack.yml                 # PVCs + ConfigMap + Pod (CPU variant)
   │   ├── stack-rocm.yml            # Same, AMD ROCm GPU variant
   │   └── llm-companion.kube        # Quadlet .kube unit — manages the pod via systemd
   │
   ├── ansible/                      # Ansible playbook and roles
   │   ├── site.yml                  # Top-level playbook
   │   ├── group_vars/all.yml        # Stack-wide variables
   │   ├── inventory/
   │   │   └── hosts.yml.example     # Example inventory — copy and fill in
   │   └── roles/
   │       ├── common/               # Dirs, linger, subuid/subgid
   │       ├── firewall/             # firewalld (Fedora) or ufw (Debian)
   │       ├── podman/               # Install Podman, SELinux boolean, build image
   │       └── llm_stack/            # Copy manifest, generate secrets, enable service
   │
   ├── caddy/
   │   └── Caddyfile                 # Canonical reference — embedded in kube/stack.yml ConfigMap
   │
   ├── modelfiles/                   # Manual alternatives to scripts/pull-models.sh
   │   ├── Modelfile.ministral-3-8b
   │   ├── Modelfile.ministral-3-14b
   │   ├── Modelfile.qwen3-8b        # Thinking mode disabled for agentic use
   │   ├── Modelfile.qwen2.5-coder
   │   └── Modelfile.devstral-small-2
   │
   └── scripts/
       ├── vm.sh                     # Manage QEMU/KVM VMs (local or remote)
       ├── pull-models.sh            # Hardware-aware model pull + variant creation
       ├── generate-api-key.sh       # Create Bearer token for the Caddy proxy
       └── check-services.sh         # Health checks for the stack

----

Model catalogue
---------------

All models are Apache 2.0 licensed. Sizes are actual Q4_K_M on-disk weight
sizes (not counting KV cache, which scales with context length).

``pull-models.sh`` auto-detects your architecture, GPU, and available RAM, then
selects the **best fitting model per category** (coding, vision, general, embedding).
Run ``./scripts/pull-models.sh --list`` to preview what would be selected on your hardware.

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
     - GPU ≥ 20 GB VRAM
     - SWE-bench leader; purpose-built agentic coding
   * - ``qwen3-coder-30b-32k``
     - ``qwen3-coder:30b``
     - ~19 GB
     - NVIDIA CUDA ≥ 24 GB VRAM
     - MoE 30B/3B-active; replaces Qwen2.5-Coder 32B; faster at equal VRAM
   * - ``qwen2.5-coder-14b-32k``
     - ``qwen2.5-coder:14b``
     - ~9 GB
     - GPU ≥ 14 GB VRAM
     - Reliable tool-call format; mid-GPU tier
   * - ``qwen2.5-coder-7b-16k``
     - ``qwen2.5-coder:7b``
     - ~4.5 GB
     - x86_64 CPU, 6 GB RAM
     - Most reliable tool-call format; fast default at 6 GB
   * - ``qwen3.5-9b-16k``
     - ``qwen3.5:9b``
     - ~6.6 GB
     - x86_64 CPU, 8 GB RAM
     - Native multimodal, highest quality at 8 GB, but slow in Ollama today (see note)
   * - ``qwen2.5-coder-1.5b-4k``
     - ``qwen2.5-coder:1.5b``
     - ~1.3 GB
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
     - ~9.1 GB
     - GPU ≥ 14 GB VRAM
     - High-quality vision + multilingual on GPU
   * - ``gemma4-e4b-8k``
     - ``gemma4:e4b``
     - ~9.6 GB
     - any CPU, 12 GB RAM
     - Native multimodal; Gemma 4 edge model; strong reasoning
   * - ``ministral-3-3b-16k``
     - ``ministral-3:3b``
     - ~2 GB
     - any CPU, 4 GB RAM
     - Vision; 40+ languages; fast fallback
   * - ``qwen3.5-9b-16k``
     - ``qwen3.5:9b``
     - ~6.6 GB
     - x86_64 CPU, 8 GB RAM
     - Native multimodal, highest quality, but slow in Ollama today (see note)
   * - ``moondream-1.8b-2k``
     - ``moondream:1.8b``
     - ~1.1 GB
     - any CPU, 2 GB RAM
     - Smallest vision model; image Q&A on constrained devices

General — chat, reasoning, quick one-shot questions
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

.. list-table::
   :header-rows: 1

   * - Variant created
     - Base model
     - Disk
     - Gate
     - Strength
   * - ``deepseek-r1-32b-32k``
     - ``deepseek-r1:32b``
     - ~20 GB
     - NVIDIA CUDA ≥ 24 GB VRAM
     - Top open reasoning; chain-of-thought; 24 GB tier
   * - ``ministral-3-14b-16k``
     - ``ministral-3:14b``
     - ~9.1 GB
     - GPU ≥ 14 GB VRAM
     - High-quality general + vision on GPU
   * - ``deepseek-r1-8b-16k``
     - ``deepseek-r1:8b``
     - ~5 GB
     - x86_64 CPU, 6 GB RAM
     - R1-0528 Qwen3-8B distill; best CPU reasoning
   * - ``gemma4-e4b-8k``
     - ``gemma4:e4b``
     - ~9.6 GB
     - any CPU, 12 GB RAM
     - Native multimodal; Gemma 4 edge model; strong reasoning
   * - ``ministral-3-3b-16k``
     - ``ministral-3:3b``
     - ~2 GB
     - any CPU, 4 GB RAM
     - Vision; 40+ languages; fast fallback
   * - ``qwen3.5-9b-16k``
     - ``qwen3.5:9b``
     - ~6.6 GB
     - x86_64 CPU, 8 GB RAM
     - Native multimodal, highest quality, but slow in Ollama today (see note)
   * - ``qwen3-1.7b-4k``
     - ``qwen3:1.7b``
     - ~1.5 GB
     - any CPU, 2 GB RAM
     - Best reasoning at sub-2 GB; ``/no_think`` baked in; also always pulled
       as the dedicated Open WebUI background-task model (see note)

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

   **Task model:** ``qwen3-1.7b-4k`` is always created, on every hardware tier,
   regardless of which model wins the general category above. Open WebUI uses
   it as ``TASK_MODEL`` for background jobs (chat title generation, web search
   query rewriting) so those requests don't evict the main chat model from
   memory.

.. note::

   **Qwen3.5 9B is slow in Ollama today:** its hybrid Gated-Delta-Network
   (linear attention) layers are not yet well optimized by Ollama's bundled
   llama.cpp — see `ollama/ollama#14579
   <https://github.com/ollama/ollama/issues/14579>`_ and `#14861
   <https://github.com/ollama/ollama/issues/14861>`_, which report 5-6x slower
   generation than llama.cpp directly, on both CPU and GPU. ``pull-models.sh``
   therefore ranks it last in each category (an explicit opt-in via
   ``--all`` or ``ollama pull qwen3.5:9b`` rather than the automatic "best"
   pick) until upstream support matures.

.. note::

   **Gemma 4 "effective" parameters:** ``gemma4:e4b``'s "4B" refers to
   *effective* (active) parameters, not on-disk weight size — the actual
   Q4_K_M download is 9.6 GB, larger than some models with bigger parameter
   counts in their name. Its hardware gate (12 GB RAM) reflects the real size.

.. note::

   **Qwen3 thinking mode:** ``qwen3`` and ``qwen3.5`` variants bake in ``/no_think``
   via a SYSTEM prompt where noted above, disabling chain-of-thought blocks for
   faster, more predictable agentic responses.

Switch models inside OpenCode at any time with ``/models``.

Cloud fallbacks — when the local stack is unavailable
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

When Ollama is unreachable (stack down, travelling, constrained device),
OpenCode can route to a cloud provider instead. Add them alongside the
``ollama`` provider in ``opencode.json`` and switch with ``/models``.

.. list-table::
   :header-rows: 1

   * - Provider
     - Model ID
     - Strength
   * - Anthropic
     - ``anthropic/claude-sonnet-4-6``
     - Best tool-use + coding; direct cloud equivalent of Devstral
   * - Anthropic
     - ``anthropic/claude-haiku-4-5``
     - Fast and cheap; good for quick Q&A and light tasks
   * - GitHub Copilot
     - ``github/gpt-4o``
     - Strong general + coding; available on most Copilot plans
   * - GitHub Copilot
     - ``github/o3-mini``
     - Reasoning-focused; cloud equivalent of DeepSeek-R1

See the `Configure OpenCode`_ section for the provider configuration.

----

Setup
-----

Deploy in a QEMU/KVM VM
~~~~~~~~~~~~~~~~~~~~~~~

``vm.sh`` provisions a QEMU/KVM VM that runs the full stack — same Ansible playbook,
same ``kube/stack.yml``, same build process. Use it for local testing or to deploy the
VM on a remote server.

Host prerequisites
^^^^^^^^^^^^^^^^^^

.. code-block:: bash

   sudo dnf install qemu-kvm qemu-img wget curl genisoimage

Ensure your user can use KVM:

.. code-block:: bash

   sudo usermod -aG kvm $USER && newgrp kvm   # or log out/in

Workflow
^^^^^^^^

``build`` is the one-time provisioning step; ``start``/``stop`` are for day-to-day
operation. Each built VM is identified by a ``--name`` (defaults to the distro name
when omitted) and stores its settings in ``<vm-dir>/<name>.conf``.

.. code-block:: bash

   # First build — name defaults to 'fedora'
   ./scripts/vm.sh build
   # Or with an explicit name (e.g. to run multiple VMs with different resources)
   ./scripts/vm.sh build --distro fedora --name fedora-gpu --ram 32 --cpus 8

   # Subsequent boots (~2 min from the pre-built golden image)
   # --name is auto-detected when only one .conf exists in vm-dir
   ./scripts/vm.sh start
   ./scripts/vm.sh stop

After a code change, rebuild the golden image:

.. code-block:: bash

   ./scripts/vm.sh clean && ./scripts/vm.sh build && ./scripts/vm.sh start

   # Explicit name when multiple VMs exist
   ./scripts/vm.sh clean --name fedora-gpu && \
   ./scripts/vm.sh build --name fedora-gpu --distro fedora --ram 32 --cpus 8 && \
   ./scripts/vm.sh start --name fedora-gpu

Build-only options (``--distro``, ``--ram``, ``--cpus``, ``--disk``, ``--ssh-port``,
``--web-port``, ``--image``) are only valid for ``build``; other subcommands load
those settings from ``<name>.conf``.

Systemd user service
^^^^^^^^^^^^^^^^^^^^

.. code-block:: ini

   [Service]
   Type=notify
   NotifyAccess=all
   ExecStart=/path/to/vm.sh start --name <name>
   ExecStop=/path/to/vm.sh stop  --name <name>

When started as a service, ``vm.sh start`` signals readiness once the VM is up
then stays alive forwarding ``journalctl --user -f`` output from inside the VM
to stdout, which systemd captures to journald. Interactive runs exit after
printing the ready banner (QEMU keeps running in the background).

``build`` writes the unit file (using the same RAM/CPU settings as the build)
but does not activate it. Run ``enable`` once to register the service:

.. code-block:: bash

   ./scripts/vm.sh enable              # auto-detected when only one VM exists
   ./scripts/vm.sh enable --name fedora-gpu
   ./scripts/vm.sh disable --name fedora-gpu   # stop + disable (unit file is kept)

   # Day-to-day (service name matches --name)
   systemctl --user start   llm-companion-vm-fedora-gpu.service
   systemctl --user stop    llm-companion-vm-fedora-gpu.service
   journalctl --user -u     llm-companion-vm-fedora-gpu.service -f

``enable`` activates ``loginctl linger`` so the user's systemd instance —
and this service — start at boot without an active login session.

Connection info
^^^^^^^^^^^^^^^

.. list-table::
   :header-rows: 1

   * - Service
     - URL / command
   * - Open WebUI
     - ``http://localhost:8080``
   * - Ollama API
     - ``http://localhost:8080/ollama/v1``  (Bearer token printed at the end)
   * - SearXNG
     - ``http://localhost:8080/searxng/``
   * - SSH
     - ``ssh -p 2222 fedora@127.0.0.1``

Accessing services from a remote server
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

When the VM runs on a remote server (e.g. reachable only over VPN), open an
SSH local-port-forward so your browser hits the Caddy proxy on port 8080:

.. code-block:: bash

   ssh -N -L 8080:localhost:8080 user@server   # keep terminal open
   # or in the background:
   ssh -fN -L 8080:localhost:8080 user@server

All services are then reachable on your local machine:

.. list-table::
   :header-rows: 1

   * - Service
     - URL
   * - Open WebUI
     - ``http://localhost:8080``
   * - Ollama API
     - ``http://localhost:8080/ollama/v1``
   * - SearXNG
     - ``http://localhost:8080/searxng/``

For convenience, add the forwards to ``~/.ssh/config`` so any ``ssh
llm-server`` session opens the tunnels automatically:

.. code-block:: text

   Host llm-server
       HostName server.example.com
       User     myuser
       LocalForward 8080 localhost:8080
       LocalForward 2222 localhost:2222   # optional: reach the VM console locally

The second ``LocalForward`` lets you run ``./scripts/vm.sh console`` or
``ssh -p 2222 fedora@127.0.0.1`` from your local machine as if the VM were
local.

Pull models inside the VM
^^^^^^^^^^^^^^^^^^^^^^^^^

SSH into the VM and run the pull script directly:

.. code-block:: bash

   ./scripts/vm.sh console
   pull-models.sh

Tear down
^^^^^^^^^

.. code-block:: bash

   ./scripts/vm.sh stop                  # auto-detected when one VM
   ./scripts/vm.sh stop --name fedora-gpu
   ./scripts/vm.sh clean                 # stop + delete overlay/golden (keeps base image)
   ./scripts/vm.sh clean --name fedora-gpu
   ./scripts/vm.sh mrproper              # also delete the downloaded base image

Build options
^^^^^^^^^^^^^

These options are only valid for ``build``. Other subcommands read the values from
``<name>.conf``.

.. code-block:: bash

   ./scripts/vm.sh build --distro fedora        # fedora (default) or debian
   ./scripts/vm.sh build --name fedora-gpu      # VM name (default: distro name)
   ./scripts/vm.sh build --ram 12               # 12 GB RAM  (unit: GB, no upper limit)
   ./scripts/vm.sh build --cpus 8               # 8 vCPUs
   ./scripts/vm.sh build --disk 60              # 60 GB overlay disk
   ./scripts/vm.sh build --ssh-port 2222        # host SSH port  (default: 2222)
   ./scripts/vm.sh build --web-port 8080        # host web port  (default: 8080)
   ./scripts/vm.sh build --image /path/to/Fedora-Cloud-Base-Generic.x86_64-44-1.7.qcow2

Remote server:

.. code-block:: bash

   ./scripts/vm.sh build --host myserver.example.com  # rsync + build on remote host
   ./scripts/vm.sh start --host myserver.example.com  # forward any subcommand

x86-64 (CPU only)
~~~~~~~~~~~~~~~~~~

Clone and configure inventory
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

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

Run the Ansible playbook
^^^^^^^^^^^^^^^^^^^^^^^^

.. code-block:: bash

   ansible-playbook -i ansible/inventory/hosts.yml ansible/site.yml

The playbook handles everything in order:

- **common**: creates required directories, enables ``loginctl linger``, sets up subuid/subgid
- **firewall**: opens port 8080 (firewalld on Fedora, ufw on Debian)
- **podman**: installs Podman + buildah, sets SELinux boolean, builds the Ollama image
- **llm_stack**: copies ``kube/stack.yml``, generates API key and WebUI secret, installs and starts the service

Or use the hardware-aware setup script
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

``scripts/setup-host.sh`` detects the target's CPU/RAM/accelerator (cpu / AMD
ROCm / NVIDIA CUDA), writes the matching ``ollama_build_target`` to
``ansible/inventory/host_vars/<hostname>.yml``, runs the playbook above, and
starts the service — one command instead of three:

.. code-block:: bash

   ./scripts/setup-host.sh my-server   # hostname must match an entry in hosts.yml

For local self-provisioning (no inventory needed):

.. code-block:: bash

   ./scripts/setup-host.sh

Pull models
^^^^^^^^^^^

.. code-block:: bash

   ./scripts/pull-models.sh               # best model per category (coding, vision, general, embedding)
   ./scripts/pull-models.sh --list        # dry run — show what would be pulled
   ./scripts/pull-models.sh --all         # pull all models that fit the hardware
   ./scripts/pull-models.sh --reserve 4   # reserve 4 GB instead of the default 2 GB

``pull-models.sh`` auto-detects your architecture (x86_64 / aarch64), GPU (AMD ROCm
/ NVIDIA CUDA), and available RAM, then selects the **best fitting model per category**.
Hardware gate is based on total RAM minus a configurable reserve (default: 2 GB).

On an 8 GB x86_64 CPU host (2 GB reserved, 6 GB effective), selects:
``qwen2.5-coder-7b-16k`` (coding), ``ministral-3-3b-16k`` (vision),
``deepseek-r1-8b-16k`` (general), ``qwen3-1.7b-4k`` (task model, always pulled),
``nomic-embed-text-8k`` (embedding). ``qwen3.5:9b`` would also fit at this tier
but is ranked last per-category due to its current Ollama slowness (see note
above) — pull it explicitly with ``--all`` or by name if you want it anyway.

Verify the proxy
^^^^^^^^^^^^^^^^

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

   # SearXNG (same Bearer token as Ollama)
   curl -s -H "Authorization: Bearer $KEY" \
       'http://localhost:8080/searxng/search?q=test&format=json' | python3 -m json.tool

Configure OpenCode
^^^^^^^^^^^^^^^^^^

``~/.config/opencode/opencode.json`` on the **client**:

.. code-block:: json

   {
     "$schema": "https://opencode.ai/config.json",
     "model": "ollama/qwen2.5-coder-7b-16k",
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
           "qwen2.5-coder-7b-16k": { "name": "Qwen2.5-Coder 7B — reliable (16k)",        "tools": true },
           "deepseek-r1-8b-16k":   { "name": "DeepSeek-R1 8B — CPU reasoning (16k)",     "tools": false },
           "gemma4-e4b-8k":        { "name": "Gemma 4 4B — vision/general (8k)",          "tools": true },
           "qwen3.5-9b-16k":       { "name": "Qwen3.5 9B — coding/vision/general (16k), slow (see note)", "tools": true }
         }
       }
     }
   }

Replace ``<server-ip>`` with your LAN IP or Tailscale/WireGuard address.

To add cloud fallbacks, extend the ``provider`` block:

.. code-block:: json

   "anthropic": {
     "options": {
       "apiKey": "sk-ant-..."
     },
     "models": {
       "claude-sonnet-4-6": { "name": "Claude Sonnet 4.6 (cloud)", "tools": true },
       "claude-haiku-4-5":  { "name": "Claude Haiku 4.5 (cloud)",  "tools": true }
     }
   },
   "github": {
     "npm": "@ai-sdk/openai-compatible",
     "name": "GitHub Copilot",
     "options": {
       "baseURL": "https://models.inference.ai.azure.com",
       "headers": { "Authorization": "Bearer <github-pat>" }
     },
     "models": {
       "gpt-4o":  { "name": "Copilot GPT-4o (cloud)",  "tools": true },
       "o3-mini": { "name": "Copilot o3-mini (cloud)", "tools": true }
     }
   }

The ``github-pat`` needs the ``models:read`` scope (GitHub → Settings → Developer
settings → Personal access tokens). Switch between local and cloud with ``/model``
inside OpenCode at any time.

AMD Radeon GPU (x86-64)
~~~~~~~~~~~~~~~~~~~~~~~~

Additional prerequisites
^^^^^^^^^^^^^^^^^^^^^^^^

.. code-block:: bash

   sudo usermod -aG render,video $USER   # logout/login required after

   sudo dnf install rocm-hip rocm-opencl rocm-smi
   rocm-smi --showproductname
   rocminfo | grep gfx   # note your gfx version

Run the Ansible playbook
^^^^^^^^^^^^^^^^^^^^^^^^

.. code-block:: bash

   ansible-playbook -i ansible/inventory/hosts.yml ansible/site.yml \
       -e "ollama_build_target=rocm"

This builds ``localhost/ollama-rocm:latest`` and deploys ``kube/stack-rocm.yml``
(which sets ``ROCR_VISIBLE_DEVICES=all`` and ``securityContext.privileged: true``
for ``/dev/kfd`` + ``/dev/dri`` access) as the active stack manifest.

.. warning::

   ``kube/stack-rocm.yml`` runs the Ollama container in **privileged mode**.
   This is required for AMD GPU access (``/dev/kfd``, ``/dev/dri``) but
   bypasses most kernel namespace isolation — a compromised container
   process can affect the host. Only deploy the ROCm variant on a
   dedicated, trusted host that is not shared with other workloads.

Set ``HSA_OVERRIDE_GFX_VERSION`` in ``kube/stack-rocm.yml`` if your card needs it
(uncomment the env var and set the value to your gfx version string).

Pull GPU models
^^^^^^^^^^^^^^^

.. code-block:: bash

   ./scripts/pull-models.sh --all   # bypass RAM check — pull everything

Adds ``ministral-3-14b-16k`` and ``devstral-small-2-32k``.

Add to ``opencode.json`` models block:

.. code-block:: json

   "ministral-3-14b-16k":   { "name": "Ministral-3 14B — vision (16k)",    "tools": true },
   "devstral-small-2-32k":  { "name": "Devstral Small 2 — agentic (32k)",  "tools": true }

Change default: ``"model": "ollama/devstral-small-2-32k"``

ARM64
~~~~~

No code changes needed — the same Dockerfile ``cpu`` target, ``kube/stack.yml``,
Ansible playbook, and scripts work unchanged on ARM64.

.. code-block:: bash

   # Run the playbook targeting your ARM64 host:
   ansible-playbook -i ansible/inventory/hosts.yml ansible/site.yml

   # Cross-build from x86-64 (if needed):
   sudo dnf install qemu-user-static
   podman build --platform linux/arm64 --target cpu -t ollama-cpu:arm64 .

Then pull models with RAM auto-detection:

.. code-block:: bash

   ./scripts/pull-models.sh

On a 2 GB device, ``pull-models.sh`` will pull ``qwen2.5-coder:1.5b`` and
``qwen3:1.7b`` only. On a 4 GB device it will also pull ``ministral-3:3b``.
Models above the hardware gate are automatically skipped.

----

Updating the stack
------------------

.. code-block:: bash

   # Re-run the playbook to pick up any changes (idempotent):
   ansible-playbook -i ansible/inventory/hosts.yml ansible/site.yml

   # Pull pinned images and replace the pod (bump version tags in kube/stack.yml first):
   podman pull docker.io/library/caddy:2.11.4
   podman pull ghcr.io/open-webui/open-webui:v0.10.2
   podman pull docker.io/searxng/searxng:2026.7.7-f69b22c45
   systemctl --user restart llm-companion

``AutoUpdate=registry`` in ``kube/llm-companion.kube`` also enables automatic updates via:

.. code-block:: bash

   podman auto-update   # manual trigger
   # Or install the systemd timer:
   systemctl --user enable --now podman-auto-update.timer

----

Rotating the API key
--------------------

.. code-block:: bash

   ./scripts/generate-api-key.sh            # generates a new key, overwrites api-key.env
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

   # Reload Caddy config without restart (after updating kube/stack.yml ConfigMap)
   podman exec llm-companion-caddy caddy reload --config /etc/caddy/Caddyfile

   # Check SearXNG logs
   podman logs llm-companion-searxng

   # Test SearXNG directly (from inside the pod network)
   podman exec llm-companion-searxng wget -qO- 'http://localhost:8888/search?q=test&format=json' | head -c 200

   # Test SearXNG via Caddy proxy (Bearer token required)
   KEY=$(grep OLLAMA_API_KEY ~/.config/ollama/api-key.env | cut -d= -f2-)
   curl -s -H "Authorization: Bearer $KEY" \
       'http://localhost:8080/searxng/search?q=test&format=json' | head -c 200

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

**Web search returns no results in Open WebUI**

Check that SearXNG is running and responding:

.. code-block:: bash

   podman logs llm-companion-searxng
   podman exec llm-companion-searxng wget -qO- 'http://localhost:8888/search?q=test&format=json' | head -c 200

If SearXNG has not started yet, wait for the readiness probe (10 s initial delay).
If the JSON response is missing, confirm ``formats: [html, json]`` is present in
the ``searxng-settings.yml`` key of the ConfigMap in ``kube/stack.yml``.

----

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

   ./scripts/vm.sh console
   pull-models.sh

**``systemctl --user`` fails over SSH ("Failed to connect to bus")**

.. code-block:: bash

   export XDG_RUNTIME_DIR=/run/user/$(id -u)
   systemctl --user status llm-companion

**Port 8080 unreachable from LAN**

.. code-block:: bash

   sudo firewall-cmd --list-ports        # should show 8080/tcp
   curl http://localhost:8080/           # verify Caddy responds

**Qwen3.5 9B produces** ``<think>…</think>`` **blocks inside OpenCode**

You are using the base ``qwen3.5:9b`` tag instead of ``qwen3.5-9b-16k``.
Check the ``"model"`` field in ``opencode.json``.
