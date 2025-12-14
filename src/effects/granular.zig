const std = @import("std");
const Allocator = std.mem.Allocator;

/// Individual grain for granular synthesis
const Grain = struct {
    active: bool,
    read_pos: f32,
    playback_rate: f32,
    envelope_pos: f32,
    size_samples: usize,

    pub fn init() Grain {
        return .{
            .active = false,
            .read_pos = 0.0,
            .playback_rate = 1.0,
            .envelope_pos = 0.0,
            .size_samples = 0,
        };
    }

    /// Process one sample from the grain
    /// Returns the grain's output with envelope applied
    pub fn process(self: *Grain, buffer: []const f32) f32 {
        if (!self.active) return 0.0;

        const buffer_len: f32 = @floatFromInt(buffer.len);
        const size_samples_f: f32 = @floatFromInt(self.size_samples);

        // Read with linear interpolation
        const pos_wrapped: f32 = @mod(self.read_pos, buffer_len);
        const pos_int: usize = @intFromFloat(@floor(pos_wrapped));
        const pos_next: usize = @intCast(@mod(@as(i32, @intCast(pos_int)) + 1, @as(i32, @intCast(buffer.len))));
        const frac: f32 = pos_wrapped - @floor(pos_wrapped);

        const sample: f32 = buffer[pos_int] * (1.0 - frac) + buffer[pos_next] * frac;

        // Apply Hann window envelope
        const envelope: f32 = 0.5 * (1.0 - @cos(self.envelope_pos * 2.0 * std.math.pi));

        // Advance grain position
        self.read_pos += self.playback_rate;
        self.envelope_pos += 1.0 / size_samples_f;

        // Deactivate when envelope completes
        if (self.envelope_pos >= 1.0) {
            self.active = false;
        }

        return sample * envelope;
    }
};

