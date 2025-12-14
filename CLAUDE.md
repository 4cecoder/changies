# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Changies is a real-time voice changer CLI application written in Zig 0.16.0-dev, using PulseAudio for audio I/O. The application processes audio in real-time, applying pitch shifting and formant filtering to create various voice effects.

## Build Commands

```bash
# Build debug version
zig build

# Build optimized release
zig build -Doptimize=ReleaseFast

# Run the application (via build system)
zig build run

# Check compilation without producing artifacts
zig build check
```

**IMPORTANT:** Do NOT use `zig run src/main.zig` directly - it will fail because:
- The build system handles libc linking and PulseAudio library linking
- Use `zig build run` or run the compiled binary directly: `./zig-out/bin/changies`

## Running the Application

```bash
# Show help
./zig-out/bin/changies --help

# Apply an effect
./zig-out/bin/changies --effect male

# Custom pitch adjustment
./zig-out/bin/changies --pitch 1.5

# Specify PulseAudio input device
./zig-out/bin/changies --input alsa_input.usb-Device.mono-fallback --effect female
```

## Architecture

### Single-File Monolith
The entire application is in `src/main.zig` (~350 lines). This is intentional for simplicity. **If the file grows beyond 400 lines, refactor into modules** (`audio.zig`, `effects.zig`, `cli.zig`).

### Core Components

1. **AudioContext** - Manages PulseAudio connections (input/output streams), configuration, and thread-safe state
2. **VoiceEffect enum** - Defines available effects with `fromString()` for CLI parsing
3. **Audio Processing Functions** - Pure functions for DSP:
   - `pitchShift()` - Phase vocoder-style resampling
   - `applyFormantFilter()` - Simple 3-band EQ approximation
   - `applyEffect()` - Combines pitch/formant per effect type
4. **Processing Thread** - Runs `audioProcessingThread()` which reads from input, processes, writes to output

### Threading Model
- Main thread: CLI parsing, audio initialization, then sleeps
- Audio thread: Real-time processing loop with atomic `running` flag

## Zig 0.16.0-dev Specifics

**Critical API differences from stable Zig (0.11.0/0.13.0):**

### Type Casting
- **@ptrCast** takes ONE argument: `@ptrCast(ptr)` not `@ptrCast(Type, ptr)`
- Type is inferred from context or return type
- Example: `const widget: *GtkWidget = @ptrCast(button);`

### Standard Library Changes
- **Sleep function**: Use `std.posix.nanosleep(ns, 0)` not `std.time.sleep(ns)` or `std.Thread.sleep(ns)`
- `std.posix` namespace contains POSIX system calls
- `std.mem.copy()` is now `@memcpy()` builtin

### Build System (build.zig)
- **Module creation**: Use `b.createModule(.{ .root_source_file = b.path("..."), .target = target, .optimize = optimize })`
- Old `addExecutable()` required `.root_source_file` directly; now requires `.root_module`
- `b.path()` instead of `b.pathFromRoot()` or string literals
- System libraries: `exe.linkSystemLibrary("pulse-simple")` unchanged

### Type Inference Strictness
- **Explicit float types in runtime contexts**: Inside loops, use `const x: f32 = ...` not `const x = ...`
- Comptime-only types (like `comptime_float`) cannot depend on runtime control flow
- Error: "value with comptime-only type 'comptime_float' depends on runtime control flow"
- Solution: Add explicit type annotation `: f32` to force runtime type

### Error Handling
- `error` is a RESERVED KEYWORD - never use as variable name
- Use `pa_error`, `err`, `error_code` instead
- Custom error sets unchanged: `pub const MyError = error { Foo, Bar };`

### Atomics
- `std.atomic.Value(T)` API unchanged
- `.init()`, `.load()`, `.store()` work the same
- Memory ordering: `.monotonic`, `.seq_cst`, `.acquire`, `.release`

### C Interop
- `@cImport()` with block syntax: `@cImport({ @cInclude("header.h"); })`
- C pragma translation can fail with complex headers (like GTK)
- Workaround: Use minimal C APIs (PulseAudio simple API works)
- Must call `exe.linkLibC()` in build.zig before using C imports

## C Interop (PulseAudio)

