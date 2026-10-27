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

/* ================= Logging ================= */

static int g_log_level = 0;

#define LOG_COLORS 1
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

/* ================= Config ================= */

#define READ_BUFFER_SIZE 16384
#define LISTEN_BACKLOG 1024
#define HTTP_STATUS_DIGITS 3
#define HTTP_VERSION_PREFIX_LEN 9
#define BODY_PRERESERVE_MAX (64ULL << 10)

/* OPT: arena default size per connection */
#define ARENA_DEFAULT_SIZE (32 * 1024)
/* OPT: max arena size before falling back to separate malloc */
#define ARENA_MAX_SIZE (4 * 1024 * 1024)
/* OPT: slab size for client_ctx_t */
#define CTX_SLAB_MAX 1024
/* OPT: write_req pool */
#define WRITE_REQ_POOL_MAX 4096

static size_t g_max_header_size = 64UL << 10;
static size_t g_max_body_size = 10UL << 20;
static long g_idle_timeout_ms = 60 * 1000;
static long g_request_timeout_ms = 30 * 1000;
static long g_shutdown_timeout_ms = 30 * 1000;

static volatile sig_atomic_t g_shutdown = 0;

/* ================= Mojo ================= */

#define MOJO_RESP_OWNED 0
#define MOJO_RESP_BORROWED 1

extern char* mojo_handler(void* router, const char* url, const char* method,
                          const char* headers, const char* body,
                          size_t* out_len, int* out_ownership, size_t url_len,
                          size_t headers_len, size_t body_len);

static void* global_router = NULL;
void mojelly_set_router(void* router) { global_router = router; }

/* ================= Arena allocator ================= */
/* OPT: bump allocator, reset per request. Falls back to malloc for huge. */

typedef struct {
    char* base;
    size_t cap;
    size_t used;
} arena_t;

static void arena_init(arena_t* a, size_t cap) {
    a->base = (char*)malloc(cap);
    a->cap = a->base ? cap : 0;
    a->used = 0;
}

static void arena_free(arena_t* a) {
    if (a->base) free(a->base);
    a->base = NULL;
    a->cap = 0;
    a->used = 0;
}

static inline void arena_reset(arena_t* a) { a->used = 0; }

static void* arena_alloc(arena_t* a, size_t n) {
    if (n == 0) n = 1;
    /* align to 8 */
    n = (n + 7) & ~(size_t)7;
    if (a->base != NULL && a->used + n <= a->cap) {
        void* p = a->base + a->used;
        a->used += n;
        return p;
    }
    /* grow: double until fit, but cap at ARENA_MAX_SIZE */
    if (a->cap >= ARENA_MAX_SIZE) return NULL;
    size_t new_cap = a->cap ? a->cap : ARENA_DEFAULT_SIZE;
    while (new_cap < a->used + n) {
        if (new_cap > ARENA_MAX_SIZE / 2) { new_cap = ARENA_MAX_SIZE; break; }
        new_cap *= 2;
    }
    char* nb = (char*)realloc(a->base, new_cap);
    if (!nb) return NULL;
    a->base = nb;
    a->cap = new_cap;
    void* p = a->base + a->used;
    a->used += n;
    return p;
}

/* ================= Buffer (arena-backed) ================= */
/* OPT: buf_reset keeps capacity (in arena) */

typedef struct {
    char* data;
    size_t len;
    size_t cap;
    int arena_backed;
} buffer_t;

static void buf_init(buffer_t* b) {
    b->data = NULL; b->len = 0; b->cap = 0; b->arena_backed = 0;
}

static void buf_free(buffer_t* b) {
    if (b->data != NULL && !b->arena_backed) free(b->data);
    b->data = NULL; b->len = 0; b->cap = 0; b->arena_backed = 0;
}

static inline void buf_reset(buffer_t* b) {
    b->len = 0;
    if (b->data != NULL) b->data[0] = '\0';
}

