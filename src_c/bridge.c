#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <llhttp.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <pthread.h>
#include <sched.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>
#include <uv.h>

/* Log level is read at startup from the MOJELLY_LOG_LEVEL env variable:
 *   0 - no per-request logs (default, best performance)
 *   1 - one line per request
 */
static int g_log_level = 0;

#define LOG_COLORS 1

#define READ_BUFFER_SIZE 16384
#define LISTEN_BACKLOG 1024
#define HTTP_STATUS_DIGITS 3
#define HTTP_VERSION_PREFIX_LEN 9
#define BODY_PRERESERVE_MAX (64ULL << 10)

static size_t g_max_header_size = 64UL << 10;
static size_t g_max_body_size = 10UL << 20;
static long g_idle_timeout_ms = 60 * 1000;
static long g_request_timeout_ms = 30 * 1000;
static long g_shutdown_timeout_ms = 30 * 1000;

/* Graceful shutdown state. */
static volatile sig_atomic_t g_shutdown = 0;

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

/* ---------- Mojo response ownership ---------- */

#define MOJO_RESP_OWNED 0
#define MOJO_RESP_BORROWED 1

extern char* mojo_handler(void* router, const char* url, const char* method,
                          const char* headers, const char* body,
                          size_t* out_len, int* out_ownership, size_t url_len,
                          size_t headers_len, size_t body_len);

static void* global_router = NULL;

void mojelly_set_router(void* router) { global_router = router; }

/* ---------- buffer ---------- */

typedef struct {
    char* data;
    size_t len;
    size_t cap;
} buffer_t;

static void buf_init(buffer_t* b) {
    b->data = NULL;
    b->len = 0;
    b->cap = 0;
}

static inline void buf_reset(buffer_t* b) {
    b->len = 0;
    if (b->data != NULL) {
        b->data[0] = '\0';
    }
}

static void buf_free(buffer_t* b) {
    if (b->data != NULL) {
        free(b->data);
        b->data = NULL;
    }
    b->len = 0;
    b->cap = 0;
}

