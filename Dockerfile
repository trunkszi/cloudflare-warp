# syntax=docker/dockerfile:1
FROM ubuntu:24.04 AS builder
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends gcc libc6-dev && \
    rm -rf /var/lib/apt/lists/*
RUN <<'SH'
cat > /tmp/bindany.c <<'C'
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <dlfcn.h>
#include <errno.h>
#include <linux/netlink.h>
#include <linux/rtnetlink.h>
#include <stdlib.h>
#include <sys/socket.h>

static int (*real_bind)(int, const struct sockaddr *, socklen_t);
static int (*real_setsockopt)(int, int, int, const void *, socklen_t);
static ssize_t (*real_recv)(int, void *, size_t, int);
static ssize_t (*real_recvfrom)(int, void *, size_t, int, struct sockaddr *, socklen_t *);
static ssize_t (*real_recvmsg)(int, struct msghdr *, int);
static long warp_port = 40000;

__attribute__((constructor)) static void initialize(void) {
    real_bind = dlsym(RTLD_NEXT, "bind");
    real_setsockopt = dlsym(RTLD_NEXT, "setsockopt");
    real_recv = dlsym(RTLD_NEXT, "recv");
    real_recvfrom = dlsym(RTLD_NEXT, "recvfrom");
    real_recvmsg = dlsym(RTLD_NEXT, "recvmsg");
    const char *value = getenv("WARP_PORT");
    if (value) {
        char *end;
        long port = strtol(value, &end, 10);
        warp_port = (*value && !*end && port > 0 && port <= 65535) ? port : -1;
    }
}

int bind(int sockfd, const struct sockaddr *addr, socklen_t addrlen) {
    if (!real_bind) {
        errno = ENOSYS;
        return -1;
    }
    if (addr && addrlen >= sizeof(sa_family_t)) {
        if (addr->sa_family == AF_INET && addrlen >= sizeof(struct sockaddr_in)) {
            const struct sockaddr_in *sin = (const struct sockaddr_in *)addr;
            if (sin->sin_addr.s_addr == htonl(INADDR_LOOPBACK) &&
                ntohs(sin->sin_port) == warp_port) {
                struct sockaddr_in copy = *sin;
                copy.sin_addr.s_addr = htonl(INADDR_ANY);
                return real_bind(sockfd, (const struct sockaddr *)&copy, sizeof(copy));
            }
        } else if (addr->sa_family == AF_INET6 && addrlen >= sizeof(struct sockaddr_in6)) {
            const struct sockaddr_in6 *sin6 = (const struct sockaddr_in6 *)addr;
            if (IN6_IS_ADDR_LOOPBACK(&sin6->sin6_addr) && ntohs(sin6->sin6_port) == warp_port) {
                struct sockaddr_in6 copy = *sin6;
                copy.sin6_addr = in6addr_any;
                return real_bind(sockfd, (const struct sockaddr *)&copy, sizeof(copy));
            }
        }
    }
    return real_bind(sockfd, addr, addrlen);
}

int setsockopt(int fd, int level, int option, const void *value, socklen_t length) {
    if (!real_setsockopt) { errno = ENOSYS; return -1; }
    int result = real_setsockopt(fd, level, option, value, length);
    if (result == -1 && (errno == EPERM || errno == EACCES) && level == SOL_SOCKET &&
        (option == SO_MARK || option == SO_BINDTODEVICE)) {
        errno = 0;
        return 0;
    }
    return result;
}

static ssize_t patch_netlink_ack(int fd, void *buffer, ssize_t length) {
    int saved_errno = errno;
    struct sockaddr_storage address;
    socklen_t address_length = sizeof(address);
    if (buffer && length >= (ssize_t)NLMSG_SPACE(sizeof(struct nlmsgerr)) &&
        getsockname(fd, (struct sockaddr *)&address, &address_length) == 0 &&
        address.ss_family == AF_NETLINK) {
        struct nlmsghdr *header = buffer;
        if (header->nlmsg_type == NLMSG_ERROR &&
            header->nlmsg_len >= NLMSG_LENGTH(sizeof(struct nlmsgerr)) &&
            header->nlmsg_len <= (size_t)length) {
            struct nlmsgerr *error = NLMSG_DATA(header);
            /* Proxy traffic uses userspace sockets; no policy route is required. */
            if (error->msg.nlmsg_type == RTM_NEWRULE &&
                (error->error == -EPERM || error->error == -EACCES)) {
                error->error = 0;
                header->nlmsg_len = NLMSG_LENGTH(sizeof(struct nlmsgerr));
                errno = 0;
                return (ssize_t)header->nlmsg_len;
            }
        }
    }
    errno = saved_errno;
    return length;
}

ssize_t recv(int fd, void *buffer, size_t length, int flags) {
    if (!real_recv) { errno = ENOSYS; return -1; }
    ssize_t received = real_recv(fd, buffer, length, flags);
    return received <= (ssize_t)length ? patch_netlink_ack(fd, buffer, received) : received;
}

ssize_t recvfrom(int fd, void *buffer, size_t length, int flags,
                 struct sockaddr *address, socklen_t *address_length) {
    if (!real_recvfrom) { errno = ENOSYS; return -1; }
    ssize_t received = real_recvfrom(fd, buffer, length, flags, address, address_length);
    return received <= (ssize_t)length ? patch_netlink_ack(fd, buffer, received) : received;
}

ssize_t recvmsg(int fd, struct msghdr *message, int flags) {
    if (!real_recvmsg) { errno = ENOSYS; return -1; }
    ssize_t received = real_recvmsg(fd, message, flags);
    if (received > 0 && message->msg_iovlen && (size_t)received <= message->msg_iov[0].iov_len)
        return patch_netlink_ack(fd, message->msg_iov[0].iov_base, received);
    return received;
}
C
mkdir -p /usr/local/lib
gcc -shared -fPIC -O2 -Wall -Wextra -Werror /tmp/bindany.c -o /usr/local/lib/libbindany.so -ldl
SH

FROM ubuntu:24.04
ARG WARP_VERSION=""
ENV PYTHONDONTWRITEBYTECODE=1
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      ca-certificates curl gnupg python3 dbus iproute2 && \
    curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | \
      gpg --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg && \
    echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ noble main" \
      > /etc/apt/sources.list.d/cloudflare-client.list && \
    apt-get update && \
    if [ -n "$WARP_VERSION" ]; then \
      DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "cloudflare-warp=$WARP_VERSION" && \
      test "$(warp-cli --version | awk 'NR == 1 {print $2}')" = "$WARP_VERSION"; \
    else \
      DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends cloudflare-warp; \
    fi && \
    rm -rf /var/lib/apt/lists/*
COPY --from=builder /usr/local/lib/libbindany.so /usr/local/lib/libbindany.so
COPY --chmod=755 entrypoint.py /entrypoint.py
EXPOSE 40000/tcp
VOLUME ["/var/lib/cloudflare-warp"]
HEALTHCHECK --interval=30s --timeout=15s --start-period=2m --retries=3 CMD ["/usr/bin/python3", "/entrypoint.py", "--healthcheck"]
ENTRYPOINT ["/usr/bin/python3", "-u", "/entrypoint.py"]