static int buf_reserve_arena(buffer_t* b, arena_t* a, size_t need) {
    if (b->cap >= need) return 0;
    if (b->arena_backed && a != NULL) {
        /* try to extend in arena */
        size_t new_cap = b->cap ? b->cap : 256;
        while (new_cap < need) {
            if (new_cap > SIZE_MAX / 2) return -1;
            new_cap *= 2;
        }
        if (new_cap > ARENA_MAX_SIZE) return -1;
        char* p = (char*)arena_alloc(a, new_cap);
        if (!p) return -1;
        if (b->data && b->len) memcpy(p, b->data, b->len);
        b->data = p;
        b->cap = new_cap;
        return 0;
    }
    /* fallback: heap */
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

static int buf_append_arena(buffer_t* b, arena_t* a, const char* data, size_t len) {
    if (len == 0) return 0;
    if (b->len + len + 1 < b->len) return -1; /* overflow */
        if (buf_reserve_arena(b, a, b->len + len + 1) != 0) return -1;
        memcpy(b->data + b->len, data, len);
    b->len += len;
    b->data[b->len] = '\0';
    return 0;
}

/* ================= Client ctx (slab-allocated) ================= */

typedef enum {
    HEADER_STATE_NONE = 0,
    HEADER_STATE_FIELD,
    HEADER_STATE_VALUE
} header_state_t;

typedef struct client_ctx {
    uv_tcp_t client;
    llhttp_t parser;
    arena_t arena;
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
    int in_slab;
    struct client_ctx* prev;
    struct client_ctx* next;
    /* OPT: heap index for timeout min-heap; -1 if not in heap */
    int heap_index;
} client_ctx_t;

/* OPT: slab */
static client_ctx_t* g_ctx_slab[CTX_SLAB_MAX];
static int g_ctx_slab_len = 0;
static pthread_mutex_t g_ctx_slab_mutex = PTHREAD_MUTEX_INITIALIZER;

static client_ctx_t* ctx_alloc(void) {
    pthread_mutex_lock(&g_ctx_slab_mutex);
    if (g_ctx_slab_len > 0) {
        client_ctx_t* c = g_ctx_slab[--g_ctx_slab_len];
        pthread_mutex_unlock(&g_ctx_slab_mutex);
        memset(c, 0, sizeof(client_ctx_t));
        c->in_slab = 1;
        c->heap_index = -1;
        return c;
    }
    pthread_mutex_unlock(&g_ctx_slab_mutex);
    client_ctx_t* c = (client_ctx_t*)calloc(1, sizeof(client_ctx_t));
    if (c) { c->in_slab = 0; c->heap_index = -1; }
    return c;
}

static void ctx_free(client_ctx_t* c) {
    if (!c) return;
    arena_free(&c->arena);
    buf_free(&c->url);
    buf_free(&c->headers);
    buf_free(&c->body);
    buf_free(&c->pending);
    pthread_mutex_lock(&g_ctx_slab_mutex);
    if (g_ctx_slab_len < CTX_SLAB_MAX) {
        c->in_slab = 1;
        g_ctx_slab[g_ctx_slab_len++] = c;
        pthread_mutex_unlock(&g_ctx_slab_mutex);
        return;
    }
    pthread_mutex_unlock(&g_ctx_slab_mutex);
    free(c);
}

/* ================= write_req ================= */

typedef struct {
    uv_write_t req;
    uv_tcp_t* client;
    char* data;
    size_t len;
    int keep_alive;
    int free_data;
} write_req_t;

#define WRITE_REQ_POOL_MAX 4096
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
    if (wr_pool_len >= WRITE_REQ_POOL_MAX) { free(wr); return; }
    *(write_req_t**)wr = wr_pool;
    wr_pool = wr;
    wr_pool_len++;
}

/* ================= Timeout min-heap ================= */
/* OPT: per-thread min-heap by last_active_ms (idle timeout).
 * request_timeout still checked in sweep for simplicity. */

typedef struct {
    client_ctx_t** items;
    int len;
    int cap;
} heap_t;

static _Thread_local heap_t g_timeout_heap = {NULL, 0, 0};

static inline uint64_t deadline_of(client_ctx_t* c) {
    /* we use last_active_ms + idle_timeout as key */
    return c->last_active_ms;
}

static void heap_swap(int i, int j) {
    client_ctx_t* a = g_timeout_heap.items[i];
    client_ctx_t* b = g_timeout_heap.items[j];
    g_timeout_heap.items[i] = b; b->heap_index = i;
    g_timeout_heap.items[j] = a; a->heap_index = j;
}

