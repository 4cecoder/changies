const std = @import("std");
const Allocator = std.mem.Allocator;

/// Dynamic EQ - Resonance suppression and harsh frequency taming
///
/// Similar to Oeksound Soothe or Smooth Operator.
/// Automatically detects and reduces harsh resonances and transients
/// in specific frequency bands. Perfect for taming sibilance, harshness,
/// and problematic resonances in vocals.
pub const DynamicEQ = struct {
    sample_rate: u32,
    allocator: Allocator,

    /// Number of frequency bands
    num_bands: usize,

    /// Band processors
    bands: []Band,

    /// Enable/disable
    enabled: bool,

    /// Single frequency band with dynamic processing
    const Band = struct {
        /// Band filter (biquad bandpass)
        filter: BiquadFilter,

        /// Envelope follower state
        envelope: f32,

        /// Band parameters
        freq: f32,         // Center frequency (Hz)
        q: f32,            // Filter Q factor
        threshold: f32,    // Threshold in linear (0.0-1.0)
        ratio: f32,        // Compression ratio (1.0 = no compression, 10.0 = hard)
        attack_coeff: f32, // Attack time coefficient
        release_coeff: f32, // Release time coefficient
        enabled: bool,

        pub fn init(sample_rate: u32, freq: f32, q: f32) Band {
            const sample_rate_f: f32 = @floatFromInt(sample_rate);
            const attack_time: f32 = 0.010; // 10ms attack
            const release_time: f32 = 0.100; // 100ms release

            return .{
                .filter = BiquadFilter.designBandpass(freq, q, sample_rate),
                .envelope = 0.0,
                .freq = freq,
                .q = q,
                .threshold = 0.5, // -6dB threshold
                .ratio = 2.0,      // 2:1 compression
                .attack_coeff = 1.0 - @exp(-1.0 / (attack_time * sample_rate_f)),
                .release_coeff = 1.0 - @exp(-1.0 / (release_time * sample_rate_f)),
                .enabled = true,
            };
        }

        pub fn updateFilter(self: *Band, sample_rate: u32) void {
            self.filter = BiquadFilter.designBandpass(self.freq, self.q, sample_rate);
        }

        pub fn process(self: *Band, sample: f32) f32 {
            if (!self.enabled) return sample;

            // Filter sample through band
            const filtered = self.filter.process(sample);
            const magnitude = @abs(filtered);

            // Update envelope follower
            const coeff = if (magnitude > self.envelope)
                self.attack_coeff
            else
                self.release_coeff;

            self.envelope += (magnitude - self.envelope) * coeff;

            // Calculate gain reduction based on threshold and ratio
            var gain: f32 = 1.0;

            if (self.envelope > self.threshold) {
                // Above threshold - compress
                const overshoot = self.envelope / self.threshold;
                // gain_dB = (overshoot_dB - overshoot_dB/ratio)
                // Linear approximation for efficiency
                const reduction = (overshoot - 1.0) * (1.0 - 1.0 / self.ratio);
                gain = 1.0 / (1.0 + reduction);
            }

            // Apply gain to filtered signal and mix back
            return sample - filtered + filtered * gain;
        }
    };

    /// Biquad filter (bandpass)
    const BiquadFilter = struct {
        // Coefficients
        b0: f32,
        b1: f32,
        b2: f32,
        a1: f32,
        a2: f32,

        // State
        x1: f32 = 0.0,
        x2: f32 = 0.0,
        y1: f32 = 0.0,
        y2: f32 = 0.0,

        pub fn process(self: *BiquadFilter, input: f32) f32 {
            const output = self.b0 * input + self.b1 * self.x1 + self.b2 * self.x2 -
                self.a1 * self.y1 - self.a2 * self.y2;

            self.x2 = self.x1;
            self.x1 = input;
            self.y2 = self.y1;
            self.y1 = output;

            return output;
        }

        pub fn reset(self: *BiquadFilter) void {
            self.x1 = 0.0;
            self.x2 = 0.0;
            self.y1 = 0.0;
            self.y2 = 0.0;
        }

        pub fn designBandpass(center_freq: f32, q: f32, sample_rate: u32) BiquadFilter {
            const sample_rate_f: f32 = @floatFromInt(sample_rate);
            const omega = 2.0 * std.math.pi * center_freq / sample_rate_f;
            const sin_omega = @sin(omega);
            const cos_omega = @cos(omega);
            const alpha = sin_omega / (2.0 * q);

            const a0 = 1.0 + alpha;

            return .{
                .b0 = alpha / a0,
                .b1 = 0.0,
                .b2 = -alpha / a0,
                .a1 = -2.0 * cos_omega / a0,
                .a2 = (1.0 - alpha) / a0,
            };
        }
    };

    pub fn init(allocator: Allocator, sample_rate: u32, num_bands: usize) !DynamicEQ {
        const clamped_bands = std.math.clamp(num_bands, 3, 8);

        const bands = try allocator.alloc(Band, clamped_bands);

        // Initialize with logarithmically spaced frequencies
        const min_freq: f32 = 100.0;  // 100 Hz
        const max_freq: f32 = 8000.0; // 8 kHz
        const log_min = @log(min_freq);
        const log_max = @log(max_freq);
        const num_bands_f: f32 = @floatFromInt(clamped_bands);

        for (0..clamped_bands) |i| {
            const i_f: f32 = @floatFromInt(i);
            const t = i_f / (num_bands_f - 1.0);
            const log_freq = log_min + t * (log_max - log_min);
            const freq = @exp(log_freq);
            const q: f32 = 2.0; // Moderate Q

            bands[i] = Band.init(sample_rate, freq, q);
        }

        return .{
            .sample_rate = sample_rate,
            .allocator = allocator,
            .num_bands = clamped_bands,
            .bands = bands,
            .enabled = false,
        };
    }

    pub fn deinit(self: *DynamicEQ) void {
        self.allocator.free(self.bands);
    }

    pub fn setEnabled(self: *DynamicEQ, enabled: bool) void {
        self.enabled = enabled;
        if (!enabled) {
            self.reset();
        }
    }

    pub fn isEnabled(self: *const DynamicEQ) bool {
        return self.enabled;
    }

    /// Set parameters for a specific band
    pub fn setBandFreq(self: *DynamicEQ, band_idx: usize, freq: f32) void {
        if (band_idx >= self.num_bands) return;
        self.bands[band_idx].freq = std.math.clamp(freq, 20.0, 20000.0);
        self.bands[band_idx].updateFilter(self.sample_rate);
    }

    pub fn setBandQ(self: *DynamicEQ, band_idx: usize, q: f32) void {
        if (band_idx >= self.num_bands) return;
        self.bands[band_idx].q = std.math.clamp(q, 0.1, 10.0);
        self.bands[band_idx].updateFilter(self.sample_rate);
    }

    pub fn setBandThreshold(self: *DynamicEQ, band_idx: usize, threshold: f32) void {
        if (band_idx >= self.num_bands) return;
        self.bands[band_idx].threshold = std.math.clamp(threshold, 0.01, 1.0);
    }

    pub fn setBandRatio(self: *DynamicEQ, band_idx: usize, ratio: f32) void {
        if (band_idx >= self.num_bands) return;
        self.bands[band_idx].ratio = std.math.clamp(ratio, 1.0, 20.0);
    }

    pub fn setBandEnabled(self: *DynamicEQ, band_idx: usize, enabled: bool) void {
        if (band_idx >= self.num_bands) return;
        self.bands[band_idx].enabled = enabled;
    }

    pub fn reset(self: *DynamicEQ) void {
        for (self.bands) |*band| {
            band.filter.reset();
            band.envelope = 0.0;
        }
    }

    /// Process audio buffer
    pub fn process(self: *DynamicEQ, input: []const f32, output: []f32) void {
        std.debug.assert(input.len == output.len);

        if (!self.enabled) {
            if (output.ptr != input.ptr) @memcpy(output, input);
            return;
        }

        for (input, 0..) |sample, i| {
            var processed = sample;

            // Process through each band
            for (self.bands) |*band| {
                processed = band.process(processed);
            }

            output[i] = processed;
        }
    }
};

// Tests
test "DynamicEQ initialization" {
    const allocator = std.testing.allocator;
    var eq = try DynamicEQ.init(allocator, 48000, 4);
    defer eq.deinit();

    try std.testing.expectEqual(@as(usize, 4), eq.num_bands);
    try std.testing.expectEqual(false, eq.enabled);
}

test "DynamicEQ bypass when disabled" {
    const allocator = std.testing.allocator;
    var eq = try DynamicEQ.init(allocator, 48000, 4);
    defer eq.deinit();

    eq.setEnabled(false);

    const input = [_]f32{ 0.5, -0.5, 0.25, -0.25 };
    var output: [4]f32 = undefined;

    eq.process(&input, &output);

    for (input, output) |in_sample, out_sample| {
        try std.testing.expectEqual(in_sample, out_sample);
    }
}
