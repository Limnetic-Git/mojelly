#define _GNU_SOURCE
#include <sched.h>

#include <uv.h>
#include <llhttp.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <time.h>
#include <sys/socket.h>
#include <unistd.h>
#include <pthread.h>
#include <arpa/inet.h>
#include <fcntl.h>

#define LOG_LEVEL 1
//0 - Errors only (recommended for best performance)
//1 - Requests logs (recommended for default use)
//2 - All logs (use for debug only)

#define LOG_COLORS 1
// 0 - u are boring, but little bit faster
// 1 - u are cool =)

#if LOG_COLORS
#define COLOR_RESET   "\033[0m"
#define COLOR_GREEN   "\033[32m"
#define COLOR_YELLOW  "\033[33m"
#define COLOR_BLUE    "\033[34m"
#define COLOR_MAGENTA "\033[35m"
#define COLOR_CYAN    "\033[36m"
#define COLOR_RED     "\033[31m"
#define COLOR_BOLD    "\033[1m"
#else
#define COLOR_RESET   ""
#define COLOR_GREEN   ""
#define COLOR_YELLOW  ""
#define COLOR_BLUE    ""
#define COLOR_MAGENTA ""
#define COLOR_CYAN    ""
#define COLOR_RED     ""
#define COLOR_BOLD    ""
#endif

static __thread int current_thread_id = -1;
static __thread unsigned long request_count = 0;

extern char* mojo_handler(void* router, const char* url, const char* method, const char* headers, const char* body);

static void* global_router = NULL;

void mojelly_set_router(void* router) {
    global_router = router;
}

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

