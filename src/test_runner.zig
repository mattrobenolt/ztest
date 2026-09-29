//! ztest — a custom test runner for Zig that produces clean, parseable output.
//!
//! Designed for both humans (TTY with color) and agents/CI (non-TTY, one line
//! per test, inline stack traces). Replaces Zig's built-in test runner which
//! uses a TUI progress display that is hostile to non-interactive consumers.
//!
//! Usage in build.zig:
//!   const ztest = b.dependency("ztest", .{});
//!   const tests = b.addTest(.{
//!       .root_module = my_module,
//!       .test_runner = .{ .path = ztest.path("src/test_runner.zig"), .mode = .simple },
//!   });
//!
//! Or with zig test directly:
//!   zig test --test-runner src/test_runner.zig foo.zig
//!
//! Environment variables:
//!   ZTEST_VERBOSE=1|0   Override verbose detection (default: auto — on for non-TTY, off for TTY)
//!   ZTEST_PLAIN=1       Force non-TTY format: no ANSI colors, always verbose
//!   ZTEST_FAIL_FAST=1   Stop on first failure
//!   ZTEST_FILTER=substr Only run tests whose name contains substr

const std = @import("std");
const builtin = @import("builtin");

var current_test: ?[]const u8 = null;
var log_err_count: usize = 0;
var panicking: bool = false;

/// Requires Zig 0.16. The std.Io-era APIs (std.process.exit,
/// std.testing.io_instance, dumpErrorReturnTrace) are used unconditionally.
/// Root-level log function. std.log calls @import("root").logFn, which defaults
/// to this. We count .err level messages so we can fail tests that emit error
/// logs even if the test function itself returns success — matching the
/// built-in runner's behavior.
pub const std_options: std.Options = .{
    .logFn = log,
};

pub fn log(
    comptime message_level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    if (@intFromEnum(message_level) <= @intFromEnum(std.log.Level.err)) {
        log_err_count +|= 1;
    }
    if (@intFromEnum(message_level) <= @intFromEnum(testing.log_level)) {
        print("[" ++ @tagName(scope) ++ "] (" ++ @tagName(message_level) ++ "): " ++ format ++ "\n", args);
    }
}

/// Exit with a status code.
fn hardExit(status: u8) noreturn {
    std.process.exit(status);
}

/// Monotonic timer. 0.16 removed std.time.Timer, so we use
/// libc clock_gettime(CLOCK_MONOTONIC) directly — the runner links libc.
const Timer = struct {
    start_ts: std.c.timespec,

    fn start() Timer {
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
        return .{ .start_ts = ts };
    }

    /// Elapsed time in nanoseconds.
    fn read(self: *const Timer) u64 {
        var now_ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &now_ts);
        const sec: u64 = @intCast(now_ts.sec - self.start_ts.sec);
        const nsec: u64 = @intCast(now_ts.nsec);
        return sec * std.time.ns_per_s + nsec;
    }
};

pub const panic = std.debug.FullPanic(struct {
    pub fn panicFn(msg: []const u8, first_trace_addr: ?usize) noreturn {
        // Guard against recursive panic — if dumpBoundedStackTrace itself
        // panics (e.g. corrupt debug info), don't re-enter.
        if (panicking) {
            hardExit(1);
        }
        panicking = true;

        if (current_test) |ct| {
            print("PANIC in test \"{s}\": {s}\n", .{ ct, msg });
        } else {
            print("PANIC: {s}\n", .{msg});
        }

        // Do NOT call std.debug.defaultPanic — it calls dumpCurrentStackTrace
        // which uses StackIterator to walk live stack frames. On some platforms
        // (aarch64-linux in VMs), StackIterator.next() never returns null,
        // causing an infinite loop at 100% CPU.
        // See https://github.com/ziglang/zig/issues/18286
        //
        // Instead, do a bounded stack walk that is guaranteed to terminate.
        dumpBoundedStackTrace(first_trace_addr);
        hardExit(1);
    }
}.panicFn);

/// Print an error return trace to stderr.
fn dumpTrace(trace: ?*std.builtin.StackTrace) void {
    if (trace) |tr| {
        std.debug.dumpErrorReturnTrace(tr);
    }
}

/// Print the panic address. 0.16 made StackIterator/printSourceAtAddress
/// private, so a bounded source-resolved walk is no longer available here.
/// The error-return-trace path (dumpErrorReturnTrace) still gets full source
/// resolution. Address-only output also sidesteps the StackIterator
/// infinite-loop hazard on aarch64 VMs (ziglang/zig#18286).
fn dumpBoundedStackTrace(start_addr: ?usize) void {
    if (start_addr) |addr| {
        print("  panic address: 0x{x}\n", .{addr});
    }
}

