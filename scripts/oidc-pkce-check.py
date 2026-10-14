#!/usr/bin/env python3
"""Authorization-code + PKCE smoke test against the Dex test provider (profile `oidc`).

Usage: scripts/oidc-pkce-check.py [issuer] [user] [password]
Prints which steps worked; never prints token values.
"""
import base64, hashlib, json, os, re, secrets, sys, urllib.error, urllib.parse, urllib.request

issuer = sys.argv[1] if len(sys.argv) > 1 else "http://localhost:15556/dex"
user = sys.argv[2] if len(sys.argv) > 2 else "alice@example.test"
password = sys.argv[3] if len(sys.argv) > 3 else "alice-dev-pass"
client_id = "timetrack-dev"
redirect = "http://localhost:18080/api/v1/auth/oidc/callback"


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k):
        return None


opener = urllib.request.build_opener(NoRedirect, urllib.request.HTTPCookieProcessor())


def req(url, data=None):
    r = urllib.request.Request(url, data=urllib.parse.urlencode(data).encode() if data else None)
    try:
        resp = opener.open(r)
        return resp.status, resp.headers, resp.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.headers, e.read().decode()


def abs_url(base, loc):
    return urllib.parse.urljoin(base, loc)


disc = json.loads(req(issuer + "/.well-known/openid-configuration")[2])
assert disc["issuer"] == issuer, "issuer mismatch"
print("discovery ok:", disc["issuer"])

verifier = secrets.token_urlsafe(64)
challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
state = secrets.token_urlsafe(16)
url = disc["authorization_endpoint"] + "?" + urllib.parse.urlencode({
    "client_id": client_id, "redirect_uri": redirect, "response_type": "code",
    "scope": "openid email profile", "state": state, "nonce": secrets.token_urlsafe(8),
    "code_challenge": challenge, "code_challenge_method": "S256"})

code = None
for _ in range(10):
    if url.startswith(redirect):
        q = urllib.parse.parse_qs(urllib.parse.urlparse(url).query)
        assert q["state"][0] == state, "state mismatch"
        code = q["code"][0]
        break
    status, headers, body = req(url)
    if status in (301, 302, 303):
        loc = abs_url(url, headers["Location"])
        if loc.startswith(redirect):
            q = urllib.parse.parse_qs(urllib.parse.urlparse(loc).query)
            assert q["state"][0] == state, "state mismatch"
            code = q["code"][0]
            break
        url = loc
        continue
    if status == 200 and "password" in body:
        action = re.search(r'<form[^>]*action="([^"]*)"', body).group(1).replace("&amp;", "&")
        post = abs_url(url, action)
        status, headers, _ = req(post, {"login": user, "password": password})
        url = abs_url(post, headers["Location"])
        continue
    raise SystemExit(f"unexpected response {status} at {url}")
assert code, "no authorization code received"
print("authorization code received")

status, _, body = req(disc["token_endpoint"], {
    "grant_type": "authorization_code", "code": code, "redirect_uri": redirect,
    "client_id": client_id, "code_verifier": verifier})
tok = json.loads(body)
assert status == 200 and "id_token" in tok, f"token exchange failed: {status} {body[:200]}"
claims = json.loads(base64.urlsafe_b64decode(tok["id_token"].split(".")[1] + "=="))
print("token exchange ok; id_token claims:", {k: claims.get(k) for k in ("iss", "aud", "email", "email_verified")})
print("access_token present:", "access_token" in tok)