static void buf_reset(buffer_t* b) {
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

static int buf_append(buffer_t* b, const char* data, size_t len) {
    if (len == 0) return 0;
    if (b->len + len + 1 > b->cap) {
        size_t new_cap = (b->cap == 0) ? 256 : b->cap * 2;
        while (new_cap < b->len + len + 1) {
            new_cap *= 2;
        }
        char* new_data = (char*)realloc(b->data, new_cap);
        if (!new_data) return -1;
        b->data = new_data;
        b->cap = new_cap;
    }
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

typedef struct {
    uv_tcp_t client;
    llhttp_t parser;
    llhttp_settings_t settings;
    buffer_t url;
    buffer_t headers;
    buffer_t body;
    header_state_t header_state;
    int keep_alive;
    void* router;
} client_ctx_t;

typedef struct {
    uv_write_t req;
    char* data;
    size_t len;
    uv_tcp_t* client;
} write_req_t;

typedef struct {
    int port;
    void* router;
    int thread_id;
    int server_fd;
} thread_args_t;

static const char* http_500 = "HTTP/1.1 500 Internal Server Error\r\n\r\n";
static const char* http_400 = "HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n";

#if LOG_LEVEL >= 1
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
    const char* method_color = get_method_color(method);
    const char* status_color = get_status_color(status);

    time_t now = time(NULL);
    struct tm* tm_info = localtime(&now);
    char time_str[20];
    strftime(time_str, sizeof(time_str), "%H:%M:%S", tm_info);

    printf("[%s] [T%d] ", time_str, current_thread_id);
    printf("%s%s%s ", method_color, method, COLOR_RESET);
    printf("%s%s%s ", COLOR_BOLD, url, COLOR_RESET);
    printf("%s%d%s ", status_color, status, COLOR_RESET);
    printf("%.2fms\n", duration_ms);
}
#else
#define log_request(method, url, status, duration_ms)
#endif

static void alloc_buffer_c(uv_handle_t* handle, size_t suggested_size, uv_buf_t* buf) {
    (void)handle;
    buf->base = (char*)malloc(suggested_size);
    buf->len = suggested_size;
}

static void on_close_c(uv_handle_t* handle) {
    client_ctx_t* ctx = (client_ctx_t*)handle->data;
    if (ctx != NULL) {
        buf_free(&ctx->url);
        buf_free(&ctx->headers);
        buf_free(&ctx->body);
        free(ctx);
    } else {
        free(handle);
    }
}

static void on_write_close_c(uv_write_t* req, int status) {
    (void)status;
    write_req_t* wr = (write_req_t*)req;
    if (wr->data != NULL) free(wr->data);
    if (wr->client != NULL && !uv_is_closing((uv_handle_t*)wr->client)) {
        uv_close((uv_handle_t*)wr->client, on_close_c);
    }
    free(wr);
}

static void on_write_keep_alive_c(uv_write_t* req, int status) {
    write_req_t* wr = (write_req_t*)req;
    if (wr->data != NULL) free(wr->data);
    if (status != 0 && wr->client != NULL && !uv_is_closing((uv_handle_t*)wr->client)) {
        uv_close((uv_handle_t*)wr->client, on_close_c);
    }
    free(wr);
}

static inline void send_response(uv_tcp_t* client, char* response, int keep_alive, int is_allocated) {
    if (client == NULL || uv_is_closing((uv_handle_t*)client)) {
        if (is_allocated && response != NULL) free(response);
        return;
    }

    if (response == NULL) {
        response = (char*)http_500;
        is_allocated = 0;
    }

    size_t len = strlen(response);
    write_req_t* wr = (write_req_t*)malloc(sizeof(write_req_t));
    if (!wr) {
        if (is_allocated && response != NULL) free(response);
        if (!uv_is_closing((uv_handle_t*)client)) {
            uv_close((uv_handle_t*)client, on_close_c);
        }
        return;
    }

    wr->client = client;
    if (is_allocated) {
        // Zero-duplicate transfer from Mojo: take ownership directly
        wr->data = response;
        wr->len = len;
    } else {
        wr->data = strdup(response);
        wr->len = len;
    }

    uv_buf_t buf = uv_buf_init(wr->data, (unsigned int)wr->len);

    if (keep_alive) {
        uv_write(&wr->req, (uv_stream_t*)client, &buf, 1, on_write_keep_alive_c);
    } else {
        uv_write(&wr->req, (uv_stream_t*)client, &buf, 1, on_write_close_c);
    }
}

static int extract_status_from_response(const char* response) {
    if (response == NULL) return 500;
    if (strncmp(response, "HTTP/1.1 ", 9) != 0) return 200;
    int status = 0;
    int i = 9;
    while (response[i] >= '0' && response[i] <= '9' && i < 12) {
        status = status * 10 + (response[i] - '0');
        i++;
    }
    return status > 0 ? status : 200;
}

static int on_message_begin_c(llhttp_t* parser) {
    client_ctx_t* ctx = (client_ctx_t*)parser->data;
    buf_reset(&ctx->url);
    buf_reset(&ctx->headers);
    buf_reset(&ctx->body);
    ctx->header_state = HEADER_STATE_NONE;
    return 0;
}

static int on_url_c(llhttp_t* parser, const char* at, size_t length) {
    client_ctx_t* ctx = (client_ctx_t*)parser->data;
    return buf_append(&ctx->url, at, length);
}

static int on_header_field_c(llhttp_t* parser, const char* at, size_t length) {
    client_ctx_t* ctx = (client_ctx_t*)parser->data;
    if (ctx->header_state == HEADER_STATE_VALUE) {
        buf_append(&ctx->headers, "\r\n", 2);
    }
    ctx->header_state = HEADER_STATE_FIELD;
    return buf_append(&ctx->headers, at, length);
}

static int on_header_value_c(llhttp_t* parser, const char* at, size_t length) {
    client_ctx_t* ctx = (client_ctx_t*)parser->data;
    if (ctx->header_state == HEADER_STATE_FIELD) {
        buf_append(&ctx->headers, ": ", 2);
    }
    ctx->header_state = HEADER_STATE_VALUE;
    return buf_append(&ctx->headers, at, length);
}

static int on_headers_complete_c(llhttp_t* parser) {
    client_ctx_t* ctx = (client_ctx_t*)parser->data;
    if (ctx->header_state == HEADER_STATE_VALUE) {
        buf_append(&ctx->headers, "\r\n", 2);
    }
    ctx->header_state = HEADER_STATE_NONE;
    ctx->keep_alive = llhttp_should_keep_alive(parser);
    return 0;
}

static int on_body_c(llhttp_t* parser, const char* at, size_t length) {
    client_ctx_t* ctx = (client_ctx_t*)parser->data;
    return buf_append(&ctx->body, at, length);
}

static int on_message_complete_c(llhttp_t* parser) {
    client_ctx_t* ctx = (client_ctx_t*)parser->data;
    void* router = ctx->router ? ctx->router : global_router;
    if (router == NULL) {
        send_response(&ctx->client, (char*)http_500, 0, 0);
        return 0;
    }

    request_count++;

    const char* method = llhttp_method_name(parser->method);
    const char* url = ctx->url.data ? ctx->url.data : "";
    const char* headers = ctx->headers.data ? ctx->headers.data : "";
    const char* body = ctx->body.data ? ctx->body.data : "";

    struct timespec start, end;
    clock_gettime(CLOCK_MONOTONIC, &start);

    char* response = mojo_handler(router, url, method, headers, body);

    clock_gettime(CLOCK_MONOTONIC, &end);
    double duration_ms = (end.tv_sec - start.tv_sec) * 1000.0 +
                         (end.tv_nsec - start.tv_nsec) / 1000000.0;

    int status = 500;
    if (response != NULL) {
        status = extract_status_from_response(response);
    }

    int keep_alive = ctx->keep_alive;
    if (response != NULL) {
        send_response(&ctx->client, response, keep_alive, 1);
    } else {
        send_response(&ctx->client, (char*)http_500, 0, 0);
    }

    log_request(method, url, status, duration_ms);
    return 0;
}

static void on_read_c(uv_stream_t* client, ssize_t nread, const uv_buf_t* buf) {
    client_ctx_t* ctx = (client_ctx_t*)client->data;
    if (nread > 0) {
        if (ctx != NULL) {
            enum llhttp_errno err = llhttp_execute(&ctx->parser, buf->base, nread);
            if (err != HPE_OK) {
                send_response((uv_tcp_t*)client, (char*)http_400, 0, 0);
            }
        }
    } else if (nread < 0) {
        if (!uv_is_closing((uv_handle_t*)client)) {
            uv_close((uv_handle_t*)client, on_close_c);
        }
    }
    if (buf->base != NULL) free(buf->base);
}

static void on_connection_c(uv_stream_t* server, int status) {
    if (status < 0) return;

    client_ctx_t* ctx = (client_ctx_t*)malloc(sizeof(client_ctx_t));
    if (!ctx) return;
    memset(ctx, 0, sizeof(client_ctx_t));

    uv_tcp_init(server->loop, &ctx->client);
    ctx->client.data = ctx;

    thread_args_t* targs = (thread_args_t*)server->data;
    if (targs) {
        ctx->router = targs->router;
    } else {
        ctx->router = global_router;
    }

    buf_init(&ctx->url);
    buf_init(&ctx->headers);
    buf_init(&ctx->body);
    ctx->header_state = HEADER_STATE_NONE;

    llhttp_settings_init(&ctx->settings);
    ctx->settings.on_message_begin = on_message_begin_c;
    ctx->settings.on_url = on_url_c;
    ctx->settings.on_header_field = on_header_field_c;
    ctx->settings.on_header_value = on_header_value_c;
    ctx->settings.on_headers_complete = on_headers_complete_c;
    ctx->settings.on_body = on_body_c;
    ctx->settings.on_message_complete = on_message_complete_c;

    llhttp_init(&ctx->parser, HTTP_REQUEST, &ctx->settings);
    ctx->parser.data = ctx;

    int fd;
    uv_fileno((uv_handle_t*)&ctx->client, &fd);
    int nodelay = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &nodelay, sizeof(nodelay));

    if (uv_accept(server, (uv_stream_t*)&ctx->client) == 0) {
        uv_read_start((uv_stream_t*)&ctx->client, alloc_buffer_c, on_read_c);
    } else {
        uv_close((uv_handle_t*)&ctx->client, on_close_c);
    }
}

