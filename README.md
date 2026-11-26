# trust-no-cache: access control for internet-facing services that can't have a login screen

A small, hardened Debian VPS on the public internet. It runs a few self-hosted services, a DNS filter, a notification server, and a WireGuard tunnel that gives my devices a second way online when the home tunnel is down.

This repo documents *why* it's built the way it is. The guides in [`docs/`](docs/) cover the how, and [`configs/`](configs/) holds the sanitized configuration the host actually runs.

Everything here is written from the live host. Domains, IP addresses, the SSH port, the WireGuard subnet and user names are placeholders (`example.net`, `example.com`, documentation-range addresses).

## The constraint

Several of these services are used by apps, not clicked through in a browser: DNS lookups from phones, a notification app and feed-reader clients. An identity provider or login page in front of them doesn't degrade gracefully. It just breaks the client.

So access control moved down a layer. Before a request reaches a service, the host has to decide whether the source is trusted, and it has to make the same decision in three places that can't be allowed to drift apart: the firewall, the reverse proxy, and the VPN.

## One source of truth, enforced twice

My home connection has a dynamic IP, so a hardcoded allowlist entry is either stale within days or quietly wrong, trusting whoever the ISP hands that address to next.

The VPS asks the Cloudflare API, not DNS resolvers, for the current value of an A record my home router keeps updated. A systemd timer does this every five minutes. On a change, one script updates both the nftables allowlist set and Traefik's `ipAllowList` from the same value in the same run. There is one place that decides which IP is trusted, and both enforcement points read from it.

Three details make that safer than it sounds:

- **The static firewall config ships with an empty allowlist.** The live value exists only at runtime, filled in by the script after every boot. "No verified current IP" is the default state, not "whatever was true the last time someone edited a file."
- **The script verifies the live ruleset, not its own bookkeeping.** An earlier version trusted a state file. When a troubleshooting session cleared the live set, the script kept reporting success while nothing was enforced. It now checks that the address is really in the kernel's set on every run.
- **The Cloudflare token is read-only and locked to the VPS's addresses.** Even a read-only copy would reveal the home IP, so a leaked copy is useless anywhere else.

Details: [firewall-and-ddns-allowlist.md](docs/firewall-and-ddns-allowlist.md).

## Default deny, with a short list of ways in

Input and forwarded traffic are dropped unless a rule allows them.

| Path | Who can use it |
|---|---|
| SSH | The DDNS allowlist, two static fallback addresses (for when the DDNS mechanism is itself the broken part), and WireGuard clients |
| HTTPS (Traefik) | The DDNS allowlist and WireGuard clients. The static SSH addresses cannot reach it |
| WireGuard | Its own always-open UDP port, deliberately not dependent on the allowlist being correct |
| DNS | WireGuard clients only |

Traefik applies the same trust decision again, so a firewall mistake alone doesn't expose a service. WireGuard clients can reach Traefik, DNS, SSH and the internet, and nothing else: no private ranges, no client-to-client traffic, and nothing can open a new connection into the tunnel.

## Two VPNs on purpose

The simpler design would make this VPS another peer on my home VPN. I rejected it for two reasons that are really one:

- **Availability.** The home VPN ends at a residential connection. If these services depended on a route home, their uptime would be capped by my ISP and router.
- **Blast radius.** A server that accepts traffic from the internet shouldn't have a standing path into devices that don't. Joining the two networks would undo the segmentation before anything went wrong.

So this host runs its own independent WireGuard instance. It exists so that I can reach the server, and the internet through it, not so that the server can reach anything at home. The home side, with its per-device rules, and the reason I switch between the two by hand are in [narrow-tunnel](https://github.com/zacharyrichter/narrow-tunnel). The same rule shapes operations: the host holds no credentials for the home network, and its configuration is copied *out* by hand rather than pushed anywhere ([rebuild-from-config-repo.md](docs/rebuild-from-config-repo.md)).

## Detection, not just prevention

- A daily SHA-256 manifest of `/etc`, `/usr/bin`, `/usr/sbin` and `/boot`, with any difference sent as an alert.
- Weekly package-checksum verification (debsums).
- auditd with a CIS-derived rule set.
- Every alert goes to the host's own ntfy server, so alerting doesn't depend on the home network.

The integrity baseline lives on the machine it checks, so a careful root-level attacker could change both. It is there to catch drift, accidents and careless intruders, and I say so in the host doc.

## What this doesn't solve

IP-based trust is coarser than per-request authentication. Anyone behind my current public IP is implicitly trusted for the services that can't do application-level auth. I accepted that over breaking client compatibility, or over a VPN-only model for services meant to be reachable by lightweight clients.

The VPS is also outside my Renovate-managed fleet. Containers follow moving tags and update nightly, with an alert when anything changes. That is a deliberate trade for a host that can't hold credentials to the pipeline, and it is the one place I don't pin versions.

## Boot order is part of the security model

AdGuard Home binds DNS only to the WireGuard interface's address, so Docker must not start until `wg-quick` has finished. Left to systemd's defaults, that was a race. It is now an explicit ordering constraint, confirmed across a reboot, and the [postmortem](docs/postmortem-cascading-dns-failure.md) traces how it surfaced.

## Repo layout

```
docs/
  system-diagram.md                      one picture of everything above
  vps-host-hardening.md                  SSH, PAM, sysctl, audit, integrity, updates
  firewall-and-ddns-allowlist.md         nftables ruleset and the allowlist updater
  rebuild-from-config-repo.md            keeping a config copy, rebuilding from it
  postmortem-cascading-dns-failure.md    five-layer root-cause analysis
  services/                              Traefik, AdGuard Home, ntfy, FreshRSS
configs/                                 sanitized compose files, host files, scripts
archive/                                 retired guides, with the reason for each
```

## What this demonstrates

- Designing access control around a real client constraint instead of defaulting to an identity provider.
- Treating stale state and configuration drift as failure modes, in the self-verifying allowlist and the deliberately empty static config.
- Systemd ordering as part of the security model.
- Layered, independent controls (firewall, proxy, VPN separation, detection) that each assume the others can fail.
- Honest limits: each design page says what the control does not cover.
