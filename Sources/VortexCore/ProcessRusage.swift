import Darwin
import Darwin.libproc
import Foundation

/// Тонкая обёртка над BSD `proc_pid_rusage` — для FreezeRanker'а:
/// сравнивать RSS до/после freeze, чтобы понимать сколько реально
/// освободилось.
public enum ProcessRusage {
    /// Возвращает текущий resident set size процесса в байтах. nil если
    /// процесс недоступен (умер / чужой EUID).
    public static func residentBytes(pid: Int32) -> Int? {
        var info = rusage_info_v4()
        let rc = withUnsafeMutablePointer(to: &info) { ptr -> Int32 in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { typed in
                proc_pid_rusage(pid, RUSAGE_INFO_V4, typed)
            }
        }
        guard rc == 0 else { return nil }
        return Int(info.ri_resident_size)
    }
}
