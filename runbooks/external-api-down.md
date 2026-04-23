# `ExternalApiDown`

## Symptoms

```promql
probe_success{job="blackbox"} == 0   # for 5 minutes
```

A blackbox HTTP probe against one of `https://core.newebpay.com/API/QueryTradeInfo` / `https://server.hengfu-i.com/` / `https://accounts.google.com/o/oauth2/v2/auth` has been failing for 5 min.

Cross-reference `ppc_external_api_duration_seconds{result=~"error|timeout"}` for application-side confirmation — the probe can fail while app calls keep working (CDN / cached route) or vice versa.

## Likely causes

1. Vendor outage — check their status page first
2. PPClub EC2 outbound broken (NAT gateway / security group / DNS)
3. SSL cert on their side expired (`openssl s_client` shows expiry)
4. Cloudflare tunnel broken on our side → monitoring-prod can't run probe (affects blackbox probe only; PPClub-originated calls unaffected)
5. Rate limiting — we've been getting 429s and blackbox interprets as "down"

## Immediate actions

From central Grafana / monitoring-prod host:

```bash
# Which target is failing
# In Grafana explore:
probe_success{job="blackbox"} == 0
probe_http_status_code{job="blackbox"}         # look at the code
probe_ssl_earliest_cert_expiry{job="blackbox"} # unix ts of cert expiry

# Probe manually from the same host
curl -v -m 10 https://core.newebpay.com/API/QueryTradeInfo 2>&1 | head
openssl s_client -connect core.newebpay.com:443 -servername core.newebpay.com </dev/null 2>&1 | openssl x509 -noout -enddate
```

Check vendor status pages:

- NewebPay: (no public status page — search their announcements)
- Hengfu: (internal notifications only — ping their support)
- Google OAuth: https://status.cloud.google.com

From PPClub EC2 (is it just us or is the app affected too):

```bash
# Did PPClub's actual calls also start failing?
# In central Grafana / Loki:
{product="ppclub"} |= "NewebPay" |~ "Status.*FAIL|timeout|error"
```

If PPClub's own calls are fine but blackbox isn't → probe config issue, not a true outage.

## Verify recovery

```
probe_success{job="blackbox",target="..."} == 1
```

## Post-incident

- Record start/end from `up{}` and the app-side error rate to size the blast radius
- If SSL cert was the cause, add a higher-priority alert: `(probe_ssl_earliest_cert_expiry - time()) / 86400 < 14` — warn 14 days ahead
- If vendor-side: document in ops channel when and how long; useful for support case follow-ups
