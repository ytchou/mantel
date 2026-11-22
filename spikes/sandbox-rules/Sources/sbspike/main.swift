// Throwaway probe run under /usr/bin/sandbox-exec by run.sh.
// Each subcommand prints one "RESULT <name> OK|FAIL <detail>" line.
//
//   sbspike fm                      FoundationModels: availability, then one prompt
//   sbspike thumb <file>            QLThumbnailGenerator thumbnail of <file>
//   sbspike read <path>             read a file, or list a folder
//   sbspike write <path>            write a small file
//   sbspike tcp <host> <port>       plain TCP connect (no proxy)
//   sbspike url <url>               URLSession GET, no proxy
//   sbspike proxy <port> <url> [dict|config]
//                                   URLSession GET through an HTTPS proxy at localhost:<port>
//   sbspike dns <name>              getaddrinfo
//   sbspike prefs-read <domain>     UserDefaults(suiteName:) and CFPreferences key count
//   sbspike prefs-write <domain>    write and read back a key through both APIs
import Foundation
import FoundationModels
import Network
import QuickLookThumbnailing

func result(_ name: String, _ ok: Bool, _ detail: String) -> Never {
    print("RESULT \(name) \(ok ? "OK" : "FAIL") \(detail)")
    fflush(stdout)
    exit(ok ? 0 : 1)
}

let args = CommandLine.arguments
guard args.count >= 2 else { result("usage", false, "no subcommand") }

func runAsync(_ body: @escaping @Sendable () async -> Never) -> Never {
    Task { await body() }
    dispatchMain()
}

switch args[1] {
case "fm":
    runAsync {
        let model = SystemLanguageModel.default
        let availability = "\(model.availability)"
        guard case .available = model.availability else { result("fm", false, "availability=\(availability)") }
        let start = Date()
        do {
            let session = LanguageModelSession()
            let answer = try await session.respond(to: "Reply with the single word: ready")
            let text = answer.content.prefix(40).replacingOccurrences(of: "\n", with: " ")
            result("fm", true, "availability=\(availability) answer=\"\(text)\" in \(String(format: "%.1f", Date().timeIntervalSince(start)))s")
        } catch {
            result("fm", false, "availability=\(availability) error=\(error)")
        }
    }

case "thumb" where args.count >= 3:
    let url = URL(fileURLWithPath: args[2])
    let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 128, height: 128), scale: 2, representationTypes: .thumbnail)
    QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, error in
        if let rep { result("thumb", true, "type=\(rep.type.rawValue) size=\(rep.cgImage.width)x\(rep.cgImage.height)") }
        result("thumb", false, "error=\(error.map { "\($0)" } ?? "nil")")
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 30) { result("thumb", false, "timeout") }
    dispatchMain()

case "read" where args.count >= 3:
    let path = args[2]
    var isDir: ObjCBool = false
    if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
        do { result("read", true, "listed \(try FileManager.default.contentsOfDirectory(atPath: path).count) entries") }
        catch { result("read", false, "\((error as NSError).code) \(error.localizedDescription)") }
    }
    let fd = open(path, O_RDONLY)
    if fd < 0 { result("read", false, "errno=\(errno) \(String(cString: strerror(errno)))") }
    var buf = [UInt8](repeating: 0, count: 64)
    let n = Darwin.read(fd, &buf, 64)
    close(fd)
    result("read", n >= 0, n >= 0 ? "read \(n) bytes" : "read errno=\(errno)")

case "write" where args.count >= 3:
    do { try Data("spike".utf8).write(to: URL(fileURLWithPath: args[2])); result("write", true, "wrote") }
    catch { result("write", false, "\((error as NSError).code)") }

