# SPDX-FileCopyrightText: 2026 Thomas Perrot <thomas.perrot@tupi.fr>
# SPDX-License-Identifier: GPL-3.0-only

# =============================================================================
# Ollama — rootless Podman image
# Multi-arch ready: x86-64 (CPU), ROCm (AMD GPU), ARM64
#
# Build targets (via --target):
#   cpu     → default, x86-64 CPU-only
#   rocm    → AMD GPU via ROCm
#   cuda    → NVIDIA GPU via CUDA (same base image as cpu — Ollama's
#             official image already bundles CUDA runtime libraries;
#             GPU access at runtime comes from the NVIDIA Container
#             Toolkit + CDI, not from anything baked into this image)
#
# Both targets produce the same image layout, only the base differs.
# ARM64 is handled transparently by buildah/podman --platform.
# =============================================================================

# -----------------------------------------------------------------------------
# Stage: cpu — default target for x86-64 CPU-only hosts
# -----------------------------------------------------------------------------
FROM docker.io/ollama/ollama:0.31.2 AS cpu

# Running rootless with --userns=keep-id maps your host UID into the container.
# We pre-create the models directory and hand ownership to UID 1000 (the
# conventional default). If your host UID differs, override with:
#   --build-arg HOST_UID=<your-uid>
ARG HOST_UID=1000
ARG HOST_GID=1000

# Use a distribution-neutral path for models; the Quadlet sets OLLAMA_MODELS
# to the same path so Ollama finds it regardless of the image's default HOME.
RUN mkdir -p /var/lib/ollama/models \
    && chown -R "${HOST_UID}":"${HOST_GID}" /var/lib/ollama

# Bind-mount target inside the container.
# The host path is mounted here at runtime (see the Quadlet file).
VOLUME ["/var/lib/ollama/models"]

ENV OLLAMA_MODELS=/var/lib/ollama/models

# Listen on all interfaces so the container is reachable over LAN / VPN.
ENV OLLAMA_HOST=0.0.0.0:11434

# Sane context window default — override per-model with a Modelfile.
# OpenCode needs at least 16k; bump to 32k if RAM allows.
ENV OLLAMA_CONTEXT_LENGTH=16384

# Keep one model warm between requests (saves reload time).
ENV OLLAMA_KEEP_ALIVE=10m

# Drop to non-root user at runtime.
USER ${HOST_UID}:${HOST_GID}

EXPOSE 11434

# ollama/ollama sets its own ENTRYPOINT/CMD; nothing to override here.

# -----------------------------------------------------------------------------
# Stage: rocm — AMD GPU target (next step)
# Swap the base image; everything else is identical.
# Build with: podman build --target rocm -t ollama-rocm .
# Run with:   add --device /dev/kfd --device /dev/dri and
#             -e HSA_OVERRIDE_GFX_VERSION=<your gfx version>
# -----------------------------------------------------------------------------
FROM docker.io/ollama/ollama:0.31.2-rocm AS rocm

ARG HOST_UID=1000
ARG HOST_GID=1000

RUN mkdir -p /var/lib/ollama/models \
    && chown -R "${HOST_UID}":"${HOST_GID}" /var/lib/ollama

VOLUME ["/var/lib/ollama/models"]

ENV OLLAMA_MODELS=/var/lib/ollama/models
ENV OLLAMA_HOST=0.0.0.0:11434
ENV OLLAMA_CONTEXT_LENGTH=16384
ENV OLLAMA_KEEP_ALIVE=10m

# ROCm: make all GPU devices visible by default
ENV ROCR_VISIBLE_DEVICES=all

USER ${HOST_UID}:${HOST_GID}

EXPOSE 11434

# -----------------------------------------------------------------------------
# Stage: cuda — NVIDIA GPU target
# Same base image as cpu: the official ollama/ollama image already bundles
# CUDA runtime libraries and detects a GPU automatically at runtime. Unlike
# ROCm, no separate upstream image tag is needed — what makes CUDA actually
# work is the NVIDIA Container Toolkit + CDI device request in
# kube/stack-cuda.yml (see ansible/roles/podman for toolkit installation),
# not anything in this stage.
# Build with: podman build --target cuda -t ollama-cuda .
# -----------------------------------------------------------------------------
FROM docker.io/ollama/ollama:0.31.2 AS cuda

ARG HOST_UID=1000
ARG HOST_GID=1000

RUN mkdir -p /var/lib/ollama/models \
    && chown -R "${HOST_UID}":"${HOST_GID}" /var/lib/ollama

VOLUME ["/var/lib/ollama/models"]

ENV OLLAMA_MODELS=/var/lib/ollama/models
ENV OLLAMA_HOST=0.0.0.0:11434
ENV OLLAMA_CONTEXT_LENGTH=16384
ENV OLLAMA_KEEP_ALIVE=10m

USER ${HOST_UID}:${HOST_GID}

EXPOSE 11434
