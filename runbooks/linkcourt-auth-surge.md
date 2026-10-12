# LinkCourt 401 / 429 surges

Rules: `LinkCourt401Surge`, `LinkCourt401SurgeByHandler`, `LinkCourt429Surge`
(all `severity=Medium`, `notification_mode=shadow` until canary review).

## Symptoms

- `LinkCourt401Surge`: `sum by (product) (increase(http_requests_total{product="ppclub",status="401"}[15m])) > 500` for 10m.
  Unauthenticated or expired-session traffic is far above baseline, possibly spread across many endpoints.
- `LinkCourt401SurgeByHandler`: the same per `handler` `> 300` for 10m. One endpoint is being hammered; the route template is in the alert.
- `LinkCourt429Surge`: `sum by (product, handler) (increase(http_requests_total{product="ppclub",status="429"}[15m])) > 30` for 5m.
  The application rate limiter is rejecting a burst on one endpoint.

Baseline (2026-10-12): the slots scraper sends about 168 unauthenticated
`/api/v2/courts/slots` requests per round (3 runs x 14 dates x 4 hosts within
about 3 minutes, every about 32 minutes), so one 15m window peaks near 168.
Other 401s are dozens per day and 429s are rare. Once Cloudflare blocks the
scraper, the 401 baseline drops; revisit thresholds during canary review.

## Likely causes

- A new or returning scraper calling member-only APIs without a token.
- Credential stuffing or session probing against login/session endpoints.
- A frontend or app release that drops or expires the session token (real users; check `fetch_site` and `ua`).
- A misconfigured client or integration retrying a 401/429 in a loop.

## Immediate actions (copy-paste commands)

In Grafana (Prometheus):

```promql
# Which handlers and methods
topk(10, sum by (handler, method, status) (
  increase(http_requests_total{product="ppclub", status=~"401|429"}[15m])
))
```

On Prod02 (`request_complete` lines for 401/429 include `client_ip`, `peer`,
`cf_ray`, `country`, `auth`, `fetch_site` and `ua`):

```bash
sudo journalctl -u linkcourt.service --since "-30min" | grep -E 'status=(401|429)' | tail -50

# Top sources and user agents
sudo journalctl -u linkcourt.service --since "-30min" | grep -E 'status=(401|429)' \
  | grep -oE 'client_ip=[^ ]+' | sort | uniq -c | sort -rn | head
sudo journalctl -u linkcourt.service --since "-30min" | grep -E 'status=(401|429)' \
  | grep -oE 'ua="[^"]*"' | sort | uniq -c | sort -rn | head
```

Decide:

- Non-browser UA, `fetch_site=-`, `auth=none`, few IPs or one ASN: block or
  challenge at Cloudflare following PPClub `docs/todo/anti-scraping-plan.md`
  (custom rules and rate-limit rule steps). Do not block the monitoring and
  health paths listed there.
- Real browsers (`fetch_site=same-origin`, normal UA, many IPs): treat as an
  app/auth regression; check the latest LinkCourt release before touching
  Cloudflare.
- 429 from real users: the limiter threshold may be too low for the
  endpoint; raise it in the app rather than at Cloudflare.

## Verify recovery

```promql
sum by (handler) (increase(http_requests_total{product="ppclub", status=~"401|429"}[15m]))
```

Cloudflare: Security -> Events, filter by the rule you added and confirm the
blocked traffic matches the source seen in the journal.

## Post-incident

- Record source IPs/ASN, UA, Cloudflare rule IDs and the time window in the PPClub work log.
- If the new baseline is clearly lower, propose lower thresholds in SkyEye with updated rule tests.