pub fn main() !void {
    var mem: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&mem);
    const allocator = fba.allocator();

    // No --seed parsing: 0.16 removed std.process.args(); args are only
    // available via the main function parameter, which .mode = .simple
    // doesn't use.

    if (builtin.test_functions.len == 0) {
        print("no tests found\n", .{});
        return;
    }

    const env = Env.init(allocator);
    defer env.deinit(allocator);

    const have_tty = isStderrTty();
    const plain = env.plain or !have_tty;
    const verbose = env.verbose orelse plain;

    // Pre-count matching tests if a filter is active, so indices and totals
    // reflect only the tests that will actually run.
    const total = if (env.filter) |f| blk: {
        var count: usize = 0;
        for (builtin.test_functions) |t| {
            if (std.mem.find(u8, t.name, f) != null) count += 1;
        }
        break :blk count;
    } else builtin.test_functions.len;

    const timer = Timer.start();

    print("ztest: Running {d} test{s}...\n", .{ total, if (total != 1) "s" else "" });
    if (!verbose) print("\n", .{});

    var pass: usize = 0;
    var fail: usize = 0;
    var skip: usize = 0;
    var leak: usize = 0;
    var log_errs: usize = 0;
    var run_idx: usize = 0;
    var should_stop = false;

    for (builtin.test_functions) |t| {
        if (should_stop) break;

        const name = friendlyName(t.name);

        // Apply filter.
        if (env.filter) |f| {
            if (std.mem.find(u8, t.name, f) == null) continue;
        }

        run_idx += 1;

        current_test = name;
        testing.allocator_instance = .{};
        // Mirror the default runner: tests may use std.testing.io (process
        // spawn, file I/O, timestamps), which derefs io_instance. Without
        // this init the first such test segfaults in the allocator. The
        // environ comes from the C environ block because a simple-mode main
        // receives no Init.Minimal — an empty block means default PATH, and
        // spawned children (openssl in interop tests) would not resolve.
        const environ: std.process.Environ = if (builtin.link_libc) blk: {
            const c_environ = std.c.environ;
            var n: usize = 0;
            while (c_environ[n] != null) : (n += 1) {}
            break :blk .{ .block = .{ .slice = c_environ[0..n :null] } };
        } else .empty;
        testing.environ = environ;
        testing.io_instance = .init(testing.allocator, .{ .environ = environ });
        testing.log_level = .warn;
        log_err_count = 0;

        var test_timer = Timer.start();
        const result = t.func();

        current_test = null;
        // Capture log_err_count and error return trace BEFORE deinit — deinit
        // calls detectLeaks which logs leaks at .err level and can corrupt
        // the error return trace. @errorReturnTrace() returns null if the
        // last call didn't return an error.
        const test_log_errs = log_err_count;
        const trace = @errorReturnTrace();
        testing.io_instance.deinit();
        const leaked = testing.allocator_instance.deinit() == .leak;

        const ns = test_timer.read();
        const idx = run_idx;

        // Error logs count as a test failure, even if the test function returned
        // success or was skipped. This matches the built-in runner's behavior.
        if (test_log_errs != 0) {
            fail += 1;
            log_errs += test_log_errs;
            if (verbose) {
                printStatus(.fail, idx, total, name, ns, "ErrorLogEmitted", plain);
                print("  {d} error log{s} emitted during test\n", .{ test_log_errs, if (test_log_errs != 1) "s" else "" });
            } else {
                dot(.fail, plain);
                print("\n", .{});
                printStatus(.fail, idx, total, name, ns, "ErrorLogEmitted", plain);
                print("  {d} error log{s} emitted during test\n", .{ test_log_errs, if (test_log_errs != 1) "s" else "" });
                print("\n", .{});
            }
            if (env.fail_fast) should_stop = true;
            // Still report leaks even when error logs caused the failure.
            if (leaked) {
                leak += 1;
                if (verbose) {
                    printStatus(.leak, idx, total, name, ns, null, plain);
                } else {
                    dot(.leak, plain);
                }
            }
            continue;
        }

        if (result) |_| {
            pass += 1;
            if (verbose) {
                printStatus(.pass, idx, total, name, ns, null, plain);
            } else {
                dot(.pass, plain);
            }
        } else |err| switch (err) {
            error.SkipZigTest => {
                skip += 1;
                if (verbose) {
                    printStatus(.skip, idx, total, name, ns, null, plain);
                } else {
                    dot(.skip, plain);
                }
            },
            else => {
                fail += 1;
                if (verbose) {
                    printStatus(.fail, idx, total, name, ns, @errorName(err), plain);
                    dumpTrace(trace);
                } else {
                    dot(.fail, plain);
                    print("\n", .{});
                    printStatus(.fail, idx, total, name, ns, @errorName(err), plain);
                    dumpTrace(trace);
                    print("\n", .{});
                }
                if (env.fail_fast) should_stop = true;
            },
        }

        if (leaked) {
            leak += 1;
            if (verbose) {
                printStatus(.leak, idx, total, name, ns, null, plain);
            } else {
                dot(.leak, plain);
            }
            if (env.fail_fast) should_stop = true;
        }
    }

    if (!verbose) print("\n", .{});

    const elapsed_ns: u64 = timer.read();
    const elapsed_ms = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;

    print("\nztest: {d} passed, {d} failed, {d} skipped", .{ pass, fail, skip });
    if (leak > 0) print(", {d} leaked", .{leak});
    if (log_errs > 0) print(", {d} error logs", .{log_errs});
    print(" (of {d} total) in {d:.0}ms", .{ total, elapsed_ms });
    print("\n", .{});

    if (fail == 0 and leak == 0) {
        print("ALL TESTS PASSED\n", .{});
    } else {
        print("TESTS FAILED\n", .{});
    }

    if (fail != 0 or leak != 0 or log_errs != 0) {
        hardExit(1);
    }
}

