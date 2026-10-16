#!/usr/bin/env bash
# Run Bosun's CI steps in an Ubuntu 24.04 container (tmux 3.4 from apt, the
# same tmux GitHub's ubuntu-latest runners install).
#
#   scripts/ci-linux.sh                 # fmt + clippy + unit tests + tmux-it
#   scripts/ci-linux.sh tmux-it         # only the tmux-it run
#   scripts/ci-linux.sh shell           # interactive shell in the container
#   scripts/ci-linux.sh -- <cmd...>     # any command, run in the copied tree
#
# The repo is mounted read-only and its tracked (plus untracked, not ignored)
# files are copied into the container, so uncommitted changes are tested and
# nothing is written back. The cargo target dir and registry live in named
# volumes, so reruns only rebuild what changed. Runs with 2 CPUs, like a CI
# runner. Needs a working `docker` (Docker Desktop, OrbStack, ...).
set -euo pipefail

IMAGE=${BOSUN_CI_IMAGE:-bosun-ci:24.04}
CPUS=${BOSUN_CI_CPUS:-2}
REPO=$(cd "$(dirname "$0")/.." && pwd)

# GitHub's ubuntu-latest runners come with python3, which the key
# passthrough tests use as a raw-input recorder.
DOCKERFILE=$(cat <<'EOF'
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      build-essential pkg-config git tmux zsh curl ca-certificates python3 \
 && rm -rf /var/lib/apt/lists/*
RUN useradd -m -s /bin/bash ci \
 && mkdir -p /w /home/ci/target /home/ci/.cargo/registry /home/ci/.cargo/git \
 && chown -R ci:ci /w /home/ci
USER ci
ENV PATH=/home/ci/.cargo/bin:$PATH \
    CARGO_TARGET_DIR=/home/ci/target \
    CARGO_TERM_COLOR=always \
    RUSTFLAGS="-D warnings"
RUN curl -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal \
      --default-toolchain stable -c rustfmt -c clippy
WORKDIR /w
EOF
)
# Rebuild when the Dockerfile above changes (or BOSUN_CI_REBUILD=1).
REV=$(printf '%s' "$DOCKERFILE" | cksum | cut -d' ' -f1)
HAVE=$(docker image inspect -f '{{index .Config.Labels "bosun.ci.rev"}}' "$IMAGE" 2>/dev/null || true)
if [ "$HAVE" != "$REV" ] || [ "${BOSUN_CI_REBUILD:-0}" = 1 ]; then
    printf '%s\nLABEL bosun.ci.rev=%s\n' "$DOCKERFILE" "$REV" | docker build -t "$IMAGE" -
fi

# Copy the working tree (minus the Mac app) into /w, then run the payload.
COPY='cd /src && git -c safe.directory=/src ls-files -z --cached --others --exclude-standard \
  | grep -zv "^macos/" | xargs -0 -I{} sh -c "[ -e \"{}\" ] && cp --parents \"{}\" /w/ || true"; cd /w'

case "${1:-all}" in
    all)
        PAYLOAD='tmux -V && cargo fmt --all -- --check && cargo clippy --all-targets -- -D warnings && cargo test --all-targets && cargo test --no-fail-fast --features tmux-it --all-targets'
        TTY=() ;;
    tmux-it)
        PAYLOAD='tmux -V && cargo test --no-fail-fast --features tmux-it --all-targets'
        TTY=() ;;
    shell)
        PAYLOAD='exec bash'
        TTY=(-it) ;;
    --)
        shift
        PAYLOAD=$(printf '%q ' "$@")
        TTY=() ;;
    *)
        echo "usage: $0 [all|tmux-it|shell|-- cmd...]" >&2
        exit 2 ;;
esac

exec docker run --rm ${TTY[@]+"${TTY[@]}"} --cpus "$CPUS" \
    -v "$REPO":/src:ro \
    -v bosun-ci-target:/home/ci/target \
    -v bosun-ci-registry:/home/ci/.cargo/registry \
    "$IMAGE" bash -c "$COPY && $PAYLOAD"
