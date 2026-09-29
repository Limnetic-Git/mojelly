#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <liburing.h>
#include <limits.h>
#include <llhttp.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <pthread.h>
#include <sched.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#define LOG_LEVEL 0
#define LOG_COLORS 0

#define READ_BUFFER_SIZE 16384
#define LISTEN_BACKLOG 1024
#define HTTP_STATUS_DIGITS 3
#define HTTP_VERSION_PREFIX_LEN 9
#define BODY_PRERESERVE_MAX (1ULL << 30)

#define RING_DEPTH 4096

#define USE_SQPOLL 0

#define DBG 0

#if DBG
#define DBG_LOG(...)                                                      \
do {                                                                  \
    fprintf(stderr, "[DBG][T%d] ", current_thread_id);                \
    fprintf(stderr, __VA_ARGS__);                                     \
    fflush(stderr);                                                   \
} while (0)
#else
#define DBG_LOG(...) ((void)0)
#endif

#if LOG_COLORS
#define COLOR_RESET "\033[0m"
#define COLOR_GREEN "\033[32m"
#define COLOR_YELLOW "\033[33m"
#define COLOR_BLUE "\033[34m"
#define COLOR_MAGENTA "\033[35m"
#define COLOR_CYAN "\033[36m"
#define COLOR_RED "\033[31m"
#define COLOR_BOLD "\033[1m"
#else
#define COLOR_RESET ""
#define COLOR_GREEN ""
#define COLOR_YELLOW ""
#define COLOR_BLUE ""
#define COLOR_MAGENTA ""
#define COLOR_CYAN ""
#define COLOR_RED ""
#define COLOR_BOLD ""
#endif

static _Thread_local int current_thread_id = -1;
static _Thread_local unsigned long request_count = 0;

extern char* mojo_handler(void* router, const char* url, const char* method,
                          const char* headers, const char* body);

static void* global_router = NULL;
void mojelly_set_router(void* router) { global_router = router; }

/* ---------- buffer ---------- */

typedef struct {
    char* data;
    size_t len;
    size_t cap;
} buffer_t;

static void buf_init(buffer_t* b) { b->data = NULL; b->len = 0; b->cap = 0; }
static inline void buf_reset(buffer_t* b) { b->len = 0; }
static void buf_free(buffer_t* b) {
    if (b->data) free(b->data);
    b->data = NULL; b->len = 0; b->cap = 0;
}
static int buf_reserve(buffer_t* b, size_t need) {
    if (b->cap >= need) return 0;
    size_t nc = b->cap ? b->cap : 256;
    while (nc < need) { if (nc > SIZE_MAX / 2) return -1; nc *= 2; }
    char* nd = (char*)realloc(b->data, nc);
    if (!nd) return -1;
    b->data = nd; b->cap = nc;
    return 0;
}
static int buf_append(buffer_t* b, const char* data, size_t len) {
    if (len == 0) return 0;
    if (buf_reserve(b, b->len + len + 1) != 0) return -1;
    memcpy(b->data + b->len, data, len);
    b->len += len;
    b->data[b->len] = '\0';
    return 0;
}

typedef enum {
    HEADER_STATE_NONE = 0,
    HEADER_STATE_FIELD,
    HEADER_STATE_VALUE
} header_state_t;

/* ---------- llhttp settings ---------- */

static llhttp_settings_t g_settings;
static pthread_once_t g_settings_once = PTHREAD_ONCE_INIT;

static int on_message_begin_c(llhttp_t*);
static int on_url_c(llhttp_t*, const char*, size_t);
static int on_header_field_c(llhttp_t*, const char*, size_t);
static int on_header_value_c(llhttp_t*, const char*, size_t);
static int on_headers_complete_c(llhttp_t*);
static int on_body_c(llhttp_t*, const char*, size_t);
static int on_message_complete_c(llhttp_t*);

static void init_settings_once(void) {
    llhttp_settings_init(&g_settings);
    g_settings.on_message_begin = on_message_begin_c;
    g_settings.on_url = on_url_c;
    g_settings.on_header_field = on_header_field_c;
    g_settings.on_header_value = on_header_value_c;
    g_settings.on_headers_complete = on_headers_complete_c;
    g_settings.on_body = on_body_c;
    g_settings.on_message_complete = on_message_complete_c;
}
static inline void ensure_settings_init(void) {
    pthread_once(&g_settings_once, init_settings_once);
}

/* ---------- CQE op tags ---------- */

