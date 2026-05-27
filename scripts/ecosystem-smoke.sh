#!/usr/bin/env bash
# End-to-end smoke test for the local Froggy ecosystem:
# Froggy daemon socket -> FroggyKit -> froggy-mcp -> froggy-sre dry-run.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOME_DIR="${HOME}"

FROGGYKIT_REPO="${FROGGYKIT_REPO:-$HOME_DIR/FroggyKit}"
FROGGY_MCP_REPO="${FROGGY_MCP_REPO:-$HOME_DIR/froggy-mcp}"
FROGGY_SRE_REPO="${FROGGY_SRE_REPO:-$HOME_DIR/froggy-sre}"
FROGGY_IPC_SOCKET="${FROGGY_IPC_SOCKET:-$HOME_DIR/Library/Application Support/Froggy/froggy.sock}"

BUILD_MISSING="${BUILD_MISSING:-1}"
TMP_ROOT=""

cleanup() {
    if [[ -n "$TMP_ROOT" && -d "$TMP_ROOT" ]]; then
        rm -rf "$TMP_ROOT"
    fi
}
trap cleanup EXIT

pass() { printf 'PASS  %s\n' "$*"; }
warn() { printf 'WARN  %s\n' "$*" >&2; }
fail() { printf 'FAIL  %s\n' "$*" >&2; exit 1; }
info() { printf 'INFO  %s\n' "$*"; }

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || fail "missing command: $1"
}

repo_commit() {
    local dir="$1"
    git -C "$dir" rev-parse --short HEAD 2>/dev/null || printf 'unknown'
}

repo_dirty_marker() {
    local dir="$1"
    if [[ -n "$(git -C "$dir" status --short 2>/dev/null || true)" ]]; then
        printf ' dirty'
    fi
}

require_repo() {
    local name="$1"
    local dir="$2"
    [[ -d "$dir/.git" ]] || fail "$name repo not found at $dir"
    pass "$name repo: $dir @ $(repo_commit "$dir")$(repo_dirty_marker "$dir")"
}

ensure_swift_binary() {
    local name="$1"
    local repo="$2"
    local binary="$3"
    if [[ -x "$binary" ]]; then
        pass "$name binary: $binary"
        return
    fi
    [[ "$BUILD_MISSING" == "1" ]] || fail "$name binary missing: $binary"
    info "building $name because binary is missing..."
    swift build -c release --package-path "$repo" >/dev/null
    [[ -x "$binary" ]] || fail "$name build completed but binary still missing: $binary"
    pass "$name binary built: $binary"
}

require_cmd git
require_cmd swift
require_cmd python3

require_repo "Froggy" "$ROOT"
require_repo "FroggyKit" "$FROGGYKIT_REPO"
require_repo "froggy-mcp" "$FROGGY_MCP_REPO"
require_repo "froggy-sre" "$FROGGY_SRE_REPO"

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/froggy-ecosystem-smoke.XXXXXX")"

MCP_BIN="${FROGGY_MCP_BIN:-$FROGGY_MCP_REPO/.build/release/froggy-mcp}"
SRE_BIN="${FROGGY_SRE_BIN:-$FROGGY_SRE_REPO/.build/release/froggy-sre}"
ensure_swift_binary "froggy-mcp" "$FROGGY_MCP_REPO" "$MCP_BIN"
ensure_swift_binary "froggy-sre" "$FROGGY_SRE_REPO" "$SRE_BIN"

info "socket: $FROGGY_IPC_SOCKET"
python3 - "$FROGGY_IPC_SOCKET" <<'PY'
import json
import socket
import sys

path = sys.argv[1]
req = {"cmd": "status", "apiVersion": 1}
s = None
try:
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(5)
    s.connect(path)
    s.sendall(json.dumps(req).encode() + b"\n")
    buf = b""
    while b"\n" not in buf:
        chunk = s.recv(4096)
        if not chunk:
            break
        buf += chunk
