# Cloudflare WARP Proxy

Official Cloudflare WARP client in an Ubuntu 24.04 container (`linux/amd64` and `linux/arm64`), exposing an out-of-the-box SOCKS5 proxy on `0.0.0.0:40000`.

## Quick Start

### Docker CLI

```sh
docker run -d --name warp --restart always \
  -p 40000:40000 \
  -v warp-data:/var/lib/cloudflare-warp \
  ghcr.io/trunkszi/cloudflare-warp:latest
```

### Docker Compose

```sh
docker compose up -d
```

### Verify

```sh
curl -fsSLx socks5h://127.0.0.1:40000 https://www.cloudflare.com/cdn-cgi/trace
```

## Configuration

All environment variables are optional and have working defaults:

| Variable | Default | Description |
| --- | --- | --- |
| `WARP_PORT` | `40000` | SOCKS5 listen port (`1`–`65535`) |
| `WARP_PROTOCOL` | `MASQUE` | Tunnel protocol: `MASQUE` or `WireGuard` |
| `WARP_MASQUE_OPTIONS` | `h3-with-h2-fallback` | `h3-with-h2-fallback`, `h3-only`, or `h2-only` |
| `WARP_LICENSE` | *(empty)* | Optional WARP+ license key |
| `WARP_CONNECTOR_TOKEN` | *(empty)* | Optional Zero Trust Connector token |
| `WARP_ENDPOINT` | *(empty)* | Custom tunnel endpoint (`IP:PORT` or `[IPv6]:PORT`) |
| `WARP_LOG_LEVEL` | `error` | `off`, `error`, `warn`, `info`, `debug`, or `trace` |
| `CHECK_URL` | `https://cloudflare.com/cdn-cgi/trace` | Health check URL |
| `SLEEP_SECONDS` | `60` | Seconds between health checks |
| `RESTART_AFTER_SECONDS` | `900` | Unhealthy duration before restarting `warp-svc` |

## Releases

GitHub Actions checks official Cloudflare APT packages (`noble` `amd64` and `arm64`) daily and automatically publishes multi-arch images (`latest`, `<version>`, `v<version>`, `<major>.<minor>`) to GHCR along with a matching [GitHub Release](https://github.com/trunkszi/cloudflare-warp/releases).
