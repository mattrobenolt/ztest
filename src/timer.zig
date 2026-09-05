//! Monotonic timer. 0.15 has std.time.Timer; 0.16 removed it, so we use
//! libc clock_gettime(CLOCK_MONOTONIC) directly — works on both since the
//! runner links libc.
//!
//! The pure elapsed-time arithmetic lives in elapsed() so it can be tested
//! deterministically (see the test blocks below, wired into `zig build test`
//! by build.zig) without touching the real clock.

const std = @import("std");

pub const Timer = struct {
    start_ts: std.c.timespec,

    pub fn start() Timer {
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
        return .{ .start_ts = ts };
    }

    /// Elapsed time in nanoseconds.
    pub fn read(self: *const Timer) u64 {
        var now_ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &now_ts);
        return elapsed(self.start_ts, now_ts);
    }
};

/// Elapsed nanoseconds between two CLOCK_MONOTONIC timestamps.
///
/// The (sec, nsec) difference must be computed as signed wide arithmetic on
/// the complete pair before converting to u64. Clamping either field to u64
/// first (or dropping start_ts.nsec) miscomputes sub-second elapsed time.
pub fn elapsed(start_ts: std.c.timespec, now_ts: std.c.timespec) u64 {
    const dsec: i64 = @as(i64, now_ts.sec) - @as(i64, start_ts.sec);
    const dnsec: i64 = @as(i64, now_ts.nsec) - @as(i64, start_ts.nsec);
    return @intCast(dsec * std.time.ns_per_s + dnsec);
}

fn at(sec: i64, nsec: i64) std.c.timespec {
    return .{ .sec = @intCast(sec), .nsec = @intCast(nsec) };
}

test "elapsed within the same second" {
    try std.testing.expectEqual(@as(u64, 50_000_000), elapsed(at(10, 900_000_000), at(10, 950_000_000)));
}

test "elapsed across one second boundary" {
    try std.testing.expectEqual(@as(u64, 200_000_000), elapsed(at(10, 900_000_000), at(11, 100_000_000)));
}

test "elapsed across multiple seconds" {
    try std.testing.expectEqual(@as(u64, 1_200_000_000), elapsed(at(10, 900_000_000), at(12, 100_000_000)));
}

test "elapsed at equal timestamps is zero" {
    try std.testing.expectEqual(@as(u64, 0), elapsed(at(10, 900_000_000), at(10, 900_000_000)));
}

test "elapsed same nanosecond field across one second" {
    try std.testing.expectEqual(@as(u64, 1_000_000_000), elapsed(at(10, 900_000_000), at(11, 900_000_000)));
}
