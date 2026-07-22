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
var random_seed: u32 = 0;
var panicking: bool = false;

/// Maximum number of stack frames to attempt to resolve during a panic.
/// This prevents infinite loops in StackIterator on platforms where the
/// stack frame chain is circular (e.g. aarch64-linux in VMs).
/// See https://github.com/ziglang/zig/issues/18286
const max_panic_frames = 64;

/// Root-level log function. std.log calls @import("root").logFn, which defaults
/// to this. We count .err level messages so we can fail tests that emit error
/// logs even if the test function itself returns success — matching the
/// built-in runner's behavior.
pub const std_options: std.Options = .{
    .logFn = log,
};

pub fn log(
    comptime message_level: std.log.Level,
    comptime scope: @Type(.enum_literal),
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

pub const panic = std.debug.FullPanic(struct {
    pub fn panicFn(msg: []const u8, first_trace_addr: ?usize) noreturn {
        // Guard against recursive panic — if dumpBoundedStackTrace itself
        // panics (e.g. corrupt debug info), don't re-enter.
        if (panicking) {
            std.posix.exit(1);
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
        std.posix.exit(1);
    }
}.panicFn);

/// Walk the stack with a hard frame limit. Resolves source locations when
/// debug info is available, but never loops more than `max_panic_frames` times.
fn dumpBoundedStackTrace(start_addr: ?usize) void {
    if (builtin.strip_debug_info) {
        print("  (debug info stripped, no stack trace available)\n", .{});
        return;
    }

    const debug_info = std.debug.getSelfDebugInfo() catch |err| {
        print("  (unable to open debug info: {s})\n", .{@errorName(err)});
        return;
    };

    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buf);

    var it = std.debug.StackIterator.init(start_addr, null);
    defer it.deinit();

    var frame: usize = 0;
    while (frame < max_panic_frames) : (frame += 1) {
        const return_address = it.next() orelse break;

        // On arm64 macOS, the address of the last frame is 0x0 rather than
        // 0x1 as on x86_64, so use saturating subtraction to avoid overflow.
        const address = return_address -| 1;

        // Try to resolve source location. If this fails, print the raw address.
        std.debug.printSourceAtAddress(debug_info, &stderr_writer.interface, address, .no_color) catch {
            print("  #{d}: 0x{x}\n", .{ frame, return_address });
        };
        stderr_writer.interface.flush() catch {};
    }

    if (frame == max_panic_frames) {
        print("  ... (stopped after {d} frames to prevent infinite loop)\n", .{max_panic_frames});
    }
}

pub fn main() !void {
    var mem: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&mem);
    const allocator = fba.allocator();

    // Parse --seed=N argument (passed by zig test / zig build test).
    var args = std.process.args();
    _ = args.skip();
    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--seed=")) {
            random_seed = std.fmt.parseUnsigned(u32, arg["--seed=".len..], 0) catch
                @panic("unable to parse --seed command line argument");
            testing.random_seed = random_seed;
        }
        // Ignore other args (--listen, --cache-dir, etc.) — not relevant in simple mode.
    }

    if (builtin.test_functions.len == 0) {
        print("no tests found\n", .{});
        return;
    }

    const env = Env.init(allocator);
    defer env.deinit(allocator);

    const have_tty = stderr.isTty();
    const plain = env.plain or !have_tty;
    const verbose = env.verbose orelse plain;

    // Pre-count matching tests if a filter is active, so indices and totals
    // reflect only the tests that will actually run.
    const total = if (env.filter) |f| blk: {
        var count: usize = 0;
        for (builtin.test_functions) |t| {
            if (std.mem.indexOf(u8, t.name, f) != null) count += 1;
        }
        break :blk count;
    } else builtin.test_functions.len;

    const timer = std.time.Timer.start() catch null;

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
            if (std.mem.indexOf(u8, t.name, f) == null) continue;
        }

        run_idx += 1;

        current_test = name;
        testing.allocator_instance = .{};
        testing.log_level = .warn;
        log_err_count = 0;

        var test_timer = std.time.Timer.start() catch null;
        const result = t.func();

        current_test = null;
        // Capture log_err_count and error return trace BEFORE deinit — deinit
        // calls detectLeaks which logs leaks at .err level and can corrupt
        // the error return trace. @errorReturnTrace() returns null if the
        // last call didn't return an error.
        const test_log_errs = log_err_count;
        const trace = @errorReturnTrace();
        const leaked = testing.allocator_instance.deinit() == .leak;

        const ns = if (test_timer) |*tt| tt.read() else 0;
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
                    if (trace) |tr| {
                        std.debug.dumpStackTrace(tr.*);
                    }
                } else {
                    dot(.fail, plain);
                    print("\n", .{});
                    printStatus(.fail, idx, total, name, ns, @errorName(err), plain);
                    if (trace) |tr| {
                        std.debug.dumpStackTrace(tr.*);
                    }
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

    var timer_mut = timer;
    const elapsed_ns: u64 = if (timer_mut) |*t| t.read() else 0;
    const elapsed_ms = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;

    print("\nztest: {d} passed, {d} failed, {d} skipped", .{ pass, fail, skip });
    if (leak > 0) print(", {d} leaked", .{leak});
    if (log_errs > 0) print(", {d} error logs", .{log_errs});
    print(" (of {d} total) in {d:.0}ms", .{ total, elapsed_ms });
    if (random_seed != 0) print(" (seed: 0x{x})", .{random_seed});
    print("\n", .{});

    if (fail == 0 and leak == 0) {
        print("ALL TESTS PASSED\n", .{});
    } else {
        print("TESTS FAILED\n", .{});
    }

    if (fail != 0 or leak != 0 or log_errs != 0) {
        std.posix.exit(1);
    }
}

// ── Output ──────────────────────────────────────────────────────────────────

const stderr = std.fs.File.stderr();

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
    const v = std.process.getEnvVarOwned(allocator, key) catch |err| {
        if (err == error.EnvironmentVariableNotFound) return null;
        return null;
    };
    return v;
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
    comptime testOne: fn (context: @TypeOf(context), input: []const u8) anyerror!void,
    options: testing.FuzzInputOptions,
) anyerror!void {
    @disableInstrumentation();

    // When not in fuzz mode, just run the corpus directly. The main test
    // loop owns allocator teardown and leak detection — we don't touch the
    // allocator here, matching the default runner's non-fuzz behavior.
    if (!builtin.fuzz) {
        for (options.corpus) |input| {
            try testOne(context, input);
        }
        // Smoke test with empty input if no corpus was provided.
        if (options.corpus.len == 0) {
            try testOne(context, "");
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
