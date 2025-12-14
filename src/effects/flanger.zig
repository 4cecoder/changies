const std = @import("std");
const Allocator = std.mem.Allocator;

/// Flanger effect using a short modulated delay line with feedback.
///
/// The flanger creates a "jet plane" or "whooshing" sound by mixing the signal
/// with a very short delayed copy (1-10ms) that is modulated by an LFO.
/// Adding feedback creates resonant peaks that sweep through the frequency spectrum,
/// producing the characteristic flanging sound.
pub const Flanger = struct {
    sample_rate: u32,
    allocator: Allocator,

    // Single delay buffer (flanger uses shorter delay than chorus)
    delay_buffer: []f32,
    write_pos: usize,

    // LFO state
    lfo_phase: f32,
    lfo_rate: f32, // Hz (0.1-10 Hz typical)
    lfo_depth: f32, // 0.0-1.0 (modulation intensity)

    // Delay parameters
    base_delay_ms: f32, // Base delay time (~3-5ms typical)
    max_delay_ms: f32, // Maximum delay for buffer allocation

    // Feedback and mix
    feedback: f32, // 0.0-0.95 (feedback amount, creates resonance)
    wet_dry: f32, // 0.0-1.0 (mix ratio)
    enabled: bool,

    // Feedback sample storage
    feedback_sample: f32,

    /// Initialize a new Flanger effect
    ///
    /// Parameters:
    ///   - allocator: Memory allocator for delay buffer
    ///   - sample_rate: Audio sample rate in Hz (e.g., 48000)
    ///
    /// Default settings:
    ///   - Rate: 0.3 Hz
    ///   - Depth: 0.7
    ///   - Base delay: 3ms
    ///   - Max delay: 10ms
    ///   - Feedback: 0.5
    ///   - Wet/dry: 0.5
    ///   - Enabled: true
    pub fn init(allocator: Allocator, sample_rate: u32) !Flanger {
        const max_delay_ms: f32 = 10.0; // 10ms max delay
        const buffer_samples = @as(usize, @intFromFloat(max_delay_ms * @as(f32, @floatFromInt(sample_rate)) / 1000.0)) + 1;

        const buffer = try allocator.alloc(f32, buffer_samples);
        @memset(buffer, 0.0);

        return Flanger{
            .sample_rate = sample_rate,
            .allocator = allocator,
            .delay_buffer = buffer,
            .write_pos = 0,
            .lfo_phase = 0.0,
            .lfo_rate = 0.3, // 0.3 Hz default (slower for classic flanger)
            .lfo_depth = 0.7, // 70% depth
            .base_delay_ms = 3.0, // 3ms base delay
            .max_delay_ms = max_delay_ms,
            .feedback = 0.5, // 50% feedback
            .wet_dry = 0.5, // 50% wet/dry mix
            .enabled = true,
            .feedback_sample = 0.0,
        };
    }

    /// Free all allocated resources
    pub fn deinit(self: *Flanger) void {
        self.allocator.free(self.delay_buffer);
    }

    /// Set LFO rate (modulation speed)
    ///
    /// Parameters:
    ///   - rate: LFO frequency in Hz (typical range: 0.1-10 Hz)
    ///           Lower values = slow, sweeping flange
    ///           Higher values = fast, tremolo-like effect
    pub fn setRate(self: *Flanger, rate: f32) void {
        self.lfo_rate = std.math.clamp(rate, 0.01, 20.0);
    }

    /// Set LFO depth (modulation intensity)
    ///
    /// Parameters:
    ///   - depth: Modulation amount from 0.0 to 1.0
    ///            0.0 = no modulation (static comb filter)
    ///            1.0 = maximum modulation depth (~5ms swing)
    pub fn setDepth(self: *Flanger, depth: f32) void {
        self.lfo_depth = std.math.clamp(depth, 0.0, 1.0);
    }

    /// Set feedback amount
    ///
    /// Parameters:
    ///   - feedback: Feedback gain from 0.0 to 0.95
    ///               0.0 = no feedback (mild flanging)
    ///               0.5 = moderate feedback (classic flanger)
    ///               0.95 = high feedback (metallic, resonant)
    ///
    /// WARNING: Values above 0.95 may cause instability!
    pub fn setFeedback(self: *Flanger, feedback: f32) void {
        self.feedback = std.math.clamp(feedback, 0.0, 0.95);
    }

    /// Set wet/dry mix ratio
    ///
    /// Parameters:
    ///   - mix: Mix ratio from 0.0 to 1.0
    ///          0.0 = 100% dry (bypassed)
    ///          1.0 = 100% wet (flanger only)
    ///          0.5 = 50/50 mix (typical)
    pub fn setWetDry(self: *Flanger, mix: f32) void {
        self.wet_dry = std.math.clamp(mix, 0.0, 1.0);
    }

    /// Enable or disable the effect
    ///
    /// When disabled, input is passed through unchanged with zero latency.
    pub fn setEnabled(self: *Flanger, enabled: bool) void {
        self.enabled = enabled;
        if (!enabled) {
            // Reset feedback when disabling to avoid pops
            self.feedback_sample = 0.0;
        }
    }

    /// Process audio buffer with flanger effect
    ///
    /// Parameters:
    ///   - input: Input audio samples
    ///   - output: Output buffer (same length as input)
    ///
    /// The output buffer will contain the processed audio with flanger effect applied.
    /// If the effect is disabled, input is copied directly to output.
    pub fn process(self: *Flanger, input: []const f32, output: []f32) void {
        std.debug.assert(input.len == output.len);

        if (!self.enabled) {
            @memcpy(output, input);
            return;
        }

        for (input, 0..) |sample, i| {
            // Mix input with feedback from previous iteration
            const input_with_feedback: f32 = sample + self.feedback_sample * self.feedback;

            // Write to delay buffer
            self.delay_buffer[self.write_pos] = input_with_feedback;

            // Calculate LFO value (-1.0 to 1.0)
            const lfo: f32 = @sin(self.lfo_phase * 2.0 * std.math.pi);

            // Modulate delay time: base_delay ± (lfo * depth * 5ms)
            const delay_variation: f32 = lfo * self.lfo_depth * 5.0;
            const delay_ms: f32 = self.base_delay_ms + delay_variation;
            const delay_samples: f32 = delay_ms * @as(f32, @floatFromInt(self.sample_rate)) / 1000.0;

            // Read delayed sample with linear interpolation
            const delayed = self.readInterpolated(delay_samples);

            // Store delayed sample for next feedback iteration
            self.feedback_sample = delayed;

            // Mix dry and wet signals
            output[i] = sample * (1.0 - self.wet_dry) + delayed * self.wet_dry;

            // Advance LFO phase
            const phase_increment: f32 = self.lfo_rate / @as(f32, @floatFromInt(self.sample_rate));
            self.lfo_phase += phase_increment;
            if (self.lfo_phase >= 1.0) {
                self.lfo_phase -= 1.0;
            }

            // Advance write position
            self.write_pos = (self.write_pos + 1) % self.delay_buffer.len;
        }
    }

    /// Read from delay buffer with linear interpolation for fractional delays
    ///
    /// This method reads a sample from the delay buffer at a fractional position,
    /// using linear interpolation to smoothly blend between adjacent samples.
    ///
    /// Parameters:
    ///   - delay_samples: Delay time in samples (can be fractional)
    ///
    /// Returns: Interpolated sample value
    fn readInterpolated(self: *const Flanger, delay_samples: f32) f32 {
        // Calculate read position (write_pos - delay)
        const read_pos_float: f32 = @as(f32, @floatFromInt(self.write_pos)) - delay_samples;

        // Wrap negative positions
        const read_pos_wrapped: f32 = if (read_pos_float < 0.0)
            read_pos_float + @as(f32, @floatFromInt(self.delay_buffer.len))
        else
            read_pos_float;

        // Get integer and fractional parts
        const pos_floor: f32 = @floor(read_pos_wrapped);
        const pos_int: usize = @as(usize, @intFromFloat(pos_floor)) % self.delay_buffer.len;
        const pos_next: usize = (pos_int + 1) % self.delay_buffer.len;
        const frac: f32 = read_pos_wrapped - pos_floor;

        // Linear interpolation: y = y0 * (1 - frac) + y1 * frac
        return self.delay_buffer[pos_int] * (1.0 - frac) + self.delay_buffer[pos_next] * frac;
    }

    /// Get current parameter values (useful for UI/debugging)
    pub fn getParameters(self: *const Flanger) struct {
        rate: f32,
        depth: f32,
        feedback: f32,
        wet_dry: f32,
        enabled: bool,
    } {
        return .{
            .rate = self.lfo_rate,
            .depth = self.lfo_depth,
            .feedback = self.feedback,
            .wet_dry = self.wet_dry,
            .enabled = self.enabled,
        };
    }
};

