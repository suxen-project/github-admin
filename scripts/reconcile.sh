#!/usr/bin/env bash
set -euo pipefail

mode="${1:-audit}"
if [[ "${mode}" != "audit" && "${mode}" != "apply" ]]; then
  printf 'usage: %s [audit|apply]\n' "${0##*/}" >&2
  exit 2
fi

repository_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
organization="${GITHUB_ORGANIZATION:-suxen-project}"
api_version="2022-11-28"
temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/github-admin.XXXXXX")"
trap 'rm -rf "${temporary_directory}"' EXIT

for command in gh jq; do
  command -v "${command}" >/dev/null || {
    printf '%s is required\n' "${command}" >&2
    exit 1
  }
done
gh auth status >/dev/null

api() {
  gh api \
    --header 'Accept: application/vnd.github+json' \
    --header "X-GitHub-Api-Version: ${api_version}" \
    "$@"
}

json_contains() {
  local actual_file="$1"
  local desired_file="$2"
  jq --exit-status --slurpfile desired "${desired_file}" '
    def contains_desired($actual; $wanted):
      if ($wanted | type) == "object" then
        reduce ($wanted | keys[]) as $key
          (true; . and contains_desired($actual[$key]; $wanted[$key]))
      elif ($wanted | type) == "array" then
        ($actual | type) == "array" and
        ($actual | length) == ($wanted | length) and
        reduce range(0; $wanted | length) as $index
          (true; . and contains_desired($actual[$index]; $wanted[$index]))
      else
        $actual == $wanted
      end;
    contains_desired(.; $desired[0])
  ' "${actual_file}" >/dev/null
}

endpoint_enabled() {
  local endpoint="$1"
  api "${endpoint}" >/dev/null 2>&1
}

set_endpoint() {
  local endpoint="$1"
  local enabled="$2"
  if [[ "${enabled}" == "true" ]]; then
    api --method PUT "${endpoint}" >/dev/null
  else
    api --method DELETE "${endpoint}" >/dev/null
  fi
}

apply_repository() {
  local configuration_file="$1"
  local repository="$2"
  local endpoint="repos/${organization}/${repository}"

  jq --compact-output '.settings' "${configuration_file}" |
    api --method PATCH "${endpoint}" --input - >/dev/null
  jq --compact-output '{names: .topics}' "${configuration_file}" |
    api --method PUT "${endpoint}/topics" --input - >/dev/null
  jq --compact-output '.workflow_permissions' "${configuration_file}" |
    api --method PUT "${endpoint}/actions/permissions/workflow" --input - >/dev/null

  set_endpoint \
    "${endpoint}/vulnerability-alerts" \
    "$(jq -r '.security.vulnerability_alerts' "${configuration_file}")"
  set_endpoint \
    "${endpoint}/automated-security-fixes" \
    "$(jq -r '.security.automated_security_fixes' "${configuration_file}")"
  set_endpoint \
    "${endpoint}/private-vulnerability-reporting" \
    "$(jq -r '.security.private_vulnerability_reporting' "${configuration_file}")"

  while IFS= read -r ruleset_name; do
    local ruleset_id
    ruleset_id="$(
      api "${endpoint}/rulesets" |
        jq -r --arg name "${ruleset_name}" '.[] | select(.name == $name) | .id' |
        head -n 1
    )"
    if [[ -n "${ruleset_id}" ]]; then
      jq --compact-output --arg name "${ruleset_name}" \
        '.rulesets[] | select(.name == $name)' "${configuration_file}" |
        api --method PUT "${endpoint}/rulesets/${ruleset_id}" --input - >/dev/null
    else
      jq --compact-output --arg name "${ruleset_name}" \
        '.rulesets[] | select(.name == $name)' "${configuration_file}" |
        api --method POST "${endpoint}/rulesets" --input - >/dev/null
    fi
  done < <(jq -r '.rulesets[].name' "${configuration_file}")
}

