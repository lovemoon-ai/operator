#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct operator_blueprint_publisher_t operator_blueprint_publisher_t;
typedef struct operator_bytes_t { uint8_t* data; size_t len; size_t capacity; } operator_bytes_t;
typedef struct operator_string_view_t { const uint8_t* data; size_t len; } operator_string_view_t;

operator_string_view_t operator_blueprint_spec_sha256(void);
uint32_t operator_blueprint_spec_version(void);
operator_blueprint_publisher_t* operator_blueprint_publisher_new(void);
void operator_blueprint_publisher_free(operator_blueprint_publisher_t* value);
void operator_bytes_free(operator_bytes_t value);
bool operator_blueprint_set_json(operator_blueprint_publisher_t*, const uint8_t*, size_t, operator_bytes_t*);
bool operator_blueprint_clear(operator_blueprint_publisher_t*, operator_bytes_t*);
bool operator_blueprint_update_values_json(operator_blueprint_publisher_t*, const uint8_t*, size_t, uint64_t, uint64_t*, operator_bytes_t*);
bool operator_blueprint_definition_message_json(operator_blueprint_publisher_t*, operator_bytes_t*, operator_bytes_t*);
bool operator_blueprint_state_message_json(operator_blueprint_publisher_t*, operator_bytes_t*, operator_bytes_t*);
bool operator_blueprint_descriptor_message_json(operator_blueprint_publisher_t*, const uint8_t*, size_t, operator_bytes_t*, operator_bytes_t*);
bool operator_blueprint_parse_event_message_json(operator_blueprint_publisher_t*, const uint8_t*, size_t, operator_bytes_t*, operator_bytes_t*);

#ifdef __cplusplus
}
#endif
