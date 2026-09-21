import Foundation

/// Application Support state directory for PokeTokenBar files.
/// `PTB_STATE_DIR` overrides the default for development/QA isolation.
enum AppStatePaths {
    static func directory() -> URL {
        let override = (ProcessInfo.processInfo.environment["PTB_STATE_DIR"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let dir: URL
        if !override.isEmpty {
            dir = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("PokeTokenBar")
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 농담 생성용 claude CLI 를 돌리는 작업 디렉터리.
    ///
    /// CLI 도 세션마다 전사를 남기기 때문에, 그냥 두면 recap 감시자가 그 전사를 "가장 최근 대화"로
    /// 잡아 농담 생성 응답을 말풍선에 띄운다. 전사에 `cwd` 가 기록되므로 전용 경로에서 돌리고
    /// recap 쪽에서 그 경로의 세션을 걸러낸다.
    static func jokeSessionDirectory() -> URL {
        let dir = directory().appendingPathComponent("joke-session", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
