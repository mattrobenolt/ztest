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
const testing = std.testing;
const debug = std.debug;
const process = std.process;
const Io = std.Io;
const ascii = std.ascii;
const print = debug.print;
const builtin = @import("builtin");

var current_test: ?[]const u8 = null;
var log_err_count: usize = 0;
threadlocal var panicking: bool = false;

/// Error logs fail tests, as they do with the built-in runner.
pub const std_options: std.Options = .{
    .logFn = log,
};

pub fn log(
    comptime message_level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    @disableInstrumentation();
    if (@intFromEnum(message_level) <= @intFromEnum(std.log.Level.err)) {
        log_err_count +|= 1;
    }
    if (@intFromEnum(message_level) <= @intFromEnum(testing.log_level)) {
        print("[" ++ @tagName(scope) ++ "] (" ++ @tagName(message_level) ++ "): " ++ format ++ "\n", args);
    }
}

pub const panic = debug.FullPanic(struct {
    pub fn panicFn(msg: []const u8, first_trace_addr: ?usize) noreturn {
        // Exit if the stack trace code itself panics.
        if (panicking) {
            process.exit(1);
        }
        panicking = true;

        if (current_test) |ct| {
            print("PANIC in test \"{s}\": {s}\n", .{ ct, msg });
        } else {
            print("PANIC: {s}\n", .{msg});
        }

        debug.dumpCurrentStackTrace(.{
            .first_address = first_trace_addr orelse @returnAddress(),
            .allow_unsafe_unwind = true,
        });
        process.exit(1);
    }
}.panicFn);

/// Print an error return trace to stderr.
fn dumpTrace(trace: ?*std.builtin.StackTrace) void {
    if (trace) |tr| {
        debug.dumpErrorReturnTrace(tr);
    }
}

