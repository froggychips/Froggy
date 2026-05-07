import AppKit
import Foundation
import os

/// События workspace + power, к которым реагирует daemon. Один общий enum,
/// чтобы не плодить N независимых стримов и одной подпиской ловить всё, что
/// нужно reactive-coordinator'у и reactive-process-finder'у.
public enum WorkspaceEvent: Sendable, Equatable {
    /// `NSWorkspace.didLaunchApplicationNotification` — pid появился. На
    /// практике мы не отличаем launch от activate'а, поэтому покрываем тем
    /// же `appActivated` чтобы reactive-finder увидел новый pid и для него,
    /// и при `didActivate`. Bundle-id может быть nil (xpc-helpers, agents).
    case appActivated(pid: Int32, bundleId: String?)
    case appDeactivated(pid: Int32, bundleId: String?)
    /// pid завершился (любым способом — quit, kill, OOM, jetsam).
    /// **Критично** для cleanup `FrozenPidsStore`: если frozen pid убили
    /// извне, он должен быть удалён из persisted store.
    case appTerminated(pid: Int32, bundleId: String?)
    /// Сменился frontmost-app (переключение фокуса между приложениями).
    /// Эмитится из `NSWorkspace.didActivateApplicationNotification`
    /// **дополнительно** к `appActivated` — это две разные семантики:
    /// `.appActivated` имеет «launch-or-activate» интерпретацию (нужен
    /// reactive-finder'у, чтобы увидеть новый pid), `.frontmostChanged`
    /// — это строго «теперь фокус у этого pid». Coordinator использует
    /// последний для frontmost-veto (ADR 0015).
    /// `pid == nil` — momentary state «фокуса нет ни у кого» (например,
    /// при logout / lock-screen). Сейчас RealWorkspaceEventSource не
    /// эмитит nil — оставлено для будущего расширения.
    case frontmostChanged(pid: Int32?, bundleId: String?)
    /// `NSWorkspace.willSleepNotification` — система собирается спать.
    /// Перед этим событием полезно отпустить freeze'ы: после wake
    /// замороженные pids могут отвалиться по watchdog'ам.
    case willSleep
    case didWake
    /// `screensDidSleepNotification` — пользователь заблокировал/выключил
    /// дисплей. Capture бесполезен (чёрный кадр) — можно остановить SCStream.
    case screensDidSleep
    case screensDidWake
}

/// Источник workspace/power-событий. Абстрагирован, чтобы тесты могли
/// эмитить события руками без живого `NSWorkspace.shared`.
/// Аналог `MemoryPressureSource` — тот же broadcast-паттерн с lock'ом.
public protocol WorkspaceEventSource: Sendable {
    /// Текущий снимок «кто сейчас бежит», для seed'а reactive-finder'а.
    /// Возвращает `[(pid, bundleId)]` (bundleId может быть nil).
    func runningApplications() async -> [(Int32, String?)]
    /// Текущий frontmost pid в момент seed'а (на старте `VortexCoordinator`).
    /// Без этого первый `.frontmostChanged` event приходит только когда
    /// пользователь руками переключит фокус — между запуском demon'а и
    /// первым переключением мы бы не знали кого veto'ить.
    /// Может вернуть nil, если frontmost-app в этот момент не определена
    /// (редкий race, но теоретически возможен на login window).
    func initialFrontmostPid() async -> Int32?
    func events() -> AsyncStream<WorkspaceEvent>
}

