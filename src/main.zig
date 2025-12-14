const std = @import("std");
const c = @cImport({
    @cInclude("pulse/simple.h");
    @cInclude("pulse/error.h");
});
const virtual_device = @import("virtual_device.zig");
const web_server = @import("web_server.zig");

pub const ChangiesError = error{
    InitFailed,
    AudioError,
    AllocationFailed,
};

const VoiceEffect = enum {
    none,
    male,
    female,
    robot,
    alien,
    deep,
    high_pitch,
    custom,

    pub fn fromString(s: []const u8) ?VoiceEffect {
        const map = std.StaticStringMap(VoiceEffect).initComptime(.{
            .{ "none", .none },
            .{ "male", .male },
            .{ "female", .female },
            .{ "robot", .robot },
            .{ "alien", .alien },
            .{ "deep", .deep },
            .{ "high", .high_pitch },
            .{ "custom", .custom },
        });
        return map.get(s);
    }
};

const AudioConfig = struct {
    sample_rate: u32 = 48000,
    channels: u32 = 1,
    buffer_size: u32 = 1024,
    pitch_shift: f32 = 1.0,
    formant_shift: f32 = 1.0,
    effect: VoiceEffect = .none,
    enable_web: bool = true,
};

const NoiseGateState = struct {
    envelope: f32 = 0.0, // Current gate envelope (0.0 = closed, 1.0 = open)
    threshold: f32 = 0.01, // Linear threshold (-40dB)
    attack_coeff: f32, // Calculated from attack time
    release_coeff: f32, // Calculated from release time

    pub fn init(sample_rate: u32) NoiseGateState {
        // Attack: 5ms, Release: 150ms
        const attack_time_samples: f32 = @as(f32, @floatFromInt(sample_rate)) * 0.005;
        const release_time_samples: f32 = @as(f32, @floatFromInt(sample_rate)) * 0.150;

        return NoiseGateState{
            .attack_coeff = @exp(-1.0 / attack_time_samples),
            .release_coeff = @exp(-1.0 / release_time_samples),
        };
    }
};

