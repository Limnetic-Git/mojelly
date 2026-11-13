/* Based on node-formidable by Felix Geisendörfer
 * Igor Afonov - afonov@gmail.com - 2012
 * MIT License - http://www.opensource.org/licenses/mit-license.php
 */

#include "multipart_parser.h"

#include <stdio.h>
#include <stdarg.h>
#include <string.h>

static void multipart_log(const char * format, ...)
{
#ifdef DEBUG_MULTIPART
    va_list args;
    va_start(args, format);

    fprintf(stderr, "[HTTP_MULTIPART_PARSER] %s:%d: ", __FILE__, __LINE__);
    vfprintf(stderr, format, args);
    fprintf(stderr, "\n");
    va_end(args);
#endif
}

#define NOTIFY_CB(FOR)                                                 \
do {                                                                   \
  if (p->settings->on_##FOR) {                                         \
    if (p->settings->on_##FOR(p) != 0) {                               \
      p->error = MPPE_PAUSED;                                          \
      return i;                                                        \
    }                                                                  \
  }                                                                    \
} while (0)

#define EMIT_DATA_CB(FOR, ptr, len)                                    \
do {                                                                   \
  if (p->settings->on_##FOR) {                                         \
    if (p->settings->buffer_size > 0 && p->FOR##_buffer) {             \
      if (buffer_or_emit(p, p->settings->on_##FOR,                     \
                         &p->FOR##_buffer, &p->FOR##_buffer_len,       \
                         ptr, len) != 0) {                             \
        return i;                                                      \
      }                                                                \
    } else {                                                           \
      if (p->settings->on_##FOR(p, ptr, len) != 0) {                   \
        p->error = MPPE_PAUSED;                                        \
        return i;                                                      \
      }                                                                \
    }                                                                  \
  }                                                                    \
} while (0)


#define LF 10
#define CR 13

struct multipart_parser {
  void * data;

  size_t index;
  size_t boundary_length;

  unsigned char state;
  multipart_parser_error error;  /* Last error code */

  const multipart_parser_settings* settings;

  /* Buffering support for data callbacks */
  char* header_field_buffer;
  size_t header_field_buffer_len;
  char* header_value_buffer;
  size_t header_value_buffer_len;
  char* part_data_buffer;
  size_t part_data_buffer_len;

  char* lookbehind;
  char multipart_boundary[1];
};

enum state {
  s_uninitialized = 1,
  s_start,
  s_start_boundary,
  s_start_boundary_hyphen2,
  s_header_field_start,
  s_header_field,
  s_headers_almost_done,
  s_header_value,              /* Optimized: removed s_header_value_start state */
  s_header_value_almost_done,
  s_part_data_start,
  s_part_data,
  s_part_data_almost_boundary,
  s_part_data_boundary,
  s_part_data_boundary_hyphen2,
  s_part_data_almost_end,
  s_part_data_end,
  s_part_data_final_hyphen,
  s_end
};

multipart_parser* multipart_parser_init
    (const char *boundary, const multipart_parser_settings* settings) {
  size_t buffer_size;
  multipart_parser* p;

  buffer_size = (settings && settings->buffer_size > 0) ? settings->buffer_size : 0;

  p = malloc(sizeof(multipart_parser) +
             strlen(boundary) +
             strlen(boundary) + 9 +
             (buffer_size > 0 ? (buffer_size * 3) : 0));  /* 3 buffers if buffering enabled */

  if (p == NULL) {
    return NULL;
  }

  strcpy(p->multipart_boundary, boundary);
  p->boundary_length = strlen(boundary);

  p->lookbehind = (p->multipart_boundary + p->boundary_length + 1);

  /* Initialize buffer pointers */
  if (buffer_size > 0) {
    p->header_field_buffer = p->lookbehind + p->boundary_length + 8;
    p->header_value_buffer = p->header_field_buffer + buffer_size;
    p->part_data_buffer = p->header_value_buffer + buffer_size;
  } else {
    p->header_field_buffer = NULL;
    p->header_value_buffer = NULL;
    p->part_data_buffer = NULL;
  }

  p->header_field_buffer_len = 0;
  p->header_value_buffer_len = 0;
  p->part_data_buffer_len = 0;

  p->index = 0;
  p->state = s_start;
  p->settings = settings;
  p->error = MPPE_OK;  /* Initialize error state */

  return p;
}

/* Helper function to flush buffered data */
static int flush_buffer(multipart_parser* p, multipart_data_cb callback,
                        char** buffer, size_t* buffer_len) {
  int result = 0;
  if (*buffer_len > 0 && callback) {
    result = callback(p, *buffer, *buffer_len);
    *buffer_len = 0;
  }
  return result;
}