/// Granular Synthesis effect - time/pitch manipulation through grain-based processing
///
/// Splits audio into small overlapping grains and manipulates their playback
/// to create time-stretching, pitch-shifting, and textural effects.
pub const Granular = struct {
    allocator: Allocator,
    sample_rate: u32,

    /// Circular buffer for storing recent audio
    buffer: []f32,
    write_pos: usize,
    buffer_size: usize,

    /// Pool of grains
    grains: [32]Grain,

    /// Time until next grain spawn (in samples)
    next_grain_time: f32,

    /// Grain size in milliseconds (10-200ms)
    grain_size_ms: f32,

    /// Grain density (grains per second)
    grain_density: f32,

    /// Grain playback pitch (0.5-2.0)
    grain_pitch: f32,

    /// Grain scatter/randomness (0.0-1.0)
    grain_scatter: f32,

    /// Wet/dry mix (0.0 = dry, 1.0 = wet)
    wet_dry: f32,

    /// Enable/disable the effect
    enabled: bool,

    /// Random number generator for scatter
    rng: std.Random.DefaultPrng,

    /// Initialize granular synthesis
    /// buffer_size_ms: size of the delay buffer in milliseconds
    pub fn init(allocator: Allocator, sample_rate: u32, buffer_size_ms: f32) !Granular {
        const buffer_size_samples: usize = @intFromFloat(@as(f32, @floatFromInt(sample_rate)) * buffer_size_ms / 1000.0);
        const buffer = try allocator.alloc(f32, buffer_size_samples);
        @memset(buffer, 0.0);

        var grains: [32]Grain = undefined;
        for (&grains) |*grain| {
            grain.* = Grain.init();
        }

        // Use a default seed (can be changed later if needed)
        const seed: u64 = 0x12345678;

        return .{
            .allocator = allocator,
            .sample_rate = sample_rate,
            .buffer = buffer,
            .write_pos = 0,
            .buffer_size = buffer_size_samples,
            .grains = grains,
            .next_grain_time = 0.0,
            .grain_size_ms = 50.0,
            .grain_density = 20.0,
            .grain_pitch = 1.0,
            .grain_scatter = 0.0,
            .wet_dry = 0.5,
            .enabled = false,
            .rng = std.Random.DefaultPrng.init(seed),
        };
    }

    /// Clean up allocated memory
    pub fn deinit(self: *Granular) void {
        self.allocator.free(self.buffer);
    }

    /// Set grain size in milliseconds (10-200ms)
    pub fn setGrainSize(self: *Granular, size_ms: f32) void {
        self.grain_size_ms = std.math.clamp(size_ms, 10.0, 200.0);
    }

    /// Set grain density (grains per second, 1-100)
    pub fn setGrainDensity(self: *Granular, density: f32) void {
        self.grain_density = std.math.clamp(density, 1.0, 100.0);
    }

    /// Set grain pitch (0.5-2.0)
    pub fn setGrainPitch(self: *Granular, pitch: f32) void {
        self.grain_pitch = std.math.clamp(pitch, 0.5, 2.0);
    }

    /// Set grain scatter/randomness (0.0-1.0)
    pub fn setGrainScatter(self: *Granular, scatter: f32) void {
        self.grain_scatter = std.math.clamp(scatter, 0.0, 1.0);
    }

    /// Set wet/dry mix (0.0-1.0)
    pub fn setWetDry(self: *Granular, mix: f32) void {
        self.wet_dry = std.math.clamp(mix, 0.0, 1.0);
    }

    /// Enable or disable the effect
    pub fn setEnabled(self: *Granular, enabled: bool) void {
        self.enabled = enabled;
    }

    /// Get current grain size
    pub fn getGrainSize(self: *const Granular) f32 {
        return self.grain_size_ms;
    }

    /// Get current grain density
    pub fn getGrainDensity(self: *const Granular) f32 {
        return self.grain_density;
    }

    /// Get current grain pitch
    pub fn getGrainPitch(self: *const Granular) f32 {
        return self.grain_pitch;
    }

    /// Get current grain scatter
    pub fn getGrainScatter(self: *const Granular) f32 {
        return self.grain_scatter;
    }

    /// Get current wet/dry mix
    pub fn getWetDry(self: *const Granular) f32 {
        return self.wet_dry;
    }

    /// Get enabled state
    pub fn isEnabled(self: *const Granular) bool {
        return self.enabled;
    }

    /// Reset the effect state
    pub fn reset(self: *Granular) void {
        @memset(self.buffer, 0.0);
        self.write_pos = 0;
        for (&self.grains) |*grain| {
            grain.active = false;
        }
        self.next_grain_time = 0.0;
    }

    /// Spawn a new grain
    fn spawnGrain(self: *Granular) void {
        // Find an inactive grain slot
        var grain_slot: ?*Grain = null;
        for (&self.grains) |*grain| {
            if (!grain.active) {
                grain_slot = grain;
                break;
            }
        }

        if (grain_slot == null) return; // No free slots

        const grain: *Grain = grain_slot.?;

        // Calculate grain size in samples
        const sample_rate_f: f32 = @floatFromInt(self.sample_rate);
        const grain_size_samples: usize = @intFromFloat(sample_rate_f * self.grain_size_ms / 1000.0);

        // Apply scatter to read position
        const scatter_range: f32 = self.grain_scatter * sample_rate_f * 0.1; // Up to 100ms scatter
        const scatter_offset: f32 = (self.rng.random().float(f32) - 0.5) * 2.0 * scatter_range;

        // Calculate read position (some time behind write position)
        const lookback_samples: f32 = sample_rate_f * self.grain_size_ms / 1000.0;
        const write_pos_f: f32 = @floatFromInt(self.write_pos);
        const buffer_size_f: f32 = @floatFromInt(self.buffer_size);
        var read_pos: f32 = write_pos_f - lookback_samples + scatter_offset;

        // Wrap to buffer size
        read_pos = @mod(read_pos, buffer_size_f);
        if (read_pos < 0) read_pos += buffer_size_f;

        // Apply scatter to pitch
        const pitch_scatter: f32 = (self.rng.random().float(f32) - 0.5) * 0.2 * self.grain_scatter;
        const playback_rate: f32 = self.grain_pitch + pitch_scatter;

        // Activate grain
        grain.* = .{
            .active = true,
            .read_pos = read_pos,
            .playback_rate = playback_rate,
            .envelope_pos = 0.0,
            .size_samples = grain_size_samples,
        };
    }

    /// Process audio buffer with granular synthesis
    pub fn process(self: *Granular, input: []const f32, output: []f32) void {
        std.debug.assert(input.len == output.len);

        if (!self.enabled) {
            @memcpy(output, input);
            return;
        }

        const sample_rate_f: f32 = @floatFromInt(self.sample_rate);
        const samples_per_grain: f32 = sample_rate_f / self.grain_density;

        for (input, 0..) |sample, i| {
            // Write input to circular buffer
            self.buffer[self.write_pos] = sample;
            self.write_pos = (self.write_pos + 1) % self.buffer_size;

            // Check if it's time to spawn a new grain
            self.next_grain_time -= 1.0;
            if (self.next_grain_time <= 0.0) {
                self.spawnGrain();
                self.next_grain_time += samples_per_grain;
            }

            // Sum output from all active grains
            var granular_output: f32 = 0.0;
            var active_count: f32 = 0.0;

            for (&self.grains) |*grain| {
                if (grain.active) {
                    granular_output += grain.process(self.buffer);
                    active_count += 1.0;
                }
            }

            // Normalize by active grain count to prevent clipping
            if (active_count > 0.0) {
                granular_output /= @sqrt(active_count);
            }

            // Mix wet and dry signals
            output[i] = sample * (1.0 - self.wet_dry) + granular_output * self.wet_dry;
        }
    }

    /// Process audio buffer in place
    pub fn processInPlace(self: *Granular, buffer: []f32) void {
        if (!self.enabled) {
            return;
        }

        const sample_rate_f: f32 = @floatFromInt(self.sample_rate);
        const samples_per_grain: f32 = sample_rate_f / self.grain_density;

        for (buffer) |*sample| {
            const original: f32 = sample.*;

            // Write to delay buffer
            self.buffer[self.write_pos] = original;
            self.write_pos = (self.write_pos + 1) % self.buffer_size;

            // Spawn grains
            self.next_grain_time -= 1.0;
            if (self.next_grain_time <= 0.0) {
                self.spawnGrain();
                self.next_grain_time += samples_per_grain;
            }

            // Process grains
            var granular_output: f32 = 0.0;
            var active_count: f32 = 0.0;

            for (&self.grains) |*grain| {
                if (grain.active) {
                    granular_output += grain.process(self.buffer);
                    active_count += 1.0;
                }
            }

            if (active_count > 0.0) {
                granular_output /= @sqrt(active_count);
            }

            // Mix
            sample.* = original * (1.0 - self.wet_dry) + granular_output * self.wet_dry;
        }
    }
};

