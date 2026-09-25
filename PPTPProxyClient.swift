import SwiftUI
import AppKit
import Security
import Darwin

@main
struct PPTPProxyClientApp: App {
    @NSApplicationDelegateAdaptor(QuitGuard.self) private var quitGuard

    var body: some Scene {
        Window(tr("PPTP 프락시"), id: "main") { ContentView() }
            .windowResizability(.contentSize)
    }
}

private enum AppPage: String, CaseIterable {
    case profile = "프로필·연결"
    case proxy = "프락시 설정"
}

private final class ConnectionActivity {
    static let shared = ConnectionActivity()
    var isActive = false
    var controlSocketPath: String?
}

private final class QuitGuard: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard ConnectionActivity.shared.isActive else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = tr("연결 중에 앱을 종료하시겠습니까?")
        alert.informativeText = tr("앱을 종료하면 PPTP 연결도 종료될 수 있습니다.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: tr("연결 해제하고 종료"))
        alert.addButton(withTitle: tr("취소"))
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        if let path = ConnectionActivity.shared.controlSocketPath,
           FileManager.default.fileExists(atPath: path) {
            do {
                guard try controlRequest(path: path, command: "STOP\n") == "OK STOP\n" else {
                    throw NSError(domain: "PPTPProxyClient", code: 4,
                                  userInfo: [NSLocalizedDescriptionKey: tr("백엔드의 연결 해제 응답이 올바르지 않습니다.")])
                }
            } catch {
                let failure = NSAlert()
                failure.messageText = tr("연결 해제에 실패했습니다")
                failure.informativeText = tr("앱을 종료하지 않았습니다. 다시 시도하거나 로그를 확인하세요. \(error.localizedDescription)")
                failure.alertStyle = .warning
                failure.runModal()
                return .terminateCancel
            }
        }
        return .terminateNow
    }
}

struct ContentView: View {
    @State private var profiles: [VPNProfile] = []
    @State private var selectedID = ""
    @State private var profileName = ""
    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
    @State private var hasStoredPassword = false
    @State private var forwardText = ""
    @State private var httpPort = "18080"
    @State private var socksPort = "11080"
    @State private var connecting = false
    @State private var connected = false
    @State private var tunnelReady = false
    @State private var message = "프로필을 선택하거나 새로 등록하세요."
    @State private var processID: Int32?
    @State private var sessionDirectory: URL?
    @State private var logURL: URL?
    @State private var logsExpanded = false
    @State private var logText = "아직 연결 로그가 없습니다."
    @State private var page: AppPage = .profile
    @State private var proxyMessage = "설정을 바꾸면 적용을 누르세요."
    @State private var sentBytes: UInt64 = 0
    @State private var receivedBytes: UInt64 = 0
    @State private var connectedSeconds: UInt64 = 0
    @State private var statusRequestInFlight = false
    @State private var statusFailures = 0
    @State private var disconnecting = false
    @State private var cleaningUp = false
    @State private var applyingSettings = false

