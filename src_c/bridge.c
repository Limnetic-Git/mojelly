// src_c/bridge.c — ядро Mojelly

#include <uv.h>
#include <llhttp.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

extern char* mojo_handler(void* router, const char* url, const char* method, const char* body);

static void* global_router = NULL;

void mojelly_set_router(void* router) {
    global_router = router;
    printf("[C] Router set to %p\n", router);
}

typedef struct {
    uv_write_t req;
    char* data;
    size_t len;
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

static void alloc_buffer_c(uv_handle_t* handle, size_t suggested_size, uv_buf_t* buf) {
    buf->base = (char*)malloc(suggested_size);
    buf->len = suggested_size;
}

static void on_write_c(uv_write_t* req, int status) {
    write_req_t* wr = (write_req_t*)req;
    if (wr->data != NULL) free(wr->data);
    free(wr);
}

static void on_close_c(uv_handle_t* handle) {
    free(handle);
}

static void send_response(uv_tcp_t* client, const char* response) {
    if (response == NULL) {
        response = "HTTP/1.1 500 Internal Server Error\r\n\r\n";
    }

    size_t len = strlen(response);
    write_req_t* wr = (write_req_t*)malloc(sizeof(write_req_t));
    wr->data = (char*)malloc(len + 1);
    memcpy(wr->data, response, len + 1);

    uv_buf_t buf = uv_buf_init(wr->data, len);
    uv_write(&wr->req, (uv_stream_t*)client, &buf, 1, on_write_c);
    uv_close((uv_handle_t*)client, on_close_c);
}

static int on_url_c(llhttp_t* parser, const char* at, size_t length) {
    http_parser_t* http = (http_parser_t*)parser->data;
    if (http->url != NULL) free(http->url);
    http->url = (char*)malloc(length + 1);
    memcpy(http->url, at, length);
    http->url[length] = '\0';
    return 0;
}

static int on_body_c(llhttp_t* parser, const char* at, size_t length) {
    http_parser_t* http = (http_parser_t*)parser->data;
    if (http->body != NULL) free(http->body);
    http->body = (char*)malloc(length + 1);
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

static void handle_request(uv_tcp_t* client, const char* data, size_t len) {
    http_parser_t* http = (http_parser_t*)malloc(sizeof(http_parser_t));
    memset(http, 0, sizeof(http_parser_t));

    llhttp_settings_init(&http->settings);
    http->settings.on_url = on_url_c;
    http->settings.on_headers_complete = on_headers_complete_c;
    http->settings.on_body = on_body_c;

    llhttp_init(&http->parser, HTTP_REQUEST, &http->settings);
    http->parser.data = http;
    llhttp_execute(&http->parser, data, len);
    char* response = mojo_handler(
        global_router,
        http->url ? http->url : "",
        llhttp_method_name(http->parser.method),
                                  http->body ? http->body : ""
    );

    send_response(client, response ? response : "HTTP/1.1 500 Internal Server Error\r\n\r\n");

    //if (response != NULL) free(response);
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
    if (buf->base != NULL) {
        free(buf->base);
    }
}

static void on_connection_c(uv_stream_t* server, int status) {
    printf("[C] on_connection_c: server=%p, status=%d\n", (void*)server, status);
    uv_tcp_t* client = (uv_tcp_t*)malloc(sizeof(uv_tcp_t));
    uv_tcp_init(server->loop, client);
    if (uv_accept(server, (uv_stream_t*)client) == 0) {
        uv_read_start((uv_stream_t*)client, alloc_buffer_c, on_read_c);
    } else {
        uv_close((uv_handle_t*)client, NULL);
        free(client);
    }
}

void uv_tcp_init_wrapper(uv_loop_t* loop, uv_tcp_t* tcp) {
    uv_tcp_init(loop, tcp);
}

void uv_tcp_bind_wrapper(uv_tcp_t* tcp, const char* ip, int port) {
    struct sockaddr_in addr;
    uv_ip4_addr(ip, port, &addr);
    uv_tcp_bind(tcp, (const struct sockaddr*)&addr, 0);
}

void uv_listen_wrapper(uv_tcp_t* tcp, int backlog) {
    uv_listen((uv_stream_t*)tcp, backlog, on_connection_c);
}

void uv_run_wrapper(uv_loop_t* loop) {
    if (loop == NULL) {
        printf("[C] ERROR: loop is NULL!\n");
        return;
    }
    printf("[C] uv_run_wrapper: loop=%p starting...\n", (void*)loop);
    int result = uv_run(loop, UV_RUN_DEFAULT);
    printf("[C] uv_run finished with result: %d\n", result);
}

void uv_read_start_wrapper(uv_tcp_t* client) {
    uv_read_start((uv_stream_t*)client, alloc_buffer_c, on_read_c);
}

void uv_read_stop_wrapper(uv_tcp_t* client) {
    uv_read_stop((uv_stream_t*)client);
}

void uv_write_wrapper(uv_tcp_t* client, const char* data, size_t len) {
    write_req_t* wr = (write_req_t*)malloc(sizeof(write_req_t));
    wr->data = (char*)malloc(len);
    memcpy(wr->data, data, len);
    wr->len = len;
    uv_buf_t buf = uv_buf_init(wr->data, len);
    uv_write(&wr->req, (uv_stream_t*)client, &buf, 1, on_write_c);
}

void uv_close_wrapper(uv_tcp_t* client) {
    uv_close((uv_handle_t*)client, on_close_c);
}

uv_loop_t* uv_loop_create_wrapper() {
    uv_loop_t* loop = (uv_loop_t*)malloc(sizeof(uv_loop_t));
    if (loop == NULL) {
        printf("[C] ERROR: malloc failed for loop\n");
        return NULL;
    }
    int ret = uv_loop_init(loop);
    printf("[C] uv_loop_create_wrapper: loop=%p, init_ret=%d\n", (void*)loop, ret);
    return loop;
}

void uv_loop_destroy_wrapper(uv_loop_t* loop) {
    if (loop == NULL) return;
    printf("[C] uv_loop_destroy_wrapper: loop=%p\n", (void*)loop);
    if (uv_loop_alive(loop)) {
        uv_loop_close(loop);
    } else {
        printf("[C] loop not alive, skipping close\n");
    }
    free(loop);
}
