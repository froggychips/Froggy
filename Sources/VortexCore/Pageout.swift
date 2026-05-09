import Darwin
import Foundation
import os

/// Стратегия принудительного pageout: после `SIGSTOP` страницы dirty всё ещё
/// резидентны, и SIGSTOP сам по себе RAM не возвращает. Заставляем компрессор
/// вытеснить процесс одним из трёх путей.
public enum PageoutStrategy: String, Sendable, Codable, CaseIterable {
    /// `task_for_pid` + `mach_vm_behavior_set(VM_BEHAVIOR_PAGEOUT)` для каждого
    /// region'а. Самый прямой путь — но требует `task_for_pid-allow`-entitlement
    /// и Developer ID-подписи.
    case machVM
    /// `memorystatus_control(MEMORYSTATUS_CMD_SET_PRIORITY_PROPERTIES, idle, …)` —
    /// двигает процесс в jetsam idle-band, и компрессор ставит его первым в
    /// очередь на pageout под реальным давлением. Без entitlements, но без
    /// гарантии немедленного pageout.
    case jetsam
    /// Аллоцируем `scratchMB` буфер, заполняем его, освобождаем — провоцируем
    /// компрессор сделать его работу прямо сейчас. Грязный fallback, но
    /// работает всегда без специальных прав.
    case scratch
}

public enum PageoutOutcome: Sendable, Equatable {
    case success(strategyUsed: PageoutStrategy)
    case skipped(reason: String)
    case failed(reason: String)
}

/// Узкий интерфейс для одной стратегии. Реальные реализации — отдельные структы;
/// тесты подменяют `FakePageoutImpl`.
public protocol PageoutImpl: Sendable {
    func pageout(pid: Int32) async -> PageoutOutcome
}

/// Композит: пробует preferredStrategy, при KERN_FAILURE/EPERM откатывается
/// по цепочке machVM → jetsam → scratch. Лог-варн один раз за сессию для
/// каждого «сорванного» уровня.
public actor PageoutChain {
    private static let log = Logger(subsystem: "com.froggychips.froggy", category: "pageout")
    /// Signposter для Instruments. Каждая попытка стратегии становится
    /// interval на timeline'е, что закрывает validation-gate'овский
    /// вопрос "какая стратегия реально срабатывает на этой машине"
    /// (см. ADR 0007 / 0011).
    private static let signposter = OSSignposter(subsystem: "com.froggychips.froggy", category: "pageout")
    private static let poi = OSSignposter(subsystem: "com.froggychips.froggy", category: "PointsOfInterest")

    private let preferred: PageoutStrategy
    private let machVM: any PageoutImpl
    private let jetsam: any PageoutImpl
    private let scratch: any PageoutImpl

    private var loggedFailureFor: Set<PageoutStrategy> = []
    private var counters: PageoutCounters = .init()

    public init(
        preferred: PageoutStrategy = .jetsam,
        machVM: any PageoutImpl = MachVMPageoutImpl(),
        jetsam: any PageoutImpl = JetsamPageoutImpl(),
        scratch: any PageoutImpl = ScratchPageoutImpl(scratchMB: 256)
    ) {
        self.preferred = preferred
        self.machVM = machVM
        self.jetsam = jetsam
        self.scratch = scratch
    }

    /// Кумулятивные счётчики попыток/успехов/провалов pageout —
    /// отдаются в IPC `pressure` для observability (без них не понять,
    /// работает ли jetsam в данном сетапе).
    public func currentCounters() -> PageoutCounters { counters }

    public func pageout(pid: Int32) async -> PageoutOutcome {
        let order: [(PageoutStrategy, any PageoutImpl)]
        switch preferred {
        case .machVM:  order = [(.machVM, machVM), (.jetsam, jetsam), (.scratch, scratch)]
        case .jetsam:  order = [(.jetsam, jetsam), (.scratch, scratch)]
        case .scratch: order = [(.scratch, scratch)]
        }

        for (strategy, impl) in order {
            // Interval per strategy attempt — видно в Instruments длительность
            // и outcome (success/skipped/failed).
            let id = Self.signposter.makeSignpostID()
            let state = Self.signposter.beginInterval(
                "pageout-attempt", id: id,
                "strategy=\(strategy.rawValue, privacy: .public) pid=\(pid, privacy: .public)"
            )
            counters.bump(strategy, .attempted)
            let outcome = await impl.pageout(pid: pid)
            switch outcome {
            case .success:
                counters.bump(strategy, .succeeded)
                Self.signposter.endInterval("pageout-attempt", state,
                                             "outcome=success")
                Self.poi.emitEvent("pageout_success",
                                    "strategy=\(strategy.rawValue, privacy: .public) pid=\(pid, privacy: .public)")
                return outcome
            case .skipped:
                Self.signposter.endInterval("pageout-attempt", state,
                                             "outcome=skipped")
                return outcome
            case .failed(let reason):
                counters.bump(strategy, .failed)
                Self.signposter.endInterval("pageout-attempt", state,
                                             "outcome=failed reason=\(reason, privacy: .public)")
                if !loggedFailureFor.contains(strategy) {
                    loggedFailureFor.insert(strategy)
                    Self.log.warning("pageout strategy \(strategy.rawValue, privacy: .public) failed (\(reason, privacy: .public)); falling back")
                }
                continue
            }
        }
        return .failed(reason: "all pageout strategies failed for pid \(pid)")
    }
}

