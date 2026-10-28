#!/usr/bin/env python3
"""Phase 0 API spike: check the Portainer REST API against a real instance.

Uses only the Python standard library (the python3 that ships with the Xcode
command line tools is enough).

    export PORTAINER_URL=https://portainer.your-tailnet.ts.net
    export PORTAINER_TOKEN=ptr_...

    # Read-only: version, environments, stacks, containers. Writes sanitized
    # JSON to spike-output/ and prints a summary.
    python3 scripts/portainer_spike.py inspect

    # Redeploys one Git stack. This recreates its containers, so use a throwaway
    # stack. --confirm-name must equal the stack's name.
    python3 scripts/portainer_spike.py redeploy --stack-id 12 --confirm-name spike-test

The token is read only from the environment and is never printed or written.
Review spike-output/ by hand before you commit anything from it as a test fixture.
"""

import argparse
import json
import os
import re
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

OUT_DIR = "spike-output"
COMPOSE_STACK_TYPE = 2
STACK_STATUS = {1: "active", 2: "inactive", 3: "deploying", 4: "error"}

SECRET_KEYS = {"password", "username", "token", "apikey", "secret", "jwt", "tlscacert", "tlscert", "tlskey"}
URL_KEYS = {"url", "publicurl", "repositoryurl"}
IPV4 = re.compile(r"\b(?:\d{1,3}\.){3}\d{1,3}\b")


class Spike:
    def __init__(self, base_url, token):
        self.base_url = base_url.rstrip("/")
        self.host = urllib.parse.urlparse(self.base_url).hostname or ""
        self.token = token
        self.ssl = ssl.create_default_context()

    def call(self, method, path, query=None, body=None, timeout=30):
        """Returns (status, parsed JSON or text, seconds). Raises SystemExit on transport errors."""
        url = self.base_url + path
        if query:
            url += "?" + urllib.parse.urlencode(query)
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(url, data=data, method=method)
        req.add_header("X-API-Key", self.token)
        req.add_header("Accept", "application/json")
        if data is not None:
            req.add_header("Content-Type", "application/json")
        start = time.monotonic()
        try:
            with urllib.request.urlopen(req, timeout=timeout, context=self.ssl) as resp:
                status, raw = resp.status, resp.read()
        except urllib.error.HTTPError as e:
            status, raw = e.code, e.read()
        except urllib.error.URLError as e:
            reason = e.reason
            if isinstance(reason, ssl.SSLCertVerificationError):
                sys.exit(f"TLS certificate rejected for {self.host}: {reason.verify_message}. "
                         "A self-signed certificate (Portainer's default on :9443) will also be "
                         "rejected by iOS; see docs/api-notes.md.")
            sys.exit(f"Cannot reach {self.host}: {reason}")
        except TimeoutError:
            sys.exit(f"{method} {path} timed out after {timeout}s")
        elapsed = time.monotonic() - start
        text = raw.decode("utf-8", errors="replace")
        try:
            parsed = json.loads(text) if text else None
        except json.JSONDecodeError:
            parsed = text
        return status, parsed, elapsed

    def get(self, path, query=None):
        status, data, _ = self.call("GET", path, query)
        if status != 200:
            sys.exit(f"GET {path} -> HTTP {status}: {error_message(data)}")
        return data

    def containers(self, endpoint_id, project):
        filters = json.dumps({"label": [f"com.docker.compose.project={project}"]})
        return self.get(f"/api/endpoints/{endpoint_id}/docker/containers/json",
                        {"all": "true", "filters": filters})

    def save(self, name, data):
        os.makedirs(OUT_DIR, exist_ok=True)
        path = os.path.join(OUT_DIR, name)
        with open(path, "w") as f:
            json.dump(self.sanitize(data), f, indent=2, sort_keys=True)
            f.write("\n")
        return path

    def sanitize(self, value, key=""):
        k = key.lower()
        if isinstance(value, dict):
            out = {}
            for child_key, child in value.items():
                if child_key == "DockerSnapshotRaw":
                    out[child_key] = "<removed>"
                elif child_key.lower() in SECRET_KEYS and child not in (None, "", {}, []):
                    out[child_key] = "<redacted>"
                else:
                    out[child_key] = self.sanitize(child, child_key)
            return out
        if isinstance(value, list):
            if k == "env":
                return [redact_env(item) for item in value]
            return [self.sanitize(item, key) for item in value]
        if isinstance(value, str):
            if k in URL_KEYS and value and not value.startswith("unix://"):
                scheme = urllib.parse.urlparse(value).scheme or "https"
                return f"{scheme}://redacted.example.com/redacted"
            if self.host:
                value = value.replace(self.host, "portainer.example.ts.net")
            return IPV4.sub("192.0.2.1", value)
        return value


