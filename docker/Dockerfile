# syntax=docker/dockerfile:1
#
# Tooling image: Foundry (forge, cast, anvil) plus Node.js, Slither and Aderyn.
# Every tool version is pinned here; this file is the single source of truth.

ARG FOUNDRY_IMAGE=ghcr.io/foundry-rs/foundry:v1.8.5@sha256:32c8ea9ef052a440cb1620175987a3f49eff8b068a0c6a3d09ebf7f5f9a0e043
FROM ${FOUNDRY_IMAGE}

ARG TARGETARCH
ARG NODE_VERSION=24.21.0
ARG NODE_SHA256_ARM64=6ad1325edbdb5649c379b75a237147a666c95d4f9ae8d340fef2d1575d289ad2
ARG NODE_SHA256_AMD64=fd8e59d5a511510f6a298afb548f18c7d2b1be404d8b4a27d94fbe49f56cb2d6
ARG SLITHER_VERSION=0.11.6
ARG ADERYN_VERSION=0.6.8

USER root

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl xz-utils python3 python3-venv make \
 && rm -rf /var/lib/apt/lists/*

# Node.js: upgrade-safety checks (OpenZeppelin) and Aderyn run on it.
RUN set -eux; \
    case "${TARGETARCH}" in \
      arm64) node_arch=arm64; node_sha256="${NODE_SHA256_ARM64}" ;; \
      amd64) node_arch=x64;   node_sha256="${NODE_SHA256_AMD64}" ;; \
      *) echo "unsupported architecture: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    archive="node-v${NODE_VERSION}-linux-${node_arch}.tar.xz"; \
    curl -fsSLO "https://nodejs.org/dist/v${NODE_VERSION}/${archive}"; \
    echo "${node_sha256}  ${archive}" | sha256sum -c -; \
    tar -xJf "${archive}" -C /usr/local --strip-components=1; \
    rm "${archive}"

RUN python3 -m venv /opt/slither \
 && /opt/slither/bin/pip install --no-cache-dir "slither-analyzer==${SLITHER_VERSION}"

RUN npm install --global --omit=dev "@cyfrin/aderyn@${ADERYN_VERSION}" \
 && npm cache clean --force

# The container may run as the host user (see docker-compose.yml), so the tool
# home and caches must be writable by any uid.
RUN mkdir -p /home/foundry/.svm /home/foundry/.foundry/cache \
 && chmod -R a+rwX /home/foundry

ENV PATH="/opt/slither/bin:${PATH}" \
    HOME=/home/foundry

USER foundry
WORKDIR /workspace
