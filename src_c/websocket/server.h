#ifndef SERVER_H
#define SERVER_H

#include <stdint.h>
#include <pthread.h>
#include <uv.h>
#include "bridge.h"

// Define the possible states of the WebSocket server
typedef enum server_state_t{
    ST_INIT,
    ST_OPEN,
    ST_CLOSING,
    ST_CLOSED
} server_state_t;

// Structure to represent a write queue for outgoing WebSocket messages
typedef struct ws_write_queue_t {
    uint64_t connection_id;
    uint8_t* data;
    uint64_t length;
    int32_t kind;
    struct ws_write_queue_t* next;
} ws_write_queue_t;

// Server context structure to hold the state of the server and related information
typedef struct server_context {
    // Current state of the server (enum)
    server_state_t state;

    // Server configuration parameters
    // Maximum allowed message size for WebSocket messages
    uint64_t max_message_size;
    // WebSocket write queue to manage outgoing messages
    ws_write_queue_t* write_queue;
    // Mutex to protect access to the write queue
    pthread_mutex_t write_queue_mutex;
    // Timeouts
    uint64_t write_timeout_ms;
    uint64_t read_timeout_ms;
    uint64_t close_timeout_ms;
} server_context_t;

// Working flow of the server
typedef struct server_workflow {
    // libuv event loop and server handle
    uv_loop_t* loop;
    uv_tcp_t server;
    uv_async_t write_queue_async;
    server_context_t* context;

    // WebSocket bridge to handle communication between the server and application
    ws_bridge_t* bridge;
} server_workflow_t;

#endif // SERVER_H