#!/usr/bin/env python3
"""Live check: a running `whytap mcp` keeps serving after its helper file is
replaced by another build, with a real `execve`.

Uses a throwaway `Selftest.app`, a throwaway keychain with two self-signed
code-signing certificates (the helper's signer and an impostor) and a fake
broker that makes the app's trust check: the kernel's cdhash of the peer's
running code must equal the cdhash of the validly signed helper on disk.
Never touches /Applications/Whytap.app, the user's keychains or broker socket.

usage: scripts/check-helper-follows-build.py [path/to/built/whytap]
WHY: .project-docs/decisions/2026-11-25-helper-follows-new-build.md
"""
import ctypes, json, os, plistlib, re, secrets, shutil, socket, struct, subprocess, sys, tempfile, threading, time, uuid

BUILT = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else ".build/debug/whytap")
BUNDLE_ID = "ai.whytap.selftest-" + uuid.uuid4().hex[:8]
SUPPORT = os.path.expanduser(f"~/Library/Application Support/{BUNDLE_ID}")
SOCKET = os.path.join(SUPPORT, "case-broker.sock")
LOCAL_PEERPID = 0x002
LIBC = ctypes.CDLL(None, use_errno=True)
CS_OPS_CDHASH = 5
RESUME_KEY = b"WHYTAP_MCP_RESUME_V1_FD"


def running_cdhash(pid):
    """The cdhash the kernel holds for the code a process runs (not its file)."""
    buffer = ctypes.create_string_buffer(20)
    if LIBC.csops(ctypes.c_int(pid), ctypes.c_uint(CS_OPS_CDHASH), buffer, ctypes.c_size_t(20)) != 0:
        return None
    return buffer.raw.hex()


LIBPROC = ctypes.CDLL("/usr/lib/libproc.dylib")


def executable_path(pid):
    buffer = ctypes.create_string_buffer(4096)
    return buffer.value.decode() if LIBPROC.proc_pidpath(pid, buffer, 4096) > 0 else None


STAGING = os.path.join(SUPPORT, "helper-handover")


def staging_entries(pid):
    names = sorted(os.listdir(STAGING)) if os.path.isdir(STAGING) else []
    return [name for name in names if name.startswith(f"{pid}-")]


def runs_private_copy(pid):
    """Runs from its one verified copy (older copies of this pid swept)."""
    deadline = time.time() + 5
    while time.time() < deadline:
        path, entries = executable_path(pid) or "", staging_entries(pid)
        if len(entries) == 1 and path.startswith(os.path.join(STAGING, entries[0]) + "/"):
            return True
        time.sleep(0.05)
    return False


def file_cdhash(path):
    out = subprocess.run(["codesign", "-dvvv", path], capture_output=True, text=True).stderr
    match = re.search(r"CDHash=([0-9a-f]+)", out)
    return match.group(1) if match else None


def run(command):
    subprocess.run(command, check=True, capture_output=True)


class Keychain:
    """A temporary keychain, never added to the search list."""
    PASSWORD = "selftest"

    def __init__(self, work):
        self.path = os.path.join(work, "selftest.keychain-db")
        run(["security", "create-keychain", "-p", self.PASSWORD, self.path])
        run(["security", "unlock-keychain", "-p", self.PASSWORD, self.path])
        for name in ("Whytap Selftest Signer", "Whytap Selftest Impostor"):
            self.add_identity(work, name)
        run(["security", "set-key-partition-list", "-S", "apple-tool:,apple:,codesign:", "-s",
             "-k", self.PASSWORD, self.path])

    def add_identity(self, work, name):
        stem = os.path.join(work, uuid.uuid4().hex)
        with open(stem + ".cfg", "w") as f:
            f.write(f"[req]\ndistinguished_name=dn\nx509_extensions=ext\nprompt=no\n[dn]\nCN={name}\n"
                    "[ext]\nbasicConstraints=critical,CA:false\nkeyUsage=critical,digitalSignature\n"
                    "extendedKeyUsage=critical,codeSigning\n")
        run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", stem + ".key",
             "-out", stem + ".pem", "-days", "1", "-config", stem + ".cfg"])
        export = ["openssl", "pkcs12", "-export", "-inkey", stem + ".key", "-in", stem + ".pem",
                  "-out", stem + ".p12", "-passout", "pass:" + self.PASSWORD]
        if subprocess.run(export + ["-legacy"], capture_output=True).returncode != 0:
            run(export)
        run(["security", "import", stem + ".p12", "-k", self.path, "-P", self.PASSWORD, "-T", "/usr/bin/codesign"])

    def delete(self):
        subprocess.run(["security", "delete-keychain", self.path], capture_output=True)


def patch_uuid(data):
    """A different build of the same code: a new LC_UUID changes the cdhash."""
    magic, _, _, _, ncmds = struct.unpack_from("<IiiII", data, 0)
    assert magic == 0xFEEDFACF, "expects a thin 64-bit debug build"
    offset = 32
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", data, offset)
        if cmd == 0x1B:
            data[offset + 8:offset + 24] = secrets.token_bytes(16)
            return
        offset += size
    raise AssertionError("no LC_UUID")


