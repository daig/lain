import Darwin

/// The one clock every timestamp in lain uses: `CLOCK_UPTIME_RAW` in nanoseconds (§7.4, §9).
public enum MonotonicClock {
    @inline(__always)
    public static func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
}
