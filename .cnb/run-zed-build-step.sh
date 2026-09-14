#!/usr/bin/env bash
set -euo pipefail

run_with_progress() {
  local label="$1"
  shift
  local log_dir="/tmp/zed-yolo-build-logs"
  mkdir -p "$log_dir"
  local log_file="$log_dir/${label}.log"
  local rc_file="$log_dir/${label}.rc"
  local heartbeat_seconds="${BUILD_HEARTBEAT_SECONDS:-60}"
  local poll_seconds="${BUILD_LOG_POLL_SECONDS:-5}"
  local scanned_lines=0
  rm -f "$rc_file"
  : > "$log_file"
  printf '\n===== BEGIN %s =====\n' "$label"
  printf 'command:'
  printf ' %s' "$@"
  printf '\nlog: %s\n' "$log_file"
  local start_epoch
  start_epoch=$(date +%s)

  set +e
  (
    "$@" 2>&1
    printf '%s\n' "$?" > "$rc_file"
  ) | tee -a "$log_file" &
  local pipe_pid=$!
  set -e

  local next_heartbeat=$((start_epoch + heartbeat_seconds))

  while kill -0 "$pipe_pid" 2>/dev/null; do
    sleep "$poll_seconds"
    local total_lines
    total_lines=$(wc -l < "$log_file" | tr -d ' ')
    if [ "$total_lines" -gt "$scanned_lines" ]; then
      sed -n "$((scanned_lines + 1)),${total_lines}p" "$log_file" \
        | grep -aiE '(^error(\[|:)|^fatal:|failed to run custom build command|linking with .* failed|undefined symbols|unable to find|No such file|panicked at|Command exited with non-zero status|exit status: [1-9]|could not compile)' \
        | tail -40 \
        | sed 's/^/[error-scan] /' || true
      scanned_lines="$total_lines"
    fi

    local now
    now=$(date +%s)
    if [ "$now" -ge "$next_heartbeat" ]; then
      local elapsed=$((now - start_epoch))
      printf '\n[heartbeat] %s running for %ss pipeline_pid=%s target=%s log_lines=%s\n' \
        "$label" "$elapsed" "$pipe_pid" "${TARGET:-unknown}" "$total_lines"
      ps -o pid,ppid,pcpu,pmem,rss,vsz,etime,comm -p "$pipe_pid" || true
      ps -eo pid,ppid,pcpu,pmem,rss,vsz,etime,comm,args \
        | grep -E 'cargo|rustc|zig|ld64|clang|cc1|sccache|mold|ld' \
        | grep -v grep \
        | sort -k3 -nr \
        | head -25 || true
      df -h /workspace /var/cache/sccache /tmp 2>/dev/null || true
      du -sh "target/${TARGET:-}" 2>/dev/null || true
      sccache --show-stats 2>/dev/null | sed -n '1,18p' || true
      next_heartbeat=$((now + heartbeat_seconds))
    fi
  done

  set +e
  wait "$pipe_pid"
  local pipe_status=$?
  set -e
  local status="$pipe_status"
  if [ -s "$rc_file" ]; then
    status=$(cat "$rc_file")
  fi

  local total_lines
  total_lines=$(wc -l < "$log_file" | tr -d ' ')
  if [ "$total_lines" -gt "$scanned_lines" ]; then
    sed -n "$((scanned_lines + 1)),${total_lines}p" "$log_file" \
      | grep -aiE '(^error(\[|:)|^fatal:|failed to run custom build command|linking with .* failed|undefined symbols|unable to find|No such file|panicked at|Command exited with non-zero status|exit status: [1-9]|could not compile)' \
      | tail -40 \
      | sed 's/^/[error-scan] /' || true
  fi

  local end_epoch
  end_epoch=$(date +%s)
  printf '===== END %s status=%s elapsed=%ss log=%s =====\n' \
    "$label" "$status" "$((end_epoch - start_epoch))" "$log_file"
  if [ "$status" -ne 0 ]; then
    printf '\n===== RECENT LOG TAIL %s =====\n' "$label"
    tail -200 "$log_file" || true
  fi
  return "$status"
}

metadata() {
  rm -rf dist
  mkdir -p dist
  local version
  version=$(cargo metadata --locked --no-deps --format-version 1 \
    | jq -r '.packages[] | select(.name == "zed") | .version' \
    | head -n 1)
  test -n "$version"
  {
    printf 'VERSION=%q\n' "$version"
    printf 'BUILD_DATE=%q\n' "$(date -u +%Y%m%d)"
    printf 'GIT_SHORT=%q\n' "$(git rev-parse --short=8 HEAD)"
    if [ -z "$(git status --porcelain --untracked-files=no)" ]; then
      printf 'DIRTY=%q\n' ""
    else
      printf 'DIRTY=%q\n' "-dirty"
    fi
  } > dist/build.env
  cat dist/build.env
}

