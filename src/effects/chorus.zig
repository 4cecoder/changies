const std = @import("std");
const Allocator = std.mem.Allocator;

/// Chorus effect using multiple modulated delay lines for a rich, detuned sound.
///
/// The chorus effect creates the illusion of multiple voices by mixing the original
/// signal with several delayed copies, each with time-varying delay controlled by
/// low-frequency oscillators (LFOs). The LFOs are phase-offset to create stereo width.
pub const Chorus = struct {
    sample_rate: u32,
    allocator: Allocator,

    // Three independent delay buffers for three "voices"
    delay_buffers: [3][]f32,
    write_pos: usize,

    // LFO state - one phase per voice for independent modulation
    lfo_phase: [3]f32,
    lfo_rate: f32, // Hz (0.1-10 Hz typical)
    lfo_depth: f32, // 0.0-1.0 (modulation intensity)

    // Delay parameters
    base_delay_ms: f32, // Base delay time (~20-30ms typical)
    max_delay_ms: f32, // Maximum delay for buffer allocation

    // Mix and enable
    wet_dry: f32, // 0.0 = dry only, 1.0 = wet only
    enabled: bool,

    /// Initialize a new Chorus effect
    ///
    /// Parameters:
    ///   - allocator: Memory allocator for delay buffers
    ///   - sample_rate: Audio sample rate in Hz (e.g., 48000)
    ///
    /// Default settings:
    ///   - Rate: 0.5 Hz
    ///   - Depth: 0.5
    ///   - Base delay: 25ms
    ///   - Max delay: 50ms
    ///   - Wet/dry: 0.5
    ///   - Enabled: true
    pub fn init(allocator: Allocator, sample_rate: u32) !Chorus {
        const max_delay_ms: f32 = 50.0; // 50ms max delay
        const buffer_samples = @as(usize, @intFromFloat(max_delay_ms * @as(f32, @floatFromInt(sample_rate)) / 1000.0)) + 1;

        var chorus = Chorus{
            .sample_rate = sample_rate,
            .allocator = allocator,
            .delay_buffers = undefined,
            .write_pos = 0,
            .lfo_phase = [_]f32{ 0.0, 0.333, 0.667 }, // 0°, 120°, 240° phase offset
            .lfo_rate = 0.5, // 0.5 Hz default
            .lfo_depth = 0.5, // 50% depth
            .base_delay_ms = 25.0, // 25ms base delay
            .max_delay_ms = max_delay_ms,
            .wet_dry = 0.5, // 50% wet/dry mix
            .enabled = true,
        };

        // Allocate three delay buffers
        for (&chorus.delay_buffers) |*buffer| {
            buffer.* = try allocator.alloc(f32, buffer_samples);
            @memset(buffer.*, 0.0);
        }

        return chorus;
    }

    /// Free all allocated resources
    pub fn deinit(self: *Chorus) void {
        for (self.delay_buffers) |buffer| {
            self.allocator.free(buffer);
        }
    }

    /// Set LFO rate (modulation speed)
    ///
    /// Parameters:
    ///   - rate: LFO frequency in Hz (typical range: 0.1-10 Hz)
    ///           Lower values = slower, more subtle modulation
    ///           Higher values = faster, more vibrato-like
    pub fn setRate(self: *Chorus, rate: f32) void {
        self.lfo_rate = std.math.clamp(rate, 0.01, 20.0);
    }

    /// Set LFO depth (modulation intensity)
    ///
    /// Parameters:
    ///   - depth: Modulation amount from 0.0 to 1.0
    ///            0.0 = no modulation (static delay)
    ///            1.0 = maximum modulation depth (~10ms swing)
    pub fn setDepth(self: *Chorus, depth: f32) void {
        self.lfo_depth = std.math.clamp(depth, 0.0, 1.0);
    }

    /// Set wet/dry mix ratio
    ///
    /// Parameters:
    ///   - mix: Mix ratio from 0.0 to 1.0
    ///          0.0 = 100% dry (bypassed)
    ///          1.0 = 100% wet (chorus only)
    ///          0.5 = 50/50 mix (typical)
    pub fn setWetDry(self: *Chorus, mix: f32) void {
        self.wet_dry = std.math.clamp(mix, 0.0, 1.0);
    }

    /// Enable or disable the effect
    ///
    /// When disabled, input is passed through unchanged with zero latency.
    pub fn setEnabled(self: *Chorus, enabled: bool) void {
        self.enabled = enabled;
    }

    /// Process audio buffer with chorus effect
    ///
    /// Parameters:
    ///   - input: Input audio samples
    ///   - output: Output buffer (same length as input)
    ///
    /// The output buffer will contain the processed audio with chorus effect applied.
    /// If the effect is disabled, input is copied directly to output.
    pub fn process(self: *Chorus, input: []const f32, output: []f32) void {
        std.debug.assert(input.len == output.len);

        if (!self.enabled) {
            @memcpy(output, input);
            return;
        }

        for (input, 0..) |sample, i| {
            // Write input sample to all delay buffers
            for (&self.delay_buffers) |*buffer| {
                buffer.*[self.write_pos] = sample;
            }

            var chorus_sum: f32 = 0.0;

            // Read from each voice with different LFO modulation
            for (self.delay_buffers, 0..) |buffer, voice| {
                // Calculate LFO value (-1.0 to 1.0)
                const lfo: f32 = @sin(self.lfo_phase[voice] * 2.0 * std.math.pi);

                // Modulate delay time: base_delay ± (lfo * depth * 10ms)
                const delay_variation: f32 = lfo * self.lfo_depth * 10.0;
                const delay_ms: f32 = self.base_delay_ms + delay_variation;
                const delay_samples: f32 = delay_ms * @as(f32, @floatFromInt(self.sample_rate)) / 1000.0;

                // Read delayed sample with linear interpolation
                const delayed = self.readInterpolated(buffer, delay_samples);
                chorus_sum += delayed;

                // Advance LFO phase
                const phase_increment: f32 = self.lfo_rate / @as(f32, @floatFromInt(self.sample_rate));
                self.lfo_phase[voice] += phase_increment;
                if (self.lfo_phase[voice] >= 1.0) {
                    self.lfo_phase[voice] -= 1.0;
                }
            }

            // Average the three voices
            const chorus_output: f32 = chorus_sum / 3.0;

            // Mix dry and wet signals
            output[i] = sample * (1.0 - self.wet_dry) + chorus_output * self.wet_dry;

            // Advance write position
            self.write_pos = (self.write_pos + 1) % self.delay_buffers[0].len;
        }
    }

    /// Read from delay buffer with linear interpolation for fractional delays
    ///
    /// This method reads a sample from the delay buffer at a fractional position,
    /// using linear interpolation to smoothly blend between adjacent samples.
    /// This is crucial for the chorus effect to avoid zipper noise when the
    /// LFO modulates the delay time.
    ///
    /// Parameters:
    ///   - buffer: Delay buffer to read from
    ///   - delay_samples: Delay time in samples (can be fractional)
    ///
    /// Returns: Interpolated sample value
    fn readInterpolated(self: *Chorus, buffer: []const f32, delay_samples: f32) f32 {
        // Calculate read position (write_pos - delay)
        const read_pos_float: f32 = @as(f32, @floatFromInt(self.write_pos)) - delay_samples;

        // Wrap negative positions
        const read_pos_wrapped: f32 = if (read_pos_float < 0.0)
            read_pos_float + @as(f32, @floatFromInt(buffer.len))
        else
            read_pos_float;

        // Get integer and fractional parts
        const pos_floor: f32 = @floor(read_pos_wrapped);
        const pos_int: usize = @as(usize, @intFromFloat(pos_floor)) % buffer.len;
        const pos_next: usize = (pos_int + 1) % buffer.len;
        const frac: f32 = read_pos_wrapped - pos_floor;

        // Linear interpolation: y = y0 * (1 - frac) + y1 * frac
        return buffer[pos_int] * (1.0 - frac) + buffer[pos_next] * frac;
    }

    /// Get current parameter values (useful for UI/debugging)
    pub fn getParameters(self: *const Chorus) struct {
        rate: f32,
        depth: f32,
        wet_dry: f32,
        enabled: bool,
    } {
        return .{
            .rate = self.lfo_rate,
            .depth = self.lfo_depth,
            .wet_dry = self.wet_dry,
            .enabled = self.enabled,
        };
    }
};

