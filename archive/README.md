# Archive

Guides that described tools or components I no longer run. They are kept for the history of the design, not as current guidance. Each was retired for a reason.

| Retired guide | Why it was retired |
|---|---|
| [`logcheck-setup.md`](logcheck-setup.md) | logcheck replaced by the `integrity-check` timer, with alerts on ntfy |
| [`monitoring-aide-logcheck-logdy.md`](monitoring-aide-logcheck-logdy.md) | AIDE and logcheck replaced by the simpler `integrity-check` timer and debsums; Logdy removed |
| [`mailgun-relay.md`](mailgun-relay.md) | Outbound mail relay no longer needed: alerts go to the host's own ntfy through a `sendmail` shim |
| [`docker-auto-update.md`](docker-auto-update.md) | Described an earlier version tied to AIDE database updates. Superseded by the current `docker-update.sh` in [`configs/host/opt/`](../configs/host/opt/) |
| [`server-hardening.md`](server-hardening.md) (old, single-file version) | Also covered fail2ban, which I removed along with the tools above. Replaced by [`docs/vps-host-hardening.md`](../docs/vps-host-hardening.md) and [`docs/firewall-and-ddns-allowlist.md`](../docs/firewall-and-ddns-allowlist.md), which are written from the live host |