build() {
  TARGET="$1"
  local label="$2"
  shift 2
  # No Linux host has Apple's `metal` compiler, so every Darwin artifact,
  # including remote_server (which links gpui_platform), must compile shaders
  # at runtime. bundle-mac makes the same choice for Metal-less macOS hosts.
  local feature_args=()
  if [[ "$TARGET" == *apple-darwin ]]; then
    feature_args=(--features gpui_platform/runtime_shaders)
  fi
  mkdir -p dist
  if [ ! -e "dist/${TARGET}.start" ]; then
    date +%s > "dist/${TARGET}.start"
  fi
  rustup target add "$TARGET"
  # Build scripts probe the image's toolchain (webrtc-sys asks the host
  # `cc --print-search-dirs`) and cargo caches their output by source inputs
  # only, so a new image with an old target volume keeps stale answers. Drop
  # every cached build-script output once per image identity.
  if [ -f /etc/zed-yolo-toolchain.json ]; then
    mkdir -p target
    if ! cmp -s /etc/zed-yolo-toolchain.json target/.zed-yolo-toolchain.json; then
      echo "toolchain identity changed; discarding cached build-script outputs"
      rm -rf "target/${TARGET}/release/build" target/release/build
      cp /etc/zed-yolo-toolchain.json target/.zed-yolo-toolchain.json
    fi
  fi
  # sccache starts its server on demand and the server does not survive from
  # one pipeline stage to the next; a client that then times out waiting for
  # the startup fails the whole cargo build (CNB, 2026-09-14). Start it here,
  # with no idle exit, and build uncached rather than not at all.
  if [ "${RUSTC_WRAPPER:-}" = sccache ]; then
    sccache --stop-server >/dev/null 2>&1 || true
    if ! SCCACHE_IDLE_TIMEOUT=0 sccache --start-server >/dev/null 2>&1; then
      echo "sccache server did not start; building without the compile cache" >&2
      unset RUSTC_WRAPPER
    fi
  fi
  # Darwin targets link with clang + ld64.lld through the
  # aarch64-apple-darwin-clang wrappers selected by the container's CC_/LINKER
  # environment (zig's Mach-O linker lacks section$start/end symbols before 0.14
  # and zig >= 0.14 needs statx(2), which old build-host kernels lack). Linux
  # targets keep cargo-zigbuild for glibc-version pinning.
  local cargo_build=(cargo build)
  if [[ "$TARGET" != *apple-darwin ]]; then
    cargo_build=(cargo zigbuild)
  fi
  # .cargo/bundle-config.toml is what upstream's bundle scripts pass, so the
  # cross-built binaries get the same share-generics codegen as native bundles.
  run_with_progress "${TARGET}-${label}" \
    /usr/bin/time -v "${cargo_build[@]}" --locked --release \
      --config .cargo/bundle-config.toml \
      --target "$TARGET" \
      ${feature_args[@]+"${feature_args[@]}"} \
      "$@"
}

gzip_remote_server() {
  gzip -f --stdout --best "$1" > "$2"
  sha256sum "$2" | tee "$2.sha256"
}

