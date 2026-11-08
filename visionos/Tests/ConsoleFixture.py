#!/usr/bin/env python3
"""One bounded, failing LAN registration fixture; never emulates a real console.

Bind to an address owned by this development Mac, then launch the Debug app with
VRP_DIAGNOSTIC_PAIR_HOST set to that address. The app uses synthetic account/PIN
data. This fixture logs only packet sizes and sends a fixed rejection response.
"""
import argparse
import ipaddress
import select
import socket
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--host', required=True)
    parser.add_argument('--duration', type=float, default=45)
    args = parser.parse_args()
    if not ipaddress.ip_address(args.host).is_private or not 1 <= args.duration <= 120:
        parser.error('Use an owned private address and a duration of 1–120 seconds.')
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as udp, \
            socket.socket(socket.AF_INET, socket.SOCK_STREAM) as tcp:
        # Binding proves this is a local interface; do not discover or contact PS5s.
        udp.bind((args.host, 9295))
        tcp.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        tcp.bind((args.host, 9295))
        tcp.listen(1)
        print('Fixture ready.', flush=True)
        deadline = time.monotonic() + args.duration
        while time.monotonic() < deadline:
            ready, _, _ = select.select([udp, tcp], [], [], max(0, deadline - time.monotonic()))
            for stream in ready:
                if stream is udp:
                    packet, peer = udp.recvfrom(64)
                    print(f'UDP packet: {len(packet)} bytes.', flush=True)
                    if packet == b'SRC3\x00':
                        udp.sendto(b'RES3\x00', peer)
                else:
                    connection, _ = tcp.accept()
                    with connection:
                        connection.settimeout(3)
                        request = b''
                        while b'\r\n\r\n' not in request and len(request) < 4096:
                            chunk = connection.recv(4096 - len(request))
                            if not chunk:
                                break
                            request += chunk
                        if b'\r\n\r\n' in request:
                            header, body = request.split(b'\r\n\r\n', 1)
                            lengths = [line.split(b':', 1)[1].strip() for line in header.split(b'\r\n')
                                       if line.lower().startswith(b'content-length:')]
                            size = min(int(lengths[0]), 4096) if lengths else 0
                            while len(body) < size:
                                chunk = connection.recv(size - len(body))
                                if not chunk:
                                    break
                                body += chunk
                        print('TCP request received; returning fixed rejection.', flush=True)
                        connection.sendall(b'HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n')
                    return
        print('Fixture expired without a TCP request.', flush=True)


if __name__ == '__main__':
    main()
