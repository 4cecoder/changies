const std = @import("std");
const Allocator = std.mem.Allocator;

/// Phaser effect using a cascade of allpass filters with LFO modulation.
///
/// The phaser creates a sweeping, "swirling" sound by passing the signal through
/// a series of allpass filters whose cutoff frequencies are modulated by an LFO.
/// When mixed with the dry signal, this creates notches in the frequency spectrum
/// that sweep up and down, producing the characteristic phasing effect.
pub const Phaser = struct {
    sample_rate: u32,
    allocator: Allocator,

    // Allpass filter cascade
    allpass_filters: []AllpassFilter,
    num_stages: usize, // 4-12 stages typical

    // LFO state
    lfo_phase: f32,
    lfo_rate: f32, // Hz (0.1-10 Hz typical)
    lfo_depth: f32, // 0.0-1.0 (modulation intensity)

    // Filter frequency range
    min_freq: f32, // Minimum filter frequency (Hz)
    max_freq: f32, // Maximum filter frequency (Hz)

    // Feedback and mix
    feedback: f32, // 0.0-0.95 (feedback amount, creates resonance)
    wet_dry: f32, // 0.0-1.0 (mix ratio)
    enabled: bool,

    // Feedback sample storage
    feedback_sample: f32,

    /// First-order allpass filter with variable cutoff frequency
    ///
    /// Transfer function: H(z) = (a1 + z^-1) / (1 + a1*z^-1)
    /// where a1 = (tan(π*f/fs) - 1) / (tan(π*f/fs) + 1)
    pub const AllpassFilter = struct {
        a1: f32, // Allpass coefficient
        x1: f32, // Previous input sample
        y1: f32, // Previous output sample

        pub fn init() AllpassFilter {
            return AllpassFilter{
                .a1 = 0.0,
                .x1 = 0.0,
                .y1 = 0.0,
            };
        }

        /// Process a single sample through the allpass filter
        pub fn process(self: *AllpassFilter, input: f32) f32 {
            const output: f32 = self.a1 * input + self.x1 - self.a1 * self.y1;
            self.x1 = input;
            self.y1 = output;
            return output;
        }

        /// Set the cutoff frequency of the allpass filter
        ///
        /// Parameters:
        ///   - freq: Cutoff frequency in Hz
        ///   - sample_rate: Audio sample rate in Hz
        pub fn setFrequency(self: *AllpassFilter, freq: f32, sample_rate: u32) void {
            const tan_val: f32 = @tan(std.math.pi * freq / @as(f32, @floatFromInt(sample_rate)));
            self.a1 = (tan_val - 1.0) / (tan_val + 1.0);
        }

        /// Reset filter state (clear delay line)
        pub fn reset(self: *AllpassFilter) void {
            self.x1 = 0.0;
            self.y1 = 0.0;
        }
    };

    /// Initialize a new Phaser effect
    ///
    /// Parameters:
    ///   - allocator: Memory allocator for filter array
    ///   - sample_rate: Audio sample rate in Hz (e.g., 48000)
    ///   - num_stages: Number of allpass filter stages (4-12, default 6)
    ///
    /// Default settings:
    ///   - Rate: 0.5 Hz
    ///   - Depth: 0.7
    ///   - Min frequency: 200 Hz
    ///   - Max frequency: 2000 Hz
    ///   - Feedback: 0.5
    ///   - Wet/dry: 0.5
    ///   - Enabled: true
    pub fn init(allocator: Allocator, sample_rate: u32, num_stages: usize) !Phaser {
        const clamped_stages = std.math.clamp(num_stages, 2, 16);

        const filters = try allocator.alloc(AllpassFilter, clamped_stages);
        for (filters) |*filter| {
            filter.* = AllpassFilter.init();
        }

        return Phaser{
            .sample_rate = sample_rate,
            .allocator = allocator,
            .allpass_filters = filters,
            .num_stages = clamped_stages,
            .lfo_phase = 0.0,
            .lfo_rate = 0.5, // 0.5 Hz default
            .lfo_depth = 0.7, // 70% depth
            .min_freq = 200.0, // 200 Hz minimum
            .max_freq = 2000.0, // 2000 Hz maximum
            .feedback = 0.5, // 50% feedback
            .wet_dry = 0.5, // 50% wet/dry mix
            .enabled = true,
            .feedback_sample = 0.0,
        };
    }

    /// Free all allocated resources
    pub fn deinit(self: *Phaser) void {
        self.allocator.free(self.allpass_filters);
    }

    /// Set LFO rate (modulation speed)
    ///
    /// Parameters:
    ///   - rate: LFO frequency in Hz (typical range: 0.1-10 Hz)
    ///           Lower values = slow, sweeping phaser
    ///           Higher values = fast, warbling effect
    pub fn setRate(self: *Phaser, rate: f32) void {
        self.lfo_rate = std.math.clamp(rate, 0.01, 20.0);
    }

    /// Set LFO depth (modulation intensity)
    ///
    /// Parameters:
    ///   - depth: Modulation amount from 0.0 to 1.0
    ///            0.0 = no modulation (static notch filter)
    ///            1.0 = full frequency range sweep
    pub fn setDepth(self: *Phaser, depth: f32) void {
        self.lfo_depth = std.math.clamp(depth, 0.0, 1.0);
    }

    /// Set feedback amount
    ///
    /// Parameters:
    ///   - feedback: Feedback gain from 0.0 to 0.95
    ///               0.0 = no feedback (subtle phasing)
    ///               0.5 = moderate feedback (classic phaser)
    ///               0.95 = high feedback (resonant, metallic)
    ///
    /// WARNING: Values above 0.95 may cause instability!
    pub fn setFeedback(self: *Phaser, feedback: f32) void {
        self.feedback = std.math.clamp(feedback, 0.0, 0.95);
    }

    /// Set wet/dry mix ratio
    ///
    /// Parameters:
    ///   - mix: Mix ratio from 0.0 to 1.0
    ///          0.0 = 100% dry (bypassed)
    ///          1.0 = 100% wet (phaser only)
    ///          0.5 = 50/50 mix (typical)
    pub fn setWetDry(self: *Phaser, mix: f32) void {
        self.wet_dry = std.math.clamp(mix, 0.0, 1.0);
    }

    /// Set the number of filter stages (requires reinitialization)
    ///
    /// This method is included for completeness but requires rebuilding
    /// the filter array. Prefer setting stages at initialization time.
    pub fn setStages(self: *Phaser, num_stages: usize) !void {
        const clamped_stages = std.math.clamp(num_stages, 2, 16);
        if (clamped_stages == self.num_stages) return;

        // Reallocate filter array
        self.allocator.free(self.allpass_filters);
        const filters = try self.allocator.alloc(AllpassFilter, clamped_stages);
        for (filters) |*filter| {
            filter.* = AllpassFilter.init();
        }
        self.allpass_filters = filters;
        self.num_stages = clamped_stages;
    }

    /// Set frequency range for the phaser sweep
    ///
    /// Parameters:
    ///   - min_freq: Minimum frequency in Hz (typical: 100-500 Hz)
    ///   - max_freq: Maximum frequency in Hz (typical: 1000-5000 Hz)
    pub fn setFrequencyRange(self: *Phaser, min_freq: f32, max_freq: f32) void {
        self.min_freq = std.math.clamp(min_freq, 50.0, 10000.0);
        self.max_freq = std.math.clamp(max_freq, self.min_freq, 10000.0);
    }

    /// Enable or disable the effect
    ///
    /// When disabled, input is passed through unchanged with zero latency.
    pub fn setEnabled(self: *Phaser, enabled: bool) void {
        self.enabled = enabled;
        if (!enabled) {
            // Reset all filter states and feedback
            for (self.allpass_filters) |*filter| {
                filter.reset();
            }
            self.feedback_sample = 0.0;
        }
    }

    /// Process audio buffer with phaser effect
    ///
    /// Parameters:
    ///   - input: Input audio samples
    ///   - output: Output buffer (same length as input)
    ///
    /// The output buffer will contain the processed audio with phaser effect applied.
    /// If the effect is disabled, input is copied directly to output.
    pub fn process(self: *Phaser, input: []const f32, output: []f32) void {
        std.debug.assert(input.len == output.len);

        if (!self.enabled) {
            @memcpy(output, input);
            return;
        }

        for (input, 0..) |sample, i| {
            // Calculate LFO value (0.0 to 1.0, using sine wave mapped to 0-1 range)
            const lfo_sine: f32 = @sin(self.lfo_phase * 2.0 * std.math.pi);
            const lfo: f32 = (lfo_sine + 1.0) * 0.5; // Map from [-1, 1] to [0, 1]

            // Calculate modulated frequency
            const freq_range: f32 = self.max_freq - self.min_freq;
            const modulated_freq: f32 = self.min_freq + lfo * self.lfo_depth * freq_range;

            // Update all allpass filter frequencies
            for (self.allpass_filters) |*filter| {
                filter.setFrequency(modulated_freq, self.sample_rate);
            }

            // Mix input with feedback from previous iteration
            var filtered: f32 = sample + self.feedback_sample * self.feedback;

            // Cascade signal through all allpass filters
            for (self.allpass_filters) |*filter| {
                filtered = filter.process(filtered);
            }

            // Store filtered output for next feedback iteration
            self.feedback_sample = filtered;

            // Mix dry and wet signals
            output[i] = sample * (1.0 - self.wet_dry) + filtered * self.wet_dry;

            // Advance LFO phase
            const phase_increment: f32 = self.lfo_rate / @as(f32, @floatFromInt(self.sample_rate));
            self.lfo_phase += phase_increment;
            if (self.lfo_phase >= 1.0) {
                self.lfo_phase -= 1.0;
            }
        }
    }

    /// Get current parameter values (useful for UI/debugging)
    pub fn getParameters(self: *const Phaser) struct {
        rate: f32,
        depth: f32,
        stages: usize,
        feedback: f32,
        wet_dry: f32,
        min_freq: f32,
        max_freq: f32,
        enabled: bool,
    } {
        return .{
            .rate = self.lfo_rate,
            .depth = self.lfo_depth,
            .stages = self.num_stages,
            .feedback = self.feedback,
            .wet_dry = self.wet_dry,
            .min_freq = self.min_freq,
            .max_freq = self.max_freq,
            .enabled = self.enabled,
        };
    }
};

