import XCTest
@testable import PokeTokenBar

// 성능(measure) + 스케일/비퇴화 검증. baseline 은 머신 의존이라 느슨하게(게이트는 정확성에).
// SeededRNG / StubProvider 는 CompanionTests.swift 의 내부 헬퍼 재사용.

private func pnode(_ id: Int, _ children: [EvoNode] = []) -> EvoNode { EvoNode(speciesID: id, children: children) }
private func pline(base: Int, rarity: Rarity) -> EvoLine {
    EvoLine(baseID: base, tree: pnode(base, [pnode(base + 1, [pnode(base + 2)])]), rarity: rarity, names: [:])
}
private let pNow = Date(timeIntervalSince1970: 1_700_000_000)
private func tmpURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("poke-perf-\(UUID().uuidString).json")
}

// MARK: 순수 계산 핫패스

final class PureComputePerformanceTests: XCTestCase {
    func testPhaseThresholdThroughput() {
        measure {
            var acc = 0
            for i in 0..<100_000 {
                acc &+= PokemonBalance.phaseThreshold(rarity: .rare, totalForms: 3, stageIndex: i % 3)
            }
            XCTAssertGreaterThan(acc, 0)
        }
    }

    func testLargeDailyReportDecode() {
        let rows = (0..<1000).map {
            "{\"date\":\"2026-06-\(($0 % 28) + 1)\",\"inputTokens\":\($0),\"outputTokens\":1," +
            "\"cacheCreationTokens\":2,\"cacheReadTokens\":3,\"totalTokens\":\($0),\"totalCost\":0.1}"
        }.joined(separator: ",")
        let json = Data("{\"daily\":[\(rows)]}".utf8)
        measure {
            let report = try! JSONDecoder().decode(DailyReport.self, from: json)
            XCTAssertEqual(report.daily.count, 1000)
        }
    }
}

// MARK: 스토어 핫패스 / 스케일

@MainActor
final class StorePerformanceTests: XCTestCase {
    func testUpdateHotPath() async {
        // legendary(임계 6e9)를 부화시켜 진화 없이 작은 델타를 반복 — refresh 당 update 비용 측정.
        let s = CompanionStore(provider: StubProvider(value: pline(base: 1, rarity: .legendary)),
                               clock: { pNow }, fileURL: tmpURL(), rng: SeededRNG(seed: 1))
        await s.hatch(baseID: 1)
        var token = 0
        measure {
            for _ in 0..<500 {
                token += 100
                s.update(todayTokensByProvider: ["test": token], todayDate: "d", monthTotal: 0,
                         burnTier: .normal, limitWarning: false, hasUsageData: true)
            }
        }
        XCTAssertNotNil(s.state.active)   // 진화 없이 동일 단계 유지
    }

    /// 큰 도감을 파일 로드로 주입하고 정렬 비용/정확성을 함께 본다.
    private func storeWithLargeDex(_ count: Int) throws -> CompanionStore {
        let entries = (0..<count).map { i -> DexEntry in
            let r: Rarity = [.common, .uncommon, .rare, .legendary][i % 4]
            return DexEntry(baseID: i, finalID: i, chainOrder: [i], rarity: r,
                            caughtAt: pNow.addingTimeInterval(Double(i)))
        }
        let dexJSON = String(data: try JSONEncoder().encode(entries), encoding: .utf8)!
        let url = tmpURL()
        try Data("{\"dex\":\(dexJSON),\"language\":\"ko\"}".utf8).write(to: url)
        return CompanionStore(provider: StubProvider(value: pline(base: 1, rarity: .common)),
                              clock: { pNow }, fileURL: url, rng: SeededRNG(seed: 1))
    }

    func testLargeDexSortPerformanceAndCorrectness() throws {
        let s = try storeWithLargeDex(1000)
        XCTAssertEqual(s.dexEntries.count, 1000)
        measure {
            let sorted = s.dexEntriesSorted
            XCTAssertEqual(sorted.count, 1000)
        }
        // 정렬 정확성: 포획 로그는 기록 시각 최신순 — 희귀도는 순서에 관여하지 않는다.
        let sorted = s.dexEntriesSorted
        for i in 1..<sorted.count {
            XCTAssertGreaterThanOrEqual(
                sorted[i - 1].caughtAt ?? .distantPast,
                sorted[i].caughtAt ?? .distantPast)
        }
        XCTAssertEqual(sorted.first?.caughtAt, pNow.addingTimeInterval(999), "가장 최신 항목이 맨 앞")
        XCTAssertEqual(s.dexCount(.legendary), 250)
    }
}