const AudioContext = struct {
    config: AudioConfig,
    pa_input: ?*c.pa_simple,
    pa_output: ?*c.pa_simple,
    allocator: std.mem.Allocator,
    running: std.atomic.Value(bool),
    noise_gate_state: NoiseGateState,
    // Audio statistics (thread-safe atomic storage)
    input_rms: std.atomic.Value(f32),
    input_peak: std.atomic.Value(f32),
    output_rms: std.atomic.Value(f32),
    output_peak: std.atomic.Value(f32),
    web_srv: ?*web_server.WebServer,

    pub fn init(allocator: std.mem.Allocator, config: AudioConfig) !AudioContext {
        return AudioContext{
            .config = config,
            .pa_input = null,
            .pa_output = null,
            .allocator = allocator,
            .running = std.atomic.Value(bool).init(false),
            .noise_gate_state = NoiseGateState.init(config.sample_rate),
            .input_rms = std.atomic.Value(f32).init(0.0),
            .input_peak = std.atomic.Value(f32).init(0.0),
            .output_rms = std.atomic.Value(f32).init(0.0),
            .output_peak = std.atomic.Value(f32).init(0.0),
            .web_srv = null,
        };
    }

    pub fn deinit(self: *AudioContext) void {
        self.cleanup();
    }

    pub fn initAudio(self: *AudioContext, input_source: [:0]const u8, output_sink: [:0]const u8) !void {
        const ss = c.pa_sample_spec{
            .format = c.PA_SAMPLE_FLOAT32LE,
            .rate = self.config.sample_rate,
            .channels = @intCast(self.config.channels),
        };

        var error_code: c_int = 0;

        // Input stream
        self.pa_input = c.pa_simple_new(
            null, // Default server
            "changies",
            c.PA_STREAM_RECORD,
            input_source.ptr,
            "Voice input",
            &ss,
            null, // Default channel map
            null, // Default buffer attributes
            &error_code,
        );

        if (self.pa_input == null) {
            std.log.err("Failed to connect to PulseAudio input: {s}", .{c.pa_strerror(error_code)});
            return ChangiesError.AudioError;
        }

        // Output stream (to virtual device for Discord)
        self.pa_output = c.pa_simple_new(
            null,
            "changies",
            c.PA_STREAM_PLAYBACK,
            output_sink.ptr, // Virtual device sink
            "Voice output",
            &ss,
            null,
            null,
            &error_code,
        );

        if (self.pa_output == null) {
            self.cleanup();
            std.log.err("Failed to connect to PulseAudio output: {s}", .{c.pa_strerror(error_code)});
            return ChangiesError.AudioError;
        }

        std.log.info("Audio initialized: {d}Hz, {d} channels", .{ self.config.sample_rate, self.config.channels });
    }

    pub fn cleanup(self: *AudioContext) void {
        if (self.pa_input) |pa| {
            c.pa_simple_free(pa);
            self.pa_input = null;
        }
        if (self.pa_output) |pa| {
            c.pa_simple_free(pa);
            self.pa_output = null;
        }
    }

    pub fn updateInputStats(self: *AudioContext, buffer: []f32) void {
        const rms = calculateRms(buffer);
        const peak = calculatePeak(buffer);
        self.input_rms.store(rms, .monotonic);
        self.input_peak.store(peak, .monotonic);
    }

    pub fn updateOutputStats(self: *AudioContext, buffer: []f32) void {
        const rms = calculateRms(buffer);
        const peak = calculatePeak(buffer);
        self.output_rms.store(rms, .monotonic);
        self.output_peak.store(peak, .monotonic);
    }

    pub fn getStats(self: *AudioContext) web_server.AudioStats {
        return web_server.AudioStats{
            .input_rms = self.input_rms.load(.monotonic),
            .input_peak = self.input_peak.load(.monotonic),
            .output_rms = self.output_rms.load(.monotonic),
            .output_peak = self.output_peak.load(.monotonic),
            .gate_open = if (self.noise_gate_state.envelope > 0.5) 1 else 0,
            .processing_time_us = 0, // Will be calculated in audio thread
        };
    }

    pub fn setEffect(self: *AudioContext, effect: VoiceEffect) void {
        self.config.effect = effect;
        std.log.info("Effect changed to: {s}", .{@tagName(effect)});
    }

    pub fn setPitchShift(self: *AudioContext, pitch: f32) void {
        self.config.pitch_shift = pitch;
        std.log.info("Pitch shift changed to: {d:.2}", .{pitch});
    }

    pub fn setNoiseGateThreshold(self: *AudioContext, threshold: f32) void {
        self.noise_gate_state.threshold = threshold;
        std.log.info("Noise gate threshold changed to: {d:.4}", .{threshold});
    }
};

// Audio processing functions

fn calculateRms(buffer: []f32) f32 {
    var sum_squares: f32 = 0.0;
    for (buffer) |sample| {
        sum_squares += sample * sample;
    }
    return @sqrt(sum_squares / @as(f32, @floatFromInt(buffer.len)));
}

fn calculatePeak(buffer: []f32) f32 {
    var peak: f32 = 0.0;
    for (buffer) |sample| {
        const abs_sample: f32 = @abs(sample);
        if (abs_sample > peak) {
            peak = abs_sample;
        }
    }
    return peak;
}

// Hermite cubic interpolation for smoother pitch shifting
fn hermiteInterpolate(y0: f32, y1: f32, y2: f32, y3: f32, mu: f32) f32 {
    const mu2: f32 = mu * mu;
    const a0: f32 = -0.5 * y0 + 1.5 * y1 - 1.5 * y2 + 0.5 * y3;
    const a1: f32 = y0 - 2.5 * y1 + 2.0 * y2 - 0.5 * y3;
    const a2: f32 = -0.5 * y0 + 0.5 * y2;
    const a3: f32 = y1;

    return a0 * mu * mu2 + a1 * mu2 + a2 * mu + a3;
}

