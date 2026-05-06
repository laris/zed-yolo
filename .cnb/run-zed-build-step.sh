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
  local feature_args=()
  if [[ "$label" == "zed-cli" || "$label" == "all" ]]; then
    feature_args=(--features gpui_platform/runtime_shaders)
  fi
  mkdir -p dist
  if [ ! -e "dist/${TARGET}.start" ]; then
    date +%s > "dist/${TARGET}.start"
  fi
  rustup target add "$TARGET"
  run_with_progress "${TARGET}-${label}" \
    /usr/bin/time -v cargo zigbuild --locked --release \
      --target "$TARGET" \
      "${feature_args[@]}" \
      "$@"
}

package_target() {
  TARGET="$1"
  local label="${2:-all}"
  source dist/build.env
  local start
  start=$(cat "dist/${TARGET}.start")
  local end
  end=$(date +%s)
  local out_dir="dist/zed-yolo-v${VERSION}-${TARGET}-${BUILD_DATE}-g${GIT_SHORT}${DIRTY}"
  rm -rf "$out_dir"
  mkdir -p "$out_dir"
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
  if [[ "$TARGET" == *apple-darwin ]]; then
    local macho_inputs=()
    for bin in "${binaries[@]}"; do
      macho_inputs+=("$out_dir/$bin")
    done
    python3 script/check-macho-dylibs.py "${macho_inputs[@]}"
  elif [[ "$label" == "remote-server" && "$TARGET" == x86_64-unknown-linux-* ]]; then
    local libc
    case "$TARGET" in
      *-gnu) libc=gnu ;;
      *-musl) libc=musl ;;
      *)
        echo "unsupported linux remote_server target for enhanced asset: $TARGET" >&2
        exit 2
        ;;
    esac
    local remote_asset="dist/zed-remote-server-linux-x86_64-${libc}.gz"
    gzip -f --stdout --best "$out_dir/remote_server" > "$remote_asset"
    sha256sum "$remote_asset" | tee "$remote_asset.sha256"
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
  printf '{"package":"zed-yolo","version":"%s","target":"%s","filename":"%s","sha256":"%s","seconds":%s,"commit":"%s","build":"%s","date":"%s","runtime_shaders":%s,"binaries":"%s","runner_cpus":"%s","runner_memory_gib":"%s","cargo_build_jobs":"%s","benchmark":"%s"}\n' \
    "$VERSION" "$TARGET" "$(basename "$tarball")" "$sha" "$((end - start))" "$CNB_COMMIT" "$CNB_BUILD_ID" "$BUILD_DATE" \
    "$runtime_shaders" "$binaries_csv" \
    "${ZED_YOLO_RUNNER_CPUS:-unknown}" "${ZED_YOLO_RUNNER_MEMORY_GIB:-unknown}" "${CARGO_BUILD_JOBS:-default}" "${ZED_YOLO_BENCHMARK:-default}" \
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
  run_with_progress "macho-linker-dedupe-smoke" \
    zig cc \
      -target aarch64-macos \
      -isysroot "$SDKROOT" \
      -L "$SDKROOT/usr/lib" \
      -F "$SDKROOT/System/Library/Frameworks" \
      -mmacosx-version-min=13.0 \
      "$smoke_dir/objc_smoke.c" \
      -lobjc -l objc \
      -liconv -l iconv \
      -framework AppKit -framework Appkit -framework AppKit \
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