static void heap_up(int i) {
    while (i > 0) {
        int p = (i - 1) / 2;
        if (deadline_of(g_timeout_heap.items[p]) <= deadline_of(g_timeout_heap.items[i])) break;
        heap_swap(i, p);
        i = p;
    }
}

static void heap_down(int i) {
    int n = g_timeout_heap.len;
    for (;;) {
        int l = 2 * i + 1, r = l + 1, s = i;
        if (l < n && deadline_of(g_timeout_heap.items[l]) < deadline_of(g_timeout_heap.items[s])) s = l;
        if (r < n && deadline_of(g_timeout_heap.items[r]) < deadline_of(g_timeout_heap.items[s])) s = r;
        if (s == i) break;
        heap_swap(i, s);
        i = s;
    }
}

static void heap_push(client_ctx_t* c) {
    if (c->heap_index >= 0) return;
    if (g_timeout_heap.len >= g_timeout_heap.cap) {
        int nc = g_timeout_heap.cap ? g_timeout_heap.cap * 2 : 256;
        client_ctx_t** ni = (client_ctx_t**)realloc(g_timeout_heap.items, nc * sizeof(*ni));
        if (!ni) return;
        g_timeout_heap.items = ni;
        g_timeout_heap.cap = nc;
    }
    int i = g_timeout_heap.len++;
    g_timeout_heap.items[i] = c;
    c->heap_index = i;
    heap_up(i);
}

static void heap_update(client_ctx_t* c) {
    if (c->heap_index < 0) { heap_push(c); return; }
    heap_down(c->heap_index);
    heap_up(c->heap_index);
}

static void heap_remove(client_ctx_t* c) {
    int i = c->heap_index;
    if (i < 0) return;
    int last = --g_timeout_heap.len;
    if (i != last) {
        g_timeout_heap.items[i] = g_timeout_heap.items[last];
        g_timeout_heap.items[i]->heap_index = i;
        heap_down(i);
        heap_up(i);
    }
    c->heap_index = -1;
}

/* ================= llhttp ================= */

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

/* ================= Static responses ================= */