static int buf_reserve(buffer_t* b, size_t need) {
    if (b->cap >= need) return 0;
    size_t new_cap = b->cap ? b->cap : 256;
    while (new_cap < need) {
        if (new_cap > SIZE_MAX / 2) return -1;
        new_cap *= 2;
    }
    char* nd = (char*)realloc(b->data, new_cap);
    if (!nd) return -1;
    b->data = nd;
    b->cap = new_cap;
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

/* ---------- static llhttp settings ---------- */

static llhttp_settings_t g_settings;
static pthread_once_t g_settings_once = PTHREAD_ONCE_INIT;

static int on_message_begin_c(llhttp_t* parser);
static int on_url_c(llhttp_t* parser, const char* at, size_t length);
static int on_header_field_c(llhttp_t* parser, const char* at, size_t length);
static int on_header_value_c(llhttp_t* parser, const char* at, size_t length);
static int on_headers_complete_c(llhttp_t* parser);
static int on_body_c(llhttp_t* parser, const char* at, size_t length);
static int on_message_complete_c(llhttp_t* parser);

static void mojelly_init_settings(void) {
    const char* lvl = getenv("MOJELLY_LOG_LEVEL");
    if (lvl != NULL) g_log_level = atoi(lvl);
    const char* v;
    if ((v = getenv("MOJELLY_MAX_HEADER_SIZE")) && atol(v) > 0)
        g_max_header_size = (size_t)atol(v);
    if ((v = getenv("MOJELLY_MAX_BODY")) && atol(v) > 0)
        g_max_body_size = (size_t)atol(v);
    if ((v = getenv("MOJELLY_IDLE_TIMEOUT")) && atol(v) >= 0)
        g_idle_timeout_ms = atol(v) * 1000;
    if ((v = getenv("MOJELLY_REQUEST_TIMEOUT")) && atol(v) >= 0)
        g_request_timeout_ms = atol(v) * 1000;
    if ((v = getenv("MOJELLY_SHUTDOWN_TIMEOUT")) && atol(v) > 0)
        g_shutdown_timeout_ms = atol(v) * 1000;
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
    pthread_once(&g_settings_once, mojelly_init_settings);
}

/* ---------- client ctx ---------- */

typedef struct client_ctx {
    uv_tcp_t client;
    llhttp_t parser;
    buffer_t url;
    buffer_t headers;
    buffer_t body;
    buffer_t pending;
    header_state_t header_state;
    int keep_alive;
    int processing;
    void* router;
    int reject_status;
    uint64_t last_active_ms;
    uint64_t request_started_ms;
    int linked;
    struct client_ctx* prev;
    struct client_ctx* next;
} client_ctx_t;

typedef struct {
    uv_write_t req;
    uv_tcp_t* client;
    char* data;
    size_t len;
    int keep_alive;
    int free_data;
} write_req_t;

typedef struct {
    int port;
    void* router;
    int thread_id;
} thread_args_t;

typedef struct {
    uv_timer_t timer;
    int64_t deadline;
    int stopped;   /* guard: uv_stop called at most once */
} shutdown_ctx_t;

static const char* http_500 =
"HTTP/1.1 500 Internal Server Error\r\n"
"Content-Length: 0\r\n"
"Connection: close\r\n\r\n";

static const char* http_413 =
"HTTP/1.1 413 Payload Too Large\r\n"
"Content-Length: 0\r\n"
"Connection: close\r\n\r\n";

static const char* http_431 =
"HTTP/1.1 431 Request Header Fields Too Large\r\n"
"Content-Length: 0\r\n"
"Connection: close\r\n\r\n";

static const char* http_400 =
"HTTP/1.1 400 Bad Request\r\n"
"Content-Length: 0\r\n"
"Connection: close\r\n\r\n";

static const char* get_method_color(const char* method) {
    if (strcmp(method, "GET") == 0) return COLOR_CYAN;
    if (strcmp(method, "POST") == 0) return COLOR_GREEN;
    if (strcmp(method, "PUT") == 0) return COLOR_YELLOW;
    if (strcmp(method, "DELETE") == 0) return COLOR_RED;
    if (strcmp(method, "PATCH") == 0) return COLOR_MAGENTA;
    return COLOR_BLUE;
}

static const char* get_status_color(int status) {
    if (status >= 200 && status < 300) return COLOR_GREEN;
    if (status >= 300 && status < 400) return COLOR_CYAN;
    if (status >= 400 && status < 500) return COLOR_YELLOW;
    if (status >= 500) return COLOR_RED;
    return COLOR_RESET;
}

static void log_request(const char* method, const char* url, int status,
                        double duration_ms) {
    const char* method_color = get_method_color(method);
    const char* status_color = get_status_color(status);

    static _Thread_local time_t cached_at = 0;
    static _Thread_local char time_str[20] = "00:00:00";
    time_t now = time(NULL);
    if (now != cached_at) {
        struct tm tm_info;
        localtime_r(&now, &tm_info);
        strftime(time_str, sizeof(time_str), "%H:%M:%S", &tm_info);
        cached_at = now;
    }

    printf("[%s] [T%d] %s%s%s %s%s%s %s%d%s %.2fms\n", time_str,
           current_thread_id, method_color, method, COLOR_RESET, COLOR_BOLD,
           url, COLOR_RESET, status_color, status, COLOR_RESET, duration_ms);
                        }

/* ---------- close / write ---------- */

static _Thread_local client_ctx_t* conn_list = NULL;

static void conn_link(client_ctx_t* ctx) {
    ctx->prev = NULL;
    ctx->next = conn_list;
    if (conn_list) conn_list->prev = ctx;
    conn_list = ctx;
    ctx->linked = 1;
}

static void conn_unlink(client_ctx_t* ctx) {
    if (!ctx->linked) return;
    if (ctx->prev) ctx->prev->next = ctx->next;
    else conn_list = ctx->next;
    if (ctx->next) ctx->next->prev = ctx->prev;
    ctx->linked = 0;
}

static void on_close_c(uv_handle_t* handle) {
    client_ctx_t* ctx = (client_ctx_t*)handle->data;
    if (ctx != NULL) {
        conn_unlink(ctx);
        buf_free(&ctx->url);
        buf_free(&ctx->headers);
        buf_free(&ctx->body);
        buf_free(&ctx->pending);
        free(ctx);
    }
}

static void on_read_c(uv_stream_t* client, ssize_t nread, const uv_buf_t* buf);
static void send_response(uv_tcp_t* client, const char* response, size_t len,
                            int keep_alive, int owned);

static void send_parse_error(client_ctx_t* ctx) {
    const char* resp = http_400;
    if (ctx->reject_status == 431) resp = http_431;
    else if (ctx->reject_status == 413) resp = http_413;
    send_response(&ctx->client, resp, strlen(resp), 0, MOJO_RESP_BORROWED);
}

#define WRITE_REQ_POOL_MAX 256
static _Thread_local write_req_t* wr_pool = NULL;
static _Thread_local int wr_pool_len = 0;

static write_req_t* wr_acquire(void) {
    write_req_t* wr = wr_pool;
    if (wr != NULL) {
        wr_pool = *(write_req_t**)wr;
        wr_pool_len--;
        return wr;
    }
    return (write_req_t*)malloc(sizeof(write_req_t));
}

static void wr_release(write_req_t* wr) {
    if (wr_pool_len >= WRITE_REQ_POOL_MAX) {
        free(wr);
        return;
    }
    *(write_req_t**)wr = wr_pool;
    wr_pool = wr;
    wr_pool_len++;
}

static void finish_write(write_req_t* wr, int status) {
    if (wr->free_data && wr->data != NULL) {
        free(wr->data);
    }
    wr->data = NULL;

    uv_tcp_t* client = wr->client;
    int keep_alive = wr->keep_alive;
    wr_release(wr);

    if (client == NULL || uv_is_closing((uv_handle_t*)client)) {
        return;
    }

    client_ctx_t* ctx = (client_ctx_t*)client->data;

    if (status != 0 || !keep_alive) {
        uv_close((uv_handle_t*)client, on_close_c);
        return;
    }

    if (ctx != NULL) {
        ctx->last_active_ms = uv_now(client->loop);
        buf_reset(&ctx->url);
        buf_reset(&ctx->headers);
        buf_reset(&ctx->body);
        ctx->header_state = HEADER_STATE_NONE;
        ctx->reject_status = 0;
        llhttp_init(&ctx->parser, HTTP_REQUEST, &g_settings);
        ctx->parser.data = ctx;
        ctx->processing = 0;

        if (ctx->pending.len > 0) {
            size_t plen = ctx->pending.len;
            const char* pdata = ctx->pending.data;
            enum llhttp_errno err = llhttp_execute(&ctx->parser, pdata, plen);
            buf_reset(&ctx->pending);
            if (err != HPE_OK) {
                send_parse_error(ctx);
            }
        }
    }
}

static void on_write_c(uv_write_t* req, int status) {
    finish_write((write_req_t*)req, status);
}

/* ---------- response ---------- */

static void send_response(uv_tcp_t* client, const char* response, size_t len,
                            int keep_alive, int owned) {
    if (client == NULL || uv_is_closing((uv_handle_t*)client)) {
        if (owned == MOJO_RESP_OWNED && response != NULL) free((void*)response);
        return;
    }

    if (response == NULL) {
        response = http_500;
        len = strlen(http_500);
        owned = MOJO_RESP_BORROWED;
        keep_alive = 0;
    }

    write_req_t* wr = wr_acquire();
    if (!wr) {
        if (owned == MOJO_RESP_OWNED && response != NULL) free((void*)response);
        if (!uv_is_closing((uv_handle_t*)client)) {
            uv_close((uv_handle_t*)client, on_close_c);
        }
        return;
    }

    wr->client = client;
    wr->keep_alive = keep_alive;
    wr->data = (char*)response;
    wr->len = len;
    wr->free_data = (owned == MOJO_RESP_OWNED) ? 1 : 0;

    uv_buf_t buf = uv_buf_init(wr->data, (unsigned int)wr->len);
    int rc = uv_write(&wr->req, (uv_stream_t*)client, &buf, 1, on_write_c);
    if (rc != 0) {
        if (wr->free_data && wr->data != NULL) free(wr->data);
        wr_release(wr);
        if (!uv_is_closing((uv_handle_t*)client)) {
            uv_close((uv_handle_t*)client, on_close_c);
        }
    }
                            }

static int extract_status_from_response(const char* response) {
    if (response == NULL) return 500;
    if (strncmp(response, "HTTP/1.1 ", HTTP_VERSION_PREFIX_LEN) != 0)
        return 200;
    int status = 0;
    int i = HTTP_VERSION_PREFIX_LEN;
    int end = HTTP_VERSION_PREFIX_LEN + HTTP_STATUS_DIGITS;
    while (i < end && response[i] >= '0' && response[i] <= '9') {
        status = status * 10 + (response[i] - '0');
        i++;
    }
    return status > 0 ? status : 200;
}

/* ---------- llhttp callbacks ---------- */

static int on_message_begin_c(llhttp_t* parser) {
    client_ctx_t* ctx = (client_ctx_t*)parser->data;
    ctx->reject_status = 0;
    buf_reset(&ctx->url);
    buf_reset(&ctx->headers);
    buf_reset(&ctx->body);
    ctx->header_state = HEADER_STATE_NONE;
    return 0;
}

static int check_header_limit(client_ctx_t* ctx, size_t extra) {
    if (ctx->url.len + ctx->headers.len + extra > g_max_header_size) {
        ctx->reject_status = 431;
        return -1;
    }
    return 0;
}

static int on_url_c(llhttp_t* parser, const char* at, size_t length) {
    client_ctx_t* ctx = (client_ctx_t*)parser->data;
    if (check_header_limit(ctx, length) != 0) return -1;
    return buf_append(&ctx->url, at, length);
}

static int on_header_field_c(llhttp_t* parser, const char* at, size_t length) {
    client_ctx_t* ctx = (client_ctx_t*)parser->data;
    if (ctx->header_state == HEADER_STATE_VALUE) {
        if (buf_append(&ctx->headers, "\r\n", 2) != 0) return -1;
    }
    ctx->header_state = HEADER_STATE_FIELD;
    if (check_header_limit(ctx, length + 2) != 0) return -1;
    return buf_append(&ctx->headers, at, length);
}

static int on_header_value_c(llhttp_t* parser, const char* at, size_t length) {
    client_ctx_t* ctx = (client_ctx_t*)parser->data;
    if (ctx->header_state == HEADER_STATE_FIELD) {
        if (buf_append(&ctx->headers, ": ", 2) != 0) return -1;
    }
    ctx->header_state = HEADER_STATE_VALUE;
    if (check_header_limit(ctx, length + 2) != 0) return -1;
    return buf_append(&ctx->headers, at, length);
}

static int on_headers_complete_c(llhttp_t* parser) {
    client_ctx_t* ctx = (client_ctx_t*)parser->data;
    if (ctx->header_state == HEADER_STATE_VALUE) {
        if (buf_append(&ctx->headers, "\r\n", 2) != 0) return -1;
    }
    ctx->header_state = HEADER_STATE_NONE;
    ctx->keep_alive = llhttp_should_keep_alive(parser);

    uint64_t cl = parser->content_length;
    if (cl != ULLONG_MAX && cl > g_max_body_size) {
        ctx->reject_status = 413;
        return -1;
    }
    if (cl != ULLONG_MAX && cl > 0) {
        size_t want = cl < BODY_PRERESERVE_MAX ? (size_t)cl : BODY_PRERESERVE_MAX;
        if (buf_reserve(&ctx->body, want + 1) != 0) return -1;
    }
    return 0;
}

static int on_body_c(llhttp_t* parser, const char* at, size_t length) {
    client_ctx_t* ctx = (client_ctx_t*)parser->data;
    if (ctx->body.len + length > g_max_body_size) {
        ctx->reject_status = 413;
        return -1;
    }
    return buf_append(&ctx->body, at, length);
}

static int on_message_complete_c(llhttp_t* parser) {
    client_ctx_t* ctx = (client_ctx_t*)parser->data;
    void* router = ctx->router ? ctx->router : global_router;

    if (router == NULL) {
        send_response(&ctx->client, http_500, strlen(http_500), 0,
                    MOJO_RESP_BORROWED);
        return 0;
    }

    request_count++;
    ctx->request_started_ms = 0;

    ctx->processing = 1;

    const char* method = llhttp_method_name((llhttp_method_t)parser->method);
    const char* url = ctx->url.data ? ctx->url.data : "";
    const char* headers = ctx->headers.data ? ctx->headers.data : "";
    const char* body = ctx->body.data ? ctx->body.data : "";

    struct timespec start, end;
    int log_on = g_log_level >= 1;
    if (log_on) clock_gettime(CLOCK_MONOTONIC, &start);

    size_t resp_len = 0;
    int resp_owned = MOJO_RESP_OWNED;
    char* response = mojo_handler(router, url, method, headers, body, &resp_len,
                                &resp_owned, ctx->url.len, ctx->headers.len,
                                ctx->body.len);

    double duration_ms = 0;
    if (log_on) {
        clock_gettime(CLOCK_MONOTONIC, &end);
        duration_ms = (end.tv_sec - start.tv_sec) * 1000.0 +
        (end.tv_nsec - start.tv_nsec) / 1000000.0;
    }

    int status = 500;
    int keep_alive = ctx->keep_alive;

    if (response != NULL) {
        if (resp_len == 0) resp_len = strlen(response);
        status = extract_status_from_response(response);
        send_response(&ctx->client, response, resp_len, keep_alive, resp_owned);
    } else {
        send_response(&ctx->client, http_500, strlen(http_500), 0,
                    MOJO_RESP_BORROWED);
    }

    if (log_on) log_request(method, url, status, duration_ms);
    return 0;
}

/* ---------- connection ---------- */

static void alloc_buffer_c(uv_handle_t* handle, size_t suggested_size,
                            uv_buf_t* buf) {
    (void)handle;
    (void)suggested_size;
    static _Thread_local char read_buf[READ_BUFFER_SIZE];
    buf->base = read_buf;
    buf->len = READ_BUFFER_SIZE;
                            }

static void on_read_c(uv_stream_t* client, ssize_t nread, const uv_buf_t* buf) {
    if (nread > 0) {
        client_ctx_t* ctx = (client_ctx_t*)client->data;
        if (ctx != NULL) {
            uint64_t now = uv_now(client->loop);
            ctx->last_active_ms = now;
            if (ctx->request_started_ms == 0 && !ctx->processing) {
                ctx->request_started_ms = now;
            }
            if (ctx->processing) {
                if (ctx->pending.len + (size_t)nread >
                    g_max_header_size + g_max_body_size) {
                    ctx->reject_status = 413;
                send_parse_error(ctx);
                    } else if (buf_append(&ctx->pending, buf->base,
                        (size_t)nread) != 0) {
                        send_response((uv_tcp_t*)client, http_500, strlen(http_500),
                                    0, MOJO_RESP_BORROWED);
                        }
            } else {
                enum llhttp_errno err =
                llhttp_execute(&ctx->parser, buf->base, (size_t)nread);
                if (err != HPE_OK) {
                    send_parse_error(ctx);
                }
            }
        }
    } else if (nread < 0) {
        if (!uv_is_closing((uv_handle_t*)client)) {
            uv_close((uv_handle_t*)client, on_close_c);
        }
    }
}

static void sweep_timeouts_c(uv_timer_t* timer) {
    uint64_t now = uv_now(timer->loop);
    client_ctx_t* c = conn_list;
    while (c != NULL) {
        client_ctx_t* next = c->next;
        if (!uv_is_closing((uv_handle_t*)&c->client)) {
            int idle = g_idle_timeout_ms > 0 &&
            now - c->last_active_ms > (uint64_t)g_idle_timeout_ms;
            int slow = g_request_timeout_ms > 0 && c->request_started_ms != 0 &&
            now - c->request_started_ms >
            (uint64_t)g_request_timeout_ms;
            if (idle || slow) uv_close((uv_handle_t*)&c->client, on_close_c);
        }
        c = next;
    }
}

/* ---------- graceful shutdown ---------- */

static void on_signal(uv_signal_t* handle, int signum) {
    (void)handle;
    (void)signum;
    if (g_shutdown) return;
    g_shutdown = 1;
    fprintf(stderr,
            "[C] Received signal %d, starting graceful shutdown...\n", signum);
}

static void check_shutdown_c(uv_timer_t* timer) {
    shutdown_ctx_t* sctx = (shutdown_ctx_t*)timer->data;
    if (!g_shutdown || sctx->stopped) return;

    if (conn_list == NULL) {
        sctx->stopped = 1;
        fprintf(stderr, "[C] All connections drained, stopping loop\n");
        uv_stop(timer->loop);
        return;
    }

    int64_t now = uv_now(timer->loop);
    if (now >= sctx->deadline) {
        sctx->stopped = 1;
        fprintf(stderr,
                "[C] Shutdown timeout reached, force-closing connections\n");
        client_ctx_t* c = conn_list;
        while (c != NULL) {
            client_ctx_t* next = c->next;
            if (!uv_is_closing((uv_handle_t*)&c->client)) {
                uv_close((uv_handle_t*)&c->client, on_close_c);
            }
            c = next;
        }
        uv_stop(timer->loop);
    }
}

static void on_connection_c(uv_stream_t* server, int status) {
    ensure_settings_init();

    if (status < 0) return;
    if (g_shutdown) return;

    client_ctx_t* ctx = (client_ctx_t*)malloc(sizeof(client_ctx_t));
    if (!ctx) return;
    memset(ctx, 0, sizeof(client_ctx_t));

    uv_tcp_init(server->loop, &ctx->client);
    ctx->client.data = ctx;

    thread_args_t* targs = (thread_args_t*)server->data;
    ctx->router = (targs && targs->router) ? targs->router : global_router;

    buf_init(&ctx->url);
    buf_init(&ctx->headers);
    buf_init(&ctx->body);
    buf_init(&ctx->pending);
    ctx->header_state = HEADER_STATE_NONE;
    ctx->processing = 0;
    ctx->last_active_ms = uv_now(server->loop);

    llhttp_init(&ctx->parser, HTTP_REQUEST, &g_settings);
    ctx->parser.data = ctx;

    if (uv_accept(server, (uv_stream_t*)&ctx->client) != 0) {
        uv_close((uv_handle_t*)&ctx->client, on_close_c);
        return;
    }
    conn_link(ctx);

    int fd = -1;
    if (uv_fileno((uv_handle_t*)&ctx->client, &fd) == 0 && fd >= 0) {
        int nodelay = 1;
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &nodelay, sizeof(nodelay));
    }

    if (uv_read_start((uv_stream_t*)&ctx->client, alloc_buffer_c, on_read_c) !=
        0) {
        uv_close((uv_handle_t*)&ctx->client, on_close_c);
        }
}

