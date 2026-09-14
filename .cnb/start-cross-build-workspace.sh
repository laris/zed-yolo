#!/bin/sh
# Start the zed-yolo-cross-build workspace (Dev-CPU pool) for the commit of the
# pipeline that runs this script. Used by the tag_push and web_trigger pipelines
# in .cnb.yml; runs on a 1-cpu Build-CPU runner in an alpine image.
#
# Two facts about the workspace API shape this (2026-09-14, BUILDING.md §2.2):
#   * `branch` is resolved against branches only and a slash-containing tag
#     is not found through `ref` either, but a commit sha as `ref` works, so
#     the workspace is started on `branch: enhanced` at `ref: $CNB_COMMIT`.
#   * a workspace is keyed by branch and start reuses an existing one, even a
#     closed one, so the enhanced workspace is stopped and deleted first.
set -eu
: "${CNB_TOKEN:?}" "${CNB_API_ENDPOINT:?}" "${CNB_REPO_SLUG:?}" "${CNB_COMMIT:?}"
command -v jq >/dev/null || apk add --no-cache -q curl jq

api() { curl -fsS -H "Authorization: Bearer $CNB_TOKEN" -H "Content-Type: application/json" "$@"; }

api "$CNB_API_ENDPOINT/workspace/list?slug=$CNB_REPO_SLUG&branch=enhanced&page=1&page_size=20" \
  | jq -r '(.list // .data // [])[] | "\(.sn) \(.status) \(.pipelineId // .pipeline_id)"' \
  | while read -r sn status pipeline_id; do
      [ -n "$sn" ] || continue
      if [ "$status" = running ]; then
        echo "stopping running workspace $sn"
        api -X POST -d "{\"pipelineId\":\"$pipeline_id\"}" "$CNB_API_ENDPOINT/workspace/stop" >/dev/null || true
        sleep 5
      fi
      echo "deleting workspace $sn ($status)"
      api -X POST -d "{\"sn\":\"$sn\"}" "$CNB_API_ENDPOINT/workspace/delete" >/dev/null || true
    done

api -X POST -d "{\"branch\":\"enhanced\",\"ref\":\"$CNB_COMMIT\"}" "$CNB_API_ENDPOINT/$CNB_REPO_SLUG/-/workspace/start"
echo
echo "started zed-yolo-cross-build for ${CNB_BRANCH:-?} at $CNB_COMMIT"