static const char* http_500 =
"HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
    static const char* http_413 =
    "HTTP/1.1 413 Payload Too Large\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
    static const char* http_431 =
    "HTTP/1.1 431 Request Header Fields Too Large\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
    static const char* http_400 =
    "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";

    /* ================= Logging helpers ================= */

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
    static void log_request(const char* method, const char* url, int status, double duration_ms) {
        const char* mc = get_method_color(method);
        const char* sc = get_status_color(status);
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
               current_thread_id, mc, method, COLOR_RESET, COLOR_BOLD,
               url, COLOR_RESET, sc, status, COLOR_RESET, duration_ms);
    }

    /* ================= Conn list (per thread) ================= */

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

    /* ================= forward ================= */

    static void on_close_c(uv_handle_t* handle);
    static void on_read_c(uv_stream_t* client, ssize_t nread, const uv_buf_t* buf);
    static void send_response(uv_tcp_t* client, const char* response, size_t len,
                              int keep_alive, int owned);

    /* ================= close ================= */

    static void on_close_c(uv_handle_t* handle) {
        client_ctx_t* ctx = (client_ctx_t*)handle->data;
        if (ctx == NULL) return;
        conn_unlink(ctx);
        heap_remove(ctx);
        ctx_free(ctx);
    }

    /* ================= write ================= */

    static void finish_write(write_req_t* wr, int status) {
        if (wr->free_data && wr->data != NULL) free(wr->data);
        wr->data = NULL;
        uv_tcp_t* client = wr->client;
        int keep_alive = wr->keep_alive;
        wr_release(wr);

        if (client == NULL || uv_is_closing((uv_handle_t*)client)) return;

        client_ctx_t* ctx = (client_ctx_t*)client->data;
        if (status != 0 || !keep_alive) {
            uv_close((uv_handle_t*)client, on_close_c);
            return;
        }
        if (ctx != NULL) {
            ctx->last_active_ms = uv_now(client->loop);
            heap_update(ctx);
            buf_reset(&ctx->url);
            buf_reset(&ctx->headers);
            buf_reset(&ctx->body);
            arena_reset(&ctx->arena); /* OPT: reclaim arena */
            ctx->header_state = HEADER_STATE_NONE;
            ctx->reject_status = 0;
            llhttp_init(&ctx->parser, HTTP_REQUEST, &g_settings);
            ctx->parser.data = ctx;
            ctx->processing = 0;

            if (ctx->pending.len > 0) {
                size_t plen = ctx->pending.len;
                char tmp[4096];
                const char* pdata = ctx->pending.data;
                /* copy pending to stack to avoid arena reset issue */
                if (plen > sizeof(tmp)) plen = sizeof(tmp);
                memcpy(tmp, pdata, plen);
                buf_reset(&ctx->pending);
                enum llhttp_errno err = llhttp_execute(&ctx->parser, tmp, plen);
                if (err != HPE_OK) {
                    const char* resp = (ctx->reject_status == 431) ? http_431 :
                    (ctx->reject_status == 413) ? http_413 : http_400;
                    send_response(&ctx->client, resp, strlen(resp), 0, MOJO_RESP_BORROWED);
                    uv_read_stop((uv_stream_t*)client);
                }
            }
        }
    }

    static void on_write_c(uv_write_t* req, int status) {
        finish_write((write_req_t*)req, status);
    }

    static void send_response(uv_tcp_t* client, const char* response, size_t len,
                              int keep_alive, int owned) {
        if (client == NULL || uv_is_closing((uv_handle_t*)client)) {
            if (owned == MOJO_RESP_OWNED && response != NULL) free((void*)response);
            return;
        }
        if (response == NULL) {
            response = http_500; len = strlen(http_500);
            owned = MOJO_RESP_BORROWED; keep_alive = 0;
        }
        write_req_t* wr = wr_acquire();
        if (!wr) {
            if (owned == MOJO_RESP_OWNED && response != NULL) free((void*)response);
            if (!uv_is_closing((uv_handle_t*)client))
                uv_close((uv_handle_t*)client, on_close_c);
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
            if (!uv_is_closing((uv_handle_t*)client))
                uv_close((uv_handle_t*)client, on_close_c);
        }
                              }

/* OPT: no loop, direct index */
static int extract_status_from_response(const char* response) {
    if (response == NULL) return 500;
    if (response[0] != 'H' || response[1] != 'T' || response[2] != 'T' ||
        response[3] != 'P' || response[4] != '/')
        return 200;
    /* find first space after "HTTP/x.y " */
    const char* p = response;
    while (*p && *p != ' ') p++;
    if (!*p) return 200;
    p++;
    int status = 0;
    for (int i = 0; i < HTTP_STATUS_DIGITS; i++) {
        if (p[i] < '0' || p[i] > '9') return 200;
        status = status * 10 + (p[i] - '0');
    }
    return status > 0 ? status : 200;
}

/* ================= llhttp callbacks ================= */

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
    return buf_append_arena(&ctx->url, &ctx->arena, at, length);
}

static int on_header_field_c(llhttp_t* parser, const char* at, size_t length) {
    client_ctx_t* ctx = (client_ctx_t*)parser->data;
    if (ctx->header_state == HEADER_STATE_VALUE) {
        if (buf_append_arena(&ctx->headers, &ctx->arena, "\r\n", 2) != 0) return -1;
    }
    ctx->header_state = HEADER_STATE_FIELD;
    if (check_header_limit(ctx, length + 2) != 0) return -1;
    return buf_append_arena(&ctx->headers, &ctx->arena, at, length);
}

static int on_header_value_c(llhttp_t* parser, const char* at, size_t length) {
    client_ctx_t* ctx = (client_ctx_t*)parser->data;
    if (ctx->header_state == HEADER_STATE_FIELD) {
        if (buf_append_arena(&ctx->headers, &ctx->arena, ": ", 2) != 0) return -1;
    }
    ctx->header_state = HEADER_STATE_VALUE;
    if (check_header_limit(ctx, length + 2) != 0) return -1;
    return buf_append_arena(&ctx->headers, &ctx->arena, at, length);
}

