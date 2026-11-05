#!/usr/bin/env python3
"""mock-cloudflare.py - a small stand-in for the parts of the Cloudflare REST API that
src/vylaris/setup-repo-host.sh uses. Python 3 standard library only, state in memory.

API (base path /client/v4, "Authorization: Bearer <token>" is checked):
  GET    /zones?name=                                   (exact name)
  GET    /accounts/{a}/cfd_tunnel?name=&is_deleted=false (set tunnel_list_ignores_name to get all tunnels)
  POST   /accounts/{a}/cfd_tunnel                       {"name", "config_src"}
  GET    /accounts/{a}/cfd_tunnel/{id}                  "connections" is always [] (deprecated at Cloudflare);
                                                        "status" says healthy/degraded/inactive
  DELETE /accounts/{a}/cfd_tunnel/{id}
  DELETE /accounts/{a}/cfd_tunnel/{id}/connections
  GET    /accounts/{a}/cfd_tunnel/{id}/configurations
  PUT    /accounts/{a}/cfd_tunnel/{id}/configurations   {"config": {"ingress": [...]}}
  GET    /accounts/{a}/cfd_tunnel/{id}/token
  GET    /zones/{z}/dns_records?name.exact=             ONLY name.exact filters. A bare name=, or no filter,
                                                        returns EVERY record of the zone (like an API that
                                                        does not know the parameter), so a script that
                                                        relies on a filter it does not send is caught.
  GET    /zones/{z}/dns_records/{id}
  POST   /zones/{z}/dns_records
  PATCH  /zones/{z}/dns_records/{id}
  DELETE /zones/{z}/dns_records/{id}
Answers look like Cloudflare's: {"success": bool, "errors": [{"code", "message"}], "messages": [],
"result": ...}.

Test control (no authentication), all JSON:
  POST /_mock/reset                      back to the default state
  POST /_mock/set                        merge settings, keys:
      token        the valid API token
      wrong_token_status/wrong_token_code   what a wrong token gets (default 401 / 9109)
      perms        list of granted permissions (default "tunnel", "dns", "zone"): "tunnel" and "dns" are the
                   Edit permissions (read and write), "tunnel_read" and "dns_read" allow only GET requests
                   (a POST/PUT/PATCH/DELETE then answers 403, like Cloudflare), "zone" is Zone Read
      zones        list of {"name"}; replaces the zones (default one zone, "vylaris.test")
      dns          list of records {"type","name","content","proxied"} to add
      tunnels      list of {"name","config_src","ingress":[{"hostname","service"}],"config":{...}} to add
                   (config: a raw configuration, for example {"warp-routing": {"enabled": true}})
      fail         list of {"method","contains","status","times"}: answer the matching request
                   with that HTTP status (and a Cloudflare error body) this many times.
                   Optional "retry_after": seconds (a number or a string such as "0000000002"), sent as a
                   Retry-After header (for 429).
                   Optional "apply": true: the request IS carried out, only the answer is
                   replaced by the error (a record created although the answer was a 500).
      dns_ignore_filter          true: the DNS list ignores name.exact too (returns every record)
      tunnel_list_ignores_name   true: the tunnel list ignores name (returns every tunnel)
  POST /_mock/connect {"tunnel_id", "status"}   a cloudflared connects: status "healthy" (default)
                                         or "degraded"
  POST /_mock/disconnect {"tunnel_id"}
  GET  /_mock/state                      zones, tunnels, dns records, the list of calls

Edge (optional): --edge-https-port / --edge-http-port start a server that plays Cloudflare's edge:
a request for a host name whose tunnel is connected is forwarded to the ingress service of the
tunnel (like cloudflared does), otherwise it answers 530 (error 1033).
"""
import argparse
import base64
import json
import ssl
import sys
import threading
import urllib.error
import urllib.request
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

LOCK = threading.Lock()
S = {}
ARGS = None


def new_id():
    return uuid.uuid4().hex