#define CQE_OP_ACCEPT 1
#define CQE_OP_RECV   2
#define CQE_OP_SEND   3

static inline void* make_ud(void* ptr, int op) {
    return (void*)((uintptr_t)ptr | (uintptr_t)(op & 0x7));
}
static inline void* ud_to_ptr(void* ud) {
    return (void*)((uintptr_t)ud & ~(uintptr_t)0x7);
}
static inline int ud_to_op(void* ud) {
    return (int)((uintptr_t)ud & 0x7);
}

/* ---------- forward decls ---------- */

struct conn_t;

typedef struct {
    struct io_uring ring;
    int listen_fd;
    int running;
    int thread_id;
    void* router;
    struct conn_t* close_queue;
} worker_t;

static _Thread_local worker_t* tls_worker = NULL;

typedef enum {
    CONN_STATE_READING = 0,
    CONN_STATE_WRITING
} conn_state_t;

typedef struct conn_t {
    int fd;
    worker_t* worker;
    llhttp_t parser;
    buffer_t url;
    buffer_t headers;
    buffer_t body;
    buffer_t pending;
    header_state_t header_state;
    int keep_alive;
    conn_state_t state;
    int recv_active;
    int send_active;
    int want_close;

    /* Per-connection read buffer, malloc'ed once. */
    char* read_buf;

    /* Response buffer (malloc'ed by Mojo, freed by us). */
    char* resp_data;
    size_t resp_len;

    struct conn_t* next;
} conn_t;

static void queue_conn_for_close(conn_t* c);
static void submit_recv(conn_t* c);
static void submit_send(conn_t* c);
static void submit_accept(worker_t* w);
static void conn_close(conn_t* c);

/* ---------- logs ---------- */

#if LOG_LEVEL >= 1
static const char* method_color(const char* m) {
    if (!strcmp(m, "GET")) return COLOR_CYAN;
    if (!strcmp(m, "POST")) return COLOR_GREEN;
    if (!strcmp(m, "PUT")) return COLOR_YELLOW;
    if (!strcmp(m, "DELETE")) return COLOR_RED;
    if (!strcmp(m, "PATCH")) return COLOR_MAGENTA;
    return COLOR_BLUE;
}
static const char* status_color(int s) {
    if (s >= 200 && s < 300) return COLOR_GREEN;
    if (s >= 300 && s < 400) return COLOR_CYAN;
    if (s >= 400 && s < 500) return COLOR_YELLOW;
    if (s >= 500) return COLOR_RED;
    return COLOR_RESET;
}
static _Thread_local time_t tls_time_cached = 0;
static _Thread_local char tls_time_str[20] = "00:00:00";
static inline const char* cached_time(void) {
    time_t now = time(NULL);
    if (now != tls_time_cached) {
        struct tm tm_info;
        localtime_r(&now, &tm_info);
        strftime(tls_time_str, sizeof(tls_time_str), "%H:%M:%S", &tm_info);
        tls_time_cached = now;
    }
    return tls_time_str;
}
static void log_request(const char* method, const char* url, int status,
                        double ms) {
    printf("[%s] [T%d] %s%s%s %s%s%s %s%d%s %.2fms\n", cached_time(),
           current_thread_id, method_color(method), method, COLOR_RESET,
           COLOR_BOLD, url, COLOR_RESET, status_color(status), status,
           COLOR_RESET, ms);
}
#else
#define log_request(m, u, s, d) ((void)0)
#endif

static int extract_status(const char* resp, size_t len) {
    if (!resp || len < HTTP_VERSION_PREFIX_LEN + HTTP_STATUS_DIGITS) return 200;
    if (strncmp(resp, "HTTP/1.1 ", HTTP_VERSION_PREFIX_LEN) != 0) return 200;
    int st = 0, i = HTTP_VERSION_PREFIX_LEN;
    int end = HTTP_VERSION_PREFIX_LEN + HTTP_STATUS_DIGITS;
    while (i < end && resp[i] >= '0' && resp[i] <= '9') {
        st = st * 10 + (resp[i] - '0'); i++;
    }
    return st > 0 ? st : 200;
}

static const char* http_400 =
"HTTP/1.1 400 Bad Request\r\n"
"Content-Length: 0\r\n"
"Connection: close\r\n\r\n";
static const char* http_500 =
"HTTP/1.1 500 Internal Server Error\r\n"
"Content-Length: 0\r\n"
"Connection: close\r\n\r\n";

/* ---------- llhttp callbacks ---------- */