except FileNotFoundError:
    raise SystemExit(
        f"FAIL  daemon socket not found: {path}\n"
        "      Start FroggyDaemon or set FROGGY_IPC_SOCKET."
    )
except ConnectionRefusedError:
    raise SystemExit(
        f"FAIL  daemon socket is stale or not accepting connections: {path}\n"
        "      Start/restart FroggyDaemon, or remove the stale socket."
    )
except PermissionError as e:
    raise SystemExit(
        f"FAIL  daemon socket permission denied: {path} ({e})\n"
        "      Run outside a sandbox or check socket ownership/mode."
    )
finally:
    if s is not None:
        try:
            s.close()
        except Exception:
            pass

if b"\n" not in buf:
    raise SystemExit("daemon returned no newline-terminated status response")
resp = json.loads(buf.split(b"\n", 1)[0])
if resp.get("ok") is not True:
    raise SystemExit(f"daemon status failed: {resp!r}")
print(
    "PASS  daemon raw IPC status: "
    f"apiVersion={resp.get('apiVersion')} "
    f"state={resp.get('coordinatorState')} "
    f"modelLoaded={resp.get('modelLoaded')}"
)
PY

KIT_SMOKE="$TMP_ROOT/FroggyKitSmoke"
mkdir -p "$KIT_SMOKE/Sources/FroggyKitSmoke"
cat > "$KIT_SMOKE/Package.swift" <<EOF
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FroggyKitSmoke",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "$FROGGYKIT_REPO"),
    ],
    targets: [
        .executableTarget(
            name: "FroggyKitSmoke",
            dependencies: [.product(name: "FroggyKit", package: "FroggyKit")]
        ),
    ]
)
EOF
cat > "$KIT_SMOKE/Sources/FroggyKitSmoke/main.swift" <<'EOF'
import Foundation
import FroggyKit

do {
    let client = FroggyClient()
    let responses = try client.send(FroggyRequest(cmd: "status"), timeoutSeconds: 5)
    guard let first = responses.first, first.ok == true else {
        throw FroggyClientError.daemon("status failed or empty response")
    }
    print("PASS  FroggyKit client status: modelLoaded=\(first.modelLoaded == true) kvCacheBits=\(first.kvCacheBits ?? -1)")
} catch {
    fputs("FAIL  FroggyKit client status failed: \(error)\n", stderr)
    exit(1)
}
EOF
FROGGY_IPC_SOCKET="$FROGGY_IPC_SOCKET" swift run --package-path "$KIT_SMOKE" -q FroggyKitSmoke

python3 - "$MCP_BIN" "$SRE_BIN" "$FROGGY_IPC_SOCKET" "$TMP_ROOT" <<'PY'
import json
import os
import select
import subprocess
import sys
import time

mcp_bin, sre_bin, socket_path, tmp_root = sys.argv[1:5]

def read_line(proc, timeout=10):
    deadline = time.time() + timeout
    while time.time() < deadline:
        ready, _, _ = select.select([proc.stdout], [], [], 0.1)
        if ready:
            line = proc.stdout.readline()
            if not line:
                raise RuntimeError("process closed stdout")
            return json.loads(line)
    raise TimeoutError("timed out waiting for JSON-RPC response")

def rpc(proc, method, params=None, id_=1, timeout=10):
    msg = {"jsonrpc": "2.0", "id": id_, "method": method}
    if params is not None:
        msg["params"] = params
    proc.stdin.write(json.dumps(msg) + "\n")
    proc.stdin.flush()
    return read_line(proc, timeout=timeout)

def start(bin_path, extra_env=None):
    env = os.environ.copy()
    env["FROGGY_IPC_SOCKET"] = socket_path
    if extra_env:
        env.update(extra_env)
    return subprocess.Popen(
        [bin_path],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env=env,
    )

def content_text(resp):
    result = resp.get("result") or {}
    content = result.get("content") or []
    return "\n".join(str(item.get("text", "")) for item in content if isinstance(item, dict))

