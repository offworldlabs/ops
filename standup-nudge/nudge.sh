#!/bin/bash
# Post a fixed standup nudge to a ClickUp chat channel.
#
# Deliberately cheap: one curl to the ClickUp v3 API, no LLM involved. For a
# static message, invoking an LLM per run would cost real money to emit a
# constant.
#
# Configuration comes from an env file (default /root/standup/nudge.env, or set
# STANDUP_CONFIG). No credentials or site-specific IDs live in this file, so it
# is safe to keep in a public repository. See nudge.env.example.
#
# Usage:
#   ./nudge.sh                  # respects the scheduled-hour guard
#   SKIP_TIME_GUARD=1 ./nudge.sh    # post now, ignoring the guard
#   DRY_RUN=1 SKIP_TIME_GUARD=1 ./nudge.sh   # show the request, post nothing

set -euo pipefail

CONFIG_FILE="${STANDUP_CONFIG:-/root/standup/nudge.env}"

# Environment variables take precedence over the config file. Capture any that
# are already set, source the file, then re-apply the captured ones on top.
_overrides="$(declare -p CLICKUP_WORKSPACE_ID CLICKUP_CHANNEL_ID STANDUP_MESSAGE \
    STANDUP_TZ STANDUP_HOUR CLICKUP_TOKEN_FILE STANDUP_LOG 2>/dev/null || true)"
if [ -r "${CONFIG_FILE}" ]; then
    # shellcheck disable=SC1090
    . "${CONFIG_FILE}"
fi
if [ -n "${_overrides}" ]; then
    eval "${_overrides}"
fi

# Optional settings, defaulted before anything can fail so that fail() can log.
CLICKUP_TOKEN_FILE="${CLICKUP_TOKEN_FILE:-/root/standup/.clickup_token}"
STANDUP_LOG="${STANDUP_LOG:-/root/standup/log.jsonl}"
STANDUP_TZ="${STANDUP_TZ:-Europe/London}"
STANDUP_HOUR="${STANDUP_HOUR:-09}"

# Failures must be visible. Cron discards stderr when no MTA is installed, so
# also write to the system log and to the JSONL log.
fail() {
    local msg="$1"
    echo "standup-nudge FAILED: ${msg}" >&2
    logger -t standup-nudge -p user.err "FAILED: ${msg}" 2>/dev/null || true
    printf '{"ts":"%s","ok":false,"error":%s}\n' \
        "$(date -Is)" "$(printf '%s' "${msg}" | jq -Rs .)" >> "${STANDUP_LOG}" 2>/dev/null || true
    exit 1
}

# Required settings.
[ -n "${CLICKUP_WORKSPACE_ID:-}" ] || fail "CLICKUP_WORKSPACE_ID is not set (config: ${CONFIG_FILE})"
[ -n "${CLICKUP_CHANNEL_ID:-}" ]   || fail "CLICKUP_CHANNEL_ID is not set (config: ${CONFIG_FILE})"
[ -n "${STANDUP_MESSAGE:-}" ]      || fail "STANDUP_MESSAGE is not set (config: ${CONFIG_FILE})"

# Scheduled-hour guard. Cron cannot express a timezone on Debian/Ubuntu (no
# CRON_TZ), so when the host clock is not in STANDUP_TZ the schedule must fire
# at every UTC hour the target could land on, and this guard drops the rest.
# For Europe/London that means 08:00 and 09:00 UTC, since London is UTC+1 under
# BST and UTC+0 under GMT. Without this the nudge would silently shift by an
# hour at each DST changeover.
if [ "${SKIP_TIME_GUARD:-0}" != "1" ] && [ "$(TZ="${STANDUP_TZ}" date +%H)" != "${STANDUP_HOUR}" ]; then
    exit 0
fi

[ -r "${CLICKUP_TOKEN_FILE}" ] || fail "token file not readable: ${CLICKUP_TOKEN_FILE}"
TOKEN="$(tr -d '\r\n' < "${CLICKUP_TOKEN_FILE}")"
[ -n "${TOKEN}" ] || fail "token file is empty: ${CLICKUP_TOKEN_FILE}"

URL="https://api.clickup.com/api/v3/workspaces/${CLICKUP_WORKSPACE_ID}/chat/channels/${CLICKUP_CHANNEL_ID}/messages"
BODY="$(jq -nc --arg c "${STANDUP_MESSAGE}" \
    '{type:"message",content:$c,content_format:"text/plain"}')"

if [ "${DRY_RUN:-0}" = "1" ]; then
    echo "standup-nudge DRY RUN — nothing sent"
    echo "  POST ${URL}"
    echo "  body ${BODY}"
    echo "  auth token from ${CLICKUP_TOKEN_FILE} (${#TOKEN} chars)"
    exit 0
fi

RESPONSE="$(curl -sS --max-time 30 -w $'\n%{http_code}' -X POST "${URL}" \
    -H "Authorization: ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d "${BODY}" 2>&1)" || fail "curl failed: ${RESPONSE}"

HTTP_CODE="$(printf '%s' "${RESPONSE}" | tail -n1)"
PAYLOAD="$(printf '%s' "${RESPONSE}" | sed '$d')"

case "${HTTP_CODE}" in
    200|201) ;;
    *) fail "HTTP ${HTTP_CODE} from ClickUp: ${PAYLOAD}" ;;
esac

MSG_ID="$(printf '%s' "${PAYLOAD}" | jq -r '.data.id // .id // "unknown"' 2>/dev/null || echo unknown)"

printf '{"ts":"%s","ok":true,"http":%s,"message_id":"%s","channel":"%s"}\n' \
    "$(date -Is)" "${HTTP_CODE}" "${MSG_ID}" "${CLICKUP_CHANNEL_ID}" >> "${STANDUP_LOG}"

echo "standup-nudge OK: posted message ${MSG_ID}"
