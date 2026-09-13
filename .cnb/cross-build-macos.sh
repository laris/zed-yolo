#!/usr/bin/env bash
# Stage 1 of the two-stage macOS build: compile the aarch64-apple-darwin
# `zed`, `cli` and `remote_server` Mach-O binaries inside the CNB cross-build
# container on any x86_64 Linux host that has Docker. Leaves
# dist/zed-yolo-v*-<target>-*.tar.zst (+ .sha256/.build.json) for stage 2,
# `script/bundle-mac -p <extracted dir>` on a macOS host.
#
# Run from the repository root of the commit to build:
#   bash .cnb/cross-build-macos.sh
#
# Environment:
#   ZED_CROSS_IMAGE          image tag (default zed-yolo-macos-cross)
#   ZED_CROSS_TARGET         Rust target (default aarch64-apple-darwin)
#   ZED_CROSS_JOBS           cargo jobs (default: nproc)
#   ZED_CROSS_VOLUME_PREFIX  docker volume name prefix (default zed-yolo)
#   ZED_CROSS_REBUILD_IMAGE  set to 1 to force a docker image rebuild
#   ZED_CROSS_SKIP_SMOKE     set to 1 to skip the linker dedupe smoke test
#   ZED_CROSS_COMPILER_RT    arm64 slice of Xcode's libclang_rt.osx.a (default
#                            ~/.cache/zed-yolo-cross/libclang_rt.osx.a); the
#                            Darwin link needs it for __isPlatformVersionAtLeast
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

image=${ZED_CROSS_IMAGE:-zed-yolo-macos-cross}
target=${ZED_CROSS_TARGET:-aarch64-apple-darwin}
jobs=${ZED_CROSS_JOBS:-$(nproc)}
volume_prefix=${ZED_CROSS_VOLUME_PREFIX:-zed-yolo}
release_channel=$(<crates/zed/RELEASE_CHANNEL)
compiler_rt=${ZED_CROSS_COMPILER_RT:-$HOME/.cache/zed-yolo-cross/libclang_rt.osx.a}

if [[ "$target" == *apple-darwin && ! -f "$compiler_rt" ]]; then
  cat >&2 <<EOF
Missing $compiler_rt

The Darwin link needs the arm64 slice of Xcode's compiler-rt builtins
(__isPlatformVersionAtLeast, used by every @available check). On a Mac with
Xcode installed:

  lipo -thin arm64 "\$(dirname "\$(xcrun --find clang)")/../lib/clang/"*"/lib/darwin/libclang_rt.osx.a" \\
    -output libclang_rt.osx.a

then copy it to the path above on this host, or point ZED_CROSS_COMPILER_RT at it.
EOF
  exit 1
fi

if [ "${ZED_CROSS_REBUILD_IMAGE:-0}" = 1 ] || ! docker image inspect "$image" >/dev/null 2>&1; then
  echo "Building cross-compile image $image from .cnb/Dockerfile.zed-macos"
  docker build --progress=plain -t "$image" -f .cnb/Dockerfile.zed-macos .cnb
fi

for volume in cargo-registry cargo-git sccache target; do
  docker volume create "${volume_prefix}-${volume}" >/dev/null
done

# The container runs as root like the CNB runner does (rustup may still add
# components under /usr/local), so the bind-mounted checkout must be marked
# safe for Git and the outputs are chowned back to the invoking user at the end.
compiler_rt_mount=()
if [[ -f "$compiler_rt" ]]; then
  compiler_rt_mount=(-v "$compiler_rt:/opt/compiler-rt/libclang_rt.osx.a:ro")
fi

docker_run() {
  docker run --rm \
    --user 0:0 \
    ${compiler_rt_mount[@]+"${compiler_rt_mount[@]}"} \
    -v "$repo_root:/workspace" \
    -v "${volume_prefix}-cargo-registry:/usr/local/cargo/registry" \
    -v "${volume_prefix}-cargo-git:/usr/local/cargo/git" \
    -v "${volume_prefix}-sccache:/var/cache/sccache" \
    -v "${volume_prefix}-target:/workspace/target" \
    -w /workspace \
    -e CARGO_INCREMENTAL=0 \
    -e CARGO_TERM_COLOR=never \
    -e "CARGO_BUILD_JOBS=$jobs" \
    -e RUSTC_WRAPPER=sccache \
    -e SCCACHE_DIR=/var/cache/sccache \
    -e SCCACHE_CACHE_SIZE=80G \
    -e ZED_BUNDLE=true \
    -e "ZED_RELEASE_CHANNEL=$release_channel" \
    -e "ZED_ENHANCED_LABEL=${ZED_ENHANCED_LABEL:-Enhanced}" \
    -e "ZED_YOLO_RUNNER_CPUS=$jobs" \
    -e "ZED_YOLO_BENCHMARK=${ZED_YOLO_BENCHMARK:-docker-$(hostname)}" \
    -e BUILD_HEARTBEAT_SECONDS="${BUILD_HEARTBEAT_SECONDS:-120}" \
    -e GIT_CONFIG_COUNT=1 \
    -e GIT_CONFIG_KEY_0=safe.directory \
    -e GIT_CONFIG_VALUE_0='*' \
    "$image" \
    "$@"
}

cleanup() {
  docker_run chown -R "$(id -u):$(id -g)" /workspace/dist /workspace/assets 2>/dev/null || true
}
trap cleanup EXIT

if [ "${ZED_CROSS_SKIP_SMOKE:-0}" != 1 ]; then
  docker_run bash .cnb/run-zed-build-step.sh macho-smoke
fi
docker_run env ALLOW_MISSING_LICENSES=yes script/generate-licenses
docker_run bash .cnb/run-zed-build-step.sh metadata
docker_run bash .cnb/run-zed-build-step.sh build "$target" zed-cli --package zed --package cli
# Separate invocation, as in script/bundle-mac, so feature unification from the
# app crates does not change the libraries remote_server links against.
docker_run bash .cnb/run-zed-build-step.sh build "$target" remote-server --package remote_server
docker_run bash .cnb/run-zed-build-step.sh package "$target" all
docker_run bash .cnb/run-zed-build-step.sh stats

ls -lh dist/zed-yolo-v*-"$target"-*.tar.zst*