/* ---------- server socket ---------- */

static int create_bound_socket(int port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
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
        fprintf(stderr, "[C] ❌ bind port %d failed: %s\n", port,
                strerror(errno));
        close(fd);
        return -1;
    }

    return fd;
}

/* ---------- thread ---------- */

static int allowed_cpus[CPU_SETSIZE];
static int num_allowed_cpus = 0;

static void detect_allowed_cpus(void) {
    cpu_set_t set;
    CPU_ZERO(&set);
    num_allowed_cpus = 0;
    if (sched_getaffinity(0, sizeof(set), &set) == 0) {
        for (int c = 0; c < CPU_SETSIZE; c++) {
            if (CPU_ISSET(c, &set)) allowed_cpus[num_allowed_cpus++] = c;
        }
    }
    if (num_allowed_cpus == 0) allowed_cpus[num_allowed_cpus++] = 0;
}

static int resolve_thread_count(int requested) {
    if (requested > 0) return requested;
    const char* env = getenv("MOJELLY_THREADS");
    if (env != NULL && atoi(env) > 0) return atoi(env);
    return num_allowed_cpus;
}

/* Kept for wait_for_shutdown(). */
static pthread_t g_worker_threads[256];
static int g_worker_count = 0;
static pthread_mutex_t g_worker_mutex = PTHREAD_MUTEX_INITIALIZER;

