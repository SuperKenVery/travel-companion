#ifndef TC_PEER_TRANSPORT_APPLE_H
#define TC_PEER_TRANSPORT_APPLE_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
typedef void (*tc_peer_transport_apple_event_callback)(const uint8_t *json, intptr_t length, uintptr_t context);
/* start JSON must contain group identity plus either:
 *   identityPKCS12Base64 + identityPassword, or
 *   certificateDERBase64 + privateKeyPKCS8Base64.
 * Commands use a private "type" discriminator; callback events echo requestID where applicable.
 */
uint64_t tc_peer_transport_apple_create(tc_peer_transport_apple_event_callback callback, uintptr_t context);
bool tc_peer_transport_apple_submit(uint64_t handle, const uint8_t *json, intptr_t length);
void tc_peer_transport_apple_destroy(uint64_t handle);
#endif