def redact_env(item):
    if isinstance(item, dict):  # Portainer stack env: {"name": ..., "value": ...}
        return {**item, "value": "<redacted>"} if "value" in item else item
    if isinstance(item, str):  # Docker container env: "NAME=value"
        return item.split("=", 1)[0] + "=<redacted>"
    return "<redacted>"


def error_message(data):
    if isinstance(data, dict):
        return " / ".join(str(data[k]) for k in ("message", "details") if data.get(k)) or json.dumps(data)
    return str(data)[:500]


def stack_summary(stack):
    git = stack.get("GitConfig") or {}
    deployed = stack.get("CurrentDeploymentInfo") or {}
    commit = git.get("ConfigHash") or deployed.get("ConfigHash") or ""
    updated = stack.get("UpdateDate") or 0
    when = time.strftime("%Y-%m-%d %H:%M", time.localtime(updated)) if updated else "-"
    status = stack.get("Status")
    return (f"  #{stack.get('Id')} {stack.get('Name')!r} type={stack.get('Type')} "
            f"endpoint={stack.get('EndpointId')} status={status}({STACK_STATUS.get(status, '?')}) "
            f"git={'yes' if git else 'no'} ref={git.get('ReferenceName', '-')} "
            f"commit={commit[:7] or '-'} updated={when}")


def container_summary(containers):
    running = sum(1 for c in containers if c.get("State") == "running")
    return f"{running}/{len(containers)} running"


def fetch_version(spike):
    for path in ("/api/system/version", "/api/status"):
        status, data, _ = spike.call("GET", path)
        if status == 200:
            return path, data
    return None, None


def cmd_inspect(spike):
    path, version = fetch_version(spike)
    if version is not None:
        spike.save("version.json", version)
        shown = version.get("ServerVersion") or version.get("Version") if isinstance(version, dict) else version
        print(f"Portainer version ({path}): {shown}")

    endpoints = spike.get("/api/endpoints")
    print(f"\nWrote {spike.save('endpoints.json', endpoints)}")
    print("Environments:")
    for e in endpoints:
        print(f"  #{e.get('Id')} {e.get('Name')!r} type={e.get('Type')} status={e.get('Status')}")

    stacks = spike.get("/api/stacks")
    print(f"\nWrote {spike.save('stacks.json', stacks)}")
    print("Stacks:")
    for s in stacks:
        print(stack_summary(s))
    if stacks:
        print("\nTop-level stack keys:", ", ".join(sorted(stacks[0].keys())))

    git_stacks = [s for s in stacks if s.get("GitConfig")]
    if git_stacks:
        detail = spike.get(f"/api/stacks/{git_stacks[0]['Id']}")
        print(f"\nWrote {spike.save('stack-detail.json', detail)}")
        print("GitConfig keys:", ", ".join(sorted((detail.get("GitConfig") or {}).keys())))

    print("\nContainers per Compose stack:")
    for s in stacks:
        if s.get("Type") != COMPOSE_STACK_TYPE:
            continue
        containers = spike.containers(s["EndpointId"], s["Name"])
        spike.save(f"containers-{s['Id']}.json", containers)
        print(f"  #{s['Id']} {s['Name']!r}: {container_summary(containers)}")


def redeploy_body(stack, pull, prune):
    """Body that keeps the stack's current branch, env vars and saved Git credentials.

    Portainer 2.39 overwrites ReferenceName and Env with whatever is sent (empty
    included), and only uses stored Git credentials when RepositoryAuthentication
    is true. Newer versions ignore empty values, so this body is safe for both.
    """
    git = stack.get("GitConfig") or {}
    auth = git.get("Authentication") or {}
    body = {
        "RepositoryReferenceName": git.get("ReferenceName", ""),
        "Env": stack.get("Env") or [],
        "Prune": prune,
        "RepullImageAndRedeploy": pull,
        "PullImage": pull,  # deprecated since 2.36, still read by older servers
        "RepositoryAuthentication": bool(auth),
    }
    if auth:
        body["RepositoryUsername"] = auth.get("Username", "")
        body["RepositoryPassword"] = ""  # empty keeps the password Portainer has stored
        if "AuthorizationType" in auth:
            body["RepositoryAuthorizationType"] = auth["AuthorizationType"]
    return body


