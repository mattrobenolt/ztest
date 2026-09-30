# ztest

A custom test runner for [Zig](https://ziglang.org/) that writes plain text to stderr instead of a TUI.

ztest requires Zig 0.16.

```
ztest: Running 42 tests...

[1/42] PASS: addition works (0.01ms)
[2/42] FAIL: intentional failure — error.TestUnexpectedResult (0.02ms)
  /path/to/tests.zig:19:5: 0x... in expect (test)
    try std.testing.expect(1 == 2);
    ^
[3/42] SKIP: skipped test (0.00ms)
[4/42] PASS: memory leak (0.03ms)
[4/42] LEAK: memory leak (0.03ms)

ztest: 40 passed, 1 failed, 1 skipped, 1 leaked (of 42 total) in 127ms (seed: 0x1234)
TESTS FAILED
```

[![Zig](https://img.shields.io/badge/Zig-0.16.0-f7a41d?logo=zig&logoColor=white)](https://ziglang.org/)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

## Why?

Zig's built-in test runner uses `std.Progress` for a TUI. Under `zig build test`, the build runner and test binary communicate through a binary protocol on stdin and stdout. Test output on stdout can [deadlock](https://github.com/ziglang/zig/issues/15091) that protocol.

ztest uses `.mode = .simple` to skip the protocol. Results go to stderr as plain text, with inline stack traces on failure.

## Usage

Fetch the current 0.16-native runner from the main branch:

```sh
zig fetch --save https://github.com/mattrobenolt/ztest/archive/refs/heads/main.tar.gz
```

Set the custom runner in `build.zig`:

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
run_tests.has_side_effects = true; // Always run tests.
run_tests.addArg(b.fmt("--seed=0x{x}", .{b.seed}));

const test_step = b.step("test", "Run tests");
test_step.dependOn(&run_tests.step);
```

Or with `zig test` directly:

```sh
zig test --test-runner src/test_runner.zig foo.zig
```

## Output

ztest checks whether stderr is a TTY and picks a format:

**TTY:** colored dots (`.` pass, `F` fail, `S` skip, `L` leak). `ZTEST_VERBOSE=1` selects one line per test with elapsed time.

**Non-TTY:** one line per test, no ANSI codes. Each line includes the status, test name, and elapsed time. Failures include error details and inline stack traces.

Elapsed time uses `std.Io.Clock.awake`, the monotonic clock.

## Environment variables

| Variable | Default | Effect |
|----------|---------|--------|
| `ZTEST_VERBOSE` | auto (on for non-TTY, off for TTY) | `1` = one line per test; `0` = dots |
| `ZTEST_PLAIN` | auto (off for TTY, on for non-TTY) | `1` = force non-TTY format: no ANSI, always verbose |
| `ZTEST_FAIL_FAST` | off | `1` = stop on first failure |
| `ZTEST_FILTER` | none | Only run tests whose fully-qualified name contains the substring |

## Features

Same as the built-in runner:

- Memory leak detection via `std.testing.allocator` in Debug and ReleaseSafe (per-test reset and check)
- `error.SkipZigTest` handling
- Error-return traces when error tracing is enabled (`@errorReturnTrace`)
- `std.log` error level counting (tests that emit `.err` logs fail, even if the test function returns success)
- `--seed=N` argument for `std.testing.random_seed` (printed in the summary for reproducibility)
- Exit code 0 = all passed, 1 = any failure or leak

## Panic handling

ztest prints the panic message and current test name, then calls `std.debug.dumpCurrentStackTrace`. If stack tracing is enabled, the trace includes source locations. Zig 0.16 bounds the stack walk, which fixes the [old infinite-loop bug](https://github.com/ziglang/zig/issues/18286).

A recursive-panic guard exits if the trace code itself panics. A panic exits with code 1.

## Fuzz testing

In normal test builds, `std.testing.fuzz()` passes each corpus input unchanged to `std.testing.Smith`. It also runs an empty-input smoke test, as the built-in runner does. The main test loop checks for leaks.

Actual fuzz mode needs the server protocol, which `.mode = .simple` bypasses.

Select the default runner for fuzz mode in the consumer's `build.zig`:

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
- `zig build test -Dfuzz --fuzz` uses the default runner for fuzz mode

ztest rejects fuzz builds at compile time with a diagnostic about the default runner.

## Development

Run the checks from the repository root:

```sh
zig build test
zig build example
```

`zig build test` runs unit tests against the actual runner helpers. Fixture checks cover the runner's output and exit codes.

The standalone example includes intentional failures and a panic. The root build checks those results, so both commands exit with code 0.

## License

MIT
