const std = @import("std");
const Allocator = std.mem.Allocator;

// Import actual effect modules
const autotune_mod = @import("effects/autotune.zig");
const reverb_mod = @import("effects/reverb.zig");
const delay_mod = @import("effects/delay.zig");
const chorus_mod = @import("effects/chorus.zig");
const flanger_mod = @import("effects/flanger.zig");
const phaser_mod = @import("effects/phaser.zig");
const ring_mod_mod = @import("effects/ring_mod.zig");
const vocoder_mod = @import("effects/vocoder.zig");
const granular_mod = @import("effects/granular.zig");
const bit_crusher_mod = @import("effects/bit_crusher.zig");
const vocal_rider_mod = @import("effects/vocal_rider.zig");
const denoiser_mod = @import("effects/denoiser.zig");
const dynamic_eq_mod = @import("effects/dynamic_eq.zig");

// Type aliases for cleaner code
const AutoTune = autotune_mod.AutoTune;
const Reverb = reverb_mod.Reverb;
const Delay = delay_mod.Delay;
const Chorus = chorus_mod.Chorus;
const Flanger = flanger_mod.Flanger;
const Phaser = phaser_mod.Phaser;
const RingModulator = ring_mod_mod.RingModulator;
const Vocoder = vocoder_mod.Vocoder;
const Granular = granular_mod.Granular;
const BitCrusher = bit_crusher_mod.BitCrusher;
const VocalRider = vocal_rider_mod.VocalRider;
const Denoiser = denoiser_mod.Denoiser;
const DynamicEQ = dynamic_eq_mod.DynamicEQ;


