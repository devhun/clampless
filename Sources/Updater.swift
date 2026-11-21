// GitHub Release 기반 자동 업데이트.
//
// api.github.com 은 비인증 요청이 IP당 시간당 60회로 제한되므로 사용하지 않는다.
// 대신 https://github.com/<repo>/releases/latest 에 HEAD 요청을 보내
// 302 리다이렉트의 Location(/releases/tag/<tag>)에서 최신 태그를 읽는다.
// 에셋도 github.com/<repo>/releases/download/<tag>/<name> 으로 직접 받는다.

import AppKit
import CryptoKit

enum UpdateError: LocalizedError {
    case unexpectedRedirect(String)
    case http(Int, String)
    case checksumNotFound(String)
    case checksumMismatch
    case invalidBundle
    case notInstallable(String)

    var errorDescription: String? {
        switch self {
        case .unexpectedRedirect(let l): return "최신 릴리즈 정보를 읽지 못했습니다 (\(l))"
        case .http(let code, let url): return "HTTP \(code): \(url)"
        case .checksumNotFound(let name): return "checksums.txt 에 \(name) 항목이 없습니다"
        case .checksumMismatch: return "다운로드한 파일의 체크섬이 일치하지 않습니다"
        case .invalidBundle: return "다운로드한 앱 번들이 올바르지 않습니다"
        case .notInstallable(let why): return why
        }
    }
}

final class Updater: NSObject, URLSessionTaskDelegate {
    static let repo = "devhun/clampless"
    static let checkInterval: TimeInterval = 60 * 60 // 1시간

    /// 리다이렉트를 따라가지 않는 세션 (Location 헤더를 직접 읽기 위함)
    private lazy var noRedirectSession = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
    private let session = URLSession(configuration: .ephemeral)

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    var releasesPageURL: URL { URL(string: "https://github.com/\(Self.repo)/releases/latest")! }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    // MARK: 버전 확인

    /// 최신 릴리즈 태그 (예: "v1.2.0")
    func fetchLatestTag() throws -> String {
        var req = URLRequest(url: releasesPageURL, timeoutInterval: 30)
        req.httpMethod = "HEAD"
        req.setValue("Clampless/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let (_, response) = try sync(noRedirectSession, req)
        let location = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Location") ?? ""
        guard let range = location.range(of: "/releases/tag/") else {
            throw UpdateError.unexpectedRedirect(location)
        }
        return String(location[range.upperBound...])
    }

    /// "v1.2.3" / "1.2.3" → [1,2,3]. 형식이 다르면(개발 빌드 "0.0.0-dev" 등) nil
    static func parseVersion(_ v: String) -> [Int]? {
        let s = v.hasPrefix("v") ? String(v.dropFirst()) : v
        let parts = s.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard parts.count == 3, !parts.contains(where: { $0 == nil }) else { return nil }
        return parts.map { $0! }
    }

    static func isNewer(_ latest: String, than current: String) -> Bool {
        guard let l = parseVersion(latest), let c = parseVersion(current) else { return false }
        return c.lexicographicallyPrecedes(l)
    }

    /// 새 버전이 있으면 태그, 없으면 nil
    func checkForUpdate() throws -> String? {
        let tag = try fetchLatestTag()
        return Self.isNewer(tag, than: currentVersion) ? tag : nil
    }

    // MARK: 설치 가능 여부

    /// 개발 빌드가 아니고, 앱이 들어 있는 폴더에 쓸 수 있어야 자동 교체 가능
    func installBlocker() -> String? {
        if Self.parseVersion(currentVersion) == nil {
            return "개발 빌드(\(currentVersion))는 자동 업데이트하지 않습니다"
        }
        let parent = (Bundle.main.bundlePath as NSString).deletingLastPathComponent
        if !FileManager.default.isWritableFile(atPath: parent) {
            return "\(parent) 에 쓰기 권한이 없어 자동으로 교체할 수 없습니다"
        }
        return nil
    }

    // MARK: 다운로드 + 검증

    static func assetName(for tag: String) -> String { "Clampless-\(tag)-macos-universal.zip" }

    private func assetURL(_ tag: String, _ name: String) -> URL {
        URL(string: "https://github.com/\(Self.repo)/releases/download/\(tag)/\(name)")!
    }

    /// zip을 받아 checksums.txt 로 검증하고, 앱 옆 임시 폴더에 풀어 새 번들 경로를 반환
    func downloadAndStage(tag: String) throws -> URL {
        if let why = installBlocker() { throw UpdateError.notInstallable(why) }
        let name = Self.assetName(for: tag)

        let sums = String(decoding: try get(assetURL(tag, "checksums.txt")), as: UTF8.self)
        guard let expected = Self.findChecksum(sums, name: name) else { throw UpdateError.checksumNotFound(name) }

        let zip = try get(assetURL(tag, name), timeout: 300)
        let actual = SHA256.hash(data: zip).map { String(format: "%02x", $0) }.joined()
        guard actual == expected else { throw UpdateError.checksumMismatch }

        // 같은 볼륨에서 mv 할 수 있도록 앱이 있는 폴더 안에 스테이징
        let fm = FileManager.default
        let parent = URL(fileURLWithPath: Bundle.main.bundlePath).deletingLastPathComponent()
        let stage = parent.appendingPathComponent(".Clampless-update")
        try? fm.removeItem(at: stage)
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        let zipURL = stage.appendingPathComponent(name)
        try zip.write(to: zipURL)

        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zipURL.path, stage.path]
        try ditto.run()
        ditto.waitUntilExit()

        let newApp = stage.appendingPathComponent("Clampless.app")
        guard ditto.terminationStatus == 0,
              let bundle = Bundle(url: newApp),
              bundle.bundleIdentifier == Bundle.main.bundleIdentifier,
              let v = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              Self.parseVersion(v) == Self.parseVersion(tag)
        else { throw UpdateError.invalidBundle }
        try? fm.removeItem(at: zipURL)
        return newApp
    }