/// Кумулятивные счётчики pageout для IPC `pressure`. Не сбрасываются.
public struct PageoutCounters: Sendable, Codable, Equatable {
    public var machVMAttempted: Int = 0
    public var machVMSucceeded: Int = 0
    public var machVMFailed: Int = 0
    public var jetsamAttempted: Int = 0
    public var jetsamSucceeded: Int = 0
    public var jetsamFailed: Int = 0
    public var scratchAttempted: Int = 0
    public var scratchSucceeded: Int = 0
    public var scratchFailed: Int = 0

    public enum Slot: Sendable { case attempted, succeeded, failed }

    public init() {}

    public mutating func bump(_ strategy: PageoutStrategy, _ slot: Slot) {
        switch (strategy, slot) {
        case (.machVM, .attempted): machVMAttempted += 1
        case (.machVM, .succeeded): machVMSucceeded += 1
        case (.machVM, .failed): machVMFailed += 1
        case (.jetsam, .attempted): jetsamAttempted += 1
        case (.jetsam, .succeeded): jetsamSucceeded += 1
        case (.jetsam, .failed): jetsamFailed += 1
        case (.scratch, .attempted): scratchAttempted += 1
        case (.scratch, .succeeded): scratchSucceeded += 1
        case (.scratch, .failed): scratchFailed += 1
        }
    }
}

// MARK: - machVM impl

/// `task_for_pid` → `mach_vm_region` enumerate → `mach_vm_behavior_set(VM_BEHAVIOR_PAGEOUT)`.
/// На обычной dev-подписи `task_for_pid` возвращает `KERN_FAILURE` — это сигнал
/// для `PageoutChain` упасть к jetsam.
public struct MachVMPageoutImpl: PageoutImpl {
    public init() {}

    public func pageout(pid: Int32) async -> PageoutOutcome {
        var task: mach_port_t = 0
        let kr = task_for_pid(mach_task_self_, pid, &task)
        if kr != KERN_SUCCESS {
            return .failed(reason: "task_for_pid kr=\(kr) — нет task_for_pid-allow entitlement?")
        }
        defer { mach_port_deallocate(mach_task_self_, task) }

        var address: mach_vm_address_t = 0
        var hinted: UInt64 = 0
        let infoCount0 = mach_msg_type_number_t(
            MemoryLayout<vm_region_basic_info_data_64_t>.size / MemoryLayout<integer_t>.size
        )
        while true {
            var size: mach_vm_size_t = 0
            var info = vm_region_basic_info_data_64_t()
            var infoCount = infoCount0
            var objectName: mach_port_t = 0

            let regionKR = withUnsafeMutablePointer(to: &info) { infoPtr -> kern_return_t in
                infoPtr.withMemoryRebound(to: integer_t.self, capacity: Int(infoCount0)) { intPtr in
                    mach_vm_region(
                        task,
                        &address,
                        &size,
                        kVMRegionBasicInfo64,
                        intPtr,
                        &infoCount,
                        &objectName
                    )
                }
            }
            if regionKR == KERN_INVALID_ADDRESS { break }
            if regionKR != KERN_SUCCESS {
                return .failed(reason: "mach_vm_region kr=\(regionKR) at \(address)")
            }

            // Пропускаем executable-страницы — pageout кода ничего не даёт,
            // ядро всё равно держит их read-only из mapped binary.
            let prot = info.protection
            let isExec = (prot & VM_PROT_EXECUTE) != 0
            let isWritable = (prot & VM_PROT_WRITE) != 0
            if !isExec && isWritable {
                let behaviorKR = mach_vm_behavior_set(task, address, size, kVMBehaviorPageout)
                if behaviorKR == KERN_SUCCESS {
                    hinted &+= UInt64(size)
                }
                // KERN_INVALID_ARGUMENT часто бывает на shared-memory-региях,
                // не считаем фатальным — просто пропускаем.
            }
            address &+= mach_vm_address_t(size)
        }
        return .success(strategyUsed: .machVM)
    }
}

