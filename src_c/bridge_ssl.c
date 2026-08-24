#include <openssl/ssl.h>
#include <openssl/err.h>
#include <openssl/opensslv.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    SSL_CTX* ctx;
    SSL* ssl;
} ssl_connection_t;

SSL_CTX* ssl_ctx_create(const char* cert_path, const char* key_path) {
    SSL_library_init();
    SSL_load_error_strings();
    OpenSSL_add_all_algorithms();
    SSL_CTX* ctx = SSL_CTX_new(TLS_server_method());
    if (!ctx) {
        return NULL;
    }
    SSL_CTX_set_ecdh_auto(ctx, 1);
    SSL_CTX_set_min_proto_version(ctx, TLS1_2_VERSION);

    if (SSL_CTX_use_certificate_file(ctx, cert_path, SSL_FILETYPE_PEM) <= 0) {
        SSL_CTX_free(ctx);
        return NULL;
    }

    if (SSL_CTX_use_PrivateKey_file(ctx, key_path, SSL_FILETYPE_PEM) <= 0) {
        SSL_CTX_free(ctx);
        return NULL;
    }

    if (!SSL_CTX_check_private_key(ctx)) {
        SSL_CTX_free(ctx);
        return NULL;
    }

    return ctx;
}

SSL* ssl_create(SSL_CTX* ctx, int fd) {
    SSL* ssl = SSL_new(ctx);
    if (!ssl) {
        return NULL;
    }
    SSL_set_fd(ssl, fd);
    SSL_set_accept_state(ssl);
    return ssl;
}

int ssl_accept_wrapper(SSL* ssl) {
    return SSL_accept(ssl);
}

int ssl_read_wrapper(SSL* ssl, char* buf, int len) {
    return SSL_read(ssl, buf, len);
}

int ssl_write_wrapper(SSL* ssl, const char* buf, int len) {
    return SSL_write(ssl, buf, len);
}

int ssl_pending(SSL* ssl) {
    return SSL_pending(ssl);
}

void ssl_free(SSL* ssl) {
    if (ssl) {
        SSL_shutdown(ssl);
        SSL_free(ssl);
    }
}

void ssl_ctx_free(SSL_CTX* ctx) {
    if (ctx) {
        SSL_CTX_free(ctx);
    }
}

int generate_self_signed_cert(const char* cert_path, const char* key_path) {
    char cmd[512];
    snprintf(cmd, sizeof(cmd),
             "openssl req -x509 -newkey rsa:2048 -keyout %s -out %s -days 365 -nodes "
             "-subj '/CN=localhost' 2>/dev/null",
             key_path, cert_path
    );
    return system(cmd);
}

const char* ssl_last_error() {
    return ERR_reason_error_string(ERR_get_error());
}