def install_identical(helper):
    """The same signed bytes again, the way a bundle swap leaves it: the running
    file is moved away, an identical copy takes its place, the old one is deleted."""
    parked = helper + ".parked"
    os.rename(helper, parked)
    shutil.copy2(parked, helper)
    os.unlink(parked)


def install(helper, keychain, signer="Whytap Selftest Signer", resumes=True, corrupt=False):
    staged = helper + ".new"
    data = bytearray(open(BUILT, "rb").read())
    patch_uuid(data)
    if not resumes:  # a rollback build that does not know this envelope
        data = bytearray(bytes(data).replace(RESUME_KEY, b"WHYTAP_MCP_RESUME_V0_FD"))
    with open(staged, "wb") as f:
        f.write(data)
    os.chmod(staged, 0o755)
    if signer == "-":
        run(["codesign", "-f", "-s", "-", "-i", "whytap", staged])
    else:
        run(["codesign", "-f", "-s", signer, "--keychain", keychain.path, "-i", "whytap", staged])
    if corrupt:  # a signed file whose code no longer matches its signature
        with open(staged, "r+b") as f:
            f.seek(0x4000 + 100)
            byte = f.read(1)
            f.seek(0x4000 + 100)
            f.write(bytes([byte[0] ^ 0xFF]))
    os.rename(staged, helper)  # atomic swap, like the builder's bundle replacement


class Broker:
    def __init__(self, helper):
        self.helper, self.log, self.stop, self.deny_all = helper, [], False, False
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
            disk_valid = subprocess.run(["codesign", "-v", "--strict", self.helper], capture_output=True).returncode == 0
            # Like the app's dynamic validity check: the peer's own executable
            # file must still exist and match the code it runs.
            own_path = executable_path(pid)
            own_valid = own_path is not None and file_cdhash(own_path) == running_cdhash(pid)
            trusted = (not self.deny_all and disk_valid and own_valid
                       and running_cdhash(pid) == file_cdhash(self.helper))
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

    def denied(self):
        return sum(1 for entry in self.log if entry[0] == "denied")

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

    def handshake(self):
        self.send("initialize", {"protocolVersion": "2025-06-18"})
        self.reply()
        self.send("notifications/initialized", notify=True)

    def close(self):
        self.proc.stdin.close()
        self.proc.wait(timeout=10)


def payload(reply):
    return json.loads(reply["result"]["content"][0]["text"])


def ok(reply, rid, pid):
    return (reply["id"] == rid and "result" in reply and not reply["result"]["isError"]
            and payload(reply)["data"]["pid"] == pid)


def check(condition, text):
    print(("PASS  " if condition else "FAIL  ") + text)
    if not condition:
        raise SystemExit(1)


def settle(client):
    """A first call; meanwhile the helper captures its signer in the background."""
    rid = client.call("whytap_get_state")
    return client.reply()["id"] == rid


