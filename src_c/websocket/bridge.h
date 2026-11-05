#ifndef WS_BRIDGE_H
#define WS_BRIDGE_H

#include <stdint.h>

#include "events.h"

typedef struct ws_bridge ws_bridge_t;

enum {
    WS_OK = 0,
    WS_INVALID_ARGUMENT = -1,
    WS_NO_MEMORY = -2,
    WS_NOT_FOUND = -3,
    WS_CLOSING = -4,
    WS_TOO_LARGE = -5,
    WS_BACKPRESSURE = -6,
    WS_WRONG_THREAD = -7,
    WS_STOPPED = -8,
    WS_BUSY = -9
};

/* При успехе транспорт получает владение буфером и обязан освободить его
 * через free(), когда данные больше не нужны. При ошибке буфер освобождает
 * мост; транспорт не должен сохранять его. Пустые данные представлены NULL.
 * Транспорт проверяет существование соединения, его состояние, очередь,
 * коды закрытия и UTF-8. Успех означает принятие команды, а не доставку.
 * После принятия данных функция обязана вернуть WS_OK. */
typedef struct {
    int32_t (*send)(void* context, uint64_t connection_id, uint8_t* data,
                    uint64_t length, int32_t kind);
    int32_t (*close)(void* context, uint64_t connection_id, uint32_t code,
                     uint8_t* reason, uint64_t reason_length);
} ws_transport_t;

/* Создание привязывает мост к текущему потоку. Таблицы функций копируются;
 * контексты заимствованы и должны жить до уничтожения моста. Обе операции
 * транспорта обязательны; callbacks может быть NULL. Лимит должен быть > 0.
 * Параллельное использование и уничтожение моста не поддерживаются. */
int32_t ws_bridge_create(
    void* transport_context, const ws_transport_t* transport,
    void* application_context, const ws_callbacks_t* callbacks,
    uint64_t max_message_size, ws_bridge_t** out_bridge);

/* Запрещает новые команды и события открытия/сообщений; события закрытия
 * и ошибок остаются доступны. Сам сервер эта функция не останавливает. */
int32_t ws_bridge_stop(ws_bridge_t* bridge);

/* Вызывать после stop и полного завершения работы транспорта. Незавершённые
 * записи и будущие вызовы событий должны отсутствовать. Из обработчика
 * уничтожение запрещено. При успехе указатель моста становится недействителен. */
int32_t ws_bridge_destroy(ws_bridge_t* bridge);

/* Исходные данные копируются до передачи транспорту. После возврата ими
 * можно распоряжаться независимо от результата операции. Идентификатор 0
 * зарезервирован; повторное использование идентификаторов контролирует ядро. */
int32_t ws_send(ws_bridge_t* bridge, uint64_t connection_id,
                       const uint8_t* data, uint64_t length, int32_t kind);
int32_t ws_close(ws_bridge_t* bridge, uint64_t connection_id,
                        uint32_t code, const uint8_t* reason,
                        uint64_t reason_length);

/* Внутренние входы для ядра. Оно передаёт проверенные полные сообщения,
 * сохраняет порядок событий и вызывает закрытие ровно один раз после
 * завершения работы соединения. События доставляются синхронно. Обработчик
 * может вызвать send, close или stop, но не destroy. */
int32_t ws_emit_open(ws_bridge_t* bridge,
                            uint64_t connection_id, uint64_t route_id);
int32_t ws_emit_message(ws_bridge_t* bridge,
                               uint64_t connection_id, const uint8_t* data,
                               uint64_t length, int32_t kind);
int32_t ws_emit_close(ws_bridge_t* bridge,
                             uint64_t connection_id, uint32_t code,
                             const uint8_t* reason, uint64_t reason_length);
int32_t ws_emit_error(ws_bridge_t* bridge,
                             uint64_t connection_id, int32_t error,
                             const uint8_t* message, uint64_t message_length);

#endif