// MARK: 비퇴화(터미네이션) 가드

@MainActor
final class StoreTerminationTests: XCTestCase {
    func testHugeDeltaGraduatesOnceAndTerminates() async {
        // 거대한 단일 델타가 무한 루프 없이 라인을 통과해 정확히 1회 졸업하는지 (guardCount 캡 보호).
        let s = CompanionStore(provider: StubProvider(value: pline(base: 1, rarity: .common)),
                               clock: { pNow }, fileURL: tmpURL(), rng: SeededRNG(seed: 1))
        await s.hatch(baseID: 1)
        s.applyUsage(Int(PokemonBalance.graduationTotal(.common)) * 10)   // 졸업 총량의 10배
        XCTAssertNil(s.state.active)            // 졸업 완료
        XCTAssertEqual(s.dexEntries.count, 1)   // 정확히 1회
        XCTAssertEqual(s.dexEntries[0].chainOrder, [1, 2, 3])
        XCTAssertEqual(s.state.eggUsage, 0)     // 새 알 인큐베이션 리셋
    }

    func testRepeatedGraduationGrowsDexLinearly() async {
        // 무진화 라인을 반복 졸업 — dex 가 선형으로 증가하고 상태가 매번 정합한지.
        let provider = StubProvider(value: pline(base: 1, rarity: .common))
        let s = CompanionStore(provider: provider, clock: { pNow }, fileURL: tmpURL(), rng: SeededRNG(seed: 9))
        for n in 1...20 {
            await s.hatch(baseID: 1)
            s.applyUsage(Int(PokemonBalance.graduationTotal(.common)) * 10)
            XCTAssertEqual(s.dexEntries.count, n)
            XCTAssertNil(s.state.active)
        }
    }
}

// MARK: 플로팅 펫 / 스프라이트 idle 배터리 규율

/// 항상 떠 있는 플로팅 펫은 두 번째 GIF 표면이라, 메뉴바에서 고친 idle wakeup 증폭이 재발하지 않게
/// 같은 규율(fps 하한 + 저전력 정적화)을 공유한다. 여기선 그 순수 판정만 고정한다.
@MainActor
final class FloatingPetEnergyTests: XCTestCase {
    /// [회귀] 상시 표시 표면의 GIF 는 **어떤 프리셋에서도** fps 하한으로 캡 — 네이티브 fps 로 돌면
    /// 프레임마다 재합성(CA 커밋→디스플레이 사이클 wakeup)이 늘어 메뉴바 회귀를 그대로 반복한다.
    func testEveryPresetCapsFramesWithoutChangingSpeed() {
        for q in UsageStore.AnimationQuality.allCases {
            let capped = GIFDecoder.capFrameRate(Self.uniformFrames(count: 20, delay: 0.1),
                                                floor: q.frameFloor)
            XCTAssertTrue(capped.allSatisfy { $0.delay >= q.frameFloor - 1e-9 },
                          "\(q.rawValue): 빠른 프레임은 캡 이상으로 묶여야 한다")
            XCTAssertEqual(capped.reduce(0) { $0 + $1.delay }, 2.0, accuracy: 1e-6,
                           "\(q.rawValue): 속도는 원본 유지")
        }
    }

    /// 팝오버 등 일시적 표시(floor=0)는 네이티브 delay 그대로 — 캡은 항상 뜬 표면에만 적용.
    func testTransientSpriteKeepsNativeDelay() {
        let native = Self.uniformFrames(count: 10, delay: 0.03)
        let untouched = GIFDecoder.capFrameRate(native, floor: 0)
        XCTAssertEqual(untouched.count, 10)
        XCTAssertTrue(untouched.allSatisfy { abs($0.delay - 0.03) < 1e-9 })
    }

    /// 저전력 모드면 펫 애니메이션을 정지(정적)해 배터리를 아낀다. 정상 모드면 애니메이션.
    func testPetFreezesUnderLowPower() {
        XCTAssertFalse(FloatingPetController.shouldAnimate(lowPower: true))
        XCTAssertTrue(FloatingPetController.shouldAnimate(lowPower: false))
    }