// MARK: - jetsam impl

/// Двигает процесс в jetsam-band «idle» через memorystatus_control. Без
/// entitlements; на dev-подписи может вернуть EPERM — `PageoutChain` тогда
/// откатится на scratch.
public struct JetsamPageoutImpl: PageoutImpl {
    public init() {}

    public func pageout(pid: Int32) async -> PageoutOutcome {
        var props = MemorystatusPriorityProperties(priority: kJetsamPriorityIdle, userData: 0)
        let rc = withUnsafeMutablePointer(to: &props) { ptr -> Int32 in
            memorystatus_control_swift(
                kMemorystatusCmdSetPriorityProperties,
                pid,
                0,
                UnsafeMutableRawPointer(ptr),
                MemoryLayout<MemorystatusPriorityProperties>.size
            )
        }
        if rc != 0 {
            return .failed(reason: "memorystatus_control rc=\(rc) errno=\(errno)")
        }
        return .success(strategyUsed: .jetsam)
    }
}

// MARK: - scratch impl

/// Аллоцирует `scratchMB` MB heap, прогоняет memset → free. Системный
/// компрессор реагирует на скачок и часто вытесняет именно «холодные» pages
/// SIGSTOP-нутого процесса, потому что они in-active. Самый грязный, но
/// работающий путь.
public struct ScratchPageoutImpl: PageoutImpl {
    public let scratchMB: Int
    public init(scratchMB: Int) {
        self.scratchMB = max(16, scratchMB)
    }

    public func pageout(pid: Int32) async -> PageoutOutcome {
        // Detached, чтобы не блокировать caller (выделение 256 MB занимает
        // десятки мс).
        await Task.detached(priority: .background) {
            let bytes = Self.totalBytes(scratchMB: scratchMB)
            guard let buffer = malloc(bytes) else { return }
            memset(buffer, 0xAB, bytes)
            free(buffer)
        }.value
        _ = pid // не используется — это глобальная провокация, не таргетная
        return .success(strategyUsed: .scratch)
    }

    nonisolated private static func totalBytes(scratchMB: Int) -> Int {
        scratchMB * 1024 * 1024
    }
}

// MARK: - Тестовая реализация

public struct FakePageoutImpl: PageoutImpl {
    public let stub: @Sendable (Int32) -> PageoutOutcome
    public init(stub: @escaping @Sendable (Int32) -> PageoutOutcome) {
        self.stub = stub
    }
    public func pageout(pid: Int32) async -> PageoutOutcome { stub(pid) }
}

// MARK: - Биндинги к приватным sys-API

/// `memorystatus_control` объявлен в `<sys/kern_memorystatus.h>`, который
/// SDK не выставляет в публичном слое. Биндим вручную.
@_silgen_name("memorystatus_control")
private func memorystatus_control_swift(
    _ command: UInt32,
    _ pid: Int32,
    _ flags: UInt32,
    _ buffer: UnsafeMutableRawPointer?,
    _ buffersize: Int
) -> Int32

/// `MEMORYSTATUS_CMD_SET_PRIORITY_PROPERTIES` (xnu).
private let kMemorystatusCmdSetPriorityProperties: UInt32 = 1
/// `JETSAM_PRIORITY_IDLE` (xnu).
private let kJetsamPriorityIdle: Int32 = 0
/// `VM_REGION_BASIC_INFO_64` (mach/vm_region.h).
private let kVMRegionBasicInfo64: vm_region_flavor_t = 9
/// `VM_BEHAVIOR_PAGEOUT` (mach/vm_behavior.h).
private let kVMBehaviorPageout: vm_behavior_t = 6

private struct MemorystatusPriorityProperties {
    var priority: Int32
    var userData: UInt64
}
