const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // In a real project, this would be:
    //   const ztest = b.dependency("ztest", .{});
    //   .test_runner = .{ .path = ztest.path("src/test_runner.zig"), .mode = .simple },
    // Here we reference the runner directly since the example lives inside the repo.
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .test_runner = .{ .path = b.path("../src/test_runner.zig"), .mode = .simple },
    });

    const run_tests = b.addRunArtifact(tests);
    run_tests.has_side_effects = true;

    const test_step = b.step("test", "Run example tests");
    test_step.dependOn(&run_tests.step);
}