    /// [회귀] fps 캡은 **재생 속도를 보존**해야 한다 — `max(floor, delay)` 로 프레임을 늘려 붙이면
    /// 프레임 수가 그대로라 애니메이션 전체가 느려진다(55프레임×0.05s=2.75s 스프라이트가 floor 0.4s
    /// 에서 22s = 1/8 속도). 22px 에서 "끊김이 안 보인다"는 판단은 프레임 레이트에만 맞는 얘기였고
    /// 재생 속도가 8배 늘어나는 건 놓쳤다(사용자 지적, 2026-08-20). 캡은 hold 가 아니라 decimate 다.
    func testCapPreservesPlaybackSpeed() {
        let native = Self.uniformFrames(count: 55, delay: 0.05)   // 2.75s, 20fps — Gen-V 실제 스프라이트
        for floor in [0.2, 0.4] {
            let capped = GIFDecoder.capFrameRate(native, floor: floor)
            let total = capped.reduce(0) { $0 + $1.delay }
            XCTAssertEqual(total, 2.75, accuracy: 1e-6,
                           "floor=\(floor): 캡을 걸어도 루프 한 바퀴 길이(재생 속도)는 원본과 같아야 한다")
            XCTAssertLessThan(Double(capped.count) / total, 1 / floor + 1e-6,
                              "floor=\(floor): 유효 fps 가 캡을 넘으면 wakeup 회귀")
            XCTAssertGreaterThan(capped.count, 1, "floor=\(floor): 애니메이션이 정적으로 붕괴하면 안 된다")
        }
    }

    /// 이미 느린 GIF(프레임 delay ≥ floor)는 솎아낼 게 없으니 그대로 — 불필요한 변형 금지.
    func testCapLeavesAlreadySlowFramesAlone() {
        let slow = Self.uniformFrames(count: 4, delay: 0.6)
        let capped = GIFDecoder.capFrameRate(slow, floor: 0.4)
        XCTAssertEqual(capped.count, 4)
        XCTAssertEqual(capped.reduce(0) { $0 + $1.delay }, 2.4, accuracy: 1e-6)
    }

    /// floor=0(팝오버 등 일시적 표시)은 네이티브 그대로 — 손대지 않는다.
    func testCapIsIdentityAtZeroFloor() {
        let native = Self.uniformFrames(count: 55, delay: 0.05)
        XCTAssertEqual(GIFDecoder.capFrameRate(native, floor: 0).count, 55)
    }

    private static func uniformFrames(count: Int, delay: TimeInterval)
        -> [(image: NSImage, delay: TimeInterval)] {
        let img = NSImage(size: NSSize(width: 1, height: 1))
        return (0..<count).map { _ in (img, delay) }
    }

    /// [회귀] 코얼레싱 tolerance 는 **늦게만** 발화시키므로 곧 재생 지연의 상한이다. 0.5 였을 때
    /// 2.75s 루프가 최대 4.13s 로 늘어 팝오버(tolerance 0)와 나란히 보면 메뉴바만 느렸다.
    /// 코얼레싱을 없애지 않으면서(>0) 늘어짐은 눈에 안 띄는 범위(≤15%)로 묶는다.
    func testToleranceDoesNotVisiblyStretchPlayback() {
        XCTAssertGreaterThan(AppDelegate.menuFrameTolerance, 0, "코얼레싱이 사라지면 wakeup 회귀")
        let loop = 2.75                       // 41-a.gif 실측 루프 길이
        let worstCase = loop * (1 + AppDelegate.menuFrameTolerance)
        XCTAssertLessThanOrEqual(worstCase, loop * 1.15,
                                 "최악의 경우 재생이 15% 이상 늘어지면 팝오버와 속도가 어긋나 보인다")
    }

    /// [회귀] **어떤 프리셋도 캡을 해제하지 못한다.** 사용자에게 fps 선택권을 주면서 0(네이티브)이
    /// 새는 게 가장 위험한 회귀 — 프리셋을 추가해도 이 가드가 자동으로 걸린다(개별 상수 단정과 달리).
    func testNoAnimationQualityPresetDisablesTheCap() {
        XCTAssertFalse(UsageStore.AnimationQuality.allCases.isEmpty)
        for q in UsageStore.AnimationQuality.allCases {
            XCTAssertGreaterThan(q.frameFloor, 0, "\(q.rawValue): 캡이 해제되면 idle wakeup 회귀")
        }
    }