**Keep C boundary minimal:**
- Only import PulseAudio headers: `pulse/simple.h`, `pulse/error.h`
- GTK/GUI is NOT used (caused C import translation failures)
- Wrap C calls immediately in Zig error handling
- Use `c.pa_strerror(error_code)` for error messages
- Never use `error` as a variable name (it's a Zig keyword)

## Audio Processing Rules

1. **No allocations in audio thread hot path** - All buffers pre-allocated in `audioProcessingThread()`
2. **Fixed buffer size** - Default 1024 samples at 48kHz (21ms latency)
3. **Error recovery** - On PulseAudio read/write errors, log and continue (don't crash)
4. **Effect algorithms are naive** - Pitch shifting uses linear interpolation, formant is simple gain. These can be improved but work for demo purposes.

## Development Workflow

### Adding a New Voice Effect

1. Add variant to `VoiceEffect` enum
2. Add mapping in `VoiceEffect.fromString()`
3. Add `switch` case in `applyEffect()`
4. Test with: `zig build && ./zig-out/bin/changies --effect neweffect`

### Modifying Audio Algorithms

- Changes to `pitchShift()` or `applyFormantFilter()` affect all effects
- Test with `--effect custom --pitch 1.0` first (no effect) to verify no artifacts
- Then test extreme values: `--pitch 0.5` and `--pitch 2.0`

## Code Patterns to Follow

### Error Handling
- Use custom `ChangiesError` set for domain errors
- Propagate with `try` or `catch` with recovery
- Log errors with `std.log.err()` before returning

### Memory Management
- Main allocator: `GeneralPurposeAllocator` for long-lived allocations
- All allocations paired with `defer allocator.free()`
- Audio buffers allocated once at thread start, freed at thread end

### Atomic Operations
- `AudioContext.running` is atomic for cross-thread communication
- Use `.monotonic` ordering for performance
- Never access from multiple writers

## Common Pitfalls

1. **Don't use GTK** - C import fails with Zig 0.16 pragma translation
2. **Don't use `error` as identifier** - Reserved keyword
3. **Type inference in loops** - Explicitly annotate float types
4. **PulseAudio device names** - Use `pactl list sources` to find valid input devices
5. **Thread cleanup** - Currently uses infinite sleep; proper signal handling needed for production

## Advanced Zig Patterns (Inspired by Modern Codebases)

### Module Organization (When Refactoring)
If refactoring beyond 400 lines, follow these patterns:

```zig
// audio.zig - Audio I/O abstraction
pub const Context = struct {
    allocator: Allocator,
    // ... fields

    pub fn init(allocator: Allocator) !Context { }
    pub fn deinit(self: *Context) void { }
};

// effects.zig - DSP algorithms
pub const Effect = enum { male, female, ... };
pub fn apply(buffer: []f32, effect: Effect) void { }

// main.zig - CLI and orchestration
const audio = @import("audio.zig");
const effects = @import("effects.zig");
```

### Configuration Patterns
For future config file support, follow Zig conventions:
- Use `std.json.parseFromSlice()` for JSON configs
- Struct with defaults: `const Config = struct { sample_rate: u32 = 48000, ... };`
- Validate after parse: separate `validate()` method

### Error Context
When wrapping C errors, provide context:
```zig
self.pa_input = c.pa_simple_new(...) orelse {
    std.log.err("Failed to connect to PulseAudio input: {s}", .{c.pa_strerror(error_code)});
    return error.AudioError; // NOT just `return error`
};
```

### Compile-Time Configuration
Use comptime for build-time decisions:
```zig
const buffer_size = if (@import("builtin").mode == .Debug) 512 else 1024;
const enable_logging = @import("builtin").mode == .Debug;
```

### Testing Patterns (Future)
When adding tests:
```zig
test "pitchShift preserves buffer length" {
    const allocator = std.testing.allocator;
    const input = try allocator.alloc(f32, 1024);
    defer allocator.free(input);
    // ... test logic
}
```

Run with: `zig build test`

## Common Zig 0.16+ Gotchas

1. **Import cycles**: If `a.zig` imports `b.zig` which imports `a.zig`, you'll get compile error. Use dependency injection or separate interface modules.

2. **Sentinel-terminated slices**: `[:0]const u8` for C strings, `[]const u8` for Zig strings. PulseAudio device names need `[:0]`.

3. **Allocator must be passed explicitly**: No global allocator. Always thread `allocator` parameter through.

4. **No implicit casts**: `u32` → `c_int` requires `@intCast()`. Be explicit.

5. **Defer execution order**: LIFO (last defer executes first). Group related cleanup together.

## Future Improvements (DO NOT implement without asking)

- Signal handling for graceful shutdown (SIGINT/SIGTERM) - use `std.posix.sigaction()`
- Proper FFT-based pitch shifting (current is phase-linear) - consider using C library via @cImport
- Virtual audio device creation (loopback) - would require PulseAudio module-loopback
- Configuration file support - use `std.json` or TOML parser
- TUI interface (avoid GTK) - consider libvaxis or similar Zig TUI library
