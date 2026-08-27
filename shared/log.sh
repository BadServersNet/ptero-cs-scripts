#!/usr/bin/env bash

log_info() {
  printf '%s\n' "$*"
}

log_success() {
  printf '✓ %s\n' "$*"
}

log_warn() {
  printf 'warning: %s\n' "$*" >&2
}

log_error() {
  printf 'error: %s\n' "$*" >&2
}

log_dry_run() {
  printf '[dry-run] %s\n' "$*"
}

