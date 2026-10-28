# tailscaled exit-node fix for macOS

`exitfix.patch` makes exit nodes work with the open-source `tailscaled` on macOS. Without it (checked on 1.104.1), choosing an exit node doesn't route any traffic, and clearing one removes the Mac's default route for about a minute.

## The bug

`tailscaled`'s macOS router (`wgengine/router/osrouter/router_userspace_bsd.go`) installs every route with `route add -inet <prefix> -iface utunX`. For an exit node, the routes are `0.0.0.0/0` and `::/0`. With LAN access off, they also include the Mac's LAN prefixes, such as `192.168.1.0/24`.

- macOS already has those exact routes on Wi-Fi, so `route add` fails with "File exists" and traffic stays on Wi-Fi.
- `tailscaled` still records them as installed. When the exit node is cleared, it runs `route delete -inet 0.0.0.0/0 -iface utunX`, which deletes Wi-Fi's default route.
- The router also ignores `LocalRoutes`, the list that implements Allow Local Network Access, so that setting did nothing.

## The fix

The patch adds `router_darwin_split.go` and changes one line in `Set`. On macOS, a default route, or a route equal to one of the Mac's own on-link prefixes, is installed as its two halves:

- `0/0` becomes `0.0.0.0/1` and `128.0.0.0/1`; `::/0` becomes `::/1` and `8000::/1`.
- `192.168.1.0/24` becomes two `/25` routes.

Other VPNs do the same. The halves win by longest-prefix match, add without conflict, and deleting them never touches Wi-Fi's routes. Link-local prefixes are skipped. When a LAN prefix is split, the patch also adds an interface-scoped copy on Wi-Fi (`route add -ifscope en0`). Only sockets pinned to Wi-Fi use it, which means only tailscaled's own. That keeps WireGuard to peers on the same LAN, often the exit node itself, off the tunnel. Without it, LAN access off made a LAN exit node unreachable.

- **LAN access off:** the LAN halves go into the tunnel, so LAN traffic leaves through the exit node.
- **LAN access on:** Tailscale doesn't send LAN prefixes at all, and Wi-Fi's `/24` beats the tunnel's `/1`, so the LAN stays local.
- **tailscaled's own traffic:** its sockets are bound to Wi-Fi (`net/netns`, `IP_BOUND_IF`), so its WireGuard, DERP and control traffic doesn't loop into the tunnel.

## Build and install

```bash
./build.sh
```

The script:
1. Clones the tag and commit from the Homebrew formula and checks the commit.
2. Applies the patch and runs its tests.
3. Builds with Homebrew's version ldflags and checks for the marker string `tailscaled-darwin-exitfix-v2`.
4. Runs `sudo tailscaled install-system-daemon` (one password prompt).
5. Pins Homebrew's `tailscale`, so `brew upgrade` doesn't move the CLI ahead of the daemon.

Run it at the keyboard: the daemon restarts. Tailnet finds the marker in `/usr/local/bin/tailscaled` and turns its exit-node controls on.

## Trade-offs

- You run a root daemon that you built: upstream source plus this 133-line patch, which you can read in `exitfix.patch`.
- Updates aren't automatic. To update: `brew unpin tailscale && brew upgrade tailscale`, then `./build.sh` again. If the patch stops applying, upstream has changed that file, so check whether they fixed it.
- DNS isn't managed by `tailscaled` on macOS. With an exit node, public resolvers (such as `1.1.1.1`) are reached through the exit node. A resolver on your LAN is reached directly while LAN access is on.

## Undo

```bash
sudo "$(brew --prefix)/bin/tailscaled" install-system-daemon
```

```bash
brew unpin tailscale
```

That puts back the stock Homebrew daemon. Tailnet then turns its exit-node controls off again.
