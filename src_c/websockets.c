#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <netdb.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/epoll.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

/* Scalar FFI for the standalone synchronous WebSocket client and server. */
uint64_t ws_alloc(uint64_t size) { return (uint64_t)(uintptr_t)malloc((size_t)size); }

int ws_errno(void) { return errno; }
int ws_close(int fd) { return close(fd); }

int64_t ws_now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

int ws_http_date(char* out, int capacity) {
    static const char* days[] = {"Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"};
    static const char* months[] = {"Jan", "Feb", "Mar", "Apr", "May", "Jun",
                                   "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"};
    time_t now = time(NULL);
    struct tm tm;
    if (capacity < 30 || gmtime_r(&now, &tm) == NULL) return 0;
    return snprintf(out, (size_t)capacity, "%s, %02d %s %04d %02d:%02d:%02d GMT",
                    days[tm.tm_wday], tm.tm_mday, months[tm.tm_mon],
                    tm.tm_year + 1900, tm.tm_hour, tm.tm_min, tm.tm_sec);
}

int ws_port(int fd) {
    struct sockaddr_storage addr;
    socklen_t len = sizeof(addr);
    if (getsockname(fd, (struct sockaddr*)&addr, &len) < 0) return -1;
    if (addr.ss_family == AF_INET)
        return ntohs(((struct sockaddr_in*)&addr)->sin_port);
    if (addr.ss_family == AF_INET6)
        return ntohs(((struct sockaddr_in6*)&addr)->sin6_port);
    errno = EAFNOSUPPORT;
    return -1;
}

int ws_poll(int fd, int writing, int timeout_ms) {
    struct pollfd p = {fd, writing ? POLLOUT : POLLIN, 0};
    int rc = poll(&p, 1, timeout_ms);
    return rc < 0 && errno == EINTR ? -2 : rc;
}

static int open_socket(const char* host, int port, int listening, int timeout_ms) {
    char service[6];
    snprintf(service, sizeof(service), "%d", port);
    struct addrinfo hints = {0};
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_flags = listening ? AI_PASSIVE : 0;
    struct addrinfo* addresses = NULL;
    if (getaddrinfo(host[0] ? host : NULL, service, &hints, &addresses) != 0) {
        errno = EINVAL;
        return -1;
    }
    int result = -1;
    int saved_errno = ECONNREFUSED;
    int64_t deadline = ws_now_ms() + timeout_ms;
    for (struct addrinfo* a = addresses; a; a = a->ai_next) {
        int fd = socket(a->ai_family, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
        if (fd < 0) { saved_errno = errno; continue; }
        int one = 1;
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
        if (listening) {
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
            if (bind(fd, a->ai_addr, a->ai_addrlen) == 0 && listen(fd, 128) == 0) {
                result = fd;
                break;
            }
        } else {
            int rc = connect(fd, a->ai_addr, a->ai_addrlen);
            if (rc == 0) { result = fd; break; }
            if (errno == EINPROGRESS) {
                while (ws_now_ms() < deadline) {
                    int64_t remaining = deadline - ws_now_ms();
                    rc = ws_poll(fd, 1, (int)(remaining > INT_MAX ? INT_MAX : remaining));
                    if (rc == -2) continue;
                    if (rc > 0) {
                        int error = 0;
                        socklen_t len = sizeof(error);
                        if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &len) == 0) {
                            if (error == 0) result = fd;
                            else errno = error;
                        }
                    } else if (rc == 0) errno = ETIMEDOUT;
                    break;
                }
                if (result >= 0) break;
                if (ws_now_ms() >= deadline) errno = ETIMEDOUT;
            }
        }
        saved_errno = errno;
        close(fd);
    }
    freeaddrinfo(addresses);
    if (result < 0) errno = saved_errno;
    return result;
}

int ws_listen(const char* host, int port) { return open_socket(host, port, 1, 0); }
int ws_connect(const char* host, int port, int timeout_ms) {
    return open_socket(host, port, 0, timeout_ms);
}

int ws_accept(int fd) {
    int client;
    do { client = accept4(fd, NULL, NULL, SOCK_NONBLOCK | SOCK_CLOEXEC); }
    while (client < 0 && errno == EINTR);
    if (client < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) return -2;
    if (client >= 0) {
        int one = 1;
        setsockopt(client, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
    }
    return client;
}

int64_t ws_recv(int fd, void* out, int64_t capacity) {
    ssize_t n;
    do { n = recv(fd, out, (size_t)capacity, 0); } while (n < 0 && errno == EINTR);
    return n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) ? -2 : n;
}

int64_t ws_send(int fd, const void* data, int64_t length) {
    ssize_t n;
    do { n = send(fd, data, (size_t)length, MSG_NOSIGNAL); } while (n < 0 && errno == EINTR);
    return n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) ? -2 : n;
}

int ws_epoll_create(void) { return epoll_create1(EPOLL_CLOEXEC); }
int ws_epoll_watch(int poller, int operation, int fd, uint64_t id, int writing) {
    struct epoll_event event = {0};
    event.events = EPOLLIN | EPOLLRDHUP | (writing ? EPOLLOUT : 0);
    event.data.u64 = id;
    int op = operation == 1 ? EPOLL_CTL_ADD : operation == 2 ? EPOLL_CTL_DEL : EPOLL_CTL_MOD;
    return epoll_ctl(poller, op, fd, &event);
}

int ws_epoll_wait(int poller, uint64_t* ids, uint32_t* flags, int capacity, int timeout_ms) {
    struct epoll_event events[128];
    if (capacity < 1 || capacity > 128) { errno = EINVAL; return -1; }
    int n = epoll_wait(poller, events, capacity, timeout_ms);
    if (n < 0 && errno == EINTR) return -2;
    for (int i = 0; i < n; i++) {
        ids[i] = events[i].data.u64;
        flags[i] = events[i].events;
    }
    return n;
}
