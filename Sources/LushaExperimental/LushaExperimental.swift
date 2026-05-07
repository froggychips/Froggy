import Foundation
import LushaBridge

/// Регистратор опытных (`experimental: true`) аксессоров. Подключается
/// `FroggyDaemon` одной строкой; добавление нового experimental-аксессора
/// требует правки только этого файла, а не `main.swift` — см. ADR 0011 § EXP-1.
public struct LushaExperimentalRegistrar: AccessorRegistrar {
    public init() {}

    public func register(into registry: AccessorRegistry) async {
        await registry.register(ThermalStateAccessor())
    }
}

/// Sample experimental accessor — экспонирует thermal state процесса.
/// Тривиальный, без system permissions, deterministic для теста.
/// Существует, чтобы `experimental`-канал был непустой и проверяемый
/// сразу после merge'a EXP-1.
public struct ThermalStateAccessor: LushaAccessor {
    public let id = "thermal"
    public let name = "Process Thermal State"
    public let experimental = true

    public init() {}

    public func snapshot() async -> [String] {
        let state = ProcessInfo.processInfo.thermalState
        return ["state=\(label(for: state))", "raw=\(state.rawValue)"]
    }

    private func label(for state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}
