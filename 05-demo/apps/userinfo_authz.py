"""External authorization service for Envoy Gateway (HTTP ext_authz).

For each request, Envoy sends the Authorization header to this service. The
service calls the OpenID Connect UserInfo endpoint of Keycloak with the access
token and answers:
  - 200 with X-Remote-* headers built from the UserInfo claims: Envoy copies
    them to the request sent to the application (headersToBackend);
  - 401 when Keycloak rejects the token, for example because the session was
    ended: the request does not reach the application.
Answers are cached for CACHE_TTL_SECONDS per token.
"""
import hashlib
import json
import os
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

USERINFO_URL = os.environ["USERINFO_URL"]
CACHE_TTL_SECONDS = int(os.environ.get("CACHE_TTL_SECONDS", "10"))

# UserInfo claim -> request header
CLAIM_HEADERS = {
    "groups": "X-Remote-Groups",
    "employee_id": "X-Remote-Employee-Id",
    "department": "X-Remote-Department",
}

cache = {}  # sha256(token) -> (expiry, headers)


def userinfo_headers(token):
    key = hashlib.sha256(token.encode()).hexdigest()
    cached = cache.get(key)
    if cached and cached[0] > time.monotonic():
        return cached[1]

    request = urllib.request.Request(
        USERINFO_URL,
        headers={"Authorization": f"Bearer {token}", "Accept": "application/json"},
    )
    with urllib.request.urlopen(request, timeout=3) as response:
        claims = json.load(response)

    headers = {}
    for claim, header in CLAIM_HEADERS.items():
        value = claims.get(claim)
        if isinstance(value, list):
            value = ",".join(str(v) for v in value)
        if value is not None:
            headers[header] = str(value)

    for k in [k for k, (expiry, _) in cache.items() if expiry <= time.monotonic()]:
        cache.pop(k, None)
    cache[key] = (time.monotonic() + CACHE_TTL_SECONDS, headers)
    return headers


class Handler(BaseHTTPRequestHandler):
    def check(self):
        if self.path == "/healthz":
            return self.reply(200, {})
        if not self.path.startswith("/authz"):
            return self.reply(404, {})

        authorization = self.headers.get("Authorization", "")
        if not authorization.lower().startswith("bearer "):
            return self.reply(401, {}, "Missing access token.\n")
        try:
            headers = userinfo_headers(authorization[7:])
        except urllib.error.HTTPError as error:
            if error.code in (401, 403):
                return self.reply(401, {}, "Session ended. Sign in again: /logout\n")
            return self.reply(503, {}, "UserInfo endpoint error.\n")
        except (urllib.error.URLError, TimeoutError, ValueError):
            return self.reply(503, {}, "UserInfo endpoint unreachable.\n")
        return self.reply(200, headers)

    # Envoy forwards the method of the original request.
    do_GET = do_POST = do_PUT = do_PATCH = do_DELETE = do_HEAD = do_OPTIONS = check

    def reply(self, status, headers, body=""):
        data = body.encode()
        self.send_response(status)
        for name, value in headers.items():
            self.send_header(name, value)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)


if __name__ == "__main__":
    ThreadingHTTPServer(("", 8080), Handler).serve_forever()
