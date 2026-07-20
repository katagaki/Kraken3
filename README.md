# Kraken

A remote-controlled browser that can be accessed from mobile devices via the local network or Tailscale.

## Running

The container drives headless Chromium over the DevTools protocol and serves a phone control page.

```sh
docker compose up -d --build
```

## Environment variables

- `KRAKEN_HOMEPAGE`: homepage for new tabs (default `https://www.startpage.com`)
- `KRAKEN_HTTP_PORT`: listen port for the UI and control WebSocket (default `8080`)
- `KRAKEN_SESSIONS_DIR`: where per-session profiles + downloads live (default `/data/sessions`)
- `KRAKEN_SINGLE_USER`: `1` locks Kraken to the first client that connects; every
  later client is refused. Default `0` (multi-user).
- `KRAKEN_MAX_SESSIONS`: max concurrent sessions in multi-user mode (default `10`).
- `KRAKEN_SESSION_TIMEOUT`: idle seconds before a session is reaped (default `300`).
- `KRAKEN_DISABLE_IP_ACL`: `1` disables the client IP allowlist (only if Kraken sits
  behind a trusted reverse proxy that already restricts access).

Everything is served on a single port: the control page over HTTP and the live
view over a WebSocket on the same origin (`/ws`).

## Access & sessions

- **Per-user sessions.** Each client gets its own isolated browser: a separate
  Chromium process with its own profile, tabs, and downloads. Session and refresh
  tokens are stored in `HttpOnly`, `SameSite=Lax` cookies and rotated on every
  request. A single-user mode (`KRAKEN_SINGLE_USER=1`) instead locks Kraken to the
  first client and refuses all others.
- **Idle cleanup.** A separate `kraken-reaper` process terminates a session's
  Chromium and deletes its directory after `KRAKEN_SESSION_TIMEOUT` seconds of
  inactivity.
- **Network allowlist.** Only clients on LAN / Tailscale / loopback ranges may
  connect; public-internet peers are rejected. This needs host networking (or a
  proxy that preserves the client IP) — with Docker bridge + published ports every
  client looks like the Docker gateway. **Still firewall the ports**; the allowlist
  is a safety net, not a substitute for not exposing the host publicly.

## Controls

- **Tab bar**: scrollable tabs; tap to switch, ✕ to close, + for a new tab. Popups
  open as new tabs.
- **Live view**: tap to click, drag to scroll, pinch to zoom.
- **Address bar**: address or search terms.
- **Paste/Keyboard**: send clipboard text, or forward iPhone keystrokes, into the
  focused field.
- **Downloads**: progress bars; save a finished file to the phone or delete it.
