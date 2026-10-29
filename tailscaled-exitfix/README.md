# tailscaled exit-node fix for macOS

`exitfix.patch` makes exit nodes work with the open-source `tailscaled` on macOS. Without it (checked on 1.104.1), choosing an exit node doesn't route any traffic, and clearing one removes the Mac's default route for about a minute.

## The bug

`tailscaled`'s macOS router (`wgengine/router/osrouter/router_userspace_bsd.go`) installs every route with `route add -inet <prefix> -iface utunX`. For an exit node, the routes are `0.0.0.0/0` and `::/0`. With LAN access off, they also include the Mac's LAN prefixes, such as `192.168.1.0/24`.

- macOS already has those exact routes on Wi-Fi, so `route add` fails with "File exists" and traffic stays on Wi-Fi.
- `tailscaled` still records them as installed. When the exit node is cleared, it runs `route delete -inet 0.0.0.0/0 -iface utunX`, which deletes Wi-Fi's default route.
- The router also ignores `LocalRoutes`, the list that implements Allow Local Network Access, so that setting did nothing.

## The fix

The v4 patch adds `router_darwin_split.go` and updates route application and cleanup in `Set` and `Close`. On macOS, a default route, or a route equal to one of the Mac's own on-link prefixes, is installed as its two halves:

- `0/0` becomes `0.0.0.0/1` and `128.0.0.0/1`; `::/0` becomes `::/1` and `8000::/1`.
- `192.168.1.0/24` becomes two `/25` routes.

Other VPNs do the same. The halves win by longest-prefix match, add without conflict, and deleting them never touches Wi-Fi's routes. Link-local prefixes are skipped. Before a LAN prefix is split, the patch installs an interface-scoped copy on Wi-Fi (`route add -ifscope en0`). Interface-bound sockets, including tailscaled's transport sockets, can use it. That keeps WireGuard to peers on the same LAN, often the exit node itself, off the tunnel. Without it, LAN access off made a LAN exit node unreachable.

- **LAN access off:** the LAN halves go into the tunnel, so LAN traffic leaves through the exit node.
- **LAN access on:** Tailscale doesn't send LAN prefixes at all, and Wi-Fi's `/24` beats the tunnel's `/1`, so the LAN stays local.
- **tailscaled's own traffic:** its sockets are bound to Wi-Fi (`net/netns`, `IP_BOUND_IF`), so its WireGuard, DERP and control traffic doesn't loop into the tunnel.

## Transport protection and reliability

- Install the physical, interface-scoped transport route before adding tunnel routes. Abort the route update if that protection fails.
- Treat an existing direct, interface-scoped route as OS-owned and leave it alone.
- Track only successfully added tunnel routes. Failed adds cannot make a later cleanup delete another VPN's route.
- Retain failed scoped-route deletions for retry and clean up owned scoped routes when the router closes.
- Unit tests cover deterministic prefix splitting, route ownership, error propagation, cleanup retries and validation of existing scoped routes.

V4 also reads the kernel routing table for physical IPv4/IPv6 default gateways and installs interface-scoped copies before any tunnel halves. Without a scoped default, sockets bound to Wi-Fi can have no route to a remote WireGuard endpoint after `/1` routes appear, even though the unscoped physical default still exists. V3 protected same-LAN transport only. Gateway and interface are validated before reusing an existing scoped default; OS-owned routes are never claimed for deletion. Tests cover default-route classification, IPv6 gateway zones, and scoped gateway/interface validation.

The installed daemon must contain `tailscaled-darwin-exitfix-v4`. Older v1 builds can break same-LAN exit nodes when local network access is disabled. The GUI should not treat the generic marker prefix as sufficient.

## Build and install

```bash
./build.sh
```

The script:
1. Clones the tag and commit from the Homebrew formula and checks the commit.
2. Applies the patch and runs its tests.
3. Builds with Homebrew's version ldflags and checks for the marker string `tailscaled-darwin-exitfix-v4`.
4. Runs `sudo tailscaled install-system-daemon` (one password prompt).
5. Pins Homebrew's `tailscale`, so `brew upgrade` doesn't move the CLI ahead of the daemon.

Run it at the keyboard: the daemon restarts. tailscaled-gui finds the marker in `/usr/local/bin/tailscaled` and turns its exit-node controls on.

## Trade-offs

- You run a root daemon that you built: upstream source plus the patch, which you can read in `exitfix.patch`.
- Updates aren't automatic. To update: `brew unpin tailscale && brew upgrade tailscale`, then `./build.sh` again. If the patch stops applying, upstream has changed that file, so check whether they fixed it.
- DNS is configured by the daemon. With an exit node selected, DNS may use that peer's DNS proxy; diagnostics must distinguish failed DNS from failed HTTPS or peer transport.

## Undo

```bash
sudo "$(brew --prefix)/bin/tailscaled" install-system-daemon
```

```bash
brew unpin tailscale
```

That puts back the stock Homebrew daemon. tailscaled-gui then turns its exit-node controls off again.

## Live validation

The unit tests verify the routing logic without changing system routes. They cannot prove packet forwarding, DNS, same-LAN peer transport or network changes on a particular Mac. Before live tests, arm an independent timed rollback that restores the previous exit-node and LAN-access preferences. Test both LAN-access settings, verify that traffic actually exits through the selected node, then clear it and confirm the physical default route still exists. A daemon install restarts networking; keep the previous binary available for rollback.