static int on_headers_complete_c(llhttp_t* parser) {
    client_ctx_t* ctx = (client_ctx_t*)parser->data;
    if (ctx->header_state == HEADER_STATE_VALUE) {
        if (buf_append_arena(&ctx->headers, &ctx->arena, "\r\n", 2) != 0) return -1;
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
        if (buf_reserve_arena(&ctx->body, &ctx->arena, want + 1) != 0) return -1;
    }
    return 0;
}

static int on_body_c(llhttp_t* parser, const char* at, size_t length) {
    client_ctx_t* ctx = (client_ctx_t*)parser->data;
    if (ctx->body.len + length > g_max_body_size) {
        ctx->reject_status = 413;
        return -1;
    }
    return buf_append_arena(&ctx->body, &ctx->arena, at, length);
}

static int on_message_complete_c(llhttp_t* parser) {
    client_ctx_t* ctx = (client_ctx_t*)parser->data;
    void* router = ctx->router ? ctx->router : global_router;
    if (router == NULL) {
        send_response(&ctx->client, http_500, strlen(http_500), 0, MOJO_RESP_BORROWED);
        return 0;
    }
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
                                &resp_owned, ctx->url.len, ctx->headers.len, ctx->body.len);

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
        send_response(&ctx->client, http_500, strlen(http_500), 0, MOJO_RESP_BORROWED);
    }
    if (log_on) log_request(method, url, status, duration_ms);
    return 0;
}

/* ================= read ================= */

static void alloc_buffer_c(uv_handle_t* handle, size_t suggested_size, uv_buf_t* buf) {
    (void)handle; (void)suggested_size;
    static _Thread_local char read_buf[READ_BUFFER_SIZE];
    buf->base = read_buf;
    buf->len = READ_BUFFER_SIZE;
}

static void send_parse_error(client_ctx_t* ctx) {
    const char* resp = http_400;
    if (ctx->reject_status == 431) resp = http_431;
    else if (ctx->reject_status == 413) resp = http_413;
    send_response(&ctx->client, resp, strlen(resp), 0, MOJO_RESP_BORROWED);
    /* OPT: stop reading so we don't enqueue a second response */
    uv_read_stop((uv_stream_t*)&ctx->client);
}

static void on_read_c(uv_stream_t* client, ssize_t nread, const uv_buf_t* buf) {
    if (nread > 0) {
        client_ctx_t* ctx = (client_ctx_t*)client->data;
        if (ctx == NULL) return;
        uint64_t now = uv_now(client->loop);
        ctx->last_active_ms = now;
        heap_update(ctx);
        if (ctx->request_started_ms == 0 && !ctx->processing)
            ctx->request_started_ms = now;

        if (ctx->processing) {
            if (ctx->pending.len + (size_t)nread > g_max_header_size + g_max_body_size) {
                ctx->reject_status = 413;
                send_parse_error(ctx);
                return; /* OPT: P0 fix */
            }
            if (buf_append_arena(&ctx->pending, &ctx->arena, buf->base, (size_t)nread) != 0) {
                send_response((uv_tcp_t*)client, http_500, strlen(http_500), 0, MOJO_RESP_BORROWED);
                uv_read_stop(client);
                return;
            }
        } else {
            enum llhttp_errno err = llhttp_execute(&ctx->parser, buf->base, (size_t)nread);
            if (err != HPE_OK) send_parse_error(ctx);
        }
    } else if (nread < 0) {
        if (!uv_is_closing((uv_handle_t*)client))
            uv_close((uv_handle_t*)client, on_close_c);
    }
}

/* ================= sweep (heap-based) ================= */

static _Thread_local uv_timer_t* g_sweep_timer = NULL;

