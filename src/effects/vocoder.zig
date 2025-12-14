const std = @import("std");
const Allocator = std.mem.Allocator;

/// Biquad filter for vocoder filterbanks
const BiquadFilter = struct {
    // Coefficients
    b0: f32,
    b1: f32,
    b2: f32,
    a1: f32,
    a2: f32,

    // State variables
    x1: f32 = 0.0,
    x2: f32 = 0.0,
    y1: f32 = 0.0,
    y2: f32 = 0.0,

    /// Process one sample through the filter
    pub fn process(self: *BiquadFilter, input: f32) f32 {
        const output: f32 = self.b0 * input + self.b1 * self.x1 + self.b2 * self.x2 - self.a1 * self.y1 - self.a2 * self.y2;

        // Update state
        self.x2 = self.x1;
        self.x1 = input;
        self.y2 = self.y1;
        self.y1 = output;

        return output;
    }

    /// Reset filter state
    pub fn reset(self: *BiquadFilter) void {
        self.x1 = 0.0;
        self.x2 = 0.0;
        self.y1 = 0.0;
        self.y2 = 0.0;
    }

    /// Design a bandpass filter
    pub fn designBandpass(center_freq: f32, q: f32, sample_rate: u32) BiquadFilter {
        const sample_rate_f: f32 = @floatFromInt(sample_rate);
        const omega: f32 = 2.0 * std.math.pi * center_freq / sample_rate_f;
        const sin_omega: f32 = @sin(omega);
        const cos_omega: f32 = @cos(omega);
        const alpha: f32 = sin_omega / (2.0 * q);

        const a0: f32 = 1.0 + alpha;

        return .{
            .b0 = alpha / a0,
            .b1 = 0.0,
            .b2 = -alpha / a0,
            .a1 = -2.0 * cos_omega / a0,
            .a2 = (1.0 - alpha) / a0,
        };
    }
};

/// Vocoder effect - channel vocoder for robotic voice effects
///
/// Uses a filterbank to analyze the modulator (voice) and applies
/// the envelope to a synthesized carrier, creating the classic vocoder sound.
pub const Vocoder = struct {
    sample_rate: u32,
    allocator: Allocator,
    num_bands: usize,

    /// Analysis filterbank (processes modulator/voice)
    analysis_filters: []BiquadFilter,

    /// Synthesis filterbank (processes carrier/synth)
    synthesis_filters: []BiquadFilter,

    /// Envelope followers for each band
    envelopes: []f32,

    /// Envelope attack coefficient
    envelope_attack: f32,

    /// Envelope release coefficient
    envelope_release: f32,

    /// Carrier oscillator frequency (Hz)
    carrier_freq: f32,

    /// Carrier oscillator phase (0.0-1.0)
    carrier_phase: f32,

    /// Wet/dry mix (0.0 = dry, 1.0 = wet)
    wet_dry: f32,

    /// Enable/disable the effect
    enabled: bool,

    /// Band center frequencies
    band_freqs: []f32,

    /// Initialize vocoder
    pub fn init(allocator: Allocator, sample_rate: u32, num_bands: usize) !Vocoder {
        const clamped_bands: usize = std.math.clamp(num_bands, 8, 32);

        // Allocate arrays
        const analysis_filters = try allocator.alloc(BiquadFilter, clamped_bands);
        const synthesis_filters = try allocator.alloc(BiquadFilter, clamped_bands);
        const envelopes = try allocator.alloc(f32, clamped_bands);
        const band_freqs = try allocator.alloc(f32, clamped_bands);

        // Initialize envelopes to zero
        @memset(envelopes, 0.0);

        // Design filterbanks with logarithmically spaced bands
        // Frequency range: 100 Hz to 8000 Hz
        const min_freq: f32 = 100.0;
        const max_freq: f32 = 8000.0;
        const log_min: f32 = @log(min_freq);
        const log_max: f32 = @log(max_freq);
        const num_bands_f: f32 = @floatFromInt(clamped_bands);

        for (0..clamped_bands) |i| {
            const i_f: f32 = @floatFromInt(i);
            const t: f32 = i_f / (num_bands_f - 1.0);
            const log_freq: f32 = log_min + t * (log_max - log_min);
            const center_freq: f32 = @exp(log_freq);

            band_freqs[i] = center_freq;

            // Q factor for bandpass filters (adjust for band overlap)
            const q: f32 = 4.0;

            analysis_filters[i] = BiquadFilter.designBandpass(center_freq, q, sample_rate);
            synthesis_filters[i] = BiquadFilter.designBandpass(center_freq, q, sample_rate);
        }

        // Calculate envelope coefficients
        // Attack: 10ms, Release: 50ms
        const sample_rate_f: f32 = @floatFromInt(sample_rate);
        const attack_time: f32 = 0.010; // 10ms
        const release_time: f32 = 0.050; // 50ms

        return .{
            .sample_rate = sample_rate,
            .allocator = allocator,
            .num_bands = clamped_bands,
            .analysis_filters = analysis_filters,
            .synthesis_filters = synthesis_filters,
            .envelopes = envelopes,
            .envelope_attack = 1.0 - @exp(-1.0 / (attack_time * sample_rate_f)),
            .envelope_release = 1.0 - @exp(-1.0 / (release_time * sample_rate_f)),
            .carrier_freq = 120.0,
            .carrier_phase = 0.0,
            .wet_dry = 0.5,
            .enabled = false,
            .band_freqs = band_freqs,
        };
    }

    /// Clean up allocated memory
    pub fn deinit(self: *Vocoder) void {
        self.allocator.free(self.analysis_filters);
        self.allocator.free(self.synthesis_filters);
        self.allocator.free(self.envelopes);
        self.allocator.free(self.band_freqs);
    }

    /// Set carrier frequency (50-500 Hz)
    pub fn setCarrierFreq(self: *Vocoder, freq: f32) void {
        self.carrier_freq = std.math.clamp(freq, 50.0, 500.0);
    }

    /// Set wet/dry mix (0.0-1.0)
    pub fn setWetDry(self: *Vocoder, mix: f32) void {
        self.wet_dry = std.math.clamp(mix, 0.0, 1.0);
    }

    /// Enable or disable the effect
    pub fn setEnabled(self: *Vocoder, enabled: bool) void {
        self.enabled = enabled;
    }

    /// Get current carrier frequency
    pub fn getCarrierFreq(self: *const Vocoder) f32 {
        return self.carrier_freq;
    }

    /// Get current wet/dry mix
    pub fn getWetDry(self: *const Vocoder) f32 {
        return self.wet_dry;
    }

    /// Get enabled state
    pub fn isEnabled(self: *const Vocoder) bool {
        return self.enabled;
    }

    /// Get number of bands
    pub fn getNumBands(self: *const Vocoder) usize {
        return self.num_bands;
    }

    /// Reset the effect state
    pub fn reset(self: *Vocoder) void {
        for (self.analysis_filters) |*filter| {
            filter.reset();
        }
        for (self.synthesis_filters) |*filter| {
            filter.reset();
        }
        @memset(self.envelopes, 0.0);
        self.carrier_phase = 0.0;
    }

    /// Generate sawtooth wave for carrier
    /// Sawtooth provides rich harmonics for better vocoding
    fn generateSawtooth(self: *Vocoder) f32 {
        return 2.0 * self.carrier_phase - 1.0;
    }

    /// Generate square wave for carrier (alternative)
    fn generateSquare(self: *Vocoder) f32 {
        return if (self.carrier_phase < 0.5) 1.0 else -1.0;
    }

    /// Generate pulse train with multiple harmonics
    fn generatePulse(self: *Vocoder) f32 {
        // Sum first 8 harmonics for a rich spectrum
        var output: f32 = 0.0;
        const two_pi: f32 = 2.0 * std.math.pi;

        var harmonic: usize = 1;
        while (harmonic <= 8) : (harmonic += 1) {
            const harmonic_f: f32 = @floatFromInt(harmonic);
            const amplitude: f32 = 1.0 / harmonic_f;
            output += amplitude * @sin(self.carrier_phase * two_pi * harmonic_f);
        }

        return output * 0.3; // Scale down to prevent clipping
    }

    /// Process audio buffer with vocoder
    pub fn process(self: *Vocoder, input: []const f32, output: []f32) void {
        std.debug.assert(input.len == output.len);

        if (!self.enabled) {
            @memcpy(output, input);
            return;
        }

        const sample_rate_f: f32 = @floatFromInt(self.sample_rate);
        const phase_increment: f32 = self.carrier_freq / sample_rate_f;

        for (input, 0..) |sample, i| {
            // Generate carrier (using sawtooth for rich harmonics)
            const carrier: f32 = self.generateSawtooth();

            var voiced_output: f32 = 0.0;

            // Process each frequency band
            for (0..self.num_bands) |band| {
                // Analyze modulator (voice input)
                const mod_filtered: f32 = self.analysis_filters[band].process(sample);

                // Extract envelope (absolute value)
                const envelope_target: f32 = @abs(mod_filtered);

                // Smooth envelope with attack/release
                const coeff: f32 = if (envelope_target > self.envelopes[band])
                    self.envelope_attack
                else
                    self.envelope_release;

                self.envelopes[band] += (envelope_target - self.envelopes[band]) * coeff;

                // Synthesize: apply envelope to filtered carrier
                const carrier_filtered: f32 = self.synthesis_filters[band].process(carrier);
                voiced_output += carrier_filtered * self.envelopes[band];
            }

            // Normalize to prevent excessive gain
            const num_bands_f: f32 = @floatFromInt(self.num_bands);
            voiced_output /= @sqrt(num_bands_f);

            // Mix wet and dry signals
            output[i] = sample * (1.0 - self.wet_dry) + voiced_output * self.wet_dry;

            // Advance carrier phase
            self.carrier_phase += phase_increment;
            if (self.carrier_phase >= 1.0) {
                self.carrier_phase -= 1.0;
            }
        }
    }

    /// Process audio buffer in place
    pub fn processInPlace(self: *Vocoder, buffer: []f32) void {
        if (!self.enabled) {
            return;
        }

        const sample_rate_f: f32 = @floatFromInt(self.sample_rate);
        const phase_increment: f32 = self.carrier_freq / sample_rate_f;

        for (buffer) |*sample| {
            const original: f32 = sample.*;
            const carrier: f32 = self.generateSawtooth();

            var voiced_output: f32 = 0.0;

            for (0..self.num_bands) |band| {
                const mod_filtered: f32 = self.analysis_filters[band].process(original);
                const envelope_target: f32 = @abs(mod_filtered);

                const coeff: f32 = if (envelope_target > self.envelopes[band])
                    self.envelope_attack
                else
                    self.envelope_release;

                self.envelopes[band] += (envelope_target - self.envelopes[band]) * coeff;

                const carrier_filtered: f32 = self.synthesis_filters[band].process(carrier);
                voiced_output += carrier_filtered * self.envelopes[band];
            }

            const num_bands_f: f32 = @floatFromInt(self.num_bands);
            voiced_output /= @sqrt(num_bands_f);

            sample.* = original * (1.0 - self.wet_dry) + voiced_output * self.wet_dry;

            self.carrier_phase += phase_increment;
            if (self.carrier_phase >= 1.0) {
                self.carrier_phase -= 1.0;
            }
        }
    }

    /// Get the center frequency of a specific band
    pub fn getBandFreq(self: *const Vocoder, band: usize) ?f32 {
        if (band >= self.num_bands) return null;
        return self.band_freqs[band];
    }

    /// Get the current envelope value of a specific band
    pub fn getBandEnvelope(self: *const Vocoder, band: usize) ?f32 {
        if (band >= self.num_bands) return null;
        return self.envelopes[band];
    }
};

// Tests
test "Vocoder initialization" {
    const allocator = std.testing.allocator;
    var vocoder = try Vocoder.init(allocator, 48000, 16);
    defer vocoder.deinit();

    try std.testing.expectEqual(@as(usize, 16), vocoder.num_bands);
    try std.testing.expectEqual(@as(f32, 120.0), vocoder.carrier_freq);
    try std.testing.expectEqual(@as(f32, 0.5), vocoder.wet_dry);
    try std.testing.expectEqual(false, vocoder.enabled);
}

test "Vocoder parameter setters" {
    const allocator = std.testing.allocator;
    var vocoder = try Vocoder.init(allocator, 48000, 16);
    defer vocoder.deinit();

    vocoder.setCarrierFreq(200.0);
    try std.testing.expectEqual(@as(f32, 200.0), vocoder.carrier_freq);

    // Test clamping
    vocoder.setCarrierFreq(1000.0);
    try std.testing.expectEqual(@as(f32, 500.0), vocoder.carrier_freq);

    vocoder.setCarrierFreq(10.0);
    try std.testing.expectEqual(@as(f32, 50.0), vocoder.carrier_freq);

    vocoder.setWetDry(0.75);
    try std.testing.expectEqual(@as(f32, 0.75), vocoder.wet_dry);

    vocoder.setEnabled(true);
    try std.testing.expectEqual(true, vocoder.enabled);
}

test "Vocoder bypass when disabled" {
    const allocator = std.testing.allocator;
    var vocoder = try Vocoder.init(allocator, 48000, 16);
    defer vocoder.deinit();

    vocoder.setEnabled(false);

    const input = [_]f32{ 0.5, -0.5, 0.25, -0.25 };
    var output: [4]f32 = undefined;

    vocoder.process(&input, &output);

    for (input, output) |in_sample, out_sample| {
        try std.testing.expectEqual(in_sample, out_sample);
    }
}

test "Vocoder band frequencies" {
    const allocator = std.testing.allocator;
    var vocoder = try Vocoder.init(allocator, 48000, 16);
    defer vocoder.deinit();

    // Check that band frequencies are logarithmically spaced
    const first_freq = vocoder.getBandFreq(0).?;
    const last_freq = vocoder.getBandFreq(15).?;

    try std.testing.expect(first_freq >= 100.0);
    try std.testing.expect(last_freq <= 8001.0); // Allow small floating point error
    try std.testing.expect(first_freq < last_freq);
}

test "BiquadFilter process" {
    var filter = BiquadFilter.designBandpass(1000.0, 2.0, 48000);

    // Process some samples
    const input: f32 = 0.5;
    const output = filter.process(input);

    // Output should be non-zero for valid filter
    try std.testing.expect(output != 0.0 or input == 0.0);
}