def reset():
    S.clear()
    acc = "a" * 8 + new_id()[:24]
    S.update(
        token=ARGS.token,
        wrong_token_status=401,
        wrong_token_code=9109,
        perms={"tunnel", "dns", "zone"},
        account=acc,
        zones={},
        tunnels={},
        dns={},
        fail=[],
        calls=[],
        dns_ignore_filter=False,
        tunnel_list_ignores_name=False,
    )
    add_zone(ARGS.zone)


def add_zone(name):
    zid = new_id()
    S["zones"][zid] = {
        "id": zid,
        "name": name,
        "status": "active",
        "account": {"id": S["account"], "name": "Test account"},
    }


def add_tunnel(name, config_src="cloudflare", ingress=None, config=None):
    tid = str(uuid.uuid4())
    S["tunnels"][tid] = {
        "id": tid,
        "account_tag": S["account"],
        "name": name,
        "created_at": "2026-01-01T00:00:00Z",
        "deleted_at": None,
        "tun_type": "cfd_tunnel",
        "config_src": config_src,
        "remote_config": config_src == "cloudflare",
        "secret": base64.b64encode(new_id().encode()).decode(),
        "connected": False,
        "status": "inactive",
        "ingress": ingress,
        "config": config,  # a raw configuration (for example warp-routing), else built from ingress
        "version": 0 if ingress is None and config is None else 1,
    }
    return S["tunnels"][tid]


def tunnel_view(t):
    return {
        "id": t["id"],
        "account_tag": t["account_tag"],
        "name": t["name"],
        "created_at": t["created_at"],
        "deleted_at": t["deleted_at"],
        "tun_type": t["tun_type"],
        "config_src": t["config_src"],
        "remote_config": t["remote_config"],
        "status": t["status"] if t["connected"] else "inactive",
        # deprecated at Cloudflare: always empty here, the state is in "status"
        "connections": [],
    }


def add_dns(zone_id, rec):
    rid = new_id()
    r = {
        "id": rid,
        "zone_id": zone_id,
        "type": rec.get("type", "A"),
        "name": rec["name"],
        "content": rec["content"],
        "proxied": bool(rec.get("proxied", False)),
        "ttl": rec.get("ttl", 1),
        "comment": rec.get("comment"),
    }
    S["dns"][rid] = r
    return r