def cmd_redeploy(spike, stack_id, confirm_name, pull, prune, wait):
    stack = spike.get(f"/api/stacks/{stack_id}")
    if stack.get("Name") != confirm_name:
        sys.exit(f"Stack #{stack_id} is named {stack.get('Name')!r}, not {confirm_name!r}. Nothing sent.")
    if not stack.get("GitConfig"):
        sys.exit(f"Stack {confirm_name!r} is not Git-based. Nothing sent.")
    print("Before:", stack_summary(stack))
    endpoint_id = stack["EndpointId"]
    before = spike.containers(endpoint_id, stack["Name"])
    print("Containers before:", container_summary(before))

    body = redeploy_body(stack, pull, prune)
    print("\nPUT /api/stacks/%s/git/redeploy?endpointId=%s" % (stack_id, endpoint_id))
    print("Body (env values redacted):", json.dumps(spike.sanitize(body), indent=2))

    status, data, elapsed = spike.call("PUT", f"/api/stacks/{stack_id}/git/redeploy",
                                       {"endpointId": endpoint_id}, body, timeout=600)
    print(f"\nHTTP {status} after {elapsed:.1f}s")
    if status != 200:
        spike.save("redeploy-error.json", data)
        sys.exit(f"Redeploy failed: {error_message(data)}")
    print(f"Wrote {spike.save('redeploy-response.json', data)}")
    print("Response:", stack_summary(data))

    # 2.39 answers after the deploy finishes; newer versions answer with
    # status=deploying and finish in the background, so poll either way.
    deadline = time.monotonic() + wait
    while True:
        current = spike.get(f"/api/stacks/{stack_id}")
        containers = spike.containers(endpoint_id, stack["Name"])
        print(f"  [{time.strftime('%H:%M:%S')}] status={STACK_STATUS.get(current.get('Status'), current.get('Status'))} "
              f"containers={container_summary(containers)}")
        if current.get("Status") != 3 or time.monotonic() > deadline:
            break
        time.sleep(3)

    spike.save("redeploy-after-stack.json", current)
    spike.save("redeploy-after-containers.json", containers)
    print("\nAfter:", stack_summary(current))
    for entry in current.get("DeploymentStatus") or []:
        print(f"  deployment status {entry.get('Status')} at {entry.get('Time')}: {entry.get('Message', '')}")
    env_before = [e.get("name") for e in stack.get("Env") or []]
    env_after = [e.get("name") for e in current.get("Env") or []]
    print("Env names kept:", env_before == env_after, env_after)
    print("Commit before/after:", (stack.get("GitConfig") or {}).get("ConfigHash", "")[:7],
          "->", (current.get("GitConfig") or {}).get("ConfigHash", "")[:7])


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("inspect", help="read-only calls; writes sanitized JSON to spike-output/")
    rd = sub.add_parser("redeploy", help="pull and redeploy one Git stack (recreates containers)")
    rd.add_argument("--stack-id", type=int, required=True)
    rd.add_argument("--confirm-name", required=True, help="must equal the stack's name")
    rd.add_argument("--no-pull", action="store_true", help="do not re-pull images")
    rd.add_argument("--prune", action="store_true", help="prune services no longer in the compose file")
    rd.add_argument("--wait", type=int, default=300, help="seconds to poll while status is deploying")
    args = parser.parse_args()

    url, token = os.environ.get("PORTAINER_URL"), os.environ.get("PORTAINER_TOKEN")
    if not url or not token:
        sys.exit("Set PORTAINER_URL and PORTAINER_TOKEN in the environment.")
    spike = Spike(url, token)

    if args.command == "inspect":
        cmd_inspect(spike)
    else:
        cmd_redeploy(spike, args.stack_id, args.confirm_name, not args.no_pull, args.prune, args.wait)


if __name__ == "__main__":
    main()
