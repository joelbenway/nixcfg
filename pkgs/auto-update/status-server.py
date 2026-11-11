#!/usr/bin/env python3
# Copyright (c) Joel Benway
# SPDX-License-Identifier: MIT
import http.server
import os
import socket
import sys

status_file = (
    sys.argv[1]
    if len(sys.argv) > 1
    else os.environ.get("STATUS_FILE", "/var/lib/nixos-auto-update/status.json")
)
port = (
    int(sys.argv[2])
    if len(sys.argv) > 2
    else int(os.environ.get("STATUS_PORT", "9105"))
)


class StatusHandler(http.server.BaseHTTPRequestHandler):

  def do_GET(self):
    if self.path not in ("/", "/status", "/status.json"):
      self.send_response(404)
      self.end_headers()
      return
    if os.path.exists(status_file):
      with open(status_file, "rb") as f:
        data = f.read()
    else:
      data = (
          b'{"status":"healthy","severity":"info","summary":"No status'
          b' recorded yet"}'
      )
    self.send_response(200)
    self.send_header("Content-Type", "application/json")
    self.send_header("Content-Length", str(len(data)))
    self.end_headers()
    self.wfile.write(data)

  def log_message(self, format, *args):
    return


class HTTPServerV6(http.server.HTTPServer):
  address_family = socket.AF_INET6


try:
  server = HTTPServerV6(("::", port), StatusHandler)
except Exception:
  server = http.server.HTTPServer(("0.0.0.0", port), StatusHandler)
server.serve_forever()