// Unit tests
test "Phaser init and deinit" {
    const allocator = std.testing.allocator;
    var phaser = try Phaser.init(allocator, 48000, 6);
    defer phaser.deinit();

    try std.testing.expectEqual(@as(u32, 48000), phaser.sample_rate);
    try std.testing.expectEqual(@as(usize, 6), phaser.num_stages);
    try std.testing.expect(phaser.enabled);
    try std.testing.expectApproxEqRel(@as(f32, 0.5), phaser.wet_dry, 0.01);
}

test "Phaser bypasses when disabled" {
    const allocator = std.testing.allocator;
    var phaser = try Phaser.init(allocator, 48000, 6);
    defer phaser.deinit();

    phaser.setEnabled(false);

    const input = [_]f32{ 0.1, 0.2, 0.3, 0.4, 0.5 };
    var output: [5]f32 = undefined;

    phaser.process(&input, &output);

    for (input, output) |in, out| {
        try std.testing.expectEqual(in, out);
    }
}

test "Phaser processes audio when enabled" {
    const allocator = std.testing.allocator;
    var phaser = try Phaser.init(allocator, 48000, 6);
    defer phaser.deinit();

    const input = [_]f32{0.5} ** 1024;
    var output: [1024]f32 = undefined;

    phaser.process(&input, &output);

    // Output should be different from input (phaser is processing)
    var differs = false;
    for (input, output) |in, out| {
        if (@abs(in - out) > 0.001) {
            differs = true;
            break;
        }
    }
    try std.testing.expect(differs);
}

