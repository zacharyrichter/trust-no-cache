# Postmortem: a five-layer cascading failure (WireGuard → DNS → firewall automation)

**Status:** Resolved
**Severity:** High (loss of remote SSH access to a production VPS)
**Duration:** about 2.5 hours from first symptom to full resolution

---

## Summary

A routine fleet-wide package cleanup removed a dependency (`resolvconf`) that a WireGuard tunnel's DNS-push configuration relied on. The removal had no immediate effect. It surfaced on the next reboot, about two weeks later, as a locked-out SSH session with no obvious connection to its cause.

Tracing it back meant working through five independent layers: a firewall rule that appeared to be blocking access, a DNS resolver in a crash loop, a VPN tunnel that had failed to start, a missing system package, and, as the actual trigger, a maintenance action from weeks earlier that had shown no error at the time.

This write-up is about the diagnostic process more than the fix. Each individual fix was simple; the work was working out which layer was upstream of which.

---

## Impact

- SSH access to the VPS was unavailable for the whole incident. Recovery needed the provider's out-of-band console.
- The host's ad-blocking DNS resolver was down, and the dynamic-IP firewall allowlist automation failed silently for the same period.
- No data loss, no unauthorized access, and no outage beyond the host itself.

---

## Timeline

*(All times approximate, condensed from system logs.)*

- **T–2 weeks:** A fleet-wide package audit removes several packages flagged as unused, including `resolvconf`, on multiple hosts. No errors on any host.
- **T+0:00:** The host is rebooted during unrelated maintenance.
- **T+0:00:05:** `wg-quick` fails to bring up the WireGuard interface. Its DNS hooks call `resolvconf`, which no longer exists. Exit code 127.
- **T+0:00:15:** The DNS resolver container, which binds to the WireGuard interface's address, fails to bind (`cannot assign requested address`) and enters a crash-restart loop.
- **T+0:00:15 to T+0:47:00:** The systemd timer that keeps the dynamic-IP allowlist in sync with an external DNS record fires every five minutes and fails each time. It can't resolve the API hostname because the host's own resolver depends on the resolver that is down.
- **T+0:52:** An operator who is unaware of the above reboots the host again to troubleshoot an unrelated issue, then finds SSH completely unavailable.
- **T+0:55 to T+1:30:** Diagnosis proceeds layer by layer. Firewall rules are inspected first, because a drop-policy firewall is the most visible symptom, and they look correct. DNS is found to be broken host-wide. The resolver's logs show the bind failure. The WireGuard interface is found to be down entirely. Finally the WireGuard unit's own logs show the missing `resolvconf` binary.
- **T+1:35:** `resolvconf` is reinstalled and WireGuard comes up cleanly.
- **T+1:38:** The DNS resolver is restarted and binds successfully.
- **T+1:40:** DNS resolution is confirmed working host-wide.
- **T+1:45:** The allowlist automation is re-run by hand and self-heals once DNS is back.
- **T+2:30:** A second, unrelated bug turns up during verification. The automation compared its own cached state against the intended address and never checked that the address was actually present in the live firewall set. It could report success while enforcement had silently drifted. The logic was corrected in the same session.

---

## Root cause

`resolvconf` was removed because nothing on the host referenced it by name. It was in fact a dependency of `wg-quick`'s DNS-push feature, invoked from a hook rather than declared as a service dependency, so no `apt remove` dry run or dependency check would flag it. The failure stayed dormant for two weeks because nothing forced `wg-quick` to restart until the next reboot.

## Contributing factors

- **No systemd ordering between the container runtime and WireGuard.** Both started in parallel at boot. The resolver's bind depended on WireGuard already being up, but nothing enforced it, so one failed service became two.
- **No persistent allowlist, by design.** The allowlist is filled from an external source of truth on every boot rather than stored in a static config. An empty allowlist can't contain a stale address that an ISP has since reassigned, so this is a deliberate trade-off. It also meant the only way back in after this failure was the out-of-band console, because the static fallback was limited to a hardcoded address.
- **The automation's success logging was misleading.** It logged success when its last-known state matched its target, rather than re-verifying the enforcement point on every run. That hid how long the outage had lasted during triage.

## Resolution

1. Reinstalled `resolvconf` and confirmed that `wg-quick` started cleanly.
2. Restarted the DNS resolver and confirmed a clean bind and working resolution.
3. Decoupled the host's own DNS from the filtering resolver. The host now resolves through a public resolver directly, so a failure of the container can't take down name resolution for the host or the other containers.
4. Corrected the allowlist automation to verify live set membership on every run, so it self-heals from drift and not only from IP changes.
5. Documented the `resolvconf` and `wg-quick` dependency in the host's rebuild guide, together with a pre-removal dependency check for future cleanup passes, which is now part of the fleet's package-cleanup process.
6. Replaced the boot-time race with an explicit rule. A systemd drop-in (`wait-for-wg0.conf`) makes Docker start only after `wg-quick@wg0` has finished, using `Wants=` rather than `Requires=` so that a WireGuard failure costs only the DNS resolver. I confirmed it across a reboot: `wg-quick` finished at 6.82 s and Docker started at 6.99 s. Until this drop-in was added the ordering was a matter of timing, so the same race remained possible after the first four fixes.

## Action items

| Action | Status |
|---|---|
| Fix allowlist automation to verify live state, not cached state | Done |
| Decouple host DNS from the filtering resolver | Done |
| Document the `resolvconf` / `wg-quick` dependency | Done |
| Add a pre-removal dependency check to the fleet's package-cleanup process | Done |
| Add a systemd rule so Docker starts after the VPN tunnel is up | Done |
| Audit the other hosts for the same `resolvconf` removal and WireGuard DNS-push combination | Done |

---

## What this tested

None of the individual fixes took more than a line. What the incident tested was holding five unrelated-looking symptoms in one model and working backward through the dependency chain, instead of patching whichever symptom was most visible. The firewall looked broken, and it wasn't. The DNS resolver looked broken, and it was really a downstream victim. The real cause sat two weeks upstream, in a maintenance action that had produced no error when it happened. Log-based, layer-by-layer elimination is what found it.
