#!/usr/bin/env bash

load_dotenv_values() {
  local env_path="$1"
  shift
  local allowed_names=("$@")
  local line
  local key
  local value
  local allowed_name
  local is_allowed

  if [[ ! -f "${env_path}" ]]; then
    printf 'Environment file was not found: %s\n' "${env_path}" >&2
    return 1
  fi

  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line%$'\r'}"

    if [[ -z "${line//[[:space:]]/}" || "${line}" =~ ^[[:space:]]*# ]]; then
      continue
    fi

    if [[ ! "${line}" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=(.*)$ ]]; then
      continue
    fi

    key="${BASH_REMATCH[2]}"
    value="${BASH_REMATCH[3]}"
    is_allowed=0

    for allowed_name in "${allowed_names[@]}"; do
      if [[ "${key}" == "${allowed_name}" ]]; then
        is_allowed=1
        break
      fi
    done

    if [[ "${is_allowed}" != "1" ]]; then
      continue
    fi

    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"

    if [[ "${value}" =~ ^\"(.*)\"$ || "${value}" =~ ^\'(.*)\'$ ]]; then
      value="${BASH_REMATCH[1]}"
    fi

    if [[ ! -v "${key}" || -z "${!key}" ]]; then
      printf -v "${key}" '%s' "${value}"
      export "${key}"
    fi
  done <"${env_path}"
}

load_project_env() {
  local env_path="$1"

  load_dotenv_values \
    "${env_path}" \
    PTERO_URL \
    PTERO_API_KEY \
    PTERO_SERVER_IDS \
    PLAYER_COUNT_API_URL \
    PLAYER_COUNT_MISSING_IS_EMPTY \
    MIN_UPTIME_HOURS \
    GAME_UPDATE_COOLDOWN_MINUTES \
    GAME_UPDATE_VERIFY_ATTEMPTS \
    GAME_UPDATE_VERIFY_INTERVAL_SECONDS \
    PTERO_REQUEST_DELAY_SECONDS \
    PTERO_GET_RETRIES
}
