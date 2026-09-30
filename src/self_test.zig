//! Runner fixtures include intentional failures, a skip, and a leak.
//! The build checks their output and exit status.

const std = @import("std");

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
    // Error logs must fail this test despite its successful return.
    std.log.err("something went wrong", .{});
    try std.testing.expect(true);
}

test "fuzz: simple corpus" {
    // Corpus execution does not require the server protocol.
    try std.testing.fuzz(.{}, fuzzCallback, .{
        .corpus = &.{
            "hello",
            "world",
            "",
        },
    });
}

fn fuzzCallback(_: @TypeOf(.{}), smith: *std.testing.Smith) anyerror!void {
    var buf: [256]u8 = undefined;
    _ = smith.slice(&buf);
}

test "fuzz corpus matches the standard runner" {
    var calls: u32 = 0;
    try std.testing.fuzz(&calls, fuzzCorpusCallback, .{ .corpus = &.{"hello"} });
    try std.testing.expectEqual(@as(u32, 2), calls);
}

fn fuzzCorpusCallback(calls: *u32, smith: *std.testing.Smith) anyerror!void {
    const expected: []const u8 = if (calls.* == 0) "hello" else "";
    try std.testing.expectEqualStrings(expected, smith.in.?);
    calls.* += 1;
}

test "fuzz without a corpus runs an empty smoke test" {
    var calls: u32 = 1;
    try std.testing.fuzz(&calls, fuzzCorpusCallback, .{});
    try std.testing.expectEqual(@as(u32, 2), calls);
}

test "testing.io and environ are initialized" {
    const allocator = std.testing.allocator;
    const path = try std.testing.environ.getAlloc(allocator, "PATH");
    defer allocator.free(path);
    try std.testing.expect(path.len > 0);
    const start = std.Io.Clock.Timestamp.now(std.testing.io, .awake);
    try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    try std.testing.expect(start.untilNow(std.testing.io).raw.nanoseconds > 0);
}

test "seed supplied by runner" {
    const allocator = std.testing.allocator;
    const expected = std.testing.environ.getAlloc(allocator, "ZTEST_EXPECT_SEED") catch |err| switch (err) {
        error.EnvironmentVariableMissing => return,
        else => return err,
    };
    defer allocator.free(expected);
    const seed = try std.fmt.parseUnsigned(u32, expected, 0);
    try std.testing.expectEqual(seed, std.testing.random_seed);
}