static int on_message_begin_c(llhttp_t* p) {
    conn_t* c = (conn_t*)p->data;
    buf_reset(&c->url);
    buf_reset(&c->headers);
    buf_reset(&c->body);
    c->header_state = HEADER_STATE_NONE;
    return 0;
}
static int on_url_c(llhttp_t* p, const char* at, size_t n) {
    return buf_append(&((conn_t*)p->data)->url, at, n);
}
static int on_header_field_c(llhttp_t* p, const char* at, size_t n) {
    conn_t* c = (conn_t*)p->data;
    if (c->header_state == HEADER_STATE_VALUE) {
        if (buf_append(&c->headers, "\r\n", 2) != 0) return -1;
    }
    c->header_state = HEADER_STATE_FIELD;
    return buf_append(&c->headers, at, n);
}
static int on_header_value_c(llhttp_t* p, const char* at, size_t n) {
    conn_t* c = (conn_t*)p->data;
    if (c->header_state == HEADER_STATE_FIELD) {
        if (buf_append(&c->headers, ": ", 2) != 0) return -1;
    }
    c->header_state = HEADER_STATE_VALUE;
    return buf_append(&c->headers, at, n);
}
static int on_headers_complete_c(llhttp_t* p) {
    conn_t* c = (conn_t*)p->data;
    if (c->header_state == HEADER_STATE_VALUE) {
        if (buf_append(&c->headers, "\r\n", 2) != 0) return -1;
    }
    c->header_state = HEADER_STATE_NONE;
    c->keep_alive = llhttp_should_keep_alive(p);
    uint64_t cl = p->content_length;
    if (cl != ULLONG_MAX && cl > 0 && cl < BODY_PRERESERVE_MAX) {
        if (buf_reserve(&c->body, (size_t)cl + 1) != 0) return -1;
    }
    return 0;
}
static int on_body_c(llhttp_t* p, const char* at, size_t n) {
    return buf_append(&((conn_t*)p->data)->body, at, n);
}

/* ---------- response ---------- */

static void set_error_response(conn_t* c, const char* resp) {
    size_t len = strlen(resp);
    char* copy = (char*)malloc(len);
    if (!copy) {
        c->resp_data = NULL;
        c->resp_len = 0;
        c->keep_alive = 0;
        c->state = CONN_STATE_WRITING;
        return;
    }
    memcpy(copy, resp, len);
    c->resp_data = copy;
    c->resp_len = len;
    c->keep_alive = 0;
    c->state = CONN_STATE_WRITING;
}

static int on_message_complete_c(llhttp_t* p) {
    conn_t* c = (conn_t*)p->data;
    void* router = c->worker->router ? c->worker->router : global_router;

    if (!router) {
        set_error_response(c, http_500);
        submit_send(c);
        return 0;
    }

    request_count++;

    const char* method = llhttp_method_name((llhttp_method_t)p->method);
    const char* url = c->url.data ? c->url.data : "";
    const char* headers = c->headers.data ? c->headers.data : "";
    const char* body = c->body.data ? c->body.data : "";

    struct timespec ts, te;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    char* response = mojo_handler(router, url, method, headers, body);
    clock_gettime(CLOCK_MONOTONIC, &te);
    double ms = (te.tv_sec - ts.tv_sec) * 1000.0 +
    (te.tv_nsec - ts.tv_nsec) / 1000000.0;

    int status = 500;

    if (response != NULL) {
        size_t resp_len = strlen(response);
        status = extract_status(response, resp_len);
        c->resp_data = response;
        c->resp_len = resp_len;
    } else {
        set_error_response(c, http_500);
        log_request(method, url, 500, ms);
        submit_send(c);
        return 0;
    }

    log_request(method, url, status, ms);
    c->state = CONN_STATE_WRITING;
    submit_send(c);
    return 0;
}

/* ---------- io_uring submit ---------- */

static void queue_conn_for_close(conn_t* c) {
    DBG_LOG("queue_conn_for_close fd=%d recv_active=%d send_active=%d\n",
            c->fd, c->recv_active, c->send_active);
    c->next = c->worker->close_queue;
    c->worker->close_queue = c;
}

