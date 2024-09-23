# warp-svc
Cloudflare WARP client as a socks5 server in docker

This dockerfile will create a docker image with official Cloudflare WARP client for linux and provides a socks5 proxy to use in other compaliant applications either in your local machine or by other docker containers in a docker compose or Kubernetes.

The official Cloudflare WARP client for Linux only listens on localhost for the socks proxy so you cannot use it in a docker container which need to bind on 0.0.0.0

## Features
* Register a new Cloudflare WARP account
* Configurable "families mode"
* Subscribe to Cloudflare WARP+

## How to use
The socks proxy in exposed on port `40000`

You can use these environment variables:
* `FAMILIES_MODE`: Use one of `off`, `malware` and `full` values. (Default: `off`)
* `WARP_LICENSE`: Put your WARP+ licesne.

You should mount `/var/lib/cloudflare-warp` directory of the container to your host to make you WARP account persistant. Notice that each WARP+ license is working only on 4 device so persisting the configuration is important!

### Using as a local proxy with Docker
```
docker run -d --name=warp --network host --restart=always -e FAMILIES_MODE=off -e WARP_LICENSE=xxxxxxxx-xxxxxxxx-xxxxxxxx -v ${PWD}/warp:/var/lib/cloudflare-warp ghcr.io/trunkszi/cloudflare-warp:latest
```
You can verify warp by visiting this url:
```
curl -x socks5h://127.0.0.1:40000 -sL https://cloudflare.com/cdn-cgi/trace | grep -iE "warp=(on|plus)"

warp=on or warp=plus
```
You can also use `warp-cli` command to control your connection:
```
docker exec warp warp-cli --accept-tos status

Status update: Connected
Success
```
### Using as a proxy for other containers with docker-compose

```
version: "3"
services:
  warp:
    image: ghcr.io/trunkszi/cloudflare-warp:latest
    expose:
    - 40000
    restart: always
    environment:
      WARP_LICENSE: xxxxxxxx-xxxxxxxx-xxxxxxxx
      FAMILIES_MODE: off
    volumes:
    - ./warp:/var/lib/cloudflare-warp
  app:
    image: <app-image>
    depends_on:
    - warp
    environment:
      proxy: warp:40000
```

