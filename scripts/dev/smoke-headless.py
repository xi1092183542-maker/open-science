"""Start the built runtime with disposable state; never call a model provider."""
import argparse
import json
import os
from pathlib import Path
import socket
import subprocess
import time
import urllib.error
import urllib.request

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("binary", type=Path)
parser.add_argument("test_root", type=Path)
args = parser.parse_args()
binary = args.binary.resolve()
root = args.test_root.resolve()
root.mkdir(parents=True, exist_ok=False)
workspace = root / "workspace"
workspace.mkdir()
state = root / "state"
(state / "runtime").mkdir(parents=True)
(state / "runtime/base-workspace.txt").write_text(str(workspace), encoding="utf8")
with socket.socket() as sock:
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]
token = "synthetic-local-smoke-token"
env = os.environ.copy()
# Do not inherit model credentials into a no-model startup check.
for key in list(env):
    if key.endswith(("_API_KEY", "_AUTH_TOKEN")) or key in ("OPENCODE_CONFIG", "OPENCODE_CONFIG_CONTENT", "OPENCODE_CONFIG_DIR", "OSD_STATE_DIR"):
        env.pop(key)
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
def request(path, auth=True):
    req = urllib.request.Request(f"http://127.0.0.1:{port}{path}")
    if auth:
        req.add_header("Authorization", "Bearer " + token)
    with opener.open(req, timeout=10) as response:
        return response.read()

with (root / "server.log").open("wb") as log:
    child = subprocess.Popen([str(binary), "server", "--state-dir", str(state),
                              "--resources", str(binary.parent), "--workspace", str(workspace),
                              "--port", str(port), "--token", token, "--mode", "read-only"],
                             cwd=workspace, env=env, stdout=log, stderr=subprocess.STDOUT,
                             creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0)
    try:
        deadline = time.monotonic() + 90
        while True:
            if child.poll() is not None:
                raise RuntimeError(f"server exited {child.returncode}; inspect {root / 'server.log'}")
            try:
                health = json.loads(request("/v1/health", auth=False))
                break
            except (OSError, urllib.error.URLError):
                if time.monotonic() >= deadline:
                    raise TimeoutError("runtime did not become healthy within 90 seconds")
                time.sleep(1)
        assert health["ok"] is True
        who = json.loads(request("/v1/whoami"))
        assert Path(who["directory"]).resolve() == workspace
        assert who["mode"] == "read-only"
        sessions = json.loads(request("/v1/sessions"))
        assert isinstance(sessions, list)
        try:
            request("/v1/whoami", auth=False)
            raise AssertionError("unauthenticated API access succeeded")
        except urllib.error.HTTPError as error:
            assert error.code == 401
        result = {"health": True, "isolated_workspace": True, "read_only": True,
                  "session_api": True, "unauthenticated_api_rejected": True,
                  "model_calls": 0, "shutdown": "test-owned process tree terminated by harness"}
        (root / "result.json").write_text(json.dumps(result, indent=2) + "\n")
        print(json.dumps(result))
    finally:
        if child.poll() is None:
            if os.name == "nt":
                subprocess.run(["taskkill", "/PID", str(child.pid), "/T", "/F"], check=True,
                               stdout=subprocess.DEVNULL, creationflags=subprocess.CREATE_NO_WINDOW)
            else:
                child.terminate()
            child.wait(timeout=15)
