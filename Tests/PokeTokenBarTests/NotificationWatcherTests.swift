import XCTest
@testable import PokeTokenBar

// usernoted 배달 기록(binary plist) → 말풍선 문자열 변환만 검증한다. DB 폴링은 보호된 경로와
// 실제 알림 도착에 의존해 단위 테스트로 재현할 수 없으므로, 재현 가능한 순수 경계인 디코딩을 잡는다.
@MainActor
final class NotificationWatcherTests: XCTestCase {

    /// 실제 기록과 같은 모양: 최상위 `req` 딕셔너리 안에 `titl`/`body` 가 들어 있다.
    private func payload(_ req: [String: Any]) -> Data {
        try! PropertyListSerialization.data(
            fromPropertyList: ["app": "com.dooray.messenger", "req": req],
            format: .binary, options: 0)
    }

    func testBubbleReadsTitleAndBodyFromRequest() {
        let content = NotificationWatcher.bubble(
            fromPayload: payload(["titl": "MySQL / MariaDB 배포 알림",
                                  "body": "Deploy: Script Deploy SUCCESS"]))
        XCTAssertEqual(content?.title, "MySQL / MariaDB 배포 알림")
        XCTAssertEqual(content?.body, "Deploy: Script Deploy SUCCESS")
        // 알림은 한도 경고가 아니다 — 빨간 제목으로 그려지면 안 된다.
        XCTAssertEqual(content?.isCritical, false)
        // 보낸 앱을 모르면 시스템 색이다.
        XCTAssertEqual(content?.palette, .system)
        // Dooray Messenger 알림만 제 색으로 띄운다. 어디서 온 말인지 글을 읽기 전에 구분된다.
        let dooray = NotificationWatcher.bubble(
            fromPayload: payload(["titl": "팀 채널", "body": "메시지"]),
            sender: NotificationWatcher.doorayMessengerIdentifier)
        XCTAssertEqual(dooray?.palette, .dooray)
        let other = NotificationWatcher.bubble(
            fromPayload: payload(["titl": "캘린더", "body": "일정"]), sender: "com.apple.ical")
        XCTAssertEqual(other?.palette, .system)
    }

    /// Dooray 는 본문에 마크다운을 그대로 넣어 보낸다. 말풍선은 서식을 못 그리므로 펴서 올린다.
    func testPlainTextFlattensMarkdownAndEscapes() {
        XCTAssertEqual(
            NotificationWatcher.plainText(
                "GitHub: [[repo](https://example.com/repo)] 님이 \\[EC\\] 건을 \\(단일 → 다중\\)"),
            "GitHub: [repo] 님이 [EC] 건을 (단일 → 다중)")
        // 줄바꿈을 그대로 두면 짧은 메시지가 세 줄을 다 잡아먹는다.
        XCTAssertEqual(NotificationWatcher.plainText("여러 줄\n메시지\n입니다"), "여러 줄 메시지 입니다")
        // 서식이 없는 본문은 손대지 않는다.
        XCTAssertEqual(NotificationWatcher.plainText(" Deploy SUCCESS : mysql-alpha "),
                       "Deploy SUCCESS : mysql-alpha")
    }

    /// 본문 없는 알림은 제목이 본문 자리로 내려가지 않고 제목 줄에 남는다(빈 굵은 줄 방지).
    func testBubbleWithoutBodyKeepsTitle() {
        let content = NotificationWatcher.bubble(fromPayload: payload(["titl": "새 메시지"]))
        XCTAssertEqual(content?.title, "새 메시지")
        XCTAssertEqual(content?.body, "")
    }

    /// 제목만 비면 본문을 제목 자리로 올린다 — 굵은 줄이 비어 보이는 말풍선을 만들지 않는다.
    func testBubbleWithoutTitlePromotesBody() {
        let content = NotificationWatcher.bubble(fromPayload: payload(["body": "본문만 있는 알림"]))
        XCTAssertEqual(content?.title, "본문만 있는 알림")
        XCTAssertEqual(content?.body, "")
    }

    /// 표시할 문자열이 없으면 말풍선을 띄우지 않는다. plist 가 아니거나 `req` 가 없는 기록도 같다.
    func testBubbleReturnsNilWhenNothingToShow() {
        XCTAssertNil(NotificationWatcher.bubble(fromPayload: payload(["titl": "  ", "body": ""])))
        XCTAssertNil(NotificationWatcher.bubble(fromPayload: payload([:])))
        XCTAssertNil(NotificationWatcher.bubble(
            fromPayload: try! PropertyListSerialization.data(
                fromPropertyList: ["app": "com.dooray.messenger"], format: .binary, options: 0)))
        XCTAssertNil(NotificationWatcher.bubble(fromPayload: Data()))
        XCTAssertNil(NotificationWatcher.bubble(fromPayload: Data("not a plist".utf8)))
    }
}

// 농담 주기와 응답 파싱 — 둘 다 파일·프로세스 없이 검증되는 순수 경계다.
@MainActor
final class JokeWatcherTests: XCTestCase {

    /// 문장은 꺼내도 지우지 않고 순서대로 돌려 쓴다. 끝에 닿으면 처음으로 돌아간다.
    func testNextRotatesThroughRepertoire() {
        let pool = ["첫째", "둘째", "셋째"]
        XCTAssertEqual(JokeWatcher.next(from: pool, cursor: 0)?.joke, "첫째")
        XCTAssertEqual(JokeWatcher.next(from: pool, cursor: 0)?.next, 1)
        XCTAssertEqual(JokeWatcher.next(from: pool, cursor: 2)?.joke, "셋째")
        // 세 개짜리 주머니에서 자리 3 은 다시 처음이다.
        XCTAssertEqual(JokeWatcher.next(from: pool, cursor: 3)?.joke, "첫째")
        XCTAssertNil(JokeWatcher.next(from: [], cursor: 0), "빈 주머니에서는 꺼낼 게 없다")
    }

