# Self-Hosted VPS: Access Control Without Auth Screens

A hardened, internet-facing Debian VPS running a small stack of self-hosted services
(search, video client backend, file transfer, DNS filtering) plus a WireGuard tunnel that
serves as a fallback VPN entry point when my primary home-network VPN is unreachable.

This document is about *why* the system is built the way it is, not a feature list. The
individual setup guides in [`docs/`](docs/) cover the how in full detail.

---

## The actual constraint

Every service on this box is reachable from the open internet, and most of them can't
sit behind a login screen. A metasearch engine and a video-client API backend are both
things that get *queried programmatically* — by search plugins, mobile apps, browser
extensions — not clicked through in a browser session. Bolting an auth challenge in front
of either one doesn't degrade gracefully; it just breaks the client. So the usual answer
to "how do I gate an internet-facing service" — put an identity provider in front of it —
wasn't available for a meaningful chunk of what's running here.

That pushed the access control problem down a layer: if it can't happen at the
application layer, it has to happen at the network layer instead. The whole box has to
decide, before a request even reaches a service, whether the source is trusted — and it
has to make that decision consistently across a plain TCP firewall, a reverse proxy, and
(for one specific case) a VPN tunnel, without three separate systems drifting out of sync
with each other.

There's a second constraint stacked on top of the first: this VPS is also a **fallback
VPN endpoint**. If my home network's primary VPN is unreachable — which, being terminated
at a residential connection, happens for reasons entirely outside my control — this is
how I get back in instead. That only works if this box's own reachability isn't itself
downstream of the thing it's meant to be a fallback for, which turned out to have
implications for how the two VPNs relate to each other structurally, not just for uptime.
More on that below.

## One source of truth, enforced twice

Given "network-layer, not application-layer," the next problem is that a home internet
connection doesn't have a static IP. A firewall rule allowlisting "my home IP" is either
stale within days, or — worse — silently wrong, allowing in whoever an ISP reassigns that
old IP to next. Baking a specific IP into a static config file is the wrong shape for
this problem entirely; the system needs a live, authoritative answer to "what is my
current home IP" every time it makes an access-control decision, not a config value
someone remembered to update.

**This is the piece I'm most pleased with:** the VPS doesn't ask "what's my home IP" by
resolving DNS and hoping the answer is fresh. It queries the Cloudflare API directly for
the current value of a DNS A record my home network's DDNS client keeps updated —
bypassing DNS caching and propagation entirely and reading the authoritative value at the
source. A systemd timer does this every five minutes, and on any change it does two
things atomically from the script's perspective: updates the `nftables` allowlist set
*and* updates Traefik's `ipAllowList` for the reverse-proxy layer, from the same single
value, in the same run. There's exactly one place "what IP is currently trusted" gets
decided, and both enforcement points read from it — they can't drift apart from each
other because there's only one source generating both updates.

The firewall's static config also deliberately ships with that allowlist **empty**. The
live, dynamic value only exists at runtime, populated fresh by the same script on every
boot. A stale IP baked into a config file is a liability, not a convenience — so the
architecture treats "no verified-current IP" as the correct default state rather than
"whatever was true last time someone edited a file."

The script also verifies its own enforcement on every run, not just its own bookkeeping —
it checks that the IP is actually present in the live firewall rule set, not just that it
*thinks* it already applied the change. That distinction turned out to matter: an
unrelated troubleshooting session once cleared the live rule set without the script's
internal state noticing, and the earlier version of the script would have reported
"success" indefinitely without the IP actually being enforced. Fixing that — verify the
real state, don't trust your own cache — is a small change with an outsized effect on
whether the system tells the truth about itself.

## Default-deny, with exactly two ways in

The firewall's baseline posture is deny-everything. Two paths back in exist deliberately:
the DDNS-tracked dynamic allowlist described above, and one hardcoded static IP as a true
fallback — the "what if the DDNS mechanism itself is the thing that's broken" case.
Everything else, including every Docker-published port, is reachable only through
Traefik, which applies the *same* IP-based trust decision a second time at the
application layer. A request has to clear both checks, generated from the same source, to
reach anything.

