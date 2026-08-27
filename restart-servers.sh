#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
RUN_STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
RUN_DATE="${RUN_STARTED_AT%%T*}"
RUN_TIME="${RUN_STARTED_AT#*T}"
RUN_TIME="${RUN_TIME%Z}"
RUN_TIME="${RUN_TIME//:/-}"
LOG_DIR="${REPO_ROOT}/.logs/${RUN_DATE}"
LOG_FILE="${LOG_DIR}/${RUN_TIME}.log"

mkdir -p "${LOG_DIR}"
exec >>"${LOG_FILE}" 2>&1

source "${REPO_ROOT}/shared/env.sh"
source "${REPO_ROOT}/shared/log.sh"

DRY_RUN=0
case "${1:-}" in
  "") ;;
  -n | --dry-run) DRY_RUN=1 ;;
  -h | --help)
    echo "Usage: $0 [-n|--dry-run]"
    exit 0
    ;;
  *)
    echo "Usage: $0 [-n|--dry-run]" >&2
    exit 64
    ;;
esac

for command in curl flock jq; do
  if ! command -v "${command}" >/dev/null 2>&1; then
    log_error "Required command was not found: ${command}"
    exit 1
  fi
done

CACHE_DIR="${REPO_ROOT}/.cache"
mkdir -p "${CACHE_DIR}"
exec {LOCK_FD}>"${CACHE_DIR}/restart-servers.lock"
if ! flock -n "${LOCK_FD}"; then
  log_info "Another restart check is already running."
  exit 0
fi

PROJECT_ENV_FILE="${PROJECT_ENV_FILE:-${REPO_ROOT}/.env}"
load_project_env "${PROJECT_ENV_FILE}"

PTERO_URL="${PTERO_URL:-}"
PTERO_API_KEY="${PTERO_API_KEY:-}"
PTERO_SERVER_IDS="${PTERO_SERVER_IDS:-}"
PLAYER_COUNT_API_URL="${PLAYER_COUNT_API_URL:-https://badservers.net/api/servers}"
PLAYER_COUNT_MISSING_IS_EMPTY="${PLAYER_COUNT_MISSING_IS_EMPTY:-1}"
MIN_UPTIME_HOURS="${MIN_UPTIME_HOURS:-6}"
GAME_UPDATE_COOLDOWN_MINUTES="${GAME_UPDATE_COOLDOWN_MINUTES:-30}"
GAME_UPDATE_VERIFY_ATTEMPTS="${GAME_UPDATE_VERIFY_ATTEMPTS:-60}"
GAME_UPDATE_VERIFY_INTERVAL_SECONDS="${GAME_UPDATE_VERIFY_INTERVAL_SECONDS:-10}"
PTERO_REQUEST_DELAY_SECONDS="${PTERO_REQUEST_DELAY_SECONDS:-1}"
PTERO_GET_RETRIES="${PTERO_GET_RETRIES:-10}"
PTERO_URL="${PTERO_URL%/}"