class Handler(BaseHTTPRequestHandler):
    server_version = "mock-cloudflare"
    protocol_version = "HTTP/1.1"
    muted = False

    def log_message(self, fmt, *args):  # never log headers (the token is in one)
        if ARGS.log:
            with open(ARGS.log, "a") as f:
                f.write("%s %s\n" % (self.address_string(), fmt % args))

    # ---- helpers -----------------------------------------------------------------------------
    def body_json(self):
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n) if n else b""
        if not raw:
            return {}
        try:
            return json.loads(raw)
        except ValueError:
            return {}

    def send_json(self, status, obj, headers=None):
        if self.muted:  # the request was carried out, its answer is replaced by an error
            return
        data = json.dumps(obj).encode()
        self.send_response(status)
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def ok(self, result, status=200, info=None):
        o = {"success": True, "errors": [], "messages": [], "result": result}
        if info:
            o["result_info"] = info
        self.send_json(status, o)

    def err(self, status, code, message, headers=None):
        self.send_json(
            status,
            {"success": False, "errors": [{"code": code, "message": message}], "messages": [], "result": None},
            headers,
        )

    def need(self, perm, method="GET"):
        # "tunnel" and "dns" are the Edit (write) permissions and include reading; "tunnel_read" and
        # "dns_read" allow only GET; "zone" is Zone Read. A write with a read-only token is a 403, like at Cloudflare.
        write = method != "GET"
        ok = perm in S["perms"] or (not write and perm + "_read" in S["perms"])
        if not ok:
            self.err(403, 10000, "Authentication error")
            return False
        return True

    # ---- dispatch ----------------------------------------------------------------------------
    def handle_any(self, method):
        u = urlparse(self.path)
        q = {k: v[0] for k, v in parse_qs(u.query).items()}
        path = u.path
        if path.startswith("/_mock/"):
            return self.control(method, path, q)
        with LOCK:
            S["calls"].append("%s %s" % (method, self.path))
            if not path.startswith("/client/v4/"):
                return self.err(404, 7003, "No route for that URI")
            path = path[len("/client/v4") :]
            auth = self.headers.get("Authorization", "")
            if auth != "Bearer " + S["token"]:
                return self.err(S["wrong_token_status"], S["wrong_token_code"], "Invalid access token")
            body = self.body_json() if method in ("POST", "PUT", "PATCH") else {}
            for rule in S["fail"]:
                if rule["times"] > 0 and rule["method"] == method and rule["contains"] in self.path:
                    rule["times"] -= 1
                    if rule.get("apply"):
                        self.muted = True
                        try:
                            self.route(method, path, q, body)
                        finally:
                            self.muted = False
                    hdrs = {"Retry-After": str(rule["retry_after"])} if rule.get("retry_after") is not None else None
                    return self.err(rule["status"], 1000 + rule["status"], "Simulated server error", hdrs)
            return self.route(method, path, q, body)

    def route(self, method, path, q, body):
        parts = [p for p in path.split("/") if p]
        # zones
        if parts == ["zones"] and method == "GET":
            if not self.need("zone"):
                return
            res = [z for z in S["zones"].values() if "name" not in q or z["name"] == q["name"]]
            return self.ok(res, info={"count": len(res), "total_count": len(res)})
        # tunnels
        if len(parts) >= 3 and parts[0] == "accounts" and parts[2] == "cfd_tunnel":
            if not self.need("tunnel", method):
                return
            if parts[1] != S["account"]:
                return self.err(403, 10000, "Authentication error")
            return self.tunnels(method, parts[3:], q, body)
        # dns
        if len(parts) >= 3 and parts[0] == "zones" and parts[2] == "dns_records":
            if not self.need("dns", method):
                return
            if parts[1] not in S["zones"]:
                return self.err(404, 7003, "Could not route to /zones/%s, perhaps your object identifier is invalid?" % parts[1])
            return self.dns(method, parts[1], parts[3:], q, body)
        return self.err(404, 7003, "No route for that URI")

    def tunnels(self, method, rest, q, body):
        if not rest:
            if method == "GET":
                res = [
                    tunnel_view(t)
                    for t in S["tunnels"].values()
                    if t["deleted_at"] is None
                    and ("name" not in q or S["tunnel_list_ignores_name"] or t["name"] == q["name"])
                ]
                return self.ok(res)
            if method == "POST":
                name = body.get("name", "")
                if not name:
                    return self.err(400, 1001, "Invalid tunnel name")
                if any(t["name"] == name and t["deleted_at"] is None for t in S["tunnels"].values()):
                    return self.err(409, 1013, "A tunnel with this name already exists. Please use another name or delete the existing tunnel.")
                t = add_tunnel(name, body.get("config_src", "local"))
                v = tunnel_view(t)
                v["token"] = t["secret"]
                return self.ok(v)
            return self.err(405, 10405, "Method not allowed")
        tid = rest[0]
        t = S["tunnels"].get(tid)
        if t is None or t["deleted_at"] is not None:
            return self.err(404, 1003, "Tunnel not found")
        sub = rest[1:]
        if not sub:
            if method == "GET":
                return self.ok(tunnel_view(t))
            if method == "DELETE":
                if t["connected"]:
                    return self.err(400, 1022, "Cannot delete a tunnel with active connections")
                t["deleted_at"] = "2026-01-02T00:00:00Z"
                return self.ok(tunnel_view(t))
        elif sub == ["connections"] and method == "DELETE":
            t["connected"] = False
            return self.ok({})
        elif sub == ["configurations"]:
            if method == "GET":
                if t["config"] is not None:
                    cfg = t["config"]
                else:
                    cfg = {"ingress": t["ingress"]} if t["ingress"] is not None else None
                return self.ok({"tunnel_id": tid, "version": t["version"], "config": cfg, "source": "cloudflare"})
            if method == "PUT":
                cfg = body.get("config")
                ing = (cfg or {}).get("ingress")
                if not isinstance(ing, list) or not ing or "hostname" in ing[-1]:
                    return self.err(400, 1056, "Invalid ingress: the last rule must be a catch-all")
                t["ingress"] = ing
                t["config"] = None
                t["version"] += 1
                return self.ok({"tunnel_id": tid, "version": t["version"], "config": cfg})
        elif sub == ["token"] and method == "GET":
            tok = base64.b64encode(json.dumps({"a": S["account"], "t": tid, "s": t["secret"]}).encode()).decode()
            return self.ok(tok)
        return self.err(405, 10405, "Method not allowed")

    def dns(self, method, zid, rest, q, body):
        if not rest:
            if method == "GET":
                res = [
                    r
                    for r in S["dns"].values()
                    if r["zone_id"] == zid
                    and (S["dns_ignore_filter"] or "name.exact" not in q or r["name"] == q["name.exact"])
                ]
                return self.ok(res, info={"count": len(res), "total_count": len(res), "page": 1, "per_page": 100, "total_pages": 1})
            if method == "POST":
                if body.get("type") in ("A", "AAAA", "CNAME") and any(
                    r["name"] == body.get("name") and r["type"] in ("A", "AAAA", "CNAME") for r in S["dns"].values()
                ):
                    return self.err(400, 81053, "An A, AAAA, or CNAME record with that host already exists.")
                if not body.get("name") or not body.get("content"):
                    return self.err(400, 9005, "Content for CNAME record is invalid.")
                return self.ok(add_dns(zid, body))
            return self.err(405, 10405, "Method not allowed")
        r = S["dns"].get(rest[0])
        if r is None or r["zone_id"] != zid:
            return self.err(404, 81044, "Record does not exist.")
        if method == "GET":
            return self.ok(r)
        if method == "PATCH":
            # like Cloudflare: a CNAME cannot stand next to an A/AAAA/CNAME record of the same name
            if body.get("type", r["type"]) in ("A", "AAAA", "CNAME") and any(
                o["id"] != r["id"] and o["name"] == r["name"] and o["type"] in ("A", "AAAA", "CNAME") and "CNAME" in (o["type"], body.get("type", r["type"]))
                for o in S["dns"].values()
            ):
                return self.err(400, 81053, "An A, AAAA, or CNAME record with that host already exists.")
            for k in ("type", "name", "content", "proxied", "ttl", "comment"):
                if k in body:
                    r[k] = body[k]
            return self.ok(r)
        if method == "DELETE":
            del S["dns"][r["id"]]
            return self.ok({"id": r["id"]})
        return self.err(405, 10405, "Method not allowed")

    # ---- test control ------------------------------------------------------------------------
    def control(self, method, path, q):
        body = self.body_json() if method == "POST" else {}
        with LOCK:
            if path == "/_mock/reset":
                reset()
                return self.ok({})
            if path == "/_mock/state":
                st = {
                    "zones": list(S["zones"].values()),
                    "tunnels": [tunnel_view(t) | {"ingress": t["ingress"]} for t in S["tunnels"].values()],
                    "dns": list(S["dns"].values()),
                    "calls": S["calls"],
                    "account": S["account"],
                }
                return self.ok(st)
            if path == "/_mock/connect" or path == "/_mock/disconnect":
                t = S["tunnels"].get(body.get("tunnel_id", ""))
                if t is None:
                    return self.err(404, 1003, "Tunnel not found")
                if path.endswith("connect") and not path.endswith("disconnect"):
                    t["connected"] = True
                    t["status"] = body.get("status", "healthy")
                else:
                    t["connected"] = False
                return self.ok({})
            if path == "/_mock/set":
                for k in ("token", "wrong_token_status", "wrong_token_code", "dns_ignore_filter", "tunnel_list_ignores_name"):
                    if k in body:
                        S[k] = body[k]
                if "perms" in body:
                    S["perms"] = set(body["perms"])
                if "zones" in body:
                    S["zones"] = {}
                    for z in body["zones"]:
                        add_zone(z["name"])
                zone_ids = {z["name"]: zid for zid, z in S["zones"].items()}
                for rec in body.get("dns", []):
                    zid = zone_ids.get(rec.get("zone"), next(iter(S["zones"])))
                    add_dns(zid, rec)
                for t in body.get("tunnels", []):
                    add_tunnel(t["name"], t.get("config_src", "cloudflare"), t.get("ingress"), t.get("config"))
                for rule in body.get("fail", []):
                    S["fail"].append(
                        {
                            "method": rule.get("method", "GET"),
                            "contains": rule["contains"],
                            "status": rule.get("status", 500),
                            "times": rule.get("times", 1),
                            "retry_after": rule.get("retry_after"),
                            "apply": rule.get("apply", False),
                        }
                    )
                return self.ok({})
        return self.err(404, 7003, "No such control path")

    def do_GET(self):
        self.handle_any("GET")

    def do_POST(self):
        self.handle_any("POST")

    def do_PUT(self):
        self.handle_any("PUT")

    def do_PATCH(self):
        self.handle_any("PATCH")

    def do_DELETE(self):
        self.handle_any("DELETE")


