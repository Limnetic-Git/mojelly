#define _GNU_SOURCE
#include <arpa/inet.h>
#include <ctype.h>
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
#include <strings.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#include <uv.h>
#include "multipart_parser.h"

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

#define ARENA_DEFAULT_SIZE (32 * 1024)
#define ARENA_MAX_SIZE (4 * 1024 * 1024)
#define CTX_SLAB_MAX 1024
#define WRITE_REQ_POOL_MAX 4096
#define MAX_UPLOAD_ROUTES 64
#define SENDFILE_CHUNK_SIZE (512 * 1024)
#define SENDFILE_RETRY_MS 2

static size_t g_max_header_size = 64UL << 10;
static size_t g_max_body_size = 10UL << 20;
static size_t g_max_file_size = 100UL << 20;
static size_t g_max_field_size = 1UL << 20;   /* 1 MB per text field */
static int g_max_parts = 100;                 /* max number of parts (files + fields) */
static long g_idle_timeout_ms = 60 * 1000;
static long g_request_timeout_ms = 30 * 1000;
static long g_shutdown_timeout_ms = 30 * 1000;

static volatile sig_atomic_t g_shutdown = 0;

/* ================= Static files config ================= */

typedef struct {
    char prefix[256];
    size_t prefix_len;
    char root_dir[PATH_MAX];
    size_t root_len;
    int enabled;
} static_config_t;

static static_config_t g_static = {{0}, 0, {0}, 0, 0};
static int g_static_frozen = 0;
static pthread_mutex_t g_static_mutex = PTHREAD_MUTEX_INITIALIZER;

int mojelly_set_static_dir(const char* prefix, const char* dir) {
    if (prefix == NULL || dir == NULL || prefix[0] != '/') return -1;

    char resolved[PATH_MAX];
    if (realpath(dir, resolved) == NULL) return -1;

    struct stat st;
    if (stat(resolved, &st) != 0 || !S_ISDIR(st.st_mode)) return -1;

    pthread_mutex_lock(&g_static_mutex);
    if (g_static_frozen) {
        pthread_mutex_unlock(&g_static_mutex);
        return -1;
    }

    size_t plen = strlen(prefix);
    while (plen > 1 && prefix[plen - 1] == '/') plen--;
    if (plen >= sizeof(g_static.prefix)) {
        pthread_mutex_unlock(&g_static_mutex);
        return -1;
    }

    memcpy(g_static.prefix, prefix, plen);
    g_static.prefix[plen] = '\0';
    g_static.prefix_len = plen;

    size_t rlen = strlen(resolved);
    memcpy(g_static.root_dir, resolved, rlen + 1);
    g_static.root_len = rlen;

    __atomic_store_n(&g_static.enabled, 1, __ATOMIC_RELEASE);
    fprintf(stderr, "[C] static dir mounted: %s -> %s\n", g_static.prefix, g_static.root_dir);
    pthread_mutex_unlock(&g_static_mutex);
    return 0;
}

static void freeze_static_config(void) {
    pthread_mutex_lock(&g_static_mutex);
    __atomic_store_n(&g_static_frozen, 1, __ATOMIC_RELEASE);
    pthread_mutex_unlock(&g_static_mutex);
}

/* ================= Upload route registry ================= */

typedef struct {
    char method[16];
    char path[256];
} upload_route_t;

static upload_route_t g_upload_routes[MAX_UPLOAD_ROUTES];
static _Atomic int g_upload_route_count = 0;
static int g_upload_routes_frozen = 0;
static pthread_mutex_t g_upload_routes_mutex = PTHREAD_MUTEX_INITIALIZER;

void mojelly_register_upload_route(const char* method, const char* path) {
    if (method == NULL || path == NULL) return;
    pthread_mutex_lock(&g_upload_routes_mutex);
    if (g_upload_routes_frozen) {
        pthread_mutex_unlock(&g_upload_routes_mutex);
        return;
    }
    int idx = __atomic_load_n(&g_upload_route_count, __ATOMIC_RELAXED);
    if (idx < MAX_UPLOAD_ROUTES) {
        upload_route_t* r = &g_upload_routes[idx];
        strncpy(r->method, method, sizeof(r->method) - 1);
        r->method[sizeof(r->method) - 1] = '\0';
        strncpy(r->path, path, sizeof(r->path) - 1);
        r->path[sizeof(r->path) - 1] = '\0';
        __atomic_store_n(&g_upload_route_count, idx + 1, __ATOMIC_RELEASE);
        fprintf(stderr, "[C] registered upload route: %s %s\n", method, path);
    }
    pthread_mutex_unlock(&g_upload_routes_mutex);
}

static int is_upload_route(const char* method, const char* path) {
    int count = __atomic_load_n(&g_upload_route_count, __ATOMIC_ACQUIRE);
    if (count == 0) return 0;
    if (method == NULL || path == NULL) return 0;
    for (int i = 0; i < count; i++) {
        if (strcmp(g_upload_routes[i].method, method) == 0 &&
            strcmp(g_upload_routes[i].path, path) == 0) {
            return 1;
            }
    }
    return 0;
}

static void freeze_upload_routes(void) {
    pthread_mutex_lock(&g_upload_routes_mutex);
    __atomic_store_n(&g_upload_routes_frozen, 1, __ATOMIC_RELEASE);
    pthread_mutex_unlock(&g_upload_routes_mutex);
}

/* ================= Mojo (FFI-array, 2.3) ================= */

#define MOJO_RESP_OWNED 0
#define MOJO_RESP_BORROWED 1

/* 2.3: struct layouts must match Mojo structs exactly. */
typedef struct {
    const char* name;
    const char* value;
    size_t value_len;
} c_form_field_t;

typedef struct {
    const char* name;
    const char* filename;
    const char* content_type;
    const char* path;
    size_t size;
} c_file_part_t;

extern char* mojo_handler(void* router, const char* url, const char* method,
                          const char* headers, const char* body,
                          size_t* out_len, int* out_ownership,
                          size_t url_len, size_t headers_len, size_t body_len,
                          c_form_field_t* form, size_t form_count,
                          c_file_part_t* files, size_t file_count);

extern uint64_t mojo_websocket_open(void* router,
    const char* url, uint64_t url_len, const char* method, uint64_t method_len,
    const char* headers, uint64_t headers_len, int32_t major, int32_t minor,
    uint64_t max_size, uint64_t max_header_size, uint64_t* out_data, uint64_t* out_len);
extern void mojo_websocket_receive(void* state, const char* data, uint64_t len,
    uint64_t* out_data, uint64_t* out_len, int32_t* out_close);
extern void mojo_websocket_free(void* state);

static void* global_router = NULL;
void mojelly_set_router(void* router) { global_router = router; }

/* ================= Arena allocator ================= */

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
    n = (n + 7) & ~(size_t)7;
    if (a->base != NULL && a->used + n <= a->cap) {
        void* p = a->base + a->used;
        a->used += n;
        return p;
    }
    return NULL;
}

/* ================= Buffer ================= */

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
    size_t new_cap = b->cap ? b->cap : 256;
    while (new_cap < need) {
        if (new_cap > SIZE_MAX / 2) return -1;
        new_cap *= 2;
    }
    if (b->arena_backed && a != NULL && new_cap <= ARENA_MAX_SIZE) {
        char* p = (char*)arena_alloc(a, new_cap);
        if (p) {
            if (b->data && b->len) memcpy(p, b->data, b->len);
            b->data = p;
            b->cap = new_cap;
            return 0;
        }
        char* nd = (char*)malloc(new_cap);
        if (!nd) return -1;
        if (b->data && b->len) memcpy(nd, b->data, b->len);
        b->data = nd;
        b->cap = new_cap;
        b->arena_backed = 0;
        return 0;
    }
    char* nd = (char*)realloc(b->data, new_cap);
    if (!nd) return -1;
    b->data = nd;
    b->cap = new_cap;
    b->arena_backed = 0;
    return 0;
}

