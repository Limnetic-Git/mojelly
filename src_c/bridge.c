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
#include <errno.h> // wip

#define LOG_LEVEL 1
//0 - Errors only (recommended for best performance)
//1 - Requests logs (recommended for default use)
//2 - All logs (use for debug only)

#define LOG_COLORS 1
// 0 - u are boring, but little bit faster
// 1 - u are cool =)

static void on_close_c(uv_handle_t* handle);

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

#if LOG_LEVEL >= 0
#define LOG_ERROR(fmt, ...)   fprintf(stderr, "[ERROR] " fmt "\n", ##__VA_ARGS__)
#else
#define LOG_ERROR(fmt, ...)
#endif

#if LOG_LEVEL >= 1
#define LOG_REQUEST(fmt, ...) printf("[REQ] " fmt "\n", ##__VA_ARGS__)
#else
#define LOG_REQUEST(fmt, ...)
#endif

#if LOG_LEVEL >= 2
#define LOG_DEBUG(fmt, ...)   printf("[DBG] " fmt "\n", ##__VA_ARGS__)
#else
#define LOG_DEBUG(fmt, ...)
#endif

static __thread int current_thread_id = -1;
static __thread unsigned long request_count = 0;

extern char* mojo_handler(void* router, const char* url, const char* method, const char* body);

static void* global_router = NULL;

void mojelly_set_router(void* router) {
    global_router = router;
}

typedef struct {
    uv_write_t req;
    char* data;
    size_t len;
    uv_tcp_t* client;
} write_req_t;

typedef struct {
    llhttp_t parser;
    llhttp_settings_t settings;
    char* url;
    char* method;
    char* body;
    size_t body_len;
    int headers_complete;
    int status_code;
} http_parser_t;

typedef struct {
    int port;
    void* router;
    int thread_id;
    int server_fd;
} thread_args_t;

static const char* http_500 = "HTTP/1.1 500 Internal Server Error\r\n\r\n";

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
    buf->base = (char*)malloc(suggested_size);
    buf->len = suggested_size;
}

static void on_close_c(uv_handle_t* handle) {
    free(handle);
}

static void on_write_c(uv_write_t* req, int status) {
    write_req_t* wr = (write_req_t*)req;
    if (wr->data != NULL) free(wr->data);
    if (wr->client != NULL) uv_close((uv_handle_t*)wr->client, on_close_c);
    free(wr);
}

static inline void send_response(uv_tcp_t* client, const char* response) {
    if (response == NULL) response = http_500;

    size_t len = strlen(response);
    write_req_t* wr = (write_req_t*)malloc(sizeof(write_req_t));
    if (!wr) { uv_close((uv_handle_t*)client, on_close_c); return; }

    wr->data = (char*)malloc(len + 1);
    if (!wr->data) { free(wr); uv_close((uv_handle_t*)client, on_close_c); return; }

    memcpy(wr->data, response, len + 1);
    wr->len = len;
    wr->client = client;

    uv_buf_t buf = uv_buf_init(wr->data, len);
    uv_write(&wr->req, (uv_stream_t*)client, &buf, 1, on_write_c);
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

static int on_url_c(llhttp_t* parser, const char* at, size_t length) {
    http_parser_t* http = (http_parser_t*)parser->data;
    if (http->url != NULL) free(http->url);
    http->url = (char*)malloc(length + 1);
    if (!http->url) return -1;
    memcpy(http->url, at, length);
    http->url[length] = '\0';
    return 0;
}

static int on_body_c(llhttp_t* parser, const char* at, size_t length) {
    http_parser_t* http = (http_parser_t*)parser->data;
    if (http->body != NULL) free(http->body);
    http->body = (char*)malloc(length + 1);
    if (!http->body) return -1;
    memcpy(http->body, at, length);
    http->body[length] = '\0';
    http->body_len = length;
    return 0;
}

static int on_headers_complete_c(llhttp_t* parser) {
    http_parser_t* http = (http_parser_t*)parser->data;
    http->headers_complete = 1;
    http->status_code = parser->status_code;
    return 0;
}

static inline void handle_request(uv_tcp_t* client, const char* data, size_t len) {
    if (global_router == NULL) {
        send_response(client, http_500);
        return;
    }

    request_count++;

    http_parser_t* http = (http_parser_t*)malloc(sizeof(http_parser_t));
    if (!http) { send_response(client, http_500); return; }
    memset(http, 0, sizeof(http_parser_t));

    llhttp_settings_init(&http->settings);
    http->settings.on_url = on_url_c;
    http->settings.on_headers_complete = on_headers_complete_c;
    http->settings.on_body = on_body_c;

    llhttp_init(&http->parser, HTTP_REQUEST, &http->settings);
    http->parser.data = http;

    llhttp_execute(&http->parser, data, len);

    const char* method = llhttp_method_name(http->parser.method);
    const char* url = http->url ? http->url : "";
    const char* body = http->body ? http->body : "";

    struct timespec start, end;
    clock_gettime(CLOCK_MONOTONIC, &start);

    char* response = mojo_handler(global_router, url, method, body);

    clock_gettime(CLOCK_MONOTONIC, &end);
    double duration_ms = (end.tv_sec - start.tv_sec) * 1000.0 +
    (end.tv_nsec - start.tv_nsec) / 1000000.0;

    int status = 500;
    if (response != NULL) {
        status = extract_status_from_response(response);
    }

    send_response(client, response ? response : http_500);

    if (response != NULL) free(response);

    log_request(method, url, status, duration_ms);

    if (http->url != NULL) free(http->url);
    if (http->body != NULL) free(http->body);
    free(http);
}

static void on_read_c(uv_stream_t* client, ssize_t nread, const uv_buf_t* buf) {
    if (nread > 0) {
        handle_request((uv_tcp_t*)client, buf->base, nread);
    } else if (nread < 0) {
        uv_close((uv_handle_t*)client, on_close_c);
    }
    if (buf->base != NULL) free(buf->base);
}

static void on_connection_c(uv_stream_t* server, int status) {
    uv_tcp_t* client = (uv_tcp_t*)malloc(sizeof(uv_tcp_t));
    if (!client) return;

    uv_tcp_init(server->loop, client);
    if (uv_accept(server, (uv_stream_t*)client) == 0) {
        uv_read_start((uv_stream_t*)client, alloc_buffer_c, on_read_c);
    } else {
        uv_close((uv_handle_t*)client, NULL);
        free(client);
    }
}

static int create_server_socket(int port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        perror("socket");
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
        perror("bind");
        close(fd);
        return -1;
    }

    if (listen(fd, 1024) < 0) {
        perror("listen");
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
    LOG_DEBUG("pthread_create_wrapper: port=%d, num_threads=%d", port, num_threads);

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
    if (!wr) { uv_close((uv_handle_t*)client, on_close_c); return; }
    wr->data = (char*)malloc(len);
    if (!wr->data) { free(wr); uv_close((uv_handle_t*)client, on_close_c); return; }
    memcpy(wr->data, data, len);
    wr->len = len;
    wr->client = client;
    uv_buf_t buf = uv_buf_init(wr->data, len);
    uv_write(&wr->req, (uv_stream_t*)client, &buf, 1, on_write_c);
}

void uv_close_wrapper(uv_tcp_t* client) {
    uv_close((uv_handle_t*)client, on_close_c);
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
