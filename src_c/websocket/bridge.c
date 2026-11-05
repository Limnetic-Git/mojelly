#include "bridge.h"

#include <pthread.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

struct ws_bridge {
    pthread_t owner;
    void* transport_context;
    void* application_context;
    ws_transport_t transport;
    ws_callbacks_t callbacks;
    uint64_t max_message_size;
    size_t dispatch_depth;
    int stopped;
};

static int32_t check_bridge(const ws_bridge_t* bridge,
                            int require_running) {
    if (bridge == NULL) return WS_INVALID_ARGUMENT;
    if (!pthread_equal(bridge->owner, pthread_self())) {
        return WS_WRONG_THREAD;
    }
    if (require_running && bridge->stopped) return WS_STOPPED;
    return WS_OK;
}

// Check that the data pointer is valid for the given length, and that the length is not too large
static int32_t check_bytes(const uint8_t* data, uint64_t length) {
    if (data == NULL && length != 0) return WS_INVALID_ARGUMENT;
    if (length > SIZE_MAX) return WS_TOO_LARGE;
    return WS_OK;
}

// Check that the message parameters are valid for sending or receiving
static int32_t check_message(const ws_bridge_t* bridge,
                             uint64_t connection_id, const uint8_t* data,
                             uint64_t length, int32_t kind) {
    if (connection_id == 0 ||
        (kind != WS_TEXT && kind != WS_BINARY)) {
        return WS_INVALID_ARGUMENT;
    }
    int32_t status = check_bytes(data, length);
    if (status != WS_OK) return status;
    if (length > bridge->max_message_size) return WS_TOO_LARGE;
    return WS_OK;
}

// Copy the given data into a newly allocated buffer and return it through out_copy
static int32_t copy_bytes(const uint8_t* data, uint64_t length,
                          uint8_t** out_copy) {
    *out_copy = NULL;
    if (length == 0) return WS_OK;
    uint8_t* copy = malloc((size_t)length);
    if (copy == NULL) return WS_NO_MEMORY;
    memcpy(copy, data, (size_t)length);
    *out_copy = copy;
    return WS_OK;
}

// Create a new WebSocket bridge with the given transport and callbacks, and return it through out_bridge
int32_t ws_bridge_create(
    void* transport_context, const ws_transport_t* transport,
    void* application_context, const ws_callbacks_t* callbacks,
    uint64_t max_message_size, ws_bridge_t** out_bridge) {
    if (out_bridge == NULL) return WS_INVALID_ARGUMENT;
    *out_bridge = NULL;
    if (transport == NULL || transport->send == NULL ||
        transport->close == NULL || max_message_size == 0 ||
        max_message_size > SIZE_MAX) {
        return WS_INVALID_ARGUMENT;
    }
    ws_bridge_t* bridge = calloc(1, sizeof(*bridge));
    if (bridge == NULL) return WS_NO_MEMORY;
    bridge->owner = pthread_self();
    bridge->transport_context = transport_context;
    bridge->application_context = application_context;
    bridge->transport = *transport;
    if (callbacks != NULL) bridge->callbacks = *callbacks;
    bridge->max_message_size = max_message_size;
    *out_bridge = bridge;
    return WS_OK;
}

int32_t ws_bridge_stop(ws_bridge_t* bridge) {
    int32_t status = check_bridge(bridge, 0);
    if (status != WS_OK) return status;
    bridge->stopped = 1;
    return WS_OK;
}

int32_t ws_bridge_destroy(ws_bridge_t* bridge) {
    int32_t status = check_bridge(bridge, 0);
    if (status != WS_OK) return status;
    if (!bridge->stopped || bridge->dispatch_depth != 0) {
        return WS_BUSY;
    }
    free(bridge);
    return WS_OK;
}