// ── Output ──────────────────────────────────────────────────────────────────

/// Check whether stderr is a TTY. Uses libc isatty(2) — 0.16 has no non-Io
/// std API for it, and the runner links libc.
fn isStderrTty() bool {
    return std.c.isatty(2) != 0;
}

const Status = enum { pass, fail, skip, leak };

fn print(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt, args);
}

fn dot(status: Status, plain: bool) void {
    const ch: u8 = switch (status) {
        .pass => '.',
        .fail => 'F',
        .skip => 'S',
        .leak => 'L',
    };
    if (plain) {
        print("{c}", .{ch});
    } else {
        const color = switch (status) {
            .pass => "\x1b[32m",
            .fail => "\x1b[31m",
            .skip => "\x1b[33m",
            .leak => "\x1b[31m",
        };
        print("{s}{c}\x1b[0m", .{ color, ch });
    }
}

fn printStatus(
    status: Status,
    idx: usize,
    total: usize,
    name: []const u8,
    ns: u64,
    err_name: ?[]const u8,
    plain: bool,
) void {
    const label = switch (status) {
        .pass => "PASS",
        .fail => "FAIL",
        .skip => "SKIP",
        .leak => "LEAK",
    };

    const ms = @as(f64, @floatFromInt(ns)) / 1_000_000.0;

    if (plain) {
        if (err_name) |e| {
            print("[{d}/{d}] {s}: {s} — error.{s} ({d:.2}ms)\n", .{ idx, total, label, name, e, ms });
        } else {
            print("[{d}/{d}] {s}: {s} ({d:.2}ms)\n", .{ idx, total, label, name, ms });
        }
    } else {
        const color = switch (status) {
            .pass => "\x1b[32m", // green
            .fail => "\x1b[31m", // red
            .skip => "\x1b[33m", // yellow
            .leak => "\x1b[31m", // red
        };
        if (err_name) |e| {
            print("[{d}/{d}] {s}{s}\x1b[0m: {s} — error.{s} ({d:.2}ms)\n", .{
                idx, total, color, label, name, e, ms,
            });
        } else {
            print("[{d}/{d}] {s}{s}\x1b[0m: {s} ({d:.2}ms)\n", .{ idx, total, color, label, name, ms });
        }
    }
}

// ── Test name formatting ────────────────────────────────────────────────────

/// Extract a human-friendly test name from the fully-qualified builtin name.
/// Named tests:   "myapp.parser.test.parseJson" -> "parseJson"
///                "myapp.parser.test.test_42"   -> "test_42"
/// Unnamed tests: "myapp.parser.test_0"         -> "myapp.parser.test_0" (keep full)
fn friendlyName(name: []const u8) []const u8 {
    // First, look for the ".test." separator used by named tests.
    // A named test "test_42" produces "module.test.test_42" which has ".test."
    // before the test name. An unnamed test produces "module.test_0" which
    // has ".test_" but NO ".test." — the segment is "test_0", not "test".
    var it = std.mem.splitScalar(u8, name, '.');
    while (it.next()) |segment| {
        if (std.mem.eql(u8, segment, "test")) {
            const rest = it.rest();
            return if (rest.len > 0) rest else name;
        }
    }

    // No ".test." segment found — this is an unnamed test (test_0, test_1, ...).
    // Keep the full qualified name since there's no meaningful short name.
    return name;
}

