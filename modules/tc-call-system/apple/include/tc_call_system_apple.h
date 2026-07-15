#ifndef TC_CALL_SYSTEM_APPLE_H
#define TC_CALL_SYSTEM_APPLE_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
typedef void (*tc_call_system_apple_event_callback)(const uint8_t *json, intptr_t length, uintptr_t context);
uint64_t tc_call_system_apple_create(tc_call_system_apple_event_callback callback, uintptr_t context);
bool tc_call_system_apple_submit(uint64_t handle, const uint8_t *json, intptr_t length);
void tc_call_system_apple_destroy(uint64_t handle);
#endif