static void close_if_open(uv_handle_t* h, void* arg) {
    (void)arg;
    if (!uv_is_closing(h)) {
        uv_close(h, NULL);
    }
}

static void* thread_main(void* arg) {
    thread_args_t* args = (thread_args_t*)arg;
    current_thread_id = args->thread_id;
    request_count = 0;

    int cpu_id = allowed_cpus[args->thread_id % num_allowed_cpus];
    cpu_set_t cpuset;
    CPU_ZERO(&cpuset);
    CPU_SET(cpu_id, &cpuset);
    pthread_setaffinity_np(pthread_self(), sizeof(cpu_set_t), &cpuset);

    ensure_settings_init();

    int server_fd = create_bound_socket(args->port);
    if (server_fd < 0) {
        free(args);
        return NULL;
    }

    uv_loop_t* loop = (uv_loop_t*)malloc(sizeof(uv_loop_t));
    if (!loop) {
        close(server_fd);
        free(args);
        return NULL;
    }
    if (uv_loop_init(loop) != 0) {
        free(loop);
        close(server_fd);
        free(args);
        return NULL;
    }

    uv_tcp_t* server = (uv_tcp_t*)malloc(sizeof(uv_tcp_t));
    if (!server) {
        uv_loop_close(loop);
        free(loop);
        close(server_fd);
        free(args);
        return NULL;
    }
    uv_tcp_init(loop, server);
    server->data = args;

    int rc = uv_tcp_open(server, server_fd);
    if (rc != 0) {
        fprintf(stderr, "[C] ❌ uv_tcp_open failed: %s\n", uv_strerror(rc));
        close(server_fd);
        uv_close((uv_handle_t*)server, NULL);
        uv_run(loop, UV_RUN_NOWAIT);
        uv_loop_close(loop);
        free(server);
        free(loop);
        free(args);
        return NULL;
    }

    rc = uv_listen((uv_stream_t*)server, LISTEN_BACKLOG, on_connection_c);
    if (rc != 0) {
        fprintf(stderr, "[C] ❌ uv_listen failed: %s\n", uv_strerror(rc));
        uv_close((uv_handle_t*)server, NULL);
        uv_run(loop, UV_RUN_NOWAIT);
        uv_loop_close(loop);
        free(server);
        free(loop);
        free(args);
        return NULL;
    }

    uv_timer_t* sweep = NULL;
    if (g_idle_timeout_ms > 0 || g_request_timeout_ms > 0) {
        sweep = (uv_timer_t*)malloc(sizeof(uv_timer_t));
        if (sweep != NULL) {
            uv_timer_init(loop, sweep);
            uv_timer_start(sweep, sweep_timeouts_c, 1000, 1000);
        }
    }

    uv_signal_t* sigint_h = (uv_signal_t*)malloc(sizeof(uv_signal_t));
    uv_signal_t* sigterm_h = (uv_signal_t*)malloc(sizeof(uv_signal_t));
    if (sigint_h != NULL) {
        uv_signal_init(loop, sigint_h);
        uv_signal_start(sigint_h, on_signal, SIGINT);
        uv_unref((uv_handle_t*)sigint_h);
    }
    if (sigterm_h != NULL) {
        uv_signal_init(loop, sigterm_h);
        uv_signal_start(sigterm_h, on_signal, SIGTERM);
        uv_unref((uv_handle_t*)sigterm_h);
    }

    shutdown_ctx_t* sctx = (shutdown_ctx_t*)malloc(sizeof(shutdown_ctx_t));
    if (sctx != NULL) {
        uv_timer_init(loop, &sctx->timer);
        sctx->timer.data = sctx;
        sctx->stopped = 0;
        sctx->deadline = uv_now(loop) + g_shutdown_timeout_ms;
        uv_timer_start(&sctx->timer, check_shutdown_c, 100, 100);
    }

    printf("[C] 🧵 Thread %d listening on CPU %d (port %d)\n", args->thread_id,
        cpu_id, args->port);
    fflush(stdout);

    uv_run(loop, UV_RUN_DEFAULT);

    /* ---- Cleanup after graceful shutdown ---- */

    /* Stop timers first, so they do not fire during the closing walk. */
    if (sweep != NULL) {
        uv_timer_stop(sweep);
    }
    if (sctx != NULL) {
        uv_timer_stop(&sctx->timer);
    }

    /* Close every handle that is still open, exactly once. */
    uv_walk(loop, close_if_open, NULL);

    /* Drain close callbacks. */
    uv_run(loop, UV_RUN_DEFAULT);
    uv_loop_close(loop);

    free(sctx);
    free(sigint_h);
    free(sigterm_h);
    free(sweep);
    free(server);
    free(loop);
    free(args);

    return NULL;
}

