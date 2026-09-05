const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Self-test: use ztest's own runner to test itself.
    // The runner uses libc for env-var access and TTY detection (getenv,
    // isatty) because the std APIs for those changed between 0.15 and 0.16
    // and libc is the common denominator.
    const self_test_mod = b.createModule(.{
        .root_source_file = b.path("src/self_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    self_test_mod.link_libc = true;
    const self_tests = b.addTest(.{
        .root_module = self_test_mod,
        .test_runner = .{ .path = b.path("src/test_runner.zig"), .mode = .simple },
    });

    const run_tests = b.addRunArtifact(self_tests);
    run_tests.has_side_effects = true; // always run tests, don't cache

    const test_step = b.step("test", "Run ztest's own tests");
    test_step.dependOn(&run_tests.step);

    // Timer arithmetic tests. timer.zig is also imported by the test runner
    // itself, and a file can't be imported by both the runner and a test root
    // (they'd land in two modules of one compilation), so it gets its own
    // test target using the built-in runner.
    const timer_mod = b.createModule(.{
        .root_source_file = b.path("src/timer.zig"),
        .target = target,
        .optimize = optimize,
    });
    timer_mod.link_libc = true;
    const timer_tests = b.addTest(.{ .root_module = timer_mod });
    const run_timer_tests = b.addRunArtifact(timer_tests);
    test_step.dependOn(&run_timer_tests.step);

    // Example: demonstrates a consumer project using ztest as a dependency.
    const example_step = b.step("example", "Run the example test suite");
    const run_example = b.addSystemCommand(&.{ "zig", "build", "test" });
    run_example.setCwd(b.path("example"));
    example_step.dependOn(&run_example.step);
}