static void submit_recv(conn_t* c) {
    if (c->recv_active) {
        DBG_LOG("submit_recv SKIP fd=%d (already active)\n", c->fd);
        return;
    }
    worker_t* w = c->worker;
    struct io_uring_sqe* sqe = io_uring_get_sqe(&w->ring);
    if (!sqe) {
        DBG_LOG("submit_recv NO SQE fd=%d\n", c->fd);
        queue_conn_for_close(c);
        return;
    }

    if (!c->read_buf) {
        c->read_buf = (char*)malloc(READ_BUFFER_SIZE);
        if (!c->read_buf) {
            queue_conn_for_close(c);
            return;
        }
    }

    io_uring_prep_recv(sqe, c->fd, c->read_buf, READ_BUFFER_SIZE, 0);
    io_uring_sqe_set_data(sqe, make_ud(c, CQE_OP_RECV));

    int rc = io_uring_submit(&w->ring);
    DBG_LOG("submit_recv fd=%d rc=%d\n", c->fd, rc);
    if (rc < 0) {
        queue_conn_for_close(c);
        return;
    }
    c->recv_active = 1;
}

static void submit_send(conn_t* c) {
    if (c->resp_data == NULL || c->resp_len == 0) {
        DBG_LOG("submit_send EMPTY fd=%d\n", c->fd);
        queue_conn_for_close(c);
        return;
    }

    worker_t* w = c->worker;
    struct io_uring_sqe* sqe = io_uring_get_sqe(&w->ring);
    if (!sqe) {
        DBG_LOG("submit_send NO SQE fd=%d\n", c->fd);
        queue_conn_for_close(c);
        return;
    }

    io_uring_prep_send(sqe, c->fd, c->resp_data, c->resp_len, MSG_NOSIGNAL);
    io_uring_sqe_set_data(sqe, make_ud(c, CQE_OP_SEND));

    int rc = io_uring_submit(&w->ring);
    DBG_LOG("submit_send fd=%d len=%zu rc=%d\n", c->fd, c->resp_len, rc);
    if (rc < 0) {
        queue_conn_for_close(c);
        return;
    }
    c->send_active = 1;
}

static void submit_accept(worker_t* w) {
    struct io_uring_sqe* sqe = io_uring_get_sqe(&w->ring);
    if (!sqe) {
        DBG_LOG("submit_accept NO SQE\n");
        return;
    }

    io_uring_prep_multishot_accept(sqe, w->listen_fd, NULL, NULL, 0);
    io_uring_sqe_set_data(sqe, make_ud(w, CQE_OP_ACCEPT));
    int rc = io_uring_submit(&w->ring);
    DBG_LOG("submit_accept rc=%d\n", rc);
}

static void conn_close(conn_t* c) {
    if (!c) return;
    DBG_LOG("conn_close fd=%d\n", c->fd);
    if (c->fd >= 0) { close(c->fd); c->fd = -1; }
    buf_free(&c->url);
    buf_free(&c->headers);
    buf_free(&c->body);
    buf_free(&c->pending);
    if (c->read_buf) { free(c->read_buf); c->read_buf = NULL; }
    if (c->resp_data) free(c->resp_data);
    c->resp_data = NULL;
    c->resp_len = 0;
    free(c);
}

/* ---------- connection setup ---------- */

static conn_t* conn_new(worker_t* w, int fd) {
    conn_t* c = (conn_t*)calloc(1, sizeof(conn_t));
    if (!c) return NULL;

    c->fd = fd;
    c->worker = w;
    c->state = CONN_STATE_READING;
    c->keep_alive = 1;
    c->header_state = HEADER_STATE_NONE;
    c->recv_active = 0;
    c->send_active = 0;
    c->want_close = 0;
    c->read_buf = NULL;

    buf_init(&c->url);
    buf_init(&c->headers);
    buf_init(&c->body);
    buf_init(&c->pending);

    llhttp_init(&c->parser, HTTP_REQUEST, &g_settings);
    c->parser.data = c;

    int nodelay = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &nodelay, sizeof(nodelay));

    DBG_LOG("conn_new fd=%d c=%p\n", fd, (void*)c);
    return c;
}

/* ---------- CQE handlers ---------- */

static void handle_accept_cqe(worker_t* w, struct io_uring_cqe* cqe) {
    DBG_LOG("ACCEPT cqe res=%d flags=0x%x F_MORE=%d\n",
            cqe->res, cqe->flags,
            (cqe->flags & IORING_CQE_F_MORE) ? 1 : 0);

    if (cqe->res < 0) {
        if (cqe->res != -EAGAIN && cqe->res != -ECANCELED) {
            fprintf(stderr, "[io_uring] accept: %s\n", strerror(-cqe->res));
        }
        if (!(cqe->flags & IORING_CQE_F_MORE)) {
            submit_accept(w);
        }
        return;
    }

    int fd = cqe->res;

    if (!(cqe->flags & IORING_CQE_F_MORE)) {
        submit_accept(w);
    }

    conn_t* c = conn_new(w, fd);
    if (!c) { close(fd); return; }

    submit_recv(c);
}

