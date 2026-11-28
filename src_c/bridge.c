#define _GNU_SOURCE
#include "multipart_parser.h"
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

#if defined(__linux__) && defined(__has_include)
#if __has_include(<linux/openat2.h>) && __has_include(<sys/syscall.h>)
#include <linux/openat2.h>
#include <sys/syscall.h>
#ifdef SYS_openat2
#define MOJELLY_HAVE_OPENAT2 1
#endif
#endif
#endif

#if defined(__GNUC__) || defined(__clang__)
#define LIKELY(x) __builtin_expect(!!(x), 1)
#define UNLIKELY(x) __builtin_expect(!!(x), 0)
#define NOINLINE __attribute__((noinline))
#else
#define LIKELY(x) (x)
#define UNLIKELY(x) (x)
#define NOINLINE
#endif

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

#define READ_BUFFER_SIZE 65536
#define LISTEN_BACKLOG 4096
#define HTTP_STATUS_DIGITS 3
#define HTTP_VERSION_PREFIX_LEN 9
#define BODY_PRERESERVE_MAX (64ULL << 10)

#define ARENA_DEFAULT_SIZE (32 * 1024)
#define ARENA_MAX_SIZE (4 * 1024 * 1024)
#define CTX_SLAB_MAX 1024
#define WRITE_REQ_POOL_MAX 4096
#define MAX_UPLOAD_ROUTES 64
#define SENDFILE_CHUNK_SIZE (512 * 1024)
#define SENDFILE_RETRY_MS 1
#define STATIC_SMALL_FILE_MAX (32 * 1024)
#define STATIC_HDR_MAX 512
#define RESP_SCRATCH_SIZE 65536

#define MOJELLY_METHOD_OTHER 0
#define MOJELLY_METHOD_GET 1
#define MOJELLY_METHOD_POST 2
#define MOJELLY_METHOD_PUT 3
#define MOJELLY_METHOD_DELETE 4
#define MOJELLY_METHOD_PATCH 5
#define MOJELLY_METHOD_HEAD 6

static size_t g_max_header_size = 64UL << 10;
static size_t g_max_body_size = 10UL << 20;
static size_t g_max_file_size = 100UL << 20;
static size_t g_max_field_size = 1UL << 20; /* 1 MB per text field */
static int g_max_parts = 100; /* max number of parts (files + fields) */
static long g_idle_timeout_ms = 60 * 1000;
static long g_request_timeout_ms = 30 * 1000;
static long g_shutdown_timeout_ms = 30 * 1000;

static volatile sig_atomic_t g_shutdown = 0;

/* RFC 7230 token characters (tchar) для валидации имён заголовков в fast-path
 */
static const uint8_t g_tchar[256] = {
    ['!'] = 1, ['#'] = 1, ['$'] = 1, ['%'] = 1, ['&'] = 1, ['\''] = 1,
    ['*'] = 1, ['+'] = 1, ['-'] = 1, ['.'] = 1, ['0'] = 1, ['1'] = 1,
    ['2'] = 1, ['3'] = 1, ['4'] = 1, ['5'] = 1, ['6'] = 1, ['7'] = 1,
    ['8'] = 1, ['9'] = 1, ['A'] = 1, ['B'] = 1, ['C'] = 1, ['D'] = 1,
    ['E'] = 1, ['F'] = 1, ['G'] = 1, ['H'] = 1, ['I'] = 1, ['J'] = 1,
    ['K'] = 1, ['L'] = 1, ['M'] = 1, ['N'] = 1, ['O'] = 1, ['P'] = 1,
    ['Q'] = 1, ['R'] = 1, ['S'] = 1, ['T'] = 1, ['U'] = 1, ['V'] = 1,
    ['W'] = 1, ['X'] = 1, ['Y'] = 1, ['Z'] = 1, ['^'] = 1, ['_'] = 1,
    ['`'] = 1, ['a'] = 1, ['b'] = 1, ['c'] = 1, ['d'] = 1, ['e'] = 1,
    ['f'] = 1, ['g'] = 1, ['h'] = 1, ['i'] = 1, ['j'] = 1, ['k'] = 1,
    ['l'] = 1, ['m'] = 1, ['n'] = 1, ['o'] = 1, ['p'] = 1, ['q'] = 1,
    ['r'] = 1, ['s'] = 1, ['t'] = 1, ['u'] = 1, ['v'] = 1, ['w'] = 1,
    ['x'] = 1, ['y'] = 1, ['z'] = 1, ['|'] = 1, ['~'] = 1};

/* ================= Static files config ================= */

typedef struct {
  char prefix[256];
  size_t prefix_len;
  char root_dir[PATH_MAX];
  size_t root_len;
  int root_fd;
  int enabled;
} static_config_t;

static static_config_t g_static = {{0}, 0, {0}, 0, -1, 0};
static int g_static_frozen = 0;
static pthread_mutex_t g_static_mutex = PTHREAD_MUTEX_INITIALIZER;

#ifdef MOJELLY_HAVE_OPENAT2
static _Atomic int g_openat2_unsupported = 0;
#endif