static int buf_append_arena(buffer_t* b, arena_t* a, const char* data, size_t len) {
    if (len == 0) return 0;
    if (buf_reserve_arena(b, a, b->len + len + 1) != 0) return -1;
    memcpy(b->data + b->len, data, len);
    b->len += len;
    b->data[b->len] = '\0';
    return 0;
}

/* ================= Static transfer state machine ================= */

typedef enum {
    STATIC_STATE_IDLE = 0,
    STATIC_STATE_SENDING_HEADERS,
    STATIC_STATE_SENDING_FILE,
    STATIC_STATE_RETRY_WAIT,
    STATIC_STATE_ABORTING
} static_state_t;

typedef struct {
    uv_fs_t fs_req;
    uv_timer_t* retry_timer;
    int file_fd;
    int sock_fd;
    int64_t offset;
    int64_t file_size;
    int keep_alive;
    int in_flight;
    int headers_writing;
    int ctx_closing;
    struct timespec start_ts;
} static_transfer_t;

/* ================= Client ctx ================= */

typedef enum {
    HEADER_STATE_NONE = 0,
    HEADER_STATE_FIELD,
    HEADER_STATE_VALUE
} header_state_t;

typedef enum {
    MP_HDR_NONE = 0,
    MP_HDR_CONTENT_DISPOSITION,
    MP_HDR_CONTENT_TYPE,
    MP_HDR_OTHER
} mp_header_t;

typedef struct {
    char name[256];
    char* value;
    size_t value_len;
} mp_form_field_t;

typedef struct {
    char name[256];
    char filename[256];
    char content_type[128];
    char path[256];
    size_t size;
} mp_file_part_t;

/* Все multipart-поля в одной структуре.
 * Аллоцируется только когда запрос реально multipart. */
typedef struct {
    multipart_parser* parser;
    char* boundary;
    mp_header_t last_header;
    char field_name[256];
    char filename[256];
    char content_type[128];
    char temp_path[256];
    FILE* current_file;
    size_t current_size;
    size_t total_size;
    int part_count;
    int error;

    buffer_t field_value;
    mp_form_field_t form[100];
    int form_count;

    mp_file_part_t files[100];
    int file_count;
} multipart_state_t;

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
    int websocket_active;
    void* websocket;
    uint64_t websocket_closing_ms;
    void* router;
    int reject_status;
    uint64_t last_active_ms;
    uint64_t request_started_ms;
    int linked;
    struct client_ctx* prev;
    struct client_ctx* next;

    arena_t arena;
    int in_slab;
    int heap_index;

    int expect_files;
    int is_multipart;

    multipart_state_t* mp;   /* NULL для non-multipart */

    static_state_t static_state;
    static_transfer_t* static_tx; /* NULL для non-static */
} client_ctx_t;

static client_ctx_t* g_ctx_slab[CTX_SLAB_MAX];
static int g_ctx_slab_len = 0;
static pthread_mutex_t g_ctx_slab_mutex = PTHREAD_MUTEX_INITIALIZER;

static void on_retry_timer_close(uv_handle_t* h) {
    free(h);
}

static void static_close_retry_timer(static_transfer_t* st) {
    if (st == NULL || st->retry_timer == NULL) return;
    uv_timer_t* t = st->retry_timer;
    st->retry_timer = NULL;
    uv_timer_stop(t);
    t->data = NULL;
    if (!uv_is_closing((uv_handle_t*)t)) {
        uv_close((uv_handle_t*)t, on_retry_timer_close);
    }
}

static void static_transfer_free(static_transfer_t* st) {
    if (st == NULL) return;
    static_close_retry_timer(st);
    if (st->file_fd >= 0) {
        close(st->file_fd);
        st->file_fd = -1;
    }
    free(st);
}

static multipart_state_t* mp_state_alloc(void) {
    multipart_state_t* mp = (multipart_state_t*)calloc(1, sizeof(multipart_state_t));
    if (mp != NULL) {
        buf_init(&mp->field_value);
        mp->last_header = MP_HDR_NONE;
    }
    return mp;
}

static void mp_form_reset(multipart_state_t* mp) {
    for (int i = 0; i < mp->form_count; i++) {
        if (mp->form[i].value) {
            free(mp->form[i].value);
            mp->form[i].value = NULL;
        }
        mp->form[i].value_len = 0;
        mp->form[i].name[0] = '\0';
    }
    mp->form_count = 0;
}

static void mp_files_reset(multipart_state_t* mp) {
    for (int i = 0; i < mp->file_count; i++) {
        if (mp->files[i].path[0]) {
            unlink(mp->files[i].path);
        }
        mp->files[i].path[0] = '\0';
        mp->files[i].filename[0] = '\0';
        mp->files[i].name[0] = '\0';
        mp->files[i].content_type[0] = '\0';
        mp->files[i].size = 0;
    }
    mp->file_count = 0;
}

static void mp_state_free(multipart_state_t* mp) {
    if (mp == NULL) return;
    if (mp->parser) { multipart_parser_free(mp->parser); mp->parser = NULL; }
    if (mp->boundary) { free(mp->boundary); mp->boundary = NULL; }
    if (mp->current_file) { fclose(mp->current_file); mp->current_file = NULL; }
    if (mp->temp_path[0]) { unlink(mp->temp_path); mp->temp_path[0] = '\0'; }
    mp_form_reset(mp);
    buf_free(&mp->field_value);
    mp_files_reset(mp);
    free(mp);
}

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
    if (c) {
        c->in_slab = 0;
        c->heap_index = -1;
    }
    return c;
}