// Unit tests
test "Flanger init and deinit" {
    const allocator = std.testing.allocator;
    var flanger = try Flanger.init(allocator, 48000);
    defer flanger.deinit();

    try std.testing.expectEqual(@as(u32, 48000), flanger.sample_rate);
    try std.testing.expect(flanger.enabled);
    try std.testing.expectApproxEqRel(@as(f32, 0.5), flanger.wet_dry, 0.01);
    try std.testing.expectApproxEqRel(@as(f32, 0.5), flanger.feedback, 0.01);
}

test "Flanger bypasses when disabled" {
    const allocator = std.testing.allocator;
    var flanger = try Flanger.init(allocator, 48000);
    defer flanger.deinit();

    flanger.setEnabled(false);

    const input = [_]f32{ 0.1, 0.2, 0.3, 0.4, 0.5 };
    var output: [5]f32 = undefined;

    flanger.process(&input, &output);

    for (input, output) |in, out| {
        try std.testing.expectEqual(in, out);
    }
}

test "Flanger processes audio when enabled" {
    const allocator = std.testing.allocator;
    var flanger = try Flanger.init(allocator, 48000);
    defer flanger.deinit();

    const input = [_]f32{0.5} ** 1024;
    var output: [1024]f32 = undefined;

    flanger.process(&input, &output);

    // Output should be different from input (flanger is processing)
    var differs = false;
    for (input, output) |in, out| {
        if (@abs(in - out) > 0.001) {
            differs = true;
            break;
        }
    }
    try std.testing.expect(differs);
}