    private var proxyPath: String? {
        let path = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/pptp-proxy").path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    private var pptpPath: String? {
        let path = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/pptp").path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 42, height: 42)
                VStack(alignment: .leading) {
                    Text(tr("PPTP 프락시")).font(.title.bold())
                    Text(tr("Safari·프락시 클라이언트용 VPN 연결")).foregroundStyle(.secondary)
                }
            }
            Picker(tr("화면"), selection: $page) {
                ForEach(AppPage.allCases, id: \.self) { item in Text(tr(item.rawValue)).tag(item) }
            }.pickerStyle(.segmented).labelsHidden()
            connectionSummary
            Text(tr(message)).font(.callout).foregroundStyle(message.hasPrefix("실패") ? .red : .secondary)
            if page == .profile { profilePage }
            else { proxyPage }
        }
        .padding(24).frame(width: 650)
        .onAppear { loadProfiles(); loadLatestLog() }
        .onChange(of: selectedID) { _, newValue in selectProfile(newValue) }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            refreshConnectionState()
            if connected { refreshBackendStatus() }
            if logsExpanded { refreshLog() }
        }
    }

    private var connectionSummary: some View {
        HStack(spacing: 14) {
            Circle().fill(disconnecting ? Color.orange : (tunnelReady ? Color.green : (connecting || connected ? Color.orange : Color.gray)))
                .frame(width: 9, height: 9)
            Text(tr(disconnecting ? "연결 해제 중" : (tunnelReady ? "PPP/MPPE 연결됨" : (connecting || connected ? "연결 중" : "연결 안 됨"))))
                .font(.subheadline.bold())
            Spacer()
            if connecting || connected {
                Text(tr("보냄 \(formattedBytes(sentBytes))"))
                Text(tr("받음 \(formattedBytes(receivedBytes))"))
                Text("\(formattedDuration(connectedSeconds))")
                Button(tr(disconnecting ? "연결 해제 중…" : "연결 해제")) { disconnect() }
                    .disabled(disconnecting)
            }
        }
        .font(.caption)
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var profilePage: some View {
        VStack(alignment: .leading, spacing: 14) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 9) {
                GridRow {
                    Text(tr("프로필"))
                    Picker(tr("프로필"), selection: $selectedID) {
                        Text(tr("새 프로필")).tag("")
                        ForEach(profiles) { profile in Text(profile.name).tag(profile.id) }
                    }.labelsHidden()
                }
                GridRow { Text(tr("이름")); TextField(tr("프로필 이름"), text: $profileName) }
                GridRow { Text(tr("PPTP 서버")); TextField(tr("서버 주소"), text: $server) }
                GridRow { Text(tr("VPN 아이디")); TextField(tr("아이디"), text: $username) }
                GridRow {
                    Text(tr("VPN 암호"))
                    SecureField(tr(hasStoredPassword ? "키체인에 저장됨 · 변경하려면 입력" : "VPN 계정 암호"), text: $password)
                }
            }.textFieldStyle(.roundedBorder).disabled(connecting || connected)

            HStack {
                Button(tr("신규 등록")) { selectedID = ""; clearForm() }.disabled(connecting || connected)
                Button(tr("저장")) { _ = saveProfile() }.disabled(connecting || connected)
                Button(tr("삭제")) { deleteProfile() }.disabled(selectedID.isEmpty || connecting || connected)
                Spacer()
                if hasStoredPassword { Text(tr("암호는 키체인에 저장됨")).font(.caption).foregroundStyle(.secondary) }
            }

            HStack {
                Button(tr("연결")) { connect() }.buttonStyle(.borderedProminent).disabled(connecting || connected)
                Button(tr("남은 연결 정리")) { cleanupOrphanBackend() }
                    .disabled(connecting || connected || cleaningUp)
                Button(tr(logsExpanded ? "로그 접기" : "로그 보기")) { logsExpanded.toggle(); if logsExpanded { refreshLog() } }
            }
            if logsExpanded {
                ScrollView {
                    Text(tr(logText)).font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 155).padding(9)
                .background(Color(nsColor: .textBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(.secondary.opacity(0.25)))
            }
        }
    }

    private var proxyPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(tr("프락시 설정")).font(.title3.bold())
            Text(tr(selectedID.isEmpty ? "프로필을 저장하면 포트포워딩 규칙도 함께 보관됩니다." : "현재 프로필: \(profileName)"))
                .font(.caption).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 9) {
                GridRow {
                    Text(tr("HTTP 프락시"))
                    HStack { Text("127.0.0.1:"); TextField("18080", text: $httpPort).frame(width: 75) }
                }
                GridRow {
                    Text(tr("SOCKS5 프락시"))
                    HStack { Text("127.0.0.1:"); TextField("11080", text: $socksPort).frame(width: 75) }
                }
            }.textFieldStyle(.roundedBorder).disabled(applyingSettings)
            VStack(alignment: .leading, spacing: 5) {
                Text(tr("수동 포트포워딩")).font(.headline)
                Text(tr("한 줄에 로컬포트:대상호스트:대상포트 (예: 15432:10.0.0.5:5432)"))
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $forwardText)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(height: 120)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(.secondary.opacity(0.25)))
            }.disabled(applyingSettings)
            HStack {
                Button(tr("적용")) { applyProxySettings() }.buttonStyle(.borderedProminent)
                    .disabled(applyingSettings)
                Text(tr(proxyMessage)).font(.callout)
                    .foregroundStyle(proxyMessage.hasPrefix("실패") ? .red : .secondary)
            }
            Text(tr("Safari는 macOS 네트워크 설정의 웹·보안 웹 프락시에 HTTP 주소를 입력하세요. 수동 포트는 이 Mac의 127.0.0.1에서만 열립니다."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func clearForm() {
        profileName = ""; server = ""; username = ""; password = ""; forwardText = ""
        hasStoredPassword = false
    }

    private func loadProfiles() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: "vpnProfiles.v1"),
           let decoded = try? JSONDecoder().decode([VPNProfile].self, from: data) {
            profiles = decoded
        } else if let oldServer = defaults.string(forKey: "server"), !oldServer.isEmpty {
            profiles = [VPNProfile(id: UUID().uuidString, name: oldServer, server: oldServer,
                                   username: defaults.string(forKey: "username") ?? "", forwards: nil)]
            persistProfiles()
        }
        httpPort = defaults.string(forKey: "proxyHTTPPort") ?? "18080"
        socksPort = defaults.string(forKey: "proxySOCKSPort") ?? "11080"
        let remembered = defaults.string(forKey: "selectedVPNProfile") ?? ""
        selectedID = profiles.contains(where: { $0.id == remembered }) ? remembered : (profiles.first?.id ?? "")
        selectProfile(selectedID)
    }

    private func selectProfile(_ id: String) {
        password = ""
        guard let profile = profiles.first(where: { $0.id == id }) else {
            clearForm()
            proxyMessage = "프로필을 저장하면 포트포워딩 규칙도 함께 보관됩니다."
            return
        }
        profileName = profile.name; server = profile.server; username = profile.username
        forwardText = profile.forwards ?? ""
        proxyMessage = "설정을 바꾸면 적용을 누르세요."
        do { hasStoredPassword = try KeychainPassword.read(account: id) != nil }
        catch { hasStoredPassword = false; message = "키체인 확인 실패: \(error.localizedDescription)" }
        UserDefaults.standard.set(id, forKey: "selectedVPNProfile")
    }

    private func persistProfiles() {
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: "vpnProfiles.v1")
        }
    }

    private func parsedForwards() -> [String]? {
        var result: [String] = []
        var localPorts = Set<Int>()
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        for raw in forwardText.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            let parts = line.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 3,
                  let local = Int(parts[0]), (1...65535).contains(local),
                  let remote = Int(parts[2]), (1...65535).contains(remote),
                  !parts[1].isEmpty, parts[1].utf8.count < 256,
                  parts[1].unicodeScalars.allSatisfy({ allowed.contains($0) }),
                  localPorts.insert(local).inserted
            else { return nil }
            result.append("\(local):\(parts[1]):\(remote)")
        }
        return result.count <= 32 ? result : nil
    }

    private func validatedProxyConfig() -> (http: Int, socks: Int, forwards: [String])? {
        guard let http = Int(httpPort), (1...65535).contains(http),
              let socks = Int(socksPort), (1...65535).contains(socks), http != socks,
              let forwards = parsedForwards(),
              !forwards.contains(where: { rule in
                  guard let first = rule.split(separator: ":").first, let local = Int(first) else { return true }
                  return local == http || local == socks
              }) else { return nil }
        return (http, socks, forwards)
    }

    private func persistProxySettings(http: Int, socks: Int, forwards: String) {
        UserDefaults.standard.set(String(http), forKey: "proxyHTTPPort")
        UserDefaults.standard.set(String(socks), forKey: "proxySOCKSPort")
        if let index = profiles.firstIndex(where: { $0.id == selectedID }) {
            profiles[index].forwards = forwards
            persistProfiles()
        }
    }

    private func applyProxySettings() {
        guard let config = validatedProxyConfig() else {
            proxyMessage = "실패: 포트 또는 포워딩 형식을 확인하세요."
            return
        }
        let savedForwardText = forwardText
        guard connected else {
            persistProxySettings(http: config.http, socks: config.socks, forwards: savedForwardText)
            proxyMessage = selectedID.isEmpty
                ? "프락시 포트를 저장했습니다. 포워딩 규칙은 프로필 저장 후 유지됩니다."
                : "저장했습니다. 다음 연결부터 적용됩니다."
            return
        }
        guard let directory = sessionDirectory else {
            proxyMessage = "실패: 연결 정보를 찾을 수 없습니다."
            return
        }
        let socketPath = directory.appendingPathComponent("control.sock").path
        let lines = config.forwards.map { rule -> String in
            let fields = rule.split(separator: ":")
            return "F \(fields[0]) \(fields[1]) \(fields[2])\n"
        }.joined()
        let command = "APPLY \(config.http) \(config.socks)\n\(lines)END\n"
        applyingSettings = true
        proxyMessage = "현재 연결에 설정을 적용하는 중입니다."
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try controlRequest(path: socketPath, command: command) }
            DispatchQueue.main.async {
                applyingSettings = false
                switch result {
                case .success(let reply) where reply == "OK APPLY\n":
                    persistProxySettings(http: config.http, socks: config.socks, forwards: savedForwardText)
                    proxyMessage = "현재 연결에 적용했습니다. 새 연결부터 변경된 설정을 사용합니다."
                case .success(let reply):
                    let parts = reply.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
                    if parts.count == 3, parts[0] == "ERR", parts[1] == "APPLY",
                       let port = Int(parts[2]), port > 0 {
                        proxyMessage = "실패: 로컬 포트 \(port)를 열 수 없습니다."
                    } else {
                        proxyMessage = "실패: 설정 형식 또는 포트 충돌을 확인하세요."
                    }
                case .failure(let error):
                    proxyMessage = "실패: 현재 연결에 적용하지 못했습니다: \(error.localizedDescription)"
                }
            }
        }
    }

    private func formattedBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }

    private func formattedDuration(_ seconds: UInt64) -> String {
        String(format: "%02llu:%02llu:%02llu", seconds / 3600, (seconds / 60) % 60, seconds % 60)
    }

    @discardableResult private func saveProfile() -> VPNProfile? {
        let host = server.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, !user.isEmpty,
              !host.contains(where: { $0.isWhitespace || $0 == "'" || $0 == "\"" || $0 == "\\" }),
              !user.contains("\n"), !user.contains("\r"),
              !password.contains("\n"), !password.contains("\r") else {
            message = "실패: 서버와 아이디를 확인하세요."
            return nil
        }
        let id = selectedID.isEmpty ? UUID().uuidString : selectedID
        let name = profileName.trimmingCharacters(in: .whitespacesAndNewlines)
        let existingForwards = selectedID.isEmpty ? forwardText : profiles.first(where: { $0.id == id })?.forwards
        let profile = VPNProfile(id: id, name: name.isEmpty ? host : name, server: host,
                                 username: user, forwards: existingForwards)
        do {
            if !password.isEmpty { try KeychainPassword.save(password, account: id) }
            guard try KeychainPassword.read(account: id) != nil else {
                message = "실패: VPN 계정 암호를 입력하세요."; return nil
            }
        } catch { message = "실패: 키체인 저장 오류: \(error.localizedDescription)"; return nil }
        if let index = profiles.firstIndex(where: { $0.id == id }) { profiles[index] = profile }
        else { profiles.append(profile) }
        persistProfiles()
        selectedID = id; profileName = profile.name; password = ""; hasStoredPassword = true
        UserDefaults.standard.set(id, forKey: "selectedVPNProfile")
        UserDefaults.standard.set(httpPort, forKey: "proxyHTTPPort")
        UserDefaults.standard.set(socksPort, forKey: "proxySOCKSPort")
        message = "프로필을 저장했습니다."
        return profile
    }

    private func deleteProfile() {
        guard !selectedID.isEmpty else { return }
        do { try KeychainPassword.delete(account: selectedID) }
        catch { message = "실패: 키체인 삭제 오류: \(error.localizedDescription)"; return }
        profiles.removeAll(where: { $0.id == selectedID })
        persistProfiles(); selectedID = ""; clearForm()
        UserDefaults.standard.removeObject(forKey: "selectedVPNProfile")
        message = "프로필과 키체인 암호를 삭제했습니다."
    }

    private func connect() {
        guard let proxyPath, let pptpPath else { message = "실패: 앱 번들에 실행 파일이 없습니다."; return }
        guard let config = validatedProxyConfig() else {
            message = "실패: 프락시 설정 화면의 포트와 포워딩 규칙을 확인하세요."
            return
        }
        guard let profile = saveProfile() else { return }
        persistProxySettings(http: config.http, socks: config.socks, forwards: forwardText)
        let secret: String
        do { guard let stored = try KeychainPassword.read(account: profile.id) else { message = "실패: 저장된 암호가 없습니다."; return }; secret = stored }
        catch { message = "실패: 키체인 암호 읽기 오류: \(error.localizedDescription)"; return }

        // Keep the control socket outside the system's purgeable temporary directory.
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/PPTPProxy", isDirectory: true)
        let directory = base.appendingPathComponent("s-\(UUID().uuidString.prefix(12))", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            let fifo = directory.appendingPathComponent("password.fifo")
            guard Darwin.mkfifo(fifo.path, 0o600) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            let control = directory.appendingPathComponent("control.sock")
            let log = directory.appendingPathComponent("connection.log")
            sessionDirectory = directory; logURL = log; logText = "연결 로그를 기다리는 중입니다."
            ConnectionActivity.shared.controlSocketPath = control.path
            connecting = true; message = "관리자 권한을 확인한 뒤 PPTP 연결을 시작합니다."
            ConnectionActivity.shared.isActive = true
            sentBytes = 0; receivedBytes = 0; connectedSeconds = 0
            var args = ["--server", profile.server, "--user", profile.username, "--pptp", pptpPath,
                        "--password-fifo", fifo.path, "--control-socket", control.path,
                        "--http", String(config.http), "--socks", String(config.socks)]
            for rule in config.forwards { args += ["--forward", rule] }
            let command = "umask 022; \(shellQuote(proxyPath)) \(args.map(shellQuote).joined(separator: " ")) >\(shellQuote(log.path)) 2>&1 </dev/null & echo $!"
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let pidText = try privileged(command)
                    guard let pid = Int32(pidText.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 else {
                        throw NSError(domain: "PPTPProxyClient", code: 1,
                                      userInfo: [NSLocalizedDescriptionKey: pidText])
                    }
                    DispatchQueue.main.async { processID = pid; connected = true; message = "PPP/MPPE 협상 중입니다." }
                    try writeSecret(secret, to: fifo)
                    try? FileManager.default.removeItem(at: fifo)
                } catch {
                    DispatchQueue.main.async {
                        connecting = false; connected = false
                        ConnectionActivity.shared.isActive = false
                        ConnectionActivity.shared.controlSocketPath = nil
                        message = "실패: 연결 시작 오류: \(error.localizedDescription)"
                    }
                    try? FileManager.default.removeItem(at: fifo)
                }
            }
        } catch {
            connecting = false
            ConnectionActivity.shared.isActive = false
            ConnectionActivity.shared.controlSocketPath = nil
            message = "실패: 연결 준비 오류: \(error.localizedDescription)"
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func disconnect() {
        guard !disconnecting else { return }
        guard let directory = sessionDirectory else {
            clearConnection()
            message = "연결이 이미 종료됐습니다."
            return
        }
        let socketPath = directory.appendingPathComponent("control.sock").path
        disconnecting = true
        message = "연결 해제를 요청하는 중입니다."
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try controlRequest(path: socketPath, command: "STOP\n") }
            DispatchQueue.main.async {
                guard sessionDirectory == directory else { return }
                switch result {
                case .success("OK STOP\n"):
                    message = "연결 해제 요청을 보냈습니다. 종료를 기다리는 중입니다."
                case .success(let reply):
                    disconnecting = false
                    message = "실패: 연결 해제 응답이 올바르지 않습니다: \(reply.trimmingCharacters(in: .whitespacesAndNewlines))"
                case .failure(let error):
                    if connecting && processID == nil {
                        disconnecting = false
                        message = "관리자 권한 확인 창을 먼저 취소하거나 완료한 뒤 연결을 해제하세요."
                    } else if !FileManager.default.fileExists(atPath: socketPath) ||
                              (processID.map { !processIsRunning($0) } ?? false) {
                        clearConnection()
                        message = "연결 프로세스가 이미 종료돼 화면 상태를 정리했습니다."
                    } else {
                        disconnecting = false
                        message = "실패: 연결 해제 요청을 보낼 수 없습니다: \(error.localizedDescription)"
                    }
                }
            }
        }
    }

    private func cleanupOrphanBackend() {
        guard let executable = proxyPath, let config = validatedProxyConfig() else {
            message = "실패: 앱 실행 파일과 프락시 포트를 확인하세요."
            return
        }
        cleaningUp = true
        message = "남은 연결을 확인하는 중입니다. 관리자 권한을 요청할 수 있습니다."
        let expected = shellQuote("n" + executable)
        let command = """
        stopped=0
        for port in \(config.http) \(config.socks); do
          for pid in $(/usr/sbin/lsof -nP -t -iTCP:$port -sTCP:LISTEN); do
            if /usr/sbin/lsof -nP -p "$pid" -a -d txt -Fn | /usr/bin/grep -Fxq \(expected); then
              /bin/kill -TERM "$pid" || exit 1
              stopped=1
              /bin/sleep 2
              if /usr/sbin/lsof -nP -t -iTCP:$port -sTCP:LISTEN | /usr/bin/grep -Fxq "$pid" &&
                 /usr/sbin/lsof -nP -p "$pid" -a -d txt -Fn | /usr/bin/grep -Fxq \(expected); then
                /bin/kill -KILL "$pid" || exit 1
              fi
            fi
          done
        done
        echo "$stopped"
        """
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try privileged(command) }
            DispatchQueue.main.async {
                cleaningUp = false
                switch result {
                case .success(let text) where text.trimmingCharacters(in: .whitespacesAndNewlines) == "1":
                    message = "남은 PPTP 프락시 프로세스에 종료를 요청했습니다. 잠시 뒤 다시 연결하세요."
                case .success:
                    message = "현재 프락시 포트에서 이 앱의 남은 연결을 찾지 못했습니다."
                case .failure(let error):
                    message = "실패: 남은 연결 정리 오류: \(error.localizedDescription)"
                }
            }
        }
    }

    private func processIsRunning(_ pid: Int32) -> Bool {
        Darwin.kill(pid, 0) == 0 || errno == EPERM
    }

    private func clearConnection() {
        connecting = false; connected = false; tunnelReady = false; disconnecting = false
        processID = nil
        sentBytes = 0; receivedBytes = 0; connectedSeconds = 0
        statusRequestInFlight = false; statusFailures = 0
        ConnectionActivity.shared.isActive = false
        ConnectionActivity.shared.controlSocketPath = nil
        page = .profile
        if let directory = sessionDirectory {
            let fifo = directory.appendingPathComponent("password.fifo")
            try? FileManager.default.removeItem(at: fifo)
        }
        sessionDirectory = nil
    }

    private func refreshConnectionState() {
        guard let processID else { return }
        if processIsRunning(processID) {
            if !tunnelReady, let logURL,
               let log = try? String(contentsOf: logURL, encoding: .utf8),
               log.contains("PPP/MPPE 연결됨") {
                tunnelReady = true; connecting = false
                page = .proxy
                message = "PPP/MPPE 연결됨. 프락시에서 원격 접속을 시도할 수 있습니다."
            }
            return
        }
        let log = logURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        let wasDisconnecting = disconnecting
        clearConnection()
        if wasDisconnecting { message = "연결을 해제했습니다."; return }
        if log.contains("PPTP 프로세스 종료") && !log.contains("PPP/MPPE 연결됨") {
            message = "실패: PPTP 데이터 채널이 열리지 않았습니다. GRE 경로와 로그를 확인하세요."
        } else if log.contains("PPP 연결 종료/실패") {
            message = "실패: PPP 협상 또는 인증이 종료됐습니다. 로그를 확인하세요."
        } else { message = "연결이 종료됐습니다." }
    }

    private func refreshBackendStatus() {
        guard !statusRequestInFlight, let directory = sessionDirectory else { return }
        statusRequestInFlight = true
        let socketPath = directory.appendingPathComponent("control.sock").path
        DispatchQueue.global(qos: .utility).async {
            let reply = try? controlRequest(path: socketPath, command: "STATUS\n")
            DispatchQueue.main.async {
                statusRequestInFlight = false
                guard connected, sessionDirectory == directory else { return }
                guard let fields = reply?.split(separator: " "), fields.count == 7,
                      fields[0] == "STATUS",
                      let sent = UInt64(fields[2]), let received = UInt64(fields[3]),
                      let elapsed = UInt64(fields[4]) else {
                    statusFailures += 1
                    if statusFailures >= 2 {
                        if disconnecting || !FileManager.default.fileExists(atPath: socketPath) ||
                           (processID.map { !processIsRunning($0) } ?? false) {
                            let wasDisconnecting = disconnecting
                            clearConnection()
                            message = wasDisconnecting ? "연결을 해제했습니다." : "연결 프로세스가 종료돼 화면 상태를 정리했습니다."
                        } else {
                            message = "실패: 연결 상태를 확인할 수 없습니다. 다시 시도하거나 로그를 확인하세요."
                        }
                    }
                    return
                }
                statusFailures = 0
                sentBytes = sent; receivedBytes = received; connectedSeconds = elapsed
                if disconnecting { return }
                if fields[1] == "1" && !tunnelReady {
                    tunnelReady = true; connecting = false; page = .proxy
                    message = "PPP/MPPE 연결됨. 프락시에서 원격 접속을 시도할 수 있습니다."
                } else if fields[1] == "0" && tunnelReady {
                    tunnelReady = false; page = .profile
                    message = "실패: PPP 연결이 끊어졌습니다. 로그를 확인하세요."
                }
            }
        }
    }

    private func loadLatestLog() {
        let locations = [FileManager.default.temporaryDirectory,
                         FileManager.default.homeDirectoryForCurrentUser
                            .appendingPathComponent("Library/Application Support/PPTPProxy", isDirectory: true)]
        let directories = locations.flatMap { location in
            (try? FileManager.default.contentsOfDirectory(at: location,
                includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        }
        let latest = directories.filter {
            ($0.lastPathComponent.hasPrefix("ptvpn-") || $0.lastPathComponent.hasPrefix("pptp-proxy-") ||
             $0.lastPathComponent.hasPrefix("s-")) &&
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("connection.log").path)
        }
            .max { left, right in
                let l = (try? left.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let r = (try? right.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return l < r
            }
        if let latest { logURL = latest.appendingPathComponent("connection.log") }
    }

    private func refreshLog() {
        guard let logURL, let file = try? FileHandle(forReadingFrom: logURL) else {
            logText = "연결 로그를 기다리는 중입니다."; return
        }
        defer { try? file.close() }
        do {
            let end = try file.seekToEnd()
            try file.seek(toOffset: end > 65536 ? end - 65536 : 0)
            logText = String(decoding: try file.readToEnd() ?? Data(), as: UTF8.self)
        } catch { logText = "로그 읽기 실패: \(error.localizedDescription)" }
    }
}

private func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

private func privileged(_ command: String) throws -> String {
    let quoted = "\"" + command.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", "do shell script \(quoted) with administrator privileges"]
    let output = Pipe()
    process.standardOutput = output; process.standardError = output
    try process.run()
    process.waitUntilExit()
    let result = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    guard process.terminationStatus == 0 else {
        throw NSError(domain: "PPTPProxyClient", code: Int(process.terminationStatus),
                      userInfo: [NSLocalizedDescriptionKey: result])
    }
    return result
}

private func controlRequest(path: String, command: String) throws -> String {
    let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    defer { Darwin.close(descriptor) }
    var noSignal: Int32 = 1
    setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal)))
    var timeout = timeval(tv_sec: 1, tv_usec: 0)
    setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(path.utf8CString)
    guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
        throw NSError(domain: "PPTPProxyClient", code: 3,
                      userInfo: [NSLocalizedDescriptionKey: tr("제어 소켓 경로가 너무 깁니다.")])
    }
    withUnsafeMutableBytes(of: &address.sun_path) { raw in
        for i in pathBytes.indices { raw[i] = UInt8(bitPattern: pathBytes[i]) }
    }
    let result = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }

    let bytes = Array(command.utf8)
    try bytes.withUnsafeBytes { raw in
        guard let base = raw.baseAddress else { return }
        var offset = 0
        while offset < raw.count {
            let written = Darwin.send(descriptor, base.advanced(by: offset), raw.count - offset, 0)
            if written > 0 { offset += written }
            else if written < 0 && errno == EINTR { continue }
            else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        }
    }
    Darwin.shutdown(descriptor, SHUT_WR)
    var reply = [UInt8](repeating: 0, count: 512)
    let count = reply.withUnsafeMutableBytes { raw -> Int in
        guard let base = raw.baseAddress else { return -1 }
        return Darwin.read(descriptor, base, raw.count)
    }
    guard count > 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    return String(decoding: reply.prefix(count), as: UTF8.self)
}

