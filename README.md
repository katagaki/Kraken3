# Kraken

A remote-controlled browser that can be accessed from mobile devices via the local network or Tailscale.

## Run on macOS

```sh
swift run
```

Renders through an invisible WKWebView and shows a server control panel window (homepage, downloads). Downloads land in `Downloads/` next to `Package.swift`.

## Run in Docker

The container build has no UI: it drives headless Chromium over the DevTools protocol instead of WKWebView. The phone control page and protocol are identical.

```sh
docker build -t kraken .
docker run -d --name kraken \
  -p 8080:8080 -p 8081:8081 \
  -v "$PWD/Downloads:/downloads" \
  kraken
```

Or `docker compose up -d`.

Environment variables:

- `KRAKEN_DOWNLOADS`: where downloads are stored (default `/downloads`, mount a volume there)
- `KRAKEN_HOMEPAGE`: homepage for new tabs (default `https://www.startpage.com`)
- `KRAKEN_HTTP_PORT`, `KRAKEN_WS_PORT`: listen ports (defaults 8080, 8081)

The control page always connects to WebSocket port 8081 on the host, so keep the external mapping `8081:8081`.

## Controls

- **Tab bar**: scrollable tabs; tap to switch, ✕ to close, + for a new tab. Popups
  open as new tabs.
- **Live view**: tap to click, drag to scroll, pinch to zoom.
- **URL bar**: address or search terms.
- **Paste / Keyboard**: send clipboard text, or forward iPhone keystrokes, into the
  focused field.
- **Downloads**: progress bars; save a finished file to the phone or delete it.