class Edge(BaseHTTPRequestHandler):
    """Plays Cloudflare's edge plus cloudflared: forwards to the ingress service of a connected tunnel."""

    server_version = "mock-edge"
    protocol_version = "HTTP/1.0"

    def log_message(self, fmt, *args):
        if ARGS.log:
            with open(ARGS.log, "a") as f:
                f.write("edge %s %s\n" % (self.address_string(), fmt % args))

    def target(self, host):
        with LOCK:
            for t in S["tunnels"].values():
                if t["deleted_at"] is not None or not t["ingress"]:
                    continue
                for rule in t["ingress"]:
                    if rule.get("hostname") == host:
                        return bool(t["connected"]), rule.get("service")
        return False, None

    def reply(self, status, body, headers=None):
        self.send_response(status)
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def handle_any(self):
        host = (self.headers.get("Host") or "").split(":")[0]
        connected, service = self.target(host)
        if not connected or not service:
            return self.reply(530, b"error code: 1033", {"Content-Type": "text/plain"})
        req = urllib.request.Request(service + self.path, method=self.command)
        req.add_header("Host", host)
        if self.headers.get("Authorization"):
            req.add_header("Authorization", self.headers["Authorization"])
        try:
            with urllib.request.urlopen(req, timeout=20) as r:
                body = r.read()
                self.reply(r.status, body, {"Content-Type": r.headers.get("Content-Type", "application/octet-stream")})
        except urllib.error.HTTPError as e:
            self.reply(e.code, e.read(), {"Content-Type": e.headers.get("Content-Type", "text/plain")})
        except Exception:
            self.reply(502, b"bad gateway")

    do_GET = do_HEAD = handle_any