    /// 프리셋 순서 계약 — powerSaver 가 가장 느리고(하한 큼) smooth 가 가장 부드럽다. 라벨과 실제
    /// 동작이 어긋나면 사용자가 정반대를 고르게 된다.
    func testAnimationQualityPresetsAreOrdered() {
        let q = UsageStore.AnimationQuality.self
        XCTAssertGreaterThan(q.powerSaver.frameFloor, q.balanced.frameFloor)
        XCTAssertGreaterThan(q.balanced.frameFloor, q.smooth.frameFloor)
    }

    /// 저전력 모드의 유효 하한 — 파생값이라 "복귀"는 lowPower=false 계산 그 자체다.
    /// 저전력이면 어떤 프리셋도 powerSaver 보다 빠르게 돌 수 없고(캡), 아니면 선택값 그대로.
    /// 프리셋이 늘어도 자동으로 걸리도록 개별 상수 대신 전 케이스를 돈다.
    func testLowPowerCapsEffectiveFloorAtPowerSaverAndDerivationRestoresChoice() {
        let saver = UsageStore.AnimationQuality.powerSaver.frameFloor
        for q in UsageStore.AnimationQuality.allCases {
            XCTAssertGreaterThanOrEqual(q.effectiveFrameFloor(lowPower: true), saver,
                                        "\(q.rawValue): 저전력에서 powerSaver 보다 빠르면 절전 실패")
            XCTAssertGreaterThanOrEqual(q.effectiveFrameFloor(lowPower: true), q.frameFloor,
                                        "\(q.rawValue): 저전력이 애니메이션을 더 빠르게 만들 수는 없다")
            XCTAssertEqual(q.effectiveFrameFloor(lowPower: false), q.frameFloor,
                           "\(q.rawValue): 저전력이 아니면 사용자 선택 그대로(자동 복귀)")
        }
    }

    /// [회귀] 저전력 토글이 메뉴바 재구성으로 이어지는 기계 — 유효 하한이 `menuSpriteKey` 에
    /// 들어가므로 smooth 사용자의 저전력 진입/해제는 키를 바꾼다. 키가 안 바뀌면 관측자가
    /// 재호출해도 `ensureMenuAnimation` 이 조기 반환해 옛 fps 로 계속 돈다(설계 시 확인된 함정과
    /// 같은 부류 — `testIdentityKeysIncludeTheFrameFloor`).
    func testLowPowerToggleChangesMenuSpriteKeyForFasterPresets() {
        let smooth = UsageStore.AnimationQuality.smooth
        XCTAssertNotEqual(
            AppDelegate.menuSpriteKey(id: 41, shiny: false,
                                      floor: smooth.effectiveFrameFloor(lowPower: true)),
            AppDelegate.menuSpriteKey(id: 41, shiny: false,
                                      floor: smooth.effectiveFrameFloor(lowPower: false)),
            "smooth: 저전력 토글이 키를 못 바꾸면 재구성이 일어나지 않는다")
        // powerSaver 선택자는 저전력 전후 키가 같아야 한다 — 이미 그 프레임률이라 재구성 자체가 낭비.
        let saver = UsageStore.AnimationQuality.powerSaver
        XCTAssertEqual(
            AppDelegate.menuSpriteKey(id: 41, shiny: false,
                                      floor: saver.effectiveFrameFloor(lowPower: true)),
            AppDelegate.menuSpriteKey(id: 41, shiny: false,
                                      floor: saver.effectiveFrameFloor(lowPower: false)))
    }

    /// [회귀] 설정을 바꾸면 **즉시** 반영돼야 한다. 두 표면 모두 "정체성이 바뀌면 재로딩" 기계로
    /// 프레임을 갱신하는데, 그 정체성 키에 하한이 빠져 있으면 종이 바뀔 때까지 옛 fps 로 계속 돈다
    /// (`menuSpriteKey` = "id-shiny", `SpriteView.task(id:)` = "id-shiny" 였다 — 설계 시 확인된 함정).
    func testIdentityKeysIncludeTheFrameFloor() {
        XCTAssertNotEqual(AppDelegate.menuSpriteKey(id: 41, shiny: false, floor: 0.4),
                          AppDelegate.menuSpriteKey(id: 41, shiny: false, floor: 0.1),
                          "메뉴바: 하한이 키에 없으면 설정 변경이 안 먹는다")
        XCTAssertNotEqual(SpriteView.frameTaskID(speciesID: 41, shiny: false, floor: 0.4),
                          SpriteView.frameTaskID(speciesID: 41, shiny: false, floor: 0.1),
                          "펫: 하한이 task id 에 없으면 설정 변경이 안 먹는다")
        // 종·이로치 구분은 그대로 유지(하한 추가가 기존 판정을 덮어쓰지 않는다).
        XCTAssertNotEqual(AppDelegate.menuSpriteKey(id: 41, shiny: false, floor: 0.2),
                          AppDelegate.menuSpriteKey(id: 41, shiny: true, floor: 0.2))
        XCTAssertNotEqual(SpriteView.frameTaskID(speciesID: 41, shiny: true, floor: 0.2),
                          SpriteView.frameTaskID(speciesID: 42, shiny: true, floor: 0.2))
    }

