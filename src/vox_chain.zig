const std = @import("std");

// Professional Vocal Processing Chain
// Provides broadcast-quality voice processing with:
// - High-pass filter, Dynamic EQ, De-esser, Compressor, Limiter

/// Biquad filter coefficients and state
pub const BiquadFilter = struct {
    // Coefficients
    b0: f32 = 1.0,
    b1: f32 = 0.0,
    b2: f32 = 0.0,
    a1: f32 = 0.0,
    a2: f32 = 0.0,

    // State (history)
    x1: f32 = 0.0,
    x2: f32 = 0.0,
    y1: f32 = 0.0,
    y2: f32 = 0.0,

    enabled: bool = true,

    pub fn init() BiquadFilter {
        return BiquadFilter{};
    }

    /// Process a single sample through the filter
    pub fn processSample(self: *BiquadFilter, input: f32) f32 {
        if (!self.enabled) return input;

        const output: f32 = self.b0 * input + self.b1 * self.x1 + self.b2 * self.x2 - self.a1 * self.y1 - self.a2 * self.y2;

        // Update state
        self.x2 = self.x1;
        self.x1 = input;
        self.y2 = self.y1;
        self.y1 = output;

        return output;
    }

    /// Process entire buffer
    pub fn processBuffer(self: *BiquadFilter, buffer: []f32) void {
        if (!self.enabled) return;

        for (buffer) |*sample| {
            sample.* = self.processSample(sample.*);
        }
    }

    /// Design a high-pass filter (2nd order Butterworth)
    pub fn designHighpass(self: *BiquadFilter, frequency: f32, sample_rate: f32) void {
        const omega: f32 = 2.0 * std.math.pi * frequency / sample_rate;
        const cos_omega: f32 = @cos(omega);
        const sin_omega: f32 = @sin(omega);
        const alpha: f32 = sin_omega / (2.0 * 0.707); // Q = 0.707 for Butterworth

        const a0: f32 = 1.0 + alpha;
        self.b0 = (1.0 + cos_omega) / (2.0 * a0);
        self.b1 = -(1.0 + cos_omega) / a0;
        self.b2 = (1.0 + cos_omega) / (2.0 * a0);
        self.a1 = (-2.0 * cos_omega) / a0;
        self.a2 = (1.0 - alpha) / a0;
    }

    /// Design a low shelf filter
    pub fn designLowShelf(self: *BiquadFilter, frequency: f32, gain_db: f32, sample_rate: f32) void {
        const a: f32 = @exp(@log(10.0) * gain_db / 40.0); // amplitude
        const omega: f32 = 2.0 * std.math.pi * frequency / sample_rate;
        const cos_omega: f32 = @cos(omega);
        const sin_omega: f32 = @sin(omega);
        const alpha: f32 = sin_omega / (2.0 * 0.707);
        const sqrt_a: f32 = @sqrt(a);

        const a0: f32 = (a + 1.0) + (a - 1.0) * cos_omega + 2.0 * sqrt_a * alpha;
        self.b0 = (a * ((a + 1.0) - (a - 1.0) * cos_omega + 2.0 * sqrt_a * alpha)) / a0;
        self.b1 = (2.0 * a * ((a - 1.0) - (a + 1.0) * cos_omega)) / a0;
        self.b2 = (a * ((a + 1.0) - (a - 1.0) * cos_omega - 2.0 * sqrt_a * alpha)) / a0;
        self.a1 = (-2.0 * ((a - 1.0) + (a + 1.0) * cos_omega)) / a0;
        self.a2 = ((a + 1.0) + (a - 1.0) * cos_omega - 2.0 * sqrt_a * alpha) / a0;
    }

    /// Design a peaking/parametric EQ filter
    pub fn designPeaking(self: *BiquadFilter, frequency: f32, gain_db: f32, q: f32, sample_rate: f32) void {
        const a: f32 = @exp(@log(10.0) * gain_db / 40.0);
        const omega: f32 = 2.0 * std.math.pi * frequency / sample_rate;
        const cos_omega: f32 = @cos(omega);
        const sin_omega: f32 = @sin(omega);
        const alpha: f32 = sin_omega / (2.0 * q);

        const a0: f32 = 1.0 + alpha / a;
        self.b0 = (1.0 + alpha * a) / a0;
        self.b1 = (-2.0 * cos_omega) / a0;
        self.b2 = (1.0 - alpha * a) / a0;
        self.a1 = (-2.0 * cos_omega) / a0;
        self.a2 = (1.0 - alpha / a) / a0;
    }

    /// Design a high shelf filter
    pub fn designHighShelf(self: *BiquadFilter, frequency: f32, gain_db: f32, sample_rate: f32) void {
        const a: f32 = @exp(@log(10.0) * gain_db / 40.0);
        const omega: f32 = 2.0 * std.math.pi * frequency / sample_rate;
        const cos_omega: f32 = @cos(omega);
        const sin_omega: f32 = @sin(omega);
        const alpha: f32 = sin_omega / (2.0 * 0.707);
        const sqrt_a: f32 = @sqrt(a);

        const a0: f32 = (a + 1.0) - (a - 1.0) * cos_omega + 2.0 * sqrt_a * alpha;
        self.b0 = (a * ((a + 1.0) + (a - 1.0) * cos_omega + 2.0 * sqrt_a * alpha)) / a0;
        self.b1 = (-2.0 * a * ((a - 1.0) + (a + 1.0) * cos_omega)) / a0;
        self.b2 = (a * ((a + 1.0) + (a - 1.0) * cos_omega - 2.0 * sqrt_a * alpha)) / a0;
        self.a1 = (2.0 * ((a - 1.0) - (a + 1.0) * cos_omega)) / a0;
        self.a2 = ((a + 1.0) - (a - 1.0) * cos_omega - 2.0 * sqrt_a * alpha) / a0;
    }

    /// Design a bandpass filter (for de-esser detector)
    pub fn designBandpass(self: *BiquadFilter, center_freq: f32, q: f32, sample_rate: f32) void {
        const omega: f32 = 2.0 * std.math.pi * center_freq / sample_rate;
        const cos_omega: f32 = @cos(omega);
        const sin_omega: f32 = @sin(omega);
        const alpha: f32 = sin_omega / (2.0 * q);

        const a0: f32 = 1.0 + alpha;
        self.b0 = alpha / a0;
        self.b1 = 0.0;
        self.b2 = -alpha / a0;
        self.a1 = (-2.0 * cos_omega) / a0;
        self.a2 = (1.0 - alpha) / a0;
    }

    pub fn reset(self: *BiquadFilter) void {
        self.x1 = 0.0;
        self.x2 = 0.0;
        self.y1 = 0.0;
        self.y2 = 0.0;
    }
};

