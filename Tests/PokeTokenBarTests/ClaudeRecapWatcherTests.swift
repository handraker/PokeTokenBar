import XCTest
@testable import PokeTokenBar

// 전사 한 줄 → 말풍선 문장까지의 순수 경계와, 파일 끝에서 되짚는 탐색을 검증한다.
@MainActor
final class ClaudeRecapWatcherTests: XCTestCase {

    private func line(_ entry: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: entry), encoding: .utf8)!
    }

    private func assistant(_ text: String, isSidechain: Bool = false,
                           at: String = "2026-09-18T01:00:00.000Z",
                           cwd: String = "/Users/me/project") -> [String: Any] {
        ["type": "assistant", "isSidechain": isSidechain, "timestamp": at, "cwd": cwd,
         "message": ["content": [["type": "text", "text": text]]]]
    }

    func testAssistantEntrySkipsSidechainToolOnlyAndUndatedLines() {
        let entry = ClaudeRecapWatcher.assistantEntry(
            fromJSONLine: Data(line(assistant("본 대화의 응답")).utf8))
        XCTAssertEqual(entry?.text, "본 대화의 응답")
        XCTAssertEqual(entry?.at, ClaudeRecapWatcher.parseTimestamp("2026-09-18T01:00:00.000Z"))
        // 서브에이전트가 한 말은 사용자가 본 적 없는 문장이라 말풍선에 띄우지 않는다.
        XCTAssertNil(ClaudeRecapWatcher.assistantEntry(
            fromJSONLine: Data(line(assistant("서브에이전트 응답", isSidechain: true)).utf8)))
        // 도구 호출만 있는 줄에는 보여줄 문장이 없다.
        XCTAssertNil(ClaudeRecapWatcher.assistantEntry(fromJSONLine: Data(line([
            "type": "assistant", "timestamp": "2026-09-18T01:00:00.000Z",
            "message": ["content": [["type": "tool_use", "name": "Bash"]]]]).utf8)))
        // 시각이 없으면 새 응답인지 판정할 수 없다.
        XCTAssertNil(ClaudeRecapWatcher.assistantEntry(fromJSONLine: Data(line([
            "type": "assistant",
            "message": ["content": [["type": "text", "text": "시각 없는 응답"]]]]).utf8)))
        // 앱이 농담을 만들려고 띄운 CLI 의 전사. 그냥 두면 농담 생성 응답이 recap 으로 뜬다.
        XCTAssertNil(ClaudeRecapWatcher.assistantEntry(
            fromJSONLine: Data(line(assistant("농담 10개입니다", cwd: "/state/joke-session")).utf8),
            excludingCwd: "/state/joke-session"))
        XCTAssertNotNil(ClaudeRecapWatcher.assistantEntry(
            fromJSONLine: Data(line(assistant("사람이 본 응답")).utf8),
            excludingCwd: "/state/joke-session"))
        XCTAssertNil(ClaudeRecapWatcher.assistantEntry(fromJSONLine: Data(line(["type": "user"]).utf8)))
        XCTAssertNil(ClaudeRecapWatcher.assistantEntry(fromJSONLine: Data("깨진 줄".utf8)))
    }

    /// 소수점 이하가 있는 표기와 없는 표기가 전사에 섞여 있다.
    func testParseTimestampAcceptsBothIsoForms() {
        XCTAssertEqual(ClaudeRecapWatcher.parseTimestamp("2026-09-18T01:00:00.000Z"),
                       ClaudeRecapWatcher.parseTimestamp("2026-09-18T01:00:00Z"))
        XCTAssertNil(ClaudeRecapWatcher.parseTimestamp("어제"))
    }

    /// 첫 문단을 통째로 가져온다. 문장 하나만 쓰면 말풍선 3줄 중 두 줄이 비어 보인다.
    func testRecapTextTakesWholeFirstParagraph() {
        XCTAssertEqual(
            ClaudeRecapWatcher.recapText(of: "확인했다. 그다음 문장."),
            "확인했다. 그다음 문장.")
        // 문단 안의 줄바꿈은 공백으로 잇고, 빈 줄에서 멈춘다.
        XCTAssertEqual(
            ClaudeRecapWatcher.recapText(of: "첫 줄이다.\n둘째 줄이다.\n\n다음 문단은 안 가져온다."),
            "첫 줄이다. 둘째 줄이다.")
    }

    /// 코드 블록은 말풍선에 그릴 수 없다. 문단이 시작된 뒤 만나면 거기서 멈춘다.
    func testRecapTextStopsAtCodeFence() {
        XCTAssertEqual(
            ClaudeRecapWatcher.recapText(of: "설명 문장이다.\n```swift\nlet x = 1\n```"),
            "설명 문장이다.")
    }

    func testRecapTextStripsMarkdownAndKeepsFullLength() {
        XCTAssertEqual(ClaudeRecapWatcher.recapText(of: "## 제목\n\n본문"), "제목")
        XCTAssertEqual(ClaudeRecapWatcher.recapText(of: "**굵게** 시작"), "굵게 시작")
        XCTAssertEqual(ClaudeRecapWatcher.recapText(of: "`Type.member` 를 쓴다."), "Type.member 를 쓴다.")
        XCTAssertNil(ClaudeRecapWatcher.recapText(of: "   \n  "))
        // 길이를 여기서 자르면 알림과 처리가 갈린다. 넘치는 만큼은 뷰가 줄 수로 자른다.
        let long = String(repeating: "가", count: 120)
        XCTAssertEqual(ClaudeRecapWatcher.recapText(of: long), long)
    }

    /// 파일 끝에서 되짚어 가장 마지막 응답을 잡는다. 도구 호출로 끝나는 전사가 흔하므로
    /// 마지막 줄만 보면 문장을 놓친다.
    func testLatestRecapScansBackwardPastToolLines() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("recap-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let content = [
            line(assistant("첫 번째 응답이다.", at: "2026-09-18T01:00:00.000Z")),
            line(assistant("마지막 응답이다.", at: "2026-09-18T01:01:00.000Z")),
            line(["type": "assistant", "timestamp": "2026-09-18T01:02:00.000Z",
                  "message": ["content": [["type": "tool_use", "name": "Bash"]]]]),
        ].joined(separator: "\n") + "\n"
        try content.write(to: url, atomically: true, encoding: .utf8)

        let recap = ClaudeRecapWatcher.latestRecap(in: url)
        XCTAssertEqual(recap?.sentence, "마지막 응답이다.")
        XCTAssertEqual(recap?.at, ClaudeRecapWatcher.parseTimestamp("2026-09-18T01:01:00.000Z"))
        // 세션 이름이 없는 전사도 있다. 제목 자리를 비워두지 않는다.
        XCTAssertEqual(recap?.title, ClaudeRecapWatcher.fallbackTitle)
    }

    /// 세션 이름은 대화가 길어지면 갱신된다. 끝에서 만난 것이 가장 최근 값이다.
    func testLatestRecapTakesNewestSessionTitle() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("recap-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let content = [
            line(["type": "ai-title", "aiTitle": "처음 붙은 이름"]),
            line(assistant("작업을 이어간다.")),
            line(["type": "ai-title", "aiTitle": "갱신된 세션 이름"]),
        ].joined(separator: "\n") + "\n"
        try content.write(to: url, atomically: true, encoding: .utf8)

        let recap = ClaudeRecapWatcher.latestRecap(in: url)
        XCTAssertEqual(recap?.title, "갱신된 세션 이름")
        XCTAssertEqual(recap?.sentence, "작업을 이어간다.")
    }

    func testSessionTitleIgnoresOtherLines() {
        XCTAssertEqual(
            ClaudeRecapWatcher.sessionTitle(
                fromJSONLine: Data(line(["type": "ai-title", "aiTitle": "세션 이름"]).utf8)),
            "세션 이름")
        XCTAssertNil(ClaudeRecapWatcher.sessionTitle(
            fromJSONLine: Data(line(["type": "ai-title", "aiTitle": "   "]).utf8)))
        XCTAssertNil(ClaudeRecapWatcher.sessionTitle(
            fromJSONLine: Data(line(assistant("응답")).utf8)))
    }

    /// 꼬리만 읽으므로 잘린 첫 줄은 버린다. 그 줄을 파싱하려 들면 깨진 JSON 이 된다.
    func testLatestRecapDropsPartialFirstLine() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("recap-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let keep = line(assistant("꼬리 안에 온전히 들어온 응답이다."))
        let padding = line(assistant(String(repeating: "가", count: 600)))
        try (padding + "\n" + keep + "\n").write(to: url, atomically: true, encoding: .utf8)

        // 꼬리를 keep 줄만 온전히 담을 크기로 잘라 앞줄이 반 토막 나게 만든다.
        XCTAssertEqual(ClaudeRecapWatcher.latestRecap(in: url, tailBytes: keep.utf8.count + 10)?.sentence,
                       "꼬리 안에 온전히 들어온 응답이다.")
    }
}
