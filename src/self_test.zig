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

test "panic via @panic" {
    @panic("intentional panic for testing");
}

test "panic via debug.assert" {
    std.debug.assert(1 == 2);
}

test "panic via unreachable" {
    unreachable;
}

// ── Internal helpers (copied from test_runner.zig for testing) ──────────────

fn friendlyName(name: []const u8) []const u8 {
    const marker = ".test_";
    if (std.mem.indexOf(u8, name, marker)) |idx| {
        if (std.fmt.parseInt(u32, name[idx + marker.len ..], 10)) |_| {
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