if [[ -z "${PTERO_URL}" || ! "${PTERO_URL}" =~ ^https?:// ]]; then
  log_error "PTERO_URL must be configured with an http:// or https:// URL."
  exit 1
fi
if [[ -z "${PTERO_API_KEY}" ]]; then
  log_error "PTERO_API_KEY must be configured."
  exit 1
fi
if [[ -z "${PTERO_SERVER_IDS//[[:space:],]/}" ]]; then
  log_error "PTERO_SERVER_IDS must contain at least one server identifier."
  exit 1
fi
if [[ ! "${PLAYER_COUNT_API_URL}" =~ ^https?:// ]]; then
  log_error "PLAYER_COUNT_API_URL must begin with http:// or https://."
  exit 1
fi
if [[ "${PLAYER_COUNT_MISSING_IS_EMPTY}" != "0" && "${PLAYER_COUNT_MISSING_IS_EMPTY}" != "1" ]]; then
  log_error "PLAYER_COUNT_MISSING_IS_EMPTY must be 0 or 1."
  exit 1
fi
if [[ ! "${MIN_UPTIME_HOURS}" =~ ^[0-9]+$ ]]; then
  log_error "MIN_UPTIME_HOURS must be a nonnegative integer."
  exit 1
fi
if [[ ! "${GAME_UPDATE_COOLDOWN_MINUTES}" =~ ^[0-9]+$ ]]; then
  log_error "GAME_UPDATE_COOLDOWN_MINUTES must be a nonnegative integer."
  exit 1
fi
if [[ ! "${GAME_UPDATE_VERIFY_ATTEMPTS}" =~ ^[1-9][0-9]*$ ]]; then
  log_error "GAME_UPDATE_VERIFY_ATTEMPTS must be a positive integer."
  exit 1
fi
if [[ ! "${GAME_UPDATE_VERIFY_INTERVAL_SECONDS}" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  log_error "GAME_UPDATE_VERIFY_INTERVAL_SECONDS must be a nonnegative number."
  exit 1
fi
if [[ ! "${PTERO_REQUEST_DELAY_SECONDS}" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  log_error "PTERO_REQUEST_DELAY_SECONDS must be a nonnegative number."
  exit 1
fi
if [[ ! "${PTERO_GET_RETRIES}" =~ ^[0-9]+$ ]]; then
  log_error "PTERO_GET_RETRIES must be a nonnegative integer."
  exit 1
fi

source "${REPO_ROOT}/shared/pterodactyl.sh"

normalized_server_ids="${PTERO_SERVER_IDS//,/ }"
read -r -a SERVER_IDS <<<"${normalized_server_ids}"
for server_id in "${SERVER_IDS[@]}"; do
  if [[ ! "${server_id}" =~ ^[A-Za-z0-9_-]+$ ]]; then
    log_error "Invalid Pterodactyl server identifier: ${server_id}"
    exit 1
  fi
done

latest_cs2_version() {
  local response
  local version

  response="$(curl --fail --location --show-error --silent \
    'https://api.steampowered.com/ISteamApps/UpToDateCheck/v0001?version=1&format=json&appid=730')" || return 1
  version="$(jq -r '
    try (.response.message | capture("(?<version>[0-9]+(\\.[0-9]+)+)").version)
    catch ""
  ' <<<"${response}")"
  if [[ -z "${version}" ]]; then
    return 1
  fi
  printf '%s\n' "${version}"
}

installed_cs2_version() {
  local server_id="$1"
  local steam_inf
  local version

  steam_inf="$(pterodactyl_get_file_contents "${server_id}" "/game/csgo/steam.inf")" || return 1
  version="$(sed -nE 's/^PatchVersion=([^=[:space:]]+).*/\1/p' <<<"${steam_inf}" | head -n 1)"
  if [[ ! "${version}" =~ ^[0-9]+([.][0-9]+)*$ ]]; then
    return 1
  fi
  printf '%s\n' "${version}"
}

version_is_newer() {
  local candidate="$1"
  local installed="$2"
  local candidate_parts=()
  local installed_parts=()
  local length
  local index
  local candidate_part
  local installed_part

  [[ "${candidate}" =~ ^[0-9]+([.][0-9]+)*$ ]] || return 1
  [[ "${installed}" =~ ^[0-9]+([.][0-9]+)*$ ]] || return 1
  IFS=. read -r -a candidate_parts <<<"${candidate}"
  IFS=. read -r -a installed_parts <<<"${installed}"
  length="${#candidate_parts[@]}"
  if ((${#installed_parts[@]} > length)); then
    length="${#installed_parts[@]}"
  fi
  for ((index = 0; index < length; index++)); do
    candidate_part="${candidate_parts[index]:-0}"
    installed_part="${installed_parts[index]:-0}"
    if ((10#${candidate_part} > 10#${installed_part})); then
      return 0
    fi
    if ((10#${candidate_part} < 10#${installed_part})); then
      return 1
    fi
  done
  return 1
}

wait_for_verified_game_update() {
  local server_id="$1"
  local target_version="$2"
  local attempt
  local installed_version
  local resources
  local current_state

  log_info "Waiting for ${server_id} to install CS2 patch ${target_version} and return to running."
  for ((attempt = 1; attempt <= GAME_UPDATE_VERIFY_ATTEMPTS; attempt++)); do
    installed_version=""
    installed_version="$(installed_cs2_version "${server_id}" 2>/dev/null)" || installed_version=""
    current_state="version pending"

    if [[ -n "${installed_version}" ]] && ! version_is_newer "${target_version}" "${installed_version}"; then
      current_state="unavailable"
      if resources="$(pterodactyl_get_server_resources "${server_id}" 2>/dev/null)"; then
        current_state="$(jq -r '.attributes.current_state // "unavailable"' <<<"${resources}")"
      fi
      if [[ "${current_state}" == "running" ]]; then
        log_success "Verified ${server_id} at CS2 patch ${installed_version} and running."
        return 0
      fi
    fi

    log_info "Verification ${attempt}/${GAME_UPDATE_VERIFY_ATTEMPTS} for ${server_id}: patch ${installed_version:-unavailable}, state ${current_state}."
    if ((attempt < GAME_UPDATE_VERIFY_ATTEMPTS)); then
      sleep "${GAME_UPDATE_VERIFY_INTERVAL_SECONDS}"
    fi
  done

  log_error "${server_id} did not reach CS2 patch ${target_version} and running state within the verification window."
  return 1
}

PLAYER_COUNTS_LOADED=0
declare -A PLAYER_COUNTS=()

load_player_counts() {
  local response
  local server_id
  local player_count

  if [[ "${PLAYER_COUNTS_LOADED}" == "1" ]]; then
    return 0
  fi
  response="$(curl --fail --location --show-error --silent "${PLAYER_COUNT_API_URL}")" || {
    log_error "Could not load player counts from ${PLAYER_COUNT_API_URL}."
    return 1
  }
  if ! jq -e '.result.servers | type == "array"' <<<"${response}" >/dev/null; then
    log_error "Player count API returned an unexpected response."
    return 1
  fi
  while IFS=$'\t' read -r server_id player_count; do
    if [[ -n "${server_id}" ]]; then
      PLAYER_COUNTS["${server_id}"]="${player_count}"
    fi
  done < <(jq -r '.result.servers[] | [.id, (.players | length)] | @tsv' <<<"${response}")
  PLAYER_COUNTS_LOADED=1
}

get_player_count() {
  local server_id="$1"
  local output_name="$2"
  local resolved_count

  load_player_counts || return 1
  if [[ ! -v "PLAYER_COUNTS[${server_id}]" ]]; then
    if [[ "${PLAYER_COUNT_MISSING_IS_EMPTY}" != "1" ]]; then
      log_error "Server ${server_id} was not found in the player count API."
      return 1
    fi
    log_warn "Server ${server_id} is not listed by the player count API; treating it as empty or offline."
    resolved_count=0
  else
    resolved_count="${PLAYER_COUNTS[${server_id}]}"
  fi
  printf -v "${output_name}" '%s' "${resolved_count}"
}

UPDATE_STATE_FILE="${CACHE_DIR}/game-update-restarts.json"
update_state='{}'
if [[ -f "${UPDATE_STATE_FILE}" ]]; then
  if ! jq -e 'type == "object" and all(values[]; (.version | type == "string") and (.epoch | type == "number"))' "${UPDATE_STATE_FILE}" >/dev/null; then
    log_error "Invalid game update restart state: ${UPDATE_STATE_FILE}"
    exit 1
  fi
  update_state="$(<"${UPDATE_STATE_FILE}")"
fi

save_update_state() {
  local temporary_file

  temporary_file="$(mktemp "${CACHE_DIR}/game-update-restarts.XXXXXXXX")"
  printf '%s\n' "${update_state}" | jq --sort-keys . >"${temporary_file}"
  chmod 600 "${temporary_file}"
  mv -- "${temporary_file}" "${UPDATE_STATE_FILE}"
}

latest_version=""
run_status=0
if ! latest_version="$(latest_cs2_version)"; then
  log_error "Could not determine the latest CS2 patch version from Steam."
  run_status=1
fi

now_epoch="$(date +%s)"
minimum_uptime_ms="$((MIN_UPTIME_HOURS * 60 * 60 * 1000))"
cooldown_seconds="$((GAME_UPDATE_COOLDOWN_MINUTES * 60))"

for server_id in "${SERVER_IDS[@]}"; do
  if ! resources="$(pterodactyl_get_server_resources "${server_id}")"; then
    run_status=1
    continue
  fi
  if ! current_state="$(jq -er '.attributes.current_state' <<<"${resources}")"; then
    log_error "Could not read the power state for ${server_id}."
    run_status=1
    continue
  fi
  if [[ "${current_state}" != "running" ]]; then
    log_info "Skipping ${server_id}: ${current_state}."
    continue
  fi

  installed_version=""
  if [[ -n "${latest_version}" ]] && ! installed_version="$(installed_cs2_version "${server_id}")"; then
    log_error "Could not read the installed CS2 patch for ${server_id}."
    run_status=1
  fi

  if [[ -n "${latest_version}" && -n "${installed_version}" ]] \
    && version_is_newer "${latest_version}" "${installed_version}"; then
    last_version="$(jq -r --arg server_id "${server_id}" '.[$server_id].version // ""' <<<"${update_state}")"
    last_epoch="$(jq -r --arg server_id "${server_id}" '.[$server_id].epoch // 0' <<<"${update_state}")"
    if [[ "${last_version}" == "${latest_version}" ]] && ((now_epoch - last_epoch < cooldown_seconds)); then
      log_info "Skipping ${server_id}: the ${latest_version} update restart cooldown is active."
      continue
    fi
    if pterodactyl_restart_server "${server_id}"; then
      if [[ "${DRY_RUN}" == "1" ]]; then
        log_dry_run "Game update detected for ${server_id}: ${installed_version} -> ${latest_version}."
      else
        update_state="$(jq -c \
          --arg server_id "${server_id}" \
          --arg version "${latest_version}" \
          --argjson epoch "${now_epoch}" \
          '.[$server_id] = {version: $version, epoch: $epoch}' <<<"${update_state}")"
        save_update_state
        log_success "Requested a restart for ${server_id} to install CS2 patch ${installed_version} -> ${latest_version}."
        if ! wait_for_verified_game_update "${server_id}" "${latest_version}"; then
          run_status=1
        fi
      fi
    else
      log_error "Pterodactyl rejected the game update restart for ${server_id}."
      run_status=1
    fi
    continue
  fi

  if ! uptime_ms="$(jq -er '.attributes.resources.uptime' <<<"${resources}")"; then
    log_error "Could not read the uptime for ${server_id}."
    run_status=1
    continue
  fi
  if ((uptime_ms < minimum_uptime_ms)); then
    log_info "Skipping ${server_id}: uptime is under ${MIN_UPTIME_HOURS} hours."
    continue
  fi
  if ! get_player_count "${server_id}" player_count; then
    run_status=1
    continue
  fi
  if ((player_count > 0)); then
    log_info "Deferring ${server_id}: ${player_count} player(s) connected."
    continue
  fi

  uptime_hours="$((uptime_ms / 60 / 60 / 1000))"
  if pterodactyl_restart_server "${server_id}"; then
    if [[ "${DRY_RUN}" == "1" ]]; then
      log_dry_run "Server ${server_id} is empty after ${uptime_hours} hours of uptime."
    else
      log_success "Restarted ${server_id} after ${uptime_hours} hours of uptime while empty."
    fi
  else
    log_error "Pterodactyl rejected the uptime restart for ${server_id}."
    run_status=1
  fi
done

exit "${run_status}"