pub fn main(init: process.Init) u8 {
    @disableInstrumentation();
    if (builtin.fuzz) {
        @compileError("ztest: fuzz mode needs the default test runner. Disable ztest for --fuzz.");
    }
    const io = init.io;
    var args = init.minimal.args.iterateAllocator(init.gpa) catch |err|
        process.fatal("ztest: cannot read arguments: {t}", .{err});
    defer args.deinit();
    _ = args.skip();
    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--seed=")) {
            testing.random_seed = std.fmt.parseUnsigned(u32, arg["--seed=".len..], 0) catch
                process.fatal("ztest: invalid seed: {s}", .{arg});
        } else {
            process.fatal("ztest: unrecognized argument: {s}", .{arg});
        }
    }

    if (builtin.test_functions.len == 0) {
        print("no tests found\n", .{});
        return 0;
    }

    const env: Env = .init(init.environ_map);
    const have_tty = Io.File.stderr().isTty(io) catch unreachable;
    const plain = env.plain or !have_tty;
    const verbose = env.plain or (env.verbose orelse plain);

    // Pre-count matching tests if a filter is active, so indices and totals
    // reflect only the tests that will actually run.
    const total = if (env.filter) |f| blk: {
        var count: usize = 0;
        for (builtin.test_functions) |t| {
            if (std.mem.find(u8, t.name, f) != null) count += 1;
        }
        break :blk count;
    } else builtin.test_functions.len;

    const start: Io.Clock.Timestamp = .now(io, .awake);

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
        // Keep test I/O allocations separate from the runner's I/O allocations.
        testing.environ = init.minimal.environ;
        testing.io_instance = .init(testing.allocator, .{
            .argv0 = .init(init.minimal.args),
            .environ = init.minimal.environ,
        });
        testing.log_level = .warn;
        log_err_count = 0;

        const test_start: Io.Clock.Timestamp = .now(io, .awake);
        // Do not include errors from earlier tests in this test's trace.
        if (@errorReturnTrace()) |trace| trace.index = 0;
        const result = t.func();

        current_test = null;
        // Capture test diagnostics before teardown emits allocator diagnostics.
        const test_log_errs = log_err_count;
        const trace = @errorReturnTrace();
        testing.io_instance.deinit();
        const leaked = testing.allocator_instance.deinit() == .leak;

        const elapsed = test_start.untilNow(io).raw;
        const idx = run_idx;

        // Error logs count as a test failure, even if the test function returned
        // success or was skipped. This matches the built-in runner's behavior.
        if (test_log_errs != 0) {
            fail += 1;
            log_errs += test_log_errs;
            if (verbose) {
                printStatus(.fail, idx, total, name, elapsed, "ErrorLogEmitted", plain);
                print("  {d} error log{s} emitted during test\n", .{
                    test_log_errs, if (test_log_errs != 1) "s" else "",
                });
            } else {
                dot(.fail, plain);
                print("\n", .{});
                printStatus(.fail, idx, total, name, elapsed, "ErrorLogEmitted", plain);
                print("  {d} error log{s} emitted during test\n", .{
                    test_log_errs, if (test_log_errs != 1) "s" else "",
                });
                print("\n", .{});
            }
            if (env.fail_fast) should_stop = true;
            // Still report leaks even when error logs caused the failure.
            if (leaked) {
                leak += 1;
                if (verbose) {
                    printStatus(.leak, idx, total, name, elapsed, null, plain);
                } else {
                    dot(.leak, plain);
                }
            }
            continue;
        }

        if (result) |_| {
            pass += 1;
            if (verbose) {
                printStatus(.pass, idx, total, name, elapsed, null, plain);
            } else {
                dot(.pass, plain);
            }
        } else |err| switch (err) {
            error.SkipZigTest => {
                skip += 1;
                if (verbose) {
                    printStatus(.skip, idx, total, name, elapsed, null, plain);
                } else {
                    dot(.skip, plain);
                }
            },
            else => {
                fail += 1;
                if (verbose) {
                    printStatus(.fail, idx, total, name, elapsed, @errorName(err), plain);
                    dumpTrace(trace);
                } else {
                    dot(.fail, plain);
                    print("\n", .{});
                    printStatus(.fail, idx, total, name, elapsed, @errorName(err), plain);
                    dumpTrace(trace);
                    print("\n", .{});
                }
                if (env.fail_fast) should_stop = true;
            },
        }

        if (leaked) {
            leak += 1;
            if (verbose) {
                printStatus(.leak, idx, total, name, elapsed, null, plain);
            } else {
                dot(.leak, plain);
            }
            if (env.fail_fast) should_stop = true;
        }
    }

    if (!verbose) print("\n", .{});

    const elapsed = start.untilNow(io).raw;

    print("\nztest: {d} passed, {d} failed, {d} skipped", .{ pass, fail, skip });
    if (leak > 0) print(", {d} leaked", .{leak});
    if (log_errs > 0) print(", {d} error logs", .{log_errs});
    print(" (of {d} total) in {d}ms (seed: 0x{x})\n", .{
        total, elapsed.toMilliseconds(), testing.random_seed,
    });

    if (fail == 0 and leak == 0) {
        print("ALL TESTS PASSED\n", .{});
    } else {
        print("TESTS FAILED\n", .{});
    }

    return if (fail != 0 or leak != 0 or log_errs != 0) 1 else 0;
}

// -- Output ------------------------------------------------------------------

