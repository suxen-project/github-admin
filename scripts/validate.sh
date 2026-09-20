#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

command -v jq >/dev/null || {
  printf 'jq is required\n' >&2
  exit 1
}

shopt -s nullglob
configuration_files=("${repository_root}"/config/repositories/*.json)
if ((${#configuration_files[@]} == 0)); then
  printf 'no repository configuration files found\n' >&2
  exit 1
fi

for configuration_file in "${configuration_files[@]}"; do
  jq --exit-status '
    (.name | type == "string" and length > 0) and
    (.settings | type == "object") and
    (.topics | type == "array" and all(.[]; type == "string")) and
    (.workflow_permissions.default_workflow_permissions | IN("read", "write")) and
    (.workflow_permissions.can_approve_pull_request_reviews | type == "boolean") and
    (.security | type == "object" and all(.[]; type == "boolean")) and
    (.rulesets | type == "array" and length > 0) and
    all(.rulesets[];
      (.name | type == "string" and length > 0) and
      (.target | IN("branch", "tag")) and
      (.enforcement | IN("active", "evaluate", "disabled")) and
      (.conditions.ref_name.include | type == "array" and length > 0) and
      (.rules | type == "array" and length > 0)
    )
  ' "${configuration_file}" >/dev/null
done

for script in "${repository_root}"/scripts/*.sh; do
  bash -n "${script}"
done

if git -C "${repository_root}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git -C "${repository_root}" diff --check
fi
printf 'configuration is valid\n'
