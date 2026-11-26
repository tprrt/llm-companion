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
a single Kubernetes Pod manifest (rendered from ``kube/stack.yml.j2``) deployed by Ansible.
Multi-arch ready: x86-64 (CPU, AMD ROCm or NVIDIA CUDA GPU) and ARM64.

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
- **SearXNG** runs on port **8888** internally — used by Open WebUI for web search; also reachable externally at ``:8080/searxng/`` via Caddy, with its own Bearer token (``~/.config/ollama/searxng-api-key.env``)
- **Open Terminal** runs on port **8000** internally — gives Open WebUI agents a sandboxed shell, never exposed outside the pod
- **Caddy** enforces a Bearer token on ``/ollama/api/*``, ``/ollama/v1/*``, and ``/searxng/*``

.. warning::

   TLS is **disabled by default** (plain HTTP): the Open WebUI login and the
   Bearer token cross the network in clear text. Set ``llm_tls_hostnames``
   (see `Enable HTTPS`_) on any network you do not fully trust, and never
   expose port 8080 to the public internet.

----

Directory layout
----------------

.. code-block::

   .
   ├── Dockerfile                    # Multi-stage: cpu, rocm and cuda targets
   │
   ├── kube/                         # Kubernetes Pod manifests and Quadlet unit
   │   ├── stack.yml.j2              # PVCs + ConfigMap + Pod; rendered per cpu / rocm / cuda
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
   │   └── Caddyfile                 # The Caddy config, embedded in the rendered manifest
   │
   ├── modelfiles/                   # Manual alternatives to scripts/pull-models.sh
   │   ├── Modelfile.flint-40b
   │   ├── Modelfile.qwen3.8-27b
   │   ├── Modelfile.laguna-xs-2.1
   │   ├── Modelfile.gemma4-26b
   │   ├── Modelfile.gemma4-12b
   │   └── Modelfile.mimo-v2.6-9b
   │
   └── scripts/
       ├── vm.sh                     # Manage QEMU/KVM VMs (local or remote)
       ├── setup-host.sh             # Detect hardware, run the playbook, start the service
       ├── detect-hardware.sh        # Print the accelerator and ollama_build_target
       ├── pull-models.sh            # Hardware-aware model pull + variant creation
       ├── generate-api-key.sh       # Create Bearer token for the Caddy proxy
       ├── check-services.sh         # Health checks for the stack
       └── functional-tests.sh       # On-demand behavioral checks (real inference, search, auth)

----

Model catalogue
---------------

Sizes are actual on-disk weight sizes (Q4_K_M unless the tag says
otherwise). CPU gates are the resident
memory measured with Ollama 0.40.18 at each variant's context length (weights
plus KV cache), rounded up; speeds are prompt / generation tokens per second
on a Zen 5 laptop CPU (Ryzen AI 7 350, 8 cores) for a ~1.8K-token code prompt.

To re-measure on your own hardware, e.g. after an Ollama upgrade, run
``scripts/bench-models.py`` against a pulled model; ``--help`` lists the
options.

Licenses differ per model: check each model's page on ollama.com before
commercial use. MiMo-V2.6 is MIT, Flint is Apache 2.0, Laguna XS 2.1 is
OpenMDW-1.1 and LFM3 uses the LFM Open License v1.0. GPU models are not
benchmarked here; their gates are estimates from weight sizes, and their
quality figures come from the publishers.

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
   * - ``flint-40b-32k``
     - ``flint:40b``
     - ~23 GB
     - GPU ≥ 32 GB VRAM
     - MoE 40B/2.5B-active; agentic coding; SWE-bench Verified 74.2 (publisher)
   * - ``qwen3.8-27b-32k``
     - ``qwen3.8:27b``
     - ~18 GB
     - GPU ≥ 24 GB VRAM
     - Newest Qwen; agentic coding + vision + thinking in a single model
   * - ``laguna-xs-2.1-32k``
     - ``laguna-xs-2.1``
     - ~20 GB
     - NVIDIA CUDA ≥ 24 GB VRAM
     - MoE 33B/3B-active; agentic coding; faster than the dense 27B
   * - ``mimo-v2.6-9b-q8_0-32k``
     - ``mimo-v2.6:9b-q8_0``
     - ~10 GB
     - GPU ≥ 12 GB VRAM
     - MiMo-V2.6 9B at Q8; tools + vision; mid-GPU tier
   * - ``mimo-v2.6-9b-16k``
     - ``mimo-v2.6:9b``
     - ~6.6 GB
     - any CPU, 8 GB RAM
     - Code + agent fine-tune of Qwen3.5-9B; tools + vision; 71 / 6.7 tok/s
   * - ``qwen3.5-4b-16k``
     - ``qwen3.5:4b``
     - ~3.3 GB
     - any CPU, 5 GB RAM
     - Tools + vision; 121 / 11.8 tok/s
   * - ``qwen3.5-0.8b-4k``
     - ``qwen3.5:0.8b``
     - ~1.3 GB
     - any CPU, 2 GB RAM
     - Tools + vision on constrained devices; 484 / 31.7 tok/s

Vision — image / schematic input, multilingual
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

.. list-table::
   :header-rows: 1

   * - Variant created
     - Base model
     - Disk
     - Gate
     - Strength
   * - ``qwen3.8-27b-32k``
     - ``qwen3.8:27b``
     - ~18 GB
     - GPU ≥ 24 GB VRAM
     - Vision alongside coding and general use; one pull covers all three
   * - ``gemma4-26b-16k``
     - ``gemma4:26b``
     - ~18 GB
     - GPU ≥ 20 GB VRAM
     - MoE 25B/3.8B-active; alternative to Qwen3.8 27B, fewer active parameters
   * - ``gemma4-12b-16k``
     - ``gemma4:12b``
     - ~7.7 GB
     - GPU ≥ 12 GB VRAM
     - Native multimodal; mid-GPU tier
   * - ``gemma4-e4b-8k``
     - ``gemma4:e4b``
     - ~6.6 GB
     - any CPU, 8 GB RAM
     - Native multimodal; fastest 8 GB pick; 201 / 16.5 tok/s
   * - ``ministral-3-3b-16k``
     - ``ministral-3:3b``
     - ~3 GB
     - any CPU, 5 GB RAM
     - Vision; 40+ languages; 182 / 14.3 tok/s
   * - ``qwen3.5-0.8b-4k``
     - ``qwen3.5:0.8b``
     - ~1.3 GB
     - any CPU, 2 GB RAM
     - Smallest vision model with tools; 484 / 31.7 tok/s

General — chat, reasoning, quick one-shot questions
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

.. list-table::
   :header-rows: 1

   * - Variant created
     - Base model
     - Disk
     - Gate
     - Strength
   * - ``qwen3.8-27b-32k``
     - ``qwen3.8:27b``
     - ~18 GB
     - GPU ≥ 24 GB VRAM
     - Thinking model; best general pick at the 24 GB tier
   * - ``gemma4-26b-16k``
     - ``gemma4:26b``
     - ~18 GB
     - GPU ≥ 20 GB VRAM
     - MoE 25B/3.8B-active; alternative to Qwen3.8 27B, fewer active parameters (``--all``)
   * - ``gemma4-12b-16k``
     - ``gemma4:12b``
     - ~7.7 GB
     - GPU ≥ 12 GB VRAM
     - General + vision on mid-range GPUs
   * - ``gemma4-e4b-8k``
     - ``gemma4:e4b``
     - ~6.6 GB
     - any CPU, 8 GB RAM
     - Native multimodal; fastest 8 GB pick; 201 / 16.5 tok/s
   * - ``ministral-3-3b-16k``
     - ``ministral-3:3b``
     - ~3 GB
     - any CPU, 5 GB RAM
     - Vision; 40+ languages; 182 / 14.3 tok/s
   * - ``lfm3-1.7b-4k``
     - ``lfm3:1.7b``
     - ~1.1 GB
     - any CPU, 2 GB RAM
     - Hybrid model for local agents; 256K native context; 318 / 30.5 tok/s

Embedding — RAG / document search (Open WebUI)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

.. list-table::
   :header-rows: 1

   * - Variant created
     - Base model
     - Disk
     - Gate
     - Strength
   * - ``embeddinggemma-300m-2k``
     - ``embeddinggemma:300m``
     - ~620 MB
     - any CPU, 1 GB RAM
     - Open WebUI document upload and semantic search; 3,040 tok/s

.. note::

   ``embeddinggemma:300m`` is not a chat model — it converts text to vectors
   for Open WebUI's RAG feature (document upload + semantic search). It is
   pulled on any hardware and set as ``RAG_EMBEDDING_MODEL`` in the stack
   manifests. Its 2K context fits Open
   WebUI's default ~1,000-character chunks. Changing the embedding model
   means re-indexing documents already in Open WebUI.

.. note::

   **Task model:** ``qwen3.5-0.8b-4k`` (``qwen3.5:0.8b``) is always created, on
   every hardware tier, regardless of which model wins the categories above.
   Open WebUI uses it as ``TASK_MODEL`` for background jobs (chat titles, tags,
   web search queries) so those requests don't evict the main chat model from
   memory, with thinking disabled through ``TASK_MODEL_PARAMS``. Each task
   takes about 2 s on the CPU above.

.. note::

   **Tool calls:** every CPU model above returns real tool calls. The
   Qwen2.5-Coder models previously listed wrote them as plain JSON text, which
   Ollama does not turn into ``tool_calls``, so OpenCode and other agents
   never saw them.

.. note::

   **Gemma 4 "effective" parameters:** ``gemma4:e4b``'s "4B" refers to
   *effective* (active) parameters, not on-disk weight size — the actual
   Q4_K_M download is 6.6 GB, larger than some models with bigger parameter
   counts in their name. Its hardware gate (8 GB RAM) reflects the measured
   memory use.

.. note::

   **Thinking:** the Qwen3.5, MiMo and LFM3 models think by default, and on
   Ollama 0.40.x they ignore a ``/no_think`` system prompt. On a CPU host this
   can take longer than the answer itself. Disable it per request: Ollama's
   ``"think": false``, or ``"reasoning_effort": "none"`` on the
   OpenAI-compatible ``/ollama/v1`` endpoint. On CPU hosts, Open WebUI chats
   default to no thinking (``llm_chat_thinking``, on by default with a GPU);
   the per-chat toggle and per-model settings override it.

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
     - Best tool-use + coding; cloud equivalent of Qwen3.8 27B
   * - Anthropic
     - ``anthropic/claude-haiku-4-5``
     - Fast and cheap; good for quick Q&A and light tasks
   * - GitHub Copilot
     - ``github/gpt-4o``
     - Strong general + coding; available on most Copilot plans
   * - GitHub Copilot
     - ``github/o3-mini``
     - Reasoning-focused; for harder reasoning than the CPU models handle

See the `Configure OpenCode`_ section for the provider configuration.

----

Setup
-----

Deploy in a QEMU/KVM VM
~~~~~~~~~~~~~~~~~~~~~~~

``vm.sh`` provisions a QEMU/KVM VM that runs the full stack — same Ansible playbook,
same ``kube/stack.yml.j2``, same build process. Use it for local testing or to deploy the
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
- **firewall**: opens port 8080 (firewalld on Fedora, ufw on Debian), to
  every source or only to ``llm_allowed_networks``
- **podman**: installs Podman + buildah, sets SELinux boolean, builds the Ollama image
- **llm_stack**: renders ``kube/stack.yml.j2`` for the host's GPU, generates API key and secrets, installs and enables the service

To accept connections only from your LAN or VPN, list the networks in
``ansible/group_vars/all.yml`` or in the host's inventory entry:

.. code-block:: yaml

   llm_allowed_networks: ["192.168.1.0/24", "100.64.0.0/10"]

Networks removed from the list later have their rules removed on the next
playbook run; an empty list opens the port to every source again.

Enable HTTPS
^^^^^^^^^^^^

List the names and addresses clients use to reach the host:

.. code-block:: yaml

   llm_tls_hostnames: ["llm.lan", "192.168.1.100"]

Caddy then serves HTTPS on port 8080 with certificates from its own local CA,
kept in the ``llm-caddy-data`` volume; plain HTTP requests on that port get
an HTTP 400 reply.
Clients connecting through any other name get a TLS error. Export the CA
certificate once the service is up, and make each client trust it:

.. code-block:: bash

   podman cp llm-companion-caddy:/data/caddy/pki/authorities/local/root.crt llm-companion-ca.crt

   # Fedora client
   sudo cp llm-companion-ca.crt /etc/pki/ca-trust/source/anchors/ && sudo update-ca-trust
   # Debian client
   sudo cp llm-companion-ca.crt /usr/local/share/ca-certificates/ && sudo update-ca-certificates
   # OpenCode (Node.js does not read the system store)
   export NODE_EXTRA_CA_CERTS=/path/to/llm-companion-ca.crt

Browsers may need the certificate imported into their own store. Then use
``https://`` URLs, e.g. ``"baseURL": "https://llm.lan:8080/ollama/v1"`` in
``opencode.json``. ``check-services.sh`` and ``functional-tests.sh`` detect
HTTPS on their own.

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
To override detection, e.g. to pick CPU models on a GPU host or preview
another machine, set ``LLM_ACCEL`` (cpu, rocm, cuda), ``LLM_VRAM_GB`` and
``LLM_RAM_GB``: ``LLM_ACCEL=cuda LLM_VRAM_GB=24 ./scripts/pull-models.sh --list``.

On an 8 GB CPU host (2 GB reserved, 6 GB effective), selects:
``qwen3.5-4b-16k`` (coding), ``ministral-3-3b-16k`` (vision and general),
``qwen3.5-0.8b-4k`` (task model, always pulled) and ``embeddinggemma-300m-2k``
(embedding). From 10 GB of RAM (8 GB effective), ``mimo-v2.6-9b-16k`` takes
coding and ``gemma4-e4b-8k`` takes vision and general.

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

   # SearXNG (its own Bearer token)
   SKEY=$(grep SEARXNG_API_KEY ~/.config/ollama/searxng-api-key.env | cut -d= -f2-)
   curl -s -H "Authorization: Bearer $SKEY" \
       'http://localhost:8080/searxng/search?q=test&format=json' | python3 -m json.tool

Functional tests
^^^^^^^^^^^^^^^^

The commands above are a useful one-off manual check. For a repeatable,
scriptable version — real inference through Ollama, a real SearXNG search,
Caddy auth enforcement, and Open WebUI's connectivity to Ollama — run:

.. code-block:: bash

   ./scripts/functional-tests.sh                         # on the deployed host
   ssh myhost 'bash -s' < scripts/functional-tests.sh    # bare-metal host, no repo checked out
   ./scripts/vm.sh functional-check                      # against a running VM

Requires a pulled model (``./scripts/pull-models.sh``) and the same
``OLLAMA_API_KEY`` as ``check-services.sh``. Not installed by Ansible and not
run in CI — it needs a live deployment with pulled models and network
access, so it is meant to be run on demand, not as routine monitoring.

Configure OpenCode
^^^^^^^^^^^^^^^^^^

``~/.config/opencode/opencode.json`` on the **client**:

.. code-block:: json

   {
     "$schema": "https://opencode.ai/config.json",
     "model": "ollama/mimo-v2.6-9b-16k",
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
           "mimo-v2.6-9b-16k": { "name": "MiMo-V2.6 9B — coding (16k)",       "tools": true },
           "qwen3.5-4b-16k":   { "name": "Qwen3.5 4B — coding (16k)",         "tools": true },
           "gemma4-e4b-8k":    { "name": "Gemma 4 4B — vision/general (8k)",  "tools": true }
         }
       }
     }
   }

Replace ``<server-ip>`` with your LAN IP or Tailscale/WireGuard address, and
``http`` with ``https`` if you enabled HTTPS.

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

This builds ``localhost/ollama-rocm:latest`` and deploys the ROCm variant of
the stack manifest, which sets ``ROCR_VISIBLE_DEVICES=all`` and
``securityContext.privileged: true`` for ``/dev/kfd`` + ``/dev/dri`` access.

.. warning::

   The ROCm variant runs the Ollama container in **privileged mode**.
   This is required for AMD GPU access (``/dev/kfd``, ``/dev/dri``) but
   bypasses most kernel namespace isolation — a compromised container
   process can affect the host. Only deploy the ROCm variant on a
   dedicated, trusted host that is not shared with other workloads.

If your card needs ``HSA_OVERRIDE_GFX_VERSION``, set
``ollama_hsa_override_gfx_version`` (e.g. ``"11.0.0"``) in
``ansible/group_vars/all.yml`` or the host's inventory entry, then re-run the
playbook.

Pull GPU models
^^^^^^^^^^^^^^^

.. code-block:: bash

   ./scripts/pull-models.sh         # best fitting model per category
   ./scripts/pull-models.sh --all   # every model that fits the VRAM

Models available by VRAM: from 12 GB ``mimo-v2.6-9b-q8_0-32k`` (coding) and
``gemma4-12b-16k`` (vision/general); from 20 GB ``gemma4-26b-16k``; from
24 GB ``qwen3.8-27b-32k``; from 32 GB ``flint-40b-32k`` (coding). The default
run pulls the best of these per category; ``--all`` pulls every one that fits.

Add the ones you pulled to the ``opencode.json`` models block:

.. code-block:: json

   "mimo-v2.6-9b-q8_0-32k": { "name": "MiMo-V2.6 9B Q8 — coding (32k)",       "tools": true },
   "gemma4-12b-16k":        { "name": "Gemma 4 12B — vision/general (16k)",   "tools": true },
   "gemma4-26b-16k":        { "name": "Gemma 4 26B — vision/general (16k)",   "tools": true },
   "qwen3.8-27b-32k":       { "name": "Qwen3.8 27B — agentic (32k)",          "tools": true },
   "flint-40b-32k":         { "name": "Flint 40B — agentic coding (32k)",     "tools": true }

Change default to the best coding model pulled, e.g.
``"model": "ollama/qwen3.8-27b-32k"``.

NVIDIA GPU (x86-64)
~~~~~~~~~~~~~~~~~~~

Additional prerequisites
^^^^^^^^^^^^^^^^^^^^^^^^

.. code-block:: bash

   nvidia-smi   # confirm the driver is installed and the GPU is visible

The NVIDIA Container Toolkit and its generated CDI spec are installed
automatically by the Ansible ``podman`` role when ``ollama_build_target:
cuda`` — no manual toolkit setup needed, only the driver itself.

Run the Ansible playbook
^^^^^^^^^^^^^^^^^^^^^^^^

.. code-block:: bash

   ansible-playbook -i ansible/inventory/hosts.yml ansible/site.yml \
       -e "ollama_build_target=cuda"

Or let ``scripts/setup-host.sh`` detect it automatically (see "Setup" above).

This builds ``localhost/ollama-cuda:latest``, installs the NVIDIA Container
Toolkit, generates a CDI spec, and deploys the CUDA variant of the stack
manifest, which requests the GPU via
``resources.limits."nvidia.com/gpu=all": 1``.

Unlike the ROCm variant, this does **not** run the container in privileged
mode — CDI grants access to only the GPU device, not the whole host.

Pull GPU models
^^^^^^^^^^^^^^^

.. code-block:: bash

   ./scripts/pull-models.sh         # best fitting model per category
   ./scripts/pull-models.sh --all   # every model that fits the VRAM

Same GPU tiers as the ROCm path (see that section for the ``opencode.json``
entries), plus ``laguna-xs-2.1-32k`` (coding, CUDA only) from 24 GB.

ARM64
~~~~~

No code changes needed — the same Dockerfile ``cpu`` target, ``kube/stack.yml.j2``,
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

On a 4 GB device (2 GB effective after the default 2 GB reserve),
``pull-models.sh`` pulls ``qwen3.5:0.8b`` (coding, vision and task model),
``lfm3:1.7b`` (general) and ``embeddinggemma:300m``; ``ministral-3:3b`` needs 5 GB
effective.
Models above the hardware gate are automatically skipped.

----

Updating the stack
------------------

.. code-block:: bash

   # Re-run the playbook to pick up any changes (idempotent):
   ansible-playbook -i ansible/inventory/hosts.yml ansible/site.yml

When the run changes the stack manifest, the secrets, the Quadlet unit or the
Ollama image, the playbook stops a running service, exports the Open WebUI
data volume (users, chats, settings) to ``~/llm-companion-backups/``, and
starts the service again; it keeps the newest ``llm_backup_keep`` (3)
archives. To restore one:

.. code-block:: bash

   systemctl --user stop llm-companion
   podman volume import llm-open-webui-data ~/llm-companion-backups/llm-open-webui-data-<timestamp>.tar
   systemctl --user start llm-companion

Image versions are pinned in ``kube/stack.yml.j2``. Podman pulls missing
images when the pod starts; pulling them before the playbook run keeps that
start within the unit's 300 s start timeout:

.. code-block:: bash

   podman pull docker.io/library/caddy:2.11.9
   podman pull ghcr.io/open-webui/open-webui:v0.13.5
   podman pull ghcr.io/open-webui/open-terminal:0.18.6-slim
   podman pull docker.io/searxng/searxng:2026.10.7-6671d89be

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

The SearXNG key (``~/.config/ollama/searxng-api-key.env``) and the other
secrets in ``~/.config/ollama/`` are regenerated by deleting the file and
re-running the playbook.

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
   podman exec -it llm-companion-ollama ollama pull qwen3.5:4b

   # Apply a Caddyfile change: edit caddy/Caddyfile, re-run the playbook, then
   # restart (the ConfigMap is read when the pod is created)
   systemctl --user restart llm-companion

   # Check SearXNG logs
   podman logs llm-companion-searxng

   # Test SearXNG directly (from inside the pod network)
   podman exec llm-companion-searxng wget -qO- 'http://localhost:8888/search?q=test&format=json' | head -c 200

   # Test SearXNG via Caddy proxy (SearXNG Bearer token required)
   SKEY=$(grep SEARXNG_API_KEY ~/.config/ollama/searxng-api-key.env | cut -d= -f2-)
   curl -s -H "Authorization: Bearer $SKEY" \
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
the ``searxng-settings.yml`` key of the ConfigMap in ``kube/stack.yml.j2``.

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

   sudo firewall-cmd --list-ports        # should show 8080/tcp, unless restricted
   sudo firewall-cmd --list-rich-rules   # one rule per llm_allowed_networks entry
   curl http://localhost:8080/           # verify Caddy responds

If ``llm_allowed_networks`` is set, the client's address must be in one of
the listed networks.

**Slow replies or long reasoning blocks from Qwen3.5, MiMo or LFM3**

These models think by default. Disable thinking per request (see the
**Thinking** note in the model catalogue).
