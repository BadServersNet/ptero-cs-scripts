#!/usr/bin/env bash

pterodactyl_throttle() {
  if [[ "${PTERO_REQUEST_DELAY_SECONDS}" != "0" ]]; then
    sleep "${PTERO_REQUEST_DELAY_SECONDS}"
  fi
}

pterodactyl_api_get() {
  local endpoint="$1"
  local response

  response="$(curl \
    --fail-with-body \
    --silent \
    --show-error \
    --retry "${PTERO_GET_RETRIES}" \
    --retry-all-errors \
    --header "Authorization: Bearer ${PTERO_API_KEY}" \
    --header "Accept: Application/vnd.pterodactyl.v1+json" \
    "${PTERO_URL}/api/client${endpoint}")"

  pterodactyl_throttle
  printf '%s\n' "${response}"
}

pterodactyl_get_server_resources() {
  local server_id="$1"
  local response

  response="$(pterodactyl_api_get "/servers/${server_id}/resources")" || return 1
  if ! jq -e '.attributes.resources | type == "object"' <<<"${response}" >/dev/null; then
    log_error "Pterodactyl returned invalid resources for ${server_id}."
    return 1
  fi
  printf '%s\n' "${response}"
}

pterodactyl_get_file_contents() {
  local server_id="$1"
  local remote_path="$2"
  local encoded_path

  encoded_path="$(jq -rn --arg value "${remote_path}" '$value | @uri')"
  pterodactyl_api_get "/servers/${server_id}/files/contents?file=${encoded_path}"
}

pterodactyl_restart_server() {
  local server_id="$1"
  local payload='{"signal":"restart"}'

  if [[ "${DRY_RUN}" == "1" ]]; then
    log_dry_run "Would restart ${server_id}."
    return 0
  fi

  curl \
    --fail-with-body \
    --silent \
    --show-error \
    --request POST \
    --header "Authorization: Bearer ${PTERO_API_KEY}" \
    --header 'Content-Type: application/json' \
    --header "Accept: Application/vnd.pterodactyl.v1+json" \
    --data "${payload}" \
    --output /dev/null \
    "${PTERO_URL}/api/client/servers/${server_id}/power"

  pterodactyl_throttle
}

