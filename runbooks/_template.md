# `<AlertName>`

Paste this into the `runbook_url` field of a Prometheus rule. One file per rule.

## Symptoms

What the alert sees and what the user sees. Expression and the annotation text go here verbatim.

## Likely causes

Bulleted list, most-likely first. Keep each entry one sentence.

## Immediate actions (copy-paste commands)

```bash
# Commands to diagnose fast. Work from "is it actually happening" → "where exactly" → "stop the bleeding".
```

## Verify recovery

```
# PromQL / LogQL / curl that proves the alert condition is false again.
```

## Post-incident

- Link to incident doc / ticket
- Data to gather before state is lost (running container logs, db snapshot, ...)
- What to change so this doesn't reoccur