package_target() {
  TARGET="$1"
  local label="${2:-all}"
  source dist/build.env
  local start
  start=$(cat "dist/${TARGET}.start")
  local end
  end=$(date +%s)
  # The compiled-in channel follows $ZED_RELEASE_CHANNEL when set (see
  # crates/release_channel/build.rs); name the package after it when it is not
  # the checkout's default so stage 2 cannot mistake a test channel for a release.
  local default_channel
  default_channel=$(<crates/zed/RELEASE_CHANNEL)
  local channel="${ZED_RELEASE_CHANNEL:-$default_channel}"
  local channel_suffix=""
  if [ "$channel" != "$default_channel" ]; then
    channel_suffix="-${channel}"
  fi
  local out_dir="dist/zed-yolo-v${VERSION}${channel_suffix}-${TARGET}-${BUILD_DATE}-g${GIT_SHORT}${DIRTY}"
  rm -rf "$out_dir"
  mkdir -p "$out_dir"
  printf '%s' "$channel" > "$out_dir/RELEASE_CHANNEL"
  local expected_binaries=()
  case "$label" in
    zed-cli)
      expected_binaries=(zed cli)
      ;;
    remote-server)
      expected_binaries=(remote_server)
      ;;
    all)
      expected_binaries=(zed cli remote_server)
      ;;
    *)
      echo "unknown package label: ${label}" >&2
      exit 2
      ;;
  esac
  local binaries=()
  local bin
  for bin in "${expected_binaries[@]}"; do
    if [ -f "target/${TARGET}/release/${bin}" ]; then
      cp "target/${TARGET}/release/${bin}" "$out_dir/${bin}"
      binaries+=("$bin")
    fi
  done
  if [ "${#binaries[@]}" -eq 0 ]; then
    echo "no release binaries found for ${TARGET}" >&2
    exit 1
  fi
  local arch=${TARGET%%-*}
  if [[ "$TARGET" == *apple-darwin ]]; then
    local macho_inputs=()
    for bin in "${binaries[@]}"; do
      macho_inputs+=("$out_dir/$bin")
    done
    python3 script/check-macho-dylibs.py "${macho_inputs[@]}"
    if [ -f "$out_dir/remote_server" ]; then
      # Nothing about this binary needs the Mac, so the release asset (same
      # name as upstream's) is produced here rather than in stage 2.
      gzip_remote_server "$out_dir/remote_server" "dist/zed-remote-server-macos-${arch}.gz"
    fi
  elif [[ "$TARGET" == *-unknown-linux-* && -f "$out_dir/remote_server" ]]; then
    local suffix=""
    case "$TARGET" in
      *-musl) ;;
      *-gnu) suffix=-gnu ;;
      *)
        echo "unsupported linux remote_server target: $TARGET" >&2
        exit 2
        ;;
    esac
    gzip_remote_server "$out_dir/remote_server" "dist/zed-remote-server-linux-${arch}${suffix}.gz"
  fi
  local tarball="${out_dir}.tar.zst"
  tar -C dist -I 'zstd -19 -T0' -cf "$tarball" "$(basename "$out_dir")"
  local sha
  sha=$(sha256sum "$tarball" | tee "$tarball.sha256" | awk '{print $1}')
  local runtime_shaders=false
  if [ -f "$out_dir/zed" ] || [ -f "$out_dir/cli" ]; then
    runtime_shaders=true
  fi
  local binaries_csv
  binaries_csv=$(IFS=,; printf '%s' "${binaries[*]}")
  # The image records its pinned inputs (BUILDING.md §1.2); carrying them in
  # the provenance lets two hosts prove they built with the same toolchain.
  local toolchain_json
  toolchain_json=$(cat /etc/zed-yolo-toolchain.json 2>/dev/null || printf '{}')
  printf '{"package":"zed-yolo","version":"%s","channel":"%s","target":"%s","filename":"%s","sha256":"%s","seconds":%s,"commit":"%s","build":"%s","date":"%s","runtime_shaders":%s,"binaries":"%s","runner_cpus":"%s","runner_memory_gib":"%s","cargo_build_jobs":"%s","benchmark":"%s","toolchain":%s}\n' \
    "$VERSION" "$channel" "$TARGET" "$(basename "$tarball")" "$sha" "$((end - start))" "${CNB_COMMIT:-$(git rev-parse HEAD)}" "${CNB_BUILD_ID:-local}" "$BUILD_DATE" \
    "$runtime_shaders" "$binaries_csv" \
    "${ZED_YOLO_RUNNER_CPUS:-unknown}" "${ZED_YOLO_RUNNER_MEMORY_GIB:-unknown}" "${CARGO_BUILD_JOBS:-default}" "${ZED_YOLO_BENCHMARK:-default}" \
    "$toolchain_json" \
    | tee "$tarball.build.json"
  ls -lh "$tarball" "$tarball.sha256" "$tarball.build.json"
}

macho_smoke() {
  local smoke_dir="/tmp/zed-yolo-macho-smoke"
  rm -rf "$smoke_dir"
  mkdir -p "$smoke_dir"
  cat > "$smoke_dir/objc_smoke.c" <<'EOF'
int main(void) {
  return 0;
}
EOF
  # Same wrapper cargo uses for the real link; duplicate -l/-framework flags
  # mirror what rustc emits and must collapse to one load command each.
  run_with_progress "macho-linker-dedupe-smoke" \
    aarch64-apple-darwin-clang \
      "$smoke_dir/objc_smoke.c" \
      -lobjc -l objc \
      -liconv -l iconv \
      -framework AppKit -framework Appkit -framework AppKit \
      -Wl,-ObjC -Wl,-weak_framework,ScreenCaptureKit -Wl,-dead_strip \
      -o "$smoke_dir/objc_smoke"
  file "$smoke_dir/objc_smoke"
  python3 script/check-macho-dylibs.py "$smoke_dir/objc_smoke"
}

case "${1:-}" in
  metadata)
    metadata
    ;;
  build)
    shift
    build "$@"
    ;;
  package)
    shift
    package_target "$@"
    ;;
  stats)
    sccache --show-stats || true
    ;;
  macho-smoke)
    macho_smoke
    ;;
  *)
    echo "usage: $0 {metadata|build <target> <label> <cargo package args...>|package <target>|stats|macho-smoke}" >&2
    exit 2
    ;;
esac