pub const EffectsChain = struct {
    allocator: Allocator,
    sample_rate: u32,

    // Effect instances (nullable for those requiring allocation)
    denoiser: ?Denoiser,
    vocal_rider: VocalRider,
    dynamic_eq: ?DynamicEQ, // Soothe-style resonance suppressor
    autotune: ?AutoTune,
    reverb: ?Reverb,
    delay: ?Delay,
    chorus: ?Chorus,
    flanger: ?Flanger,
    phaser: ?Phaser,
    ring_mod: RingModulator,
    vocoder: ?Vocoder,
    granular: ?Granular,
    bit_crusher: BitCrusher,

    // Temporary processing buffer
    temp_buffer: [4096]f32,

    pub fn init(allocator: Allocator, sample_rate: u32) !EffectsChain {
        // Initialize all effects with appropriate default parameters
        const denoiser = try Denoiser.init(allocator, sample_rate, 16); // 16 bands
        const vocal_rider = VocalRider.init(sample_rate);
        const dynamic_eq = try DynamicEQ.init(allocator, sample_rate, 6); // 6-band Soothe
        const autotune = try AutoTune.init(allocator, sample_rate);
        const reverb = try Reverb.init(allocator, sample_rate);
        const delay = try Delay.init(allocator, sample_rate, 2000.0); // 2 second max delay
        const chorus = try Chorus.init(allocator, sample_rate);
        const flanger = try Flanger.init(allocator, sample_rate);
        const phaser = try Phaser.init(allocator, sample_rate, 6); // 6 stage phaser
        const ring_mod = RingModulator.init(sample_rate);
        const vocoder = try Vocoder.init(allocator, sample_rate, 16); // 16 bands
        const granular = try Granular.init(allocator, sample_rate, 500.0); // 500ms buffer
        const bit_crusher = BitCrusher.init();

        return EffectsChain{
            .allocator = allocator,
            .sample_rate = sample_rate,
            .denoiser = denoiser,
            .vocal_rider = vocal_rider,
            .dynamic_eq = dynamic_eq,
            .autotune = autotune,
            .reverb = reverb,
            .delay = delay,
            .chorus = chorus,
            .flanger = flanger,
            .phaser = phaser,
            .ring_mod = ring_mod,
            .vocoder = vocoder,
            .granular = granular,
            .bit_crusher = bit_crusher,
            .temp_buffer = undefined,
        };
    }

    pub fn deinit(self: *EffectsChain) void {
        // Deinit all allocated effects
        if (self.denoiser) |*fx| fx.deinit();
        // vocal_rider has no allocations
        if (self.dynamic_eq) |*fx| fx.deinit();
        if (self.autotune) |*fx| fx.deinit();
        if (self.reverb) |*fx| fx.deinit();
        if (self.delay) |*fx| fx.deinit();
        if (self.chorus) |*fx| fx.deinit();
        if (self.flanger) |*fx| fx.deinit();
        if (self.phaser) |*fx| fx.deinit();
        // ring_mod and bit_crusher have no allocations, no deinit needed
        if (self.vocoder) |*fx| fx.deinit();
        if (self.granular) |*fx| fx.deinit();
    }

    pub fn process(self: *EffectsChain, input: []f32, output: []f32) void {
        // Process through effect chain
        // Use temp_buffer for intermediate results
        const len = input.len;

        // Copy input to temp buffer
        @memcpy(self.temp_buffer[0..len], input);

        // Fixed order for now (can make configurable later)
        // 1. Noise reduction first (clean the signal)
        if (self.denoiser) |*fx| {
            fx.process(self.temp_buffer[0..len], self.temp_buffer[0..len]);
        }

        // 2. Vocal rider (automatic gain control)
        self.vocal_rider.process(self.temp_buffer[0..len], self.temp_buffer[0..len]);

        // 3. Dynamic EQ / Soothe (resonance suppression)
        if (self.dynamic_eq) |*fx| {
            fx.process(self.temp_buffer[0..len], self.temp_buffer[0..len]);
        }

        // 4. Pitch correction
        if (self.autotune) |*fx| {
            fx.process(self.temp_buffer[0..len], self.temp_buffer[0..len]);
        }

        // Ring modulation
        self.ring_mod.process(self.temp_buffer[0..len], self.temp_buffer[0..len]);

        // Modulation effects
        if (self.chorus) |*fx| {
            fx.process(self.temp_buffer[0..len], self.temp_buffer[0..len]);
        }

        if (self.flanger) |*fx| {
            fx.process(self.temp_buffer[0..len], self.temp_buffer[0..len]);
        }

        if (self.phaser) |*fx| {
            fx.process(self.temp_buffer[0..len], self.temp_buffer[0..len]);
        }

        // Delay
        if (self.delay) |*fx| {
            fx.process(self.temp_buffer[0..len], self.temp_buffer[0..len]);
        }

        // Reverb
        if (self.reverb) |*fx| {
            fx.process(self.temp_buffer[0..len], self.temp_buffer[0..len]);
        }

        // Special effects
        if (self.vocoder) |*fx| {
            fx.process(self.temp_buffer[0..len], self.temp_buffer[0..len]);
        }

        if (self.granular) |*fx| {
            fx.process(self.temp_buffer[0..len], self.temp_buffer[0..len]);
        }

        // Bit crushing last
        self.bit_crusher.process(self.temp_buffer[0..len], self.temp_buffer[0..len]);

        // Copy to output
        @memcpy(output, self.temp_buffer[0..len]);
    }

    // Getter methods for each effect (for WebSocket control)
    pub fn getDenoiser(self: *EffectsChain) ?*Denoiser {
        if (self.denoiser) |*fx| return fx;
        return null;
    }

    pub fn getVocalRider(self: *EffectsChain) *VocalRider {
        return &self.vocal_rider;
    }

    pub fn getDynamicEQ(self: *EffectsChain) ?*DynamicEQ {
        if (self.dynamic_eq) |*fx| return fx;
        return null;
    }

    pub fn getAutoTune(self: *EffectsChain) ?*AutoTune {
        if (self.autotune) |*fx| return fx;
        return null;
    }

    pub fn getReverb(self: *EffectsChain) ?*Reverb {
        if (self.reverb) |*fx| return fx;
        return null;
    }

    pub fn getDelay(self: *EffectsChain) ?*Delay {
        if (self.delay) |*fx| return fx;
        return null;
    }

    pub fn getChorus(self: *EffectsChain) ?*Chorus {
        if (self.chorus) |*fx| return fx;
        return null;
    }

    pub fn getFlanger(self: *EffectsChain) ?*Flanger {
        if (self.flanger) |*fx| return fx;
        return null;
    }

    pub fn getPhaser(self: *EffectsChain) ?*Phaser {
        if (self.phaser) |*fx| return fx;
        return null;
    }

    pub fn getRingMod(self: *EffectsChain) *RingModulator {
        return &self.ring_mod;
    }

    pub fn getVocoder(self: *EffectsChain) ?*Vocoder {
        if (self.vocoder) |*fx| return fx;
        return null;
    }

    pub fn getGranular(self: *EffectsChain) ?*Granular {
        if (self.granular) |*fx| return fx;
        return null;
    }

    pub fn getBitCrusher(self: *EffectsChain) *BitCrusher {
        return &self.bit_crusher;
    }
};