static void handle_recv_cqe(conn_t* c, struct io_uring_cqe* cqe) {
    DBG_LOG("RECV cqe fd=%d res=%d flags=0x%x\n",
            c->fd, cqe->res, cqe->flags);

    c->recv_active = 0;

    if (cqe->res <= 0) {
        /* EOF or error. */
        if (c->send_active) {
            c->want_close = 1;
        } else {
            queue_conn_for_close(c);
        }
        return;
    }

    size_t len = (size_t)cqe->res;

    if (c->state == CONN_STATE_READING) {
        enum llhttp_errno err = llhttp_execute(&c->parser, c->read_buf, len);
        DBG_LOG("llhttp_execute fd=%d err=%d\n", c->fd, (int)err);
        if (err != HPE_OK) {
            if (c->state != CONN_STATE_WRITING) {
                set_error_response(c, http_400);
                submit_send(c);
            }
        }
    } else {
        /* In WRITING state: accumulate into pending. */
        DBG_LOG("RECV while WRITING fd=%d len=%zu\n", c->fd, len);
        if (buf_append(&c->pending, c->read_buf, len) != 0) {
            queue_conn_for_close(c);
            return;
        }
    }

    /* If we are still in READING state (no response queued), re-arm recv. */
    if (c->state == CONN_STATE_READING) {
        submit_recv(c);
    }
}

static void handle_send_cqe(conn_t* c, struct io_uring_cqe* cqe) {
    DBG_LOG("SEND cqe fd=%d res=%d\n", c->fd, cqe->res);

    c->send_active = 0;

    if (cqe->res < 0 && cqe->res != -ECANCELED) {
        queue_conn_for_close(c);
        return;
    }

    if (c->resp_data) { free(c->resp_data); c->resp_data = NULL; }
    c->resp_len = 0;

    if (c->want_close) {
        queue_conn_for_close(c);
        return;
    }

    if (!c->keep_alive) {
        queue_conn_for_close(c);
        return;
    }

    /* Reset parser for next request. */
    buf_reset(&c->url);
    buf_reset(&c->headers);
    buf_reset(&c->body);
    c->header_state = HEADER_STATE_NONE;
    llhttp_reset(&c->parser);
    c->parser.data = c;
    c->state = CONN_STATE_READING;

    /* Process any pending data that arrived while sending. */
    if (c->pending.len > 0) {
        DBG_LOG("SEND done, pending fd=%d len=%zu\n", c->fd, c->pending.len);
        size_t plen = c->pending.len;
        char* pdata = c->pending.data;
        c->pending.data = NULL;
        c->pending.len = 0;
        c->pending.cap = 0;

        enum llhttp_errno err = llhttp_execute(&c->parser, pdata, plen);
        free(pdata);

        if (err != HPE_OK) {
            if (c->state != CONN_STATE_WRITING) {
                set_error_response(c, http_400);
                submit_send(c);
            }
            return;
        }
        if (c->state == CONN_STATE_WRITING) {
            /* Another request parsed; its send is queued. */
            return;
        }
    }

    submit_recv(c);
}

static void dispatch_cqe(worker_t* w, struct io_uring_cqe* cqe) {
    void* ud = io_uring_cqe_get_data(cqe);
    if (!ud) {
        DBG_LOG("dispatch: null ud\n");
        return;
    }

    int op = ud_to_op(ud);
    void* ptr = ud_to_ptr(ud);

    switch (op) {
        case CQE_OP_ACCEPT:
            handle_accept_cqe((worker_t*)ptr, cqe);
            break;
        case CQE_OP_RECV:
            handle_recv_cqe((conn_t*)ptr, cqe);
            break;
        case CQE_OP_SEND:
            handle_send_cqe((conn_t*)ptr, cqe);
            break;
        default:
            DBG_LOG("dispatch: unknown op=%d ptr=%p\n", op, ptr);
            break;
    }
}

static void drain_close_queue(worker_t* w) {
    conn_t* c = w->close_queue;
    w->close_queue = NULL;
    while (c) {
        conn_t* next = c->next;
        conn_close(c);
        c = next;
    }
}

