# syntax=docker/dockerfile:1
#
# Tooling image: Foundry (forge, cast, anvil) plus Node.js, Slither and Aderyn.
# Every tool version is pinned in docker/: here, and for Slither and its dependencies (pinned by hash) in slither-requirements.txt.

ARG FOUNDRY_IMAGE=ghcr.io/foundry-rs/foundry:v1.8.5@sha256:32c8ea9ef052a440cb1620175987a3f49eff8b068a0c6a3d09ebf7f5f9a0e043
FROM ${FOUNDRY_IMAGE}

ARG TARGETARCH
ARG NODE_VERSION=24.21.0
ARG NODE_SHA256_ARM64=6ad1325edbdb5649c379b75a237147a666c95d4f9ae8d340fef2d1575d289ad2
ARG NODE_SHA256_AMD64=fd8e59d5a511510f6a298afb548f18c7d2b1be404d8b4a27d94fbe49f56cb2d6
ARG ADERYN_VERSION=0.6.8
ARG ADERYN_SHA256_ARM64=961070bf5ee4ed0f82f67a261c616e1525ec1b036bae60cdaec94d087eb5e405
ARG ADERYN_SHA256_AMD64=ffd6ca658962e211a3ac821c646f69c8e14bf1b1001cbfe091bcd4535a691e46

USER root

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl xz-utils python3 python3-venv make \
 && rm -rf /var/lib/apt/lists/*

# Node.js: the upgrade-safety checks (OpenZeppelin) run on it.
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

# Slither: the version and every dependency are pinned by hash in slither-requirements.txt.
COPY slither-requirements.txt /tmp/slither-requirements.txt
RUN python3 -m venv /opt/slither \
 && /opt/slither/bin/pip install --no-cache-dir --require-hashes --only-binary=:all: --no-deps -r /tmp/slither-requirements.txt \
 && /opt/slither/bin/pip check \
 && rm /tmp/slither-requirements.txt

# Aderyn: the release binary, checked against its pinned hash.
RUN set -eux; \
    case "${TARGETARCH}" in \
      arm64) aderyn_target=aarch64-unknown-linux-gnu; aderyn_sha256="${ADERYN_SHA256_ARM64}" ;; \
      amd64) aderyn_target=x86_64-unknown-linux-gnu;  aderyn_sha256="${ADERYN_SHA256_AMD64}" ;; \
      *) echo "unsupported architecture: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    archive="aderyn-${aderyn_target}.tar.xz"; \
    curl -fsSLO "https://github.com/cyfrin/aderyn/releases/download/aderyn-v${ADERYN_VERSION}/${archive}"; \
    echo "${aderyn_sha256}  ${archive}" | sha256sum -c -; \
    tar -xJf "${archive}" -C /usr/local/bin --strip-components=1 "aderyn-${aderyn_target}/aderyn"; \
    rm "${archive}"

# The container may run as the host user (see docker-compose.yml), so the tool
# home and caches must be writable by any uid.
RUN mkdir -p /home/foundry/.svm /home/foundry/.foundry/cache \
 && chmod -R a+rwX /home/foundry

ENV PATH="/opt/slither/bin:${PATH}" \
    HOME=/home/foundry

USER foundry
WORKDIR /workspace
