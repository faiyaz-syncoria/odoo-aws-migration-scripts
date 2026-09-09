import json
import re
import urllib.request
from datetime import datetime, timedelta, timezone

import boto3

WEBHOOK_URL = "https://chat.googleapis.com/v1/spaces/AAQAUn9qr8w/messages?key=AIzaSyDdI0hCZtE6vySjMm-WEfRq3CPzqKqqsHI&token=S8x8idNBPp4jayLEyf14IIgz2EQIf7IdiGWufx2Rb5A"

# Alarms whose alarm-message alone is already self-explanatory (single metric,
# named threshold) don't need a log lookup - only the log-pattern-based
# app-errors alarm benefits from it.
LOG_BACKED_ALARMS = {
    "mermaid-pools-production-app-errors": "/mermaid-pools/production/odoo",
}

# Ordered (first match wins). Each pattern is checked against the raw log
# text pulled from the alarm's own evaluation window. Add a new entry here
# whenever a new root cause gets diagnosed by hand, so the next occurrence
# explains itself.
KNOWN_CAUSES = [
    (
        re.compile(r"AADSTS50011"),
        "Microsoft/Outlook OAuth token refresh failed (AADSTS50011) - Azure's "
        "app registration is still missing the redirect URI "
        "`https://hub.mermaidpools.com/microsoft_outlook/confirm`. Needs an "
        "Azure AD admin to add it (app 69ada66d-7c2e-4bbc-bc7d-6628a42310b7). "
        "Not fixable from the AWS/Odoo side. See IMPLEMENTATION_LOG.md open item 13.",
    ),
    (
        re.compile(r"WRONG_VERSION_NUMBER"),
        "IMAP TLS handshake blip connecting to Outlook's mail server during "
        "fetchmail. Historically self-heals on the very next ~5-minute cycle - "
        "no action needed unless it starts recurring back-to-back. See "
        "IMPLEMENTATION_LOG.md §6 item 32.",
    ),
    (
        re.compile(r"livemode must begin with|payment_stripe.*HTTPError", re.S),
        "Stripe webhook registration rejected a non-https callback URL. This "
        "was root-caused and fixed 2026-09-09 (nginx missing "
        "X-Forwarded-Host, commit f24aebe) - if it's firing again, that fix "
        "may have regressed; check the nginx config first.",
    ),
    (
        re.compile(r"Invalid field '([^']+)' on model '([^']+)'"),
        None,  # filled in dynamically below with the captured names
    ),
    (
        re.compile(r"column ([\w.]+) does not exist"),
        None,  # filled in dynamically below
    ),
]

# A generic "SomeException: message" line, used only when nothing above matched.
GENERIC_EXCEPTION_RE = re.compile(r"^([\w.]+(?:Error|Exception|Warning)): (.+)$", re.M)

logs_client = boto3.client("logs")


def _classify(raw_text):
    for pattern, explanation in KNOWN_CAUSES:
        m = pattern.search(raw_text)
        if not m:
            continue
        if explanation is not None:
            return explanation
        if m.re.pattern.startswith("Invalid field"):
            field, model = m.group(1), m.group(2)
            return (
                f"ORM rejected a read() for field `{field}` on model `{model}` - "
                "that field doesn't exist there. Usually a UI/widget bug asking "
                "for the wrong field name. Check what action triggered it."
            )
        if m.re.pattern.startswith("column"):
            col = m.group(1)
            return (
                f"Missing column `{col}` - looks like schema drift between a "
                "SQL view and its ORM model. A targeted `-u <module>` on the "
                "owning module usually fixes this."
            )

    generic_matches = GENERIC_EXCEPTION_RE.findall(raw_text)
    if generic_matches:
        exc_type, exc_msg = generic_matches[-1]
        return f"Unrecognized error - `{exc_type}: {exc_msg[:200]}`. Worth a manual look."

    return None


def _fetch_window_text(log_group, state_change_time, period_seconds):
    end = state_change_time + timedelta(seconds=60)
    start = state_change_time - timedelta(seconds=period_seconds + 120)
    try:
        resp = logs_client.filter_log_events(
            logGroupName=log_group,
            startTime=int(start.timestamp() * 1000),
            endTime=int(end.timestamp() * 1000),
            limit=500,
        )
    except Exception:
        return ""
    return "\n".join(e.get("message", "") for e in resp.get("events", []))


def _format_message(msg):
    alarm_name = msg.get("AlarmName")
    if alarm_name is None:
        return None

    state = msg.get("NewStateValue", "?")
    reason = msg.get("NewStateReasonData") or msg.get("NewStateReason", "")
    region = msg.get("Region", "")
    icon = "🔴" if state == "ALARM" else ("✅" if state == "OK" else "⚪")
    header = f"{icon} *{alarm_name}* -> {state}"
    test_prefix = "🧪 TEST -- " if msg.get("_test") else ""

    cause = None
    if state == "ALARM" and alarm_name in LOG_BACKED_ALARMS:
        try:
            sct = datetime.fromisoformat(msg["StateChangeTime"].replace("Z", "+00:00"))
        except (KeyError, ValueError):
            sct = datetime.now(timezone.utc)
        period = msg.get("Trigger", {}).get("Period", 300)
        window_text = _fetch_window_text(LOG_BACKED_ALARMS[alarm_name], sct, period)
        if window_text:
            cause = _classify(window_text)

    lines = [test_prefix + header]
    if cause:
        lines.append(f"Likely cause: {cause}")
    else:
        lines.append(reason)
    lines.append(f"Region: {region}")
    return "\n".join(lines)


def handler(event, context):
    for record in event.get("Records", []):
        raw = record["Sns"]["Message"]
        try:
            msg = json.loads(raw)
        except (json.JSONDecodeError, TypeError):
            text = raw
        else:
            text = _format_message(msg) or raw

        body = json.dumps({"text": text}).encode("utf-8")
        req = urllib.request.Request(
            WEBHOOK_URL, data=body, headers={"Content-Type": "application/json"}
        )
        with urllib.request.urlopen(req, timeout=10) as resp:
            resp.read()
    return {"statusCode": 200}