static void loop_run(worker_t* w) {
    while (w->running) {
        struct io_uring_cqe* cqe;
        int ret = io_uring_wait_cqe(&w->ring, &cqe);
        if (ret < 0) {
            if (ret == -EINTR) continue;
            fprintf(stderr, "[io_uring] wait_cqe: %s\n", strerror(-ret));
            break;
        }

        unsigned head;
        unsigned count = 0;
        io_uring_for_each_cqe(&w->ring, head, cqe) {
            dispatch_cqe(w, cqe);
            count++;
        }
        io_uring_cq_advance(&w->ring, count);

        drain_close_queue(w);
    }
}

/* ---------- server socket ---------- */

static int create_listen_socket(int port) {
    int fd = socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
    if (fd < 0) return -1;

    int opt = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
    #ifdef SO_REUSEPORT
    setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &opt, sizeof(opt));
    #endif

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = INADDR_ANY;
    addr.sin_port = htons((uint16_t)port);

    if (bind(fd, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
        fprintf(stderr, "[C] bind %d failed: %s\n", port, strerror(errno));
        close(fd);
        return -1;
    }
    if (listen(fd, LISTEN_BACKLOG) < 0) {
        fprintf(stderr, "[C] listen failed: %s\n", strerror(errno));
        close(fd);
        return -1;
    }
    return fd;
}

/* ---------- thread ---------- */

typedef struct {
    int port;
    void* router;
    int thread_id;
} thread_args_t;

static void* thread_main(void* arg) {
    thread_args_t* args = (thread_args_t*)arg;
    if (!args) return NULL;

    current_thread_id = args->thread_id;
    request_count = 0;

    int num_cpus = (int)sysconf(_SC_NPROCESSORS_ONLN);
    if (num_cpus < 1) num_cpus = 1;
    int cpu_id = args->thread_id % num_cpus;
    cpu_set_t cpuset;
    CPU_ZERO(&cpuset);
    CPU_SET(cpu_id, &cpuset);
    pthread_setaffinity_np(pthread_self(), sizeof(cpu_set_t), &cpuset);

    ensure_settings_init();

    worker_t* w = (worker_t*)calloc(1, sizeof(worker_t));
    if (!w) { free(args); return NULL; }

    w->running = 1;
    w->thread_id = args->thread_id;
    w->router = args->router;

    unsigned flags = 0;
    #if USE_SQPOLL
    flags |= IORING_SETUP_SQPOLL;
    flags |= IORING_SETUP_SQ_AFF;
    #endif
    flags |= IORING_SETUP_COOP_TASKRUN;
    flags |= IORING_SETUP_DEFER_TASKRUN;

    int ret = io_uring_queue_init(RING_DEPTH, &w->ring, flags);
    if (ret < 0) {
        flags &= ~(unsigned)(IORING_SETUP_COOP_TASKRUN |
        IORING_SETUP_DEFER_TASKRUN);
        ret = io_uring_queue_init(RING_DEPTH, &w->ring, flags);
    }
    if (ret < 0) {
        fprintf(stderr, "[io_uring] queue_init: %s\n", strerror(-ret));
        free(w);
        free(args);
        return NULL;
    }

    w->listen_fd = create_listen_socket(args->port);
    if (w->listen_fd < 0) {
        io_uring_queue_exit(&w->ring);
        free(w);
        free(args);
        return NULL;
    }

    tls_worker = w;

    printf("[C] 🧵 Thread %d listening on CPU %d (port %d)\n",
            args->thread_id, cpu_id, args->port);
    fflush(stdout);

    submit_accept(w);
    loop_run(w);

    drain_close_queue(w);
    close(w->listen_fd);
    io_uring_queue_exit(&w->ring);
    free(w);
    free(args);
    return NULL;
}

/* ---------- public API ---------- */

void pthread_create_wrapper(int port, void* router, int num_threads) {
    ensure_settings_init();
    for (int i = 0; i < num_threads; i++) {
        pthread_t t;
        thread_args_t* args = (thread_args_t*)malloc(sizeof(thread_args_t));
        if (!args) continue;
        args->port = port;
        args->router = router;
        args->thread_id = i;

        if (pthread_create(&t, NULL, thread_main, args) != 0) {
            fprintf(stderr, "[C] pthread_create failed for thread %d\n", i);
            free(args);
            continue;
        }
        pthread_detach(t);
    }
    printf("[C] ✅ All %d threads created\n", num_threads);
    fflush(stdout);
}

void mojelly_ensure_init(void) { ensure_settings_init(); }
void mojelly_free_response(char* ptr) { if (ptr) free(ptr); }
