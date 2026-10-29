"""Remote workspace qualification for scripts/qualify.py --remote (FR-RW03, FR-RW08).

Starts a disposable Docker sshd (Tests/Fixtures/remote-sshd) with a throwaway key, installs the static Linux helper
over ssh with its SHA-256 checked on the host, and measures keystroke echo through a remote workspace session (the
helper's bridge over `ssh -T`) against a plain `ssh -tt` shell, the same way for both. Never touches ~/.ssh.
"""
import gzip, json, os, select, struct, subprocess, tempfile, time, uuid


def run(root, samples):
    helpers = os.path.join(root, ".build", "remote-helpers")
    if not os.path.exists(os.path.join(helpers, "remote-helpers.json")):
        subprocess.run([os.path.join(root, "scripts", "build-remote-helpers.sh"), helpers], check=True, capture_output=True)
    work = tempfile.mkdtemp(prefix="trellis-qr-")
    name = f"trellis-qualify-{os.getpid()}"
    key = os.path.join(work, "key")
    processes = []
    # Everything after the throwaway key exists is undone on any failure: the key, the container and the ssh processes.
    try:
        subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "trellis-qualify", "-f", key], check=True)
        public = open(key + ".pub").read().strip()
        subprocess.run(["docker", "build", "-q", "-t", "trellis-remote-sshd", "--build-arg", f"PUBLIC_KEY={public}",
                        os.path.join(root, "Tests", "Fixtures", "remote-sshd")], check=True, capture_output=True)
        subprocess.run(["docker", "run", "-d", "--name", name, "-p", "127.0.0.1::22", "trellis-remote-sshd"], check=True, capture_output=True)
        port = subprocess.run(["docker", "port", name, "22/tcp"], capture_output=True, text=True).stdout.split(":")[-1].strip()
        ssh = ["/usr/bin/ssh", "-i", key, "-p", port, "-o", f"UserKnownHostsFile={work}/known_hosts", "-o", "StrictHostKeyChecking=accept-new",
               "-o", "BatchMode=yes"]
        for _ in range(50):
            if subprocess.run(ssh + ["--", "dev@127.0.0.1", "true"], capture_output=True, timeout=15).returncode == 0:
                break
            time.sleep(0.2)
        else:
            raise RuntimeError("the Docker sshd never accepted the key")
        machine = subprocess.run(ssh + ["--", "dev@127.0.0.1", "uname -m"], capture_output=True, text=True).stdout.strip()
        manifest = json.load(open(os.path.join(helpers, "remote-helpers.json")))
        entry = next(h for h in manifest["helpers"] if h["platform"] == f"linux-{'aarch64' if machine in ('aarch64', 'arm64') else machine}")
        payload = open(os.path.join(helpers, entry["file"]), "rb").read()

        started = time.perf_counter()
        directory = entry["digest"][:16]
        install = (f"umask 077; set -e; d=~/.trellis/remote/{directory}; mkdir -p $d; t=$d/.upload.$$; gzip -dc > $t; "
                   f"[ \"$(sha256sum $t | cut -d' ' -f1)\" = {entry['digest']} ]; chmod 700 $t; mv $t $d/trellis-broker")
        subprocess.run(ssh + ["--", "dev@127.0.0.1", install], input=payload, check=True, capture_output=True)
        install_s = time.perf_counter() - started

        link = Link(ssh + ["-T", "-e", "none", "--", "dev@127.0.0.1"], directory, processes)
        connect_s = link.connect_s
        session = uuid.uuid4()
        link.request({"spawnLogin": {"_0": {"sessionID": str(session).upper(), "shell": "/bin/sh", "environment": {"TERM": "xterm-256color", "PS1": "$ "},
                                            "columns": 100, "rows": 30}}})
        link.wait_output(session, b"$ ")
        workspace = echo_samples(lambda data: link.send_input(session, data), lambda: link.output_len(session), lambda: link.pump(0.5), samples)
        link.stop_all()
        link.close()

        def plain_echo(options):
            plain = subprocess.Popen(ssh + options + ["-tt", "--", "dev@127.0.0.1", "PS1='$ ' exec /bin/sh"], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
            processes.append(plain)
            received = bytearray()

            def plain_pump(timeout):
                ready, _, _ = select.select([plain.stdout], [], [], timeout)
                if ready:
                    received.extend(os.read(plain.stdout.fileno(), 65536))
            deadline = time.time() + 15
            while b"$ " not in received and time.time() < deadline:
                plain_pump(0.5)

            def plain_send(data):
                plain.stdin.write(data)
                plain.stdin.flush()
            values = echo_samples(plain_send, lambda: len(received), lambda: plain_pump(0.5), samples)
            plain.kill()
            plain.wait()
            return values
        # OpenSSH 9.5+ paces keystrokes in a session with a PTY (ObscureKeystrokeTiming, about 20 ms by default); the
        # `ssh -T` bridge has no PTY, so it isn't paced. The fair transport baseline turns it off; the default is kept too.
        direct = plain_echo(["-o", "ObscureKeystrokeTiming=no"])
        obscured = plain_echo([])
        return {"install_s": round(install_s, 2), "connect_s": round(connect_s, 2), "helper_platform": entry["platform"],
                "echo_workspace_ms": workspace, "echo_plain_ssh_ms": direct, "echo_plain_ssh_obscured_ms": obscured}
    finally:
        for process in processes:
            if process.poll() is None:
                process.kill()
                process.wait()
        subprocess.run(["docker", "rm", "-f", name], capture_output=True)
        subprocess.run(["rm", "-rf", work])


def echo_samples(send, length, pump, count):
    """Milliseconds from writing one character to its echo arriving; Ctrl-U clears the line every 50."""
    values = []
    for index in range(count):
        if index and index % 50 == 0:
            send(b"\x15")
            time.sleep(0.05)
            pump_until_quiet(pump)
        before = length()
        started = time.perf_counter()
        send(b"x")
        deadline = time.time() + 5
        while length() <= before and time.time() < deadline:
            pump()
        if length() > before:
            values.append((time.perf_counter() - started) * 1000)
        time.sleep(0.005)
    send(b"\x15")
    return values


def pump_until_quiet(pump):
    for _ in range(3):
        pump()


class Link:
    """The app's side of a remote workspace link, as RemoteHostLink speaks it, for measurement only."""

    def __init__(self, ssh, directory, processes):
        self.token, self.client = uuid.uuid4().hex, uuid.uuid4().hex
        started = time.perf_counter()
        command = f"exec ~/.trellis/remote/{directory}/trellis-broker bridge --client-id {self.client} --sync {self.token}"
        self.process = subprocess.Popen(ssh + [command], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        processes.append(self.process)
        self.buffer, self.next_id, self.replies, self.output = b"", 1, {}, {}
        marker = f"\nTRELLIS-SYNC-1 {self.token}\n".encode()
        deadline = time.time() + 30
        while marker not in self.buffer:
            if time.time() > deadline:
                raise TimeoutError("the helper bridge never printed its sync line")
            self.read(1)
        self.buffer = self.buffer.split(marker, 1)[1]
        self.request({"hello": {"protocolVersion": 2, "features": [], "maximumVersion": 2, "clientID": self.client}})
        self.connect_s = time.perf_counter() - started

    def read(self, timeout):
        ready, _, _ = select.select([self.process.stdout], [], [], timeout)
        if not ready:
            return
        chunk = os.read(self.process.stdout.fileno(), 65536)
        if not chunk:
            raise ConnectionError("link closed")
        self.buffer += chunk

    def pump(self, timeout=0.2):
        self.read(timeout)
        while len(self.buffer) >= 4:
            (length,) = struct.unpack(">I", self.buffer[:4])
            if len(self.buffer) < 4 + length:
                return
            kind, payload, self.buffer = self.buffer[4], self.buffer[5:4 + length], self.buffer[4 + length:]
            if kind == 0:
                envelope = json.loads(payload)
                if envelope.get("requestID") is not None:
                    self.replies[envelope["requestID"]] = envelope["message"]
            elif kind == 2:
                self.output.setdefault(uuid.UUID(bytes=payload[:16]), bytearray()).extend(payload[16:])

    def send(self, kind, payload):
        self.process.stdin.write(struct.pack(">IB", len(payload) + 1, kind) + payload)
        self.process.stdin.flush()

    def request(self, message):
        ident, self.next_id = self.next_id, self.next_id + 1
        self.send(0, json.dumps({"requestID": ident, "message": message}).encode())
        deadline = time.time() + 15
        while ident not in self.replies:
            if time.time() > deadline:
                raise TimeoutError(message)
            self.pump()
        return self.replies.pop(ident)

    def send_input(self, session, data):
        self.send(1, session.bytes + data)

    def output_len(self, session):
        return len(self.output.get(session, b""))

    def wait_output(self, session, needle, timeout=15):
        deadline = time.time() + timeout
        while needle not in self.output.get(session, b"") and time.time() < deadline:
            self.pump()

    def stop_all(self):
        self.send(255, b"")
        time.sleep(0.3)

    def close(self):
        self.process.kill()
        self.process.wait()
