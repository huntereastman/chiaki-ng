// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

#include <chiaki/sock.h>
#include <fcntl.h>
#ifdef __APPLE__
#include <sys/socket.h>
#endif

CHIAKI_EXPORT ChiakiErrorCode chiaki_socket_set_nonblock(chiaki_socket_t sock, bool nonblock)
{
#ifdef _WIN32
	u_long nbio = nonblock ? 1 : 0;
	if(ioctlsocket(sock, FIONBIO, &nbio) != NO_ERROR)
		return CHIAKI_ERR_UNKNOWN;
#else
#ifdef __APPLE__
	// A closed TCP peer must return EPIPE, not terminate an embedding app.
	// Keep this per socket so the host's process-wide signal policy is intact.
	const int no_sigpipe = 1;
	if(setsockopt(sock, SOL_SOCKET, SO_NOSIGPIPE, &no_sigpipe, sizeof(no_sigpipe)) < 0)
		return CHIAKI_ERR_NETWORK;
#endif
	int flags = fcntl(sock, F_GETFL, 0);
	if(flags == -1)
		return CHIAKI_ERR_UNKNOWN;
	flags = nonblock ? (flags | O_NONBLOCK) : (flags & ~O_NONBLOCK);
	if(fcntl(sock, F_SETFL, flags) == -1)
		return CHIAKI_ERR_UNKNOWN;
#endif
	return CHIAKI_ERR_SUCCESS;
}