    /// 두 상시 표시 표면(메뉴바·펫)은 이제 **같은 설정값**을 읽는다(`animationQuality.frameFloor`)
    /// — 한쪽만 캡이 풀리는 비대칭이 구조적으로 불가능해졌다. 남은 위험은 호출부가 0 을 직접
    /// 넘기는 것뿐인데, 두 호출부 모두 SwiftUI/AppKit 뷰라 헤드리스로 잡을 수 없어 여기선
    /// 프리셋 자체의 계약만 잠근다(`testNoAnimationQualityPresetDisablesTheCap`).
    /// 일시적 표시(팝오버)는 의도적으로 floor 0 = 네이티브 fps 다.
    func testTransientSurfaceIsTheOnlyUncappedOne() {
        XCTAssertEqual(GIFDecoder.capFrameRate(Self.uniformFrames(count: 10, delay: 0.03),
                                               floor: 0).count, 10, "팝오버는 네이티브 유지")
        XCTAssertTrue(UsageStore.AnimationQuality.allCases.allSatisfy { $0.frameFloor > 0 })
    }

    /// Bubble needs headroom + width beyond the square pet size — otherwise content is clipped.
    func testPanelGrowsForBubbleWithoutChangingPetOrigin() {
        let pet: CGFloat = 96
        let idle = FloatingPetController.panelSize(petSize: pet, headroom: 0)
        XCTAssertEqual(idle, NSSize(width: pet, height: pet))

        let shown = FloatingPetController.panelSize(petSize: pet, headroom: FloatingPetController.bubbleHeadroom)
        XCTAssertGreaterThan(shown.height, pet, "must reserve vertical headroom for the bubble")
        XCTAssertGreaterThanOrEqual(shown.width, pet)

        // The other branch of `max(petSize, bubbleMinWidth)`: past 180pt the pet drives the
        // panel width, not the bubble column. Only 184/192 reached it before the slider max
        // went to 384, so it was an untested 2-step edge; now it is most of the range.
        let large: CGFloat = 384
        let largeShown = FloatingPetController.panelSize(petSize: large, headroom: FloatingPetController.bubbleHeadroom)
        XCTAssertEqual(largeShown.width, large, "panel must widen with the pet past bubbleMinWidth")
        XCTAssertEqual(largeShown.height,
                       large + FloatingPetController.bubbleHeadroom
                           + FloatingPetController.bubbleShadowMargin)

        let petOrigin = NSPoint(x: 400, y: 200)
        let panelOrigin = FloatingPetController.panelOrigin(
            petOrigin: petOrigin, petSize: pet, panelSize: shown)
        XCTAssertEqual(panelOrigin.y, petOrigin.y, accuracy: 0.5)
        let roundTrip = FloatingPetController.petOrigin(
            panelOrigin: panelOrigin, petSize: pet, panelSize: shown)
        XCTAssertEqual(roundTrip.x, petOrigin.x, accuracy: 0.5)
        XCTAssertEqual(roundTrip.y, petOrigin.y, accuracy: 0.5)
    }

    /// Click opens the popover only when the pointer barely moved; larger movement is a drag.
    func testClickThresholdDistinguishesClickFromDrag() {
        let a = NSPoint(x: 10, y: 10)
        XCTAssertTrue(FloatingPetController.isClick(from: a, to: NSPoint(x: 11, y: 12)))
        XCTAssertTrue(FloatingPetController.isClick(from: a, to: a))
        XCTAssertFalse(FloatingPetController.isClick(from: a, to: NSPoint(x: 20, y: 10)))
    }

