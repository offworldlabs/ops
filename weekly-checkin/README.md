# weekly-checkin

Posts a fixed weekly check-in prompt to a ClickUp chat channel on a schedule.

Deliberately cheap: one `curl` to the ClickUp v3 API, no LLM involved. The
message is static, so invoking a model per run would cost real money to emit a
constant.

## Setup

1. Generate a ClickUp API token (Settings → Apps → API Token; starts with `pk_`)
   and write it to a file readable only by the user running the job:

   ```bash
   install -m 600 /dev/null /root/weekly-checkin/.clickup_token
   printf '%s' 'pk_YOUR_TOKEN' > /root/weekly-checkin/.clickup_token
   ```

2. Copy `weekly-checkin.env.example` to `/root/weekly-checkin/weekly-checkin.env`
   (or anywhere, and set `CHECKIN_CONFIG`) and fill in your workspace and channel
   IDs. Both appear in the channel URL:
   `https://app.clickup.com/<workspace_id>/v/cn/<channel_id>`.

3. Check it without sending anything:

   ```bash
   DRY_RUN=1 SKIP_TIME_GUARD=1 ./weekly-checkin.sh
   ```

## Scheduling and the timezone guard

Debian/Ubuntu `cron` does not support `CRON_TZ` — that is a cronie (RHEL)
feature — so a target time in a specific timezone cannot be expressed in the
schedule itself when the host clock is set to something else.

The script works around this. The schedule fires at **every UTC hour the target
could land on**, and a guard inside the script drops the ones that are not
`CHECKIN_HOUR` in `CHECKIN_TZ`. For 09:00 Europe/London on a UTC host that means
08:00 and 09:00 UTC — London is UTC+1 under BST and UTC+0 under GMT, so exactly
one fires on any given run day, and the pair swaps automatically at each
changeover. Without the guard the nudge would silently drift by an hour twice a
year.

The crontab entry on the host, which runs the nudge weekly on Mondays:

```cron
0 8,9 * * 1 /opt/apps/ops/weekly-checkin/weekly-checkin.sh >> /root/weekly-checkin/cron.log 2>&1
```

The redirect is required: that host has no MTA, so unredirected cron stderr is
discarded.

## Behaviour

| Variable | Effect |
| --- | --- |
| `CHECKIN_CONFIG` | Path to the config file (default `/root/weekly-checkin/weekly-checkin.env`) |
| `SKIP_TIME_GUARD=1` | Post now, ignoring the scheduled-hour guard |
| `DRY_RUN=1` | Print the request that would be sent; send nothing |

Failures exit non-zero and are reported three ways — stderr, `logger` (system
log, tagged `weekly-checkin`), and a JSON line appended to `CHECKIN_LOG`:

```json
{"ts":"2026-08-10T21:55:44+00:00","ok":true,"http":201,"message_id":"...","channel":"..."}
```
