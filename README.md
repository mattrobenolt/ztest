# ztest

A custom test runner for [Zig](https://ziglang.org/) that writes plain text to stderr instead of a TUI.

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

Zig's built-in test runner uses `std.Progress` for a TUI that doesn't make sense when piped. Under `zig build test`, the build runner and test binary talk over stdin/stdout with a binary protocol, so there's no readable output and writing to stdout in tests [deadlocks](https://github.com/ziglang/zig/issues/15091).

ztest uses `.mode = .simple` to skip the protocol. Results go straight to stderr as plain text: one line per test, stack traces inline on failure.

## Usage

```sh
zig fetch --save https://github.com/mattrobenolt/ztest/archive/refs/tags/v0.1.0.tar.gz
```

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

Or with `zig test` directly:

```sh
zig test --test-runner src/test_runner.zig foo.zig
```

## Output

ztest checks whether stderr is a TTY and picks a format:

**TTY:** colored dots (`.` pass, `F` fail, `S` skip, `L` leak). Set `ZTEST_VERBOSE=1` for one line per test with timing.

**Non-TTY:** one line per test, no ANSI codes. This is what agents and CI see. Each line has the status, test name, and error details. Stack traces print inline on failure. Timing is always shown.

## Environment variables

| Variable | Default | Effect |
|----------|---------|--------|
| `ZTEST_VERBOSE` | auto (on for non-TTY, off for TTY) | `1` = one line per test; `0` = dots |
| `ZTEST_PLAIN` | auto (off for TTY, on for non-TTY) | `1` = force non-TTY format: no ANSI, always verbose |
| `ZTEST_FAIL_FAST` | off | `1` = stop on first failure |
| `ZTEST_FILTER` | none | Only run tests whose fully-qualified name contains the substring |

## Features

Same as the built-in runner:

- Memory leak detection via `std.testing.allocator` (per-test reset and check)
- `error.SkipZigTest` handling
- Stack traces on failure (`@errorReturnTrace`)
- `std.log` error level counting (tests that emit `.err` logs fail, even if the test function returns success)
- `--seed=N` argument for `std.testing.random_seed` (printed in the summary for reproducibility)
- Exit code 0 = all passed, 1 = any failure or leak

## Panic handling

`std.debug.dumpCurrentStackTrace` can [loop forever at 100% CPU](https://github.com/ziglang/zig/issues/18286) on aarch64-linux in VMs when a test panics. The fix landed in Zig master but not 0.15.x.

ztest's panic handler walks the stack with a hard 64-frame limit instead of calling `std.debug.defaultPanic`. The panic message, test name, and a bounded stack trace still print to stderr. A recursive-panic guard prevents re-entry if the stack walk itself panics.

## Fuzz testing

`std.testing.fuzz()` works. In non-fuzz mode (normal `zig build test`), it runs the provided corpus inputs as regular test calls and the main test loop handles leak detection.

For actual fuzzing (`zig build test --fuzz`), the build system needs the server protocol, which `.mode = .simple` bypasses. Use a conditional runner in `build.zig`:

```zig
const ztest = b.dependency("ztest", .{});

const fuzz_mode = b.option(bool, "fuzz", "Enable fuzzing") orelse false;

const tests = b.addTest(.{
    .root_module = my_module,
    .test_runner = if (!fuzz_mode)
        .{ .path = ztest.path("src/test_runner.zig"), .mode = .simple }
    else
        null, // use the built-in runner for fuzz mode
});
```

- `zig build test` uses ztest
- `zig build test -Dfuzz` uses the default runner

If you run `--fuzz` without the conditional, ztest panics with a message pointing you to the default runner.

## License

MIT