static void sweep_timeouts_c(uv_timer_t* timer) {
    uint64_t now = uv_now(timer->loop);
    /* idle: pop from heap while expired */
    if (g_idle_timeout_ms > 0) {
        uint64_t idle = (uint64_t)g_idle_timeout_ms;
        while (g_timeout_heap.len > 0) {
            client_ctx_t* c = g_timeout_heap.items[0];
            if (now - c->last_active_ms <= idle) break;
            heap_remove(c);
            if (!uv_is_closing((uv_handle_t*)&c->client))
                uv_close((uv_handle_t*)&c->client, on_close_c);
        }
    }
    /* request timeout: still O(n), but only for processing conns.
    * OPT: if this dominates, add a second heap keyed by request_started_ms. */
    if (g_request_timeout_ms > 0) {
        uint64_t rt = (uint64_t)g_request_timeout_ms;
        client_ctx_t* c = conn_list;
        while (c) {
            client_ctx_t* next = c->next;
            if (!uv_is_closing((uv_handle_t*)&c->client) &&
                c->request_started_ms != 0 && !c->processing &&
                now - c->request_started_ms > rt) {
                uv_close((uv_handle_t*)&c->client, on_close_c);
                }
                c = next;
        }
    }
}

/* ================= graceful shutdown ================= */

static void on_signal(uv_signal_t* handle, int signum) {
    (void)handle; (void)signum;
    if (g_shutdown) return;
    g_shutdown = 1;
    fprintf(stderr, "[C] Received signal %d, starting graceful shutdown...\n", signum);
}

static void check_shutdown_c(uv_timer_t* timer) {
    /* simple ctx: use timer->data as int* stopped */
    int* stopped = (int*)timer->data;
    if (!g_shutdown || *stopped) return;
    if (conn_list == NULL) {
        *stopped = 1;
        fprintf(stderr, "[C] All connections drained, stopping loop\n");
        uv_stop(timer->loop);
        return;
    }
    /* timeout handled by watchdog in thread_main */
}

/* OPT: close listen + all conns */
static void close_all_cb(uv_handle_t* h, void* arg) {
    (void)arg;
    if (uv_is_closing(h)) return;
    if (h->type == UV_TCP) {
        uv_close(h, on_close_c);
    } else {
        uv_close(h, NULL);
    }
}

/* ================= connection ================= */

static void on_connection_c(uv_stream_t* server, int status) {
    ensure_settings_init();
    if (status < 0) return;
    if (g_shutdown) return;

    client_ctx_t* ctx = ctx_alloc();
    if (!ctx) return;

    uv_tcp_init(server->loop, &ctx->client);
    ctx->client.data = ctx;

    ctx->router = global_router;
    arena_init(&ctx->arena, ARENA_DEFAULT_SIZE);
    /* OPT: mark buffers arena-backed lazily on first append */
    buf_init(&ctx->url); ctx->url.arena_backed = 1;
    buf_init(&ctx->headers); ctx->headers.arena_backed = 1;
    buf_init(&ctx->body); ctx->body.arena_backed = 1;
    buf_init(&ctx->pending); ctx->pending.arena_backed = 1;
    ctx->header_state = HEADER_STATE_NONE;
    ctx->processing = 0;
    ctx->last_active_ms = uv_now(server->loop);
    ctx->heap_index = -1;

    llhttp_init(&ctx->parser, HTTP_REQUEST, &g_settings);
    ctx->parser.data = ctx;

    if (uv_accept(server, (uv_stream_t*)&ctx->client) != 0) {
        uv_close((uv_handle_t*)&ctx->client, on_close_c);
        return;
    }
    conn_link(ctx);
    heap_push(ctx);

    int fd = -1;
    if (uv_fileno((uv_handle_t*)&ctx->client, &fd) == 0 && fd >= 0) {
        int nodelay = 1;
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &nodelay, sizeof(nodelay));
        #ifdef TCP_QUICKACK
        int quickack = 1;
        setsockopt(fd, IPPROTO_TCP, TCP_QUICKACK, &quickack, sizeof(quickack));
        #endif
    }

    if (uv_read_start((uv_stream_t*)&ctx->client, alloc_buffer_c, on_read_c) != 0) {
        uv_close((uv_handle_t*)&ctx->client, on_close_c);
    }
}

/* ================= server socket ================= */

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
        fprintf(stderr, "[C] bind port %d failed: %s\n", port, strerror(errno));
        close(fd);
        return -1;
    }
    return fd;
}

/* ================= thread ================= */

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

static pthread_t g_worker_threads[256];
static int g_worker_count = 0;
static pthread_mutex_t g_worker_mutex = PTHREAD_MUTEX_INITIALIZER;

