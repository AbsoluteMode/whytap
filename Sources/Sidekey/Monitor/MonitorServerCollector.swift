import Foundation

struct MonitorServerCollector {
    var runner = MonitorProcessRunner()

    func collect(_ server: MonitorServer) async throws -> MonitorServerMetrics {
        try server.validate()
        let ssh = URL(fileURLWithPath: "/usr/bin/ssh")
        var executable = ssh
        var arguments: [String] = []
        var environment = ProcessInfo.processInfo.environment
        // A GUI launch can have a minimal PATH. These are local tools only.
        environment["PATH"] = [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("bin").path,
                               "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"].joined(separator: ":")
        var target = server.sshTarget ?? ""
        var authentication = ["-o", "BatchMode=yes"]
        if let reference = server.doppler {
            guard let doppler = MonitorProcessRunner.executable(named: "doppler"),
                  let sshpass = MonitorProcessRunner.executable(named: "sshpass") else {
                throw MonitorProcessError.failed
            }
            let names = ["HOSTNAME", "USER", "PASSWORD"].map { reference.prefix + "_" + $0 }
            let data = try await runner.run(executable: doppler, arguments:
                ["secrets", "get"] + names + ["--project", reference.project, "--config", reference.config,
                                             "--json", "--no-check-version", "--attempts", "1", "--timeout", "5s"])
            let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            func value(_ name: String) -> String? {
                if let text = raw?[name] as? String { return text }
                let item = raw?[name] as? [String: Any]
                return item?["computed"] as? String ?? item?["raw"] as? String
            }
            guard let host = value(names[0]), let user = value(names[1]), let password = value(names[2]),
                  !password.isEmpty, MonitorServer.validSSHTarget(user + "@" + host) else {
                throw MonitorProcessError.failed
            }
            target = user + "@" + host
            environment["SSHPASS"] = password
            executable = sshpass
            arguments = ["-e", ssh.path]
            authentication = ["-o", "BatchMode=no", "-o", "PreferredAuthentications=password",
                              "-o", "PubkeyAuthentication=no", "-o", "NumberOfPasswordPrompts=1"]
        }
        arguments += ["-T", "-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=5",
                      "-o", "ServerAliveInterval=3", "-o", "ServerAliveCountMax=1"]
        arguments += authentication + [target, Self.remoteReadCommand]
        // A credential lookup can take seconds; a poll cancelled meanwhile
        // (Server status deleted) must not go on to connect.
        try Task.checkCancellation()
        let data = try await runner.run(executable: executable, arguments: arguments, environment: environment)
        try Task.checkCancellation()
        let metrics = try JSONDecoder().decode(MonitorServerMetrics.self, from: data)
        try metrics.validate()
        return metrics
    }

    /// Fixed read-only Linux collector. Nothing is installed, restarted or
    /// written on the server. CPU is a measured interval, not load average.
    static let remoteReadCommand = #"""
    python3 - <<'WHYTAP_METRICS'
    import csv, io, json, shutil, subprocess, time
    def cpu():
        with open('/proc/stat') as f:
            v = [int(x) for x in f.readline().split()[1:9]]
        return sum(v), v[3] + v[4]
    first = cpu()
    time.sleep(0.25)
    second = cpu()
    delta = second[0] - first[0]
    cpu_percent = max(0, min(100, 100 * (1 - (second[1] - first[1]) / delta))) if delta else 0
    memory = {}
    with open('/proc/meminfo') as f:
        for line in f:
            key, value = line.split(':', 1)
            memory[key] = int(value.split()[0]) * 1024
    total = memory['MemTotal']
    available = memory.get('MemAvailable', memory.get('MemFree', 0))
    with open('/proc/loadavg') as f: load = float(f.read().split()[0])
    with open('/proc/uptime') as f: uptime = float(f.read().split()[0])
    gpus, state = [], 'not-present'
    if shutil.which('nvidia-smi'):
        state = 'unavailable'
        try:
            result = subprocess.run(['nvidia-smi', '--query-gpu=index,name,utilization.gpu,memory.used,memory.total',
                                     '--format=csv,noheader,nounits'], capture_output=True, text=True, timeout=3,
                                    check=True)
            for row in csv.reader(io.StringIO(result.stdout)):
                if len(row) != 5: raise ValueError('GPU format')
                gpus.append(dict(index=int(row[0]), name=row[1].strip(), utilizationPercent=float(row[2]),
                                 memoryUsedMiB=float(row[3]), memoryTotalMiB=float(row[4])))
            state = 'available' if gpus else 'not-present'
        except (subprocess.SubprocessError, ValueError, OSError):
            gpus = []
    print(json.dumps(dict(cpuPercent=round(cpu_percent, 2), memoryUsedBytes=max(0, total-available),
                         memoryTotalBytes=total, load1=load, uptimeSeconds=uptime, gpus=gpus, gpuState=state)))
    WHYTAP_METRICS
    """#
}
