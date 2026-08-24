#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <stdlib.h>
#include <errno.h>
#include <stdint.h>

void* shm_create(const char* name, size_t size) {
    int fd = shm_open(name, O_CREAT | O_RDWR, 0666);
    if (fd == -1) {
        return NULL;
    }

    if (ftruncate(fd, size) == -1) {
        close(fd);
        return NULL;
    }

    void* ptr = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);

    if (ptr == MAP_FAILED) {
        return NULL;
    }

    return ptr;
}

void shm_destroy(void* ptr, size_t size) {
    if (ptr) {
        munmap(ptr, size);
    }
}

void shm_remove(const char* name) {
    shm_unlink(name);
}

#include <linux/futex.h>
#include <sys/syscall.h>

void futex_wait(uint32_t* addr, uint32_t val) {
    syscall(SYS_futex, addr, FUTEX_WAIT_PRIVATE, val, NULL, NULL, 0);
}

void futex_wake(uint32_t* addr) {
    syscall(SYS_futex, addr, FUTEX_WAKE_PRIVATE, 1, NULL, NULL, 0);
}

#define RING_BUFFER_SIZE (1024 * 1024)  //1MB

typedef struct {
    uint32_t head;
    uint32_t tail;
    uint32_t status;
    uint32_t request_len;
    uint32_t response_len;
    char data[RING_BUFFER_SIZE];
} ring_buffer_t;

void ring_buffer_init(ring_buffer_t* rb) {
    rb->head = 0;
    rb->tail = 0;
    rb->status = 0;
    rb->request_len = 0;
    rb->response_len = 0;
    memset(rb->data, 0, RING_BUFFER_SIZE);
}

int ring_buffer_write_request(ring_buffer_t* rb, const char* data, size_t len) {
    if (len > RING_BUFFER_SIZE) {
        return -1;
    }

    while (rb->status != 0) {
        futex_wait(&rb->status, 1);
    }

    memcpy(rb->data, data, len);
    rb->request_len = len;
    rb->status = 1;
    futex_wake(&rb->status);

    return 0;
}

int ring_buffer_read_request(ring_buffer_t* rb, char* buffer, size_t* len) {
    while (rb->status != 1) {
        futex_wait(&rb->status, 0);
    }

    *len = rb->request_len;
    memcpy(buffer, rb->data, *len);

    return 0;
}

int ring_buffer_write_response(ring_buffer_t* rb, const char* data, size_t len) {
    if (len > RING_BUFFER_SIZE) {
        return -1;
    }

    memcpy(rb->data, data, len);
    rb->response_len = len;
    rb->status = 2;
    futex_wake(&rb->status);

    return 0;
}

int ring_buffer_read_response(ring_buffer_t* rb, char* buffer, size_t* len) {
    while (rb->status != 2) {
        futex_wait(&rb->status, 1);
    }

    *len = rb->response_len;
    memcpy(buffer, rb->data, *len);
    rb->status = 0;
    futex_wake(&rb->status);

    return 0;
}