def serve(server):
    t = threading.Thread(target=server.serve_forever, daemon=True)
    t.start()


def main():
    global ARGS
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port", type=int, default=8787)
    ap.add_argument("--token", default="mock-valid-token-0123456789abcdef")
    ap.add_argument("--zone", default="vylaris.test")
    ap.add_argument("--log", default="")
    ap.add_argument("--edge-http-port", type=int, default=0)
    ap.add_argument("--edge-https-port", type=int, default=0)
    ap.add_argument("--cert", default="")
    ap.add_argument("--key", default="")
    ARGS = ap.parse_args()
    reset()
    api = ThreadingHTTPServer(("127.0.0.1", ARGS.port), Handler)
    if ARGS.edge_http_port:
        serve(ThreadingHTTPServer(("127.0.0.1", ARGS.edge_http_port), Edge))
    if ARGS.edge_https_port:
        srv = ThreadingHTTPServer(("127.0.0.1", ARGS.edge_https_port), Edge)
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(ARGS.cert, ARGS.key)
        srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
        serve(srv)
    print("mock cloudflare listening on 127.0.0.1:%d" % ARGS.port, flush=True)
    try:
        api.serve_forever()
    except KeyboardInterrupt:
        sys.exit(0)


if __name__ == "__main__":
    main()