/* ---------- public API ---------- */

void pthread_create_wrapper(int port, void* router, int num_threads) {
    ensure_settings_init();
    detect_allowed_cpus();
    num_threads = resolve_thread_count(num_threads);

    pthread_mutex_lock(&g_worker_mutex);
    g_worker_count = 0;
    pthread_mutex_unlock(&g_worker_mutex);

    for (int i = 0; i < num_threads && i < 256; i++) {
        pthread_t thread;
        thread_args_t* args = (thread_args_t*)malloc(sizeof(thread_args_t));
        if (!args) continue;
        args->port = port;
        args->router = router;
        args->thread_id = i;

        if (pthread_create(&thread, NULL, thread_main, args) != 0) {
            fprintf(stderr, "[C] ❌ pthread_create failed for thread %d\n", i);
            free(args);
            continue;
        }
        pthread_mutex_lock(&g_worker_mutex);
        g_worker_threads[g_worker_count++] = thread;
        pthread_mutex_unlock(&g_worker_mutex);
    }
    printf("[C] ✅ All %d threads created\n", num_threads);
    fflush(stdout);
}

void wait_for_shutdown(void) {
    pthread_mutex_lock(&g_worker_mutex);
    int n = g_worker_count;
    pthread_t copy[256];
    for (int i = 0; i < n; i++) copy[i] = g_worker_threads[i];
    pthread_mutex_unlock(&g_worker_mutex);

    for (int i = 0; i < n; i++) {
        pthread_join(copy[i], NULL);
    }
}