test "Phaser parameter setters" {
    const allocator = std.testing.allocator;
    var phaser = try Phaser.init(allocator, 48000, 6);
    defer phaser.deinit();

    phaser.setRate(2.0);
    phaser.setDepth(0.8);
    phaser.setFeedback(0.7);
    phaser.setWetDry(0.6);
    phaser.setFrequencyRange(300.0, 3000.0);
    phaser.setEnabled(false);

    const params = phaser.getParameters();
    try std.testing.expectApproxEqRel(@as(f32, 2.0), params.rate, 0.01);
    try std.testing.expectApproxEqRel(@as(f32, 0.8), params.depth, 0.01);
    try std.testing.expectApproxEqRel(@as(f32, 0.7), params.feedback, 0.01);
    try std.testing.expectApproxEqRel(@as(f32, 0.6), params.wet_dry, 0.01);
    try std.testing.expectApproxEqRel(@as(f32, 300.0), params.min_freq, 0.01);
    try std.testing.expectApproxEqRel(@as(f32, 3000.0), params.max_freq, 0.01);
    try std.testing.expect(!params.enabled);
}

test "Phaser stages modification" {
    const allocator = std.testing.allocator;
    var phaser = try Phaser.init(allocator, 48000, 6);
    defer phaser.deinit();

    try phaser.setStages(8);
    try std.testing.expectEqual(@as(usize, 8), phaser.num_stages);

    try phaser.setStages(4);
    try std.testing.expectEqual(@as(usize, 4), phaser.num_stages);
}

test "AllpassFilter basic operation" {
    var filter = Phaser.AllpassFilter.init();
    filter.setFrequency(1000.0, 48000);

    // Process some samples
    const input = [_]f32{ 0.5, 0.3, 0.1, -0.2, -0.5 };
    var output: [5]f32 = undefined;

    for (input, 0..) |sample, i| {
        output[i] = filter.process(sample);
    }

    // Allpass should preserve signal energy but change phase
    // Just check that output is not identical to input
    var differs = false;
    for (input, output) |in, out| {
        if (@abs(in - out) > 0.001) {
            differs = true;
            break;
        }
    }
    try std.testing.expect(differs);
}

test "Phaser feedback stays stable" {
    const allocator = std.testing.allocator;
    var phaser = try Phaser.init(allocator, 48000, 6);
    defer phaser.deinit();

    phaser.setFeedback(0.9); // High but safe feedback

    const input = [_]f32{0.1} ** 4800; // 100ms of audio
    var output: [4800]f32 = undefined;

    phaser.process(&input, &output);

    // Check that output doesn't explode
    for (output) |sample| {
        try std.testing.expect(@abs(sample) < 10.0); // Reasonable bound
    }
}