/// De-esser for taming sibilance (4-8kHz)
pub const DeEsser = struct {
    detector: BiquadFilter,
    threshold: f32 = 0.01, // Linear threshold
    ratio: f32 = 3.0,
    envelope: f32 = 0.0,
    attack_coeff: f32,
    release_coeff: f32,
    enabled: bool = true,

    pub fn init(sample_rate: f32) DeEsser {
        const attack_samples: f32 = sample_rate * 0.001; // 1ms
        const release_samples: f32 = sample_rate * 0.050; // 50ms

        var detector = BiquadFilter.init();
        detector.designBandpass(6000.0, 1.0, sample_rate); // Center at 6kHz

        return DeEsser{
            .detector = detector,
            .attack_coeff = @exp(-1.0 / attack_samples),
            .release_coeff = @exp(-1.0 / release_samples),
        };
    }

    pub fn processBuffer(self: *DeEsser, buffer: []f32) void {
        if (!self.enabled) return;

        for (buffer) |*sample| {
            // Detect sibilant energy
            const detected: f32 = self.detector.processSample(sample.*);
            const detected_abs: f32 = @abs(detected);

            // Envelope follower
            const coeff: f32 = if (detected_abs > self.envelope) self.attack_coeff else self.release_coeff;
            self.envelope = detected_abs + coeff * (self.envelope - detected_abs);

            // Apply gain reduction only when above threshold
            if (self.envelope > self.threshold) {
                const excess: f32 = self.envelope - self.threshold;
                const reduction: f32 = excess * (1.0 - 1.0 / self.ratio);
                const gain: f32 = 1.0 - (reduction / (self.envelope + 0.0001));
                sample.* *= @max(0.1, gain); // Limit max reduction
            }
        }
    }

    pub fn setThresholdDb(self: *DeEsser, db: f32) void {
        self.threshold = @exp(@log(10.0) * db / 20.0);
    }

    pub fn setRatio(self: *DeEsser, ratio: f32) void {
        self.ratio = @max(1.0, ratio);
    }
};

