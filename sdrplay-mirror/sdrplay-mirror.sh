#!/bin/bash
# Upload a local file into the SDRplay mirror bucket (Cloudflare R2).
#
# Why this exists: owl-os's OS image build downloads the SDRplay RSP API
# installer and SDRconnect directly from sdrplay.com at build time. That
# stopped being reliable — sdrplay.com restructured its downloads behind a
# WordPress Download Manager -> personal SharePoint redirect with a per-request
# token, and separately sits behind a Cloudflare bot challenge that an
# unattended build cannot solve. This script re-populates a small R2 bucket we
# control so owl-os's build depends on a stable, static URL instead.
#
# This is a manually-invoked operator action, not a scheduled chore: there is
# nothing to run periodically, only to re-run by hand if SDRplay's upstream
# file changes again.
#
# Configuration comes from an env file (default
# /root/sdrplay-mirror/sdrplay-mirror.env, or set SDRPLAY_MIRROR_CONFIG). No
# credentials or account-specific values live in this file, so it is safe to
# keep in a public repository. See sdrplay-mirror.env.example.
#
# Requires: aws CLI on PATH (any recent version - only used against R2's
# S3-compatible API, never AWS itself).
#
# Usage:
#   ./sdrplay-mirror.sh <local-file> <object-key> [<local-file> <object-key> ...]
#   DRY_RUN=1 ./sdrplay-mirror.sh SDRplay_RSP_API-Linux-3.15.run sdrplay-api/SDRplay_RSP_API-Linux-3.15.run

set -euo pipefail

CONFIG_FILE="${SDRPLAY_MIRROR_CONFIG:-/root/sdrplay-mirror/sdrplay-mirror.env}"

# Environment variables take precedence over the config file, same pattern as
# every other script here - capture any that are already set, source the
# file, then re-apply the captured ones on top.
_overrides="$(declare -p R2_ENDPOINT R2_BUCKET R2_CREDENTIALS_FILE SDRPLAY_MIRROR_LOG 2>/dev/null || true)"
if [ -r "${CONFIG_FILE}" ]; then
    # shellcheck disable=SC1090
    . "${CONFIG_FILE}"
fi
if [ -n "${_overrides}" ]; then
    eval "${_overrides}"
fi

R2_CREDENTIALS_FILE="${R2_CREDENTIALS_FILE:-/root/sdrplay-mirror/.r2_credentials}"
SDRPLAY_MIRROR_LOG="${SDRPLAY_MIRROR_LOG:-/root/sdrplay-mirror/log.jsonl}"

# Failures must be visible. Cron discards stderr when no MTA is installed, so
# also write to the system log and to the JSONL log - matches weekly-checkin.
fail() {
    local msg="$1"
    echo "sdrplay-mirror FAILED: ${msg}" >&2
    logger -t sdrplay-mirror -p user.err "FAILED: ${msg}" 2>/dev/null || true
    printf '{"ts":"%s","ok":false,"error":%s}\n' \
        "$(date -Is)" "$(printf '%s' "${msg}" | jq -Rs .)" >> "${SDRPLAY_MIRROR_LOG}" 2>/dev/null || true
    exit 1
}

command -v aws >/dev/null 2>&1 || fail "aws CLI not found on PATH"

[ -n "${R2_ENDPOINT:-}" ] || fail "R2_ENDPOINT is not set (config: ${CONFIG_FILE})"
[ -n "${R2_BUCKET:-}" ]   || fail "R2_BUCKET is not set (config: ${CONFIG_FILE})"
[ "$#" -ge 2 ] && [ $(( $# % 2 )) -eq 0 ] || fail "usage: $0 <local-file> <object-key> [<local-file> <object-key> ...]"

[ -r "${R2_CREDENTIALS_FILE}" ] || fail "credentials file not readable: ${R2_CREDENTIALS_FILE}"
# shellcheck disable=SC1090
. "${R2_CREDENTIALS_FILE}"
[ -n "${AWS_ACCESS_KEY_ID:-}" ]     || fail "AWS_ACCESS_KEY_ID not set in ${R2_CREDENTIALS_FILE}"
[ -n "${AWS_SECRET_ACCESS_KEY:-}" ] || fail "AWS_SECRET_ACCESS_KEY not set in ${R2_CREDENTIALS_FILE}"
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY

while [ "$#" -gt 0 ]; do
    local_file="$1"; object_key="$2"; shift 2

    [ -r "${local_file}" ] || fail "local file not readable: ${local_file}"

    if [ "${DRY_RUN:-0}" = "1" ]; then
        echo "sdrplay-mirror DRY RUN — nothing uploaded"
        echo "  ${local_file} -> s3://${R2_BUCKET}/${object_key} (endpoint ${R2_ENDPOINT})"
        continue
    fi

    OUTPUT="$(aws s3 cp "${local_file}" "s3://${R2_BUCKET}/${object_key}" \
        --endpoint-url "${R2_ENDPOINT}" 2>&1)" \
        || fail "upload failed for ${object_key}: ${OUTPUT}"

    SIZE="$(stat -c%s "${local_file}" 2>/dev/null || stat -f%z "${local_file}")"
    printf '{"ts":"%s","ok":true,"object":"%s","bytes":%s}\n' \
        "$(date -Is)" "${object_key}" "${SIZE}" >> "${SDRPLAY_MIRROR_LOG}"
    echo "sdrplay-mirror OK: ${object_key} (${SIZE} bytes)"
done
