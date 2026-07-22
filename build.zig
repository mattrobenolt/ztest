const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Self-test: use ztest's own runner to test itself.
    const self_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/self_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .test_runner = .{ .path = b.path("src/test_runner.zig"), .mode = .simple },
    });

    const run_tests = b.addRunArtifact(self_tests);
    run_tests.has_side_effects = true; // always run tests, don't cache

    const test_step = b.step("test", "Run ztest's own tests");
    test_step.dependOn(&run_tests.step);

    // Example: demonstrates a consumer project using ztest as a dependency.
    const example_step = b.step("example", "Run the example test suite");
    const run_example = b.addSystemCommand(&.{ "zig", "build", "test" });
    run_example.setCwd(b.path("example"));
    example_step.dependOn(&run_example.step);
}