/* Helper function to append data to buffer or emit immediately */
static int buffer_or_emit(multipart_parser* p, multipart_data_cb callback,
                          char** buffer, size_t* buffer_len,
                          const char* data, size_t len) {
  size_t buffer_size = p->settings->buffer_size;

  /* If buffering disabled or no buffer, emit immediately */
  if (buffer_size == 0 || *buffer == NULL) {
    if (callback && callback(p, data, len) != 0) {
      p->error = MPPE_PAUSED;
      return 1;
    }
    return 0;
  }

  /* Try to buffer the data */
  if (*buffer_len + len <= buffer_size) {
    /* Fits in buffer */
    memcpy(*buffer + *buffer_len, data, len);
    *buffer_len += len;
    return 0;
  }

  /* Buffer would overflow - flush current buffer and handle new data */
  if (*buffer_len > 0) {
    if (callback && callback(p, *buffer, *buffer_len) != 0) {
      p->error = MPPE_PAUSED;
      return 1;
    }
    *buffer_len = 0;
  }

  /* If new data fits in empty buffer, buffer it */
  if (len <= buffer_size) {
    memcpy(*buffer, data, len);
    *buffer_len = len;
    return 0;
  }

  /* Data too large for buffer, emit directly */
  if (callback && callback(p, data, len) != 0) {
    p->error = MPPE_PAUSED;
    return 1;
  }
  return 0;
}

void multipart_parser_free(multipart_parser* p) {
  /* Note: free(NULL) is safe per C standard */
  free(p);
}

void multipart_parser_set_data(multipart_parser *p, void *data) {
    if (p != NULL) {
        p->data = data;
    }
}

void *multipart_parser_get_data(multipart_parser *p) {
    if (p == NULL) {
        return NULL;
    }
    return p->data;
}

multipart_parser_error multipart_parser_get_error(multipart_parser* p) {
    if (p == NULL) {
        return MPPE_UNKNOWN;
    }
    return p->error;
}

const char* multipart_parser_get_error_message(multipart_parser* p) {
    if (p == NULL) {
        return "Invalid parser pointer";
    }
    switch (p->error) {
        case MPPE_OK:
            return "No error";
        case MPPE_PAUSED:
            return "Parsing paused by callback";
        case MPPE_INVALID_BOUNDARY:
            return "Invalid boundary format";
        case MPPE_INVALID_HEADER_FIELD:
            return "Invalid character in header field name";
        case MPPE_INVALID_HEADER_FORMAT:
            return "Invalid header format";
        case MPPE_INVALID_STATE:
            return "Parser in invalid state";
        case MPPE_UNKNOWN:
        default:
            return "Unknown error";
    }
}

int multipart_parser_reset(multipart_parser* p, const char *boundary) {
    size_t new_boundary_length;

    /* Validate parser pointer */
    if (p == NULL) {
        return -1;
    }

    if (boundary != NULL) {
        new_boundary_length = strlen(boundary);

        /* Check if new boundary fits in allocated space
         * The original allocation has space for the boundary plus lookbehind (boundary_length + 8)
         * So we can accept any boundary up to and including the original length */
        if (new_boundary_length > p->boundary_length) {
            return -1;
        }

        /* Update boundary */
        strcpy(p->multipart_boundary, boundary);
        p->boundary_length = new_boundary_length;
    }

    /* Reset parser state */
    p->index = 0;
    p->state = s_start;
    p->error = MPPE_OK;

    /* Clear buffer lengths (but keep buffer pointers) */
    p->header_field_buffer_len = 0;
    p->header_value_buffer_len = 0;
    p->part_data_buffer_len = 0;

    /* Note: settings and data pointer are preserved */

    return 0;
}