static int create_server_socket(int port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        return -1;
    }

    int opt = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
    setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &opt, sizeof(opt));

    fcntl(fd, F_SETFL, O_NONBLOCK);

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = INADDR_ANY;
    addr.sin_port = htons(port);

    if (bind(fd, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
        close(fd);
        return -1;
    }

    if (listen(fd, 4096) < 0) {
        close(fd);
        return -1;
    }

    return fd;
}

static void* thread_main(void* arg) {
    thread_args_t* args = (thread_args_t*)arg;
    current_thread_id = args->thread_id;
    request_count = 0;

    int num_cpus = sysconf(_SC_NPROCESSORS_ONLN);
    int cpu_id = args->thread_id % num_cpus;
    cpu_set_t cpuset;
    CPU_ZERO(&cpuset);
    CPU_SET(cpu_id, &cpuset);
    pthread_setaffinity_np(pthread_self(), sizeof(cpu_set_t), &cpuset);

    int server_fd = create_server_socket(args->port);
    if (server_fd < 0) {
        free(args);
        return NULL;
    }

    uv_loop_t* loop = (uv_loop_t*)malloc(sizeof(uv_loop_t));
    uv_loop_init(loop);

    uv_tcp_t* server = (uv_tcp_t*)malloc(sizeof(uv_tcp_t));
    uv_tcp_init(loop, server);
    server->data = args;
    uv_tcp_open(server, server_fd);

    uv_listen((uv_stream_t*)server, 1024, on_connection_c);

    printf("[C] 🧵 Thread %d listening on CPU %d (port %d)\n",
           args->thread_id, cpu_id, args->port);

    uv_run(loop, UV_RUN_DEFAULT);

    close(server_fd);
    uv_loop_close(loop);
    free(loop);
    free(server);
    free(args);

    return NULL;
}

