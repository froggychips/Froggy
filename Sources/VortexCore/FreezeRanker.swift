import Foundation
import os

/// Считает «сколько реально освободил freeze» и «как долго оживает thaw»
/// для каждого pid'а, и пишет результаты в `FreezeStatsStore`. Mem-5 этап 1:
/// только сбор телеметрии — overlay (выбор tier'ов на основе медиан) пойдёт
/// отдельным PR'ом, когда данных накопится.
public actor FreezeRanker {
    private static let log = Logger(subsystem: "com.froggychips.froggy", category: "freeze-ranker")

    private let store: FreezeStatsStore
    /// Через сколько секунд после freeze снимать `rss_after`. Достаточно
    /// 5с для jetsam/scratch, машины успевают закомпрессить.
    private let postFreezeDelay: TimeInterval

    /// Тестовая инжекция: позволяет подменить чтение RSS на mock.
    private let rssReader: @Sendable (Int32) -> Int?

    /// Активные «эпизоды» freeze — pid → bundleId, rss_before, ts.
    private var inflight: [Int32: InflightFreeze] = [:]

    public init(
        store: FreezeStatsStore,
        postFreezeDelay: TimeInterval = 5,
        rssReader: @escaping @Sendable (Int32) -> Int? = ProcessRusage.residentBytes
    ) {
        self.store = store
        self.postFreezeDelay = postFreezeDelay
        self.rssReader = rssReader
    }

    private struct InflightFreeze {
        let bundleId: String
        let rssBefore: Int
        let strategy: String?
        let startedAt: Date
    }

    /// Вызывать сразу после успешного `SIGSTOP` + pageout. Снимает
    /// `rss_before`, через `postFreezeDelay` снимет `rss_after` и запишет
    /// событие в БД.
    public func recordFreeze(pid: Int32, bundleId: String, pageoutStrategy: String?) {
        let rss = rssReader(pid) ?? 0
        let entry = InflightFreeze(
            bundleId: bundleId,
            rssBefore: rss,
            strategy: pageoutStrategy,
            startedAt: Date()
        )
        inflight[pid] = entry

        // Через postFreezeDelay делаем снимок и пишем.
        let reader = rssReader
        let store = store
        let delay = postFreezeDelay
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            await self?.completeRecord(pid: pid, reader: reader, store: store)
        }
    }

    private func completeRecord(
        pid: Int32,
        reader: @Sendable (Int32) -> Int?,
        store: FreezeStatsStore
    ) async {
        guard let entry = inflight.removeValue(forKey: pid) else { return }
        let rssAfter = reader(pid) ?? entry.rssBefore // если pid уже умер
        let event = FreezeStatsStore.Event(
            timestamp: entry.startedAt,
            bundleId: entry.bundleId,
            pid: pid,
            rssBefore: entry.rssBefore,
            rssAfter: rssAfter,
            pageoutStrategy: entry.strategy,
            recoveryMs: nil
        )
        do {
            try await store.record(event)
        } catch {
            Self.log.warning("freeze stats record failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Вызывать на `SIGCONT`. Стартует поллинг, чтобы засечь время до
    /// первой активности процесса (CPU-burst через `proc_pid_rusage`).
    /// Если pid уже исчез — пропуск.
    public func recordThaw(pid: Int32, bundleId: String) {
        let reader = rssReader
        let store = store
        Task { [weak self] in
            await self?.measureRecovery(pid: pid, bundleId: bundleId, reader: reader, store: store)
        }
    }

    private func measureRecovery(
        pid: Int32,
        bundleId: String,
        reader: @Sendable (Int32) -> Int?,
        store: FreezeStatsStore
    ) async {
        let start = Date()
        let initialRss = reader(pid) ?? 0
        // Поллинг 100мс × 50 = 5 сек максимум.
        for _ in 0..<50 {
            try? await Task.sleep(for: .milliseconds(100))
            guard let rss = reader(pid) else { return }
            // Простая эвристика: rss изменился (delta > 1 MB) → процесс ожил.
            if abs(rss - initialRss) > 1_048_576 {
                let ms = Int(Date().timeIntervalSince(start) * 1000)
                let event = FreezeStatsStore.Event(
                    bundleId: bundleId,
                    pid: pid,
                    rssBefore: initialRss,
                    rssAfter: rss,
                    pageoutStrategy: nil,
                    recoveryMs: ms
                )
                try? await store.record(event)
                return
            }
        }
        // Таймаут — фиксируем как «recovered после 5с» с верхней границей.
        let event = FreezeStatsStore.Event(
            bundleId: bundleId,
            pid: pid,
            rssBefore: initialRss,
            rssAfter: initialRss,
            pageoutStrategy: nil,
            recoveryMs: 5_000
        )
        try? await store.record(event)
    }
}
