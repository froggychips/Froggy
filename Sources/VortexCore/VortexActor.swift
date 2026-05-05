import Foundation

/// Модуль управления процессами и ресурсами.
/// Оптимизирован для Apple Silicon (ARM64).
actor VortexActor {
    private var suspendedPids: Set<Int32> = []
    
    /// Анализ давления на память (Memory Pressure)
    func getMemoryPressure() -> Int {
        var pressure: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memo_status_level", &pressure, &size, nil, 0) != 0 {
            return 0
        }
        return Int(pressure)
    }
    
    /// Заморозка процесса (SIGSTOP)
    func freezeProcess(pid: Int32) {
        if kill(pid, SIGSTOP) == 0 {
            suspendedPids.insert(pid)
            print("[Vortex] Process \(pid) suspended.")
        }
    }
    
    /// Разморозка процесса (SIGCONT)
    func thawProcess(pid: Int32) {
        if kill(pid, SIGCONT) == 0 {
            suspendedPids.remove(pid)
            print("[Vortex] Process \(pid) resumed.")
        }
    }
    
    /// Разморозить все перед выходом
    func thawAll() {
        for pid in suspendedPids {
            kill(pid, SIGCONT)
        }
        suspendedPids.removeAll()
    }
}