void mojelly_ensure_init(void) { ensure_settings_init(); }

/* ---------- low-level wrappers ---------- */

void uv_tcp_init_wrapper(uv_loop_t* loop, uv_tcp_t* tcp) {
    ensure_settings_init();
    uv_tcp_init(loop, tcp);
}

void uv_tcp_bind_wrapper(uv_tcp_t* tcp, const char* ip, int port) {
    ensure_settings_init();
    struct sockaddr_in addr;
    uv_ip4_addr(ip, port, &addr);
    unsigned int flags = 0;
    #ifdef UV_TCP_REUSEPORT
    flags |= UV_TCP_REUSEPORT;
    #endif
    int rc = uv_tcp_bind(tcp, (const struct sockaddr*)&addr, flags);
    if (rc != 0) {
        fprintf(stderr, "[C] ❌ uv_tcp_bind failed: %s\n", uv_strerror(rc));
    }
}

void uv_listen_wrapper(uv_tcp_t* tcp, int backlog) {
    ensure_settings_init();
    int rc = uv_listen((uv_stream_t*)tcp, backlog, on_connection_c);
    if (rc != 0) {
        fprintf(stderr, "[C] ❌ uv_listen failed: %s\n", uv_strerror(rc));
    }
}

void uv_run_wrapper(uv_loop_t* loop) {
    if (loop) uv_run(loop, UV_RUN_DEFAULT);
}