    /// Hover tooltip is localized and pure — tokens always; limit % only when provided.
    /// Remaining mode inverts the % and adds the self-describing suffix.
    func testHoverTooltipBuilder() {
        let l = L(.en)
        func rows(_ session: Double?, _ weekly: Double?, _ modelWeekly: Double?,
                  _ experience: Double? = nil) -> [FloatingPetView.LimitRow] {
            FloatingPetView.hoverLimitRows(
                sessionPercent: session, weeklyPercent: weekly, modelWeeklyPercent: modelWeekly,
                modelName: "Fable", experiencePercent: experience, l: l)
        }
        func tooltip(_ session: Double?, _ weekly: Double?, _ modelWeekly: Double?,
                     _ mode: UsageStore.LimitDisplayMode = .used) -> UsageStore.BubbleContent {
            FloatingPetView.hoverTooltip(rows: rows(session, weekly, modelWeekly),
                                         todayTokens: 12_345, mode: mode, l: l)
        }
        // 줄 목록은 막대와 글자판이 함께 쓰는 원본이다 — 사용률을 변환하지 않고 그대로 담는다.
        XCTAssertEqual(rows(41, 33, 12).map(\.label), [l.fiveHourSession, l.weekly, "Fable \(l.weekly)"])
        XCTAssertEqual(rows(41, 33, 12).map(\.percent), [41, 33, 12])
        XCTAssertEqual(rows(nil, nil, nil), [])
        // 경험치는 펫 자신의 값이라 한도 아래에 붙고, used/remaining 뒤집기를 따르지 않는다.
        let withExp = rows(41, nil, nil, 62)
        XCTAssertEqual(withExp.last?.label, l.expLabel)
        XCTAssertEqual(withExp.last?.kind, .experience)
        XCTAssertEqual(withExp.first?.kind, .limit)
        // 제목은 한도, 본문은 세션·주간·모델별 주간 순서로 값마다 한 줄.
        let full = tooltip(41, 33, 12)
        XCTAssertEqual(full.title, l.statusTitle)
        XCTAssertEqual(full.body, [
            "\(l.fiveHourSession) \(TokenFormatter.percent(41))",
            "\(l.weekly) \(TokenFormatter.percent(33))",
            "Fable \(l.weekly) \(TokenFormatter.percent(12))",
        ].joined(separator: "\n"))
        // 없는 값의 줄은 빼고 순서는 유지한다. 빈 자리를 0% 로 채우지 않는다.
        XCTAssertEqual(tooltip(nil, 33, nil).body, "\(l.weekly) \(TokenFormatter.percent(33))")
        XCTAssertEqual(tooltip(41, nil, 12).body, [
            "\(l.fiveHourSession) \(TokenFormatter.percent(41))",
            "Fable \(l.weekly) \(TokenFormatter.percent(12))",
        ].joined(separator: "\n"))
        // remaining 모드는 %를 뒤집고 자기설명 접미사를 붙인다.
        XCTAssertEqual(
            tooltip(41, nil, nil, .remaining).body,
            "\(l.fiveHourSession) \(l.percentRemaining(TokenFormatter.percent(59)))")
        // remaining 모드에서도 경험치는 쌓인 양 그대로다. 뒤집으면 "38% 남음"이 되어 뜻이 바뀐다.
        XCTAssertEqual(
            FloatingPetView.hoverTooltip(rows: rows(nil, nil, nil, 62), todayTokens: 0,
                                         mode: .remaining, l: l).body,
            "\(l.expLabel) \(TokenFormatter.percent(62))")
        // 한도를 아직 못 받았으면 빈 툴팁 대신 오늘 토큰으로 되돌아간다.
        let empty = tooltip(nil, nil, nil)
        XCTAssertEqual(empty.title, l.floatingPetHoverTokensOnly(TokenFormatter.grouped(12_345)))
        XCTAssertEqual(empty.body, "")
    }