/// Compressor with RMS detection
pub const Compressor = struct {
    threshold: f32 = 0.1, // Linear threshold
    ratio: f32 = 4.0,
    attack_coeff: f32,
    release_coeff: f32,
    makeup_gain: f32 = 1.0,
    envelope: f32 = 0.0,
    rms_buffer: [480]f32, // 10ms at 48kHz
    rms_index: usize = 0,
    rms_sum: f32 = 0.0,
    enabled: bool = true,

    pub fn init(sample_rate: f32) Compressor {
        const attack_samples: f32 = sample_rate * 0.005; // 5ms
        const release_samples: f32 = sample_rate * 0.050; // 50ms

        return Compressor{
            .attack_coeff = @exp(-1.0 / attack_samples),
            .release_coeff = @exp(-1.0 / release_samples),
            .rms_buffer = [_]f32{0.0} ** 480,
        };
    }

    pub fn processBuffer(self: *Compressor, buffer: []f32) void {
        if (!self.enabled) return;

        for (buffer) |*sample| {
            // RMS detection
            const old_sample: f32 = self.rms_buffer[self.rms_index];
            self.rms_buffer[self.rms_index] = sample.* * sample.*;
            self.rms_sum = self.rms_sum - old_sample + self.rms_buffer[self.rms_index];
            self.rms_index = (self.rms_index + 1) % self.rms_buffer.len;

            const rms: f32 = @sqrt(@max(0.0, self.rms_sum / @as(f32, @floatFromInt(self.rms_buffer.len))));

            // Envelope follower
            const coeff: f32 = if (rms > self.envelope) self.attack_coeff else self.release_coeff;
            self.envelope = rms + coeff * (self.envelope - rms);

            // Compute gain reduction
            var gain: f32 = 1.0;
            if (self.envelope > self.threshold) {
                const excess_db: f32 = 20.0 * @log10(@max(0.0001, self.envelope / self.threshold));
                const reduction_db: f32 = excess_db * (1.0 - 1.0 / self.ratio);
                gain = @exp(@log(10.0) * (-reduction_db / 20.0));
            }

            // Apply gain and makeup
            sample.* *= gain * self.makeup_gain;
        }
    }

    pub fn setThresholdDb(self: *Compressor, db: f32) void {
        self.threshold = @exp(@log(10.0) * db / 20.0);
    }

    pub fn setRatio(self: *Compressor, ratio: f32) void {
        self.ratio = @max(1.0, ratio);
    }

    pub fn setAttackMs(self: *Compressor, ms: f32, sample_rate: f32) void {
        const samples: f32 = sample_rate * ms / 1000.0;
        self.attack_coeff = @exp(-1.0 / samples);
    }

    pub fn setReleaseMs(self: *Compressor, ms: f32, sample_rate: f32) void {
        const samples: f32 = sample_rate * ms / 1000.0;
        self.release_coeff = @exp(-1.0 / samples);
    }

    pub fn setMakeupGainDb(self: *Compressor, db: f32) void {
        self.makeup_gain = @exp(@log(10.0) * db / 20.0);
    }
};