def main():
    work = tempfile.mkdtemp(prefix="whytap-follow-")
    keychain = Keychain(work)
    contents = os.path.join(work, "Selftest.app", "Contents")
    os.makedirs(os.path.join(contents, "Helpers"))
    with open(os.path.join(contents, "Info.plist"), "wb") as f:
        plistlib.dump({"CFBundleIdentifier": BUNDLE_ID}, f)
    helper = os.path.join(contents, "Helpers", "whytap")
    install(helper, keychain)
    broker = Broker(helper)
    try:
        # 1. Follow, repeatedly, then the loop budget.
        client = Client(helper, ["mcp"])
        pid = client.proc.pid
        client.handshake()
        check(settle(client), "call on the first build")
        for step in (1, 2):
            install(helper, keychain)
            rid = client.call("whytap_get_state")
            check(ok(client.reply(), rid, pid), f"replacement {step}: the same process answers the next call from the new build")
            check(running_cdhash(pid) == file_cdhash(helper), f"replacement {step}: the process runs the new file's code")
            check(runs_private_copy(pid) and file_cdhash(executable_path(pid)) == file_cdhash(helper),
                  f"replacement {step}: it runs its verified private copy (path readable for the app), older copies removed")
        install(helper, keychain)
        ids = [client.call("whytap_get_state"), client.call("whytap_list_models")]
        answers = [client.reply(), client.reply()]
        check(sorted(a["id"] for a in answers) == sorted(ids) and all(ok(a, a["id"], pid) for a in answers),
              "two pipelined calls after a replacement each get exactly one answer")
        check({entry[2] for entry in broker.log} == {os.getpid()}, "the app always sees the harness as the helper's parent")
        install(helper, keychain)
        before = running_cdhash(pid)
        rid = client.call("whytap_get_state")
        answer = client.reply()
        check(answer["id"] == rid and answer["result"]["isError"] and running_cdhash(pid) == before,
              "loop budget: a fourth relaunch within two minutes is refused, the call is answered")
        client.close()

        # 2. Files that must never be executed, then a rollback build.
        install(helper, keychain)
        client = Client(helper, ["mcp"])
        pid = client.proc.pid
        client.handshake()
        settle(client)
        for label, options in (("an invalidly signed file", {"corrupt": True}),
                               ("a valid file from another signer", {"signer": "Whytap Selftest Impostor"}),
                               ("a valid ad-hoc file", {"signer": "-"})):
            before, denied = running_cdhash(pid), broker.denied()
            install(helper, keychain, **options)
            rid = client.call("whytap_get_state")
            answer = client.reply()
            check(answer["id"] == rid and answer["result"]["isError"] and running_cdhash(pid) == before
                  and broker.denied() - denied == 1 and client.proc.poll() is None,
                  f"{label}: not executed, one denied request, the call is answered")
        install(helper, keychain, resumes=False)
        rid = client.call("whytap_get_state")
        partial = json.dumps({"jsonrpc": "2.0", "id": 900, "method": "tools/call",
                              "params": {"name": "whytap_get_state", "arguments": {}}})
        client.proc.stdin.write(partial[:15].encode())
        client.proc.stdin.flush()
        answer = client.reply(timeout=5)
        check(answer["id"] == rid and "error" in answer and "Retry" in answer["error"]["message"],
              "rollback to a build without the protocol: the triggering call is answered at once, next frame unfinished")
        client.proc.stdin.write((partial[15:] + "\n").encode())
        client.proc.stdin.flush()
        answer = client.reply()
        check(answer["id"] == 900 and "error" in answer, "rollback: the completed frame gets its explicit answer too")
        # The refusal is written before the exec, so give the exec a moment.
        deadline = time.time() + 5
        while running_cdhash(pid) != file_cdhash(helper) and time.time() < deadline:
            time.sleep(0.05)
        check(running_cdhash(pid) == file_cdhash(helper), "rollback: the same process runs the rollback build")
        check(runs_private_copy(pid), "rollback: it runs from its private copy, kept while it runs")
        rid = client.call("whytap_get_state")
        check(ok(client.reply(), rid, pid), "rollback: later calls are answered by the rollback build")
        client.close()

        # 3. An ad-hoc helper fails closed (its requirement is its own cdhash).
        install(helper, keychain, signer="-")
        client = Client(helper, ["mcp"])
        pid = client.proc.pid
        client.handshake()
        settle(client)
        before = running_cdhash(pid)
        install(helper, keychain, signer="-")
        rid = client.call("whytap_get_state")
        answer = client.reply()
        check(answer["id"] == rid and answer["result"]["isError"] and running_cdhash(pid) == before,
              "ad-hoc helper: never follows another build")
        client.close()

        # 4. The same build swapped in again (1760 -> 1761 shipped an identical
        #    helper): the old process lost its file and must follow it too.
        install(helper, keychain)
        client = Client(helper, ["mcp"])
        pid = client.proc.pid
        client.handshake()
        settle(client)
        same = running_cdhash(pid)
        install_identical(helper)
        check(file_cdhash(helper) == same and executable_path(pid) is None,
              "identical replacement: same cdhash, the process lost its executable file")
        rid = client.call("whytap_get_state")
        check(ok(client.reply(), rid, pid) and runs_private_copy(pid) and running_cdhash(pid) == same,
              "identical replacement: the same process follows and answers from its private copy")
        broker.deny_all = True
        denied = broker.denied()
        rid = client.call("whytap_get_state")
        answer = client.reply()
        broker.deny_all = False
        check(answer["id"] == rid and answer["result"]["isError"] and broker.denied() - denied == 1
              and runs_private_copy(pid), "intact image, same cdhash, denied anyway: no exec, the call is answered")
        rid = client.call("whytap_get_state")
        check(ok(client.reply(), rid, pid), "identical replacement: later calls are answered")
        client.close()

        # 5. case mcp and app mcp follow; no broker means no exec loop.
        install(helper, keychain)
        case = Client(helper, ["case", "mcp"])
        case.handshake()
        case.call("case_list_keys")
        check("SELFTEST_KEY" in json.dumps(case.reply()), "case mcp on the current build")
        app = Client(helper, ["app", "mcp"])
        app.handshake()
        check(settle(app), "app mcp on the current build")
        install(helper, keychain)
        rid = case.call("case_list_keys")
        answer = case.reply()
        check(answer["id"] == rid and "SELFTEST_KEY" in json.dumps(answer), "case mcp follows a replacement")
        rid = app.call("whytap_get_state")
        check(ok(app.reply(), rid, app.proc.pid), "app mcp follows a replacement")
        broker.close()
        broker = None
        install(helper, keychain)
        before = running_cdhash(app.proc.pid)
        rid = app.call("whytap_get_state")
        answer = app.reply(timeout=30)
        check(answer["id"] == rid and answer["result"]["isError"] and running_cdhash(app.proc.pid) == before
              and app.proc.poll() is None, "Whytap not running: the call answers 'unavailable', no exec")
        for c in (case, app):
            c.close()
        check(True, "all servers exit on EOF")
    finally:
        if broker:
            broker.close()
        keychain.delete()
        shutil.rmtree(SUPPORT, ignore_errors=True)
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    main()
