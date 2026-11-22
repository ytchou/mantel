#!/usr/bin/env python3
# Throwaway CONNECT proxy for the sandbox spike. Logs each request line to
# stdout, connects to the named host (spike only) and relays bytes both ways.
#   python3 proxy.py <port>
import socket, sys, threading

def pipe(a, b):
    try:
        while (data := a.recv(65536)):
            b.sendall(data)
    except OSError:
        pass
    finally:
        for s in (a, b):
            try: s.shutdown(socket.SHUT_RDWR)
            except OSError: pass

def handle(client):
    head = b""
    while b"\r\n\r\n" not in head and len(head) < 8192:
        if not (chunk := client.recv(4096)): return client.close()
        head += chunk
    line = head.split(b"\r\n", 1)[0].decode(errors="replace")
    print("REQUEST", line, flush=True)
    method, target, _ = line.split(" ", 2)
    if method != "CONNECT": return client.sendall(b"HTTP/1.1 405 Method Not Allowed\r\n\r\n"), client.close()
    host, port = target.rsplit(":", 1)
    upstream = socket.create_connection((host, int(port)), timeout=10)
    client.sendall(b"HTTP/1.1 200 Connection Established\r\n\r\n")
    threading.Thread(target=pipe, args=(upstream, client), daemon=True).start()
    pipe(client, upstream)

server = socket.create_server(("127.0.0.1", int(sys.argv[1])))
print("LISTENING", sys.argv[1], flush=True)
while True:
    conn, _ = server.accept()
    threading.Thread(target=handle, args=(conn,), daemon=True).start()
