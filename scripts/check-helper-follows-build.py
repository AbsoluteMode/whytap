#!/usr/bin/env python3
"""Live check: a running `whytap mcp` keeps serving after its helper file is
replaced by another build. Uses a throwaway bundle and a fake broker that makes
the app's trust check (running cdhash == cdhash of the valid helper on disk).
Never touches /Applications/Whytap.app or the user's broker socket.

usage: scripts/check-helper-follows-build.py [path/to/built/whytap]
WHY: .project-docs/decisions/2026-11-25-helper-follows-new-build.md
"""
import ctypes, json, os, plistlib, re, shutil, socket, subprocess, sys, tempfile, threading, time, uuid

BUILT = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else ".build/debug/whytap")
BUNDLE_ID = "ai.whytap.selftest-" + uuid.uuid4().hex[:8]
SUPPORT = os.path.expanduser(f"~/Library/Application Support/{BUNDLE_ID}")
SOCKET = os.path.join(SUPPORT, "case-broker.sock")
LOCAL_PEERPID = 0x002


LIBC = ctypes.CDLL(None, use_errno=True)
CS_OPS_CDHASH = 5


def running_cdhash(pid):
    """The cdhash the kernel holds for the code a process runs (not its file)."""
    buffer = ctypes.create_string_buffer(20)
    if LIBC.csops(ctypes.c_int(pid), ctypes.c_uint(CS_OPS_CDHASH), buffer, ctypes.c_size_t(20)) != 0:
        return None
    return buffer.raw.hex()


def file_cdhash(path):
    out = subprocess.run(["codesign", "-dvvv", path], capture_output=True, text=True).stderr
    match = re.search(r"CDHash=([0-9a-f]+)", out)
    return match.group(1) if match else None


def install(helper, identifier, corrupt=False):
    staged = helper + ".new"
    shutil.copy2(BUILT, staged)
    subprocess.run(["codesign", "-f", "-s", "-", "-i", identifier, staged], check=True, capture_output=True)
    if corrupt:  # a signed file whose code no longer matches its signature
        with open(staged, "r+b") as f:
            f.seek(0x4000 + 100)
            byte = f.read(1)
            f.seek(0x4000 + 100)
            f.write(bytes([byte[0] ^ 0xFF]))
    os.rename(staged, helper)  # atomic swap, like the builder's bundle replacement


class Broker:
    def __init__(self, helper):
        self.helper, self.log, self.stop = helper, [], False
        os.makedirs(SUPPORT, exist_ok=True)
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.bind(SOCKET)
        self.sock.listen(16)
        threading.Thread(target=self.loop, daemon=True).start()

    def loop(self):
        while not self.stop:
            try:
                conn, _ = self.sock.accept()
            except OSError:
                return
            threading.Thread(target=self.serve, args=(conn,), daemon=True).start()

    def serve(self, conn):
        with conn:
            pid = int.from_bytes(conn.getsockopt(0, LOCAL_PEERPID, 4), "little")
            disk_valid = subprocess.run(["codesign", "-v", self.helper], capture_output=True).returncode == 0
            trusted = disk_valid and running_cdhash(pid) == file_cdhash(self.helper)
            ppid = int(subprocess.run(["ps", "-o", "ppid=", "-p", str(pid)], capture_output=True, text=True).stdout or 0)
            if not trusted:
                self.log.append(("denied", pid, ppid, None))
                conn.sendall(b'{"denied":{"reason":"untrustedHelper"}}\n')
                return
            data = b""
            while not data.endswith(b"\n"):
                chunk = conn.recv(65536)
                if not chunk:
                    break
                data += chunk
            request = json.loads(data)
            self.log.append(("served", pid, ppid, request))
            if "listKeys" in request:
                answer = {"keys": {"_0": [{"name": "SELFTEST_KEY", "description": "", "project": "p"}]}}
            else:
                op = request["appControl"]["_0"]["operation"]
                answer = {"appControl": {"_0": {"ok": True, "data": {"operation": op, "pid": pid}}}}
            conn.sendall(json.dumps(answer).encode() + b"\n")

    def close(self):
        self.stop = True
        self.sock.close()
        os.unlink(SOCKET)


