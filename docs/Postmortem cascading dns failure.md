# Postmortem: Diagnosing a Five-Layer Cascading Failure (WireGuard → DNS → Firewall Automation)

**Status:** Resolved
**Severity:** High (loss of remote SSH access to a production VPS)
**Duration:** ~2.5 hours from first symptom to full resolution

---

## Summary

A routine fleet-wide package cleanup removed a dependency (`resolvconf`) that a WireGuard
tunnel's DNS-push configuration relied on. The removal had no immediate effect — it only
surfaced on the next reboot, five services and roughly two hours later, as a locked-out
SSH session with no obvious connection to its actual cause. Tracing the failure back to
its root required working backward through five independent layers: a firewall rule that
appeared to be blocking access, a DNS resolver in a crash loop, a VPN tunnel that had
failed to start, a missing system package, and — the actual trigger — a maintenance action
performed weeks earlier that had no visible effect at the time.

This writeup focuses on the diagnostic process rather than the fix itself, since the fix
in each individual layer was simple; the actual work was correctly identifying which layer
was upstream of which.

---

## Impact

- SSH access to the VPS was unavailable for the duration of the incident. Recovery required
  out-of-band console access (KVM/QEMU) rather than SSH.
- Downstream: a self-hosted ad-blocking DNS resolver was unavailable, and a dynamic-IP
  firewall whitelist automation silently failed for the same window, though this had no
  user-facing impact beyond the SSH lockout itself.
- No data loss, no unauthorized access, no service outage beyond the host itself.

---

## Timeline

*(All times approximate, condensed from system logs)*

- **T–2 weeks:** A fleet-wide package audit removes several packages flagged as unused,
  including `resolvconf`, across multiple hosts. No immediate errors on any host.
- **T+0:00** Host is rebooted as part of unrelated maintenance.
- **T+0:00:05** `wg-quick` fails to bring up the WireGuard interface — its `PostUp`/`PreDown`
  hooks call `resolvconf`, which no longer exists. Exit code 127.
- **T+0:00:15** A DNS resolver container, configured to bind to the WireGuard interface's
  address for its listener, fails to bind (`cannot assign requested address`) and enters
  a crash-restart loop.
- **T+0:00:15 – T+0:47:00** A systemd timer responsible for keeping a dynamic-IP firewall
  whitelist in sync with an external DNS record fires every 5 minutes and fails silently
  each time — it cannot resolve the external API endpoint, since the host's own resolver
  is down.
- **T+0:52** An operator (unaware of the above) attempts to reboot the host again to
  troubleshoot an unrelated issue, then discovers SSH access is completely unavailable.
- **T+0:55 – T+1:30** Diagnosis proceeds layer by layer: firewall rules are inspected first
  (the most visible symptom — a DROP-policy firewall with an apparently correct
  configuration), then DNS resolution is found to be broken host-wide, then the resolver's
  own logs are checked and show the bind failure, then the WireGuard interface is found to
  be down entirely, and finally the WireGuard service's own logs reveal the missing
  `resolvconf` binary as the actual root cause.
- **T+1:35** `resolvconf` reinstalled; WireGuard interface brought up cleanly.
- **T+1:38** DNS resolver restarted; binds successfully.
- **T+1:40** DNS resolution confirmed working host-wide.
- **T+1:45** Firewall whitelist automation re-run manually; confirmed it self-heals
  correctly once DNS is restored.
- **T+2:30** A secondary, unrelated bug is discovered during verification: the whitelist
  automation's self-healing logic only compared its own cached state against the
  *intended* IP, never verified the IP was still actually present in the live firewall
  rule set. This meant the automation could report "success" while the enforcement target
  had silently drifted — a gap that had nothing to do with the original incident but was
  surfaced by the same verification pass. Script logic corrected in the same session.

---

## Root Cause

`resolvconf` was removed during a routine package cleanup because nothing on the host
appeared to reference it directly by name. In practice, it was a transitive dependency of
`wg-quick`'s optional DNS-push feature — invoked internally by a hook, not listed as a
visible service dependency anywhere an `apt remove` dry-run or dependency check would
surface it. The failure was dormant for two weeks because nothing in that window forced
`wg-quick` to actually restart until the next reboot.

## Contributing Factors

- **No systemd ordering dependency** between the container runtime (and the DNS resolver
  it hosts) and the WireGuard service. Both started in parallel on boot; the resolver's
  successful bind depended on WireGuard already being up, but nothing enforced that
  ordering. This turned a single failed service into two.
- **A stale firewall state file wasn't being persisted to disk**, by design — the
  whitelist is deliberately populated fresh on every boot from an external source of
  truth rather than trusting a static config. This is a deliberate security tradeoff
  (an empty allowlist can't contain a stale, no-longer-yours IP address after an ISP
  reassignment), but it meant the *only* path back into the firewall after this specific
  failure was out-of-band console access — there was no static fallback beyond one
  hardcoded secondary IP.
- **The automation's own "success" logging was misleading.** It logged success based on
  its last known state matching its target state, not based on re-verifying the actual
  enforcement point on every run. This masked the outage's true duration during initial
  triage and was the secondary bug found during verification.

## Resolution

1. Reinstalled `resolvconf` and confirmed `wg-quick` started cleanly.
2. Manually restarted the DNS resolver; confirmed clean bind and resolution.
3. Added an explicit systemd ordering dependency (`After=`/`Wants=`) so the container
   runtime — and anything inside it that binds to the VPN interface — cannot start before
   WireGuard is confirmed up.
4. Corrected the whitelist automation to verify live enforcement-set membership on every
   run, not just its own cached state, so it self-heals from drift instead of just
   drift from IP changes.
5. Documented the dependency explicitly in the host's setup guide, including the exact
   commands to check whether a package is a hidden dependency of a systemd unit's hooks
   before removing it in future cleanup passes.

## Action Items

| Action | Status |
|---|---|
| Add systemd boot-ordering dependency (container runtime after VPN tunnel) | Done |
| Fix whitelist automation to verify live state, not cached state | Done |
| Document the resolvconf/wg-quick dependency in the setup guide | Done |
| Add a pre-removal dependency check step to the package-cleanup process fleet-wide | Done |
| Audit remaining hosts for the same `resolvconf` removal + WireGuard DNS-push combination | Pending |

---

## What this actually tested

The interesting part of this incident wasn't any single fix — each one was a one-line
change. What it tested was the ability to hold five unrelated-looking symptoms in a
single mental model and work backward through the actual dependency chain rather than
patching whichever symptom was most visible first. The firewall looked broken. It wasn't.
The DNS resolver looked broken. It wasn't, really — it was a downstream victim. The real
fix was two weeks upstream of the visible failure, in a maintenance action that produced
no error at the time it happened. Log-based, layer-by-layer elimination — not guesswork —
is what got there.