case "tcp" where args.count >= 4:
    // BSD socket so the sandbox decision is the only thing measured.
    var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_STREAM, ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
    var info: UnsafeMutablePointer<addrinfo>?
    let rc = getaddrinfo(args[2], args[3], &hints, &info)
    guard rc == 0, let info else { result("tcp", false, "getaddrinfo=\(rc) \(String(cString: gai_strerror(rc)))") }
    let s = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
    if s < 0 { result("tcp", false, "socket errno=\(errno) \(String(cString: strerror(errno)))") }
    let c = connect(s, info.pointee.ai_addr, info.pointee.ai_addrlen)
    let e = errno
    close(s)
    result("tcp", c == 0, c == 0 ? "connected" : "connect errno=\(e) \(String(cString: strerror(e)))")

case "url" where args.count >= 3:
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 10
    URLSession(configuration: config).dataTask(with: URL(string: args[2])!) { data, response, error in
        if let http = response as? HTTPURLResponse { result("url", true, "status=\(http.statusCode) bytes=\(data?.count ?? 0)") }
        result("url", false, "error=\((error as NSError?)?.code ?? 0) \(error?.localizedDescription ?? "")")
    }.resume()
    dispatchMain()

case "proxy" where args.count >= 4:
    let port = Int(args[2])!
    let style = args.count >= 5 ? args[4] : "dict"
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 15
    if style == "config" {
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(port))!)
        config.proxyConfigurations = [ProxyConfiguration(httpCONNECTProxy: endpoint)]
    } else {
        config.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPSEnable as String: 1,
            kCFNetworkProxiesHTTPSProxy as String: "127.0.0.1",
            kCFNetworkProxiesHTTPSPort as String: port,
        ]
    }
    URLSession(configuration: config).dataTask(with: URL(string: args[3])!) { data, response, error in
        if let http = response as? HTTPURLResponse { result("proxy-\(style)", true, "status=\(http.statusCode) bytes=\(data?.count ?? 0)") }
        result("proxy-\(style)", false, "error=\((error as NSError?)?.code ?? 0) \(error?.localizedDescription ?? "")")
    }.resume()
    dispatchMain()

case "dns" where args.count >= 3:
    var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
    var info: UnsafeMutablePointer<addrinfo>?
    let start = Date()
    let rc = getaddrinfo(args[2], "443", &hints, &info)
    let ms = Int(Date().timeIntervalSince(start) * 1000)
    if rc == 0, let info {
        var count = 0
        var p: UnsafeMutablePointer<addrinfo>? = info
        while let q = p { count += 1; p = q.pointee.ai_next }
        freeaddrinfo(info)
        result("dns", true, "resolved \(count) addresses in \(ms) ms")
    }
    result("dns", false, "getaddrinfo=\(rc) \(String(cString: gai_strerror(rc))) in \(ms) ms")

case "prefs-read" where args.count >= 3:
    let domain = args[2]
    let ud = UserDefaults(suiteName: domain)?.persistentDomain(forName: domain)?.count ?? -1
    let cfKeys = CFPreferencesCopyKeyList(domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String]
    let cf = cfKeys?.count ?? -1
    // Values are never printed: only whether anything came back, and how many keys.
    result("prefs-read", ud > 0 || cf > 0, "userDefaultsKeys=\(ud) cfPreferencesKeys=\(cf)")

case "prefs-write" where args.count >= 3:
    let domain = args[2]
    if domain == "dev.topnotch.TopNotch" { result("prefs-write", false, "refused: never write the real domain") }
    let stamp = "\(Date().timeIntervalSince1970)"
    let ud = UserDefaults(suiteName: domain)
    ud?.set(stamp, forKey: "spikeUD")
    CFPreferencesSetAppValue("spikeCF" as CFString, stamp as CFString, domain as CFString)
    let synced = CFPreferencesAppSynchronize(domain as CFString)
    // Read back through a fresh path so a process-local cache does not answer.
    let backCF = CFPreferencesCopyAppValue("spikeCF" as CFString, domain as CFString) as? String
    let backUD = UserDefaults(suiteName: domain)?.string(forKey: "spikeUD")
    result("prefs-write", backCF == stamp && backUD == stamp, "synchronize=\(synced) cfBack=\(backCF == stamp) udBack=\(backUD == stamp)")

default:
    result("usage", false, "bad arguments: \(args.dropFirst().joined(separator: " "))")
}