def assert_tools(resp, expected):
    tools = (resp.get("result") or {}).get("tools") or []
    names = {tool.get("name") for tool in tools}
    missing = sorted(set(expected) - names)
    if missing:
        raise RuntimeError(f"missing tools: {missing}; got={sorted(names)}")
    return names

mcp = start(mcp_bin)
try:
    init = rpc(mcp, "initialize", id_=1)
    info = (init.get("result") or {}).get("serverInfo") or {}
    print(f"PASS  froggy-mcp initialize: {info.get('name')} {info.get('version')}")

    tools = rpc(mcp, "tools/list", id_=2)
    names = assert_tools(tools, ["froggy_status", "froggy_context", "froggy_pressure"])
    print(f"PASS  froggy-mcp tools/list: {len(names)} tools")

    status = rpc(mcp, "tools/call", {"name": "froggy_status", "arguments": {}}, id_=3)
    text = content_text(status)
    if "Froggy status" not in text:
        raise RuntimeError(f"unexpected froggy_status content: {text[:200]!r}")
    print("PASS  froggy-mcp -> daemon: froggy_status")
finally:
    mcp.terminate()
    try:
        mcp.wait(timeout=2)
    except subprocess.TimeoutExpired:
        mcp.kill()

sre_env = {
    "FROGGY_SRE_INCIDENTS_DIR": os.path.join(tmp_root, "sre-incidents"),
    "KUBECTL_PATH": os.path.join(tmp_root, "missing-kubectl"),
}
sre = start(sre_bin, sre_env)
try:
    init = rpc(sre, "initialize", id_=10)
    info = (init.get("result") or {}).get("serverInfo") or {}
    print(f"PASS  froggy-sre initialize: {info.get('name')} {info.get('version')}")

    tools = rpc(sre, "tools/list", id_=11)
    names = assert_tools(tools, ["sre_analyze", "sre_history"])
    print(f"PASS  froggy-sre tools/list: {len(names)} tools")

    incident = {
        "labels": {
            "alertname": "FroggyEcosystemSmoke",
            "severity": "test",
        },
        "annotations": {
            "summary": "Synthetic dry-run incident for ecosystem smoke test",
        },
        "startsAt": "2026-05-27T00:00:00Z",
    }
    analyzed = rpc(
        sre,
        "tools/call",
        {"name": "sre_analyze", "arguments": incident},
        id_=12,
        timeout=20,
    )
    text = content_text(analyzed)
    if "SRE Anamnesis" not in text or "FroggyEcosystemSmoke" not in text:
        raise RuntimeError(f"unexpected sre_analyze content: {text[:300]!r}")
    print("PASS  froggy-sre dry-run: sre_analyze")

    history = rpc(
        sre,
        "tools/call",
        {"name": "sre_history", "arguments": {"limit": 1}},
        id_=13,
    )
    htext = content_text(history)
    if "FroggyEcosystemSmoke" not in htext:
        raise RuntimeError(f"sre_history did not include dry-run incident: {htext[:300]!r}")
    print("PASS  froggy-sre history: dry-run incident persisted in temp dir")
finally:
    sre.terminate()
    try:
        sre.wait(timeout=2)
    except subprocess.TimeoutExpired:
        sre.kill()
PY

info "compatibility summary:"
printf '  Froggy      %s%s\n' "$(repo_commit "$ROOT")" "$(repo_dirty_marker "$ROOT")"
printf '  FroggyKit   %s%s\n' "$(repo_commit "$FROGGYKIT_REPO")" "$(repo_dirty_marker "$FROGGYKIT_REPO")"
printf '  froggy-mcp  %s%s\n' "$(repo_commit "$FROGGY_MCP_REPO")" "$(repo_dirty_marker "$FROGGY_MCP_REPO")"
printf '  froggy-sre  %s%s\n' "$(repo_commit "$FROGGY_SRE_REPO")" "$(repo_dirty_marker "$FROGGY_SRE_REPO")"

pass "ecosystem smoke completed"