    static func findChecksum(_ sums: String, name: String) -> String? {
        for line in sums.split(separator: "\n") {
            let f = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if f.count == 2, f[1].hasPrefix("*") ? f[1].dropFirst() == name : f[1] == name {
                return f[0].lowercased()
            }
        }
        return nil
    }

    // MARK: 교체 + 재실행

    /// 이 프로세스가 끝나기를 기다렸다가 번들을 교체하고 새 버전을 실행하는 셸을 띄운다.
    /// 호출 후 앱을 종료해야 한다.
    func launchInstaller(newApp: URL) throws {
        let dest = Bundle.main.bundlePath
        let script = """
        pid="$1"; dest="$2"; new="$3"; stage="$(dirname "$new")"
        while kill -0 "$pid" 2>/dev/null; do sleep 0.2; done
        rm -rf "$dest.old"
        if mv "$dest" "$dest.old" && mv "$new" "$dest"; then
            rm -rf "$dest.old"
        else
            [ -d "$dest" ] || mv "$dest.old" "$dest"
        fi
        rm -rf "$stage"
        /usr/bin/xattr -dr com.apple.quarantine "$dest" 2>/dev/null
        /usr/bin/open "$dest"
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, "sh", String(ProcessInfo.processInfo.processIdentifier), dest, newApp.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
    }

    // MARK: HTTP helpers (백그라운드 큐에서 호출)

    private func get(_ url: URL, timeout: TimeInterval = 30) throws -> Data {
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.setValue("Clampless/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try sync(session, req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw UpdateError.http(code, url.absoluteString) }
        return data
    }

    private func sync(_ session: URLSession, _ req: URLRequest) throws -> (Data, URLResponse) {
        let sem = DispatchSemaphore(value: 0)
        var result: Result<(Data, URLResponse), Error>!
        session.dataTask(with: req) { data, response, error in
            if let error { result = .failure(error) }
            else { result = .success((data ?? Data(), response!)) }
            sem.signal()
        }.resume()
        sem.wait()
        return try result.get()
    }
}