int mojelly_set_static_dir(const char *prefix, const char *dir) {
  if (prefix == NULL || dir == NULL || prefix[0] != '/')
    return -1;

  char resolved[PATH_MAX];
  if (realpath(dir, resolved) == NULL)
    return -1;

  struct stat st;
  if (stat(resolved, &st) != 0 || !S_ISDIR(st.st_mode))
    return -1;

  int rfd = open(resolved, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
  if (rfd < 0)
    return -1;

  pthread_mutex_lock(&g_static_mutex);
  if (g_static_frozen) {
    pthread_mutex_unlock(&g_static_mutex);
    close(rfd);
    return -1;
  }

  size_t plen = strlen(prefix);
  while (plen > 1 && prefix[plen - 1] == '/')
    plen--;
  if (plen >= sizeof(g_static.prefix)) {
    pthread_mutex_unlock(&g_static_mutex);
    close(rfd);
    return -1;
  }

  if (g_static.root_fd >= 0)
    close(g_static.root_fd);
  g_static.root_fd = rfd;

  memcpy(g_static.prefix, prefix, plen);
  g_static.prefix[plen] = '\0';
  g_static.prefix_len = plen;

  size_t rlen = strlen(resolved);
  memcpy(g_static.root_dir, resolved, rlen + 1);
  g_static.root_len = rlen;

  __atomic_store_n(&g_static.enabled, 1, __ATOMIC_RELEASE);
  fprintf(stderr, "[C] static dir mounted: %s -> %s\n", g_static.prefix,
          g_static.root_dir);
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

void mojelly_register_upload_route(const char *method, const char *path) {
  if (method == NULL || path == NULL)
    return;
  pthread_mutex_lock(&g_upload_routes_mutex);
  if (g_upload_routes_frozen) {
    pthread_mutex_unlock(&g_upload_routes_mutex);
    return;
  }
  int idx = __atomic_load_n(&g_upload_route_count, __ATOMIC_RELAXED);
  if (idx < MAX_UPLOAD_ROUTES) {
    upload_route_t *r = &g_upload_routes[idx];
    strncpy(r->method, method, sizeof(r->method) - 1);
    r->method[sizeof(r->method) - 1] = '\0';
    strncpy(r->path, path, sizeof(r->path) - 1);
    r->path[sizeof(r->path) - 1] = '\0';
    __atomic_store_n(&g_upload_route_count, idx + 1, __ATOMIC_RELEASE);
    fprintf(stderr, "[C] registered upload route: %s %s\n", method, path);
  }
  pthread_mutex_unlock(&g_upload_routes_mutex);
}

static int is_upload_route(const char *method, const char *path) {
  int count = __atomic_load_n(&g_upload_route_count, __ATOMIC_RELAXED);
  if (count == 0)
    return 0;
  if (method == NULL || path == NULL)
    return 0;
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
#define MOJO_RESP_SCRATCH 2

static _Thread_local char tl_resp_buf[RESP_SCRATCH_SIZE];

typedef struct {
  const char *name;
  const char *value;
  size_t value_len;
} c_form_field_t;

typedef struct {
  const char *name;
  const char *filename;
  const char *content_type;
  const char *path;
  size_t size;
} c_file_part_t;

extern char *mojo_handler(void *router, const char *url, const char *method,
                          const char *headers, const char *body,
                          size_t *out_len, int *out_ownership, size_t url_len,
                          size_t method_len, size_t headers_len,
                          size_t body_len, uint8_t method_id, int keep_alive,
                          char *scratch_buf, size_t scratch_cap,
                          c_form_field_t *form, size_t form_count,
                          c_file_part_t *files, size_t file_count);

static void *global_router = NULL;
void mojelly_set_router(void *router) { global_router = router; }

/* ================= Arena allocator ================= */

typedef struct {
  char *base;
  size_t cap;
  size_t used;
} arena_t;

static void arena_init(arena_t *a, size_t cap) {
  a->base = (char *)malloc(cap);
  a->cap = a->base ? cap : 0;
  a->used = 0;
}

static void arena_free(arena_t *a) {
  if (a->base)
    free(a->base);
  a->base = NULL;
  a->cap = 0;
  a->used = 0;
}

static inline void arena_reset(arena_t *a) { a->used = 0; }

static inline void *arena_alloc(arena_t *a, size_t n) {
  if (n == 0)
    n = 1;
  n = (n + 7) & ~(size_t)7;
  if (LIKELY(a->base != NULL && n <= a->cap && a->used <= a->cap - n)) {
    void *p = a->base + a->used;
    a->used += n;
    return p;
  }
  return NULL;
}

/* ================= Buffer ================= */

typedef struct {
  char *data;
  size_t len;
  size_t cap;
  int arena_backed;
} buffer_t;

static inline void buf_init(buffer_t *b) {
  b->data = NULL;
  b->len = 0;
  b->cap = 0;
  b->arena_backed = 0;
}

static inline void buf_free(buffer_t *b) {
  if (b->data != NULL && !b->arena_backed)
    free(b->data);
  b->data = NULL;
  b->len = 0;
  b->cap = 0;
  b->arena_backed = 0;
}

static inline void buf_reset(buffer_t *b) {
  b->len = 0;
  if (b->data != NULL)
    b->data[0] = '\0';
}

static inline void buf_reset_arena(buffer_t *b) {
  if (UNLIKELY(!b->arena_backed && b->data != NULL))
    free(b->data);
  b->data = NULL;
  b->len = 0;
  b->cap = 0;
  b->arena_backed = 1;
}

static int buf_reserve_arena_hint(buffer_t *b, arena_t *a, size_t need,
                                  size_t init_cap) {
  if (LIKELY(b->cap >= need))
    return 0;
  size_t new_cap = b->cap ? b->cap : init_cap;
  while (new_cap < need) {
    if (UNLIKELY(new_cap > SIZE_MAX / 2))
      return -1;
    new_cap *= 2;
  }
  if (b->arena_backed && a != NULL && new_cap <= ARENA_MAX_SIZE) {
    if (b->data != NULL && a->base != NULL &&
        b->data + b->cap == a->base + a->used) {
      size_t base_off = (size_t)(b->data - a->base);
      if (LIKELY(new_cap <= a->cap && base_off <= a->cap - new_cap)) {
        a->used = base_off + new_cap;
        b->cap = new_cap;
        return 0;
      }
    }
    char *p = (char *)arena_alloc(a, new_cap);
    if (LIKELY(p != NULL)) {
      if (b->data && b->len)
        memcpy(p, b->data, b->len);
      b->data = p;
      b->cap = new_cap;
      return 0;
    }
    char *nd = (char *)malloc(new_cap);
    if (UNLIKELY(!nd))
      return -1;
    if (b->data && b->len)
      memcpy(nd, b->data, b->len);
    b->data = nd;
    b->cap = new_cap;
    b->arena_backed = 0;
    return 0;
  }
  char *nd = (char *)realloc(b->data, new_cap);
  if (UNLIKELY(!nd))
    return -1;
  b->data = nd;
  b->cap = new_cap;
  b->arena_backed = 0;
  return 0;
}

static inline int buf_reserve_arena(buffer_t *b, arena_t *a, size_t need) {
  return buf_reserve_arena_hint(b, a, need, 256);
}

static inline int buf_append_arena_hint(buffer_t *b, arena_t *a,
                                        const char *data, size_t len,
                                        size_t init_cap) {
  if (UNLIKELY(len == 0))
    return 0;
  if (UNLIKELY(b->cap < b->len + len + 1)) {
    if (UNLIKELY(buf_reserve_arena_hint(b, a, b->len + len + 1, init_cap) != 0))
      return -1;
  }
  memcpy(b->data + b->len, data, len);
  b->len += len;
  b->data[b->len] = '\0';
  return 0;
}

static inline int buf_append_arena(buffer_t *b, arena_t *a, const char *data,
                                   size_t len) {
  return buf_append_arena_hint(b, a, data, len, 256);
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
  uv_timer_t *retry_timer;
  int file_fd;
  int sock_fd;
  int64_t offset;
  int64_t file_size;
  int keep_alive;
  int in_flight;
  int headers_writing;
  int ctx_closing;
  int corked;
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
  char *value;
  size_t value_len;
  int arena_backed;
} mp_form_field_t;

typedef struct {
  char name[256];
  char filename[256];
  char content_type[128];
  char path[256];
  size_t size;
} mp_file_part_t;

typedef struct {
  multipart_parser *parser;
  char *boundary;
  mp_header_t last_header;
  char field_name[256];
  char filename[256];
  char content_type[128];
  char temp_path[256];
  FILE *current_file;
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
  size_t hdr_field_start;
  size_t ct_value_start;
  size_t ct_value_len;
  int in_content_type;
  int llhttp_active;
  int keep_alive;
  int processing;
  void *router;
  int reject_status;
  uint64_t last_active_ms;
  uint64_t request_started_ms;

  int linked;
  struct client_ctx *prev;
  struct client_ctx *next;

  int idle_linked;
  struct client_ctx *idle_prev;
  struct client_ctx *idle_next;

  arena_t arena;

  int expect_files;
  int is_multipart;

  multipart_state_t *mp;

  static_state_t static_state;
  static_transfer_t *static_tx;
} client_ctx_t;

static _Thread_local client_ctx_t *tl_ctx_slab[CTX_SLAB_MAX];
static _Thread_local int tl_ctx_slab_len = 0;

static void on_retry_timer_close(uv_handle_t *h) { free(h); }

static void static_close_retry_timer(static_transfer_t *st) {
  if (st == NULL || st->retry_timer == NULL)
    return;
  uv_timer_t *t = st->retry_timer;
  st->retry_timer = NULL;
  uv_timer_stop(t);
  t->data = NULL;
  if (!uv_is_closing((uv_handle_t *)t)) {
    uv_close((uv_handle_t *)t, on_retry_timer_close);
  }
}

static void static_uncork(static_transfer_t *st) {
#ifdef TCP_CORK
  if (st != NULL && st->corked && st->sock_fd >= 0) {
    int off = 0;
    setsockopt(st->sock_fd, IPPROTO_TCP, TCP_CORK, &off, sizeof(off));
    st->corked = 0;
  }
#else
  (void)st;
#endif
}

static void static_transfer_free(static_transfer_t *st) {
  if (st == NULL)
    return;
  static_close_retry_timer(st);
  if (st->file_fd >= 0) {
    close(st->file_fd);
    st->file_fd = -1;
  }
  free(st);
}

static multipart_state_t *mp_state_alloc(void) {
  multipart_state_t *mp =
      (multipart_state_t *)calloc(1, sizeof(multipart_state_t));
  if (mp != NULL) {
    buf_init(&mp->field_value);
    mp->field_value.arena_backed = 1;
    mp->last_header = MP_HDR_NONE;
  }
  return mp;
}

static void mp_form_reset(multipart_state_t *mp) {
  for (int i = 0; i < mp->form_count; i++) {
    if (mp->form[i].value && !mp->form[i].arena_backed) {
      free(mp->form[i].value);
    }
    mp->form[i].value = NULL;
    mp->form[i].value_len = 0;
    mp->form[i].arena_backed = 0;
    mp->form[i].name[0] = '\0';
  }
  mp->form_count = 0;
}

static void mp_files_reset(multipart_state_t *mp) {
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

static void mp_state_free(multipart_state_t *mp) {
  if (mp == NULL)
    return;
  if (mp->parser) {
    multipart_parser_free(mp->parser);
    mp->parser = NULL;
  }
  if (mp->boundary) {
    free(mp->boundary);
    mp->boundary = NULL;
  }
  if (mp->current_file) {
    fclose(mp->current_file);
    mp->current_file = NULL;
  }
  if (mp->temp_path[0]) {
    unlink(mp->temp_path);
    mp->temp_path[0] = '\0';
  }
  mp_form_reset(mp);
  buf_free(&mp->field_value);
  mp_files_reset(mp);
  free(mp);
}

static client_ctx_t *ctx_alloc(void) {
  if (LIKELY(tl_ctx_slab_len > 0)) {
    client_ctx_t *c = tl_ctx_slab[--tl_ctx_slab_len];
    arena_t saved_arena = c->arena;
    memset(c, 0, sizeof(client_ctx_t));
    c->arena = saved_arena;
    c->arena.used = 0;
    return c;
  }
  return (client_ctx_t *)calloc(1, sizeof(client_ctx_t));
}

static void ctx_free(client_ctx_t *c) {
  if (!c)
    return;
  if (UNLIKELY(c->mp != NULL)) {
    mp_state_free(c->mp);
    c->mp = NULL;
  }
  if (UNLIKELY(c->static_tx != NULL)) {
    static_transfer_free(c->static_tx);
    c->static_tx = NULL;
    c->static_state = STATIC_STATE_IDLE;
  }
  buf_free(&c->url);
  buf_free(&c->headers);
  buf_free(&c->body);
  buf_free(&c->pending);

  if (LIKELY(tl_ctx_slab_len < CTX_SLAB_MAX)) {
    arena_reset(&c->arena);
    tl_ctx_slab[tl_ctx_slab_len++] = c;
    return;
  }
  arena_free(&c->arena);
  free(c);
}

static void ctx_slab_destroy_tl(void) {
  for (int i = 0; i < tl_ctx_slab_len; i++) {
    arena_free(&tl_ctx_slab[i]->arena);
    free(tl_ctx_slab[i]);
  }
  tl_ctx_slab_len = 0;
}

/* ================= write_req ================= */

typedef struct {
  uv_write_t req;
  uv_tcp_t *client;
  char *data;
  size_t len;
  int keep_alive;
  int free_data;
} write_req_t;

static _Thread_local write_req_t *wr_pool = NULL;
static _Thread_local int wr_pool_len = 0;

static inline write_req_t *wr_acquire(void) {
  write_req_t *wr = wr_pool;
  if (LIKELY(wr != NULL)) {
    wr_pool = *(write_req_t **)wr;
    wr_pool_len--;
    return wr;
  }
  return (write_req_t *)malloc(sizeof(write_req_t));
}

static inline void wr_release(write_req_t *wr) {
  if (UNLIKELY(wr_pool_len >= WRITE_REQ_POOL_MAX)) {
    free(wr);
    return;
  }
  *(write_req_t **)wr = wr_pool;
  wr_pool = wr;
  wr_pool_len++;
}

static void wr_pool_destroy_tl(void) {
  while (wr_pool != NULL) {
    write_req_t *next = *(write_req_t **)wr_pool;
    free(wr_pool);
    wr_pool = next;
  }
  wr_pool_len = 0;
}

/* ================= O(1) Idle LRU list ================= */

static _Thread_local client_ctx_t *tl_idle_head = NULL;
static _Thread_local client_ctx_t *tl_idle_tail = NULL;

static inline void idle_push(client_ctx_t *c) {
  if (UNLIKELY(c->idle_linked))
    return;
  c->idle_prev = tl_idle_tail;
  c->idle_next = NULL;
  if (tl_idle_tail)
    tl_idle_tail->idle_next = c;
  else
    tl_idle_head = c;
  tl_idle_tail = c;
  c->idle_linked = 1;
}

static inline void idle_remove(client_ctx_t *c) {
  if (!c->idle_linked)
    return;
  if (c->idle_prev)
    c->idle_prev->idle_next = c->idle_next;
  else
    tl_idle_head = c->idle_next;
  if (c->idle_next)
    c->idle_next->idle_prev = c->idle_prev;
  else
    tl_idle_tail = c->idle_prev;
  c->idle_prev = NULL;
  c->idle_next = NULL;
  c->idle_linked = 0;
}

static inline void idle_touch(client_ctx_t *c, uint64_t now) {
  if (LIKELY(c->last_active_ms == now && c->idle_linked))
    return;
  c->last_active_ms = now;
  if (UNLIKELY(!c->idle_linked)) {
    idle_push(c);
    return;
  }
  if (c == tl_idle_tail)
    return;
  if (c->idle_prev)
    c->idle_prev->idle_next = c->idle_next;
  else
    tl_idle_head = c->idle_next;
  c->idle_next->idle_prev = c->idle_prev;
  c->idle_prev = tl_idle_tail;
  c->idle_next = NULL;
  tl_idle_tail->idle_next = c;
  tl_idle_tail = c;
}

/* ================= llhttp ================= */

static llhttp_settings_t g_settings;
static pthread_once_t g_settings_once = PTHREAD_ONCE_INIT;

static int on_message_begin_c(llhttp_t *parser);
static int on_url_c(llhttp_t *parser, const char *at, size_t length);
static int on_header_field_c(llhttp_t *parser, const char *at, size_t length);
static int on_header_value_c(llhttp_t *parser, const char *at, size_t length);
static int on_headers_complete_c(llhttp_t *parser);
static int on_body_c(llhttp_t *parser, const char *at, size_t length);
static int on_message_complete_c(llhttp_t *parser);

static void mojelly_init_settings(void) {
  signal(SIGPIPE, SIG_IGN);

  const char *lvl = getenv("MOJELLY_LOG_LEVEL");
  if (lvl != NULL)
    g_log_level = atoi(lvl);
  const char *v;
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

static const char http_500[] =
    "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\nConnection: "
    "close\r\n\r\n";
static const char http_413[] =
    "HTTP/1.1 413 Payload Too Large\r\nContent-Length: 0\r\nConnection: "
    "close\r\n\r\n";
static const char http_431[] =
    "HTTP/1.1 431 Request Header Fields Too Large\r\nContent-Length: "
    "0\r\nConnection: close\r\n\r\n";
static const char http_415[] =
    "HTTP/1.1 415 Unsupported Media Type\r\nContent-Length: 0\r\nConnection: "
    "close\r\n\r\n";
static const char http_400[] = "HTTP/1.1 400 Bad Request\r\nContent-Length: "
                               "0\r\nConnection: close\r\n\r\n";
static const char http_403[] =
    "HTTP/1.1 403 Forbidden\r\nContent-Length: 9\r\nContent-Type: "
    "text/plain\r\nConnection: close\r\n\r\nForbidden";
static const char http_404[] =
    "HTTP/1.1 404 Not Found\r\nContent-Length: 9\r\nContent-Type: "
    "text/plain\r\nConnection: keep-alive\r\n\r\nNot Found";

/* ================= Logging helpers ================= */

static const char *get_method_color(const char *method) {
  if (strcmp(method, "GET") == 0)
    return COLOR_CYAN;
  if (strcmp(method, "POST") == 0)
    return COLOR_GREEN;
  if (strcmp(method, "PUT") == 0)
    return COLOR_YELLOW;
  if (strcmp(method, "DELETE") == 0)
    return COLOR_RED;
  if (strcmp(method, "PATCH") == 0)
    return COLOR_MAGENTA;
  return COLOR_BLUE;
}

static const char *get_status_color(int status) {
  if (status >= 200 && status < 300)
    return COLOR_GREEN;
  if (status >= 300 && status < 400)
    return COLOR_CYAN;
  if (status >= 400 && status < 500)
    return COLOR_YELLOW;
  if (status >= 500)
    return COLOR_RED;
  return COLOR_RESET;
}

static NOINLINE void log_request(const char *method, const char *url,
                                 size_t url_len, int status,
                                 double duration_ms) {
  const char *mc = get_method_color(method);
  const char *sc = get_status_color(status);
  static _Thread_local time_t cached_at = 0;
  static _Thread_local char time_str[20] = "00:00:00";
  time_t now = time(NULL);
  if (now != cached_at) {
    struct tm tm_info;
    localtime_r(&now, &tm_info);
    strftime(time_str, sizeof(time_str), "%H:%M:%S", &tm_info);
    cached_at = now;
  }
  printf("[%s] [T%d] %s%s%s %s%.*s%s %s%d%s %.2fms\n", time_str,
         current_thread_id, mc, method, COLOR_RESET, COLOR_BOLD, (int)url_len,
         url, COLOR_RESET, sc, status, COLOR_RESET, duration_ms);
}

/* ================= Conn list ================= */

static _Thread_local client_ctx_t *conn_list = NULL;

static inline void conn_link(client_ctx_t *ctx) {
  ctx->prev = NULL;
  ctx->next = conn_list;
  if (conn_list)
    conn_list->prev = ctx;
  conn_list = ctx;
  ctx->linked = 1;
}

static inline void conn_unlink(client_ctx_t *ctx) {
  if (!ctx->linked)
    return;
  if (ctx->prev)
    ctx->prev->next = ctx->next;
  else
    conn_list = ctx->next;
  if (ctx->next)
    ctx->next->prev = ctx->prev;
  ctx->linked = 0;
}

/* ================= forward ================= */

static void on_close_c(uv_handle_t *handle);
static void on_read_c(uv_stream_t *client, ssize_t nread, const uv_buf_t *buf);
static void send_response(uv_tcp_t *client, const char *response, size_t len,
                          int keep_alive, int owned);
static void send_parse_error(client_ctx_t *ctx);
static void execute_http_data(client_ctx_t *ctx, const char *data, size_t len);

/* ================= Keep-alive reset ================= */

static inline void reset_request_state_inline(client_ctx_t *ctx) {
  idle_touch(ctx, uv_now(ctx->client.loop));
  ctx->request_started_ms = 0;
  if (UNLIKELY(ctx->arena.used != 0 || ctx->url.data != NULL ||
               ctx->headers.data != NULL || ctx->body.data != NULL)) {
    buf_reset_arena(&ctx->url);
    buf_reset_arena(&ctx->headers);
    buf_reset_arena(&ctx->body);
    arena_reset(&ctx->arena);
  }
  ctx->header_state = HEADER_STATE_NONE;
  ctx->hdr_field_start = 0;
  ctx->ct_value_start = 0;
  ctx->ct_value_len = 0;
  ctx->in_content_type = 0;
  ctx->llhttp_active = 0;
  ctx->reject_status = 0;
  ctx->processing = 0;
  ctx->expect_files = 0;
  ctx->is_multipart = 0;

  if (UNLIKELY(ctx->mp != NULL)) {
    mp_state_free(ctx->mp);
    ctx->mp = NULL;
  }
}

static void reset_for_next_request(client_ctx_t *ctx) {
  reset_request_state_inline(ctx);

  if (llhttp_get_errno(&ctx->parser) == HPE_PAUSED) {
    llhttp_resume(&ctx->parser);
  } else {
    llhttp_init(&ctx->parser, HTTP_REQUEST, &g_settings);
    ctx->parser.data = ctx;
  }

  if (UNLIKELY(ctx->pending.len > 0)) {
    char *pdata = ctx->pending.data;
    size_t plen = ctx->pending.len;
    ctx->pending.data = NULL;
    ctx->pending.len = 0;
    ctx->pending.cap = 0;
    ctx->pending.arena_backed = 0;

    execute_http_data(ctx, pdata, plen);
    free(pdata);
  }
}

/* ================= close ================= */

static void on_close_c(uv_handle_t *handle) {
  client_ctx_t *ctx = (client_ctx_t *)handle->data;
  if (ctx == NULL)
    return;
  conn_unlink(ctx);
  idle_remove(ctx);

  if (UNLIKELY(ctx->static_tx != NULL)) {
    static_transfer_t *st = ctx->static_tx;
    static_close_retry_timer(st);
    ctx->static_state = STATIC_STATE_ABORTING;
    st->ctx_closing = 1;
    if (st->in_flight || st->headers_writing) {
      return;
    }
    static_transfer_free(st);
    ctx->static_tx = NULL;
    ctx->static_state = STATIC_STATE_IDLE;
  }

  ctx_free(ctx);
}

/* ================= Static files (small fast-path + uv_fs_sendfile)
 * ================= */

static inline int hex_val(char c) {
  if (c >= '0' && c <= '9')
    return c - '0';
  if (c >= 'a' && c <= 'f')
    return c - 'a' + 10;
  if (c >= 'A' && c <= 'F')
    return c - 'A' + 10;
  return -1;
}

static int url_decode_path(const char *src, size_t src_len, char *dst,
                           size_t dst_sz) {
  size_t out = 0;
  for (size_t i = 0; i < src_len; i++) {
    char c = src[i];
    if (UNLIKELY(c == '%')) {
      if (i + 2 >= src_len)
        return -1;
      int hi = hex_val(src[i + 1]);
      int lo = hex_val(src[i + 2]);
      if (hi < 0 || lo < 0)
        return -1;
      unsigned char decoded = (unsigned char)((hi << 4) | lo);
      if (decoded == 0)
        return -1;
      c = (char)decoded;
      i += 2;
    }
    if (UNLIKELY(out + 1 >= dst_sz))
      return -1;
    dst[out++] = c;
  }
  dst[out] = '\0';
  return 0;
}

static const char *get_mime_type(const char *path) {
  const char *dot = strrchr(path, '.');
  if (dot == NULL || dot[1] == '\0')
    return "application/octet-stream";
  dot++;
  size_t len = strlen(dot);
  unsigned char c0 = (unsigned char)dot[0] | 0x20;
  switch (len) {
  case 2:
    if (c0 == 'j' && ((unsigned char)dot[1] | 0x20) == 's')
      return "application/javascript; charset=utf-8";
    break;
  case 3:
    switch (c0) {
    case 'c':
      if (strcasecmp(dot, "css") == 0)
        return "text/css; charset=utf-8";
      break;
    case 'g':
      if (strcasecmp(dot, "gif") == 0)
        return "image/gif";
      break;
    case 'h':
      if (strcasecmp(dot, "htm") == 0)
        return "text/html; charset=utf-8";
      break;
    case 'i':
      if (strcasecmp(dot, "ico") == 0)
        return "image/x-icon";
      break;
    case 'j':
      if (strcasecmp(dot, "jpg") == 0)
        return "image/jpeg";
      break;
    case 'm':
      if (strcasecmp(dot, "mjs") == 0)
        return "application/javascript; charset=utf-8";
      if (strcasecmp(dot, "mp4") == 0)
        return "video/mp4";
      if (strcasecmp(dot, "mp3") == 0)
        return "audio/mpeg";
      break;
    case 'p':
      if (strcasecmp(dot, "png") == 0)
        return "image/png";
      if (strcasecmp(dot, "pdf") == 0)
        return "application/pdf";
      break;
    case 's':
      if (strcasecmp(dot, "svg") == 0)
        return "image/svg+xml";
      break;
    case 't':
      if (strcasecmp(dot, "txt") == 0)
        return "text/plain; charset=utf-8";
      if (strcasecmp(dot, "ttf") == 0)
        return "font/ttf";
      break;
    case 'x':
      if (strcasecmp(dot, "xml") == 0)
        return "application/xml; charset=utf-8";
      break;
    }
    break;
  case 4:
    switch (c0) {
    case 'h':
      if (strcasecmp(dot, "html") == 0)
        return "text/html; charset=utf-8";
      break;
    case 'j':
      if (strcasecmp(dot, "json") == 0)
        return "application/json; charset=utf-8";
      if (strcasecmp(dot, "jpeg") == 0)
        return "image/jpeg";
      break;
    case 'w':
      if (strcasecmp(dot, "webp") == 0)
        return "image/webp";
      if (strcasecmp(dot, "woff") == 0)
        return "font/woff";
      if (strcasecmp(dot, "wasm") == 0)
        return "application/wasm";
      if (strcasecmp(dot, "webm") == 0)
        return "video/webm";
      break;
    }
    break;
  case 5:
    if (c0 == 'w' && strcasecmp(dot, "woff2") == 0)
      return "font/woff2";
    break;
  default:
    break;
  }
  return "application/octet-stream";
}

static int open_static_file(const char *url, size_t url_len, int *out_fd,
                            struct stat *out_st, char *out_mime_path,
                            size_t out_mime_sz) {
  *out_fd = -1;
  if (url == NULL || url_len == 0)
    return 1;

  const char *rel = NULL;
  size_t rem_len = 0;
  if (g_static.prefix_len == 1 && g_static.prefix[0] == '/') {
    if (url[0] != '/')
      return 1;
    rel = url + 1;
    rem_len = url_len - 1;
  } else {
    if (url_len <= g_static.prefix_len)
      return 1;
    if (memcmp(url, g_static.prefix, g_static.prefix_len) != 0)
      return 1;
    if (url[g_static.prefix_len] != '/')
      return 1;
    rel = url + g_static.prefix_len + 1;
    rem_len = url_len - g_static.prefix_len - 1;
  }

  size_t rel_len = 0;
  while (rel_len < rem_len && rel[rel_len] != '?' && rel[rel_len] != '#') {
    rel_len++;
  }
  if (rel_len == 0)
    return -1;

  char decoded[PATH_MAX];
  if (url_decode_path(rel, rel_len, decoded, sizeof(decoded)) != 0)
    return -2;

#ifdef MOJELLY_HAVE_OPENAT2
  if (LIKELY(g_static.root_fd >= 0 &&
             !__atomic_load_n(&g_openat2_unsupported, __ATOMIC_RELAXED))) {
    const char *sub = decoded;
    while (*sub == '/')
      sub++;
    if (*sub == '\0')
      return -1;

    struct open_how how;
    memset(&how, 0, sizeof(how));
    how.flags = O_RDONLY | O_CLOEXEC;
    how.resolve = RESOLVE_BENEATH;

    long fd = syscall(SYS_openat2, g_static.root_fd, sub, &how, sizeof(how));
    if (fd >= 0) {
      if (fstat((int)fd, out_st) != 0 || !S_ISREG(out_st->st_mode)) {
        close((int)fd);
        return -1;
      }
      size_t slen = strlen(sub);
      if (slen >= out_mime_sz) {
        close((int)fd);
        return -2;
      }
      memcpy(out_mime_path, sub, slen + 1);
      *out_fd = (int)fd;
      return 0;
    }
    int err = errno;
    if (err == ENOSYS) {
      __atomic_store_n(&g_openat2_unsupported, 1, __ATOMIC_RELAXED);
    } else if (err == EXDEV) {
      return -2;
    } else {
      return -1;
    }
  }
#endif

  char candidate[PATH_MAX];
  int n = snprintf(candidate, sizeof(candidate), "%s/%s", g_static.root_dir,
                   decoded);
  if (n < 0 || (size_t)n >= sizeof(candidate))
    return -2;

  char resolved[PATH_MAX];
  if (realpath(candidate, resolved) == NULL)
    return -1;

  if (strncmp(resolved, g_static.root_dir, g_static.root_len) != 0)
    return -2;
  if (!(g_static.root_len == 1 && g_static.root_dir[0] == '/')) {
    char boundary = resolved[g_static.root_len];
    if (boundary != '/' && boundary != '\0')
      return -2;
  }

  int fd = open(resolved, O_RDONLY | O_CLOEXEC);
  if (fd < 0)
    return -1;
  if (fstat(fd, out_st) != 0 || !S_ISREG(out_st->st_mode)) {
    close(fd);
    return -1;
  }

  size_t res_len = strlen(resolved);
  if (res_len >= out_mime_sz) {
    close(fd);
    return -2;
  }
  memcpy(out_mime_path, resolved, res_len + 1);
  *out_fd = fd;
  return 0;
}

static void static_finish_aborted(client_ctx_t *ctx) {
  static_transfer_t *st = ctx->static_tx;
  if (st == NULL)
    return;
  if (st->in_flight || st->headers_writing)
    return;

  int should_free_ctx = st->ctx_closing;
  static_transfer_free(st);
  ctx->static_tx = NULL;
  ctx->static_state = STATIC_STATE_IDLE;

  if (should_free_ctx) {
    ctx_free(ctx);
  } else if (!uv_is_closing((uv_handle_t *)&ctx->client)) {
    uv_close((uv_handle_t *)&ctx->client, on_close_c);
  }
}

static void static_cleanup_and_finish(client_ctx_t *ctx, int ok) {
  static_transfer_t *st = ctx->static_tx;
  if (st == NULL)
    return;

  int keep_alive = ok && st->keep_alive;
  if (UNLIKELY(g_log_level >= 1)) {
    struct timespec end_ts;
    clock_gettime(CLOCK_MONOTONIC, &end_ts);
    double duration_ms = (end_ts.tv_sec - st->start_ts.tv_sec) * 1000.0 +
                         (end_ts.tv_nsec - st->start_ts.tv_nsec) / 1000000.0;
    log_request("GET", ctx->url.data ? ctx->url.data : "", ctx->url.len,
                ok ? 200 : 500, duration_ms);
  }

  if (!uv_is_closing((uv_handle_t *)&ctx->client)) {
    static_uncork(st);
  }

  static_transfer_free(st);
  ctx->static_tx = NULL;
  ctx->static_state = STATIC_STATE_IDLE;

  if (uv_is_closing((uv_handle_t *)&ctx->client))
    return;

  if (!keep_alive) {
    uv_close((uv_handle_t *)&ctx->client, on_close_c);
    return;
  }

  reset_for_next_request(ctx);
}

static void on_sendfile_cb(uv_fs_t *req);

static void sendfile_next_chunk(client_ctx_t *ctx) {
  static_transfer_t *st = ctx->static_tx;
  if (st == NULL)
    return;

  if (st->offset >= st->file_size) {
    static_cleanup_and_finish(ctx, 1);
    return;
  }

  size_t remain = (size_t)(st->file_size - st->offset);
  size_t chunk = remain > SENDFILE_CHUNK_SIZE ? SENDFILE_CHUNK_SIZE : remain;

  st->fs_req.data = ctx;
  st->in_flight = 1;
  int rc = uv_fs_sendfile(ctx->client.loop, &st->fs_req, st->sock_fd,
                          st->file_fd, st->offset, chunk, on_sendfile_cb);
  if (rc < 0) {
    st->in_flight = 0;
    static_cleanup_and_finish(ctx, 0);
  }
}

static void on_sendfile_retry_timer(uv_timer_t *t) {
  client_ctx_t *ctx = (client_ctx_t *)t->data;
  if (ctx == NULL)
    return;
  static_transfer_t *st = ctx->static_tx;
  if (st == NULL || ctx->static_state != STATIC_STATE_RETRY_WAIT ||
      uv_is_closing((uv_handle_t *)&ctx->client)) {
    return;
  }
  ctx->static_state = STATIC_STATE_SENDING_FILE;
  sendfile_next_chunk(ctx);
}

static void on_sendfile_cb(uv_fs_t *req) {
  client_ctx_t *ctx = (client_ctx_t *)req->data;
  ssize_t res = req->result;
  uv_fs_req_cleanup(req);

  if (ctx == NULL || ctx->static_tx == NULL)
    return;
  static_transfer_t *st = ctx->static_tx;
  st->in_flight = 0;

  if (ctx->static_state == STATIC_STATE_ABORTING ||
      uv_is_closing((uv_handle_t *)&ctx->client)) {
    static_finish_aborted(ctx);
    return;
  }

  if (res > 0) {
    st->offset += res;
    idle_touch(ctx, uv_now(ctx->client.loop));
    sendfile_next_chunk(ctx);
  } else if (res == -UV_EAGAIN) {
    if (st->retry_timer == NULL) {
      st->retry_timer = (uv_timer_t *)malloc(sizeof(uv_timer_t));
      if (st->retry_timer == NULL) {
        static_cleanup_and_finish(ctx, 0);
        return;
      }
      uv_timer_init(ctx->client.loop, st->retry_timer);
    }
    st->retry_timer->data = ctx;
    ctx->static_state = STATIC_STATE_RETRY_WAIT;
    if (uv_timer_start(st->retry_timer, on_sendfile_retry_timer,
                       SENDFILE_RETRY_MS, 0) != 0) {
      static_cleanup_and_finish(ctx, 0);
    }
  } else {
    static_cleanup_and_finish(ctx, 0);
  }
}

static void on_static_headers_written(uv_write_t *req, int status) {
  write_req_t *wr = (write_req_t *)req;
  if (wr->free_data && wr->data != NULL)
    free(wr->data);
  wr->data = NULL;
  uv_tcp_t *client = wr->client;
  wr_release(wr);

  if (client == NULL)
    return;
  client_ctx_t *ctx = (client_ctx_t *)client->data;
  if (ctx == NULL || ctx->static_tx == NULL)
    return;

  static_transfer_t *st = ctx->static_tx;
  st->headers_writing = 0;

  if (ctx->static_state == STATIC_STATE_ABORTING ||
      uv_is_closing((uv_handle_t *)client)) {
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

static NOINLINE int try_serve_static(client_ctx_t *ctx, int is_head,
                                     const char *method, const char *url,
                                     size_t url_len) {
  int fd = -1;
  struct stat st_buf;
  char mime_path[PATH_MAX];
  int rc = open_static_file(url, url_len, &fd, &st_buf, mime_path,
                            sizeof(mime_path));
  if (rc == 1)
    return 0;

  if (rc == -2) {
    if (UNLIKELY(g_log_level >= 1))
      log_request(method, url, url_len, 403, 0.0);
    send_response(&ctx->client, http_403, sizeof(http_403) - 1, 0,
                  MOJO_RESP_BORROWED);
    return 1;
  }

  if (fd < 0) {
    if (g_static.prefix_len == 1 && g_static.prefix[0] == '/')
      return 0;
    if (UNLIKELY(g_log_level >= 1))
      log_request(method, url, url_len, 404, 0.0);
    send_response(&ctx->client, http_404, sizeof(http_404) - 1, ctx->keep_alive,
                  MOJO_RESP_BORROWED);
    return 1;
  }

  const char *mime = get_mime_type(mime_path);
  int64_t file_size = (int64_t)st_buf.st_size;
  int keep_alive = ctx->keep_alive;

  if (is_head || file_size <= STATIC_SMALL_FILE_MAX) {
    static _Thread_local char small_buf[STATIC_HDR_MAX + STATIC_SMALL_FILE_MAX];
    int hdr_len = snprintf(small_buf, STATIC_HDR_MAX,
                           "HTTP/1.1 200 OK\r\n"
                           "Content-Type: %s\r\n"
                           "Content-Length: %lld\r\n"
                           "Connection: %s\r\n"
                           "\r\n",
                           mime, (long long)file_size,
                           keep_alive ? "keep-alive" : "close");
    if (hdr_len <= 0 || hdr_len >= STATIC_HDR_MAX) {
      close(fd);
      if (UNLIKELY(g_log_level >= 1))
        log_request(method, url, url_len, 500, 0.0);
      send_response(&ctx->client, http_500, sizeof(http_500) - 1, 0,
                    MOJO_RESP_BORROWED);
      return 1;
    }

    size_t total_len = (size_t)hdr_len;
    if (!is_head && file_size > 0) {
      size_t want = (size_t)file_size;
      size_t got = 0;
      while (got < want) {
        ssize_t r = read(fd, small_buf + hdr_len + got, want - got);
        if (r > 0) {
          got += (size_t)r;
        } else if (r < 0 && errno == EINTR) {
          continue;
        } else {
          break;
        }
      }
      if (got != want) {
        close(fd);
        if (UNLIKELY(g_log_level >= 1))
          log_request(method, url, url_len, 500, 0.0);
        send_response(&ctx->client, http_500, sizeof(http_500) - 1, 0,
                      MOJO_RESP_BORROWED);
        return 1;
      }
      total_len += want;
    }
    close(fd);

    if (UNLIKELY(g_log_level >= 1))
      log_request(method, url, url_len, 200, 0.0);
    send_response(&ctx->client, small_buf, total_len, keep_alive,
                  MOJO_RESP_SCRATCH);
    return 1;
  }

  int sock_fd = -1;
  if (uv_fileno((uv_handle_t *)&ctx->client, &sock_fd) != 0 || sock_fd < 0) {
    close(fd);
    if (UNLIKELY(g_log_level >= 1))
      log_request(method, url, url_len, 500, 0.0);
    send_response(&ctx->client, http_500, sizeof(http_500) - 1, 0,
                  MOJO_RESP_BORROWED);
    return 1;
  }

  char hdr_stack[STATIC_HDR_MAX];
  int hdr_len =
      snprintf(hdr_stack, sizeof(hdr_stack),
               "HTTP/1.1 200 OK\r\n"
               "Content-Type: %s\r\n"
               "Content-Length: %lld\r\n"
               "Connection: %s\r\n"
               "\r\n",
               mime, (long long)file_size, keep_alive ? "keep-alive" : "close");
  if (hdr_len <= 0 || hdr_len >= STATIC_HDR_MAX) {
    close(fd);
    if (UNLIKELY(g_log_level >= 1))
      log_request(method, url, url_len, 500, 0.0);
    send_response(&ctx->client, http_500, sizeof(http_500) - 1, 0,
                  MOJO_RESP_BORROWED);
    return 1;
  }

  static_transfer_t *st =
      (static_transfer_t *)calloc(1, sizeof(static_transfer_t));
  if (st == NULL) {
    close(fd);
    if (UNLIKELY(g_log_level >= 1))
      log_request(method, url, url_len, 500, 0.0);
    send_response(&ctx->client, http_500, sizeof(http_500) - 1, 0,
                  MOJO_RESP_BORROWED);
    return 1;
  }

  st->file_fd = fd;
  st->sock_fd = sock_fd;
  st->offset = 0;
  st->file_size = file_size;
  st->keep_alive = keep_alive;
  if (UNLIKELY(g_log_level >= 1)) {
    clock_gettime(CLOCK_MONOTONIC, &st->start_ts);
    if (ctx->url.data == NULL && url_len > 0) {
      (void)buf_append_arena(&ctx->url, &ctx->arena, url, url_len);
    }
  }

#ifdef TCP_CORK
  {
    int on = 1;
    if (setsockopt(sock_fd, IPPROTO_TCP, TCP_CORK, &on, sizeof(on)) == 0) {
      st->corked = 1;
    }
  }
#endif

  ctx->processing = 1;
  ctx->static_tx = st;

  uv_buf_t hbuf = uv_buf_init(hdr_stack, (unsigned int)hdr_len);
  int written = uv_try_write((uv_stream_t *)&ctx->client, &hbuf, 1);
  if (LIKELY(written == hdr_len)) {
    ctx->static_state = STATIC_STATE_SENDING_FILE;
    sendfile_next_chunk(ctx);
    return 1;
  }
  if (written < 0 && written != UV_EAGAIN && written != UV_ENOSYS) {
    static_cleanup_and_finish(ctx, 0);
    return 1;
  }

  size_t off = (written > 0) ? (size_t)written : 0;
  size_t rem = (size_t)hdr_len - off;
  char *hdr_buf = (char *)malloc(rem);
  write_req_t *wr = wr_acquire();
  if (hdr_buf == NULL || wr == NULL) {
    free(hdr_buf);
    if (wr)
      wr_release(wr);
    static_cleanup_and_finish(ctx, 0);
    return 1;
  }
  memcpy(hdr_buf, hdr_stack + off, rem);

  st->headers_writing = 1;
  ctx->static_state = STATIC_STATE_SENDING_HEADERS;

  wr->client = &ctx->client;
  wr->data = hdr_buf;
  wr->len = rem;
  wr->keep_alive = keep_alive;
  wr->free_data = 1;

  uv_buf_t buf = uv_buf_init(wr->data, (unsigned int)wr->len);
  int wrc = uv_write(&wr->req, (uv_stream_t *)&ctx->client, &buf, 1,
                     on_static_headers_written);
  if (wrc != 0) {
    free(wr->data);
    wr_release(wr);
    st->headers_writing = 0;
    static_cleanup_and_finish(ctx, 0);
  }
  return 1;
}

/* ================= write ================= */

static void finish_write(write_req_t *wr, int status) {
  if (wr->free_data && wr->data != NULL)
    free(wr->data);
  wr->data = NULL;
  uv_tcp_t *client = wr->client;
  int keep_alive = wr->keep_alive;
  wr_release(wr);

  if (client == NULL || uv_is_closing((uv_handle_t *)client))
    return;

  client_ctx_t *ctx = (client_ctx_t *)client->data;
  if (status != 0 || !keep_alive) {
    uv_close((uv_handle_t *)client, on_close_c);
    return;
  }
  if (ctx != NULL) {
    reset_for_next_request(ctx);
  }
}

static void on_write_c(uv_write_t *req, int status) {
  finish_write((write_req_t *)req, status);
}

static void send_response(uv_tcp_t *client, const char *response, size_t len,
                          int keep_alive, int owned) {
  if (UNLIKELY(client == NULL || uv_is_closing((uv_handle_t *)client))) {
    if (owned == MOJO_RESP_OWNED && response != NULL)
      free((void *)response);
    return;
  }
  if (UNLIKELY(response == NULL)) {
    response = http_500;
    len = sizeof(http_500) - 1;
    owned = MOJO_RESP_BORROWED;
    keep_alive = 0;
  }

  client_ctx_t *ctx = (client_ctx_t *)client->data;

  uv_buf_t buf = uv_buf_init((char *)response, (unsigned int)len);
  int written = uv_try_write((uv_stream_t *)client, &buf, 1);

  if (LIKELY(written >= 0 && (size_t)written == len)) {
    if (owned == MOJO_RESP_OWNED)
      free((void *)response);
    if (!keep_alive) {
      uv_close((uv_handle_t *)client, on_close_c);
    } else if (ctx != NULL) {
      reset_request_state_inline(ctx);
    }
    return;
  }

  if (UNLIKELY(written < 0 && written != UV_EAGAIN && written != UV_ENOSYS)) {
    if (owned == MOJO_RESP_OWNED)
      free((void *)response);
    uv_close((uv_handle_t *)client, on_close_c);
    return;
  }

  size_t off = (written > 0) ? (size_t)written : 0;
  size_t rem = len - off;
  write_req_t *wr = wr_acquire();
  if (UNLIKELY(!wr)) {
    if (owned == MOJO_RESP_OWNED)
      free((void *)response);
    if (!uv_is_closing((uv_handle_t *)client))
      uv_close((uv_handle_t *)client, on_close_c);
    return;
  }

  char *write_ptr = (char *)response + off;
  if (owned == MOJO_RESP_SCRATCH) {
    char *heap_rem = (char *)malloc(rem);
    if (UNLIKELY(!heap_rem)) {
      wr_release(wr);
      if (!uv_is_closing((uv_handle_t *)client))
        uv_close((uv_handle_t *)client, on_close_c);
      return;
    }
    memcpy(heap_rem, write_ptr, rem);
    wr->data = heap_rem;
    wr->free_data = 1;
    write_ptr = heap_rem;
  } else {
    wr->data = (char *)response;
    wr->free_data = (owned == MOJO_RESP_OWNED) ? 1 : 0;
  }

  if (ctx != NULL)
    ctx->processing = 1;
  wr->client = client;
  wr->keep_alive = keep_alive;
  wr->len = rem;

  uv_buf_t rem_buf = uv_buf_init(write_ptr, (unsigned int)rem);
  int rc = uv_write(&wr->req, (uv_stream_t *)client, &rem_buf, 1, on_write_c);
  if (UNLIKELY(rc != 0)) {
    if (wr->free_data && wr->data != NULL)
      free(wr->data);
    wr_release(wr);
    if (!uv_is_closing((uv_handle_t *)client))
      uv_close((uv_handle_t *)client, on_close_c);
  }
}

static int extract_status_from_response(const char *response, size_t resp_len) {
  if (response == NULL || resp_len < 12)
    return 500;
  if (response[0] != 'H' || response[1] != 'T' || response[2] != 'T' ||
      response[3] != 'P' || response[4] != '/')
    return 200;
  const char *p = response;
  while (*p && *p != ' ')
    p++;
  if (!*p)
    return 200;
  p++;
  int status = 0;
  for (int i = 0; i < HTTP_STATUS_DIGITS; i++) {
    if (p[i] < '0' || p[i] > '9')
      return 200;
    status = status * 10 + (p[i] - '0');
  }
  return status > 0 ? status : 200;
}

/* ================= multipart helpers ================= */

static void safe_copy(char *dst, size_t dstsz, const char *at, size_t length) {
  if (dstsz == 0)
    return;
  size_t n = length < dstsz - 1 ? length : dstsz - 1;
  memcpy(dst, at, n);
  dst[n] = '\0';
}

static const char *find_ci(const char *hay, size_t haylen, const char *needle) {
  size_t nlen = strlen(needle);
  if (nlen == 0 || haylen < nlen)
    return NULL;
  for (size_t i = 0; i + nlen <= haylen; i++) {
    if (strncasecmp(hay + i, needle, nlen) == 0)
      return hay + i;
  }
  return NULL;
}

static void copy_range(char *dst, size_t dstsz, const char *at, size_t start,
                       size_t end) {
  if (end <= start) {
    if (dstsz)
      dst[0] = '\0';
    return;
  }
  size_t n = end - start;
  if (n >= dstsz)
    n = dstsz - 1;
  memcpy(dst, at + start, n);
  dst[n] = '\0';
}

static void sanitize_filename(char *name) {
  if (name == NULL || name[0] == '\0')
    return;
  char *base = name;
  for (char *p = name; *p != '\0'; p++) {
    if (*p == '/' || *p == '\\')
      base = p + 1;
  }
  if (base != name) {
    size_t n = strlen(base);
    memmove(name, base, n + 1);
  }
  if (strcmp(name, ".") == 0 || strcmp(name, "..") == 0) {
    name[0] = '\0';
  }
}

static int mp_on_header_field(multipart_parser *p, const char *at,
                              size_t length) {
  client_ctx_t *ctx = (client_ctx_t *)multipart_parser_get_data(p);
  multipart_state_t *mp = ctx->mp;
  if (mp == NULL)
    return -1;
  if (length >= 19 && strncasecmp(at, "Content-Disposition", 19) == 0) {
    mp->last_header = MP_HDR_CONTENT_DISPOSITION;
  } else if (length >= 12 && strncasecmp(at, "Content-Type", 12) == 0) {
    mp->last_header = MP_HDR_CONTENT_TYPE;
  } else {
    mp->last_header = MP_HDR_OTHER;
  }
  return 0;
}

static int mp_on_header_value(multipart_parser *p, const char *at,
                              size_t length) {
  client_ctx_t *ctx = (client_ctx_t *)multipart_parser_get_data(p);
  multipart_state_t *mp = ctx->mp;
  if (mp == NULL)
    return -1;

  if (mp->last_header == MP_HDR_CONTENT_DISPOSITION) {
    const char *name_p = find_ci(at, length, "name=\"");
    if (name_p != NULL) {
      size_t off = (size_t)(name_p - at) + 6;
      size_t end = off;
      while (end < length && at[end] != '"')
        end++;
      copy_range(mp->field_name, sizeof(mp->field_name), at, off, end);
    }
    const char *fname_p = find_ci(at, length, "filename=\"");
    if (fname_p != NULL) {
      size_t off = (size_t)(fname_p - at) + 10;
      size_t end = off;
      while (end < length && at[end] != '"')
        end++;
      copy_range(mp->filename, sizeof(mp->filename), at, off, end);
      sanitize_filename(mp->filename);
    }
  } else if (mp->last_header == MP_HDR_CONTENT_TYPE) {
    safe_copy(mp->content_type, sizeof(mp->content_type), at, length);
  }
  return 0;
}

static int mp_on_part_data_begin(multipart_parser *p) {
  client_ctx_t *ctx = (client_ctx_t *)multipart_parser_get_data(p);
  multipart_state_t *mp = ctx->mp;
  if (mp == NULL)
    return -1;
  mp->current_size = 0;
  mp->current_file = NULL;
  mp->temp_path[0] = '\0';
  buf_reset(&mp->field_value);
  return 0;
}

static int mp_on_part_data(multipart_parser *p, const char *at, size_t length) {
  client_ctx_t *ctx = (client_ctx_t *)multipart_parser_get_data(p);
  multipart_state_t *mp = ctx->mp;
  if (mp == NULL)
    return -1;

  if (mp->filename[0] != '\0') {
    if (mp->current_file == NULL) {
      char tmpl[] = "/tmp/mojelly-upload-XXXXXX";
      int fd = mkstemp(tmpl);
      if (fd < 0) {
        mp->error = 1;
        return -1;
      }
      mp->current_file = fdopen(fd, "wb");
      if (!mp->current_file) {
        close(fd);
        unlink(tmpl);
        mp->error = 1;
        return -1;
      }
      setvbuf(mp->current_file, NULL, _IOFBF, 65536);
      strncpy(mp->temp_path, tmpl, sizeof(mp->temp_path) - 1);
      mp->temp_path[sizeof(mp->temp_path) - 1] = '\0';
    }
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
    size_t written = fwrite_unlocked(at, 1, length, mp->current_file);
    if (written != length) {
      mp->error = 1;
      return -1;
    }
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

static int mp_on_part_data_end(multipart_parser *p) {
  client_ctx_t *ctx = (client_ctx_t *)multipart_parser_get_data(p);
  multipart_state_t *mp = ctx->mp;
  if (mp == NULL)
    return -1;

  if (mp->current_file != NULL) {
    if (fflush_unlocked(mp->current_file) != 0)
      mp->error = 1;
    if (fclose(mp->current_file) != 0)
      mp->error = 1;
    mp->current_file = NULL;
    mp->part_count++;

    if (!mp->error && mp->filename[0] != '\0') {
      if (mp->file_count >= g_max_parts || mp->file_count >= 100) {
        mp->error = 1;
      } else {
        mp_file_part_t *f = &mp->files[mp->file_count];
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
        mp_form_field_t *f = &mp->form[mp->form_count];
        strncpy(f->name, mp->field_name, sizeof(f->name) - 1);
        f->name[sizeof(f->name) - 1] = '\0';
        f->value_len = mp->field_value.len;
        if (f->value_len > 0) {
          char *dst = (char *)arena_alloc(&ctx->arena, f->value_len + 1);
          if (dst != NULL) {
            f->arena_backed = 1;
          } else {
            dst = (char *)malloc(f->value_len + 1);
            f->arena_backed = 0;
          }
          if (dst == NULL) {
            mp->error = 1;
          } else {
            memcpy(dst, mp->field_value.data, f->value_len);
            dst[f->value_len] = '\0';
            f->value = dst;
            mp->form_count++;
          }
        } else {
          f->value = NULL;
          f->arena_backed = 0;
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

static int mp_on_body_end(multipart_parser *p) {
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

static char *extract_boundary(const char *content_type, size_t ct_len) {
  if (content_type == NULL || ct_len == 0)
    return NULL;
  const char *p = find_ci(content_type, ct_len, "boundary=");
  if (p == NULL)
    return NULL;
  const char *limit = content_type + ct_len;
  p += 9;
  while (p < limit && (*p == ' ' || *p == '\t'))
    p++;
  const char *start = p;
  char quote = 0;
  if (start < limit && *start == '"') {
    quote = '"';
    start++;
  }
  const char *end = start;
  if (quote != 0) {
    while (end < limit && *end != quote)
      end++;
  } else {
    while (end < limit && *end != ';' && *end != '\r' && *end != '\n' &&
           *end != ' ')
      end++;
  }
  size_t len = (size_t)(end - start);
  if (len == 0)
    return NULL;
  char *boundary = (char *)malloc(len + 1);
  if (boundary == NULL)
    return NULL;
  memcpy(boundary, start, len);
  boundary[len] = '\0';
  return boundary;
}

/* ================= Common request dispatch ================= */

static inline uint8_t http_method_id(uint8_t m) {
  switch (m) {
  case HTTP_GET:
    return MOJELLY_METHOD_GET;
  case HTTP_POST:
    return MOJELLY_METHOD_POST;
  case HTTP_PUT:
    return MOJELLY_METHOD_PUT;
  case HTTP_DELETE:
    return MOJELLY_METHOD_DELETE;
  case HTTP_PATCH:
    return MOJELLY_METHOD_PATCH;
  case HTTP_HEAD:
    return MOJELLY_METHOD_HEAD;
  default:
    return MOJELLY_METHOD_OTHER;
  }
}

static inline size_t http_method_len(uint8_t m, const char *name) {
  switch (m) {
  case HTTP_GET:
    return 3;
  case HTTP_POST:
    return 4;
  case HTTP_PUT:
    return 3;
  case HTTP_DELETE:
    return 6;
  case HTTP_PATCH:
    return 5;
  case HTTP_HEAD:
    return 4;
  case HTTP_OPTIONS:
    return 7;
  default:
    return strlen(name);
  }
}

static NOINLINE char *
call_mojo_with_multipart(void *router, client_ctx_t *ctx, uint8_t method_id,
                         const char *url, size_t url_len, const char *method,
                         size_t method_len, const char *headers,
                         size_t headers_len, const char *body, size_t body_len,
                         size_t *resp_len, int *resp_owned) {
  int form_count = ctx->mp->form_count;
  int file_count = ctx->mp->file_count;

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

  return mojo_handler(router, url, method, headers, body, resp_len, resp_owned,
                      url_len, method_len, headers_len, body_len, method_id,
                      ctx->keep_alive, tl_resp_buf, RESP_SCRATCH_SIZE, form_arr,
                      (size_t)form_count, file_arr, (size_t)file_count);
}

static inline void dispatch_http_request(client_ctx_t *ctx, uint8_t method_id,
                                         const char *method, size_t method_len,
                                         const char *url, size_t url_len,
                                         const char *headers,
                                         size_t headers_len, const char *body,
                                         size_t body_len) {
  if (UNLIKELY(__atomic_load_n(&g_static.enabled, __ATOMIC_RELAXED)) &&
      (method_id == MOJELLY_METHOD_GET || method_id == MOJELLY_METHOD_HEAD)) {
    if (try_serve_static(ctx, method_id == MOJELLY_METHOD_HEAD, method, url,
                         url_len)) {
      return;
    }
  }

  void *router = ctx->router ? ctx->router : global_router;
  if (UNLIKELY(router == NULL)) {
    send_response(&ctx->client, http_500, sizeof(http_500) - 1, 0,
                  MOJO_RESP_BORROWED);
    return;
  }

  struct timespec start, end;
  int log_on = g_log_level >= 1;
  if (UNLIKELY(log_on))
    clock_gettime(CLOCK_MONOTONIC, &start);

  size_t resp_len = 0;
  int resp_owned = MOJO_RESP_OWNED;
  char *response;
  if (UNLIKELY(ctx->mp != NULL)) {
    response = call_mojo_with_multipart(
        router, ctx, method_id, url, url_len, method, method_len, headers,
        headers_len, body, body_len, &resp_len, &resp_owned);
  } else {
    response = mojo_handler(router, url, method, headers, body, &resp_len,
                            &resp_owned, url_len, method_len, headers_len,
                            body_len, method_id, ctx->keep_alive, tl_resp_buf,
                            RESP_SCRATCH_SIZE, NULL, 0, NULL, 0);
  }

  double duration_ms = 0.0;
  if (UNLIKELY(log_on)) {
    clock_gettime(CLOCK_MONOTONIC, &end);
    duration_ms = (end.tv_sec - start.tv_sec) * 1000.0 +
                  (end.tv_nsec - start.tv_nsec) / 1000000.0;
  }

  int keep_alive = ctx->keep_alive;
  if (LIKELY(response != NULL)) {
    if (resp_len == 0)
      resp_len = strlen(response);
    if (UNLIKELY(log_on)) {
      int status = extract_status_from_response(response, resp_len);
      log_request(method, url, url_len, status, duration_ms);
    }
    send_response(&ctx->client, response, resp_len, keep_alive, resp_owned);
  } else {
    if (UNLIKELY(log_on))
      log_request(method, url, url_len, 500, duration_ms);
    send_response(&ctx->client, http_500, sizeof(http_500) - 1, 0,
                  MOJO_RESP_BORROWED);
  }
}

/* ================= Zero-copy fast-path GET HTTP/1.1 parser =================
 */

typedef struct {
  const char *url;
  size_t url_len;
  const char *headers;
  size_t headers_len;
  size_t consumed;
  int keep_alive;
} fast_req_t;

/* Возвращает 1 при валидном полном GET HTTP/1.1 без тела прямо внутри буфера.
 * При любом сомнении / неполноте / ошибке возвращает 0 — запрос уходит в
 * llhttp. */
static inline int try_fast_get(const char *data, size_t len, fast_req_t *out) {
  if (len < 18 || memcmp(data, "GET ", 4) != 0)
    return 0;

  const char *end = data + len;
  const char *url = data + 4;
  if (UNLIKELY(*url != '/'))
    return 0;

  const char *p = url + 1;
  while (p < end && (unsigned char)*p > 0x20 && (unsigned char)*p < 0x7F) {
    p++;
  }
  size_t url_len = (size_t)(p - url);
  if (UNLIKELY((size_t)(end - p) < 13 || memcmp(p, " HTTP/1.1\r\n", 11) != 0)) {
    return 0;
  }
  p += 11;

  const char *headers = p;
  int keep_alive = 1;

  for (;;) {
    if (UNLIKELY(p + 2 > end))
      return 0;
    if (p[0] == '\r' && p[1] == '\n') {
      size_t headers_len = (size_t)(p - headers);
      if (UNLIKELY(url_len + headers_len > g_max_header_size))
        return 0;
      out->url = url;
      out->url_len = url_len;
      out->headers = headers;
      out->headers_len = headers_len;
      out->consumed = (size_t)((p + 2) - data);
      out->keep_alive = keep_alive;
      return 1;
    }

    const char *name_start = p;
    while (p < end && g_tchar[(unsigned char)*p])
      p++;
    size_t name_len = (size_t)(p - name_start);
    if (UNLIKELY(name_len == 0 || p >= end || *p != ':'))
      return 0;
    p++;

    const char *val_start = p;
    while (p < end && *p != '\r') {
      unsigned char ch = (unsigned char)*p;
      if (UNLIKELY(ch < 0x20 && ch != '\t'))
        return 0;
      p++;
    }
    if (UNLIKELY(p + 2 > end || p[1] != '\n'))
      return 0;
    size_t val_len = (size_t)(p - val_start);

    unsigned char c0 = (unsigned char)name_start[0] | 0x20;
    if (UNLIKELY(c0 == 'c')) {
      if (name_len == 14 &&
          strncasecmp(name_start, "Content-Length", 14) == 0) {
        return 0;
      }
      if (name_len == 10 && strncasecmp(name_start, "Connection", 10) == 0) {
        const char *v = val_start;
        size_t vl = val_len;
        while (vl > 0 && (*v == ' ' || *v == '\t')) {
          v++;
          vl--;
        }
        while (vl > 0 && (v[vl - 1] == ' ' || v[vl - 1] == '\t'))
          vl--;
        if (vl == 5 && strncasecmp(v, "close", 5) == 0) {
          keep_alive = 0;
        } else if (!(vl == 10 && strncasecmp(v, "keep-alive", 10) == 0)) {
          return 0;
        }
      } else if (name_len == 12 &&
                 strncasecmp(name_start, "Content-Type", 12) == 0) {
        const char *v = val_start;
        size_t vl = val_len;
        while (vl > 0 && (*v == ' ' || *v == '\t')) {
          v++;
          vl--;
        }
        if (vl >= 19 && strncasecmp(v, "multipart/form-data", 19) == 0) {
          return 0;
        }
      }
    } else if (UNLIKELY(c0 == 't' && name_len == 17 &&
                        strncasecmp(name_start, "Transfer-Encoding", 17) ==
                            0)) {
      return 0;
    } else if (UNLIKELY(c0 == 'e' && name_len == 6 &&
                        strncasecmp(name_start, "Expect", 6) == 0)) {
      return 0;
    }

    p += 2;
  }
}

/* ================= llhttp callbacks ================= */

static int on_message_begin_c(llhttp_t *parser) {
  client_ctx_t *ctx = (client_ctx_t *)parser->data;
  ctx->llhttp_active = 1;
  ctx->reject_status = 0;
  ctx->expect_files = 0;
  ctx->keep_alive = 1;
  buf_reset_arena(&ctx->url);
  buf_reset_arena(&ctx->headers);
  buf_reset_arena(&ctx->body);
  arena_reset(&ctx->arena);
  ctx->header_state = HEADER_STATE_NONE;
  ctx->hdr_field_start = 0;
  ctx->ct_value_start = 0;
  ctx->ct_value_len = 0;
  ctx->in_content_type = 0;
  if (ctx->request_started_ms == 0) {
    ctx->request_started_ms = uv_now(ctx->client.loop);
  }
  return 0;
}

static inline int check_header_limit(client_ctx_t *ctx, size_t extra) {
  if (UNLIKELY(ctx->url.len + ctx->headers.len + extra > g_max_header_size)) {
    ctx->reject_status = 431;
    return -1;
  }
  return 0;
}

static int on_url_c(llhttp_t *parser, const char *at, size_t length) {
  client_ctx_t *ctx = (client_ctx_t *)parser->data;
  if (UNLIKELY(check_header_limit(ctx, length) != 0))
    return -1;
  return buf_append_arena_hint(&ctx->url, &ctx->arena, at, length, 256);
}

static int on_header_field_c(llhttp_t *parser, const char *at, size_t length) {
  client_ctx_t *ctx = (client_ctx_t *)parser->data;
  if (ctx->header_state == HEADER_STATE_VALUE) {
    if (UNLIKELY(ctx->in_content_type)) {
      ctx->ct_value_len = ctx->headers.len - ctx->ct_value_start;
      ctx->in_content_type = 0;
    }
    if (UNLIKELY(buf_append_arena_hint(&ctx->headers, &ctx->arena, "\r\n", 2,
                                       1024) != 0))
      return -1;
  }
  if (ctx->header_state != HEADER_STATE_FIELD) {
    ctx->hdr_field_start = ctx->headers.len;
    ctx->in_content_type = 0;
    ctx->header_state = HEADER_STATE_FIELD;
  }
  if (UNLIKELY(check_header_limit(ctx, length + 2) != 0))
    return -1;
  return buf_append_arena_hint(&ctx->headers, &ctx->arena, at, length, 1024);
}

static int on_header_value_c(llhttp_t *parser, const char *at, size_t length) {
  client_ctx_t *ctx = (client_ctx_t *)parser->data;
  if (ctx->header_state == HEADER_STATE_FIELD) {
    size_t flen = ctx->headers.len - ctx->hdr_field_start;
    if (UNLIKELY(flen == 12 &&
                 strncasecmp(ctx->headers.data + ctx->hdr_field_start,
                             "Content-Type", 12) == 0)) {
      ctx->in_content_type = 1;
    }
    if (UNLIKELY(buf_append_arena_hint(&ctx->headers, &ctx->arena, ": ", 2,
                                       1024) != 0))
      return -1;
    if (UNLIKELY(ctx->in_content_type)) {
      ctx->ct_value_start = ctx->headers.len;
    }
    ctx->header_state = HEADER_STATE_VALUE;
  }
  if (UNLIKELY(check_header_limit(ctx, length + 2) != 0))
    return -1;
  return buf_append_arena_hint(&ctx->headers, &ctx->arena, at, length, 1024);
}

static NOINLINE int init_multipart_request(client_ctx_t *ctx, llhttp_t *parser,
                                           const char *content_type,
                                           size_t ct_len) {
  const char *method = llhttp_method_name((llhttp_method_t)parser->method);
  ctx->expect_files = (method != NULL && ctx->url.data != NULL)
                          ? is_upload_route(method, ctx->url.data)
                          : 0;
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

  ctx->mp->boundary = extract_boundary(content_type, ct_len);
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
  return 0;
}

static int on_headers_complete_c(llhttp_t *parser) {
  client_ctx_t *ctx = (client_ctx_t *)parser->data;

  if (ctx->header_state == HEADER_STATE_VALUE) {
    if (UNLIKELY(ctx->in_content_type)) {
      ctx->ct_value_len = ctx->headers.len - ctx->ct_value_start;
      ctx->in_content_type = 0;
    }
    if (UNLIKELY(buf_append_arena_hint(&ctx->headers, &ctx->arena, "\r\n", 2,
                                       1024) != 0))
      return -1;
  }
  ctx->header_state = HEADER_STATE_NONE;
  ctx->keep_alive = llhttp_should_keep_alive(parser);

  if (UNLIKELY(ctx->ct_value_len >= 19 && ctx->headers.data != NULL)) {
    const char *p = ctx->headers.data + ctx->ct_value_start;
    size_t ct_len = ctx->ct_value_len;
    while (ct_len > 0 && (*p == ' ' || *p == '\t')) {
      p++;
      ct_len--;
    }
    if (ct_len >= 19 && strncasecmp(p, "multipart/form-data", 19) == 0) {
      return init_multipart_request(ctx, parser, p, ct_len);
    }
  }

  uint64_t cl = parser->content_length;
  if (UNLIKELY(cl != ULLONG_MAX && cl > g_max_body_size)) {
    ctx->reject_status = 413;
    return -1;
  }
  if (cl != ULLONG_MAX && cl > 0) {
    size_t want = cl < BODY_PRERESERVE_MAX ? (size_t)cl : BODY_PRERESERVE_MAX;
    if (UNLIKELY(buf_reserve_arena(&ctx->body, &ctx->arena, want + 1) != 0))
      return -1;
  }
  return 0;
}

static int on_body_c(llhttp_t *parser, const char *at, size_t length) {
  client_ctx_t *ctx = (client_ctx_t *)parser->data;

  if (UNLIKELY(ctx->is_multipart)) {
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

  if (UNLIKELY(ctx->body.len + length > g_max_body_size)) {
    ctx->reject_status = 413;
    return -1;
  }
  return buf_append_arena(&ctx->body, &ctx->arena, at, length);
}

static int on_message_complete_c(llhttp_t *parser) {
  client_ctx_t *ctx = (client_ctx_t *)parser->data;

  if (UNLIKELY(ctx->mp != NULL && ctx->mp->error)) {
    send_response(&ctx->client, http_500, sizeof(http_500) - 1, 0,
                  MOJO_RESP_BORROWED);
    return HPE_PAUSED;
  }

  const char *method = llhttp_method_name((llhttp_method_t)parser->method);
  uint8_t method_id = http_method_id(parser->method);
  size_t method_len = http_method_len(parser->method, method);

  dispatch_http_request(
      ctx, method_id, method, method_len, ctx->url.data ? ctx->url.data : "",
      ctx->url.len, ctx->headers.data ? ctx->headers.data : "",
      ctx->headers.len, ctx->body.data ? ctx->body.data : "", ctx->body.len);

  return (ctx->processing || uv_is_closing((uv_handle_t *)&ctx->client))
             ? HPE_PAUSED
             : 0;
}

/* ================= read ================= */

static void alloc_buffer_c(uv_handle_t *handle, size_t suggested_size,
                           uv_buf_t *buf) {
  (void)handle;
  (void)suggested_size;
  static _Thread_local char read_buf[READ_BUFFER_SIZE];
  buf->base = read_buf;
  buf->len = READ_BUFFER_SIZE;
}

static NOINLINE void send_parse_error(client_ctx_t *ctx) {
  const char *resp = http_400;
  size_t len = sizeof(http_400) - 1;
  if (ctx->reject_status == 415) {
    resp = http_415;
    len = sizeof(http_415) - 1;
  } else if (ctx->reject_status == 431) {
    resp = http_431;
    len = sizeof(http_431) - 1;
  } else if (ctx->reject_status == 413) {
    resp = http_413;
    len = sizeof(http_413) - 1;
  }
  uv_read_stop((uv_stream_t *)&ctx->client);
  send_response(&ctx->client, resp, len, 0, MOJO_RESP_BORROWED);
}

static void execute_http_data(client_ctx_t *ctx, const char *data, size_t len) {
  size_t pos = 0;

  /* Zero-copy fast-path для полных GET HTTP/1.1 запросов (включая pipelining)
   */
  while (LIKELY(!ctx->llhttp_active && !ctx->processing &&
                !uv_is_closing((uv_handle_t *)&ctx->client) && pos < len)) {
    fast_req_t freq;
    if (!try_fast_get(data + pos, len - pos, &freq)) {
      break;
    }
    pos += freq.consumed;
    ctx->keep_alive = freq.keep_alive;
    dispatch_http_request(ctx, MOJELLY_METHOD_GET, "GET", 3, freq.url,
                          freq.url_len, freq.headers, freq.headers_len, "", 0);
    if (UNLIKELY(!freq.keep_alive)) {
      return;
    }
  }

  if (LIKELY(pos >= len || uv_is_closing((uv_handle_t *)&ctx->client))) {
    return;
  }

  if (UNLIKELY(ctx->processing)) {
    size_t rem = len - pos;
    if (ctx->pending.len + rem > g_max_header_size + g_max_body_size) {
      ctx->reject_status = 413;
      send_parse_error(ctx);
      return;
    }
    if (buf_append_arena(&ctx->pending, NULL, data + pos, rem) != 0) {
      uv_read_stop((uv_stream_t *)&ctx->client);
      send_response(&ctx->client, http_500, sizeof(http_500) - 1, 0,
                    MOJO_RESP_BORROWED);
    }
    return;
  }

  /* Fallback на полноценный llhttp
   * (POST/PUT/chunked/фрагментация/HTTP 1.0/ошибки) */
  ctx->llhttp_active = 1;
  const char *ll_data = data + pos;
  size_t ll_len = len - pos;
  enum llhttp_errno err = llhttp_execute(&ctx->parser, ll_data, ll_len);
  if (LIKELY(err == HPE_OK))
    return;

  if (err == HPE_PAUSED) {
    if (ctx->processing && !uv_is_closing((uv_handle_t *)&ctx->client)) {
      const char *err_pos = llhttp_get_error_pos(&ctx->parser);
      if (err_pos != NULL && err_pos >= ll_data && err_pos < ll_data + ll_len) {
        size_t rem = (size_t)((ll_data + ll_len) - err_pos);
        if (ctx->pending.len + rem > g_max_header_size + g_max_body_size) {
          ctx->reject_status = 413;
          send_parse_error(ctx);
          return;
        }
        if (buf_append_arena(&ctx->pending, NULL, err_pos, rem) != 0) {
          uv_read_stop((uv_stream_t *)&ctx->client);
          send_response(&ctx->client, http_500, sizeof(http_500) - 1, 0,
                        MOJO_RESP_BORROWED);
          return;
        }
      }
    }
    return;
  }

  send_parse_error(ctx);
}

static void on_read_c(uv_stream_t *client, ssize_t nread, const uv_buf_t *buf) {
  if (LIKELY(nread > 0)) {
    client_ctx_t *ctx = (client_ctx_t *)client->data;
    if (UNLIKELY(ctx == NULL))
      return;
    uint64_t now = uv_now(client->loop);
    idle_touch(ctx, now);
    if (ctx->request_started_ms == 0 && !ctx->processing)
      ctx->request_started_ms = now;

    if (UNLIKELY(ctx->processing)) {
      if (ctx->pending.len + (size_t)nread >
          g_max_header_size + g_max_body_size) {
        ctx->reject_status = 413;
        send_parse_error(ctx);
        return;
      }
      if (buf_append_arena(&ctx->pending, NULL, buf->base, (size_t)nread) !=
          0) {
        uv_read_stop(client);
        send_response((uv_tcp_t *)client, http_500, sizeof(http_500) - 1, 0,
                      MOJO_RESP_BORROWED);
        return;
      }
    } else {
      execute_http_data(ctx, buf->base, (size_t)nread);
    }
  } else if (nread < 0) {
    client_ctx_t *ctx = (client_ctx_t *)client->data;
    if (ctx != NULL && ctx->static_tx != NULL &&
        (ctx->static_tx->in_flight || ctx->static_tx->headers_writing)) {
      ctx->static_state = STATIC_STATE_ABORTING;
      static_close_retry_timer(ctx->static_tx);
      uv_read_stop(client);
      return;
    }
    if (!uv_is_closing((uv_handle_t *)client))
      uv_close((uv_handle_t *)client, on_close_c);
  }
}

/* ================= sweep ================= */

static void sweep_timeouts_c(uv_timer_t *timer) {
  uint64_t now = uv_now(timer->loop);
  if (g_idle_timeout_ms > 0) {
    uint64_t idle = (uint64_t)g_idle_timeout_ms;
    while (tl_idle_head != NULL) {
      client_ctx_t *c = tl_idle_head;
      if (now <= c->last_active_ms || (now - c->last_active_ms) <= idle)
        break;
      idle_remove(c);
      if (c->static_tx != NULL &&
          (c->static_tx->in_flight || c->static_tx->headers_writing)) {
        c->static_state = STATIC_STATE_ABORTING;
        static_close_retry_timer(c->static_tx);
        uv_read_stop((uv_stream_t *)&c->client);
        continue;
      }
      if (!uv_is_closing((uv_handle_t *)&c->client))
        uv_close((uv_handle_t *)&c->client, on_close_c);
    }
  }
  if (g_request_timeout_ms > 0) {
    uint64_t rt = (uint64_t)g_request_timeout_ms;
    client_ctx_t *c = conn_list;
    while (c) {
      client_ctx_t *next = c->next;
      if (!uv_is_closing((uv_handle_t *)&c->client) &&
          c->request_started_ms != 0 && !c->processing &&
          now > c->request_started_ms && (now - c->request_started_ms) > rt) {
        uv_close((uv_handle_t *)&c->client, on_close_c);
      }
      c = next;
    }
  }
}

/* ================= graceful shutdown ================= */

static uint64_t g_shutdown_started_ms = 0;

static void on_signal(uv_signal_t *handle, int signum) {
  (void)signum;
  if (g_shutdown)
    return;
  g_shutdown = 1;
  g_shutdown_started_ms = uv_now(handle->loop);
  fprintf(stderr, "[C] Received signal %d, starting graceful shutdown...\n",
          signum);
}

static void check_shutdown_c(uv_timer_t *timer) {
  int *stopped = (int *)timer->data;
  if (!g_shutdown || *stopped)
    return;
  uint64_t now = uv_now(timer->loop);
  int drained = (conn_list == NULL);
  int timed_out =
      (g_shutdown_timeout_ms > 0) &&
      (now - g_shutdown_started_ms > (uint64_t)g_shutdown_timeout_ms);
  if (drained || timed_out) {
    *stopped = 1;
    fprintf(stderr, "[C] Shutdown (%s), stopping loop\n",
            timed_out && !drained ? "timeout" : "drained");
    uv_stop(timer->loop);
  }
}

static void close_all_cb(uv_handle_t *h, void *arg) {
  (void)arg;
  if (uv_is_closing(h))
    return;
  if (h->type == UV_TCP) {
    uv_close(h, on_close_c);
  } else {
    uv_close(h, NULL);
  }
}

/* ================= connection ================= */

static void on_connection_c(uv_stream_t *server, int status) {
  if (UNLIKELY(status < 0 || g_shutdown))
    return;

  client_ctx_t *ctx = ctx_alloc();
  if (UNLIKELY(!ctx))
    return;

  uv_tcp_init(server->loop, &ctx->client);
  ctx->client.data = ctx;

  ctx->router = global_router;
  if (UNLIKELY(ctx->arena.base == NULL)) {
    arena_init(&ctx->arena, ARENA_DEFAULT_SIZE);
  }
  buf_init(&ctx->url);
  ctx->url.arena_backed = 1;
  buf_init(&ctx->headers);
  ctx->headers.arena_backed = 1;
  buf_init(&ctx->body);
  ctx->body.arena_backed = 1;
  buf_init(&ctx->pending);
  ctx->pending.arena_backed = 0;

  ctx->header_state = HEADER_STATE_NONE;
  ctx->llhttp_active = 0;
  ctx->processing = 0;
  ctx->last_active_ms = uv_now(server->loop);
  ctx->expect_files = 0;
  ctx->is_multipart = 0;
  ctx->mp = NULL;
  ctx->static_state = STATIC_STATE_IDLE;
  ctx->static_tx = NULL;

  llhttp_init(&ctx->parser, HTTP_REQUEST, &g_settings);
  ctx->parser.data = ctx;

  if (UNLIKELY(uv_accept(server, (uv_stream_t *)&ctx->client) != 0)) {
    uv_close((uv_handle_t *)&ctx->client, on_close_c);
    return;
  }
  conn_link(ctx);
  idle_push(ctx);

  int fd = -1;
  if (uv_fileno((uv_handle_t *)&ctx->client, &fd) == 0 && fd >= 0) {
    int nodelay = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &nodelay, sizeof(nodelay));
#ifdef TCP_QUICKACK
    int quickack = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_QUICKACK, &quickack, sizeof(quickack));
#endif
  }

  if (UNLIKELY(uv_read_start((uv_stream_t *)&ctx->client, alloc_buffer_c,
                             on_read_c) != 0)) {
    uv_close((uv_handle_t *)&ctx->client, on_close_c);
  }
}

/* ================= server socket ================= */

static int create_bound_socket(int port) {
  int fd = socket(AF_INET, SOCK_STREAM, 0);
  if (fd < 0)
    return -1;
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
  if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
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
      if (CPU_ISSET(c, &set))
        allowed_cpus[num_allowed_cpus++] = c;
    }
  }
  if (num_allowed_cpus == 0)
    allowed_cpus[num_allowed_cpus++] = 0;
}

static int resolve_thread_count(int requested) {
  if (requested > 0)
    return requested;
  const char *env = getenv("MOJELLY_THREADS");
  if (env != NULL && atoi(env) > 0)
    return atoi(env);
  return num_allowed_cpus;
}

static pthread_t g_worker_threads[256];
static int g_worker_count = 0;
static pthread_mutex_t g_worker_mutex = PTHREAD_MUTEX_INITIALIZER;

typedef struct {
  int port;
  void *router;
  int thread_id;
} thread_args_t;

static void *thread_main(void *arg) {
  thread_args_t *args = (thread_args_t *)arg;
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
  if (server_fd < 0) {
    return NULL;
  }

  uv_loop_t *loop = (uv_loop_t *)malloc(sizeof(uv_loop_t));
  if (!loop) {
    close(server_fd);
    return NULL;
  }
  if (uv_loop_init(loop) != 0) {
    free(loop);
    close(server_fd);
    return NULL;
  }

  uv_tcp_t *server = (uv_tcp_t *)malloc(sizeof(uv_tcp_t));
  if (!server) {
    uv_loop_close(loop);
    free(loop);
    close(server_fd);
    return NULL;
  }
  uv_tcp_init(loop, server);

  int rc = uv_tcp_open(server, server_fd);
  if (rc != 0) {
    close(server_fd);
    uv_close((uv_handle_t *)server, NULL);
    uv_run(loop, UV_RUN_NOWAIT);
    uv_loop_close(loop);
    free(server);
    free(loop);
    return NULL;
  }

  rc = uv_listen((uv_stream_t *)server, LISTEN_BACKLOG, on_connection_c);
  if (rc != 0) {
    uv_close((uv_handle_t *)server, NULL);
    uv_run(loop, UV_RUN_NOWAIT);
    uv_loop_close(loop);
    free(server);
    free(loop);
    return NULL;
  }

  uv_timer_t *sweep = NULL;
  if (g_idle_timeout_ms > 0 || g_request_timeout_ms > 0) {
    sweep = (uv_timer_t *)malloc(sizeof(uv_timer_t));
    if (sweep) {
      uv_timer_init(loop, sweep);
      uv_timer_start(sweep, sweep_timeouts_c, 1000, 1000);
    }
  }

  uv_signal_t *sigint_h = (uv_signal_t *)malloc(sizeof(uv_signal_t));
  uv_signal_t *sigterm_h = (uv_signal_t *)malloc(sizeof(uv_signal_t));
  if (sigint_h) {
    uv_signal_init(loop, sigint_h);
    uv_signal_start(sigint_h, on_signal, SIGINT);
    uv_unref((uv_handle_t *)sigint_h);
  }
  if (sigterm_h) {
    uv_signal_init(loop, sigterm_h);
    uv_signal_start(sigterm_h, on_signal, SIGTERM);
    uv_unref((uv_handle_t *)sigterm_h);
  }

  uv_timer_t *shutdown_timer = (uv_timer_t *)malloc(sizeof(uv_timer_t));
  int shutdown_stopped = 0;
  if (shutdown_timer) {
    uv_timer_init(loop, shutdown_timer);
    shutdown_timer->data = &shutdown_stopped;
    uv_timer_start(shutdown_timer, check_shutdown_c, 100, 100);
  }

  printf("[C] Thread %d listening on CPU %d (port %d)\n", thread_id, cpu_id,
         port);
  fflush(stdout);

  uv_run(loop, UV_RUN_DEFAULT);

  if (sweep)
    uv_timer_stop(sweep);
  if (shutdown_timer)
    uv_timer_stop(shutdown_timer);
  uv_walk(loop, close_all_cb, NULL);
  uv_run(loop, UV_RUN_DEFAULT);
  uv_loop_close(loop);

  ctx_slab_destroy_tl();
  wr_pool_destroy_tl();

  free(shutdown_timer);
  free(sigint_h);
  free(sigterm_h);
  free(sweep);
  free(server);
  free(loop);
  return NULL;
}

/* ================= public API ================= */

void pthread_create_wrapper(int port, void *router, int num_threads) {
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
    thread_args_t *args = (thread_args_t *)malloc(sizeof(thread_args_t));
    if (!args)
      continue;
    args->port = port;
    args->router = router;
    args->thread_id = i;
    if (pthread_create(&thread, NULL, thread_main, args) != 0) {
      fprintf(stderr, "[C] pthread_create failed for thread %d\n", i);
      free(args);
      continue;
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
  for (int i = 0; i < n; i++)
    copy[i] = g_worker_threads[i];
  pthread_mutex_unlock(&g_worker_mutex);
  for (int i = 0; i < n; i++)
    pthread_join(copy[i], NULL);
}

void mojelly_ensure_init(void) { ensure_settings_init(); }

/* ================= low-level wrappers ================= */

void uv_tcp_init_wrapper(uv_loop_t *loop, uv_tcp_t *tcp) {
  ensure_settings_init();
  uv_tcp_init(loop, tcp);
}

void uv_tcp_bind_wrapper(uv_tcp_t *tcp, const char *ip, int port) {
  ensure_settings_init();
  struct sockaddr_in addr;
  uv_ip4_addr(ip, port, &addr);
  int rc = uv_tcp_bind(tcp, (const struct sockaddr *)&addr, 0);
  if (rc != 0)
    fprintf(stderr, "[C] uv_tcp_bind failed: %s\n", uv_strerror(rc));
}

void uv_listen_wrapper(uv_tcp_t *tcp, int backlog) {
  ensure_settings_init();
  int rc = uv_listen((uv_stream_t *)tcp, backlog, on_connection_c);
  if (rc != 0)
    fprintf(stderr, "[C] uv_listen failed: %s\n", uv_strerror(rc));
}
void uv_run_wrapper(uv_loop_t *loop) {
  if (loop)
    uv_run(loop, UV_RUN_DEFAULT);
}
void uv_read_start_wrapper(uv_tcp_t *client) {
  if (client)
    uv_read_start((uv_stream_t *)client, alloc_buffer_c, on_read_c);
}
void uv_read_stop_wrapper(uv_tcp_t *client) {
  if (client)
    uv_read_stop((uv_stream_t *)client);
}
void uv_write_wrapper(uv_tcp_t *client, const char *data, size_t len) {
  if (client == NULL || uv_is_closing((uv_handle_t *)client))
    return;
  write_req_t *wr = wr_acquire();
  if (!wr) {
    uv_close((uv_handle_t *)client, on_close_c);
    return;
  }
  wr->data = (char *)malloc(len ? len : 1);
  if (!wr->data) {
    wr_release(wr);
    uv_close((uv_handle_t *)client, on_close_c);
    return;
  }
  if (len)
    memcpy(wr->data, data, len);
  wr->len = len;
  wr->client = client;
  wr->keep_alive = 0;
  wr->free_data = 1;
  uv_buf_t buf = uv_buf_init(wr->data, (unsigned int)len);
  int rc = uv_write(&wr->req, (uv_stream_t *)client, &buf, 1, on_write_c);
  if (rc != 0) {
    free(wr->data);
    wr_release(wr);
    uv_close((uv_handle_t *)client, on_close_c);
  }
}
void uv_close_wrapper(uv_tcp_t *client) {
  if (client && !uv_is_closing((uv_handle_t *)client))
    uv_close((uv_handle_t *)client, on_close_c);
}
uv_loop_t *uv_loop_create_wrapper(void) {
  ensure_settings_init();
  uv_loop_t *loop = (uv_loop_t *)malloc(sizeof(uv_loop_t));
  if (!loop)
    return NULL;
  uv_loop_init(loop);
  return loop;
}
void uv_loop_destroy_wrapper(uv_loop_t *loop) {
  if (!loop)
    return;
  uv_walk(loop, close_all_cb, NULL);
  uv_run(loop, UV_RUN_DEFAULT);
  uv_loop_close(loop);
  free(loop);
}
void mojelly_free_response(char *ptr) {
  if (ptr)
    free(ptr);
}
