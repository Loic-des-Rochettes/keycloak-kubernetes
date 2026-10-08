"""Legacy intranet application.

It has no OIDC code. Like an application behind an Apache mod_auth_* module or a
web access management agent, it trusts the identity headers set by the gateway
in front of it, and only works when it is reached through that gateway.
"""
import html
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

IDENTITY_HEADERS = [
    "X-Remote-User",
    "X-Remote-Name",
    "X-Remote-Email",
    "X-Remote-Groups",
    "X-Remote-Employee-Id",
    "X-Remote-Department",
]


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/healthz":
            return self.reply(200, "text/plain", "ok\n")

        identity = {name: self.headers.get(name) for name in IDENTITY_HEADERS}

        # Raw view of what the application receives, used by the tests.
        if self.path == "/whoami":
            body = {
                "identity": identity,
                "authorization_header": "Authorization" in self.headers,
                "x_forwarded_for": self.headers.get("X-Forwarded-For"),
                "headers": sorted(self.headers.keys()),
            }
            return self.reply(200, "application/json", json.dumps(body, indent=2) + "\n")

        if not identity["X-Remote-User"]:
            return self.reply(401, "text/plain", "No identity header: use the gateway.\n")

        rows = "".join(
            f"<tr><th>{html.escape(name)}</th><td>{html.escape(value or '-')}</td></tr>"
            for name, value in identity.items()
        )
        page = f"""<!doctype html>
<html><head><meta charset="utf-8"><title>Legacy intranet</title>
<style>body{{font-family:sans-serif;margin:2rem}}th{{text-align:left;padding-right:1rem}}</style>
</head><body>
<h1>Welcome {html.escape(identity["X-Remote-Name"] or identity["X-Remote-User"])}</h1>
<p>This application has no OpenID Connect code: it reads the headers set by Envoy Gateway.</p>
<table>{rows}</table>
<p><a href="/logout">Sign out</a></p>
</body></html>
"""
        return self.reply(200, "text/html; charset=utf-8", page)

    def reply(self, status, content_type, body):
        data = body.encode()
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


if __name__ == "__main__":
    ThreadingHTTPServer(("", 8080), Handler).serve_forever()