static void ctx_free(client_ctx_t* c) {
    if (!c) return;
    if (c->websocket != NULL) {
        mojo_websocket_free(c->websocket);
        c->websocket = NULL;
    }
    mp_state_free(c->mp);
    c->mp = NULL;
    static_transfer_free(c->static_tx);
    c->static_tx = NULL;
    c->static_state = STATIC_STATE_IDLE;
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

typedef struct {
    client_ctx_t** items;
    int len;
    int cap;
} heap_t;

static _Thread_local heap_t g_timeout_heap = {NULL, 0, 0};

static inline uint64_t deadline_of(client_ctx_t* c) {
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
    /* sendfile(2) на закрытом сокете шлёт SIGPIPE — игнорируем, обрабатываем EPIPE */
    signal(SIGPIPE, SIG_IGN);

    const char* lvl = getenv("MOJELLY_LOG_LEVEL");
    if (lvl != NULL) g_log_level = atoi(lvl);
    const char* v;
    if ((v = getenv("MOJELLY_MAX_HEADER_SIZE")) && atol(v) > 0)
        g_max_header_size = (size_t)atol(v);
    if ((v = getenv("MOJELLY_MAX_BODY")) && atol(v) > 0)
        g_max_body_size = (size_t)atol(v);
    if ((v = getenv("MOJELLY_MAX_FILE_SIZE")) && atol(v) > 0)
        g_max_file_size = (size_t)atol(v);
    if ((v = getenv("MOJELLY_MAX_FIELD_SIZE")) && atol(v) > 0)
        g_max_field_size = (size_t)atol(v);
    if ((v = getenv("MOJELLY_MAX_PARTS")) && atoi(v) > 0)
        g_max_parts = atoi(v);
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
static const char* http_415 =
"HTTP/1.1 415 Unsupported Media Type\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
static const char* http_400 =
"HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
static const char* http_403 =
"HTTP/1.1 403 Forbidden\r\nContent-Length: 9\r\nContent-Type: text/plain\r\nConnection: close\r\n\r\nForbidden";
static const char* http_404 =
"HTTP/1.1 404 Not Found\r\nContent-Length: 9\r\nContent-Type: text/plain\r\nConnection: keep-alive\r\n\r\nNot Found";

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

/* ================= Conn list ================= */

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

static void send_parse_error(client_ctx_t* ctx);

static void websocket_receive(client_ctx_t* ctx, const char* data, size_t len) {
    if (ctx->websocket == NULL || uv_is_closing((uv_handle_t*)&ctx->client)) return;
    uint64_t output_address = 0;
    uint64_t output_len = 0;
    int32_t close_state = 0;
    mojo_websocket_receive(ctx->websocket, data, len, &output_address, &output_len, &close_state);
    char* output = (char*)(uintptr_t)output_address;
    if (close_state == 2 && ctx->websocket_closing_ms == 0)
        ctx->websocket_closing_ms = uv_now(ctx->client.loop);
    /* Bound queued output for clients that stop reading. */
    if ((output_len > 0 && output == NULL) || output_len > (20UL << 20) ||
        uv_stream_get_write_queue_size((uv_stream_t*)&ctx->client) > (20UL << 20) - output_len) {
        free(output);
        uv_close((uv_handle_t*)&ctx->client, on_close_c);
        return;
    }
    if (close_state == 1) uv_read_stop((uv_stream_t*)&ctx->client);
    if (output_len > 0) {
        send_response(&ctx->client, output, (size_t)output_len, close_state != 1, MOJO_RESP_OWNED);
    } else if (close_state == 1) {
        /* Queue an empty write so earlier frames drain before closing. */
        send_response(&ctx->client, "", 0, 0, MOJO_RESP_BORROWED);
    }
}

static void execute_http(client_ctx_t* ctx, const char* data, size_t len) {
    enum llhttp_errno err = llhttp_execute(&ctx->parser, data, len);
    if (err == HPE_PAUSED_UPGRADE && ctx->websocket_active) {
        const char* rest = llhttp_get_error_pos(&ctx->parser);
        if (ctx->websocket != NULL && rest != NULL && rest < data + len)
            websocket_receive(ctx, rest, (size_t)(data + len - rest));
        return;
    }
    if (err != HPE_OK) send_parse_error(ctx);
}

/* ================= Keep-alive reset ================= */

static void reset_for_next_request(client_ctx_t* ctx) {
    ctx->last_active_ms = uv_now(ctx->client.loop);
    ctx->request_started_ms = 0;
    heap_update(ctx);
    buf_reset(&ctx->url);
    buf_reset(&ctx->headers);
    buf_reset(&ctx->body);
    arena_reset(&ctx->arena);
    ctx->header_state = HEADER_STATE_NONE;
    ctx->reject_status = 0;
    ctx->processing = 0;
    ctx->expect_files = 0;
    ctx->is_multipart = 0;

    mp_state_free(ctx->mp);
    ctx->mp = NULL;

    llhttp_init(&ctx->parser, HTTP_REQUEST, &g_settings);
    ctx->parser.data = ctx;

    if (ctx->pending.len > 0) {
        char* pdata = ctx->pending.data;
        size_t plen = ctx->pending.len;
        ctx->pending.data = NULL;
        ctx->pending.len = 0;
        ctx->pending.cap = 0;
        ctx->pending.arena_backed = 0;

        execute_http(ctx, pdata, plen);
        free(pdata);
    }
}

/* ================= close ================= */

static void on_close_c(uv_handle_t* handle) {
    client_ctx_t* ctx = (client_ctx_t*)handle->data;
    if (ctx == NULL) return;
    conn_unlink(ctx);
    heap_remove(ctx);

    if (ctx->static_tx != NULL) {
        static_transfer_t* st = ctx->static_tx;
        static_close_retry_timer(st);
        ctx->static_state = STATIC_STATE_ABORTING;
        st->ctx_closing = 1;
        if (st->in_flight || st->headers_writing) {
            /* Откладываем ctx_free до завершения async callback'а */
            return;
        }
        static_transfer_free(st);
        ctx->static_tx = NULL;
        ctx->static_state = STATIC_STATE_IDLE;
    }

    ctx_free(ctx);
}

/* ================= Static files (uv_fs_sendfile) ================= */

static int hex_val(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

static int url_decode_path(const char* src, size_t src_len, char* dst, size_t dst_sz) {
    size_t out = 0;
    for (size_t i = 0; i < src_len; i++) {
        char c = src[i];
        if (c == '%') {
            if (i + 2 >= src_len) return -1;
            int hi = hex_val(src[i + 1]);
            int lo = hex_val(src[i + 2]);
            if (hi < 0 || lo < 0) return -1;
            unsigned char decoded = (unsigned char)((hi << 4) | lo);
            if (decoded == 0) return -1; /* Запрещаем NUL-байт */
                c = (char)decoded;
            i += 2;
        }
        if (out + 1 >= dst_sz) return -1;
        dst[out++] = c;
    }
    dst[out] = '\0';
    return 0;
}

static const char* get_mime_type(const char* path) {
    const char* dot = strrchr(path, '.');
    if (dot == NULL || dot[1] == '\0') return "application/octet-stream";
    dot++;
    if (strcasecmp(dot, "html") == 0 || strcasecmp(dot, "htm") == 0) return "text/html; charset=utf-8";
    if (strcasecmp(dot, "css") == 0) return "text/css; charset=utf-8";
    if (strcasecmp(dot, "js") == 0 || strcasecmp(dot, "mjs") == 0) return "application/javascript; charset=utf-8";
    if (strcasecmp(dot, "json") == 0) return "application/json; charset=utf-8";
    if (strcasecmp(dot, "txt") == 0) return "text/plain; charset=utf-8";
    if (strcasecmp(dot, "xml") == 0) return "application/xml; charset=utf-8";
    if (strcasecmp(dot, "svg") == 0) return "image/svg+xml";
    if (strcasecmp(dot, "png") == 0) return "image/png";
    if (strcasecmp(dot, "jpg") == 0 || strcasecmp(dot, "jpeg") == 0) return "image/jpeg";
    if (strcasecmp(dot, "gif") == 0) return "image/gif";
    if (strcasecmp(dot, "webp") == 0) return "image/webp";
    if (strcasecmp(dot, "ico") == 0) return "image/x-icon";
    if (strcasecmp(dot, "woff2") == 0) return "font/woff2";
    if (strcasecmp(dot, "woff") == 0) return "font/woff";
    if (strcasecmp(dot, "ttf") == 0) return "font/ttf";
    if (strcasecmp(dot, "pdf") == 0) return "application/pdf";
    if (strcasecmp(dot, "wasm") == 0) return "application/wasm";
    if (strcasecmp(dot, "mp4") == 0) return "video/mp4";
    if (strcasecmp(dot, "webm") == 0) return "video/webm";
    if (strcasecmp(dot, "mp3") == 0) return "audio/mpeg";
    return "application/octet-stream";
}

/* Возвращает:
    *   0 — валидный файл, путь записан в out_path
    *   1 — не совпадает с префиксом (прокинуть в Mojo-роутер)
    *  -1 — файл не найден / директория
    *  -2 — попытка path traversal или невалидный URL
    */
static int resolve_static_file(const char* url, char* out_path, size_t out_sz) {
    if (!__atomic_load_n(&g_static.enabled, __ATOMIC_ACQUIRE) || url == NULL) return 1;

    const char* rel = NULL;
    if (g_static.prefix_len == 1 && g_static.prefix[0] == '/') {
        if (url[0] != '/') return 1;
        rel = url + 1;
    } else {
        if (strncmp(url, g_static.prefix, g_static.prefix_len) != 0) return 1;
        if (url[g_static.prefix_len] != '/') return 1;
        rel = url + g_static.prefix_len + 1;
    }

    size_t rel_len = 0;
    while (rel[rel_len] != '\0' && rel[rel_len] != '?' && rel[rel_len] != '#') {
        rel_len++;
    }
    if (rel_len == 0) return -1;

    char decoded[PATH_MAX];
    if (url_decode_path(rel, rel_len, decoded, sizeof(decoded)) != 0) return -2;

    char candidate[PATH_MAX];
    int n = snprintf(candidate, sizeof(candidate), "%s/%s", g_static.root_dir, decoded);
    if (n < 0 || (size_t)n >= sizeof(candidate)) return -2;

    char resolved[PATH_MAX];
    if (realpath(candidate, resolved) == NULL) return -1;

    if (strncmp(resolved, g_static.root_dir, g_static.root_len) != 0) return -2;
    if (!(g_static.root_len == 1 && g_static.root_dir[0] == '/')) {
        char boundary = resolved[g_static.root_len];
        if (boundary != '/' && boundary != '\0') return -2;
    }

    size_t res_len = strlen(resolved);
    if (res_len >= out_sz) return -2;
    memcpy(out_path, resolved, res_len + 1);
    return 0;
}

static void static_finish_aborted(client_ctx_t* ctx) {
    static_transfer_t* st = ctx->static_tx;
    if (st == NULL) return;
    if (st->in_flight || st->headers_writing) return;

    int should_free_ctx = st->ctx_closing;
    static_transfer_free(st);
    ctx->static_tx = NULL;
    ctx->static_state = STATIC_STATE_IDLE;

    if (should_free_ctx) {
        ctx_free(ctx);
    } else if (!uv_is_closing((uv_handle_t*)&ctx->client)) {
        uv_close((uv_handle_t*)&ctx->client, on_close_c);
    }
}

static void static_cleanup_and_finish(client_ctx_t* ctx, int ok) {
    static_transfer_t* st = ctx->static_tx;
    if (st == NULL) return;

    int keep_alive = ok && st->keep_alive;
    if (g_log_level >= 1) {
        struct timespec end_ts;
        clock_gettime(CLOCK_MONOTONIC, &end_ts);
        double duration_ms = (end_ts.tv_sec - st->start_ts.tv_sec) * 1000.0 +
        (end_ts.tv_nsec - st->start_ts.tv_nsec) / 1000000.0;
        log_request("GET", ctx->url.data ? ctx->url.data : "", ok ? 200 : 500, duration_ms);
    }

    static_transfer_free(st);
    ctx->static_tx = NULL;
    ctx->static_state = STATIC_STATE_IDLE;

    if (uv_is_closing((uv_handle_t*)&ctx->client)) return;

    if (!keep_alive) {
        uv_close((uv_handle_t*)&ctx->client, on_close_c);
        return;
    }

    reset_for_next_request(ctx);
}

static void on_sendfile_cb(uv_fs_t* req);

static void sendfile_next_chunk(client_ctx_t* ctx) {
    static_transfer_t* st = ctx->static_tx;
    if (st == NULL) return;

    if (st->offset >= st->file_size) {
        static_cleanup_and_finish(ctx, 1);
        return;
    }

    size_t remain = (size_t)(st->file_size - st->offset);
    size_t chunk = remain > SENDFILE_CHUNK_SIZE ? SENDFILE_CHUNK_SIZE : remain;

    st->fs_req.data = ctx;
    st->in_flight = 1;
    int rc = uv_fs_sendfile(ctx->client.loop, &st->fs_req,
                            st->sock_fd, st->file_fd,
                            st->offset, chunk, on_sendfile_cb);
    if (rc < 0) {
        st->in_flight = 0;
        static_cleanup_and_finish(ctx, 0);
    }
}

static void on_sendfile_retry_timer(uv_timer_t* t) {
    client_ctx_t* ctx = (client_ctx_t*)t->data;
    if (ctx == NULL) return;
    static_transfer_t* st = ctx->static_tx;
    if (st == NULL || ctx->static_state != STATIC_STATE_RETRY_WAIT ||
        uv_is_closing((uv_handle_t*)&ctx->client)) {
        return;
        }
        ctx->static_state = STATIC_STATE_SENDING_FILE;
    sendfile_next_chunk(ctx);
}

static void on_sendfile_cb(uv_fs_t* req) {
    client_ctx_t* ctx = (client_ctx_t*)req->data;
    ssize_t res = req->result;
    uv_fs_req_cleanup(req);

    if (ctx == NULL || ctx->static_tx == NULL) return;
    static_transfer_t* st = ctx->static_tx;
    st->in_flight = 0;

    if (ctx->static_state == STATIC_STATE_ABORTING ||
        uv_is_closing((uv_handle_t*)&ctx->client)) {
        static_finish_aborted(ctx);
    return;
        }

        if (res > 0) {
            st->offset += res;
            ctx->last_active_ms = uv_now(ctx->client.loop);
            heap_update(ctx);
            sendfile_next_chunk(ctx);
        } else if (res == -UV_EAGAIN) {
            if (st->retry_timer == NULL) {
                st->retry_timer = (uv_timer_t*)malloc(sizeof(uv_timer_t));
                if (st->retry_timer == NULL) {
                    static_cleanup_and_finish(ctx, 0);
                    return;
                }
                uv_timer_init(ctx->client.loop, st->retry_timer);
            }
            st->retry_timer->data = ctx;
            ctx->static_state = STATIC_STATE_RETRY_WAIT;
            if (uv_timer_start(st->retry_timer, on_sendfile_retry_timer, SENDFILE_RETRY_MS, 0) != 0) {
                static_cleanup_and_finish(ctx, 0);
            }
        } else {
            static_cleanup_and_finish(ctx, 0);
        }
}

static void on_static_headers_written(uv_write_t* req, int status) {
    write_req_t* wr = (write_req_t*)req;
    if (wr->free_data && wr->data != NULL) free(wr->data);
    wr->data = NULL;
    uv_tcp_t* client = wr->client;
    wr_release(wr);

    if (client == NULL) return;
    client_ctx_t* ctx = (client_ctx_t*)client->data;
    if (ctx == NULL || ctx->static_tx == NULL) return;

    static_transfer_t* st = ctx->static_tx;
    st->headers_writing = 0;

    if (ctx->static_state == STATIC_STATE_ABORTING || uv_is_closing((uv_handle_t*)client)) {
        static_finish_aborted(ctx);
        return;
    }

    if (status != 0) {
        static_cleanup_and_finish(ctx, 0);
        return;
    }

    ctx->static_state = STATIC_STATE_SENDING_FILE;
    sendfile_next_chunk(ctx);
}

/* Возвращает 1 если запрос обработан статикой, 0 если нужно отдать в Mojo-роутер */
static int try_serve_static(client_ctx_t* ctx, const char* method, const char* url) {
    int is_get = (strcmp(method, "GET") == 0);
    int is_head = (strcmp(method, "HEAD") == 0);
    if (!is_get && !is_head) return 0;

    char resolved[PATH_MAX];
    int rc = resolve_static_file(url, resolved, sizeof(resolved));
    if (rc == 1) return 0; /* Не наш префикс */

        if (rc == -2) {
            send_response(&ctx->client, http_403, strlen(http_403), 0, MOJO_RESP_BORROWED);
            if (g_log_level >= 1) log_request(method, url, 403, 0.0);
            return 1;
        }

        int fd = -1;
    struct stat st_buf;
    if (rc == 0) {
        fd = open(resolved, O_RDONLY | O_CLOEXEC);
        if (fd >= 0 && (fstat(fd, &st_buf) != 0 || !S_ISREG(st_buf.st_mode))) {
            close(fd);
            fd = -1;
        }
    }

    if (fd < 0) {
        /* Если префикс "/", даём шанс динамическим роутам Mojo */
        if (g_static.prefix_len == 1 && g_static.prefix[0] == '/') return 0;
        send_response(&ctx->client, http_404, strlen(http_404), ctx->keep_alive, MOJO_RESP_BORROWED);
        if (g_log_level >= 1) log_request(method, url, 404, 0.0);
        return 1;
    }

    const char* mime = get_mime_type(resolved);
    int64_t file_size = (int64_t)st_buf.st_size;
    int keep_alive = ctx->keep_alive;

    char* hdr_buf = (char*)malloc(512);
    if (hdr_buf == NULL) {
        close(fd);
        send_response(&ctx->client, http_500, strlen(http_500), 0, MOJO_RESP_BORROWED);
        return 1;
    }

    int hdr_len = snprintf(hdr_buf, 512,
                            "HTTP/1.1 200 OK\r\n"
                            "Content-Type: %s\r\n"
                            "Content-Length: %lld\r\n"
                            "Connection: %s\r\n"
                            "\r\n",
                            mime, (long long)file_size,
                            keep_alive ? "keep-alive" : "close");
    if (hdr_len <= 0 || hdr_len >= 512) {
        free(hdr_buf);
        close(fd);
        send_response(&ctx->client, http_500, strlen(http_500), 0, MOJO_RESP_BORROWED);
        return 1;
    }

    /* Для HEAD или пустого файла sendfile не нужен */
    if (is_head || file_size == 0) {
        close(fd);
        send_response(&ctx->client, hdr_buf, (size_t)hdr_len, keep_alive, MOJO_RESP_OWNED);
        if (g_log_level >= 1) log_request(method, url, 200, 0.0);
        return 1;
    }

    int sock_fd = -1;
    if (uv_fileno((uv_handle_t*)&ctx->client, &sock_fd) != 0 || sock_fd < 0) {
        free(hdr_buf);
        close(fd);
        send_response(&ctx->client, http_500, strlen(http_500), 0, MOJO_RESP_BORROWED);
        return 1;
    }

    static_transfer_t* st = (static_transfer_t*)calloc(1, sizeof(static_transfer_t));
    write_req_t* wr = wr_acquire();
    if (st == NULL || wr == NULL) {
        free(st);
        if (wr) wr_release(wr);
        free(hdr_buf);
        close(fd);
        send_response(&ctx->client, http_500, strlen(http_500), 0, MOJO_RESP_BORROWED);
        return 1;
    }

    st->file_fd = fd;
    st->sock_fd = sock_fd;
    st->offset = 0;
    st->file_size = file_size;
    st->keep_alive = keep_alive;
    st->headers_writing = 1;
    if (g_log_level >= 1) clock_gettime(CLOCK_MONOTONIC, &st->start_ts);

    ctx->processing = 1;
    ctx->static_tx = st;
    ctx->static_state = STATIC_STATE_SENDING_HEADERS;

    wr->client = &ctx->client;
    wr->data = hdr_buf;
    wr->len = (size_t)hdr_len;
    wr->keep_alive = keep_alive;
    wr->free_data = 1;

    uv_buf_t buf = uv_buf_init(wr->data, (unsigned int)wr->len);
    int wrc = uv_write(&wr->req, (uv_stream_t*)&ctx->client, &buf, 1, on_static_headers_written);
    if (wrc != 0) {
        free(wr->data);
        wr_release(wr);
        st->headers_writing = 0;
        static_cleanup_and_finish(ctx, 0);
    }
    return 1;
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
    if (ctx != NULL && !ctx->websocket_active) {
        reset_for_next_request(ctx);
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

static int extract_status_from_response(const char* response, size_t resp_len) {
    if (response == NULL || resp_len < 12) return 500;
    if (response[0] != 'H' || response[1] != 'T' || response[2] != 'T' ||
        response[3] != 'P' || response[4] != '/')
        return 200;
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

/* ================= multipart helpers ================= */

static void safe_copy(char* dst, size_t dstsz, const char* at, size_t length) {
    if (dstsz == 0) return;
    size_t n = length < dstsz - 1 ? length : dstsz - 1;
    memcpy(dst, at, n);
    dst[n] = '\0';
}

static const char* find_ci(const char* hay, size_t haylen, const char* needle) {
    size_t nlen = strlen(needle);
    if (nlen == 0 || haylen < nlen) return NULL;
    for (size_t i = 0; i + nlen <= haylen; i++) {
        if (strncasecmp(hay + i, needle, nlen) == 0) return hay + i;
    }
    return NULL;
}

static void copy_range(char* dst, size_t dstsz, const char* at, size_t start, size_t end) {
    if (end <= start) { if (dstsz) dst[0] = '\0'; return; }
    size_t n = end - start;
    if (n >= dstsz) n = dstsz - 1;
    memcpy(dst, at + start, n);
    dst[n] = '\0';
}

static void sanitize_filename(char* name) {
    if (name == NULL || name[0] == '\0') return;
    char* base = name;
    for (char* p = name; *p != '\0'; p++) {
        if (*p == '/' || *p == '\\') base = p + 1;
    }
    if (base != name) {
        size_t n = strlen(base);
        memmove(name, base, n + 1);
    }
    if (strcmp(name, ".") == 0 || strcmp(name, "..") == 0) {
        name[0] = '\0';
    }
}

static int mp_on_header_field(multipart_parser* p, const char* at, size_t length) {
    client_ctx_t* ctx = (client_ctx_t*)multipart_parser_get_data(p);
    multipart_state_t* mp = ctx->mp;
    if (mp == NULL) return -1;
    if (length >= 19 && strncasecmp(at, "Content-Disposition", 19) == 0) {
        mp->last_header = MP_HDR_CONTENT_DISPOSITION;
    } else if (length >= 12 && strncasecmp(at, "Content-Type", 12) == 0) {
        mp->last_header = MP_HDR_CONTENT_TYPE;
    } else {
        mp->last_header = MP_HDR_OTHER;
    }
    return 0;
}

static int mp_on_header_value(multipart_parser* p, const char* at, size_t length) {
    client_ctx_t* ctx = (client_ctx_t*)multipart_parser_get_data(p);
    multipart_state_t* mp = ctx->mp;
    if (mp == NULL) return -1;

    if (mp->last_header == MP_HDR_CONTENT_DISPOSITION) {
        const char* name_p = find_ci(at, length, "name=\"");
        if (name_p != NULL) {
            size_t off = (size_t)(name_p - at) + 6;
            size_t end = off;
            while (end < length && at[end] != '"') end++;
            copy_range(mp->field_name, sizeof(mp->field_name), at, off, end);
        }
        const char* fname_p = find_ci(at, length, "filename=\"");
        if (fname_p != NULL) {
            size_t off = (size_t)(fname_p - at) + 10;
            size_t end = off;
            while (end < length && at[end] != '"') end++;
            copy_range(mp->filename, sizeof(mp->filename), at, off, end);
            sanitize_filename(mp->filename);
        }
    } else if (mp->last_header == MP_HDR_CONTENT_TYPE) {
        safe_copy(mp->content_type, sizeof(mp->content_type), at, length);
    }
    return 0;
}

static int mp_on_part_data_begin(multipart_parser* p) {
    client_ctx_t* ctx = (client_ctx_t*)multipart_parser_get_data(p);
    multipart_state_t* mp = ctx->mp;
    if (mp == NULL) return -1;
    mp->current_size = 0;
    mp->current_file = NULL;
    mp->temp_path[0] = '\0';
    buf_reset(&mp->field_value);
    return 0;
}

static int mp_on_part_data(multipart_parser* p, const char* at, size_t length) {
    client_ctx_t* ctx = (client_ctx_t*)multipart_parser_get_data(p);
    multipart_state_t* mp = ctx->mp;
    if (mp == NULL) return -1;

    if (mp->filename[0] != '\0') {
        if (mp->current_file == NULL) {
            char tmpl[] = "/tmp/mojelly-upload-XXXXXX";
            int fd = mkstemp(tmpl);
            if (fd < 0) { mp->error = 1; return -1; }
            mp->current_file = fdopen(fd, "wb");
            if (!mp->current_file) {
                close(fd); unlink(tmpl); mp->error = 1; return -1;
            }
            strncpy(mp->temp_path, tmpl, sizeof(mp->temp_path) - 1);
            mp->temp_path[sizeof(mp->temp_path) - 1] = '\0';
        }
        /* Payload too large: total body first, then per-file. */
        if (mp->total_size + length > g_max_body_size) {
            mp->error = 1;
            ctx->reject_status = 413;
            return -1;
        }
        if (mp->current_size + length > g_max_file_size) {
            mp->error = 1;
            ctx->reject_status = 413;
            return -1;
        }
        size_t written = fwrite(at, 1, length, mp->current_file);
        if (written != length) { mp->error = 1; return -1; }
        mp->current_size += length;
        mp->total_size += length;
    } else {
        if (mp->field_value.len + length > g_max_field_size) {
            mp->error = 1;
            return -1;
        }
        if (buf_append_arena(&mp->field_value, &ctx->arena, at, length) != 0) {
            mp->error = 1;
            return -1;
        }
        mp->total_size += length;
        if (mp->total_size > g_max_body_size) {
            mp->error = 1;
            ctx->reject_status = 413;
            return -1;
        }
    }
    return 0;
}

static int mp_on_part_data_end(multipart_parser* p) {
    client_ctx_t* ctx = (client_ctx_t*)multipart_parser_get_data(p);
    multipart_state_t* mp = ctx->mp;
    if (mp == NULL) return -1;

    if (mp->current_file != NULL) {
        if (fflush(mp->current_file) != 0) mp->error = 1;
        if (fclose(mp->current_file) != 0) mp->error = 1;
        mp->current_file = NULL;
        mp->part_count++;

        if (!mp->error && mp->filename[0] != '\0') {
            if (mp->file_count >= g_max_parts || mp->file_count >= 100) {
                mp->error = 1;
            } else {
                mp_file_part_t* f = &mp->files[mp->file_count];
                strncpy(f->name, mp->field_name, sizeof(f->name) - 1);
                f->name[sizeof(f->name) - 1] = '\0';
                strncpy(f->filename, mp->filename, sizeof(f->filename) - 1);
                f->filename[sizeof(f->filename) - 1] = '\0';
                strncpy(f->content_type, mp->content_type, sizeof(f->content_type) - 1);
                f->content_type[sizeof(f->content_type) - 1] = '\0';
                strncpy(f->path, mp->temp_path, sizeof(f->path) - 1);
                f->path[sizeof(f->path) - 1] = '\0';
                f->size = mp->current_size;
                mp->file_count++;
                mp->temp_path[0] = '\0';
            }
        }
    } else {
        if (mp->field_name[0] != '\0' && !mp->error) {
            if (mp->form_count >= g_max_parts || mp->form_count >= 100) {
                mp->error = 1;
            } else {
                mp_form_field_t* f = &mp->form[mp->form_count];
                strncpy(f->name, mp->field_name, sizeof(f->name) - 1);
                f->name[sizeof(f->name) - 1] = '\0';
                f->value_len = mp->field_value.len;
                if (f->value_len > 0) {
                    f->value = (char*)malloc(f->value_len + 1);
                    if (f->value == NULL) {
                        mp->error = 1;
                    } else {
                        memcpy(f->value, mp->field_value.data, f->value_len);
                        f->value[f->value_len] = '\0';
                        mp->form_count++;
                    }
                } else {
                    f->value = NULL;
                    mp->form_count++;
                }
            }
        }
        buf_reset(&mp->field_value);
    }

    mp->filename[0] = '\0';
    mp->field_name[0] = '\0';
    mp->content_type[0] = '\0';
    mp->last_header = MP_HDR_NONE;
    return 0;
}

static int mp_on_body_end(multipart_parser* p) {
    (void)p;
    return 0;
}

static multipart_parser_settings g_mp_settings = {
    .on_header_field = mp_on_header_field,
    .on_header_value = mp_on_header_value,
    .on_part_data = mp_on_part_data,
    .on_part_data_begin = mp_on_part_data_begin,
    .on_part_data_end = mp_on_part_data_end,
    .on_body_end = mp_on_body_end,
};

static char* extract_boundary(const char* content_type) {
    if (content_type == NULL) return NULL;
    const char* p = strcasestr(content_type, "boundary=");
    if (p == NULL) return NULL;
    p += 9;
    while (*p == ' ' || *p == '\t') p++;
    const char* start = p;
    char quote = 0;
    if (*start == '"') { quote = '"'; start++; }
    const char* end = start;
    if (quote != 0) {
        while (*end != '\0' && *end != quote) end++;
    } else {
        while (*end != '\0' && *end != ';' && *end != '\r' &&
            *end != '\n' && *end != ' ') end++;
    }
    size_t len = (size_t)(end - start);
    char* boundary = (char*)malloc(len + 1);
    if (boundary == NULL) return NULL;
    memcpy(boundary, start, len);
    boundary[len] = '\0';
    return boundary;
}

/* ================= llhttp callbacks ================= */

static int on_message_begin_c(llhttp_t* parser) {
    client_ctx_t* ctx = (client_ctx_t*)parser->data;
    ctx->reject_status = 0;
    ctx->expect_files = 0;
    ctx->keep_alive = 1;
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

static const char* find_content_type(const char* headers, size_t len) {
    static const char needle[] = "Content-Type:";
    const size_t nlen = sizeof(needle) - 1;
    for (size_t i = 0; i + nlen <= len; i++) {
        if (i != 0) {
            if (!(i >= 2 && headers[i - 2] == '\r' && headers[i - 1] == '\n')) {
                continue;
            }
        }
        if (strncasecmp(headers + i, needle, nlen) == 0) {
            const char* v = headers + i + nlen;
            size_t remaining = len - (i + nlen);
            while (remaining > 0 && (*v == ' ' || *v == '\t')) {
                v++;
                remaining--;
            }
            size_t vlen = 0;
            while (vlen < remaining && v[vlen] != '\r' && v[vlen] != '\n') vlen++;
            if (vlen == 0) return NULL;
            return v;
        }
    }
    return NULL;
}

static int on_headers_complete_c(llhttp_t* parser) {
    client_ctx_t* ctx = (client_ctx_t*)parser->data;

    const char* content_type = find_content_type(ctx->headers.data, ctx->headers.len);
    const int is_multipart = (content_type != NULL) &&
    (strncasecmp(content_type, "multipart/form-data", 19) == 0);

    if (is_multipart) {
        const char* method = llhttp_method_name((llhttp_method_t)parser->method);
        ctx->expect_files = (method != NULL && ctx->url.data != NULL)
        ? is_upload_route(method, ctx->url.data) : 0;
        if (!ctx->expect_files) {
            ctx->reject_status = 415;
            return -1;
        }
        ctx->is_multipart = 1;

        ctx->mp = mp_state_alloc();
        if (ctx->mp == NULL) {
            ctx->reject_status = 500;
            return -1;
        }

        ctx->mp->boundary = extract_boundary(content_type);
        if (ctx->mp->boundary != NULL) {
            ctx->mp->parser = multipart_parser_init(ctx->mp->boundary, &g_mp_settings);
            if (ctx->mp->parser == NULL) {
                ctx->reject_status = 500;
                return -1;
            }
            multipart_parser_set_data(ctx->mp->parser, ctx);
        } else {
            ctx->mp->error = 1;
            ctx->reject_status = 400;
            return -1;
        }
        ctx->header_state = HEADER_STATE_NONE;
        ctx->keep_alive = llhttp_should_keep_alive(parser);
        return 0;
    }

    if (ctx->header_state == HEADER_STATE_VALUE) {
        if (buf_append_arena(&ctx->headers, &ctx->arena, "\r\n", 2) != 0) return -1;
    }
    ctx->header_state = HEADER_STATE_NONE;
    ctx->keep_alive = llhttp_should_keep_alive(parser);
    /* llhttp must stop at the end of upgrade headers, before any frames. */
    if (parser->upgrade) return 2;
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

    if (ctx->is_multipart) {
        if (ctx->mp == NULL || ctx->mp->parser == NULL || ctx->mp->error) {
            ctx->reject_status = 400;
            return -1;
        }
        size_t parsed = multipart_parser_execute(ctx->mp->parser, at, length);
        if (parsed != length) {
            ctx->mp->error = 1;
            if (ctx->reject_status == 0) {
                ctx->reject_status = 400;
            }
            return -1;
        }
        return 0;
    }

    if (ctx->body.len + length > g_max_body_size) {
        ctx->reject_status = 413;
        return -1;
    }
    return buf_append_arena(&ctx->body, &ctx->arena, at, length);
}

static int on_message_complete_c(llhttp_t* parser) {
    client_ctx_t* ctx = (client_ctx_t*)parser->data;

    if (ctx->mp != NULL && ctx->mp->error) {
        send_response(&ctx->client, http_500, strlen(http_500), 0, MOJO_RESP_BORROWED);
        return 0;
    }

    const char* method = llhttp_method_name((llhttp_method_t)parser->method);
    const char* url = ctx->url.data ? ctx->url.data : "";

    if (parser->upgrade) {
        void* router = ctx->router ? ctx->router : global_router;
        uint64_t output_address = 0;
        uint64_t output_len = 0;
        ctx->websocket_active = 1;
        ctx->processing = 1;
        ctx->request_started_ms = 0;
        if (router != NULL) {
            ctx->websocket = (void*)(uintptr_t)mojo_websocket_open(router, url, ctx->url.len,
                method, strlen(method), ctx->headers.data, ctx->headers.len,
                parser->http_major, parser->http_minor, g_max_body_size, g_max_header_size,
                &output_address, &output_len);
        }
        char* output = (char*)(uintptr_t)output_address;
        if (ctx->websocket == NULL) uv_read_stop((uv_stream_t*)&ctx->client);
        if (output == NULL) {
            send_response(&ctx->client, http_500, strlen(http_500), 0, MOJO_RESP_BORROWED);
        } else {
            send_response(&ctx->client, output, (size_t)output_len,
                          ctx->websocket != NULL, MOJO_RESP_OWNED);
        }
        return 0;
    }

    /* Serve static files directly through uv_fs_sendfile. */
    if (try_serve_static(ctx, method, url)) {
        return 0;
    }

    void* router = ctx->router ? ctx->router : global_router;
    if (router == NULL) {
        send_response(&ctx->client, http_500, strlen(http_500), 0, MOJO_RESP_BORROWED);
        return 0;
    }
    ctx->processing = 1;
    const char* headers = ctx->headers.data ? ctx->headers.data : "";
    const char* body = ctx->body.data ? ctx->body.data : "";

    /* 2.3: build FFI arrays for multipart data (on the stack). */
    int form_count = ctx->mp ? ctx->mp->form_count : 0;
    int file_count = ctx->mp ? ctx->mp->file_count : 0;

    c_form_field_t form_arr[100];
    for (int i = 0; i < form_count; i++) {
        form_arr[i].name = ctx->mp->form[i].name;
        form_arr[i].value = ctx->mp->form[i].value;
        form_arr[i].value_len = ctx->mp->form[i].value_len;
    }
    c_file_part_t file_arr[100];
    for (int i = 0; i < file_count; i++) {
        file_arr[i].name = ctx->mp->files[i].name;
        file_arr[i].filename = ctx->mp->files[i].filename;
        file_arr[i].content_type = ctx->mp->files[i].content_type;
        file_arr[i].path = ctx->mp->files[i].path;
        file_arr[i].size = ctx->mp->files[i].size;
    }

    struct timespec start, end;
    int log_on = g_log_level >= 1;
    if (log_on) clock_gettime(CLOCK_MONOTONIC, &start);

    size_t resp_len = 0;
    int resp_owned = MOJO_RESP_OWNED;
    char* response = mojo_handler(router, url, method, headers, body, &resp_len,
                                &resp_owned, ctx->url.len, ctx->headers.len, ctx->body.len,
                                form_arr, (size_t)form_count,
                                    file_arr, (size_t)file_count);

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
                                    status = extract_status_from_response(response, resp_len);
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
    if (ctx->reject_status == 415) resp = http_415;
    else if (ctx->reject_status == 431) resp = http_431;
    else if (ctx->reject_status == 413) resp = http_413;
    send_response(&ctx->client, resp, strlen(resp), 0, MOJO_RESP_BORROWED);
    uv_read_stop((uv_stream_t*)&ctx->client);
}

static void on_read_c(uv_stream_t* client, ssize_t nread, const uv_buf_t* buf) {
    if (nread > 0) {
        client_ctx_t* ctx = (client_ctx_t*)client->data;
        if (ctx == NULL) return;
        uint64_t now = uv_now(client->loop);
        ctx->last_active_ms = now;
        heap_update(ctx);
        if (ctx->websocket_active) {
            websocket_receive(ctx, buf->base, (size_t)nread);
            return;
        }
        if (ctx->request_started_ms == 0 && !ctx->processing)
            ctx->request_started_ms = now;

        if (ctx->processing) {
            if (ctx->pending.len + (size_t)nread > g_max_header_size + g_max_body_size) {
                ctx->reject_status = 413;
                send_parse_error(ctx);
                return;
            }
            /* pending всегда в heap, чтобы arena_reset не затёр данные */
            if (buf_append_arena(&ctx->pending, NULL, buf->base, (size_t)nread) != 0) {
                send_response((uv_tcp_t*)client, http_500, strlen(http_500), 0, MOJO_RESP_BORROWED);
                uv_read_stop(client);
                return;
            }
        } else {
            execute_http(ctx, buf->base, (size_t)nread);
        }
    } else if (nread < 0) {
        client_ctx_t* ctx = (client_ctx_t*)client->data;
        if (ctx != NULL && ctx->static_tx != NULL &&
            (ctx->static_tx->in_flight || ctx->static_tx->headers_writing)) {
            ctx->static_state = STATIC_STATE_ABORTING;
        static_close_retry_timer(ctx->static_tx);
        uv_read_stop(client);
        return;
            }
            if (!uv_is_closing((uv_handle_t*)client))
                uv_close((uv_handle_t*)client, on_close_c);
    }
}

/* ================= sweep ================= */

static void sweep_timeouts_c(uv_timer_t* timer) {
    uint64_t now = uv_now(timer->loop);
    if (g_idle_timeout_ms > 0) {
        uint64_t idle = (uint64_t)g_idle_timeout_ms;
        while (g_timeout_heap.len > 0) {
            client_ctx_t* c = g_timeout_heap.items[0];
            if (now - c->last_active_ms <= idle) break;
            heap_remove(c);
            if (c->static_tx != NULL &&
                (c->static_tx->in_flight || c->static_tx->headers_writing)) {
                c->static_state = STATIC_STATE_ABORTING;
            static_close_retry_timer(c->static_tx);
            uv_read_stop((uv_stream_t*)&c->client);
            continue;
                }
                if (!uv_is_closing((uv_handle_t*)&c->client))
                    uv_close((uv_handle_t*)&c->client, on_close_c);
        }
    }
    for (client_ctx_t* c = conn_list; c != NULL; c = c->next) {
        if (c->websocket_closing_ms != 0 && now - c->websocket_closing_ms >= 5000 &&
            !uv_is_closing((uv_handle_t*)&c->client))
            uv_close((uv_handle_t*)&c->client, on_close_c);
    }
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

static uint64_t g_shutdown_started_ms = 0;

static void on_signal(uv_signal_t* handle, int signum) {
    (void)handle; (void)signum;
    if (g_shutdown) return;
    g_shutdown = 1;
    g_shutdown_started_ms = uv_now(handle->loop);
    fprintf(stderr, "[C] Received signal %d, starting graceful shutdown...\n", signum);
}

static void check_shutdown_c(uv_timer_t* timer) {
    int* stopped = (int*)timer->data;
    if (!g_shutdown || *stopped) return;
    uint64_t now = uv_now(timer->loop);
    int drained = (conn_list == NULL);
    int timed_out = (g_shutdown_timeout_ms > 0) &&
    (now - g_shutdown_started_ms > (uint64_t)g_shutdown_timeout_ms);
    if (drained || timed_out) {
        *stopped = 1;
        fprintf(stderr, "[C] Shutdown (%s), stopping loop\n",
                timed_out && !drained ? "timeout" : "drained");
        uv_stop(timer->loop);
    }
}

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
    buf_init(&ctx->url); ctx->url.arena_backed = 1;
    buf_init(&ctx->headers); ctx->headers.arena_backed = 1;
    buf_init(&ctx->body); ctx->body.arena_backed = 1;
    buf_init(&ctx->pending); ctx->pending.arena_backed = 0;

    ctx->header_state = HEADER_STATE_NONE;
    ctx->processing = 0;
    ctx->last_active_ms = uv_now(server->loop);
    ctx->heap_index = -1;
    ctx->expect_files = 0;
    ctx->is_multipart = 0;
    ctx->mp = NULL;
    ctx->static_state = STATIC_STATE_IDLE;
    ctx->static_tx = NULL;

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
    int thread_id = args->thread_id;
    int port = args->port;
    free(args);

    current_thread_id = thread_id;

    int cpu_id = allowed_cpus[thread_id % num_allowed_cpus];
    cpu_set_t cpuset;
    CPU_ZERO(&cpuset);
    CPU_SET(cpu_id, &cpuset);
    pthread_setaffinity_np(pthread_self(), sizeof(cpu_set_t), &cpuset);

    ensure_settings_init();

    int server_fd = create_bound_socket(port);
    if (server_fd < 0) { return NULL; }

    uv_loop_t* loop = (uv_loop_t*)malloc(sizeof(uv_loop_t));
    if (!loop) { close(server_fd); return NULL; }
    if (uv_loop_init(loop) != 0) { free(loop); close(server_fd); return NULL; }

    uv_tcp_t* server = (uv_tcp_t*)malloc(sizeof(uv_tcp_t));
    if (!server) { uv_loop_close(loop); free(loop); close(server_fd); return NULL; }
    uv_tcp_init(loop, server);

    int rc = uv_tcp_open(server, server_fd);
    if (rc != 0) {
        close(server_fd);
        uv_close((uv_handle_t*)server, NULL);
        uv_run(loop, UV_RUN_NOWAIT);
        uv_loop_close(loop);
        free(server); free(loop);
        return NULL;
    }

    rc = uv_listen((uv_stream_t*)server, LISTEN_BACKLOG, on_connection_c);
    if (rc != 0) {
        uv_close((uv_handle_t*)server, NULL);
        uv_run(loop, UV_RUN_NOWAIT);
        uv_loop_close(loop);
        free(server); free(loop);
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

    uv_timer_t* shutdown_timer = (uv_timer_t*)malloc(sizeof(uv_timer_t));
    int shutdown_stopped = 0;
    if (shutdown_timer) {
        uv_timer_init(loop, shutdown_timer);
        shutdown_timer->data = &shutdown_stopped;
        uv_timer_start(shutdown_timer, check_shutdown_c, 100, 100);
    }

    printf("[C] Thread %d listening on CPU %d (port %d)\n", thread_id, cpu_id, port);
    fflush(stdout);

    uv_run(loop, UV_RUN_DEFAULT);

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
    return NULL;
}

/* ================= public API ================= */

void pthread_create_wrapper(int port, void* router, int num_threads) {
    ensure_settings_init();
    detect_allowed_cpus();
    num_threads = resolve_thread_count(num_threads);
    freeze_upload_routes();
    freeze_static_config();
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

/* ================= low-level wrappers ================= */

void uv_tcp_init_wrapper(uv_loop_t* loop, uv_tcp_t* tcp) { ensure_settings_init(); uv_tcp_init(loop, tcp); }

uv_tcp_t* uv_tcp_create_wrapper(uv_loop_t* loop) {
    uv_tcp_t* tcp = (uv_tcp_t*)calloc(1, sizeof(uv_tcp_t));
    if (tcp == NULL) abort();
    if (uv_tcp_init(loop, tcp) != 0) { free(tcp); abort(); }
    return tcp;
}

void uv_tcp_destroy_wrapper(uv_tcp_t* tcp) { free(tcp); }

void uv_tcp_bind_wrapper(uv_tcp_t* tcp, const char* ip, int port) {
    ensure_settings_init();
    struct sockaddr_in addr; uv_ip4_addr(ip, port, &addr);
    int rc = uv_tcp_bind(tcp, (const struct sockaddr*)&addr, 0);
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
typedef struct {
    uv_loop_t loop;
    uv_timer_t timeout_timer;
} single_loop_t;

uv_loop_t* uv_loop_create_wrapper(void) {
    ensure_settings_init();
    single_loop_t* state = (single_loop_t*)calloc(1, sizeof(single_loop_t));
    if (state == NULL) abort();
    uv_loop_init(&state->loop);
    uv_timer_init(&state->loop, &state->timeout_timer);
    uv_timer_start(&state->timeout_timer, sweep_timeouts_c, 1000, 1000);
    return &state->loop;
}
void uv_loop_destroy_wrapper(uv_loop_t* loop) {
    if (!loop) return;
    uv_walk(loop, close_all_cb, NULL);
    uv_run(loop, UV_RUN_DEFAULT);
    uv_loop_close(loop);
    free(loop);
}
void mojelly_free_response(char* ptr) { if (ptr) free(ptr); }