fn pitchShift(input: []f32, pitch_factor: f32, output: []f32) void {
    if (pitch_factor == 1.0) {
        @memcpy(output, input);
        return;
    }

    const phase_increment: f32 = pitch_factor;
    var phase: f32 = 1.0; // Start at 1 to have room for cubic interpolation

    for (output) |*out_sample| {
        const read_pos: usize = @intFromFloat(phase);
        const frac: f32 = phase - @as(f32, @floatFromInt(read_pos));

        // Cubic (Hermite) interpolation for much better quality
        if (read_pos >= 1 and read_pos + 2 < input.len) {
            out_sample.* = hermiteInterpolate(
                input[read_pos - 1],
                input[read_pos],
                input[read_pos + 1],
                input[read_pos + 2],
                frac,
            );
        } else if (read_pos + 1 < input.len) {
            // Fall back to linear interpolation at boundaries
            out_sample.* = input[read_pos] * (1.0 - frac) + input[read_pos + 1] * frac;
        } else if (read_pos < input.len) {
            out_sample.* = input[read_pos];
        } else {
            out_sample.* = 0.0;
        }

        phase += phase_increment;
        if (phase >= @as(f32, @floatFromInt(input.len - 2))) {
            phase = 1.0;
        }
    }
}

fn applyFormantFilter(buffer: []f32, formant_factor: f32) void {
    for (buffer) |*sample| {
        const low_freq: f32 = if (formant_factor > 1.0) 0.8 else 1.2;
        const mid_freq: f32 = if (formant_factor > 1.0) 1.1 else 0.9;
        const high_freq: f32 = if (formant_factor > 1.0) 1.3 else 0.7;
        sample.* *= (low_freq + mid_freq + high_freq) / 3.0;
    }
}

fn applyNoiseGate(buffer: []f32, state: *NoiseGateState) void {
    // Calculate RMS of buffer
    var sum_squares: f32 = 0.0;
    for (buffer) |sample| {
        sum_squares += sample * sample;
    }
    const rms: f32 = @sqrt(sum_squares / @as(f32, @floatFromInt(buffer.len)));

    // Determine target envelope (open or closed)
    const target_envelope: f32 = if (rms > state.threshold) 1.0 else 0.0;

    // Apply envelope follower with attack/release
    const coeff: f32 = if (target_envelope > state.envelope)
        state.attack_coeff
    else
        state.release_coeff;

    // Process each sample
    for (buffer) |*sample| {
        state.envelope = target_envelope + coeff * (state.envelope - target_envelope);
        sample.* *= state.envelope;
    }
}

fn applySoftLimiter(buffer: []f32) void {
    const threshold: f32 = 0.8;
    const makeup_gain: f32 = 1.1;

    for (buffer) |*sample| {
        // Apply makeup gain
        var s: f32 = sample.* * makeup_gain;

        // Soft knee compression above threshold
        const abs_s: f32 = @abs(s);
        if (abs_s > threshold) {
            const sign: f32 = if (s > 0.0) 1.0 else -1.0;
            const excess: f32 = abs_s - threshold;
            // Soft saturation curve
            s = sign * (threshold + excess / (1.0 + excess));
        }

        // Hard clip at ±1.0
        sample.* = @max(-1.0, @min(1.0, s));
    }
}