void pthread_create_wrapper(int port, void* router, int num_threads) {
    for (int i = 0; i < num_threads; i++) {
        pthread_t thread;
        thread_args_t* args = (thread_args_t*)malloc(sizeof(thread_args_t));
        if (!args) continue;
        args->port = port;
        args->router = router;
        args->thread_id = i;
        args->server_fd = -1;

        pthread_create(&thread, NULL, thread_main, args);
        pthread_detach(thread);
    }
    printf("[C] ✅ All %d threads created\n", num_threads);
}

void uv_tcp_init_wrapper(uv_loop_t* loop, uv_tcp_t* tcp) {
    uv_tcp_init(loop, tcp);
}

void uv_tcp_bind_wrapper(uv_tcp_t* tcp, const char* ip, int port) {
    int fd;
    uv_fileno((uv_handle_t*)tcp, &fd);
    int reuse = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));
    setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &reuse, sizeof(reuse));

    struct sockaddr_in addr;
    uv_ip4_addr(ip, port, &addr);
    uv_tcp_bind(tcp, (const struct sockaddr*)&addr, 0);
}

void uv_listen_wrapper(uv_tcp_t* tcp, int backlog) {
    uv_listen((uv_stream_t*)tcp, backlog, on_connection_c);
}

void uv_run_wrapper(uv_loop_t* loop) {
    if (loop) uv_run(loop, UV_RUN_DEFAULT);
}

void uv_read_start_wrapper(uv_tcp_t* client) {
    uv_read_start((uv_stream_t*)client, alloc_buffer_c, on_read_c);
}

void uv_read_stop_wrapper(uv_tcp_t* client) {
    uv_read_stop((uv_stream_t*)client);
}

void uv_write_wrapper(uv_tcp_t* client, const char* data, size_t len) {
    write_req_t* wr = (write_req_t*)malloc(sizeof(write_req_t));
    if (!wr) {
        if (!uv_is_closing((uv_handle_t*)client)) {
            uv_close((uv_handle_t*)client, on_close_c);
        }
        return;
    }
    wr->data = (char*)malloc(len);
    if (!wr->data) {
        free(wr);
        if (!uv_is_closing((uv_handle_t*)client)) {
            uv_close((uv_handle_t*)client, on_close_c);
        }
        return;
    }
    memcpy(wr->data, data, len);
    wr->len = len;
    wr->client = client;
    uv_buf_t buf = uv_buf_init(wr->data, (unsigned int)len);
    uv_write(&wr->req, (uv_stream_t*)client, &buf, 1, on_write_close_c);
}

void uv_close_wrapper(uv_tcp_t* client) {
    if (!uv_is_closing((uv_handle_t*)client)) {
        uv_close((uv_handle_t*)client, on_close_c);
    }
}

uv_loop_t* uv_loop_create_wrapper() {
    uv_loop_t* loop = (uv_loop_t*)malloc(sizeof(uv_loop_t));
    if (!loop) return NULL;
    uv_loop_init(loop);
    return loop;
}

void uv_loop_destroy_wrapper(uv_loop_t* loop) {
    if (!loop) return;
    if (uv_loop_alive(loop)) uv_loop_close(loop);
    free(loop);
}

void mojelly_free_response(char* ptr) {
    if (ptr) free(ptr);
}