    /// [회귀] 호버 콜아웃의 글자와 외곽선은 같은 appearance에서 해석되어야 한다.
    /// 기존 경로는 텍스트 필드에 동적 `.labelColor`를 지정하면서 뷰를 만드는 동안
    /// `windowBackgroundColor.cgColor`를 굳혔다. 그 결과 다크 모드에서 밝은 말풍선에
    /// 흰 글자가 놓일 수 있었다.
    func testHoverCalloutColorsFollowLightAndDarkAppearance() throws {
        let light = try XCTUnwrap(NSAppearance(named: .aqua))
        let dark = try XCTUnwrap(NSAppearance(named: .darkAqua))
        let lightColors = FloatingPetController.hoverCalloutColors(for: light)
        let darkColors = FloatingPetController.hoverCalloutColors(for: dark)

        XCTAssertTrue(lightColors.text.isEqual(Self.snapshot(NSColor.labelColor, for: light)))
        XCTAssertTrue(lightColors.background.isEqual(Self.snapshot(NSColor.windowBackgroundColor, for: light)))
        XCTAssertTrue(lightColors.border.isEqual(Self.snapshot(NSColor.separatorColor, for: light)))
        XCTAssertTrue(darkColors.text.isEqual(Self.snapshot(NSColor.labelColor, for: dark)))
        XCTAssertTrue(darkColors.background.isEqual(Self.snapshot(NSColor.windowBackgroundColor, for: dark)))
        XCTAssertTrue(darkColors.border.isEqual(Self.snapshot(NSColor.separatorColor, for: dark)))

        XCTAssertFalse(lightColors.text.isEqual(darkColors.text), "text color must change with appearance")
        XCTAssertFalse(lightColors.background.isEqual(darkColors.background),
                      "bubble background must change with appearance")
        XCTAssertFalse(lightColors.text.isEqual(lightColors.background),
                       "라이트 모드 콜아웃 글자는 배경과 달라야 함")
        XCTAssertFalse(darkColors.text.isEqual(darkColors.background),
                       "다크 모드 콜아웃 글자는 배경과 달라야 함")
    }

    /// Alert copy in *every* language must fit the default bubble panel — width-capped wrap,
    /// not intrinsic `.fixedSize` that clipped ja by ~9pt (owner review on #124).
    /// Iterate `allCases`, never a literal list: a hardcoded `[.ko, .en, .ja]` silently stopped
    /// covering Spanish the moment #159 landed, which is exactly when a layout guard matters.
    ///
    /// 줄 수 제한을 없앤 뒤로는 "잘리는가"가 아니라 "패널이 그만큼 자라는가"가 지킬 값이다.
    /// 앱 자신의 한도 문구는 최소 높이 안에 들어와야 한다 — 그보다 크면 짧은 경고에도 패널이
    /// 커져 pet 이 화면에서 밀린다.
    func testLocalizedAlertBubbleFitsDefaultPanel() {
        let pet: CGFloat = 96
        let panel = FloatingPetController.panelSize(
            petSize: pet, headroom: FloatingPetController.bubbleHeadroom)
        // 말풍선 폭에 그림자 여백을 더한 만큼이 패널이다. 딱 맞추면 그림자가 잘린다.
        XCTAssertEqual(panel.width,
                       FloatingPetController.bubbleMinWidth
                           + FloatingPetController.bubbleShadowMargin * 2)
        XCTAssertEqual(panel.height,
                       pet + FloatingPetController.bubbleHeadroom
                           + FloatingPetController.bubbleShadowMargin)
        XCTAssertGreaterThan(panel.width, FloatingPetController.bubbleMinWidth,
                             "말풍선이 패널 경계에 닿으면 그림자와 외곽선이 깎인다")
        XCTAssertEqual(
            FloatingPetController.bubbleContentWidth
                + FloatingPetController.bubbleHorizontalPadding * 2,
            FloatingPetController.bubbleMinWidth,
            "content column + horizontal padding must equal panel width")

        for lang in AppLanguage.allCases {
            let l = L(lang)
            for title in [l.notifCritical, l.notifWarning] {
                for window in Self.alertWindows(l) {
                    let body = l.notifBody(window, TokenFormatter.percent(85))
                    let content = UsageStore.BubbleContent(title: title, body: body)
                    XCTAssertEqual(
                        FloatingPetController.headroom(for: content, petSize: pet),
                        FloatingPetController.bubbleHeadroom,
                        "\(lang.rawValue) '\(title)' / '\(body)' 가 최소 높이를 넘겼다")
                }
            }
        }
    }

    /// 줄 수를 제한하지 않으므로 긴 알림은 패널이 그만큼 위로 자란다.
    func testPanelHeadroomFollowsBubbleContent() {
        let pet: CGFloat = 152
        let short = UsageStore.BubbleContent(title: "알림", body: "짧은 본문")
        let long = UsageStore.BubbleContent(
            title: "알림", body: String(repeating: "긴 본문이 이어진다. ", count: 40))
        let shortRoom = FloatingPetController.headroom(for: short, petSize: pet)
        let longRoom = FloatingPetController.headroom(for: long, petSize: pet)
        XCTAssertEqual(shortRoom, FloatingPetController.bubbleHeadroom, "짧으면 최소 높이 그대로다")
        XCTAssertGreaterThan(longRoom, shortRoom, "길면 그만큼 자라야 잘리지 않는다")
        XCTAssertEqual(FloatingPetController.panelSize(petSize: pet, headroom: longRoom).height,
                       pet + longRoom + FloatingPetController.bubbleShadowMargin)
        // 말풍선이 없으면 패널은 pet 크기다.
        XCTAssertEqual(FloatingPetController.headroom(for: nil, petSize: pet), 0)
        XCTAssertEqual(FloatingPetController.panelSize(petSize: pet, headroom: 0),
                       NSSize(width: pet, height: pet))
    }