fn applyEffect(buffer: []f32, effect: VoiceEffect, config: AudioConfig, temp_buffer: []f32) void {
    switch (effect) {
        .none => {},
        .male => {
            applyFormantFilter(buffer, 0.8);
            pitchShift(buffer, 0.85, temp_buffer);
            @memcpy(buffer, temp_buffer);
        },
        .female => {
            applyFormantFilter(buffer, 1.3);
            pitchShift(buffer, 1.2, temp_buffer);
            @memcpy(buffer, temp_buffer);
        },
        .robot => {
            for (buffer) |*sample| {
                sample.* = @round(sample.* * 8.0) / 8.0;
                sample.* *= 1.2;
            }
        },
        .alien => {
            applyFormantFilter(buffer, 1.5);
            pitchShift(buffer, 1.4, temp_buffer);
            @memcpy(buffer, temp_buffer);
            // Add chorus effect
            for (buffer, 0..) |*sample, i| {
                if (i > 100) {
                    sample.* += buffer[i - 100] * 0.3;
                }
            }
        },
        .deep => {
            applyFormantFilter(buffer, 0.6);
            pitchShift(buffer, 0.7, temp_buffer);
            @memcpy(buffer, temp_buffer);
        },
        .high_pitch => {
            applyFormantFilter(buffer, 1.4);
            pitchShift(buffer, 1.6, temp_buffer);
            @memcpy(buffer, temp_buffer);
        },
        .custom => {
            pitchShift(buffer, config.pitch_shift, temp_buffer);
            @memcpy(buffer, temp_buffer);
            applyFormantFilter(buffer, config.formant_shift);
        },
    }
}

fn audioProcessingThread(ctx: *AudioContext) void {
    const buffer_size = ctx.config.buffer_size;
    const input_buffer = ctx.allocator.alloc(f32, buffer_size) catch {
        std.log.err("Failed to allocate input buffer", .{});
        return;
    };
    defer ctx.allocator.free(input_buffer);

    const output_buffer = ctx.allocator.alloc(f32, buffer_size) catch {
        std.log.err("Failed to allocate output buffer", .{});
        return;
    };
    defer ctx.allocator.free(output_buffer);

    const temp_buffer = ctx.allocator.alloc(f32, buffer_size) catch {
        std.log.err("Failed to allocate temp buffer", .{});
        return;
    };
    defer ctx.allocator.free(temp_buffer);

    std.log.info("Audio processing started with effect: {s}", .{@tagName(ctx.config.effect)});

    while (ctx.running.load(.monotonic)) {
        if (ctx.pa_input) |pa_in| {
            var error_code: c_int = 0;
            const bytes_to_read = buffer_size * @sizeOf(f32);

            const start_time = std.time.Instant.now() catch unreachable;

            if (c.pa_simple_read(pa_in, input_buffer.ptr, bytes_to_read, &error_code) < 0) {
                std.log.err("PulseAudio read error: {s}", .{c.pa_strerror(error_code)});
                std.posix.nanosleep(0, 10 * std.time.ns_per_ms);
                continue;
            }

            // Update input statistics
            ctx.updateInputStats(input_buffer);

            // Process audio
            @memcpy(output_buffer, input_buffer);

            // Audio processing chain for clean vocal output
            applyNoiseGate(output_buffer, &ctx.noise_gate_state); // Remove background noise

            if (ctx.config.effect != .none) {
                applyEffect(output_buffer, ctx.config.effect, ctx.config, temp_buffer);
            }

            applySoftLimiter(output_buffer); // Prevent clipping, ensure clean signal

            // Update output statistics
            ctx.updateOutputStats(output_buffer);

            // Calculate processing time
            const end_time = std.time.Instant.now() catch unreachable;
            const processing_time_us: u64 = @intCast(end_time.since(start_time) / 1000);

            // Update web server stats if enabled
            if (ctx.web_srv) |srv| {
                var stats = ctx.getStats();
                stats.processing_time_us = processing_time_us;
                srv.updateStats(stats);
            }

            // Write to output
            if (ctx.pa_output) |pa_out| {
                if (c.pa_simple_write(pa_out, output_buffer.ptr, bytes_to_read, &error_code) < 0) {
                    std.log.err("PulseAudio write error: {s}", .{c.pa_strerror(error_code)});
                    continue;
                }
            }
        }
    }

    std.log.info("Audio processing stopped", .{});
}

