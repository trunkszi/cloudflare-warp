#!/bin/bash

set -u

CHECK_URL="${CHECK_URL:-https://www.cloudflare.com/cdn-cgi/trace/}"
SOCKS_PROXY="${SOCKS_PROXY:-socks5h://127.0.0.1:40000}"
SLEEP_SECONDS="${SLEEP_SECONDS:-60}"
RESTART_AFTER_SECONDS="${RESTART_AFTER_SECONDS:-900}"
FAIL_SINCE_FILE="${FAIL_SINCE_FILE:-/tmp/warp-health-fail-since}"

curl_check_once() {
  curl \
    --connect-timeout 5 \
    -m 10 \
    -fsSLx "${SOCKS_PROXY}" \
    "${CHECK_URL}" \
    | grep -qE "warp=(on|plus)"
}

curl_check_watchdog() {
  curl \
    --retry 8 \
    -m 45 \
    -fsSLx "${SOCKS_PROXY}" \
    "${CHECK_URL}" \
    | grep -qE "warp=(on|plus)"
}

restart_warp_svc() {
  supervisorctl restart warp-svc >/dev/null 2>&1 || true
}

now_epoch_seconds() {
  date +%s
}

clear_fail_since() {
  rm -f "${FAIL_SINCE_FILE}" 2>/dev/null || true
}

record_fail_since_if_missing() {
  local now
  now="$(now_epoch_seconds)"
  echo "${now}" > "${FAIL_SINCE_FILE}" 2>/dev/null || true
}

maybe_restart_after_unhealthy_duration() {
  local now fail_since elapsed

  now="$(now_epoch_seconds)"
  fail_since="$(cat "${FAIL_SINCE_FILE}" 2>/dev/null || true)"

  if ! [[ "${fail_since}" =~ ^[0-9]+$ ]]; then
    record_fail_since_if_missing
    return 0
  fi

  elapsed=$(( now - fail_since ))
  if (( elapsed >= RESTART_AFTER_SECONDS )); then
    echo "WARP unhealthy for ${elapsed}s (>=${RESTART_AFTER_SECONDS}s). Restarting warp-svc..."
    restart_warp_svc
    echo "${now}" > "${FAIL_SINCE_FILE}" 2>/dev/null || true
  fi
}

once_mode=false
case "${1:-}" in
  --once)
    once_mode=true
    shift
    ;;
esac

if [[ "${once_mode}" == "true" ]]; then
  curl_check_once
  exit $?
fi

sleep_pid=""

# Trap SIGTERM and SIGINT to handle graceful shutdown
trap '[[ -n "${sleep_pid}" ]] && kill "${sleep_pid}" 2>/dev/null || true; exit 0' SIGTERM SIGINT

# Main loop
while true; do
  # Check if the Cloudflare WARP service is working
  if curl_check_watchdog; then
    clear_fail_since
  else
    maybe_restart_after_unhealthy_duration
  fi
  # Sleep in a way that allows interruption
  sleep "${SLEEP_SECONDS}" &
  sleep_pid=$!
  wait $sleep_pid
done