    /// 범위 밖 값은 경계로 되돌린다. 설정 화면에서 직접 입력받고 UserDefaults 도 손으로 고칠 수 있다.
    func testJokeIntervalClampsToRange() {
        // 끄는 것은 jokeBubbles 가 맡는다. 0 은 주기로 받지 않는다.
        XCTAssertEqual(UsageStore.clampJokeInterval(0), UsageStore.jokeIntervalRange.lowerBound)
        XCTAssertEqual(UsageStore.jokeIntervalRange.lowerBound, 1)
        XCTAssertEqual(UsageStore.clampJokeInterval(-5), UsageStore.jokeIntervalRange.lowerBound)
        XCTAssertEqual(UsageStore.clampJokeInterval(99_999), UsageStore.jokeIntervalRange.upperBound)
        XCTAssertEqual(UsageStore.clampJokeInterval(600), 600)
        XCTAssertEqual(UsageStore.clampJokeInterval(600.4), 600)
    }

    /// 모델이 번호·불릿·따옴표를 붙여 오거나 설명을 앞에 다는 경우가 흔하다.
    func testParseStripsListMarkupAndDropsProse() {
        let output = """
        1. 첫 번째 농담이에요
        - 두 번째 농담이에요
        "세 번째 농담이에요"

        1. 첫 번째 농담이에요
        이 줄은 농담이 아니라 설명이라 길이가 길어서 걸러진다. 40자 약속을 한참 넘기는 문장이다.
        """
        XCTAssertEqual(JokeWatcher.parse(output),
                       ["첫 번째 농담이에요", "두 번째 농담이에요", "세 번째 농담이에요"])
    }

    /// 종·성격·언어 중 하나라도 다르면 다른 주머니를 쓴다. 한 주머니를 공유하면 말투가 섞인다.
    func testKeySeparatesSpeciesNatureAndLanguage() {
        let cleffa = JokeWatcher.Context(nature: .docile, language: .ko, petName: "삐", speciesID: 173)
        let naive = JokeWatcher.Context(nature: .naive, language: .ko, petName: "삐", speciesID: 173)
        let english = JokeWatcher.Context(nature: .docile, language: .en, petName: "Cleffa", speciesID: 173)
        // 진화하면 같은 성격이라도 말투가 달라진다.
        let clefairy = JokeWatcher.Context(nature: .docile, language: .ko, petName: "삐삐", speciesID: 35)
        // 프롬프트 버전이 키에 들어간다. 안 그러면 프롬프트를 고쳐도 옛 문장이 계속 돈다.
        XCTAssertEqual(JokeWatcher.key(cleffa), "v\(JokeWatcher.promptVersion).ko.docile.173")
        XCTAssertNotEqual(JokeWatcher.key(cleffa), JokeWatcher.key(naive))
        XCTAssertNotEqual(JokeWatcher.key(cleffa), JokeWatcher.key(english))
        XCTAssertNotEqual(JokeWatcher.key(cleffa), JokeWatcher.key(clefairy))
    }

    /// 프롬프트에 종·성격·언어와 요청 수가 들어가야 주머니를 나눈 의미가 있다.
    func testPromptCarriesSpeciesNatureAndLanguage() {
        let prompt = JokeWatcher.prompt(
            for: .init(nature: .naive, language: .ko, petName: "삐", speciesID: 173,
                       types: ["fairy"]), count: 17)
        XCTAssertTrue(prompt.contains("naive"))
        XCTAssertTrue(prompt.contains("삐"))
        XCTAssertTrue(prompt.contains("173"), "도감 번호로 종을 특정한다")
        XCTAssertTrue(prompt.contains("fairy"), "타입이 있어야 그 종만 할 수 있는 농담이 나온다")
        XCTAssertTrue(prompt.contains(AppLanguage.ko.label))
        XCTAssertTrue(prompt.contains("17"))
    }

    /// 타입을 아직 못 받은 상태에서도 프롬프트는 성립해야 한다. 빈 자리를 남기지 않는다.
    func testPromptOmitsTypeWhenUnknown() {
        let prompt = JokeWatcher.prompt(
            for: .init(nature: .naive, language: .ko, petName: "삐", speciesID: 173), count: 5)
        XCTAssertFalse(prompt.contains("Type:"))
        XCTAssertTrue(prompt.contains("173"))
    }

    func testPerHourFollowsInterval() {
        XCTAssertEqual(JokeWatcher.perHour(interval: 1), 3600, accuracy: 0.01)
        XCTAssertEqual(JokeWatcher.perHour(interval: 120), 30, accuracy: 0.01)
        XCTAssertEqual(JokeWatcher.perHour(interval: 3600), 1, accuracy: 0.01)
    }

    /// 가질 문장 수는 주기에서 나온다. 짧을수록 같은 농담이 빨리 돌아오므로 많이 쟁인다.
    func testRepertoireTargetScalesWithInterval() {
        // 한 시간에 한 편이면 두 시간 치는 두 편이지만, 너무 적게 가지고 있으면 바로 반복된다.
        XCTAssertEqual(JokeWatcher.repertoireTarget(perHour: 1), JokeWatcher.repertoireRange.lowerBound)
        XCTAssertEqual(JokeWatcher.repertoireTarget(perHour: 30), 60)
        // 1초 주기(시간당 3600편)는 생성이 소비를 못 따라간다. 상한까지 쟁이고 돌려 쓴다.
        XCTAssertEqual(JokeWatcher.repertoireTarget(perHour: 3600), JokeWatcher.repertoireRange.upperBound)
    }
}