// Tests
test "Granular initialization" {
    const allocator = std.testing.allocator;
    var gran = try Granular.init(allocator, 48000, 500.0);
    defer gran.deinit();

    try std.testing.expectEqual(@as(f32, 50.0), gran.grain_size_ms);
    try std.testing.expectEqual(@as(f32, 20.0), gran.grain_density);
    try std.testing.expectEqual(@as(f32, 1.0), gran.grain_pitch);
    try std.testing.expectEqual(@as(f32, 0.0), gran.grain_scatter);
    try std.testing.expectEqual(false, gran.enabled);
}

test "Granular parameter setters" {
    const allocator = std.testing.allocator;
    var gran = try Granular.init(allocator, 48000, 500.0);
    defer gran.deinit();

    gran.setGrainSize(100.0);
    try std.testing.expectEqual(@as(f32, 100.0), gran.grain_size_ms);

    gran.setGrainDensity(30.0);
    try std.testing.expectEqual(@as(f32, 30.0), gran.grain_density);

    gran.setGrainPitch(1.5);
    try std.testing.expectEqual(@as(f32, 1.5), gran.grain_pitch);

    gran.setGrainScatter(0.5);
    try std.testing.expectEqual(@as(f32, 0.5), gran.grain_scatter);

    gran.setWetDry(0.75);
    try std.testing.expectEqual(@as(f32, 0.75), gran.wet_dry);

    gran.setEnabled(true);
    try std.testing.expectEqual(true, gran.enabled);
}

test "Granular bypass when disabled" {
    const allocator = std.testing.allocator;
    var gran = try Granular.init(allocator, 48000, 500.0);
    defer gran.deinit();

    gran.setEnabled(false);

    const input = [_]f32{ 0.5, -0.5, 0.25, -0.25 };
    var output: [4]f32 = undefined;

    gran.process(&input, &output);

    for (input, output) |in_sample, out_sample| {
        try std.testing.expectEqual(in_sample, out_sample);
    }
}
