#!/bin/bash

set -e

# Kill any existing instances of warp-svc before starting a new one
if pkill -9 -x warp-svc >/dev/null 2>&1; then
    echo "Existing warp-svc process killed."
fi

# Start warp-svc in the background and redirect output to exclude dbus messages
warp-svc > >(grep -ivE "(dbus|DEBUG|INFO|WARN)") 2> >(grep -ivE "(dbus|DEBUG|INFO|WARN)" >&2) &

WARP_PID=$!

# Trap SIGTERM and SIGINT, and forward those signals to the warp-svc process
trap "echo 'Stopping warp-svc...'; kill -TERM $WARP_PID; exit" SIGTERM SIGINT

retry_warp_cli() {
    local description="$1"
    shift

    local attempt=0
    local max_attempts=12
    while true; do
        if warp-cli --accept-tos "$@" >/dev/null 2>&1; then
            echo "${description} OK."
            return 0
        fi

        attempt=$((attempt + 1))
        if [[ "${attempt}" -ge "${max_attempts}" ]]; then
            echo "${description} failed after ${max_attempts} attempts. Continuing..."
            return 0
        fi

        sleep 5
    done
}

echo "Ensuring WARP registration..."
registration_last_log_epoch=0
while true; do
    registration_output=""
    if registration_output="$(warp-cli --accept-tos registration new 2>&1)"; then
        echo "Registration ensured."
        break
    fi

    if echo "${registration_output}" | grep -qiE "already.*registered|existing.*registration|registration.*exists"; then
        echo "Already registered."
        break
    fi

    now_epoch="$(date +%s)"
    if (( now_epoch - registration_last_log_epoch >= 30 )); then
        echo "Waiting for warp-svc/warp-cli to be ready for registration..."
        registration_last_log_epoch="${now_epoch}"
    fi
    sleep 5
done

# Set the proxy port to 40000
retry_warp_cli "Set proxy port" proxy port 40000

# Set the mode to proxy
retry_warp_cli "Set mode to proxy" mode proxy

# Disable DNS log
retry_warp_cli "Disable DNS log" dns log disable

# Set the WARP_LICENSE if it is not empty
if [[ -n $WARP_LICENSE ]]; then
    retry_warp_cli "Apply WARP+ license" registration license "${WARP_LICENSE}"
fi

# Configure tunnel protocol to MASQUE (best-effort; command availability can vary by client version)
if warp-cli --accept-tos tunnel protocol set MASQUE >/dev/null 2>&1; then
    echo "Tunnel protocol set to MASQUE."
else
    echo "Failed to set tunnel protocol to MASQUE. Continuing..."
fi

if warp-cli --accept-tos tunnel masque-options set h3-with-h2-fallback >/dev/null 2>&1; then
    echo "MASQUE options set to h3-with-h2-fallback."
else
    echo "Failed to set MASQUE options. Continuing..."
fi

# Connect to the WARP service
connect_last_attempt_epoch=0
connect_last_log_epoch=0
while true; do
    if warp-cli --accept-tos status 2>/dev/null | grep -iq connected; then
        echo "Connected successfully."
        break
    fi

    now_epoch="$(date +%s)"
    if (( now_epoch - connect_last_attempt_epoch >= 30 )); then
        warp-cli --accept-tos connect >/dev/null 2>&1 || true
        connect_last_attempt_epoch="${now_epoch}"
    fi

    if (( now_epoch - connect_last_log_epoch >= 30 )); then
        echo "Waiting for connection..."
        connect_last_log_epoch="${now_epoch}"
    fi

    sleep 5
done

# Wait for warp-svc process to finish
wait $WARP_PID
