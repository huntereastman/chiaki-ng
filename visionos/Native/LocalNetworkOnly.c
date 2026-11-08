// SPDX-License-Identifier: AGPL-3.0-only
// This target intentionally excludes PSN, UPnP, TLS and Internet traversal.
// These entry points fail closed; the native wrapper only creates LAN sessions.
#include <arpa/inet.h>
#include <chiaki/remote/holepunch.h>
#include <string.h>

void chiaki_holepunch_session_fini(ChiakiHolepunchSession s) { (void)s; }
chiaki_socket_t *chiaki_get_holepunch_sock(ChiakiHolepunchSession s, ChiakiHolepunchPortType t)
{ (void)s; (void)t; return NULL; }
ChiakiHolepunchRegistInfo chiaki_get_regist_info(ChiakiHolepunchSession s)
{ (void)s; ChiakiHolepunchRegistInfo i = {0}; return i; }
void chiaki_get_ps_selected_addr(ChiakiHolepunchSession s, char *out)
{ (void)s; if(out) out[0] = 0; }
uint16_t chiaki_get_ps_ctrl_port(ChiakiHolepunchSession s) { (void)s; return 0; }
ChiakiErrorCode holepunch_session_create_offer(ChiakiHolepunchSession s)
{ (void)s; return CHIAKI_ERR_UNINITIALIZED; }
ChiakiErrorCode chiaki_holepunch_session_punch_hole(ChiakiHolepunchSession s, ChiakiHolepunchPortType t)
{ (void)s; (void)t; return CHIAKI_ERR_UNINITIALIZED; }
