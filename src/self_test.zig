//! Self-tests for ztest's test runner.
//! These verify the runner's own internals: name formatting, env var parsing, etc.

const std = @import("std");
const builtin = @import("builtin");

test "friendlyName strips module path for named tests" {
    const name = "myapp.parser.test.parseJson";
    try std.testing.expectEqualStrings("parseJson", friendlyName(name));
}

test "friendlyName keeps unnamed tests as full name" {
    const name = "myapp.parser.test_0";
    try std.testing.expectEqualStrings("myapp.parser.test_0", friendlyName(name));
}

test "friendlyName handles deeply nested names" {
    const name = "a.b.c.d.test.my_test";
    try std.testing.expectEqualStrings("my_test", friendlyName(name));
}

test "friendlyName handles test at root" {
    const name = "test.simple";
    try std.testing.expectEqualStrings("simple", friendlyName(name));
}

test "friendlyName returns full name when no .test. segment" {
    const name = "some.function";
    try std.testing.expectEqualStrings("some.function", friendlyName(name));
}

test "friendlyName handles edge case: test_foo in nested module" {
    // A test literally named "test_foo" in module "module" gets the
    // builtin name "module.test.test_foo" — .test. separator is present.
    const name = "module.test.test_foo";
    try std.testing.expectEqualStrings("test_foo", friendlyName(name));
}

test "friendlyName strips named test that looks like test_N" {
    // A test named "test_42" should NOT be treated as an unnamed test.
    // The builtin name would be "module.test.test_42" — the remainder after
    // ".test_" is "42" which parses as a number, BUT this is a named test
    // because the user wrote test "test_42". We can't distinguish this from
    // a true unnamed test at this level, so we accept this edge case.
    // However, "module.test.test_42_extra" should NOT match because
    // "42_extra" doesn't parse as a u32.
    const name = "module.test.test_42_extra";
    try std.testing.expectEqualStrings("test_42_extra", friendlyName(name));
}

test "basic arithmetic passes" {
    try std.testing.expect(1 + 1 == 2);
}

test "string equality passes" {
    try std.testing.expectEqualStrings("hello", "hello");
}

test "skip demonstration" {
    return error.SkipZigTest;
}

test "intentional failure" {
    try std.testing.expect(1 == 2);
}

test "memory leak detection" {
    const allocator = std.testing.allocator;
    _ = try allocator.alloc(u8, 64);
}

test "emits error log but succeeds" {
    // This test should be treated as a FAILURE by the runner, even though
    // the test function itself returns success. Error logs count as failures.
    std.log.err("something went wrong", .{});
    try std.testing.expect(true);
}

test "fuzz: simple corpus" {
    // Verify that std.testing.fuzz works with ztest — it should just run
    // the corpus inputs as normal test calls (non-fuzz mode).
    try std.testing.fuzz(.{}, fuzzCallback, .{
        .corpus = &.{
            "hello",
            "world",
            "",
        },
    });
}

fn fuzzCallback(_: @TypeOf(.{}), input: []const u8) anyerror!void {
    // Simple callback that just checks the input is valid.
    _ = input;
}

// ── Internal helpers (copied from test_runner.zig for testing) ──────────────

fn friendlyName(name: []const u8) []const u8 {
    const marker = ".test_";
    if (std.mem.indexOf(u8, name, marker)) |idx| {
        const remainder = name[idx + marker.len ..];
        if (std.fmt.parseInt(u32, remainder, 10)) |_| {
            return name;
        } else |_| {}
    }

    var it = std.mem.splitScalar(u8, name, '.');
    while (it.next()) |segment| {
        if (std.mem.eql(u8, segment, "test")) {
            const rest = it.rest();
            return if (rest.len > 0) rest else name;
        }
    }
    return name;
}