    /// 알림 본문은 길이 제한이 없다. 한 통이 화면보다 길어도 패널은 화면 안에 머물러야 한다.
    func testHeadroomStopsAtScreenHeight() {
        let pet: CGFloat = 152
        let flood = UsageStore.BubbleContent(
            title: "알림", body: String(repeating: "가", count: 20_000))
        let room = FloatingPetController.headroom(for: flood, petSize: pet, screenHeight: 900)
        XCTAssertLessThanOrEqual(room, 900 - pet - FloatingPetController.bubbleShadowMargin)
        XCTAssertGreaterThan(room, FloatingPetController.bubbleHeadroom)
    }

    /// 말풍선이 사라질 때 패널을 먼저 줄이면 퇴장 애니메이션이 창 밖으로 잘려 뚝 끊겨 보인다.
    /// 크기가 같을 때 다시 그리라고 시키는 것도 진행 중인 애니메이션을 끊으므로 건너뛴다.
    func testFrameUpdateDefersShrinkUntilBubbleLeaves() {
        let small = NSRect(x: 0, y: 0, width: 152, height: 152)
        let large = NSRect(x: 0, y: 0, width: 180, height: 152 + FloatingPetController.bubbleHeadroom)
        XCTAssertEqual(
            FloatingPetController.frameUpdate(current: small, target: large, showingBubble: true), .now)
        XCTAssertEqual(
            FloatingPetController.frameUpdate(current: large, target: small, showingBubble: false),
            .afterBubbleExit)
        XCTAssertEqual(
            FloatingPetController.frameUpdate(current: large, target: large, showingBubble: true), .none)
        XCTAssertEqual(
            FloatingPetController.frameUpdate(current: small, target: small, showingBubble: false), .none)
    }






    /// Unclamped single-line width must be able to exceed the content column.
    /// `measureSpeechBubble` returns `min(contentWidth, …) + padding` (= panel width),
    /// so comparing that to `panel.width` can never fail (#167).
    func testUnclampedBubbleTextWidthCanExceedContentColumn() {
        let title = "Límite inminente"
        let body = String(repeating: "M", count: 80)
        let layout = FloatingPetController.measureSpeechBubbleLayout(title: title, body: body)
        XCTAssertGreaterThan(
            layout.unclampedBodyWidth, layout.size.width,
            "unclamped width must exceed the clamped chrome, not echo min(contentWidth, …) + padding")
        XCTAssertGreaterThan(
            layout.unclampedBodyWidth, FloatingPetController.bubbleContentWidth)

        let short = FloatingPetController.measureSpeechBubbleLayout(title: "Hi", body: "Hi")
        XCTAssertEqual(short.bodyLineCount, 1)
        XCTAssertLessThanOrEqual(short.unclampedBodyWidth, FloatingPetController.bubbleContentWidth)
        XCTAssertLessThanOrEqual(short.unclampedTitleWidth, FloatingPetController.bubbleContentWidth)
    }

    /// Window names that `buildLimitWindows` can put in a bubble body.
    private static func alertWindows(_ l: L) -> [String] {
        [
            l.claudeFiveHour,
            l.claudeWeekly,
            "Claude \(l.weeklyOpus)",
            "Claude \(l.weeklySonnet)",
            l.codexPersonalLimit,
            "Codex \(l.codexWindow(300))",
            "Codex \(l.codexWindow(10_080))",
            "Claude \(l.claudeLimitEntry(kind: "weekly_scoped", model: "Opus"))",
            "\(l.antigravityGeminiGroup) \(l.fiveHourSession)",
            "\(l.antigravityThirdPartyGroup) \(l.weekly)",
        ]
    }

    private static func snapshot(_ color: NSColor, for appearance: NSAppearance) -> NSColor {
        var resolved = color
        appearance.performAsCurrentDrawingAppearance {
            resolved = NSColor(cgColor: color.cgColor) ?? color
        }
        return resolved
    }


}