typedef struct {
    int port;
    void* router;
    int thread_id;
} thread_args_t;

static void* thread_main(void* arg) {
    thread_args_t* args = (thread_args_t*)arg;
    current_thread_id = args->thread_id;

    int cpu_id = allowed_cpus[args->thread_id % num_allowed_cpus];
    cpu_set_t cpuset;
    CPU_ZERO(&cpuset);
    CPU_SET(cpu_id, &cpuset);
    pthread_setaffinity_np(pthread_self(), sizeof(cpu_set_t), &cpuset);

    ensure_settings_init();

    int server_fd = create_bound_socket(args->port);
    if (server_fd < 0) { free(args); return NULL; }

    uv_loop_t* loop = (uv_loop_t*)malloc(sizeof(uv_loop_t));
    if (!loop) { close(server_fd); free(args); return NULL; }
    if (uv_loop_init(loop) != 0) { free(loop); close(server_fd); free(args); return NULL; }

    uv_tcp_t* server = (uv_tcp_t*)malloc(sizeof(uv_tcp_t));
    if (!server) { uv_loop_close(loop); free(loop); close(server_fd); free(args); return NULL; }
    uv_tcp_init(loop, server);

    int rc = uv_tcp_open(server, server_fd);
    if (rc != 0) {
        close(server_fd);
        uv_close((uv_handle_t*)server, NULL);
        uv_run(loop, UV_RUN_NOWAIT);
        uv_loop_close(loop);
        free(server); free(loop); free(args);
        return NULL;
    }

    rc = uv_listen((uv_stream_t*)server, LISTEN_BACKLOG, on_connection_c);
    if (rc != 0) {
        uv_close((uv_handle_t*)server, NULL);
        uv_run(loop, UV_RUN_NOWAIT);
        uv_loop_close(loop);
        free(server); free(loop); free(args);
        return NULL;
    }

    uv_timer_t* sweep = NULL;
    if (g_idle_timeout_ms > 0 || g_request_timeout_ms > 0) {
        sweep = (uv_timer_t*)malloc(sizeof(uv_timer_t));
        if (sweep) {
            uv_timer_init(loop, sweep);
            uv_timer_start(sweep, sweep_timeouts_c, 1000, 1000);
        }
    }

    uv_signal_t* sigint_h = (uv_signal_t*)malloc(sizeof(uv_signal_t));
    uv_signal_t* sigterm_h = (uv_signal_t*)malloc(sizeof(uv_signal_t));
    if (sigint_h) { uv_signal_init(loop, sigint_h); uv_signal_start(sigint_h, on_signal, SIGINT); uv_unref((uv_handle_t*)sigint_h); }
    if (sigterm_h) { uv_signal_init(loop, sigterm_h); uv_signal_start(sigterm_h, on_signal, SIGTERM); uv_unref((uv_handle_t*)sigterm_h); }

    /* OPT: shutdown timer started only after signal; here just a watchdog */
    uv_timer_t* shutdown_timer = (uv_timer_t*)malloc(sizeof(uv_timer_t));
    int shutdown_stopped = 0;
    if (shutdown_timer) {
        uv_timer_init(loop, shutdown_timer);
        shutdown_timer->data = &shutdown_stopped;
        uv_timer_start(shutdown_timer, check_shutdown_c, 100, 100);
    }

    printf("[C] Thread %d listening on CPU %d (port %d)\n", args->thread_id, cpu_id, args->port);
    fflush(stdout);

    uv_run(loop, UV_RUN_DEFAULT);

    /* cleanup */
    if (sweep) uv_timer_stop(sweep);
    if (shutdown_timer) uv_timer_stop(shutdown_timer);
    uv_walk(loop, close_all_cb, NULL);
    uv_run(loop, UV_RUN_DEFAULT);
    uv_loop_close(loop);

    free(shutdown_timer);
    free(sigint_h);
    free(sigterm_h);
    free(sweep);
    free(server);
    free(loop);
    free(args);
    return NULL;
}

