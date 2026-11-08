// SPDX-License-Identifier: AGPL-3.0-only
#include "RemotePlayBridge.h"
#include <chiaki/session.h>
#include <chiaki/regist.h>
#include <chiaki/opusdecoder.h>
#include <arpa/inet.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct VRPClient {
    VRPCallbacks callbacks;
    void *user;
    ChiakiLog log;
    ChiakiRegist registration;
    ChiakiSession session;
    ChiakiOpusDecoder audio;
    bool registering, initialized, started;
    char registration_host[INET_ADDRSTRLEN];
    uint8_t account_id[8];
};
static pthread_once_t init_once = PTHREAD_ONCE_INIT;
static int init_result;
static void init_library(void) { init_result = chiaki_lib_init(); }

// Temporary opt-in diagnosis: SIGABRT produces a device crash record containing
// the interrupted SIGPIPE call stack. Never enabled in an ordinary launch.
static void diagnostic_sigpipe(int number) { (void)number; abort(); }

static bool local_host(const char *host) {
    struct in_addr address;
    if(!host || inet_pton(AF_INET, host, &address) != 1) return false;
    uint32_t ip = ntohl(address.s_addr);
    return (ip >> 24) == 10 || (ip >> 16) == 0xc0a8 ||
        (ip >> 20) == 0xac1 || (ip >> 16) == 0xa9fe;
}
static void status(VRPClient *c, int state, const char *message) {
    if(c->callbacks.status) c->callbacks.status(c->user, state, message);
}
static void registration_callback(ChiakiRegistEvent *event, void *user) {
    VRPClient *c = user;
    if(event->type != CHIAKI_REGIST_EVENT_TYPE_FINISHED_SUCCESS) {
        status(c, 5, event->type == CHIAKI_REGIST_EVENT_TYPE_FINISHED_CANCELED ?
               "Pairing cancelled." : "Pairing failed. Check the account ID, console IP and a fresh Link Device code.");
        return;
    }
    const ChiakiRegisteredHost *h = event->registered_host;
    uint8_t pairing[VRP_PAIRING_SIZE] = {0};
    memcpy(pairing, "CVRP", 4); pairing[4] = 1;
    memcpy(pairing + 8, h->rp_regist_key, 16);
    memcpy(pairing + 24, h->rp_key, 16);
    memcpy(pairing + 40, h->server_mac, 6);
    memcpy(pairing + 48, h->server_nickname, 31);
    memcpy(pairing + 80, c->account_id, 8);
    if(c->callbacks.registered)
        c->callbacks.registered(c->user, pairing, sizeof(pairing), (char *)pairing + 48);
}
static bool video_callback(uint8_t *bytes, size_t size, int32_t lost, bool recovered, void *user) {
    VRPClient *c = user;
    return c->callbacks.video && c->callbacks.video(c->user, bytes, size, lost, recovered);
}
static void audio_format_callback(uint32_t channels, uint32_t rate, void *user) {
    VRPClient *c = user;
    if(c->callbacks.audio_format) c->callbacks.audio_format(c->user, channels, rate);
}
static void audio_callback(int16_t *samples, size_t count, void *user) {
    VRPClient *c = user;
    if(c->callbacks.audio) c->callbacks.audio(c->user, samples, count);
}
static void session_callback(ChiakiEvent *event, void *user) {
    VRPClient *c = user;
    switch(event->type) {
        case CHIAKI_EVENT_CONNECTED: status(c, 2, "Connected to PS5. Waiting for video."); break;
        case CHIAKI_EVENT_QUIT: status(c, 3, chiaki_quit_reason_string(event->quit.reason)); break;
        case CHIAKI_EVENT_LOGIN_PIN_REQUEST: status(c, 4, event->login_pin_request.pin_incorrect ? "Console login PIN was incorrect." : "Enter your console user's login PIN."); break;
        default: break;
    }
}
VRPClient *vrp_create(VRPCallbacks callbacks, void *user) {
    if(getenv("VRP_DIAGNOSTIC_SIGPIPE")) signal(SIGPIPE, diagnostic_sigpipe);
    pthread_once(&init_once, init_library);
    if(init_result) return NULL;
    VRPClient *c = calloc(1, sizeof(*c));
    if(!c) return NULL;
    c->callbacks = callbacks; c->user = user;
    // Upstream verbose logs can contain pairing secrets. Use callback status only.
    chiaki_log_init(&c->log, 0, NULL, NULL);
    chiaki_opus_decoder_init(&c->audio, &c->log);
    chiaki_opus_decoder_set_cb(&c->audio, audio_format_callback, audio_callback, c);
    return c;
}
void vrp_finish_registration(VRPClient *c) {
    if(c && c->registering) {
        chiaki_regist_stop(&c->registration);
        chiaki_regist_fini(&c->registration);
        c->registering = false;
    }
}
int vrp_register(VRPClient *c, const char *host, const uint8_t *account_id, size_t account_size, uint32_t pin) {
    if(!c || !local_host(host) || !account_id || account_size != 8 || pin > 99999999)
        return CHIAKI_ERR_INVALID_DATA;
    vrp_finish_registration(c);
    vrp_disconnect(c);
    snprintf(c->registration_host, sizeof(c->registration_host), "%s", host);
    memcpy(c->account_id, account_id, 8);
    ChiakiRegistInfo info = {0};
    info.target = CHIAKI_TARGET_PS5_1;
    info.host = c->registration_host;
    memcpy(info.psn_account_id, account_id, 8);
    info.pin = pin;
    int result = chiaki_regist_start(&c->registration, &c->log, &info, registration_callback, c);
    if(!result) { c->registering = true; status(c, 1, "Pairing with PS5…"); }
    return result;
}
int vrp_connect(VRPClient *c, const char *host, const uint8_t *pairing, size_t size, int resolution) {
    if(!c || !local_host(host) || !pairing || size != VRP_PAIRING_SIZE ||
       memcmp(pairing, "CVRP", 4) || pairing[4] != 1) return CHIAKI_ERR_INVALID_DATA;
    vrp_finish_registration(c);
    vrp_disconnect(c);
    ChiakiConnectInfo info = {0};
    info.ps5 = true; info.host = host;
    memcpy(info.regist_key, pairing + 8, 16);
    memcpy(info.morning, pairing + 24, 16);
    memcpy(info.psn_account_id, pairing + 80, 8);
    chiaki_connect_video_profile_preset(&info.video_profile,
        resolution == 1080 ? CHIAKI_VIDEO_RESOLUTION_PRESET_1080p : CHIAKI_VIDEO_RESOLUTION_PRESET_720p,
        CHIAKI_VIDEO_FPS_PRESET_60);
    info.video_profile.codec = CHIAKI_CODEC_H264;
    info.video_profile.bitrate = resolution == 1080 ? 15000 : 8000;
    info.video_profile_auto_downgrade = true;
    info.packet_loss_max = 0.05;
    info.enable_idr_on_fec_failure = true;
    int result = chiaki_session_init(&c->session, &info, &c->log);
    if(result) return result;
    c->initialized = true;
    chiaki_session_set_event_cb(&c->session, session_callback, c);
    chiaki_session_set_video_sample_cb(&c->session, video_callback, c);
    ChiakiAudioSink sink;
    chiaki_opus_decoder_get_sink(&c->audio, &sink);
    chiaki_session_set_audio_sink(&c->session, &sink);
    result = chiaki_session_start(&c->session);
    if(!result) { c->started = true; status(c, 1, "Connecting to PS5…"); }
    else { chiaki_session_fini(&c->session); c->initialized = false; }
    return result;
}
void vrp_disconnect(VRPClient *c) {
    if(!c || !c->initialized) return;
    if(c->started) { chiaki_session_stop(&c->session); chiaki_session_join(&c->session); }
    chiaki_session_fini(&c->session);
    c->initialized = false; c->started = false;
}
void vrp_destroy(VRPClient *c) {
    if(!c) return;
    vrp_finish_registration(c); vrp_disconnect(c);
    chiaki_opus_decoder_fini(&c->audio);
    memset(c, 0, sizeof(*c)); free(c);
}
void vrp_controller(VRPClient *c, uint32_t buttons, uint8_t l2, uint8_t r2, int16_t lx, int16_t ly, int16_t rx, int16_t ry) {
    if(!c || !c->started) return;
    ChiakiControllerState state;
    chiaki_controller_state_set_idle(&state);
    state.buttons = buttons; state.l2_state = l2; state.r2_state = r2;
    state.left_x = lx; state.left_y = ly; state.right_x = rx; state.right_y = ry;
    chiaki_session_set_controller_state(&c->session, &state);
}
void vrp_login_pin(VRPClient *c, const char *pin) {
    if(c && c->started && pin) chiaki_session_set_login_pin(&c->session, (const uint8_t *)pin, strlen(pin));
}
const char *vrp_error(int code) { return chiaki_error_string((ChiakiErrorCode)code); }