private func writeSecret(_ secret: String, to fifo: URL) throws {
    Darwin.signal(SIGPIPE, SIG_IGN)
    var descriptor: Int32 = -1
    for _ in 0..<100 {
        descriptor = Darwin.open(fifo.path, O_WRONLY | O_NONBLOCK)
        if descriptor >= 0 { break }
        if errno != ENXIO && errno != EINTR {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        Thread.sleep(forTimeInterval: 0.1)
    }
    guard descriptor >= 0 else {
        throw NSError(domain: "PPTPProxyClient", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: tr("VPN 암호 전달 대기 시간이 초과됐습니다.")])
    }
    defer { Darwin.close(descriptor) }
    let bytes = Array((secret + "\n").utf8)
    try bytes.withUnsafeBytes { raw in
        guard let base = raw.baseAddress else { return }
        var offset = 0
        while offset < raw.count {
            let written = Darwin.write(descriptor, base.advanced(by: offset), raw.count - offset)
            if written > 0 { offset += written }
            else if written < 0 && errno == EINTR { continue }
            else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        }
    }
}

private struct VPNProfile: Codable, Identifiable {
    var id: String
    var name: String
    var server: String
    var username: String
    var forwards: String?
}

private enum KeychainPassword {
    private static let service = "local.codex.pptpclient.vpn-password"
    private static func query(account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
    static func save(_ password: String, account: String) throws {
        let data = Data(password.utf8)
        var attributes = query(account: account)
        attributes[kSecValueData as String] = data
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let updated = SecItemUpdate(query(account: account) as CFDictionary,
                                        [kSecValueData as String: data] as CFDictionary)
            guard updated == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(updated)) }
        } else if status != errSecSuccess { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
    static func read(account: String) throws -> String? {
        var attributes = query(account: account)
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        return value
    }
    static func delete(account: String) throws {
        let status = SecItemDelete(query(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }
}
