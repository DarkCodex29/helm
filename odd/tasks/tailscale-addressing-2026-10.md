# tailscale-addressing-2026-10

Audit outcome: Tailscale is the right transport for this project; the defect is
in how the project teaches and detects its use. Baseline `089f30c` on
`feat/ux-pendings-2026-10`, clean tree, 1348/1348 tests.

## The defect

`README.md:121` instructs creating the profile with `tailscale ip -4` and says
explicitly "Usá la IP de Tailscale, no la de la LAN". A Tailscale IP is stable
per NODE REGISTRATION, not per machine: a reinstall, a logout/login, or a new
tailnet entry issues a new one. That already cost one misdiagnosed bug, where a
profile still held `100.64.0.9` while the host answered on
`100.64.0.1`, and it read as a network failure.

MagicDNS is the stable identifier and is already enabled on the owner's tailnet.

## Measured evidence (owner's Mac, 2026-10-03)

Identifiers below are REDACTED to documentation placeholders, because this
repository is public. The shapes, field names, sizes and the trailing dot are
verbatim from the real measurement; only addresses and names were swapped.

```text
MagicDNSEnabled: true
MagicDNSSuffix:  tailnet-example.ts.net
Self.DNSName:    "example-host.tailnet-example.ts.net."   <- trailing dot
TailscaleIPs:    ["100.64.0.1", "fd7a:115c:a1e0::1"]
RunSSH:          false
```

`tailscale status --peers=false --json` is the command to use: it carries
`Self.DNSName` and `TailscaleIPs`, and omits the `Peer` map, so its size does
not grow with the tailnet. Measured 3142 bytes here against 4456 for the full
status. `--self --json` does NOT drop peers and was rejected for that reason.

Comparing the connect host against `TailscaleIPs` is exact. Do not infer
Tailscale from the `100.64.0.0/10` CGNAT range: that block is shared with
NetBird and some ISPs.

## Security consequence that is not optional to mention

Host key pins are keyed by host STRING
(`known_hosts_service.dart:775`: `helm_known_host_v2_<host>:<port>:<keyType>`).
Moving a profile from an IP to a MagicDNS name creates a NEW entry, so it is a
silent first contact (`firstSeen`), not a mismatch alarm. The README must tell
the user to verify the fingerprint against `ssh-keygen -lf` on the Mac, which
is byte-comparable since `44e4622`.

## Tasks

- [ ] 1. Teach MagicDNS instead of the IP in the README
  - Surfaces: `README.md`
  - Keep the existing Spanish voseo style of the file.
  - Must keep the real reason the IP advice existed: a LAN IP stops working off
    the home WiFi. MagicDNS keeps that benefit and adds stability.
  - Must disclose the silent re-pin above.
  - Commit: pending

- [ ] 2. Advise when a profile connects by Tailscale IP instead of MagicDNS
  - Surfaces: `lib/core/host/host_diagnostics.dart`,
    `lib/core/host/host_advisory.dart`, `lib/core/host/host_advisor.dart`,
    `lib/features/terminal/data/terminal_session.dart`, `test/core/host/**`
  - Follows `evaluateTailscaleInterception` exactly: display-only, never
    executes remediation, `unknown` on an unreadable signal, never `ok`.
  - Needs the connect host threaded into the check; existing `evaluate*`
    methods take no arguments and `HostAdvisor.collect` iterates zero-arg
    closures.
  - Same pass updates the Tailscale comments this audit turned from
    UNVERIFIED into measured fact (see task 3's note).
  - Commit: pending

- [ ] 3. Retire stale claims that outlived their evidence
  - Surfaces: `lib/core/host/host_diagnostics.dart`, `lib/features/**`,
    `pubspec.yaml`
  - `host_diagnostics.dart:~96` states "tailscale is not installed on the real
    host" and `:110` marks `tailscale debug prefs` UNVERIFIED. Both are now
    measurable and measured.
  - 10 comments across `lib/` cite dartssh2 2.16.0 while the project runs
    3.3.1. Some are legitimately historical ("2.16.0 passed MD5, 3.3.1 passes
    UTF-8") and must stay; others assert CURRENT behavior verified against the
    old version and must be re-verified or re-worded. Audit, do not sweep.
  - `pubspec.yaml:118` justifies `flutter_launcher_icons: ios: false` with "No
    Runner.xcodeproj in this repo", untrue since March.
  - Commit: pending

## Out of scope, recorded deliberately

- Migrating off Tailscale. NetBird, ZeroTier, Headscale, raw WireGuard and
  Cloudflare Tunnel were each weighed against a one-user, two-device setup;
  every advantage they hold is one this project does not use, and ZeroTier
  additionally has no MagicDNS equivalent, which is the exact feature that
  fixes this defect.
- Mosh. It is the real answer to a mobile client losing its session on a
  WiFi-to-cellular switch, but there is no Dart implementation and adopting it
  means replacing the transport.
- Deleting the revoked `8JLH4JPUY3` Keychain certificate. Destructive and
  outside the repository; needs its own explicit authorization.