test "Flanger parameter setters" {
    const allocator = std.testing.allocator;
    var flanger = try Flanger.init(allocator, 48000);
    defer flanger.deinit();

    flanger.setRate(1.5);
    flanger.setDepth(0.8);
    flanger.setFeedback(0.7);
    flanger.setWetDry(0.6);
    flanger.setEnabled(false);

    const params = flanger.getParameters();
    try std.testing.expectApproxEqRel(@as(f32, 1.5), params.rate, 0.01);
    try std.testing.expectApproxEqRel(@as(f32, 0.8), params.depth, 0.01);
    try std.testing.expectApproxEqRel(@as(f32, 0.7), params.feedback, 0.01);
    try std.testing.expectApproxEqRel(@as(f32, 0.6), params.wet_dry, 0.01);
    try std.testing.expect(!params.enabled);
}

test "Flanger feedback stays stable" {
    const allocator = std.testing.allocator;
    var flanger = try Flanger.init(allocator, 48000);
    defer flanger.deinit();

    flanger.setFeedback(0.9); // High but safe feedback

    const input = [_]f32{0.1} ** 4800; // 100ms of audio
    var output: [4800]f32 = undefined;

    flanger.process(&input, &output);

    // Check that output doesn't explode
    for (output) |sample| {
        try std.testing.expect(@abs(sample) < 10.0); // Reasonable bound
    }
}
