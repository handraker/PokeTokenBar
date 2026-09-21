import Foundation
import SQLite3

/// macOS 알림을 떠 있는 pet 의 말풍선으로 흘려보내는 감시자.
///
/// 알림 센터가 배달 기록을 쌓는 usernoted DB(`record` 테이블)를 읽기 전용으로 폴링한다 —
/// 개별 앱이 알림 내용을 밖으로 내주지 않으므로 배달 기록이 유일한 경로다.
/// DB 는 보호된 경로라 앱에 Full Disk Access 가 필요하고, 권한이 없으면 열기가 실패해 아무것도
/// 표시하지 않는다. 실패를 기억하지 않고 매 tick 다시 열어보므로 권한을 나중에 줘도 재시작이 필요 없다.
@MainActor
final class NotificationWatcher {
    /// 자기 알림은 건너뛴다. 한도 경고는 이미 제 말풍선으로 뜨므로 같은 내용이 두 번 뜬다.
    static var excludedIdentifier: String { Bundle.main.bundleIdentifier ?? "" }
    /// 이 앱의 알림은 제 색으로 띄운다. 어디서 온 말인지 글을 읽기 전에 구분된다.
    static let doorayMessengerIdentifier = "com.dooray.messenger"

    static var defaultDatabaseURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/group.com.apple.usernoted/db2/db")
    }

    private let databaseURL: URL
    private let interval: TimeInterval
    private let onMessage: (UsageStore.BubbleContent) -> Void
    /// 마지막으로 본 rec_id. nil 이면 기준선 미설정 — 시작 직후 과거 알림을 쏟아내지 않도록
    /// 첫 tick 은 표시 없이 기준선만 잡는다. DB 를 못 열면 nil 로 남아 다음 tick 에 다시 시도한다.
    private var lastRecordID: Int64?
    private var timer: Timer?
    /// `db-wal` 감시. 알림이 도착하면 usernoted 가 이 파일에 먼저 쓴다.
    private var walSource: DispatchSourceFileSystemObject?
    private var walDescriptor: CInt = -1
    /// 연속으로 들어오는 쓰기 이벤트를 한 번의 조회로 합친다.
    private var pendingPoll: Task<Void, Never>?
    /// 로그 1회용 플래그. 권한이 없으면 말풍선이 안 뜨는 것 말고는 증상이 없어 원인을 알 수 없다.
    private var loggedOpenFailure = false

    /// WAL 파일 감시가 놓치는 경우를 받치는 주기. 감시가 붙으면 반응은 파일 변경이 이끌고
    /// 이 타이머는 보험이다.
    init(databaseURL: URL = NotificationWatcher.defaultDatabaseURL,
         interval: TimeInterval = 10,
         onMessage: @escaping (UsageStore.BubbleContent) -> Void) {
        self.databaseURL = databaseURL
        self.interval = interval
        self.onMessage = onMessage
    }

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: interval, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.poll() }
        }
        t.tolerance = interval * 0.5
        RunLoop.main.add(t, forMode: .common)
        timer = t
        watchWriteAheadLog()
    }

    /// 알림 도착을 기다리지 않고 알아챈다. 주기 조회만 쓰면 그 주기만큼 늦게 뜬다.
    /// DB 가 WAL 모드라 알림이 배달되면 `db-wal` 이 먼저 늘어난다.
    private func watchWriteAheadLog() {
        walSource?.cancel()
        let path = databaseURL.path + "-wal"
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }   // 아직 없거나 권한이 없다 — 타이머가 받는다
        walDescriptor = fd
        walSource = Self.makeWriteAheadLogSource(fd: fd) { [weak self] rawEvents in
            Task { @MainActor in
                guard let self else { return }
                let events = DispatchSource.FileSystemEvent(rawValue: rawEvents)
                // 체크포인트가 파일을 갈아치우면 감시가 끊긴다. 새 파일에 다시 건다.
                if events.contains(.delete) || events.contains(.rename) {
                    self.rearmWriteAheadLogWatch()
                }
                self.schedulePoll()
            }
        }
    }

    /// 이 클래스는 `@MainActor` 라, 여기 메서드 안에서 만든 클로저는 MainActor 에 묶인 것으로
    /// 추론된다. 그 클로저를 dispatch 가 백그라운드 큐에서 부르면 런타임이 격리 위반으로 트랩을
    /// 걸어 앱이 죽는다. 그래서 핸들러는 격리 밖(`nonisolated`)에서 만든다.
    private nonisolated static func makeWriteAheadLogSource(
        fd: CInt,
        onEvent: @escaping @Sendable (UInt) -> Void
    ) -> DispatchSourceFileSystemObject {
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename],
            queue: .global(qos: .utility))
        // 이벤트 묶음은 Sendable 이 아니라 raw 값으로 건넨다.
        source.setEventHandler { [weak source] in onEvent(source?.data.rawValue ?? 0) }
        source.setCancelHandler { close(fd) }
        source.resume()
        return source
    }

    private func rearmWriteAheadLogWatch() {
        walSource?.cancel()
        walSource = nil
        walDescriptor = -1
        // 갈아치우는 동안 잠깐 파일이 없다. 조금 뒤에 다시 연다.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            self?.watchWriteAheadLog()
        }
    }

    /// 한 번의 배달이 여러 번의 쓰기를 만든다. 짧게 묶어 한 번만 조회한다.
    private func schedulePoll() {
        guard pendingPoll == nil else { return }
        pendingPoll = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            self?.pendingPoll = nil
            self?.poll()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        pendingPoll?.cancel()
        pendingPoll = nil
        walSource?.cancel()
        walSource = nil
        walDescriptor = -1
    }

    /// 새 기록 중 가장 최근 1건만 말풍선으로 보낸다 — 말풍선은 한 번에 하나고 6초 뒤 사라지므로
    /// 자리비움 뒤 밀린 알림을 순서대로 흘려봐야 마지막 것만 보인다.
    private func poll() {
        guard let last = lastRecordID else {
            // 기준선은 표시 대상만 세지 않고 전체 max(rec_id) 로 잡는다. 0 으로 시작하면
            // 이후 도착하는 첫 알림이 기준선 tick 에 먹혀 사라진다.
            guard let baseline = maxRecordID() else {
                if !loggedOpenFailure {
                    loggedOpenFailure = true
                    AppLog.write("notification watcher: usernoted DB 열기 실패 — 전체 디스크 접근 권한 확인 필요")
                }
                return
            }
            lastRecordID = baseline
            AppLog.write("notification watcher armed at rec_id=\(baseline)")
            return
        }
        let rows = newRecords(after: last)
        guard let newest = rows.last else { return }
        lastRecordID = newest.id
        guard let content = Self.bubble(fromPayload: newest.data, sender: newest.sender) else { return }
        onMessage(content)
    }

    /// 알림 배달 기록 1건(binary plist)에서 말풍선 문자열을 뽑는다(순수 — DB 없이 테스트한다).
    /// `req.titl` 이 채널·발신자, `req.body` 가 메시지다. 제목만 있는 알림은 제목을 본문 자리에 놓는다.
    static func bubble(fromPayload data: Data, sender: String = "") -> UsageStore.BubbleContent? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let root = plist as? [String: Any],
              let req = root["req"] as? [String: Any] else { return nil }
        let titl = plainText((req["titl"] as? String) ?? "")
        let body = plainText((req["body"] as? String) ?? "")
        guard !titl.isEmpty || !body.isEmpty else { return nil }
        let palette: UsageStore.BubbleContent.Palette =
            sender == doorayMessengerIdentifier ? .dooray : .system
        if titl.isEmpty {
            return UsageStore.BubbleContent(title: body, body: "", palette: palette)
        }
        return UsageStore.BubbleContent(title: titl, body: body, palette: palette)
    }

    /// 알림 글을 말풍선에 올릴 한 줄로 편다(순수).
    ///
    /// Dooray 는 본문에 마크다운을 그대로 넣어 보낸다. 말풍선은 서식을 그리지 못하므로
    /// 링크는 글자만 남기고, 역슬래시 이스케이프를 되돌리고, 줄바꿈을 공백으로 잇는다.
    /// 그대로 두면 주소와 역슬래시가 글자로 남아 세 줄을 잡아먹는다.
    static func plainText(_ raw: String) -> String {
        var text = raw
        for (pattern, replacement) in [
            (#"\[([^\]]*)\]\([^)]*\)"#, "$1"),   // [글자](주소) → 글자
            (#"\\(.)"#, "$1"),                    // \[ \( \* → [ ( *
            (#"\s+"#, " "),                       // 줄바꿈·연속 공백 → 한 칸
        ] {
            text = text.replacingOccurrences(of: pattern, with: replacement,
                                             options: .regularExpression)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: usernoted DB (읽기 전용)

    private func maxRecordID() -> Int64? {
        withDatabase { db in
            var value: Int64?
            query(db, "SELECT max(rec_id) FROM record") { stmt in
                if sqlite3_column_type(stmt, 0) != SQLITE_NULL { value = sqlite3_column_int64(stmt, 0) }
            }
            // 기록이 하나도 없으면 max 가 NULL — 0 을 기준선으로 잡아 다음 tick 부터 정상 동작한다.
            return value ?? 0
        }
    }

    private func newRecords(after lastID: Int64) -> [(id: Int64, data: Data, sender: String)] {
        withDatabase { db in
            let sql = """
            SELECT r.rec_id, r.data, a.identifier FROM record r JOIN app a ON r.app_id = a.app_id
            WHERE a.identifier != '\(Self.excludedIdentifier)' AND r.rec_id > \(lastID) ORDER BY r.rec_id
            """
            var rows: [(id: Int64, data: Data, sender: String)] = []
            query(db, sql) { stmt in
                let id = sqlite3_column_int64(stmt, 0)
                guard let blob = sqlite3_column_blob(stmt, 1) else { return }
                let sender = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
                rows.append((id, Data(bytes: blob, count: Int(sqlite3_column_bytes(stmt, 1))), sender))
            }
            return rows
        } ?? []
    }

    /// 매 tick 열고 닫는다 — 폴링 간격이 초 단위라 비용이 무시할 만하고, 연결을 들고 있지 않아
    /// 알림 센터가 DB 를 갈아끼워도 다음 tick 에 스스로 회복한다.
    private func withDatabase<T>(_ work: (OpaquePointer) -> T) -> T? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let handle = db else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(handle) }
        return work(handle)
    }

    private func query(_ db: OpaquePointer, _ sql: String, row: (OpaquePointer) -> Void) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let handle = stmt else {
            sqlite3_finalize(stmt)
            return
        }
        defer { sqlite3_finalize(handle) }
        while sqlite3_step(handle) == SQLITE_ROW { row(handle) }
    }
}
