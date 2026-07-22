# ztest

A custom test runner for [Zig](https://ziglang.org/) that produces clean, parseable output.

```
ztest: Running 42 tests...

[1/42] PASS: addition works
[2/42] FAIL: intentional failure — error.TestUnexpectedResult
  /path/to/tests.zig:19:5: 0x... in expect (test)
    try std.testing.expect(1 == 2);
    ^
[3/42] SKIP: skipped test
[4/42] LEAK: memory leak

ztest: 39 passed, 1 failed, 1 skipped, 1 leaked (of 42 total) in 127ms
TESTS FAILED
```

[![Zig](https://img.shields.io/badge/Zig-0.15.2-f7a41d?logo=zig&logoColor=white)](https://ziglang.org/)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

## Why?

Zig's built-in test runner uses a TUI progress display (`std.Progress`) that is
hostile to non-interactive consumers — AI agents, CI pipelines, log collectors.
When piped, it produces inconsistent output. When run through `zig build test`,
it communicates with the build runner over stdin/stdout using a binary protocol,
which means there's no readable test output and writing to stdout in tests
[deadlocks](https://github.com/ziglang/zig/issues/15091).

`ztest` replaces the built-in runner with one that simply writes results to
stderr as plain text. One line per test. Stack traces inline on failure. No TUI,
no binary protocol, no deadlocks.

## Usage

Add ztest to your `build.zig.zon`:

```sh
zig fetch --save https://github.com/mattrobenolt/ztest/archive/refs/tags/v0.1.0.tar.gz
```

Then set it as your test runner in `build.zig`:

```zig
const ztest = b.dependency("ztest", .{});

const tests = b.addTest(.{
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    }),
    .test_runner = .{ .path = ztest.path("src/test_runner.zig"), .mode = .simple },
});

const run_tests = b.addRunArtifact(tests);
run_tests.has_side_effects = true; // always run tests, don't cache

const test_step = b.step("test", "Run tests");
test_step.dependOn(&run_tests.step);
```

Or with `zig test` directly (no build system):

```sh
zig test --test-runner src/test_runner.zig foo.zig
```

That's it. `zig build test` now uses ztest instead of the built-in runner.

## Behavior

ztest detects whether stderr is a TTY and adjusts output accordingly:

**TTY (human at a terminal):** Colored dots by default — `.` for pass, `F` for
fail, `S` for skip, `L` for leak. Use `ZTEST_VERBOSE=1` for one line per test
with timing.

**Non-TTY (agents, CI, piped):** One line per test, always. No ANSI codes.
This is the format that matters for agents — each test is a single parseable
line with its status, name, and error details. Stack traces are printed inline
on failure.

## Environment variables

| Variable | Default | Effect |
|----------|---------|--------|
| `ZTEST_VERBOSE` | auto (on for non-TTY, off for TTY) | `1` = one line per test; `0` = dots |
| `ZTEST_PLAIN` | auto (off for TTY, on for non-TTY) | `1` = force non-TTY format: no ANSI, always verbose |
| `ZTEST_FAIL_FAST` | off | `1` = stop on first failure |
| `ZTEST_FILTER` | none | Only run tests whose fully-qualified name contains the substring |

## What it preserves

- Memory leak detection via `std.testing.allocator` (per-test reset and check)
- `error.SkipZigTest` handling
- Stack traces on failure (`@errorReturnTrace`)
- `std.log` error level counting
- `--seed=N` argument for `std.testing.random_seed`
- Proper exit codes (0 = all passed, 1 = any failure or leak)
- Custom panic handler that identifies which test panicked

## What it drops

- `std.Progress` TUI (the whole point)
- The stdin/stdout server protocol (by using `.mode = .simple`)
- Fuzz testing support (this requires the server protocol; use the default
  runner if you need fuzzing)

## License

MIT
