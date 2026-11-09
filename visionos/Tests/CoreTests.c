// SPDX-License-Identifier: AGPL-3.0-only
// Exercise the production bridge's real session initialization, replacing only
// the asynchronous network start with the same display-sink notification that
// the control handshake delivers for RP-Prohibit. No console is contacted.
#ifdef __APPLE__
#define chiaki_session_start test_session_start
#include "../Native/RemotePlayBridge.c"
#undef chiaki_session_start
#else
#include "RemotePlayBridge.h"
#endif
#include <chiaki/ecdh.h>
#include <chiaki/session.h>
#include <assert.h>
#include <stdio.h>
#include <string.h>
#ifdef __APPLE__
#include "../../lib/src/utils.h"
#include <signal.h>
#include <sys/wait.h>
#include <sys/resource.h>

static bool test_cant_display;
static int test_status, test_status_calls;
static void capture_display_status(void *user, int state, const char *message) {
    assert(user == &test_status);
    test_status = state; test_status_calls++;
    assert(message && strstr(message, "PS5"));
}
ChiakiErrorCode test_session_start(ChiakiSession *session) {
    // An absent sink reproduces the installed app's branch to address zero.
    session->display_sink.cantdisplay_cb(session->display_sink.user, test_cant_display);
    return CHIAKI_ERR_CANCELED; // No thread was started; normal initialization cleanup follows.
}
static bool display_notifications_are_handled(void) {
    pid_t child = fork();
    if(child < 0) return false;
    if(child == 0) {
        struct rlimit limit = {0, 0}; setrlimit(RLIMIT_CORE, &limit);
        VRPCallbacks callbacks = { .status = capture_display_status };
        VRPClient *client = vrp_create(callbacks, &test_status);
        uint8_t pairing[VRP_PAIRING_SIZE] = {0};
        memcpy(pairing, "CVRP", 4); pairing[4] = 1;
        for(int blocked = 0; blocked < 2; blocked++) {
            test_cant_display = blocked; test_status = 0; test_status_calls = 0;
            if(vrp_connect(client, "192.168.1.1", pairing, sizeof(pairing), 1080) != CHIAKI_ERR_CANCELED) _exit(2);
            if(blocked && (test_status != 5 || test_status_calls != 1)) _exit(3);
            if(!blocked && test_status_calls != 0) _exit(4);
        }
        vrp_destroy(client); _exit(0);
    }
    int result;
    if(waitpid(child, &result, 0) != child) return false;
    if(WIFSIGNALED(result)) fprintf(stderr, "Display restriction notification terminated with signal %d.\n", WTERMSIG(result));
    return WIFEXITED(result) && WEXITSTATUS(result) == 0;
}

static bool closed_write_returns_error(bool nonblock, int socket_type) {
    // Keep the default signal disposition in a child so this catches process
    // termination even when the test runner itself ignores SIGPIPE.
    pid_t child = fork();
    if(child < 0) return false;
    if(child == 0) {
        signal(SIGPIPE, SIG_DFL);
        int sockets[2];
        if(socketpair(AF_UNIX, socket_type, 0, sockets)) _exit(2);
        if(chiaki_socket_set_nonblock(sockets[0], nonblock)) _exit(3);
        const uint8_t request[] = "registration request";
        uint8_t received[sizeof(request)];
        if(chiaki_send_fully(NULL, sockets[0], request, sizeof(request), 100) != CHIAKI_ERR_SUCCESS ||
           recv(sockets[1], received, sizeof(received), 0) != sizeof(received) ||
           memcmp(request, received, sizeof(request))) _exit(5);
        if(socket_type == SOCK_DGRAM) {
            if(shutdown(sockets[0], SHUT_WR)) _exit(6);
        } else close(sockets[1]);
        ChiakiErrorCode result = chiaki_send_fully(NULL, sockets[0], request, sizeof(request), 100);
        int error = errno;
        close(sockets[0]);
        if(socket_type == SOCK_DGRAM) close(sockets[1]);
        _exit(result == CHIAKI_ERR_NETWORK && error == EPIPE ? 0 : 4);
    }
    int result;
    if(waitpid(child, &result, 0) != child) return false;
    if(WIFSIGNALED(result)) {
        fprintf(stderr, "Closed-peer write terminated with signal %d (nonblock=%d type=%d).\n",
                WTERMSIG(result), nonblock, socket_type);
        return false;
    }
    if(!WIFEXITED(result) || WEXITSTATUS(result))
        fprintf(stderr, "Closed-write test failed with status %d (nonblock=%d type=%d).\n", result, nonblock, socket_type);
    return WIFEXITED(result) && WEXITSTATUS(result) == 0;
}
#endif

int main(void) {
#ifdef __APPLE__
    if(!display_notifications_are_handled()) return 1;
    puts("Allowed and prohibited display notifications complete without terminating the process.");
    if(!closed_write_returns_error(true, SOCK_STREAM) || !closed_write_returns_error(false, SOCK_STREAM) ||
       !closed_write_returns_error(true, SOCK_DGRAM) || !closed_write_returns_error(false, SOCK_DGRAM)) return 1;
    puts("Closed-peer writes return network errors without terminating the process.");
#endif
    VRPCallbacks callbacks = {0};
    VRPClient *client = vrp_create(callbacks, NULL);
    assert(client);
    uint8_t account[8] = {0}, invalid[VRP_PAIRING_SIZE] = {0};
    assert(vrp_register(client, "8.8.8.8", account, 8, 12345678) == CHIAKI_ERR_INVALID_DATA);
    assert(vrp_register(client, "192.168.1.1", account, 7, 12345678) == CHIAKI_ERR_INVALID_DATA);
    assert(vrp_register(client, "192.168.1.1", account, 8, 100000000) == CHIAKI_ERR_INVALID_DATA);
    assert(vrp_connect(client, "192.168.1.1", invalid, sizeof(invalid), 1080) == CHIAKI_ERR_INVALID_DATA);
    vrp_disconnect(client);
    vrp_destroy(client);

    ChiakiECDH a, b;
    assert(chiaki_ecdh_init(&a) == CHIAKI_ERR_SUCCESS);
    assert(chiaki_ecdh_init(&b) == CHIAKI_ERR_SUCCESS);
    uint8_t handshake[16] = {0x34}, apub[128], bpub[128], asig[32], bsig[32];
    size_t apub_len = sizeof(apub), bpub_len = sizeof(bpub), asig_len = sizeof(asig), bsig_len = sizeof(bsig);
    assert(chiaki_ecdh_get_local_pub_key(&a, apub, &apub_len, handshake, asig, &asig_len) == CHIAKI_ERR_SUCCESS);
    assert(chiaki_ecdh_get_local_pub_key(&b, bpub, &bpub_len, handshake, bsig, &bsig_len) == CHIAKI_ERR_SUCCESS);
    uint8_t asecret[CHIAKI_ECDH_SECRET_SIZE], bsecret[CHIAKI_ECDH_SECRET_SIZE];
    assert(chiaki_ecdh_derive_secret(&a, asecret, bpub, bpub_len, handshake, bsig, bsig_len) == CHIAKI_ERR_SUCCESS);
    assert(chiaki_ecdh_derive_secret(&b, bsecret, apub, apub_len, handshake, asig, asig_len) == CHIAKI_ERR_SUCCESS);
    assert(memcmp(asecret, bsecret, sizeof(asecret)) == 0);
    chiaki_ecdh_fini(&a); chiaki_ecdh_fini(&b);
    puts("Local-only input validation, lifecycle and mbedTLS ECDH agreement passed.");
    return 0;
}