WireGuard sits alongside this rather than depending on it, by design — per the fallback-
VPN constraint above, the tunnel's own reachability can't be contingent on the dynamic
whitelist being correctly populated. It has its own narrow, always-open port, separate
from the IP-gated surface entirely.

## Two separate VPNs, on purpose

The obvious simplification would be to make this VPS just another peer on my existing
home-network VPN mesh — one set of tunnel configs, one network, less to maintain. I
rejected that, for two reasons that are really the same reason looked at from two
directions: availability and blast radius.

**Availability:** the primary home VPN terminates at a residential connection. Residential
uptime is worse than a VPS's in every dimension that matters — ISP outages, power loss,
router reboots, a residential IP change mid-session. If the services running on this box
depended on reachability back to a home gateway, their actual availability would be
bounded by my home internet connection's uptime, which defeats a large part of the reason
to run them on a VPS instead of at home in the first place. So this VPS runs its own
independent WireGuard instance, terminating on itself, with no routing dependency on the
home network being reachable at all.

**Blast radius:** setting uptime aside, bridging an internet-facing box directly into the
same VPN mesh as my home network creates a standing path from the open internet into my
home LAN if the VPS were ever compromised — however unlikely that is day to day, it's a
different trust tier than anything sitting behind a home router's NAT. A server that
accepts arbitrary traffic from the internet shouldn't have a network path back into
devices that don't. Collapsing that boundary by joining both into one mesh means the
segmentation decision has effectively already been undone before anything even goes
wrong. So the two stay structurally separate: this VPN exists so *I* can reach *this
server*, not so this server has a route into anything at home.

## What this doesn't solve, on purpose

IP-based trust is a coarser tool than per-request authentication — anyone sharing my
current public IP (a household member, in practice, since this is a home connection) is
implicitly trusted at the network layer for the services that can't do app-layer auth.
That's a real tradeoff, not an oversight: the alternative was either breaking client
compatibility for several services, or standing up a full mTLS/VPN-only model for
services that are explicitly meant to be reachable by lightweight, unauthenticated
clients. I chose to accept the coarser boundary rather than the broken functionality.

## Boot-order dependencies, made explicit

One service (a DNS resolver used for ad/tracker filtering) binds specifically to the
WireGuard tunnel's interface address. That created an implicit dependency — the container
runtime can't usefully start that service until the tunnel is up — that systemd doesn't
enforce by default; two independent units starting in parallel on boot is the default
assumption, not sequential-when-it-matters. That gap surfaced during a real incident
(see below) and is now an explicit ordering constraint rather than something that happens
to work most of the time.

---

## Repo layout

```
docs/
├── postmortem-cascading-dns-failure.md
├── server-hardening.md
├── firewall-ddns.md
├── monitoring-aide-logcheck-logdy.md
├── mailgun-relay.md
└── docker-auto-update.md
architecture.md
configs/
```

`docs/` covers the how — full command-by-command setup for each subsystem.
[`architecture.md`](architecture.md) is a visual diagram only — everything explained
above, mapped out. No new content there, just the picture.

Also included: a [postmortem](docs/postmortem-cascading-dns-failure.md) tracing the
boot-ordering gap mentioned above back through five layers to its actual root cause —
worth reading if you want to see the debugging process rather than just the end state.

---

## What this demonstrates

- Designing access control around a real client-compatibility constraint, not a default
  "add an identity provider" answer
- Treating configuration drift and stale state as first-class failure modes, not edge
  cases — both in the DDNS mechanism's self-verification and in the deliberately-empty
  static firewall config
- Reasoning about systemd unit dependencies and boot ordering as part of the security
  model, not just service configuration
- Log-based, layer-by-layer root-cause diagnosis under a live outage (see the postmortem)
