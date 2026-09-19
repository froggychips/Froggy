import Darwin
import Foundation
import os

/// Стратегия принудительного pageout: после `SIGSTOP` страницы dirty всё ещё
/// резидентны, и SIGSTOP сам по себе RAM не возвращает. Заставляем компрессор
/// вытеснить процесс одним из трёх путей.
///
/// Честно (ADR 0018): для непривилегированного LaunchAgent реально работает
/// только `scratch`. `machVM` и `jetsam` оставлены как opt-in для окружений
/// с правами (root / отключённый SIP / development-ядро) — см. описания ниже.
public enum PageoutStrategy: String, Sendable, Codable, CaseIterable {
    /// `task_for_pid` + `mach_vm_behavior_set(VM_BEHAVIOR_PAGEOUT)` для каждого
    /// writable-region'а. Требует `task_for_pid` на чужой процесс (SIP off или
    /// entitlement), а сам `VM_BEHAVIOR_PAGEOUT` в SDK помечен «development
    /// only»: release-ядро отвечает `KERN_INVALID_ARGUMENT` на каждый region,
    /// и стратегия честно возвращает `.failed`. До ревью 2026-09-19 здесь стояла
    /// константа 6 = `VM_BEHAVIOR_FREE` («освободить без write-back»), то есть
    /// уничтожение содержимого страниц чужого процесса.
    case machVM
    /// `memorystatus_control(MEMORYSTATUS_CMD_SET_PRIORITY_PROPERTIES, idle, …)` —
    /// двигает процесс в jetsam idle-band. XNU (`bsd/kern/kern_memorystatus.c`)
    /// пускает к этой команде только root или процесс с entitlement
    /// `com.apple.private.memorystatus`; всем остальным — `EPERM`. Для обычного
    /// LaunchAgent стратегия недостижима.
    case jetsam
    /// Аллоцируем `scratchMB` буфер, заполняем его, освобождаем — провоцируем
    /// компрессор сделать его работу прямо сейчас. Грязно, но это единственный
    /// путь без привилегий; дефолт с ADR 0018.
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
///
/// Дефолт `preferred` — `.scratch` (ADR 0018): machVM/jetsam без привилегий
/// гарантированно падают, и их попытка лишь портит счётчики в IPC `pressure`.
public actor PageoutChain {
    private static let log = Logger(subsystem: "com.froggychips.froggy", category: "pageout")

    private let preferred: PageoutStrategy
    private let machVM: any PageoutImpl
    private let jetsam: any PageoutImpl
    private let scratch: any PageoutImpl

    private var loggedFailureFor: Set<PageoutStrategy> = []
    private var counters: PageoutCounters = .init()

    public init(
        preferred: PageoutStrategy = .scratch,
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
            counters.bump(strategy, .attempted)
            let outcome = await impl.pageout(pid: pid)
            switch outcome {
            case .success:
                counters.bump(strategy, .succeeded)
                return outcome
            case .skipped:
                return outcome
            case .failed(let reason):
                counters.bump(strategy, .failed)
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
    private static let log = Logger(subsystem: "com.froggychips.froggy", category: "pageout")
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
        var candidateRegions = 0
        var acceptedRegions = 0
        var lastBehaviorKR: kern_return_t = KERN_SUCCESS
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
                candidateRegions += 1
                let behaviorKR = mach_vm_behavior_set(task, address, size, kVMBehaviorPageout)
                if behaviorKR == KERN_SUCCESS {
                    acceptedRegions += 1
                    hinted &+= UInt64(size)
                } else {
                    // KERN_INVALID_ARGUMENT — либо shared-memory-регион, либо
                    // (на release-ядре) сам VM_BEHAVIOR_PAGEOUT не поддержан.
                    // Один регион не фатален; фатально — когда не принят ни один.
                    lastBehaviorKR = behaviorKR
                }
            }
            address &+= mach_vm_address_t(size)
        }
        // Ноль принятых регионов — это не «успех без страниц», а отказ ядра:
        // VM_BEHAVIOR_PAGEOUT существует только в development-сборках XNU.
        // Возвращаем .failed, чтобы PageoutChain откатился дальше.
        guard acceptedRegions > 0 else {
            return .failed(
                reason: "mach_vm_behavior_set(VM_BEHAVIOR_PAGEOUT) принят 0 из \(candidateRegions) регионов "
                    + "(последний kr=\(lastBehaviorKR)) — release-ядро не поддерживает PAGEOUT"
            )
        }
        Self.log.debug("machVM pageout pid=\(pid) hinted \(hinted) bytes in \(acceptedRegions) regions")
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
            let err = errno
            if err == EPERM {
                return .failed(
                    reason: "memorystatus_control EPERM — SET_PRIORITY_PROPERTIES требует root или "
                        + "entitlement com.apple.private.memorystatus (XNU kern_memorystatus.c); "
                        + "для LaunchAgent стратегия jetsam недостижима, см. ADR 0018"
                )
            }
            return .failed(reason: "memorystatus_control rc=\(rc) errno=\(err)")
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

/// `MEMORYSTATUS_CMD_SET_PRIORITY_PROPERTIES` (xnu bsd/sys/kern_memorystatus.h).
/// Заголовок приватный, в SDK его нет — значение переписано с исходника XNU:
/// `1` = GET_PRIORITY_LIST, `2` = SET_PRIORITY_PROPERTIES. До ревью 2026-09-19
/// здесь стояла `1`, то есть в ядро уходила команда чтения списка.
private let kMemorystatusCmdSetPriorityProperties: UInt32 = 2
/// `JETSAM_PRIORITY_IDLE` (xnu).
private let kJetsamPriorityIdle: Int32 = 0
/// `VM_REGION_BASIC_INFO_64` (mach/vm_region.h) — символ SDK, не магическое
/// число (fallback при проблеме импорта в Swift: 9).
private let kVMRegionBasicInfo64: vm_region_flavor_t = VM_REGION_BASIC_INFO_64
/// `VM_BEHAVIOR_PAGEOUT` (mach/vm_behavior.h) — символ SDK, `= 11`, «force
/// page-out of the pages in range (development only)». Fallback при проблеме
/// импорта: 11. Ни в коем случае не 6 — это `VM_BEHAVIOR_FREE`.
private let kVMBehaviorPageout: vm_behavior_t = VM_BEHAVIOR_PAGEOUT

private struct MemorystatusPriorityProperties {
    var priority: Int32
    var userData: UInt64
}
