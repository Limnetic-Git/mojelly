#ifndef WS_EVENTS_H
#define WS_EVENTS_H

#include <stdint.h>

enum {
    WS_TEXT = 1,
    WS_BINARY = 2
};

/* 

*/
typedef struct {
    void (*on_open)(void* context, uint64_t connection_id, uint64_t route_id);
    void (*on_message)(void* context, uint64_t connection_id,
                       const uint8_t* data, uint64_t length, int32_t kind);
    void (*on_close)(void* context, uint64_t connection_id, uint32_t code,
                     const uint8_t* reason, uint64_t reason_length);
    void (*on_error)(void* context, uint64_t connection_id, int32_t error,
                     const uint8_t* message, uint64_t message_length);
} ws_callbacks_t;

#endif