// ── Environment variables ───────────────────────────────────────────────────

const Env = struct {
    verbose: ?bool,
    plain: bool,
    fail_fast: bool,
    filter: ?[]const u8,

    fn init(allocator: std.mem.Allocator) Env {
        return .{
            .verbose = readEnvBool(allocator, "ZTEST_VERBOSE"),
            .plain = readEnvBoolDefault(allocator, "ZTEST_PLAIN", false),
            .fail_fast = readEnvBoolDefault(allocator, "ZTEST_FAIL_FAST", false),
            .filter = readEnv(allocator, "ZTEST_FILTER"),
        };
    }

    fn deinit(self: Env, allocator: std.mem.Allocator) void {
        if (self.filter) |f| allocator.free(f);
    }
};

fn readEnv(allocator: std.mem.Allocator, key: []const u8) ?[]const u8 {
    // Use libc getenv — in 0.16 there is no non-Io std API for this, and
    // the runner links libc. Returns a pointer to the env var value
    // (NUL-terminated) or null if not set.
    const key_z = allocator.dupeZ(u8, key) catch return null;
    defer allocator.free(key_z);
    const raw = std.c.getenv(key_z) orelse return null;
    const value = std.mem.sliceTo(raw, 0);
    return allocator.dupe(u8, value) catch null;
}

fn readEnvBool(allocator: std.mem.Allocator, key: []const u8) ?bool {
    const value = readEnv(allocator, key) orelse return null;
    defer allocator.free(value);
    if (std.ascii.eqlIgnoreCase(value, "1") or std.ascii.eqlIgnoreCase(value, "true"))
        return true;
    if (std.ascii.eqlIgnoreCase(value, "0") or std.ascii.eqlIgnoreCase(value, "false"))
        return false;
    return null;
}

fn readEnvBoolDefault(allocator: std.mem.Allocator, key: []const u8, default: bool) bool {
    return readEnvBool(allocator, key) orelse default;
}

// ── Fuzz support ───────────────────────────────────────────────────────────
//
// std.testing.fuzz is an inline function that calls @import("root").fuzz(),
// so the test runner (which is root in test mode) must export this function.
//
// When NOT in fuzz mode (normal `zig build test`), this just runs the provided
// corpus inputs as regular test calls — no server protocol needed.
//
// When IN fuzz mode (`zig build test --fuzz`), this needs libfuzzer symbols
// that are linked in a separate compilation unit. ztest does NOT support fuzz
// mode — use the default test runner for fuzzing by conditionally setting
// test_runner in build.zig only when not fuzzing.

/// Fuzzer extern symbols. These are only linked when builtin.fuzz is true.
/// We declare them here so the function compiles, but they're only called
/// in the `builtin.fuzz` branch which is never reached in simple mode.
extern fn fuzzer_init_corpus_elem(input_ptr: [*]const u8, input_len: usize) void;
extern fn fuzzer_start(testOne: *const fn ([*]const u8, usize) callconv(.c) void) void;

pub fn fuzz(
    context: anytype,
    comptime testOne: anytype,
    options: testing.FuzzInputOptions,
) anyerror!void {
    @disableInstrumentation();

    // When not in fuzz mode, just run the corpus directly. The main test
    // loop owns allocator teardown and leak detection — we don't touch the
    // allocator here, matching the default runner's non-fuzz behavior.
    if (!builtin.fuzz) {
        // testOne takes *testing.Smith. Smith.slice expects a 4-byte
        // little-endian length prefix followed by the data, so construct a
        // compatible buffer for each corpus entry.
        const max_smith_input = 65536;
        for (options.corpus) |input| {
            var buf: [max_smith_input + 4]u8 = undefined;
            const data_len = @min(input.len, max_smith_input);
            std.mem.writeInt(u32, buf[0..4], @intCast(data_len), .little);
            @memcpy(buf[4..][0..data_len], input[0..data_len]);
            var smith = testing.Smith{ .in = buf[0 .. 4 + data_len] };
            try testOne(context, &smith);
        }
        if (options.corpus.len == 0) {
            var smith = testing.Smith{ .in = &.{} };
            try testOne(context, &smith);
        }
        return;
    }

    // Fuzz mode requires the server protocol and libfuzzer. ztest uses
    // .mode = .simple which bypasses the server protocol, so fuzzing
    // is not supported here. Users should conditionally use the default
    // runner when fuzzing — see the README for the build.zig pattern.
    @panic("ztest: fuzz mode is not supported with .mode = .simple. Use the default test runner for --fuzz.");
}

// ── Aliases ─────────────────────────────────────────────────────────────────

const testing = std.testing;
