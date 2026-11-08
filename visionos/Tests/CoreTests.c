// SPDX-License-Identifier: AGPL-3.0-only
#include "RemotePlayBridge.h"
#include <chiaki/ecdh.h>
#include <chiaki/session.h>
#include <assert.h>
#include <stdio.h>
#include <string.h>

int main(void) {
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
