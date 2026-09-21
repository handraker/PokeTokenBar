import Foundation

/// 포켓몬 성격에 맞는 농담을 말풍선으로 띄우는 감시자.
///
/// 문장은 claude CLI 로 한 번에 여러 개 받아 파일에 쌓아두고 평소에는 거기서 꺼내 쓴다.
/// 띄울 때마다 부르면 응답을 기다려야 하고 토큰도 계속 나가므로, 바닥이 보일 때만 다시 채운다.
/// 한국어 농담을 성격별로 주는 공개 API 가 없어 생성 말고는 선택지가 없었다.
///
/// 띄우는 시점은 앱의 갱신 주기를 따른다. 자체 타이머를 두지 않고 `showNext()` 를 갱신이
/// 끝난 자리에서 부른다. 설정한 간격이 갱신 주기보다 길면 그만큼 건너뛴다.
@MainActor
final class JokeWatcher {
    /// 농담 한 편을 만들 때 필요한 정보. 종·성격·언어 중 하나라도 바뀌면 다른 주머니를 쓴다 —
    /// 문장에 그 종의 말투가 배어 있어서 진화하면 말투가 안 맞는다.
    struct Context: Equatable {
        let nature: PokemonNature
        let language: AppLanguage
        let petName: String
        let speciesID: Int?
        /// 그 종의 타입(`electric` 등). 소재가 되어 다른 포켓몬이 해도 되는 농담을 줄인다.
        var types: [String] = []
    }

    /// 프롬프트를 고치면 올린다. 주머니 키에 들어가서 예전 문장과 섞이지 않는다 —
    /// 꺼낸 문장을 지우지 않고 돌려 쓰므로, 버전을 안 올리면 옛 문장이 영영 남는다.
    nonisolated static let promptVersion = 2

    /// 한 번에 받아올 수 있는 최대 문장 수. 이보다 많이 시키면 응답이 느려지고 문장이 뭉개진다.
    nonisolated static let maxBatchSize = 60
    /// 생성이 실패했을 때 다시 부르기까지 기다리는 시간. 주머니가 비어도 계속 부르지 않게.
    nonisolated static let refillCooldown: TimeInterval = 300

    /// 가진 문장의 목표치 범위. 주기가 짧을수록 같은 농담이 빨리 돌아오므로 많이 쟁인다.
    nonisolated static let repertoireRange = 20...200

    /// 시간당 소비량.
    nonisolated static func perHour(interval: TimeInterval) -> Double {
        3600 / max(1, interval)
    }

    /// 가지고 있어야 할 문장 수. 두 시간 치를 목표로 하되 범위 안으로 맞춘다.
    /// 1초 주기처럼 생성이 소비를 따라갈 수 없는 구간에서는 상한까지 쟁이고 순환시킨다.
    nonisolated static func repertoireTarget(perHour: Double) -> Int {
        min(repertoireRange.upperBound,
            max(repertoireRange.lowerBound, Int((perHour * 2).rounded(.up))))
    }
    /// 생성이 끝나기를 기다리는 한도. 넘으면 프로세스를 정리하고 다음 기회로 미룬다.
    nonisolated static let generateTimeout: TimeInterval = 120
    /// 생성에 쓸 모델. 한 줄짜리 농담에는 가장 싸고 빠른 등급이면 충분하다.
    /// 별칭이라 최신 haiku 를 따라간다.
    nonisolated static let model = "haiku"

    nonisolated static var fileURL: URL {
        AppStatePaths.directory().appendingPathComponent("jokes.json")
    }

    private let context: () -> Context?
    /// 띄우는 주기(초). 설정이라 매번 다시 읽는다.
    private let interval: () -> TimeInterval
    private let onJoke: (Context, String) -> Void
    /// `언어.성격` → 가지고 있는 문장들. 꺼내도 지우지 않고 순서대로 돌려 쓴다.
    private var book: [String: [String]]
    /// 주머니마다 다음에 꺼낼 자리.
    private var cursor: [String: Int] = [:]
    private var lastRefill: Date = .distantPast
    private var refilling = false
    private var timer: Timer?
    /// 지금 걸려 있는 타이머의 주기. 설정이 바뀌면 다시 건다.
    private var scheduledInterval: TimeInterval?

    init(context: @escaping () -> Context?,
         interval: @escaping () -> TimeInterval,
         onJoke: @escaping (Context, String) -> Void) {
        self.context = context
        self.interval = interval
        self.onJoke = onJoke
        self.book = Self.load()
    }

    /// 설정한 주기로 스스로 돈다. 앱의 갱신 주기에 얹으면 그보다 짧은 주기를 지킬 수 없다.
    func start() {
        schedule()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        scheduledInterval = nil
    }