const Status = enum { pass, fail, skip, leak };

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
    elapsed: Io.Duration,
    err_name: ?[]const u8,
    plain: bool,
) void {
    const label = switch (status) {
        .pass => "PASS",
        .fail => "FAIL",
        .skip => "SKIP",
        .leak => "LEAK",
    };

    const ms = @as(f64, @floatFromInt(elapsed.nanoseconds)) / std.time.ns_per_ms;

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

// -- Test name formatting ----------------------------------------------------

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

// -- Environment variables ---------------------------------------------------

const Env = struct {
    verbose: ?bool,
    plain: bool,
    fail_fast: bool,
    filter: ?[]const u8,

    fn init(environ: *const process.Environ.Map) Env {
        return .{
            .verbose = readEnvBool(environ, "ZTEST_VERBOSE"),
            .plain = readEnvBool(environ, "ZTEST_PLAIN") orelse false,
            .fail_fast = readEnvBool(environ, "ZTEST_FAIL_FAST") orelse false,
            .filter = environ.get("ZTEST_FILTER"),
        };
    }
};

fn readEnvBool(environ: *const process.Environ.Map, key: []const u8) ?bool {
    const value = environ.get(key) orelse return null;
    if (ascii.eqlIgnoreCase(value, "1") or ascii.eqlIgnoreCase(value, "true"))
        return true;
    if (ascii.eqlIgnoreCase(value, "0") or ascii.eqlIgnoreCase(value, "false"))
        return false;
    return null;
}

// -- Fuzz support ------------------------------------------------------------
//
// std.testing.fuzz calls the root module's fuzz function.
// The main function rejects fuzz mode because it needs the server protocol.

// std.testing.fuzz requires this parameter order.
pub fn fuzz(
    context: anytype,
    comptime testOne: fn (@TypeOf(context), *testing.Smith) anyerror!void, // ziglint-ignore: Z023
    options: testing.FuzzInputOptions,
) anyerror!void {
    @disableInstrumentation();

    // Match the standard runner: preserve corpus bytes and add an empty smoke test.
    for (options.corpus) |input| {
        var smith: testing.Smith = .{ .in = input };
        try testOne(context, &smith);
    }
    var smith: testing.Smith = .{ .in = "" };
    try testOne(context, &smith);
}

// -- Self-tests --------------------------------------------------------------

test "friendlyName strips module path for named tests" {
    const name = "myapp.parser.test.parseJson";
    try testing.expectEqualStrings("parseJson", friendlyName(name));
}

test "friendlyName keeps unnamed tests as full name" {
    const name = "myapp.parser.test_0";
    try testing.expectEqualStrings("myapp.parser.test_0", friendlyName(name));
}

test "friendlyName handles deeply nested names" {
    const name = "a.b.c.d.test.my_test";
    try testing.expectEqualStrings("my_test", friendlyName(name));
}

test "friendlyName handles test at root" {
    const name = "test.simple";
    try testing.expectEqualStrings("simple", friendlyName(name));
}

test "friendlyName returns full name when no .test. segment" {
    const name = "some.function";
    try testing.expectEqualStrings("some.function", friendlyName(name));
}

test "friendlyName handles edge case: test_foo in nested module" {
    // A test literally named "test_foo" in module "module" gets the
    // builtin name "module.test.test_foo" — .test. separator is present.
    const name = "module.test.test_foo";
    try testing.expectEqualStrings("test_foo", friendlyName(name));
}

test "friendlyName strips named test that looks like test_N" {
    // A named test retains the .test. separator even if its name resembles an unnamed test.
    const name = "module.test.test_42";
    try testing.expectEqualStrings("test_42", friendlyName(name));
}

test "environment defaults preserve automatic output selection" {
    var environ: process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();
    const env: Env = .init(&environ);
    try testing.expectEqual(@as(?bool, null), env.verbose);
    try testing.expect(!env.plain);
    try testing.expect(!env.fail_fast);
    try testing.expectEqual(@as(?[]const u8, null), env.filter);
}

test "environment booleans accept numeric and case-insensitive values" {
    var environ: process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();
    for ([_][]const u8{ "1", "true", "TRUE", "TrUe" }) |value| {
        try environ.put("ZTEST_VERBOSE", value);
        try testing.expectEqual(@as(?bool, true), readEnvBool(&environ, "ZTEST_VERBOSE"));
    }
    for ([_][]const u8{ "0", "false", "FALSE", "FaLsE" }) |value| {
        try environ.put("ZTEST_VERBOSE", value);
        try testing.expectEqual(@as(?bool, false), readEnvBool(&environ, "ZTEST_VERBOSE"));
    }
    try environ.put("ZTEST_VERBOSE", "invalid");
    try testing.expectEqual(@as(?bool, null), readEnvBool(&environ, "ZTEST_VERBOSE"));
}

test "environment values do not need a fixed allocation buffer" {
    var environ: process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();
    const filter: [8192]u8 = @splat('x');
    try environ.put("ZTEST_FILTER", &filter);
    try environ.put("ZTEST_PLAIN", "1");
    try environ.put("ZTEST_FAIL_FAST", "true");
    const env: Env = .init(&environ);
    try testing.expectEqualStrings(&filter, env.filter.?);
    try testing.expect(env.plain);
    try testing.expect(env.fail_fast);
}