/* ================= public API ================= */

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
        args->port = port; args->router = router; args->thread_id = i;
        if (pthread_create(&thread, NULL, thread_main, args) != 0) {
            fprintf(stderr, "[C] pthread_create failed for thread %d\n", i);
            free(args); continue;
        }
        pthread_mutex_lock(&g_worker_mutex);
        g_worker_threads[g_worker_count++] = thread;
        pthread_mutex_unlock(&g_worker_mutex);
    }
    printf("[C] All %d threads created\n", num_threads);
    fflush(stdout);
}

void wait_for_shutdown(void) {
    pthread_mutex_lock(&g_worker_mutex);
    int n = g_worker_count;
    pthread_t copy[256];
    for (int i = 0; i < n; i++) copy[i] = g_worker_threads[i];
    pthread_mutex_unlock(&g_worker_mutex);
    for (int i = 0; i < n; i++) pthread_join(copy[i], NULL);
}

void mojelly_ensure_init(void) { ensure_settings_init(); }

/* ================= low-level wrappers (unchanged API) ================= */

void uv_tcp_init_wrapper(uv_loop_t* loop, uv_tcp_t* tcp) { ensure_settings_init(); uv_tcp_init(loop, tcp); }
void uv_tcp_bind_wrapper(uv_tcp_t* tcp, const char* ip, int port) {
    ensure_settings_init();
    struct sockaddr_in addr; uv_ip4_addr(ip, port, &addr);
    unsigned int flags = 0;
    #ifdef UV_TCP_REUSEPORT
    flags |= UV_TCP_REUSEPORT;
    #endif
    int rc = uv_tcp_bind(tcp, (const struct sockaddr*)&addr, flags);
    if (rc != 0) fprintf(stderr, "[C] uv_tcp_bind failed: %s\n", uv_strerror(rc));
}
void uv_listen_wrapper(uv_tcp_t* tcp, int backlog) {
    ensure_settings_init();
    int rc = uv_listen((uv_stream_t*)tcp, backlog, on_connection_c);
    if (rc != 0) fprintf(stderr, "[C] uv_listen failed: %s\n", uv_strerror(rc));
}
void uv_run_wrapper(uv_loop_t* loop) { if (loop) uv_run(loop, UV_RUN_DEFAULT); }
void uv_read_start_wrapper(uv_tcp_t* client) { if (client) uv_read_start((uv_stream_t*)client, alloc_buffer_c, on_read_c); }
void uv_read_stop_wrapper(uv_tcp_t* client) { if (client) uv_read_stop((uv_stream_t*)client); }
void uv_write_wrapper(uv_tcp_t* client, const char* data, size_t len) {
    if (client == NULL || uv_is_closing((uv_handle_t*)client)) return;
    write_req_t* wr = wr_acquire();
    if (!wr) { uv_close((uv_handle_t*)client, on_close_c); return; }
    wr->data = (char*)malloc(len ? len : 1);
    if (!wr->data) { wr_release(wr); uv_close((uv_handle_t*)client, on_close_c); return; }
    if (len) memcpy(wr->data, data, len);
    wr->len = len; wr->client = client; wr->keep_alive = 0; wr->free_data = 1;
    uv_buf_t buf = uv_buf_init(wr->data, (unsigned int)len);
    int rc = uv_write(&wr->req, (uv_stream_t*)client, &buf, 1, on_write_c);
    if (rc != 0) { free(wr->data); wr_release(wr); uv_close((uv_handle_t*)client, on_close_c); }
}
void uv_close_wrapper(uv_tcp_t* client) { if (client && !uv_is_closing((uv_handle_t*)client)) uv_close((uv_handle_t*)client, on_close_c); }
uv_loop_t* uv_loop_create_wrapper(void) {
    ensure_settings_init();
    uv_loop_t* loop = (uv_loop_t*)malloc(sizeof(uv_loop_t));
    if (!loop) return NULL;
    uv_loop_init(loop);
    return loop;
}
void uv_loop_destroy_wrapper(uv_loop_t* loop) {
    if (!loop) return;
    uv_walk(loop, close_all_cb, NULL);
    uv_run(loop, UV_RUN_DEFAULT);
    uv_loop_close(loop);
    free(loop);
}
void mojelly_free_response(char* ptr) { if (ptr) free(ptr); }