    private func schedule() {
        timer?.invalidate()
        let seconds = max(1, interval())
        let t = Timer(timeInterval: seconds, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        t.tolerance = seconds * 0.1
        RunLoop.main.add(t, forMode: .common)
        timer = t
        scheduledInterval = seconds
    }

    private func tick() {
        // 설정이 바뀌었으면 새 주기로 다시 건다. 다음 tick 부터 새 간격이 적용된다.
        if max(1, interval()) != scheduledInterval { schedule() }
        showNext()
    }

    /// 다음에 꺼낼 문장과 그다음 자리(순수). 끝에 닿으면 처음으로 돌아간다 —
    /// 주기가 짧으면 생성이 소비를 따라갈 수 없어 비워두는 대신 돌려 쓴다.
    nonisolated static func next(from pool: [String], cursor: Int) -> (joke: String, next: Int)? {
        guard !pool.isEmpty else { return nil }
        let index = ((cursor % pool.count) + pool.count) % pool.count
        return (pool[index], index + 1)
    }

    nonisolated static func key(_ context: Context) -> String {
        "v\(promptVersion).\(context.language.rawValue).\(context.nature.rawValue).\(context.speciesID ?? 0)"
    }

    /// 갱신이 끝날 때마다 한 편씩. 꺼낸 문장은 주머니에서 지운다 — 남겨두고 무작위로 고르면
    /// 주머니가 줄지 않아 다시 채울 일이 없고, 같은 농담이 계속 돈다.
    func showNext() {
        // context 가 nil 이면 꺼진 상태다. 띄우지도 않고 생성도 하지 않는다.
        guard let context = context() else { return }
        let key = Self.key(context)
        if let picked = Self.next(from: book[key] ?? [], cursor: cursor[key] ?? 0) {
            cursor[key] = picked.next
            onJoke(context, picked.joke)
        }
        refillIfNeeded(key: key, context: context,
                       target: Self.repertoireTarget(perHour: Self.perHour(interval: interval())))
    }

    private func refillIfNeeded(key: String, context: Context, target: Int) {
        let have = book[key]?.count ?? 0
        guard have < target, !refilling,
              Date().timeIntervalSince(lastRefill) >= Self.refillCooldown else { return }
        refilling = true
        lastRefill = Date()
        let count = min(Self.maxBatchSize, target - have)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let lines = await Self.generate(context, count: count)
            self.refilling = false
            guard !lines.isEmpty else { return }
            var pool = self.book[key] ?? []
            for line in lines where !pool.contains(line) { pool.append(line) }
            self.book[key] = Array(pool.prefix(Self.repertoireRange.upperBound))
            self.save()
            AppLog.write("jokes refilled \(key): +\(lines.count) → \(self.book[key]?.count ?? 0)")
        }
    }

    // MARK: 생성

    nonisolated static func generate(_ context: Context, count: Int) async -> [String] {
        guard let binary = BinaryLocator.resolve("claude",
                                                 staticPaths: BinaryLocator.commonNodeToolPaths("claude")) else {
            AppLog.write("jokes: claude CLI 를 못 찾아 생성을 건너뛴다")
            return []
        }
        return parse(await run(binary: binary, prompt: prompt(for: context, count: count)))
    }

    /// 프롬프트는 영어로 두고 결과 언어만 지정한다 — 7개 언어의 프롬프트를 따로 쓰지 않는다.
    nonisolated static func prompt(for context: Context, count: Int) -> String {
        let species = context.speciesID.map { "\(context.petName) (National Dex #\($0))" }
            ?? context.petName
        let types = context.types.isEmpty ? "" : " Type: \(context.types.joined(separator: "/"))."
        return """
        You write one-line jokes a Pokémon tells its trainer while they are coding.
        Pokémon: \(species).\(types) Nature: \(context.nature.rawValue).
        Write \(count) short jokes in \(context.language.label).
        Make them sound like this species speaking: keep the voice, speech habits and catchphrases
        it is known for in the games and anime, including how it refers to itself.
        Draw material from what this species actually is - its type, what it looks like, what it
        does - so that a different Pokémon could not tell the same joke.
        Let the nature set the attitude on top of that voice.
        Rules: one joke per line, no numbering, no quotes, no emoji, at most 40 characters each,
        safe for a workplace. Vary the phrasing - do not end every line the same way, and name
        yourself in about half the lines, not all of them.
        Output only the jokes.
        """
    }

    /// 모델이 번호·불릿·따옴표를 붙여 오는 경우가 흔하다. 말풍선에는 문장만 올린다(순수).
    nonisolated static func parse(_ output: String) -> [String] {
        var seen = Set<String>()
        return output.split(separator: "\n").compactMap { raw -> String? in
            var line = raw.trimmingCharacters(in: .whitespaces)
            line = line.replacingOccurrences(of: "^[0-9]+[.)]\\s*", with: "",
                                             options: .regularExpression)
            line = line.trimmingCharacters(in: CharacterSet(charactersIn: "-*•\"'“”「」 "))
            // 40자 약속을 넘기는 줄은 농담이 아니라 설명일 가능성이 크다(예: "여기 10개입니다").
            guard !line.isEmpty, line.count <= 60, seen.insert(line).inserted else { return nil }
            return line
        }
    }

    private nonisolated static func run(binary: String, prompt: String) async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: binary)
                process.arguments = ["-p", prompt, "--model", model]
                // 전용 작업 디렉터리에서 돌린다. 전사의 cwd 로 앱이 만든 세션임을 구분한다.
                process.currentDirectoryURL = AppStatePaths.jokeSessionDirectory()
                process.environment = BinaryLocator.augmentedEnvironment(binaryPath: binary)
                let output = Pipe()
                process.standardOutput = output
                process.standardError = Pipe()
                do {
                    try process.run()
                } catch {
                    AppLog.write("jokes: claude 실행 실패 \(error.localizedDescription)")
                    continuation.resume(returning: "")
                    return
                }
                // 응답이 늦으면 프로세스를 정리한다. 매달린 자식이 남으면 다음 호출까지 막힌다.
                let killer = DispatchWorkItem {
                    if process.isRunning {
                        AppLog.write("jokes: 생성이 \(Int(generateTimeout))초를 넘겨 중단")
                        process.terminate()
                    }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + generateTimeout, execute: killer)
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                killer.cancel()
                continuation.resume(returning: String(data: data, encoding: .utf8) ?? "")
            }
        }
    }

    // MARK: 저장

    private nonisolated static func load() -> [String: [String]] {
        guard let data = try? Data(contentsOf: fileURL),
              let book = try? JSONDecoder().decode([String: [String]].self, from: data) else { return [:] }
        return book
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(book) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
    }
}
