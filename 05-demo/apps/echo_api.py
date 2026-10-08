"""Echo API: a REST API with no token validation code.

Envoy Gateway validates the bearer token, checks the roles, and passes the
caller identity in headers.
"""
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ITEMS = [{"id": 1, "name": "keyboard"}, {"id": 2, "name": "screen"}]


class Handler(BaseHTTPRequestHandler):
    def caller(self):
        return {
            "client_id": self.headers.get("X-Client-Id"),
            "user": self.headers.get("X-Remote-User"),
            "authorization_header": "Authorization" in self.headers,
        }

    def do_GET(self):
        if self.path == "/healthz":
            return self.reply(200, {"status": "ok"})
        if self.path == "/items":
            return self.reply(200, {"caller": self.caller(), "items": ITEMS})
        return self.reply(404, {"error": "not found"})

    def do_POST(self):
        if self.path == "/items":
            length = int(self.headers.get("Content-Length") or 0)
            item = json.loads(self.rfile.read(length) or b"{}")
            return self.reply(201, {"caller": self.caller(), "created": item})
        return self.reply(404, {"error": "not found"})

    def reply(self, status, body):
        data = (json.dumps(body, indent=2) + "\n").encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


if __name__ == "__main__":
    ThreadingHTTPServer(("", 8080), Handler).serve_forever()
