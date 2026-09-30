const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_step = b.step("test", "Run unit tests and runner checks");

    const unit_tests = b.addTest(.{
        .name = "unit-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test_runner.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);

    const fixtures = b.addTest(.{
        .name = "runner-fixtures",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/self_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .test_runner = .{ .path = b.path("src/test_runner.zig"), .mode = .simple },
    });

    addFixtureChecks(b, test_step, fixtures, optimize);

    const example = b.addTest(.{
        .name = "example-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("example/tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .test_runner = .{ .path = b.path("src/test_runner.zig"), .mode = .simple },
    });
    const example_step = b.step("example", "Check the example test suite");
    const panic_check = addRunnerCheck(b, example_step, example, 1);
    panic_check.expectStdErrMatch("PANIC in test \"panic demonstration\": intentional panic");
    if (optimize == .Debug or optimize == .ReleaseSafe) {
        panic_check.expectStdErrMatch("example/tests.zig");
    }
    test_step.dependOn(example_step);
}

fn addFixtureChecks(
    b: *std.Build,
    test_step: *std.Build.Step,
    fixtures: *std.Build.Step.Compile,
    optimize: std.builtin.OptimizeMode,
) void {
    // Expected failures must not hide new failures in the runner.
    const suite = addRunnerCheck(b, test_step, fixtures, 1);
    suite.addArg("--seed=0x1234");
    suite.setEnvironmentVariable("ZTEST_EXPECT_SEED", "0x1234");
    suite.expectStdErrMatch(if (optimize == .Debug or optimize == .ReleaseSafe)
        "8 passed, 2 failed, 1 skipped, 1 leaked, 1 error logs (of 11 total)"
    else
        "8 passed, 2 failed, 1 skipped, 1 error logs (of 11 total)");
    suite.expectStdErrMatch("(seed: 0x1234)\nTESTS FAILED\n");

    const filtered = addRunnerCheck(b, test_step, fixtures, 0);
    filtered.setEnvironmentVariable("ZTEST_FILTER", "fuzz");
    filtered.expectStdErrMatch("3 passed, 0 failed, 0 skipped (of 3 total)");

    const fail_fast = addRunnerCheck(b, test_step, fixtures, 1);
    fail_fast.setEnvironmentVariable("ZTEST_FAIL_FAST", "true");
    fail_fast.expectStdErrMatch("2 passed, 1 failed, 1 skipped (of 11 total)");

    const dots = addRunnerCheck(b, test_step, fixtures, 0);
    dots.setEnvironmentVariable("ZTEST_FILTER", "basic arithmetic");
    dots.setEnvironmentVariable("ZTEST_VERBOSE", "0");
    dots.expectStdErrMatch("\n.\n");

    const plain = addRunnerCheck(b, test_step, fixtures, 0);
    plain.setEnvironmentVariable("ZTEST_FILTER", "basic arithmetic");
    plain.setEnvironmentVariable("ZTEST_PLAIN", "1");
    plain.setEnvironmentVariable("ZTEST_VERBOSE", "0");
    plain.expectStdErrMatch("[1/1] PASS: basic arithmetic passes");

    const empty = addRunnerCheck(b, test_step, fixtures, 0);
    empty.setEnvironmentVariable("ZTEST_FILTER", "no matching test");
    empty.expectStdErrMatch("0 passed, 0 failed, 0 skipped (of 0 total)");
}

fn addRunnerCheck(
    b: *std.Build,
    parent: *std.Build.Step,
    tests: *std.Build.Step.Compile,
    exit_code: u8,
) *std.Build.Step.Run {
    const run = b.addRunArtifact(tests);
    run.has_side_effects = true;
    for ([_][]const u8{
        "ZTEST_VERBOSE",
        "ZTEST_PLAIN",
        "ZTEST_FAIL_FAST",
        "ZTEST_FILTER",
        "ZTEST_EXPECT_SEED",
    }) |key| run.removeEnvironmentVariable(key);
    run.expectExitCode(exit_code);
    run.expectStdOutEqual("");
    parent.dependOn(&run.step);
    return run;
}