size_t multipart_parser_execute(multipart_parser* p, const char *buf, size_t len) {
  size_t i = 0;
  size_t mark = 0;
  char c, cl;
  int is_last = 0;

  /* Safety check: Validate parser pointer */
  if (p == NULL) {
    return 0;
  }

  /* Safety check: Validate buffer pointer if len > 0 */
  if (len > 0 && buf == NULL) {
    p->error = MPPE_INVALID_STATE;
    return 0;
  }

  /* Reset error state at start of parsing */
  p->error = MPPE_OK;

  while(i < len) {
    c = buf[i];
    is_last = (i == (len - 1));
    switch (p->state) {
      case s_start:
        multipart_log("s_start");
        p->index = 0;
        p->state = s_start_boundary;

      /* fallthrough */
      case s_start_boundary:
        multipart_log("s_start_boundary");
        /* RFC 2046: Skip preamble and find first boundary starting with -- */
        if (p->index == 0) {
          if (c != '-') {
            /* Skip preamble - keep looking for '-' */
            break;
          }
          p->index++;
          break;
        } else if (p->index == 1) {
          if (c != '-') {
            /* Not a boundary, reset and continue looking */
            p->index = 0;
            if (c == '-') {
              p->index = 1;
            }
            break;
          }
          p->index++;
          p->state = s_start_boundary_hyphen2;
          break;
        }
        /* Should not reach here */
        p->error = MPPE_INVALID_STATE;
        return i;

      case s_start_boundary_hyphen2:
        multipart_log("s_start_boundary_hyphen2");
        if ((p->index - 2) == p->boundary_length) {
          if (c != CR) {
            /* Not the right boundary, go back to looking for start */
            p->index = 0;
            p->state = s_start_boundary;
            if (c == '-') {
              p->index = 1;
            }
            break;
          }
          p->index++;
          break;
        } else if ((p->index - 2) == (p->boundary_length + 1)) {
          if (c != LF) {
            return i;
          }
          p->index = 0;
          NOTIFY_CB(part_data_begin);
          p->state = s_header_field_start;
          break;
        }
        if (c != p->multipart_boundary[p->index - 2]) {
          /* Boundary mismatch, go back to looking for start */
          p->index = 0;
          p->state = s_start_boundary;
          if (c == '-') {
            p->index = 1;
          }
          break;
        }
        p->index++;
        break;

      case s_header_field_start:
        multipart_log("s_header_field_start");
        mark = i;
        p->state = s_header_field;

      /* fallthrough */
      case s_header_field:
        multipart_log("s_header_field");
        if (c == CR) {
          p->state = s_headers_almost_done;
          break;
        }

        if (c == ':') {
          EMIT_DATA_CB(header_field, buf + mark, i - mark);
          /* Optimization: Skip intermediate s_header_value_start state */
          mark = i + 1;  /* Mark start after colon */
          p->state = s_header_value;
          break;
        }

        cl = tolower(c);
        if ((c != '-') && (cl < 'a' || cl > 'z')) {
          multipart_log("invalid character in header name");
          p->error = MPPE_INVALID_HEADER_FIELD;
          return i;
        }
        if (is_last)
            EMIT_DATA_CB(header_field, buf + mark, (i - mark) + 1);
        break;

      case s_headers_almost_done:
        multipart_log("s_headers_almost_done");
        if (c != LF) {
          p->error = MPPE_INVALID_HEADER_FORMAT;
          return i;
        }

        p->state = s_part_data_start;
        break;

      case s_header_value:
        multipart_log("s_header_value");
        /* Optimization: Handle leading space inline (was s_header_value_start) */
        while (mark < len && buf[mark] == ' ') {
          mark++;  /* Skip leading spaces */
        }
        if (mark > i) {
          /* All consumed were spaces, continue to next iteration */
          break;
        }
        if (c == CR) {
          EMIT_DATA_CB(header_value, buf + mark, i - mark);
          p->state = s_header_value_almost_done;
          break;
        }
        if (is_last)
            EMIT_DATA_CB(header_value, buf + mark, (i - mark) + 1);
        break;

      case s_header_value_almost_done:
        multipart_log("s_header_value_almost_done");
        if (c != LF) {
          p->error = MPPE_INVALID_HEADER_FORMAT;
          return i;
        }
        p->state = s_header_field_start;
        break;

      case s_part_data_start:
        multipart_log("s_part_data_start");
        /* Flush header buffers before starting part data */
        if (flush_buffer(p, p->settings->on_header_field, &p->header_field_buffer, &p->header_field_buffer_len) != 0) {
          p->error = MPPE_PAUSED;
          return i;
        }
        if (flush_buffer(p, p->settings->on_header_value, &p->header_value_buffer, &p->header_value_buffer_len) != 0) {
          p->error = MPPE_PAUSED;
          return i;
        }
        NOTIFY_CB(headers_complete);
        mark = i;
        p->state = s_part_data;

      /* fallthrough */
      case s_part_data:
        multipart_log("s_part_data");
        /* Optimization: Use memchr() to batch-scan for CR instead of char-by-char */
        if (i < len) {
            const char *cr_pos = (const char*)memchr(buf + i, CR, len - i);
            if (cr_pos == NULL) {
                /* No CR found, emit all remaining data */
                EMIT_DATA_CB(part_data, buf + mark, len - mark);
                /* Skip to end - loop will increment i to len and exit */
                i = len - 1;
                break;
            } else {
                /* CR found, emit data up to CR */
                size_t cr_index = (size_t)(cr_pos - buf);
                if (cr_index > mark) {
                    EMIT_DATA_CB(part_data, buf + mark, cr_index - mark);
                }
                i = cr_index;
                c = CR;
                mark = i;
                p->state = s_part_data_almost_boundary;
                p->lookbehind[0] = CR;
                break;
            }
        }
        /* Fallback for single character (shouldn't reach here with optimization) */
        if (c == CR) {
            EMIT_DATA_CB(part_data, buf + mark, i - mark);
            mark = i;
            p->state = s_part_data_almost_boundary;
            p->lookbehind[0] = CR;
            break;
        }
        if (is_last)
            EMIT_DATA_CB(part_data, buf + mark, (i - mark) + 1);
        break;

      case s_part_data_almost_boundary:
        multipart_log("s_part_data_almost_boundary");
        if (c == LF) {
            p->state = s_part_data_boundary;
            p->lookbehind[1] = LF;
            p->index = 0;
            break;
        }
        EMIT_DATA_CB(part_data, p->lookbehind, 1);
        p->state = s_part_data;
        mark = i --;
        break;

      case s_part_data_boundary:
        multipart_log("s_part_data_boundary");
        /* RFC 2046: boundary must start with -- after CRLF */
        if (p->index == 0) {
          if (c != '-') {
            EMIT_DATA_CB(part_data, p->lookbehind, 2);
            p->state = s_part_data;
            mark = i --;
            break;
          }
          p->lookbehind[2] = c;
          p->index++;
          break;
        } else if (p->index == 1) {
          if (c != '-') {
            EMIT_DATA_CB(part_data, p->lookbehind, 3);
            p->state = s_part_data;
            mark = i --;
            break;
          }
          p->lookbehind[3] = c;
          p->index++;
          p->state = s_part_data_boundary_hyphen2;
          break;
        }
        /* Should not reach here */
        p->error = MPPE_INVALID_STATE;
        return i;

      case s_part_data_boundary_hyphen2:
        multipart_log("s_part_data_boundary_hyphen2");
        if (p->multipart_boundary[p->index - 2] != c) {
          EMIT_DATA_CB(part_data, p->lookbehind, 2 + p->index);
          p->state = s_part_data;
          mark = i --;
          break;
        }
        p->lookbehind[2 + p->index] = c;
        if ((++ p->index) == (p->boundary_length + 2)) {
            /* Flush part data buffer before ending part */
            if (flush_buffer(p, p->settings->on_part_data, &p->part_data_buffer, &p->part_data_buffer_len) != 0) {
              p->error = MPPE_PAUSED;
              return i;
            }
            NOTIFY_CB(part_data_end);
            p->state = s_part_data_almost_end;
        }
        break;

      case s_part_data_almost_end:
        multipart_log("s_part_data_almost_end");
        if (c == '-') {
            p->state = s_part_data_final_hyphen;
            break;
        }
        if (c == CR) {
            p->state = s_part_data_end;
            break;
        }
        p->error = MPPE_INVALID_BOUNDARY;
        return i;

      case s_part_data_final_hyphen:
        multipart_log("s_part_data_final_hyphen");
        if (c == '-') {
            /* Flush part data buffer before body end */
            if (flush_buffer(p, p->settings->on_part_data, &p->part_data_buffer, &p->part_data_buffer_len) != 0) {
              p->error = MPPE_PAUSED;
              return i;
            }
            NOTIFY_CB(body_end);
            p->state = s_end;
            break;
        }
        p->error = MPPE_INVALID_BOUNDARY;
        return i;

      case s_part_data_end:
        multipart_log("s_part_data_end");
        if (c == LF) {
            /* Flush part data buffer before starting new part */
            if (flush_buffer(p, p->settings->on_part_data, &p->part_data_buffer, &p->part_data_buffer_len) != 0) {
              p->error = MPPE_PAUSED;
              return i;
            }
            p->state = s_header_field_start;
            NOTIFY_CB(part_data_begin);
            break;
        }
        p->error = MPPE_INVALID_BOUNDARY;
        return i;

      case s_end:
        multipart_log("s_end: %02X", (int) c);
        break;

      default:
        multipart_log("Multipart parser unrecoverable error");
        p->error = MPPE_INVALID_STATE;
        return 0;
    }
    ++ i;
  }

  return len;
}