class Client:
    def __init__(self, helper, args):
        self.proc = subprocess.Popen([helper] + args, stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        self.next_id = 1

    def send(self, method, params=None, notify=False):
        message = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            message["params"] = params
        if not notify:
            message["id"] = self.next_id
            self.next_id += 1
        self.proc.stdin.write((json.dumps(message) + "\n").encode())
        self.proc.stdin.flush()
        return message.get("id")

    def reply(self, timeout=20):
        result = {}
        def read():
            result["line"] = self.proc.stdout.readline()
        t = threading.Thread(target=read, daemon=True)
        t.start()
        t.join(timeout)
        if "line" not in result:
            raise AssertionError("no reply within %ss" % timeout)
        return json.loads(result["line"])

    def call(self, name, arguments=None):
        return self.send("tools/call", {"name": name, "arguments": arguments or {}})


def payload(reply):
    return json.loads(reply["result"]["content"][0]["text"])


def check(condition, text):
    print(("PASS  " if condition else "FAIL  ") + text)
    if not condition:
        raise SystemExit(1)


def main():
    work = tempfile.mkdtemp(prefix="whytap-follow-")
    contents = os.path.join(work, "Selftest.app", "Contents")
    os.makedirs(os.path.join(contents, "Helpers"))
    with open(os.path.join(contents, "Info.plist"), "wb") as f:
        plistlib.dump({"CFBundleIdentifier": BUNDLE_ID}, f)
    helper = os.path.join(contents, "Helpers", "whytap")
    install(helper, "selftest.a")
    broker = Broker(helper)
    try:
        client = Client(helper, ["mcp"])
        pid = client.proc.pid
        client.send("initialize", {"protocolVersion": "2025-06-18"})
        check(client.reply()["result"]["serverInfo"]["name"] == "whytap", "initialize answered")
        client.send("notifications/initialized", notify=True)
        rid = client.call("whytap_get_state")
        first = client.reply()
        check(first["id"] == rid and payload(first)["data"]["pid"] == pid, "call on the first build")

        for step, identifier in enumerate(["selftest.b", "selftest.c"], 1):
            install(helper, identifier)
            rid = client.call("whytap_get_state")
            answer = client.reply()
            check(answer["id"] == rid and answer["result"]["isError"] is False
                  and payload(answer)["data"]["pid"] == pid,
                  f"replacement {step}: same process answers the next call from the new build")
            check(running_cdhash(pid) == file_cdhash(helper), f"replacement {step}: running code is the new file")

        install(helper, "selftest.d")
        ids = [client.call("whytap_get_state"), client.call("whytap_list_models")]
        answers = [client.reply(), client.reply()]
        check(sorted(a["id"] for a in answers) == sorted(ids) and all(not a["result"]["isError"] for a in answers),
              "two pipelined calls after a replacement each get exactly one answer")
        parents = {entry[2] for entry in broker.log}
        check(parents == {os.getpid()}, "the app always sees the harness as the helper's parent")

        running = running_cdhash(pid)
        install(helper, "selftest.broken", corrupt=True)
        before = len(broker.log)
        rid = client.call("whytap_get_state")
        answer = client.reply()
        check(answer["id"] == rid and answer["result"]["isError"] is True
              and client.proc.poll() is None and running_cdhash(pid) == running,
              "an invalid new build: the old helper answers 'unavailable' and does not exec")
        check(len(broker.log) - before == 1, "invalid build: one request, no retry loop")

        install(helper, "selftest.e")
        rid = client.call("whytap_get_state")
        answer = client.reply()
        check(answer["id"] == rid and answer["result"]["isError"] is True and client.proc.poll() is None,
              "loop budget: a fourth relaunch within two minutes is refused, the call answers")

        case = Client(helper, ["case", "mcp"])
        case.send("initialize", {"protocolVersion": "2025-06-18"})
        case.reply()
        case.call("case_list_keys")
        check("SELFTEST_KEY" in json.dumps(case.reply()), "case mcp on the current build")
        install(helper, "selftest.f")
        rid = case.call("case_list_keys")
        answer = case.reply()
        check(answer["id"] == rid and "SELFTEST_KEY" in json.dumps(answer), "case mcp follows a replacement")

        app = Client(helper, ["app", "mcp"])
        app.send("initialize", {"protocolVersion": "2025-06-18"})
        app.reply()
        install(helper, "selftest.g")
        rid = app.call("whytap_get_state")
        answer = app.reply()
        check(answer["id"] == rid and payload(answer)["data"]["pid"] == app.proc.pid, "app mcp follows a replacement")

        broker.close()
        broker = None
        install(helper, "selftest.h")
        rid = app.call("whytap_get_state")
        answer = app.reply(timeout=30)
        check(answer["id"] == rid and answer["result"]["isError"] is True and app.proc.poll() is None,
              "Whytap not running: the call answers 'unavailable', no exec loop")

        for c in (client, case, app):
            c.proc.stdin.close()
            c.proc.wait(timeout=10)
        check(True, "all servers exit on EOF")
    finally:
        if broker:
            broker.close()
        shutil.rmtree(SUPPORT, ignore_errors=True)
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    main()
