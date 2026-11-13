/* Based on node-formidable by Felix Geisendörfer
 * Igor Afonov - afonov@gmail.com - 2012
 * MIT License - http://www.opensource.org/licenses/mit-license.php
 */
#ifndef _multipart_parser_h
#define _multipart_parser_h

#ifdef __cplusplus
extern "C"
{
#endif

#include <stdlib.h>
#include <ctype.h>

/**
 * @file multipart_parser.h
 * @brief RFC 7578 compliant multipart/form-data parser
 *
 * This library provides a streaming parser for multipart/form-data content
 * as specified in RFC 7578 (2015) and RFC 2046 (1996).
 *
 * It works with chunks of data without requiring the entire request to be
 * buffered in memory.
 *
 * @see https://tools.ietf.org/html/rfc7578 RFC 7578 (current standard)
 * @see https://tools.ietf.org/html/rfc2046 RFC 2046 (MIME multipart)
 * @see docs/rfc/RFC_7578_COMPLIANCE.md For detailed compliance information
 */

/**
 * @brief Error codes returned by the parser
 */
typedef enum {
    MPPE_OK = 0,                    /**< No error */
    MPPE_PAUSED,                    /**< Parser paused by callback */
    MPPE_INVALID_BOUNDARY,          /**< Invalid boundary format */
    MPPE_INVALID_HEADER_FIELD,      /**< Invalid header field character */
    MPPE_INVALID_HEADER_FORMAT,     /**< Invalid header format */
    MPPE_INVALID_STATE,             /**< Parser in invalid state */
    MPPE_UNKNOWN                    /**< Unknown error */
} multipart_parser_error;

typedef struct multipart_parser multipart_parser;
typedef struct multipart_parser_settings multipart_parser_settings;
typedef struct multipart_parser_state multipart_parser_state;

/**
 * @brief Callback for data fields (header fields, header values, part data)
 *
 * @param p Pointer to the parser
 * @param at Pointer to the data
 * @param length Length of the data
 * @return 0 to continue parsing, non-zero to pause
 */
typedef int (*multipart_data_cb) (multipart_parser*, const char *at, size_t length);

/**
 * @brief Callback for notification events
 *
 * @param p Pointer to the parser
 * @return 0 to continue parsing, non-zero to pause
 */
typedef int (*multipart_notify_cb) (multipart_parser*);

/**
 * @brief Parser callback settings
 *
 * All callbacks are optional. Set unused callbacks to NULL.
 */
struct multipart_parser_settings {
  multipart_data_cb on_header_field;      /**< Called when a header field is parsed */
  multipart_data_cb on_header_value;      /**< Called when a header value is parsed */
  multipart_data_cb on_part_data;         /**< Called when part data is available */

  multipart_notify_cb on_part_data_begin; /**< Called when a new part begins */
  multipart_notify_cb on_headers_complete; /**< Called when headers are complete */
  multipart_notify_cb on_part_data_end;   /**< Called when a part ends */
  multipart_notify_cb on_body_end;        /**< Called when the entire body ends */

  size_t buffer_size;                     /**< Buffer size for data callbacks (0 = no buffering) */
};

/**
 * @brief Initialize a new multipart parser
 *
 * Creates and initializes a new parser with the specified boundary string.
 * The boundary should NOT include the leading "--" prefix (it will be added
 * automatically as per RFC 2046).
 *
 * @param boundary The boundary string (without "--" prefix)
 * @param settings Pointer to callback settings structure
 * @return Pointer to the new parser, or NULL on allocation failure
 *
 * @note The caller must free the returned parser with multipart_parser_free()
 * @see multipart_parser_free()
 */
multipart_parser* multipart_parser_init
    (const char *boundary, const multipart_parser_settings* settings);

/**
 * @brief Free a multipart parser
 *
 * Releases all resources associated with the parser.
 *
 * @param p Pointer to the parser to free
 */
void multipart_parser_free(multipart_parser* p);

/**
 * @brief Parse a chunk of multipart data
 *
 * Processes a chunk of multipart data. Can be called multiple times with
 * successive chunks. Callbacks will be invoked as data is parsed.
 *
 * @param p Pointer to the parser
 * @param buf Pointer to the data buffer
 * @param len Length of the data buffer
 * @return Number of bytes parsed, or position where error/pause occurred
 *
 * @note If return value < len, check multipart_parser_get_error() for details
 * @see multipart_parser_get_error()
 * @see multipart_parser_get_error_message()
 */
size_t multipart_parser_execute(multipart_parser* p, const char *buf, size_t len);

/**
 * @brief Set user data pointer
 *
 * Associates arbitrary user data with the parser. This pointer can be
 * retrieved in callbacks using multipart_parser_get_data().
 *
 * @param p Pointer to the parser
 * @param data User data pointer
 * @see multipart_parser_get_data()
 */
void multipart_parser_set_data(multipart_parser* p, void* data);

/**
 * @brief Get user data pointer
 *
 * Retrieves the user data pointer previously set with
 * multipart_parser_set_data().
 *
 * @param p Pointer to the parser
 * @return User data pointer
 * @see multipart_parser_set_data()
 */
void * multipart_parser_get_data(multipart_parser* p);

/**
 * @brief Get the last error code
 *
 * Returns the error code from the last parse operation.
 *
 * @param p Pointer to the parser
 * @return Error code (MPPE_OK if no error)
 * @see multipart_parser_error
 * @see multipart_parser_get_error_message()
 */
multipart_parser_error multipart_parser_get_error(multipart_parser* p);

/**
 * @brief Get a human-readable error message
 *
 * Returns a descriptive error message for the last error.
 *
 * @param p Pointer to the parser
 * @return Error message string (never NULL)
 * @see multipart_parser_get_error()
 */
const char* multipart_parser_get_error_message(multipart_parser* p);

/**
 * @brief Reset a multipart parser for reuse
 *
 * Resets the parser state to allow reusing the same parser instance with
 * a new boundary string. This is useful when you need to parse multiple
 * multipart messages with different boundaries using the same parser object.
 *
 * The parser's internal state, buffers, and error state are reset. If a new
 * boundary is provided, it must fit within the originally allocated memory
 * (i.e., the new boundary cannot be longer than the original boundary).
 *
 * @param p Pointer to the parser to reset
 * @param boundary The new boundary string (without "--" prefix), or NULL to
 *                 keep the existing boundary
 * @return 0 on success, -1 if the new boundary is too long
 *
 * @note The settings callbacks remain unchanged
 * @note The user data pointer is preserved
 * @see multipart_parser_init()
 */
int multipart_parser_reset(multipart_parser* p, const char *boundary);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif
