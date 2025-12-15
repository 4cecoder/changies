const std = @import("std");
const Allocator = std.mem.Allocator;

/// AI-style Denoiser - Spectral noise reduction
///
/// Similar to iZotope RX's AI denoiser, this effect uses spectral
/// subtraction and adaptive filtering to remove background noise
/// while preserving vocal quality.
pub const Denoiser = struct {
    sample_rate: u32,
    allocator: Allocator,

    /// Noise reduction amount (0.0-1.0)
    reduction_amount: f32,

    /// Threshold for noise detection (0.0-1.0)
    threshold: f32,

    /// Smoothing factor for noise profile adaptation
    smoothing: f32,

    /// Enable/disable the effect
    enabled: bool,

    /// Noise profile (estimated noise floor per frequency band)
    noise_profile: []f32,
    num_bands: usize,

    /// Bandpass filters for spectral processing
    band_filters: []BandFilter,

    /// Envelope followers for each band
    envelopes: []f32,

    /// Attack/release for envelope followers
    attack_coeff: f32,
    release_coeff: f32,

    /// Simple bandpass filter
    const BandFilter = struct {
        // Biquad coefficients
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

        pub fn process(self: *BandFilter, input: f32) f32 {
            const output = self.b0 * input + self.b1 * self.x1 + self.b2 * self.x2 -
                self.a1 * self.y1 - self.a2 * self.y2;

            self.x2 = self.x1;
            self.x1 = input;
            self.y2 = self.y1;
            self.y1 = output;

            return output;
        }

        pub fn reset(self: *BandFilter) void {
            self.x1 = 0.0;
            self.x2 = 0.0;
            self.y1 = 0.0;
            self.y2 = 0.0;
        }

        pub fn designBandpass(center_freq: f32, q: f32, sample_rate: u32) BandFilter {
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

    pub fn init(allocator: Allocator, sample_rate: u32, num_bands: usize) !Denoiser {
        const clamped_bands = std.math.clamp(num_bands, 12, 32);

        const noise_profile = try allocator.alloc(f32, clamped_bands);
        const band_filters = try allocator.alloc(BandFilter, clamped_bands);
        const envelopes = try allocator.alloc(f32, clamped_bands);

        // Initialize to zero
        @memset(noise_profile, 0.0);
        @memset(envelopes, 0.0);

        // Design logarithmically spaced bandpass filters
        // Frequency range: 80 Hz to 12000 Hz (human voice range)
        const min_freq: f32 = 80.0;
        const max_freq: f32 = 12000.0;
        const log_min = @log(min_freq);
        const log_max = @log(max_freq);
        const num_bands_f: f32 = @floatFromInt(clamped_bands);

        for (0..clamped_bands) |i| {
            const i_f: f32 = @floatFromInt(i);
            const t = i_f / (num_bands_f - 1.0);
            const log_freq = log_min + t * (log_max - log_min);
            const center_freq = @exp(log_freq);

            const q: f32 = 2.0; // Filter Q factor
            band_filters[i] = BandFilter.designBandpass(center_freq, q, sample_rate);
        }

        // Attack: 5ms, Release: 50ms
        const sample_rate_f: f32 = @floatFromInt(sample_rate);
        const attack_time: f32 = 0.005;
        const release_time: f32 = 0.050;

        return .{
            .sample_rate = sample_rate,
            .allocator = allocator,
            .reduction_amount = 0.7, // 70% noise reduction
            .threshold = 0.05, // -26 dBFS threshold
            .smoothing = 0.95, // Slow adaptation
            .enabled = false,
            .noise_profile = noise_profile,
            .num_bands = clamped_bands,
            .band_filters = band_filters,
            .envelopes = envelopes,
            .attack_coeff = 1.0 - @exp(-1.0 / (attack_time * sample_rate_f)),
            .release_coeff = 1.0 - @exp(-1.0 / (release_time * sample_rate_f)),
        };
    }

    pub fn deinit(self: *Denoiser) void {
        self.allocator.free(self.noise_profile);
        self.allocator.free(self.band_filters);
        self.allocator.free(self.envelopes);
    }

    /// Set reduction amount (0.0-1.0)
    pub fn setReductionAmount(self: *Denoiser, amount: f32) void {
        self.reduction_amount = std.math.clamp(amount, 0.0, 1.0);
    }

    /// Set noise threshold (0.0-1.0)
    pub fn setThreshold(self: *Denoiser, threshold: f32) void {
        self.threshold = std.math.clamp(threshold, 0.0, 1.0);
    }

    /// Set smoothing (0.0-1.0) - how quickly the noise profile adapts
    pub fn setSmoothing(self: *Denoiser, smoothing: f32) void {
        self.smoothing = std.math.clamp(smoothing, 0.0, 1.0);
    }

    pub fn setEnabled(self: *Denoiser, enabled: bool) void {
        self.enabled = enabled;
        if (!enabled) {
            self.reset();
        }
    }

    pub fn isEnabled(self: *const Denoiser) bool {
        return self.enabled;
    }

    pub fn getReductionAmount(self: *const Denoiser) f32 {
        return self.reduction_amount;
    }

    pub fn getThreshold(self: *const Denoiser) f32 {
        return self.threshold;
    }

    pub fn getSmoothing(self: *const Denoiser) f32 {
        return self.smoothing;
    }

    pub fn reset(self: *Denoiser) void {
        @memset(self.noise_profile, 0.0);
        @memset(self.envelopes, 0.0);
        for (self.band_filters) |*filter| {
            filter.reset();
        }
    }

    /// Learn noise profile from a silent section (call this during silence)
    pub fn learnNoiseProfile(self: *Denoiser, input: []const f32) void {
        for (input) |sample| {
            for (0..self.num_bands) |band| {
                // Filter sample through each band
                const filtered = self.band_filters[band].process(sample);
                const magnitude = @abs(filtered);

                // Update noise profile (slow adaptation)
                self.noise_profile[band] = self.noise_profile[band] * 0.99 + magnitude * 0.01;
            }
        }
    }

    /// Process audio buffer with noise reduction
    pub fn process(self: *Denoiser, input: []const f32, output: []f32) void {
        std.debug.assert(input.len == output.len);

        if (!self.enabled) {
            if (output.ptr != input.ptr) @memcpy(output, input);
            return;
        }

        for (input, 0..) |sample, i| {
            var clean_output: f32 = 0.0;

            for (0..self.num_bands) |band| {
                // Filter sample through band
                const filtered = self.band_filters[band].process(sample);
                const magnitude = @abs(filtered);

                // Update envelope follower
                const target_env = magnitude;
                const coeff = if (target_env > self.envelopes[band])
                    self.attack_coeff
                else
                    self.release_coeff;

                self.envelopes[band] += (target_env - self.envelopes[band]) * coeff;

                // Adaptive noise profile update (when signal is below threshold)
                if (self.envelopes[band] < self.threshold) {
                    self.noise_profile[band] = self.noise_profile[band] * self.smoothing +
                        magnitude * (1.0 - self.smoothing);
                }

                // Calculate noise suppression gain
                const noise_floor = self.noise_profile[band];
                const signal_to_noise = if (noise_floor > 0.001)
                    self.envelopes[band] / noise_floor
                else
                    1.0;

                // Spectral subtraction with smoothing
                var gain: f32 = 1.0;
                if (signal_to_noise < 1.5) {
                    // Likely noise - reduce gain
                    gain = 1.0 - self.reduction_amount;
                } else if (signal_to_noise < 3.0) {
                    // Transition zone - soft threshold
                    const t = (signal_to_noise - 1.5) / 1.5;
                    gain = (1.0 - self.reduction_amount) + t * self.reduction_amount;
                }

                // Apply gain and accumulate
                clean_output += filtered * gain;
            }

            // Normalize by number of bands
            const num_bands_f: f32 = @floatFromInt(self.num_bands);
            output[i] = clean_output / @sqrt(num_bands_f);
        }
    }

    /// Process audio buffer in place
    pub fn processInPlace(self: *Denoiser, buffer: []f32) void {
        if (!self.enabled) return;

        for (buffer) |*sample| {
            const original = sample.*;
            var clean_output: f32 = 0.0;

            for (0..self.num_bands) |band| {
                const filtered = self.band_filters[band].process(original);
                const magnitude = @abs(filtered);

                const target_env = magnitude;
                const coeff = if (target_env > self.envelopes[band])
                    self.attack_coeff
                else
                    self.release_coeff;

                self.envelopes[band] += (target_env - self.envelopes[band]) * coeff;

                if (self.envelopes[band] < self.threshold) {
                    self.noise_profile[band] = self.noise_profile[band] * self.smoothing +
                        magnitude * (1.0 - self.smoothing);
                }

                const noise_floor = self.noise_profile[band];
                const signal_to_noise = if (noise_floor > 0.001)
                    self.envelopes[band] / noise_floor
                else
                    1.0;

                var gain: f32 = 1.0;
                if (signal_to_noise < 1.5) {
                    gain = 1.0 - self.reduction_amount;
                } else if (signal_to_noise < 3.0) {
                    const t = (signal_to_noise - 1.5) / 1.5;
                    gain = (1.0 - self.reduction_amount) + t * self.reduction_amount;
                }

                clean_output += filtered * gain;
            }

            const num_bands_f: f32 = @floatFromInt(self.num_bands);
            sample.* = clean_output / @sqrt(num_bands_f);
        }
    }
};

// Tests
test "Denoiser initialization" {
    const allocator = std.testing.allocator;
    var denoiser = try Denoiser.init(allocator, 48000, 16);
    defer denoiser.deinit();

    try std.testing.expectEqual(@as(usize, 16), denoiser.num_bands);
    try std.testing.expectEqual(@as(f32, 0.7), denoiser.reduction_amount);
    try std.testing.expectEqual(false, denoiser.enabled);
}

test "Denoiser bypass when disabled" {
    const allocator = std.testing.allocator;
    var denoiser = try Denoiser.init(allocator, 48000, 16);
    defer denoiser.deinit();

    denoiser.setEnabled(false);

    const input = [_]f32{ 0.5, -0.5, 0.25, -0.25 };
    var output: [4]f32 = undefined;

    denoiser.process(&input, &output);

    for (input, output) |in_sample, out_sample| {
        try std.testing.expectEqual(in_sample, out_sample);
    }
}