/// Soft limiter (enhanced version of existing)
pub const Limiter = struct {
    threshold: f32 = 0.8,
    makeup_gain: f32 = 1.1,
    enabled: bool = true,

    pub fn init() Limiter {
        return Limiter{};
    }

    pub fn processBuffer(self: *Limiter, buffer: []f32) void {
        if (!self.enabled) return;

        for (buffer) |*sample| {
            var s: f32 = sample.* * self.makeup_gain;

            const abs_s: f32 = @abs(s);
            if (abs_s > self.threshold) {
                const sign: f32 = if (s > 0.0) 1.0 else -1.0;
                const excess: f32 = abs_s - self.threshold;
                // Soft saturation curve
                s = sign * (self.threshold + excess / (1.0 + excess));
            }

            // Hard clip at ±1.0
            sample.* = @max(-1.0, @min(1.0, s));
        }
    }

    pub fn setThreshold(self: *Limiter, threshold: f32) void {
        self.threshold = @max(0.1, @min(1.0, threshold));
    }

    pub fn setMakeupGain(self: *Limiter, gain: f32) void {
        self.makeup_gain = @max(0.1, @min(2.0, gain));
    }
};

/// Complete vocal processing chain
pub const VoxChain = struct {
    allocator: std.mem.Allocator,
    sample_rate: f32,

    // Processing chain
    highpass: BiquadFilter,
    eq_low: BiquadFilter,
    eq_mid: BiquadFilter,
    eq_high: BiquadFilter,
    deesser: DeEsser,
    compressor: Compressor,
    limiter: Limiter,

    // Chain control
    enabled: bool = true,

    pub fn init(allocator: std.mem.Allocator, sample_rate: u32) VoxChain {
        const sr: f32 = @floatFromInt(sample_rate);

        var chain = VoxChain{
            .allocator = allocator,
            .sample_rate = sr,
            .highpass = BiquadFilter.init(),
            .eq_low = BiquadFilter.init(),
            .eq_mid = BiquadFilter.init(),
            .eq_high = BiquadFilter.init(),
            .deesser = DeEsser.init(sr),
            .compressor = Compressor.init(sr),
            .limiter = Limiter.init(),
        };

        // Set default parameters (Broadcast preset)
        chain.loadBroadcastPreset();

        return chain;
    }

    pub fn process(self: *VoxChain, buffer: []f32) void {
        if (!self.enabled) return;

        // Processing chain order:
        self.highpass.processBuffer(buffer); // 1. Remove rumble
        self.eq_low.processBuffer(buffer); // 2. Low shelf (warmth)
        self.eq_mid.processBuffer(buffer); // 3. Mid peak (presence)
        self.eq_high.processBuffer(buffer); // 4. High shelf (air)
        self.deesser.processBuffer(buffer); // 5. Tame sibilance
        self.compressor.processBuffer(buffer); // 6. Dynamic control
        self.limiter.processBuffer(buffer); // 7. Prevent clipping
    }

    // Preset management
    pub fn loadBroadcastPreset(self: *VoxChain) void {
        self.highpass.designHighpass(80.0, self.sample_rate);
        self.highpass.enabled = true;

        self.eq_low.designLowShelf(120.0, 3.0, self.sample_rate);
        self.eq_low.enabled = true;

        self.eq_mid.designPeaking(3000.0, 5.0, 2.0, self.sample_rate);
        self.eq_mid.enabled = true;

        self.eq_high.designHighShelf(10000.0, 2.0, self.sample_rate);
        self.eq_high.enabled = true;

        self.deesser.setThresholdDb(-38.0);
        self.deesser.setRatio(4.0);
        self.deesser.enabled = true;

        self.compressor.setThresholdDb(-18.0);
        self.compressor.setRatio(4.0);
        self.compressor.setAttackMs(5.0, self.sample_rate);
        self.compressor.setReleaseMs(50.0, self.sample_rate);
        self.compressor.setMakeupGainDb(6.0);
        self.compressor.enabled = true;

        self.limiter.setThreshold(0.8);
        self.limiter.setMakeupGain(1.1);
        self.limiter.enabled = true;
    }

    pub fn loadPodcastPreset(self: *VoxChain) void {
        self.highpass.designHighpass(100.0, self.sample_rate);
        self.highpass.enabled = true;

        self.eq_low.designLowShelf(150.0, 2.0, self.sample_rate);
        self.eq_low.enabled = true;

        self.eq_mid.designPeaking(2500.0, 4.0, 2.0, self.sample_rate);
        self.eq_mid.enabled = true;

        self.eq_high.designHighShelf(8000.0, 1.0, self.sample_rate);
        self.eq_high.enabled = true;

        self.deesser.setThresholdDb(-40.0);
        self.deesser.setRatio(3.0);
        self.deesser.enabled = true;

        self.compressor.setThresholdDb(-20.0);
        self.compressor.setRatio(3.0);
        self.compressor.setAttackMs(10.0, self.sample_rate);
        self.compressor.setReleaseMs(100.0, self.sample_rate);
        self.compressor.setMakeupGainDb(4.0);
        self.compressor.enabled = true;

        self.limiter.setThreshold(0.8);
        self.limiter.setMakeupGain(1.1);
        self.limiter.enabled = true;
    }

    pub fn loadGamingPreset(self: *VoxChain) void {
        self.highpass.designHighpass(120.0, self.sample_rate);
        self.highpass.enabled = true;

        self.eq_low.designLowShelf(120.0, 0.0, self.sample_rate);
        self.eq_low.enabled = false; // Flat

        self.eq_mid.designPeaking(3000.0, 8.0, 2.0, self.sample_rate);
        self.eq_mid.enabled = true; // Strong presence boost

        self.eq_high.designHighShelf(10000.0, 0.0, self.sample_rate);
        self.eq_high.enabled = false; // Flat

        self.deesser.setThresholdDb(-35.0);
        self.deesser.setRatio(3.0);
        self.deesser.enabled = true;

        self.compressor.setThresholdDb(-15.0);
        self.compressor.setRatio(2.5);
        self.compressor.setAttackMs(3.0, self.sample_rate);
        self.compressor.setReleaseMs(30.0, self.sample_rate);
        self.compressor.setMakeupGainDb(3.0);
        self.compressor.enabled = true;

        self.limiter.setThreshold(0.8);
        self.limiter.setMakeupGain(1.1);
        self.limiter.enabled = true;
    }

    pub fn loadCleanPreset(self: *VoxChain) void {
        self.highpass.designHighpass(60.0, self.sample_rate);
        self.highpass.enabled = true;

        self.eq_low.designLowShelf(120.0, 0.0, self.sample_rate);
        self.eq_low.enabled = false;

        self.eq_mid.designPeaking(2500.0, 0.0, 2.0, self.sample_rate);
        self.eq_mid.enabled = false;

        self.eq_high.designHighShelf(10000.0, 0.0, self.sample_rate);
        self.eq_high.enabled = false;

        self.deesser.setThresholdDb(-45.0);
        self.deesser.setRatio(2.0);
        self.deesser.enabled = true;

        self.compressor.setThresholdDb(-25.0);
        self.compressor.setRatio(2.0);
        self.compressor.setAttackMs(10.0, self.sample_rate);
        self.compressor.setReleaseMs(100.0, self.sample_rate);
        self.compressor.setMakeupGainDb(2.0);
        self.compressor.enabled = true;

        self.limiter.setThreshold(0.8);
        self.limiter.setMakeupGain(1.1);
        self.limiter.enabled = true;
    }

    pub fn setEnabled(self: *VoxChain, enabled: bool) void {
        self.enabled = enabled;
    }

    pub fn deinit(self: *VoxChain) void {
        _ = self;
        // Nothing to deallocate currently
    }
};