fn printHelp() void {
    std.debug.print(
        \\Changies - Professional Voice Changer
        \\
        \\Usage: changies [OPTIONS]
        \\
        \\Options:
        \\  -e, --effect <EFFECT>    Voice effect to apply
        \\                           [none, male, female, robot, alien, deep, high]
        \\  -p, --pitch <FACTOR>     Custom pitch shift factor (0.5-2.0)
        \\  -i, --input <DEVICE>     PulseAudio input device name
        \\  --no-web                 Disable web control interface
        \\  -h, --help               Show this help message
        \\
        \\Examples:
        \\  changies --effect male
        \\  changies --effect custom --pitch 1.5
        \\  changies --input alsa_input.usb-Device-02.mono-fallback
        \\  changies --no-web --effect female
        \\
        \\Web Interface:
        \\  By default, web interface runs on http://localhost:8080
        \\  Use --no-web to disable the web interface
        \\
    , .{});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var config = AudioConfig{};
    var input_device: [:0]const u8 = "default";

    // Parse arguments
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.skip(); // Skip program name

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            printHelp();
            return;
        } else if (std.mem.eql(u8, arg, "-e") or std.mem.eql(u8, arg, "--effect")) {
            const effect_str = args.next() orelse {
                std.log.err("Missing argument for --effect", .{});
                return error.InvalidArgument;
            };
            config.effect = VoiceEffect.fromString(effect_str) orelse {
                std.log.err("Invalid effect: {s}", .{effect_str});
                return error.InvalidArgument;
            };
        } else if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--pitch")) {
            const pitch_str = args.next() orelse {
                std.log.err("Missing argument for --pitch", .{});
                return error.InvalidArgument;
            };
            config.pitch_shift = try std.fmt.parseFloat(f32, pitch_str);
            config.effect = .custom;
        } else if (std.mem.eql(u8, arg, "-i") or std.mem.eql(u8, arg, "--input")) {
            input_device = args.next() orelse {
                std.log.err("Missing argument for --input", .{});
                return error.InvalidArgument;
            };
        } else if (std.mem.eql(u8, arg, "--no-web")) {
            config.enable_web = false;
        }
    }

    std.log.info("Starting Changies voice changer...", .{});
    std.log.info("Effect: {s}, Pitch: {d:.2}", .{ @tagName(config.effect), config.pitch_shift });

    // Create virtual audio device for Discord
    var vdev = try virtual_device.VirtualDevice.create();
    defer vdev.destroy();

    var ctx = try AudioContext.init(allocator, config);
    defer ctx.deinit();

    try ctx.initAudio(input_device, vdev.getSinkName());
    defer ctx.cleanup();

    // Start web server if enabled
    var web_srv: ?web_server.WebServer = null;
    var web_thread: ?std.Thread = null;

    if (config.enable_web) {
        const exe_dir = try std.fs.selfExeDirPathAlloc(allocator);
        defer allocator.free(exe_dir);

        const web_dir = try std.fmt.allocPrint(allocator, "{s}/../web", .{exe_dir});
        defer allocator.free(web_dir);

        web_srv = web_server.WebServer.init(allocator, 8080, web_dir);

        // Simple command handling through globals (thread-safe via atomics)
        ctx.web_srv = &web_srv.?;

        web_thread = try web_srv.?.start();
        std.log.info("Web interface available at http://localhost:8080", .{});
    }

    ctx.running.store(true, .monotonic);

    const audio_thread = try std.Thread.spawn(.{}, audioProcessingThread, .{&ctx});

    std.log.info("Voice changer running. Press Ctrl+C to stop...", .{});
    if (config.enable_web) {
        std.log.info("Open http://localhost:8080 in your browser to control", .{});
    }

    // Wait for Ctrl+C (sleep for a very long time)
    std.posix.nanosleep(std.math.maxInt(u63), 0);

    ctx.running.store(false, .monotonic);
    audio_thread.join();

    if (web_srv) |*srv| {
        srv.stop();
        if (web_thread) |thread| {
            thread.join();
        }
    }
}
