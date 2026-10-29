# Tailnet

A small macOS menu bar app for the open-source `tailscaled` daemon (Homebrew's `tailscale`).

The system `tailscaled` daemon can run without a user session after the startup disk is unlocked. With FileVault enabled, the first password screen after a restart unlocks the disk; this daemon and its saved state are unavailable until that unlock. Tailnet adds a user-session interface. Tailscale's saved connected/disconnected preference also persists across restarts.

> Unofficial. Tailnet is not affiliated with or endorsed by Tailscale Inc. "Tailscale" is a trademark of Tailscale Inc.

## Menu

The menu bar shows a chunky pixel sword, with a 12×12 grid rendered at 18 points. Explicit 1×/2× images align each block to three physical pixels on Retina displays. Errors appear in the tooltip and menu; the icon has exactly three states:

| Icon | Meaning |
|---|---|
| Solid sword | Connected |
| Solid sword, outward arrow | Connected through an exit node |
| Empty sword | Disconnected |

Menu-bar gestures:

- Single-click opens the menu after the system multi-click interval; right-click opens it immediately.
- Double-click enables without an exit node when disconnected, and disables when connected.
- Triple-click enables and applies the last successfully used exit node. With no remembered node, it enables without one. An offline or missing remembered node produces an error and leaves settings unchanged.

The last used node is stored separately in `~/Library/Application Support/Tailnet/last-exit-node.json`, using stable node identity. Normal enable clears the daemon's saved selection while retaining this history. Changes to exit routing and enabling share an independent rollback worker; clearing/preparing the selection happens before `tailscale up`.

The menu has:
- Status, plus this Mac's name and Tailscale IP (click to copy).
- **Connected**: enable without an exit node / disconnect. Or **Log In…** when signed out, which opens the sign-in link in your browser.
- **Exit Node ▸**: devices that offer an exit node, **None**, and **Allow Local Network Access**.
- Whether the daemon runs before login, and any `tailscaled` health warnings.
- **Unattended Remote Access Guide:** A status overview and guided steps for Tailscale, FileVault, RustDesk, sleep prevention, and testing after a restart. Checks identify what is known and what still needs a manual test. Optional security and technical details explain the trade-offs. The guide opens settings or documentation; it does not change security settings or install software.
- Open Admin Console, Refresh, Start at Login, Quit.

## Requirements

- macOS 14 or later, Apple silicon or Intel, and the Xcode command line tools (`xcode-select --install`).
- Homebrew's `tailscale` installed as a system daemon. Don't also run the official Tailscale app: two variants on one Mac conflict ([KB 1065](https://tailscale.com/kb/1065/macos-variants)).

  ```bash
  brew install tailscale
  ```

  ```bash
  sudo "$(brew --prefix)/bin/tailscaled" install-system-daemon
  ```

  ```bash
  sudo tailscale up
  ```

- Your user set as the daemon's operator, so Tailnet can make changes without sudo:

  ```bash
  sudo tailscale set --operator="$USER"
  ```

  Trade-off: any program running as you can then change Tailscale's settings or disconnect it. It gets no root access from this. Undo with `sudo tailscale set --operator=`. Without an operator, Tailnet still shows status, but changes need sudo.

## Build and install

```bash
./build.sh --install
```

```bash
open ~/Applications/Tailnet.app
```

`build.sh` compiles `Sources/` with `swiftc`, signs the app ad-hoc, and with `--install` copies it to `~/Applications`. **Start at Login** in the menu adds `~/Library/LaunchAgents/local.tailnet.agent.plist`.

## Exit nodes need a patched tailscaled on macOS

Stock `tailscaled` (checked on 1.104.1) can't use an exit node on macOS:

- It applies one with `route add -inet 0.0.0.0/0 -iface utunX`. macOS refuses that while the Wi-Fi default route exists, so traffic keeps going out over Wi-Fi.
- Clearing the exit node runs `route delete -inet 0.0.0.0/0 -iface utunX`, which removes the Mac's real default route until macOS restores it (about a minute in testing).
- Allow Local Network Access has no effect.

[`tailscaled-exitfix/`](tailscaled-exitfix/README.md) holds a small patch that fixes this by installing split routes (`0.0.0.0/1` and `128.0.0.0/1`), plus a script that builds and installs it. Tailnet requires the v4 patch marker in `/usr/local/bin/tailscaled`:

- **Patched:** the exit-node controls work.
- **Stock or an older patch:** the menu lists exit nodes but won't switch them. **None** stays clickable if one is set, so you can clear it.

## Safe routing changes

Before selecting an exit node, changing LAN access or reconnecting with a saved exit node, Tailnet starts an independent launchd rollback worker. It must acknowledge its recovery file before any settings change. The worker restores the previous exit node, LAN preference and stopped state after 60 seconds unless validation commits the change. It survives quitting or crashing the GUI and does not need internet access.

Validation requires the same direct HTTPS/DNS probes that worked before the change, the requested preferences, an online selected peer, and tunnel routes for both halves of the IPv4 internet. A failure triggers immediate restoration; the watchdog retries if that fails. This avoids treating Wi-Fi fallback as a working exit node. Clear remains available when internet is already down. If a deleted peer cannot be resolved, emergency clear falls back to no exit node rather than trying to restore an unusable selection.

HTTPS checks contact Apple and Cloudflare directly, bypassing proxy environment settings. Networks blocking both checks prevent a new exit-node selection. Normal Tailscale operation still fails closed if an established exit node later goes offline; Tailnet does not silently disable it.

A retained `~/Library/Application Support/Tailnet/exit-change/recovery.json` means every recovery attempt failed. Inspect it and restore the saved preferences with the `tailscale` CLI before removing the directory. Removing it during an active change disables recovery. Changes made in another client during the 60-second window may be overwritten by rollback.

Run `Tests/run.sh` for deterministic rollback/route-validation tests using mocked commands and an isolated temporary directory. Live routing tests require the system daemon installation and are separate from these tests.

Menu opening renders cached state immediately and refreshes in the background; it no longer blocks on two CLI calls.

## Command line

```
Tailnet --status | --menu
Tailnet --diagnose                               # save a private local network report
Tailnet --connect                                # enable without an exit node
Tailnet --connect-last-exit                      # enable with the last used exit node
Tailnet --disconnect
Tailnet --exit-node NAME|IP | --exit-node none     # NAME needs the v4 patched daemon
Tailnet --lan on|off
Tailnet --login-item on|off
```

The binary is `~/Applications/Tailnet.app/Contents/MacOS/Tailnet`.

## Uninstall

Quit Tailnet from its menu, then:

```bash
~/Applications/Tailnet.app/Contents/MacOS/Tailnet --login-item off
```

Then delete `~/Applications/Tailnet.app`. Tailnet doesn't change `tailscaled` itself.

## Security

- Tailnet runs as your user, never as root. It only runs the `tailscale` command; it doesn't open sockets or store credentials.
- The operator setting above is the one privilege trade-off.
- The exit-node fix means running a root daemon you built yourself: upstream source plus a short patch you can read first.

## Development

The app icon is rendered from the pixel map in `Sources/SwordIcon.swift`:

```bash
./tools/make-icon.sh
```

A gitleaks pre-commit hook scans staged changes for secrets and refuses author emails that aren't GitHub no-reply addresses. Turn it on once per clone with `git config core.hooksPath .githooks`. Or, if you use [pre-commit](https://pre-commit.com), run `pre-commit install` for the gitleaks check alone.

## License

MIT, see [LICENSE](LICENSE). `tailscaled-exitfix/exitfix.patch` modifies Tailscale and is under Tailscale's BSD-3-Clause licence ([tailscaled-exitfix/LICENSE](tailscaled-exitfix/LICENSE)).

## Contributor checks

Install scanners with `brew install gitleaks trufflehog` and enable the staged hook with `git config core.hooksPath .githooks`. The `.env.example` file is documentation only; no credentials or dotenv runtime configuration are required. Use a GitHub no-reply address or an intentional project identity for public commits.

Before publishing, scan both the source tree and every Git ref; the staged hook alone does not cover old commits. Do not ship `build/`, diagnostics, session notes, machine-specific configuration or Git history containing private data. This snapshot includes no CI workflow and does not grant Actions permissions.


## Connection diagnostics

Exit-node transactions automatically write private JSON reports under `~/Library/Logs/Tailnet/` (12 newest reports retained). The error dialog includes the report path. Reports contain the requested change, before/after state and daemon health, each HTTPS probe's exit code and DNS/TCP/TLS timings, route lookups including the interface-scoped physical transport route, validation reasons, and recovery results. Raw preference objects and HTTP response bodies are not recorded. Reports include command errors, private IP addresses and network details; review before sharing.

Use **Save Network Diagnostics…** in the menu, or `Tailnet --diagnose`, to collect a read-only report with netcheck, DNS/proxy configuration, routes and encrypted peer pings when an exit node is selected. It does not change VPN preferences or upload diagnostics.

Exitfix v4 preserves physical interface-scoped default routes before installing the tunnel halves. V3 could pass same-LAN tests while breaking transport to a remote exit node: `IP_BOUND_IF` sockets then returned `network is unreachable`. The exact v4 marker is required; earlier builds must be deliberately upgraded.

## Release and privacy

This repository contains rewritten project history with private operational notes removed and GitHub no-reply contributor metadata. Review authorship and local diagnostics before publishing. The environment examples are placeholders; Tailnet does not read dotenv files. The exit-node patch includes upstream BSD-3-Clause material; retain its license and follow `NOTICE.md` if distributing a daemon binary.

The exitfix installer can restart a root system daemon and interrupt network access. Review its script first and use `tailscaled-exitfix/build.sh --no-install` to build without installing. Keep a local recovery route.
