import Foundation

/// Claude Code 가 방금 한 말을 pet 말풍선으로 흘려보내는 감시자.
///
/// 가장 최근에 쓰인 전사(`~/.claude/projects/**/*.jsonl`)의 마지막 assistant 응답을 뽑는다.
/// 마지막으로 띄운 것보다 나중에 쓰인 응답만 띄우므로, 대화가 멈추면 말풍선도 저절로 멈춘다.
/// 글자만 비교하면 다른 창의 옛 응답으로 옮겨갔을 때도 새 말인 줄 알고 띄운다.
/// 전사는 세션당 수십 MB 까지 커져서 파일 전체를 읽지 않고 끝부분만 되짚는다.
@MainActor
final class ClaudeRecapWatcher {
    /// 되짚어 읽을 꼬리 크기. 한 줄이 이 크기를 넘으면 그 줄은 통째로 건너뛴다 —
    /// 마지막 응답을 놓치더라도 파일 크기에 비례하는 읽기를 만들지 않는 쪽을 택한다.
    static let tailBytes = 512 * 1024

    private let roots: () -> [URL]
    /// 이 경로에서 시작된 세션은 건너뛴다. 앱이 농담을 만들려고 띄운 claude CLI 의 전사다.
    private let excludedCwd: String?
    private let interval: TimeInterval
    private let onRecap: (Recap) -> Void
    /// 마지막으로 띄운 응답이 쓰인 시각. nil 이면 기준선 미설정 — 앱을 켜자마자 지난 대화를
    /// 띄우지 않도록 첫 tick 은 표시 없이 기준선만 잡는다.
    private var lastShownAt: Date?
    private var timer: Timer?

    init(roots: @escaping () -> [URL] = { LocalUsageReader.claudeProjectRoots },
         excludedCwd: String? = AppStatePaths.jokeSessionDirectory().path,
         interval: TimeInterval = 5,
         onRecap: @escaping (Recap) -> Void) {
        self.roots = roots
        self.excludedCwd = excludedCwd
        self.interval = interval
        self.onRecap = onRecap
    }

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: interval, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.poll() }
        }
        t.tolerance = interval * 0.5
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        guard let url = Self.newestTranscript(in: roots()),
              let recap = Self.latestRecap(in: url, excludingCwd: excludedCwd) else { return }
        let armed = lastShownAt != nil
        guard recap.at > (lastShownAt ?? .distantPast) else { return }
        lastShownAt = recap.at
        guard armed else { return }
        onRecap(recap)
    }

    /// 말풍선 한 장. 제목은 Claude Code 가 붙인 세션 이름, 본문은 방금 한 말이다.
    /// `at` 은 그 응답이 전사에 쓰인 시각 — 새 응답인지 판정하는 기준이다.
    struct Recap: Equatable {
        let title: String
        let sentence: String
        let at: Date
    }

    /// 전사에 세션 이름이 없을 때 제목 자리에 쓸 값.
    static let fallbackTitle = "Claude"

    // MARK: 전사 읽기

    /// 모든 projects 루트를 통틀어 가장 최근에 쓰인 전사. 여러 세션이 동시에 돌아도
    /// 방금 손댄 대화 하나만 따라간다.
    static func newestTranscript(in roots: [URL]) -> URL? {
        var newest: (url: URL, date: Date)?
        for root in roots {
            guard let walker = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in walker where url.pathExtension == "jsonl" {
                guard let date = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate else { continue }
                if newest == nil || date > newest!.date { newest = (url, date) }
            }
        }
        return newest?.url
    }

    /// 파일 끝에서부터 되짚어 첫 assistant 응답의 첫 문장과 그 세션의 이름을 찾는다.
    /// 세션 이름은 대화가 길어지면 갱신되므로 끝에서 만난 것이 가장 최근 값이다.
    static func latestRecap(in url: URL, tailBytes: Int = ClaudeRecapWatcher.tailBytes,
                            excludingCwd: String? = nil) -> Recap? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.readToEnd() else { return nil }

        var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        // 꼬리를 자른 지점의 첫 줄은 앞이 잘려 있어 파싱되지 않는다. 버리고 시작한다.
        if start > 0, !lines.isEmpty { lines.removeFirst() }
        var body: (text: String, at: Date)?
        var title: String?
        for line in lines.reversed() {
            if body == nil,
               let entry = assistantEntry(fromJSONLine: Data(line), excludingCwd: excludingCwd),
               let text = recapText(of: entry.text) {
                body = (text, entry.at)
            }
            if title == nil { title = sessionTitle(fromJSONLine: Data(line)) }
            if body != nil, title != nil { break }
        }
        guard let body else { return nil }
        return Recap(title: title ?? fallbackTitle, sentence: body.text, at: body.at)
    }

    /// 전사 한 줄에서 Claude Code 가 붙인 세션 이름을 꺼낸다(순수).
    static func sessionTitle(fromJSONLine data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let entry = object as? [String: Any],
              entry["type"] as? String == "ai-title",
              let title = (entry["aiTitle"] as? String)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else { return nil }
        return title
    }

    /// 전사 한 줄에서 본 대화의 assistant 응답과 쓰인 시각을 꺼낸다(순수 — 파일 없이 테스트한다).
    /// 서브에이전트 줄(`isSidechain`)과 도구 호출만 있는 줄은 건너뛴다.
    /// 시각이 없는 줄도 건너뛴다 — 새 응답인지 판정할 수 없으면 띄우지 않는다.
    /// `excludingCwd` 와 같은 자리에서 시작된 세션도 건너뛴다. 앱이 농담을 만들려고 띄운
    /// claude CLI 의 전사라, 그냥 두면 농담 생성 응답이 recap 으로 뜬다.
    static func assistantEntry(fromJSONLine data: Data,
                               excludingCwd: String? = nil) -> (text: String, at: Date)? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let entry = object as? [String: Any],
              entry["type"] as? String == "assistant",
              entry["isSidechain"] as? Bool != true,
              excludingCwd == nil || (entry["cwd"] as? String) != excludingCwd,
              let at = (entry["timestamp"] as? String).flatMap(parseTimestamp),
              let message = entry["message"] as? [String: Any],
              let blocks = message["content"] as? [[String: Any]] else { return nil }
        for block in blocks where block["type"] as? String == "text" {
            let text = ((block["text"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return (text, at) }
        }
        return nil
    }

    /// 전사의 시각은 소수점 이하가 있을 때와 없을 때가 섞여 있다.
    static func parseTimestamp(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    /// 응답에서 말풍선에 올릴 글. 첫 문단을 통째로 가져와 말풍선 3줄이 차게 한다 —
    /// 문장 하나만 쓰면 아래 두 줄이 비어 보인다. 길이는 자르지 않고 뷰의 줄 수 제한에 맡긴다.
    /// 화면에 그대로 뜨면 곤란한 마크다운 기호는 지운다(순수).
    static func recapText(of text: String) -> String? {
        var paragraph: [String] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            // 빈 줄과 코드 블록은 문단의 끝. 시작 전이면 건너뛰고 시작한 뒤면 거기서 멈춘다.
            if line.isEmpty || line.hasPrefix("```") {
                if paragraph.isEmpty { continue }
                break
            }
            paragraph.append(stripMarkdown(line))
        }
        let joined = paragraph.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return joined.isEmpty ? nil : joined
    }

    /// 말풍선은 서식을 그리지 못한다. 기호가 글자로 남지 않게 뗀다.
    private static func stripMarkdown(_ line: String) -> String {
        line.trimmingCharacters(in: CharacterSet(charactersIn: "#->* "))
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
            .trimmingCharacters(in: .whitespaces)
    }
}