int32_t ws_send(ws_bridge_t* bridge, uint64_t connection_id,
                       const uint8_t* data, uint64_t length, int32_t kind) {
    int32_t status = check_bridge(bridge, 1);
    if (status != WS_OK) return status;
    status = check_message(bridge, connection_id, data, length, kind);
    if (status != WS_OK) return status;
    uint8_t* copy;
    status = copy_bytes(data, length, &copy);
    if (status != WS_OK) return status;

    /* Транспорт тоже может синхронно вызвать события, поэтому защищаем
     * мост от уничтожения на всё время внешнего вызова. */
    bridge->dispatch_depth++;
    status = bridge->transport.send(bridge->transport_context, connection_id,
                                    copy, length, kind);
    bridge->dispatch_depth--;
    if (status != WS_OK) free(copy);
    return status;
}

int32_t ws_close(ws_bridge_t* bridge, uint64_t connection_id,
                        uint32_t code, const uint8_t* reason,
                        uint64_t reason_length) {
    int32_t status = check_bridge(bridge, 1);
    if (status != WS_OK) return status;
    if (connection_id == 0 || code > UINT16_MAX) {
        return WS_INVALID_ARGUMENT;
    }
    status = check_bytes(reason, reason_length);
    if (status != WS_OK) return status;
    /* В управляющем кадре до 125 байт, из них два занимает код закрытия. */
    if (reason_length > 123) return WS_TOO_LARGE;
    uint8_t* copy;
    status = copy_bytes(reason, reason_length, &copy);
    if (status != WS_OK) return status;
    bridge->dispatch_depth++;
    status = bridge->transport.close(bridge->transport_context, connection_id,
                                     code, copy, reason_length);
    bridge->dispatch_depth--;
    if (status != WS_OK) free(copy);
    return status;
}

int32_t ws_emit_open(ws_bridge_t* bridge,
                            uint64_t connection_id, uint64_t route_id) {
    int32_t status = check_bridge(bridge, 1);
    if (status != WS_OK) return status;
    if (connection_id == 0) return WS_INVALID_ARGUMENT;
    if (bridge->callbacks.on_open != NULL) {
        bridge->dispatch_depth++;
        bridge->callbacks.on_open(bridge->application_context, connection_id,
                                  route_id);
        bridge->dispatch_depth--;
    }
    return WS_OK;
}

int32_t ws_emit_message(ws_bridge_t* bridge,
                               uint64_t connection_id, const uint8_t* data,
                               uint64_t length, int32_t kind) {
    int32_t status = check_bridge(bridge, 1);
    if (status != WS_OK) return status;
    status = check_message(bridge, connection_id, data, length, kind);
    if (status != WS_OK) return status;
    if (bridge->callbacks.on_message != NULL) {
        bridge->dispatch_depth++;
        bridge->callbacks.on_message(bridge->application_context, connection_id,
                                     data, length, kind);
        bridge->dispatch_depth--;
    }
    return WS_OK;
}

int32_t ws_emit_close(ws_bridge_t* bridge,
                             uint64_t connection_id, uint32_t code,
                             const uint8_t* reason, uint64_t reason_length) {
    int32_t status = check_bridge(bridge, 0);
    if (status != WS_OK) return status;
    if (connection_id == 0) return WS_INVALID_ARGUMENT;
    status = check_bytes(reason, reason_length);
    if (status != WS_OK) return status;
    if (bridge->callbacks.on_close != NULL) {
        bridge->dispatch_depth++;
        bridge->callbacks.on_close(bridge->application_context, connection_id,
                                   code, reason, reason_length);
        bridge->dispatch_depth--;
    }
    return WS_OK;
}

int32_t ws_emit_error(ws_bridge_t* bridge,
                             uint64_t connection_id, int32_t error,
                             const uint8_t* message, uint64_t message_length) {
    int32_t status = check_bridge(bridge, 0);
    if (status != WS_OK) return status;
    if (connection_id == 0) return WS_INVALID_ARGUMENT;
    status = check_bytes(message, message_length);
    if (status != WS_OK) return status;
    if (bridge->callbacks.on_error != NULL) {
        bridge->dispatch_depth++;
        bridge->callbacks.on_error(bridge->application_context, connection_id,
                                   error, message, message_length);
        bridge->dispatch_depth--;
    }
    return WS_OK;
}