/// Реальный источник: подписан на `NSWorkspace.shared.notificationCenter`
/// и `NSWorkspace.shared.notificationCenter` для display-событий.
///
/// Все NSWorkspace-нотификации приходят на main thread; мы захватываем pid
/// из `userInfo[NSWorkspace.applicationUserInfoKey]` и форвардим во все
/// continuation'ы под lock'ом.
public final class RealWorkspaceEventSource: WorkspaceEventSource, @unchecked Sendable {
    private static let log = Logger(subsystem: "com.froggychips.froggy", category: "workspace-source")

    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<WorkspaceEvent>.Continuation] = [:]
    private var observers: [any NSObjectProtocol] = []

    public init() {
        let nc = NSWorkspace.shared.notificationCenter

        // Application lifecycle.
        observers.append(nc.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil, queue: nil
        ) { [weak self] note in
            self?.handleAppNote(note, kind: .launched)
        })
        observers.append(nc.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: nil
        ) { [weak self] note in
            self?.handleAppNote(note, kind: .activated)
        })
        observers.append(nc.addObserver(
            forName: NSWorkspace.didDeactivateApplicationNotification,
            object: nil, queue: nil
        ) { [weak self] note in
            self?.handleAppNote(note, kind: .deactivated)
        })
        observers.append(nc.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil, queue: nil
        ) { [weak self] note in
            self?.handleAppNote(note, kind: .terminated)
        })

        // Power / display.
        observers.append(nc.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil, queue: nil
        ) { [weak self] _ in
            self?.broadcast(.willSleep)
        })
        observers.append(nc.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil, queue: nil
        ) { [weak self] _ in
            self?.broadcast(.didWake)
        })
        observers.append(nc.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil, queue: nil
        ) { [weak self] _ in
            self?.broadcast(.screensDidSleep)
        })
        observers.append(nc.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil, queue: nil
        ) { [weak self] _ in
            self?.broadcast(.screensDidWake)
        })
    }

    deinit {
        let nc = NSWorkspace.shared.notificationCenter
        for o in observers { nc.removeObserver(o) }
    }

    public func runningApplications() async -> [(Int32, String?)] {
        await MainActor.run {
            NSWorkspace.shared.runningApplications.map { app in
                (app.processIdentifier, app.bundleIdentifier)
            }
        }
    }

    public func initialFrontmostPid() async -> Int32? {
        await MainActor.run {
            NSWorkspace.shared.frontmostApplication?.processIdentifier
        }
    }

    public func events() -> AsyncStream<WorkspaceEvent> {
        AsyncStream { cont in
            let id = UUID()
            self.lock.lock()
            self.continuations[id] = cont
            self.lock.unlock()
            cont.onTermination = { [weak self] _ in
                self?.lock.lock()
                self?.continuations.removeValue(forKey: id)
                self?.lock.unlock()
            }
        }
    }

    private enum AppKind { case launched, activated, deactivated, terminated }

    private func handleAppNote(_ note: Notification, kind: AppKind) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
            return
        }
        let pid = app.processIdentifier
        let bundleId = app.bundleIdentifier
        switch kind {
        case .launched:
            // Launch — это и «появился pid» (нужно reactive-finder'у), но не
            // обязательно «получил фокус». Эмитим только `.appActivated`
            // (legacy-семантика launch-or-activate), без `.frontmostChanged`.
            broadcast(.appActivated(pid: pid, bundleId: bundleId))
        case .activated:
            // Activate — двойная семантика. Эмитим оба события:
            // `.appActivated` для reactive-finder'a (он ожидает увидеть pid
            // на любом активе), `.frontmostChanged` для frontmost-veto.
            broadcast(.appActivated(pid: pid, bundleId: bundleId))
            broadcast(.frontmostChanged(pid: pid, bundleId: bundleId))
        case .deactivated:
            broadcast(.appDeactivated(pid: pid, bundleId: bundleId))
        case .terminated:
            broadcast(.appTerminated(pid: pid, bundleId: bundleId))
        }
    }

    private func broadcast(_ event: WorkspaceEvent) {
        lock.lock()
        let snapshot = Array(continuations.values)
        lock.unlock()
        for c in snapshot { c.yield(event) }
    }
}

/// Тестовый источник: руками вызываем `emit(_:)`. Снимок «running» —
/// явно через `seed`.
public final class FakeWorkspaceEventSource: WorkspaceEventSource, @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<WorkspaceEvent>.Continuation] = [:]
    private var seed: [(Int32, String?)] = []
    private var frontmostSeed: Int32?

    public init(seed: [(Int32, String?)] = [], frontmostPid: Int32? = nil) {
        self.seed = seed
        self.frontmostSeed = frontmostPid
    }

    public func setSeed(_ apps: [(Int32, String?)]) {
        lock.lock(); defer { lock.unlock() }
        seed = apps
    }

    public func setFrontmostSeed(_ pid: Int32?) {
        lock.lock(); defer { lock.unlock() }
        frontmostSeed = pid
    }

    public func runningApplications() async -> [(Int32, String?)] {
        lock.withLock { seed }
    }

    public func initialFrontmostPid() async -> Int32? {
        lock.withLock { frontmostSeed }
    }

    public func events() -> AsyncStream<WorkspaceEvent> {
        AsyncStream { cont in
            let id = UUID()
            self.lock.lock()
            self.continuations[id] = cont
            self.lock.unlock()
            cont.onTermination = { [weak self] _ in
                self?.lock.lock()
                self?.continuations.removeValue(forKey: id)
                self?.lock.unlock()
            }
        }
    }

    public func emit(_ event: WorkspaceEvent) {
        lock.lock()
        let snapshot = Array(continuations.values)
        lock.unlock()
        for c in snapshot { c.yield(event) }
    }
}
