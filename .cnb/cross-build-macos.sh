#!/usr/bin/env bash
# Stage 1 of the two-stage macOS build: compile the aarch64-apple-darwin
# `zed`, `cli` and `remote_server` Mach-O binaries inside the CNB cross-build
# container on any x86_64 Linux host that has Docker. Leaves
# dist/zed-yolo-v*-<target>-*.tar.zst (+ .sha256/.build.json) for stage 2,
# `script/bundle-mac -p <extracted dir>` on a macOS host, and writes the
# package's basename to dist/LATEST for the caller.
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
#   ZED_CROSS_COMPILER_RT    optional arm64 slice of Xcode's libclang_rt.osx.a
#                            (default ~/.cache/zed-yolo-cross/libclang_rt.osx.a);
#                            when present it is preferred over the archive the
#                            image builds from LLVM source
#   ZED_UPDATE_EXPLANATION   compiled into auto_update: disables zed.dev
#                            self-updates and explains why (default set)
#   ZED_CROSS_RELEASE_CHANNEL
#                            compile-time release channel (dev|nightly|preview|
#                            stable) instead of crates/zed/RELEASE_CHANNEL. A
#                            non-default channel gets its own bundle id, data
#                            dir and single-instance port, so it can be
#                            smoke-tested next to a running Zed (MAINTAINING.md
#                            §5.5). The package records it in RELEASE_CHANNEL.
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"
stage_started=$(date +%s)

image=${ZED_CROSS_IMAGE:-zed-yolo-macos-cross}
target=${ZED_CROSS_TARGET:-aarch64-apple-darwin}
jobs=${ZED_CROSS_JOBS:-$(nproc)}
volume_prefix=${ZED_CROSS_VOLUME_PREFIX:-zed-yolo}
# release_channel's build script turns ZED_RELEASE_CHANNEL into the compiled-in
# channel, so no tracked file changes for an override.
release_channel=${ZED_CROSS_RELEASE_CHANNEL:-$(<crates/zed/RELEASE_CHANNEL)}
case "$release_channel" in
  dev|nightly|preview|stable) ;;
  *) echo "unknown release channel: $release_channel" >&2; exit 2 ;;
esac
compiler_rt=${ZED_CROSS_COMPILER_RT:-$HOME/.cache/zed-yolo-cross/libclang_rt.osx.a}

if [[ "$target" == *apple-darwin && ! -f "$compiler_rt" ]]; then
  echo "note: no Apple compiler-rt slice at $compiler_rt; linking with the archive built into the image" >&2
fi

if [ "${ZED_CROSS_REBUILD_IMAGE:-0}" = 1 ] || ! docker image inspect "$image" >/dev/null 2>&1; then
  echo "Building cross-compile image $image from .cnb/Dockerfile.zed-macos"
  docker build --progress=plain -t "$image" -f .cnb/Dockerfile.zed-macos .cnb
fi

for volume in cargo-registry cargo-git sccache target; do
  docker volume create "${volume_prefix}-${volume}" >/dev/null
done

compiler_rt_mount=()
if [[ -f "$compiler_rt" ]]; then
  compiler_rt_mount=(-v "$compiler_rt:/opt/compiler-rt/libclang_rt.osx.a:ro")
fi

# The container runs as root like the CNB runner does (rustup may still add
# components under /usr/local), so the bind-mounted checkout must be marked
# safe for Git and the outputs are chowned back to the invoking user at the end.
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
    -e "ZED_UPDATE_EXPLANATION=${ZED_UPDATE_EXPLANATION:-This Enhanced build is updated through the zed-yolo release process, not by zed.dev.}" \
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

timed() {
  local label=$1
  shift
  local started
  started=$(date +%s)
  "$@"
  printf '[timing] %s: %ss\n' "$label" "$(( $(date +%s) - started ))"
}

if [ "${ZED_CROSS_SKIP_SMOKE:-0}" != 1 ]; then
  timed macho-smoke docker_run bash .cnb/run-zed-build-step.sh macho-smoke
fi
timed generate-licenses docker_run env ALLOW_MISSING_LICENSES=yes script/generate-licenses
docker_run bash .cnb/run-zed-build-step.sh metadata
timed "build zed+cli" docker_run bash .cnb/run-zed-build-step.sh build "$target" zed-cli --package zed --package cli
# Separate invocation, as in script/bundle-mac, so feature unification from the
# app crates does not change the libraries remote_server links against.
timed "build remote_server" docker_run bash .cnb/run-zed-build-step.sh build "$target" remote-server --package remote_server
timed package docker_run bash .cnb/run-zed-build-step.sh package "$target" all
docker_run bash .cnb/run-zed-build-step.sh stats

# dist/ was created by the container as root; hand it back before writing to it.
cleanup
# shellcheck disable=SC2012 # names are controlled by package_target
package=$(ls -t dist/zed-yolo-v*-"$target"-*.tar.zst | head -n 1)
basename "$package" > dist/LATEST
ls -lh "$package"*
printf '[timing] stage 1 total: %ss (%s)\n' "$(( $(date +%s) - stage_started ))" "$(basename "$package")"
