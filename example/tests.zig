const std = @import("std");

test "addition" {
    try std.testing.expect(2 + 2 == 4);
}

test "string concatenation" {
    const result = "hello" ++ " world";
    try std.testing.expectEqualStrings("hello world", result);
}

test "array sorting" {
    var arr = [_]u8{ 5, 2, 8, 1, 9, 3 };
    std.mem.sort(u8, &arr, {}, std.sort.asc(u8));
    try std.testing.expectEqualSlices(u8, &arr, &[_]u8{ 1, 2, 3, 5, 8, 9 });
}

test "intentional failure" {
    try std.testing.expect(1 == 2);
}

test "skipped test" {
    return error.SkipZigTest;
}

test "memory leak" {
    const allocator = std.testing.allocator;
    _ = try allocator.alloc(u8, 100);
}
