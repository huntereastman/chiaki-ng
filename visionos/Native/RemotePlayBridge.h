// SPDX-License-Identifier: AGPL-3.0-only
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct VRPClient VRPClient;
enum { VRP_PAIRING_SIZE = 88 };
typedef struct {
    void (*status)(void *user, int state, const char *message);
    void (*registered)(void *user, const uint8_t *pairing, size_t size, const char *name);
    bool (*video)(void *user, const uint8_t *bytes, size_t size, int32_t lost, bool recovered);
    void (*audio_format)(void *user, uint32_t channels, uint32_t sample_rate);
    void (*audio)(void *user, const int16_t *samples, size_t count);
} VRPCallbacks;
VRPClient *vrp_create(VRPCallbacks callbacks, void *user);
void vrp_destroy(VRPClient *client);
int vrp_register(VRPClient *client, const char *host, const uint8_t *account_id, size_t account_size, uint32_t pin);
void vrp_finish_registration(VRPClient *client);
int vrp_connect(VRPClient *client, const char *host, const uint8_t *pairing, size_t size, int resolution);
void vrp_disconnect(VRPClient *client);
void vrp_controller(VRPClient *client, uint32_t buttons, uint8_t l2, uint8_t r2, int16_t lx, int16_t ly, int16_t rx, int16_t ry);
void vrp_login_pin(VRPClient *client, const char *pin);
const char *vrp_error(int code);