audit_repository() {
  local configuration_file="$1"
  local repository="$2"
  local endpoint="repos/${organization}/${repository}"
  local drift=0
  local actual_file="${temporary_directory}/${repository}-actual.json"
  local desired_file="${temporary_directory}/${repository}-desired.json"

  api "${endpoint}" >"${actual_file}"
  jq '.settings' "${configuration_file}" >"${desired_file}"
  if ! json_contains "${actual_file}" "${desired_file}"; then
    printf '%s: repository settings drift\n' "${repository}" >&2
    drift=1
  fi

  api "${endpoint}/topics" >"${actual_file}"
  jq '{names: .topics}' "${configuration_file}" >"${desired_file}"
  if ! json_contains "${actual_file}" "${desired_file}"; then
    printf '%s: topics drift\n' "${repository}" >&2
    drift=1
  fi

  api "${endpoint}/actions/permissions/workflow" >"${actual_file}"
  jq '.workflow_permissions' "${configuration_file}" >"${desired_file}"
  if ! json_contains "${actual_file}" "${desired_file}"; then
    printf '%s: workflow permission drift\n' "${repository}" >&2
    drift=1
  fi

  local security_key
  local security_endpoint
  for security_key in vulnerability_alerts automated_security_fixes; do
    security_endpoint="${security_key//_/-}"
    if [[ "${security_key}" == "automated_security_fixes" ]]; then
      security_endpoint="automated-security-fixes"
    fi
    if endpoint_enabled "${endpoint}/${security_endpoint}"; then
      actual_security=true
    else
      actual_security=false
    fi
    desired_security="$(jq -r --arg key "${security_key}" '.security[$key]' "${configuration_file}")"
    if [[ "${actual_security}" != "${desired_security}" ]]; then
      printf '%s: %s drift\n' "${repository}" "${security_key}" >&2
      drift=1
    fi
  done

  api "${endpoint}/private-vulnerability-reporting" >"${actual_file}"
  actual_security="$(jq -r '.enabled' "${actual_file}")"
  desired_security="$(jq -r '.security.private_vulnerability_reporting' "${configuration_file}")"
  if [[ "${actual_security}" != "${desired_security}" ]]; then
    printf '%s: private vulnerability reporting drift\n' "${repository}" >&2
    drift=1
  fi

  while IFS= read -r ruleset_name; do
    local ruleset_id
    ruleset_id="$(
      api "${endpoint}/rulesets" |
        jq -r --arg name "${ruleset_name}" '.[] | select(.name == $name) | .id' |
        head -n 1
    )"
    if [[ -z "${ruleset_id}" ]]; then
      printf '%s: missing ruleset %s\n' "${repository}" "${ruleset_name}" >&2
      drift=1
      continue
    fi
    api "${endpoint}/rulesets/${ruleset_id}" >"${actual_file}"
    jq --arg name "${ruleset_name}" \
      '.rulesets[] | select(.name == $name)' "${configuration_file}" >"${desired_file}"
    if ! json_contains "${actual_file}" "${desired_file}"; then
      printf '%s: ruleset %s drift\n' "${repository}" "${ruleset_name}" >&2
      drift=1
    fi
  done < <(jq -r '.rulesets[].name' "${configuration_file}")

  if ((drift == 0)); then
    printf '%s: configuration matches GitHub\n' "${repository}"
  fi
  return "${drift}"
}

shopt -s nullglob
configuration_files=("${repository_root}"/config/repositories/*.json)
if ((${#configuration_files[@]} == 0)); then
  printf 'no repository configuration files found\n' >&2
  exit 1
fi

if [[ "${mode}" == "apply" ]]; then
  for configuration_file in "${configuration_files[@]}"; do
    repository="$(jq -r '.name' "${configuration_file}")"
    printf 'applying %s\n' "${repository}"
    apply_repository "${configuration_file}" "${repository}"
  done
fi

audit_failed=0
for configuration_file in "${configuration_files[@]}"; do
  repository="$(jq -r '.name' "${configuration_file}")"
  if ! audit_repository "${configuration_file}" "${repository}"; then
    audit_failed=1
  fi
done
exit "${audit_failed}"