void uv_read_start_wrapper(uv_tcp_t* client) {
    if (client == NULL) return;
    uv_read_start((uv_stream_t*)client, alloc_buffer_c, on_read_c);
}

void uv_read_stop_wrapper(uv_tcp_t* client) {
    if (client == NULL) return;
    uv_read_stop((uv_stream_t*)client);
}

void uv_write_wrapper(uv_tcp_t* client, const char* data, size_t len) {
    if (client == NULL || uv_is_closing((uv_handle_t*)client)) return;

    write_req_t* wr = wr_acquire();
    if (!wr) {
        if (!uv_is_closing((uv_handle_t*)client)) {
            uv_close((uv_handle_t*)client, on_close_c);
        }
        return;
    }
    wr->data = (char*)malloc(len ? len : 1);
    if (!wr->data) {
        wr_release(wr);
        if (!uv_is_closing((uv_handle_t*)client)) {
            uv_close((uv_handle_t*)client, on_close_c);
        }
        return;
    }
    if (len) memcpy(wr->data, data, len);
    wr->len = len;
    wr->client = client;
    wr->keep_alive = 0;
    wr->free_data = 1;

    uv_buf_t buf = uv_buf_init(wr->data, (unsigned int)len);
    int rc = uv_write(&wr->req, (uv_stream_t*)client, &buf, 1, on_write_c);
    if (rc != 0) {
        free(wr->data);
        wr_release(wr);
        if (!uv_is_closing((uv_handle_t*)client)) {
            uv_close((uv_handle_t*)client, on_close_c);
        }
    }
}

void uv_close_wrapper(uv_tcp_t* client) {
    if (client && !uv_is_closing((uv_handle_t*)client)) {
        uv_close((uv_handle_t*)client, on_close_c);
    }
}

uv_loop_t* uv_loop_create_wrapper(void) {
    ensure_settings_init();
    uv_loop_t* loop = (uv_loop_t*)malloc(sizeof(uv_loop_t));
    if (!loop) return NULL;
    uv_loop_init(loop);
    return loop;
}

void uv_loop_destroy_wrapper(uv_loop_t* loop) {
    if (!loop) return;
    uv_walk(loop, close_if_open, NULL);
    uv_run(loop, UV_RUN_DEFAULT);
    uv_loop_close(loop);
    free(loop);
}

void mojelly_free_response(char* ptr) {
    if (ptr) free(ptr);
}