// Unit tests
test "Chorus init and deinit" {
    const allocator = std.testing.allocator;
    var chorus = try Chorus.init(allocator, 48000);
    defer chorus.deinit();

    try std.testing.expectEqual(@as(u32, 48000), chorus.sample_rate);
    try std.testing.expect(chorus.enabled);
    try std.testing.expectApproxEqRel(@as(f32, 0.5), chorus.wet_dry, 0.01);
}

test "Chorus bypasses when disabled" {
    const allocator = std.testing.allocator;
    var chorus = try Chorus.init(allocator, 48000);
    defer chorus.deinit();

    chorus.setEnabled(false);

    const input = [_]f32{ 0.1, 0.2, 0.3, 0.4, 0.5 };
    var output: [5]f32 = undefined;

    chorus.process(&input, &output);

    for (input, output) |in, out| {
        try std.testing.expectEqual(in, out);
    }
}

test "Chorus processes audio when enabled" {
    const allocator = std.testing.allocator;
    var chorus = try Chorus.init(allocator, 48000);
    defer chorus.deinit();

    const input = [_]f32{0.5} ** 1024;
    var output: [1024]f32 = undefined;

    chorus.process(&input, &output);

    // Output should be different from input (chorus is processing)
    var differs = false;
    for (input, output) |in, out| {
        if (@abs(in - out) > 0.001) {
            differs = true;
            break;
        }
    }
    try std.testing.expect(differs);
}

test "Chorus parameter setters" {
    const allocator = std.testing.allocator;
    var chorus = try Chorus.init(allocator, 48000);
    defer chorus.deinit();

    chorus.setRate(2.0);
    chorus.setDepth(0.75);
    chorus.setWetDry(0.8);
    chorus.setEnabled(false);

    const params = chorus.getParameters();
    try std.testing.expectApproxEqRel(@as(f32, 2.0), params.rate, 0.01);
    try std.testing.expectApproxEqRel(@as(f32, 0.75), params.depth, 0.01);
    try std.testing.expectApproxEqRel(@as(f32, 0.8), params.wet_dry, 0.01);
    try std.testing.expect(!params.enabled);
}
