# Auto-Tune Technical Deep Dive

A comprehensive technical guide to understanding and implementing pitch correction technology from first principles.

---

## Table of Contents

1. [Scientific Foundations](#1-scientific-foundations)
2. [Pitch Detection Algorithms](#2-pitch-detection-algorithms)
3. [Pitch Shifting Algorithms](#3-pitch-shifting-algorithms)
4. [Musical Theory Integration](#4-musical-theory-integration)
5. [Mathematical Formulas](#5-mathematical-formulas)
6. [Implementation Challenges](#6-implementation-challenges)
7. [Commercial Auto-Tune Techniques](#7-commercial-auto-tune-techniques)

---

## 1. Scientific Foundations

### 1.1 Physics of Sound and Pitch

Sound is a mechanical wave that propagates through a medium (air, water, solids) as a series of compressions and rarefactions. The fundamental physical properties that define sound are:

- **Frequency (f)**: Number of oscillations per second, measured in Hertz (Hz)
- **Amplitude (A)**: Magnitude of displacement, perceived as loudness
- **Phase (φ)**: Position within the oscillation cycle at a given time
- **Wavelength (λ)**: Physical distance between consecutive wave peaks

The relationship between these properties is governed by:

```
v = f × λ
```

Where `v` is the speed of sound (approximately 343 m/s in air at 20°C).

**Pitch** is the perceptual correlate of frequency - how "high" or "low" a sound appears to the human ear. While frequency is an objective physical measurement, pitch is subjective and depends on psychoacoustic factors.

### 1.2 Psychoacoustics of Pitch Perception

Human pitch perception operates through two primary mechanisms:

#### Place Theory
Pitch is determined by the location of maximum vibration along the basilar membrane in the cochlea. Different frequencies excite different regions:
- High frequencies (>4 kHz): Near the oval window (base)
- Low frequencies (<500 Hz): Near the apex

#### Temporal Theory
Pitch is encoded by the timing patterns of neural impulses. The auditory nerve fires in synchrony with the waveform, particularly for frequencies below 4-5 kHz.

**Modern Understanding**: Both mechanisms contribute to pitch perception across different frequency ranges. Place theory dominates for high frequencies, temporal theory for low frequencies, and both work together in the mid-range (500 Hz - 4 kHz).

#### Critical Bands

The basilar membrane is divided into approximately 24 overlapping frequency ranges called **critical bands**, each about 1.3 mm wide. The critical bandwidth is approximately 19% of the center frequency:

```
CB(f) ≈ 0.19 × f
```

At 1000 Hz, the critical bandwidth is about 190 Hz. Critical bands are fundamental to:
- Masking effects
- Pitch resolution
- Harmonic interaction
- Dissonance perception

#### Just Noticeable Difference (JND)

The smallest detectable change in pitch is called the Just Noticeable Difference:

- **For pure tones**: JND ≈ 0.5-1% of the frequency (5-10 Hz at 1000 Hz)
- **For complex tones**: Can be as small as 0.2% (2 Hz at 1000 Hz)
- **Relationship to critical bands**: Approximately 30 JNDs exist within each critical band

This means humans can detect pitch changes smaller than 1 cent (1/100th of a semitone) under ideal conditions, but Auto-Tune typically corrects errors larger than 10-20 cents for natural sound.

### 1.3 Harmonic Series and Fundamental Frequency

Most musical sounds are **complex tones** consisting of multiple frequency components:

#### Fundamental Frequency (f₀)
The lowest frequency component, which typically determines the perceived pitch. For a guitar string vibrating at 440 Hz, f₀ = 440 Hz (the note A4).

#### Harmonics (Overtones)
Integer multiples of the fundamental frequency:

```
Harmonic series: f₀, 2f₀, 3f₀, 4f₀, 5f₀, 6f₀, ...

For A4 (440 Hz):
  1st harmonic (fundamental): 440 Hz
  2nd harmonic: 880 Hz (A5)
  3rd harmonic: 1320 Hz (E6)
  4th harmonic: 1760 Hz (A6)
  5th harmonic: 2200 Hz (C#7)
  6th harmonic: 2640 Hz (E7)
```

**Terminology Distinction**:
- **Harmonics**: All frequency components (including the fundamental)
- **Overtones**: Only frequencies above the fundamental (harmonics 2, 3, 4, ...)

#### Timbre and Spectral Envelope

The **spectral envelope** describes the relative amplitudes of harmonics, which defines the timbre (tone color) of an instrument. For example:

- **Sawtooth wave**: Harmonics decay as 1/n (6 dB/octave)
- **Square wave**: Only odd harmonics (1, 3, 5, ...), decay as 1/n
- **Triangle wave**: Only odd harmonics, decay as 1/n²

This harmonic structure is crucial for pitch detection - algorithms must identify f₀ even when it's masked by louder harmonics.

#### Formants

**Formants** are resonant frequencies of the vocal tract that remain relatively constant regardless of pitch. They define vowel sounds:

- **Human voice**: Typically 3-5 formants in 200-4000 Hz range
- **F1** (250-850 Hz): Tongue height
- **F2** (850-2500 Hz): Tongue position (front/back)
- **F3** (1700-3500 Hz): Tongue shape

**Critical for pitch shifting**: Naive pitch shifting moves formants proportionally with pitch, creating the "chipmunk" (pitch up) or "monster" (pitch down) effect. Professional algorithms preserve formants to maintain natural voice quality.

---

## 2. Pitch Detection Algorithms

Pitch detection (also called **fundamental frequency estimation** or **f₀ estimation**) is the first critical step in Auto-Tune. The challenge: extract the fundamental frequency from a complex audio signal containing harmonics, noise, and potential polyphonic content.

### 2.1 Autocorrelation Method

The oldest and most intuitive approach, based on the principle that periodic signals correlate strongly with time-shifted versions of themselves.

#### Algorithm

```python
def autocorrelation(signal, max_lag):
    """
    Compute autocorrelation of signal up to max_lag samples.

    Args:
        signal: Input audio samples
        max_lag: Maximum time shift to test

    Returns:
        autocorr: Autocorrelation function values
    """
    N = len(signal)
    autocorr = np.zeros(max_lag)

    for lag in range(max_lag):
        # Compute correlation at this lag
        for i in range(N - lag):
            autocorr[lag] += signal[i] * signal[i + lag]

        # Normalize by number of samples
        autocorr[lag] /= (N - lag)

    return autocorr
```

#### Peak Detection

The fundamental period T₀ corresponds to the first significant peak in the autocorrelation function (excluding lag=0):

```python
def find_pitch_autocorr(signal, sample_rate, min_freq=80, max_freq=800):
    """
    Detect pitch using autocorrelation method.
    """
    # Convert frequency range to lag range
    max_lag = int(sample_rate / min_freq)
    min_lag = int(sample_rate / max_freq)

    # Compute autocorrelation
    autocorr = autocorrelation(signal, max_lag)

    # Find first peak after minimum lag
    peak_lag = min_lag + np.argmax(autocorr[min_lag:max_lag])

    # Convert lag to frequency
    if autocorr[peak_lag] > threshold:
        f0 = sample_rate / peak_lag
        return f0
    else:
        return None  # Unvoiced segment
```

#### Strengths
- Simple to understand and implement
- Works well for clean, monophonic signals
- Computationally efficient: O(N log N) with FFT-based implementation

#### Weaknesses
- **Octave errors**: May detect 2f₀ or f₀/2 instead of f₀
- **Harmonic interference**: Strong harmonics can create spurious peaks
- **Poor performance with noise**: Low SNR degrades correlation peaks
- **Endpoint bias**: Autocorrelation decreases with lag due to fewer samples

### 2.2 YIN Algorithm

YIN (2002) by de Cheveigné and Kawahara is an improved autocorrelation method that addresses many weaknesses of standard autocorrelation through clever modifications.

#### Key Innovation: Difference Function

Instead of computing correlation (similarity), YIN computes the **squared difference**:

```python
def yin_difference_function(signal, max_lag):
    """
    Step 1: Compute difference function.

    d(τ) = Σ(x[i] - x[i+τ])²
    """
    N = len(signal)
    df = np.zeros(max_lag)

    for tau in range(max_lag):
        for i in range(N - max_lag):
            df[tau] += (signal[i] - signal[i + tau]) ** 2

    return df
```

This function approaches zero at lags corresponding to the period (where signal correlates with itself), avoiding the decreasing trend of autocorrelation.

#### Cumulative Mean Normalized Difference Function (CMNDF)

The breakthrough of YIN: normalize by the cumulative mean to suppress harmonic peaks:

```python
def yin_cumulative_mean_normalized_difference(df):
    """
    Step 2: Compute cumulative mean normalized difference function.

    d'(τ) = d(τ) / [(1/τ) Σ(j=1 to τ) d(j)]
    """
    cmndf = np.zeros_like(df)
    cmndf[0] = 1.0

    cumsum = 0.0
    for tau in range(1, len(df)):
        cumsum += df[tau]
        cmndf[tau] = df[tau] / (cumsum / tau) if cumsum > 0 else 1.0

    return cmndf
```

This normalization amplifies the true pitch period while suppressing harmonic peaks.

#### Absolute Threshold and Parabolic Interpolation

```python
def yin_pitch_detection(signal, sample_rate, min_freq=80, max_freq=800, threshold=0.1):
    """
    Complete YIN algorithm implementation.
    """
    # Step 1: Difference function
    max_lag = int(sample_rate / min_freq)
    min_lag = int(sample_rate / max_freq)
    df = yin_difference_function(signal, max_lag)

    # Step 2: CMNDF
    cmndf = yin_cumulative_mean_normalized_difference(df)

    # Step 3: Absolute threshold
    # Find first valley below threshold after min_lag
    for tau in range(min_lag, max_lag):
        if cmndf[tau] < threshold:
            # Check if this is a local minimum
            if tau + 1 < max_lag and cmndf[tau] < cmndf[tau + 1]:
                # Step 4: Parabolic interpolation for sub-sample accuracy
                if tau > 0 and tau < max_lag - 1:
                    better_tau = tau + parabolic_interpolation(
                        cmndf[tau - 1], cmndf[tau], cmndf[tau + 1]
                    )
                    f0 = sample_rate / better_tau
                    return f0

    return None  # No pitch detected


def parabolic_interpolation(y0, y1, y2):
    """
    Find sub-sample peak/valley position using parabolic fit.

    Returns offset from middle point (-0.5 to +0.5).
    """
    return 0.5 * (y0 - y2) / (y0 - 2*y1 + y2)
```

#### Performance Characteristics

According to the original paper:
- **Error rate**: 0.5% (vs. 17% for standard autocorrelation)
- **Latency**: Typically 2048 samples at 44.1 kHz ≈ 46 ms
- **Computational cost**: O(N²) naively, O(N log N) with FFT optimization
- **Best for**: Monophonic vocals and instruments

#### Why YIN is Superior

1. **Difference function eliminates decay**: No endpoint bias
2. **CMNDF suppresses harmonics**: Reduces octave errors by factor of 3
3. **Absolute threshold**: Robust voiced/unvoiced detection
4. **Parabolic interpolation**: Sub-sample accuracy (~0.01% frequency precision)

### 2.3 SWIPE Algorithm

SWIPE (Sawtooth Waveform Inspired Pitch Estimator) by Camacho and Harris (2008) takes a frequency-domain approach, matching the spectrum to an idealized sawtooth wave.

#### Core Concept

Natural musical sounds have harmonic spectra similar to a sawtooth wave, where harmonic amplitudes decay as 1/f. SWIPE finds the frequency where the spectrum best matches this pattern.

#### Algorithm Steps

```python
def swipe_pitch_detection(signal, sample_rate, min_freq=80, max_freq=800):
    """
    SWIPE algorithm for pitch detection.

    Finds pitch by matching spectrum to sawtooth-like harmonic pattern.
    """
    # Step 1: Compute spectrum using STFT
    window_size = 2048
    hop_size = window_size // 4
    spectrum = np.abs(librosa.stft(signal, n_fft=window_size, hop_length=hop_size))

    # Step 2: Define candidate pitches (log-spaced)
    num_candidates = 100
    candidate_freqs = np.logspace(np.log10(min_freq), np.log10(max_freq), num_candidates)

    # Step 3: For each candidate, compute strength
    strength = np.zeros((num_candidates, spectrum.shape[1]))

    for i, f0 in enumerate(candidate_freqs):
        # Generate kernel: square root of main lobes of Hann-windowed sawtooth
        kernel = generate_swipe_kernel(f0, sample_rate, window_size)

        # Compute inner product between spectrum and kernel
        for t in range(spectrum.shape[1]):
            strength[i, t] = np.sum(spectrum[:, t] * kernel)

    # Step 4: Find frequency with maximum strength at each time
    pitch_contour = candidate_freqs[np.argmax(strength, axis=0)]

    return pitch_contour


def generate_swipe_kernel(f0, sample_rate, fft_size):
    """
    Generate SWIPE kernel for fundamental frequency f0.

    The kernel has peaks at harmonics with amplitude decaying as 1/sqrt(n).
    """
    kernel = np.zeros(fft_size // 2 + 1)
    freq_bins = np.fft.rfftfreq(fft_size, 1/sample_rate)

    # Add peaks at each harmonic
    max_harmonic = int(sample_rate / (2 * f0))
    for n in range(1, max_harmonic + 1):
        harmonic_freq = n * f0
        # Find nearest bin
        bin_idx = np.argmin(np.abs(freq_bins - harmonic_freq))
        # Amplitude decays as 1/sqrt(n) to match sawtooth spectrum
        kernel[bin_idx] = 1.0 / np.sqrt(n)

    # Apply cosine taper
    kernel = kernel * np.sqrt(np.hanning(len(kernel)))

    return kernel
```

#### Performance Characteristics

- **Accuracy**: Comparable to or better than YIN
- **Latency**: Depends on FFT size (typically 20-50 ms)
- **Computational cost**: O(N log N × M) where M is number of candidate frequencies
- **Robustness**: Excellent with noise and reverberation
- **Best for**: Speech and music with harmonic structure

#### Advantages

1. **Spectral matching**: More robust to noise than time-domain methods
2. **No octave errors**: Explicitly models harmonic relationships
3. **Multi-pitch extension**: Can be adapted for polyphonic signals
4. **Frequency resolution**: Can detect very small pitch changes

### 2.4 Cepstral Analysis

The **cepstrum** is a technique that separates the vocal tract filter (formants) from the excitation signal (pitch) by operating in a "quefrency" domain.

#### Mathematical Foundation

```
Cepstrum = IFFT(log(|FFT(signal)|))
```

The cepstrum is the "spectrum of the spectrum" - Fourier analysis applied twice.

#### Why It Works for Pitch

1. **Time domain**: Signal = pitch excitation × vocal tract resonance (convolution)
2. **Frequency domain**: Spectrum = excitation spectrum × formant envelope (multiplication)
3. **Log spectrum**: Log spectrum = log(excitation) + log(formants) (addition)
4. **Cepstral domain**: Components are separated additively

In the cepstrum:
- **Low quefrencies** (0-3 ms): Spectral envelope (formants)
- **High quefrencies** (5-20 ms): Periodic excitation (pitch)
- **Peak in high quefrency region**: Corresponds to pitch period

#### Algorithm

```python
def cepstral_pitch_detection(signal, sample_rate, min_freq=80, max_freq=800):
    """
    Pitch detection using cepstral analysis.
    """
    # Step 1: Compute power spectrum
    fft_size = len(signal)
    spectrum = np.fft.rfft(signal)
    power_spectrum = np.abs(spectrum) ** 2

    # Step 2: Log of power spectrum (add small constant to avoid log(0))
    log_spectrum = np.log(power_spectrum + 1e-10)

    # Step 3: Inverse FFT to get cepstrum
    cepstrum = np.fft.irfft(log_spectrum)

    # Step 4: Search for peak in valid quefrency range
    min_quefrency = int(sample_rate / max_freq)  # samples
    max_quefrency = int(sample_rate / min_freq)

    # Find peak in high-quefrency region
    peak_quefrency = min_quefrency + np.argmax(cepstrum[min_quefrency:max_quefrency])

    # Convert quefrency to frequency
    f0 = sample_rate / peak_quefrency

    return f0
```

#### Liftering

A **lifter** is a filter in the cepstral domain (analogous to a filter in frequency domain):

```python
def low_pass_lifter(cepstrum, cutoff_quefrency):
    """
    Apply low-pass lifter to extract spectral envelope.
    """
    liftered = cepstrum.copy()
    liftered[cutoff_quefrency:] = 0
    return liftered


def high_pass_lifter(cepstrum, cutoff_quefrency):
    """
    Apply high-pass lifter to extract pitch excitation.
    """
    liftered = cepstrum.copy()
    liftered[:cutoff_quefrency] = 0
    return liftered
```

#### Applications in Auto-Tune

Cepstral analysis is used in Auto-Tune for:
1. **Pitch detection**: Finding f₀ from quefrency peak
2. **Formant extraction**: Low-pass liftering for formant preservation
3. **Voiced/unvoiced discrimination**: Peak magnitude indicates periodicity

### 2.5 Algorithm Comparison

| Algorithm | Accuracy | Latency | CPU Cost | Octave Errors | Noise Robustness | Best Use Case |
|-----------|----------|---------|----------|---------------|------------------|---------------|
| **Autocorrelation** | Moderate | Low (10-20 ms) | Low | High | Poor | Clean monophonic signals |
| **YIN** | Excellent | Moderate (20-50 ms) | Moderate | Very Low | Good | Vocals, monophonic instruments |
| **SWIPE** | Excellent | Moderate (20-50 ms) | High | None | Excellent | Noisy/reverberant environments |
| **Cepstral** | Good | Moderate (20-50 ms) | Moderate | Low | Good | Speech processing, formant analysis |

#### Real-Time Trade-offs

For live Auto-Tune (latency < 10 ms), simplified algorithms are needed:
- **Fast autocorrelation**: FFT-based, small windows (512 samples ≈ 11 ms at 44.1 kHz)
- **YIN-lite**: Reduced lag range, no parabolic interpolation
- **Hybrid approach**: Fast detection with slow refinement

For studio processing (offline), accuracy trumps speed:
- **Multi-pass analysis**: YIN + SWIPE consensus
- **Pitch smoothing**: Median filtering across time
- **Manual correction**: User-assisted for difficult passages

---

## 3. Pitch Shifting Algorithms

Once pitch is detected, the second challenge is **shifting** it to the target frequency while maintaining audio quality. Naive approaches (e.g., changing playback speed) alter both pitch and duration - not acceptable for Auto-Tune.

The goal: **Independent control of pitch and duration**

### 3.1 Time-Domain: PSOLA (Pitch Synchronous Overlap-Add)

PSOLA, invented around 1986, is the gold standard for time-domain pitch shifting. It manipulates pitch by adjusting the spacing between pitch-synchronous analysis windows.

#### Core Concept

1. **Segment** the signal at **pitch marks** (vocal cord closure moments or waveform peaks)
2. **Extract** windows centered on each pitch mark
3. **Shift** windows closer (pitch up) or farther (pitch down)
4. **Overlap-add** to reconstruct the signal

#### TD-PSOLA Algorithm

```python
def td_psola(signal, sample_rate, pitch_marks, pitch_shift_ratio):
    """
    Time-Domain Pitch Synchronous Overlap-Add.

    Args:
        signal: Input audio samples
        sample_rate: Sampling rate in Hz
        pitch_marks: Array of sample indices where pitch periods begin
        pitch_shift_ratio: Target pitch / original pitch (e.g., 1.5 = shift up 7 semitones)

    Returns:
        shifted_signal: Pitch-shifted audio
    """
    # Step 1: Extract pitch-synchronous grains
    grains = []
    for i, mark in enumerate(pitch_marks):
        if i == 0 or i == len(pitch_marks) - 1:
            continue

        # Window size = 2 pitch periods
        prev_period = mark - pitch_marks[i - 1]
        next_period = pitch_marks[i + 1] - mark
        window_size = prev_period + next_period

        # Extract grain centered on pitch mark
        start = max(0, mark - prev_period)
        end = min(len(signal), mark + next_period)
        grain = signal[start:end]

        # Apply Hann window
        window = np.hanning(len(grain))
        grain = grain * window

        grains.append({
            'samples': grain,
            'center': mark,
            'period': (prev_period + next_period) / 2
        })

    # Step 2: Resynthesize with new pitch period
    output_length = int(len(signal) / pitch_shift_ratio)
    output = np.zeros(output_length)

    # New spacing between grains
    original_period = np.mean([g['period'] for g in grains])
    new_period = original_period / pitch_shift_ratio

    output_position = 0
    for grain in grains:
        # Place grain at new position
        start_idx = int(output_position - len(grain['samples']) / 2)
        end_idx = start_idx + len(grain['samples'])

        if start_idx >= 0 and end_idx <= len(output):
            output[start_idx:end_idx] += grain['samples']

        output_position += new_period

    return output
```

#### Pitch Mark Detection

Accurate pitch marks are critical. Common approaches:

```python
def detect_pitch_marks(signal, sample_rate, f0_contour):
    """
    Detect pitch marks (glottal closure instants) using peak picking.

    Args:
        signal: Input audio
        sample_rate: Sampling rate
        f0_contour: Estimated fundamental frequency over time

    Returns:
        pitch_marks: Array of sample indices
    """
    pitch_marks = []
    position = 0

    for f0 in f0_contour:
        if f0 is None or f0 == 0:
            # Unvoiced segment - skip
            position += int(sample_rate / 100)  # 10 ms hop
            continue

        # Expected period
        period = int(sample_rate / f0)

        # Search for peak in next period
        search_start = position
        search_end = min(len(signal), position + period)

        if search_end > search_start:
            local_signal = signal[search_start:search_end]
            local_peak = np.argmax(np.abs(local_signal))
            pitch_marks.append(search_start + local_peak)
            position = search_start + local_peak

    return np.array(pitch_marks)
```

#### Strengths

- **High quality for small shifts**: ±7 semitones (pitch ratio 0.7 to 1.5)
- **Low latency**: Can be real-time with lookahead buffering
- **Formant preservation**: Automatically maintains spectral envelope
- **Transient preservation**: Pitch marks align with signal structure

#### Weaknesses

- **Large shifts degrade quality**: >1 octave produces audible artifacts
- **Requires accurate pitch tracking**: Errors in pitch marks cause glitches
- **Voiced segments only**: Doesn't work for percussion or noise
- **Not suitable for polyphonic material**: Needs monophonic signal

### 3.2 Frequency-Domain: Phase Vocoder

The **phase vocoder** uses the Short-Time Fourier Transform (STFT) to manipulate frequency content directly. It's the workhorse of modern pitch shifting.

#### STFT Background

The STFT divides a signal into overlapping windows and computes the FFT of each:

```python
def stft(signal, window_size=2048, hop_size=512):
    """
    Compute Short-Time Fourier Transform.

    Returns:
        stft_matrix: Complex STFT (frequency bins × time frames)
    """
    num_frames = (len(signal) - window_size) // hop_size + 1
    num_bins = window_size // 2 + 1

    stft_matrix = np.zeros((num_bins, num_frames), dtype=complex)
    window = np.hanning(window_size)

    for frame_idx in range(num_frames):
        start = frame_idx * hop_size
        end = start + window_size

        frame = signal[start:end] * window
        spectrum = np.fft.rfft(frame)
        stft_matrix[:, frame_idx] = spectrum

    return stft_matrix
```

#### Phase Vocoder for Time Stretching

First, understand time stretching (changing duration without pitch):

```python
def phase_vocoder_time_stretch(stft_matrix, stretch_ratio, hop_size=512):
    """
    Time-stretch using phase vocoder.

    Args:
        stft_matrix: Input STFT
        stretch_ratio: Output duration / input duration (e.g., 2.0 = twice as long)
        hop_size: Analysis hop size

    Returns:
        stretched_stft: Time-stretched STFT
    """
    num_bins, num_frames = stft_matrix.shape
    synthesis_hop = int(hop_size * stretch_ratio)

    # Compute instantaneous frequencies
    phase_advance = np.angle(stft_matrix[:, 1:] * np.conj(stft_matrix[:, :-1]))

    # Expected phase advance for each bin
    bin_freqs = 2 * np.pi * hop_size * np.arange(num_bins) / (2 * (num_bins - 1))
    expected_phase = bin_freqs.reshape(-1, 1)

    # Compute frequency deviation
    freq_deviation = phase_advance - expected_phase

    # Unwrap to [-π, π]
    freq_deviation = np.angle(np.exp(1j * freq_deviation))

    # True instantaneous frequency
    inst_freq = bin_freqs.reshape(-1, 1) + freq_deviation

    # Reconstruct with new hop size
    output_frames = int(num_frames / stretch_ratio)
    stretched_stft = np.zeros((num_bins, output_frames), dtype=complex)

    phase_accumulator = np.angle(stft_matrix[:, 0])

    for out_idx in range(output_frames):
        # Corresponding input frame (non-integer)
        in_idx = out_idx * stretch_ratio
        in_idx_int = int(in_idx)

        if in_idx_int >= num_frames - 1:
            break

        # Interpolate magnitude
        alpha = in_idx - in_idx_int
        magnitude = (1 - alpha) * np.abs(stft_matrix[:, in_idx_int]) + \
                    alpha * np.abs(stft_matrix[:, in_idx_int + 1])

        # Update phase accumulator
        phase_accumulator += synthesis_hop * inst_freq[:, in_idx_int]

        # Construct output frame
        stretched_stft[:, out_idx] = magnitude * np.exp(1j * phase_accumulator)

    return stretched_stft
```

#### Pitch Shifting with Phase Vocoder

To shift pitch by ratio `p`:
1. **Time-stretch** by factor `p` (makes audio slower/faster)
2. **Resample** by factor `1/p` (returns to original duration, changes pitch)

```python
def phase_vocoder_pitch_shift(signal, sample_rate, pitch_ratio):
    """
    Pitch shift using phase vocoder + resampling.

    Args:
        signal: Input audio
        sample_rate: Sampling rate
        pitch_ratio: Target pitch / original pitch

    Returns:
        shifted_signal: Pitch-shifted audio
    """
    # Step 1: STFT
    stft_matrix = stft(signal, window_size=2048, hop_size=512)

    # Step 2: Time-stretch by pitch_ratio
    stretched_stft = phase_vocoder_time_stretch(stft_matrix, pitch_ratio, hop_size=512)

    # Step 3: Inverse STFT
    stretched_signal = istft(stretched_stft, hop_size=int(512 * pitch_ratio))

    # Step 4: Resample to original duration
    shifted_signal = resample(stretched_signal, 1.0 / pitch_ratio)

    return shifted_signal
```

#### Formant Preservation in Phase Vocoder

To avoid the chipmunk effect, the spectral envelope must be preserved:

```python
def phase_vocoder_pitch_shift_with_formants(signal, sample_rate, pitch_ratio):
    """
    Pitch shift with formant preservation using spectral envelope extraction.
    """
    # Step 1: Compute STFT
    stft_matrix = stft(signal)
    magnitude = np.abs(stft_matrix)
    phase = np.angle(stft_matrix)

    # Step 2: Extract spectral envelope (formants) using cepstral liftering
    spectral_envelope = extract_spectral_envelope(magnitude)

    # Step 3: Flatten spectrum (remove formants)
    flattened_magnitude = magnitude / (spectral_envelope + 1e-6)

    # Step 4: Time-stretch flattened spectrum
    flattened_stft = flattened_magnitude * np.exp(1j * phase)
    stretched_stft = phase_vocoder_time_stretch(flattened_stft, pitch_ratio)

    # Step 5: Inverse STFT and resample
    stretched_signal = istft(stretched_stft, hop_size=int(512 * pitch_ratio))
    resampled_signal = resample(stretched_signal, 1.0 / pitch_ratio)

    # Step 6: Re-apply original spectral envelope
    resampled_stft = stft(resampled_signal)
    resampled_magnitude = np.abs(resampled_stft)
    formant_corrected_magnitude = resampled_magnitude * spectral_envelope

    output_stft = formant_corrected_magnitude * np.exp(1j * np.angle(resampled_stft))
    output_signal = istft(output_stft)

    return output_signal


def extract_spectral_envelope(magnitude_spectrum):
    """
    Extract smooth spectral envelope using cepstral liftering.
    """
    # Convert to log domain
    log_magnitude = np.log(magnitude_spectrum + 1e-10)

    # Apply inverse FFT to get cepstrum
    cepstrum = np.fft.irfft(log_magnitude, axis=0)

    # Low-pass lifter (keep only low quefrencies)
    lifter_cutoff = 30  # quefrency samples
    cepstrum[lifter_cutoff:] = 0

    # FFT back to log spectrum (this is the envelope)
    envelope_log = np.fft.rfft(cepstrum, axis=0)

    # Convert back to linear
    envelope = np.exp(envelope_log.real)

    return envelope
```

#### Strengths

- **Arbitrary pitch shifts**: Can handle extreme shifts (±2 octaves)
- **Polyphonic capability**: Works on complex mixtures
- **Frequency manipulation**: Can modify individual harmonics
- **Formant control**: Explicit envelope preservation

#### Weaknesses

- **Phasiness artifacts**: Loss of phase coherence creates "smeared" sound
- **Transient smearing**: Sharp attacks become blurred
- **High latency**: Requires larger windows (50-100 ms) for quality
- **Computational cost**: High CPU usage for real-time processing

### 3.3 Granular Synthesis Approach

Granular synthesis treats audio as a stream of tiny "grains" (1-50 ms) that can be manipulated individually.

#### Basic Granular Pitch Shifting

```python
def granular_pitch_shift(signal, sample_rate, pitch_ratio, grain_size_ms=20):
    """
    Pitch shift using granular synthesis.

    Args:
        signal: Input audio
        sample_rate: Sampling rate
        pitch_ratio: Pitch shift ratio
        grain_size_ms: Grain duration in milliseconds

    Returns:
        shifted_signal: Pitch-shifted audio
    """
    grain_samples = int(grain_size_ms * sample_rate / 1000)
    hop_samples = grain_samples // 2  # 50% overlap

    # Read grains from input with pitch-dependent spacing
    input_hop = int(hop_samples / pitch_ratio)
    output_hop = hop_samples

    output = np.zeros(len(signal))
    window = np.hanning(grain_samples)

    input_pos = 0
    output_pos = 0

    while input_pos + grain_samples < len(signal):
        # Extract grain from input
        grain = signal[input_pos:input_pos + grain_samples] * window

        # Write to output
        if output_pos + grain_samples < len(output):
            output[output_pos:output_pos + grain_samples] += grain

        input_pos += input_hop
        output_pos += output_hop

    # Normalize
    output = output / np.max(np.abs(output))

    return output
```

#### Advanced: Pitch-Preserving Time Stretch

Granular synthesis excels at independent time/pitch manipulation:

```python
def granular_time_pitch_shift(signal, sample_rate, time_ratio, pitch_ratio, grain_size_ms=30):
    """
    Independent time stretching and pitch shifting.

    Args:
        time_ratio: Output duration / input duration
        pitch_ratio: Output pitch / input pitch
    """
    grain_samples = int(grain_size_ms * sample_rate / 1000)
    window = np.hanning(grain_samples)

    # For time stretching: adjust output hop
    input_hop = grain_samples // 2
    output_hop = int(input_hop * time_ratio)

    # For pitch shifting: resample each grain
    output_length = int(len(signal) * time_ratio)
    output = np.zeros(output_length)

    input_pos = 0
    output_pos = 0

    while input_pos + grain_samples < len(signal) and output_pos < output_length:
        # Extract grain
        grain = signal[input_pos:input_pos + grain_samples]

        # Pitch shift grain by resampling
        shifted_grain = resample(grain, pitch_ratio)
        shifted_grain *= window[:len(shifted_grain)]

        # Overlap-add to output
        end_pos = min(output_pos + len(shifted_grain), output_length)
        output[output_pos:end_pos] += shifted_grain[:end_pos - output_pos]

        input_pos += input_hop
        output_pos += output_hop

    return output
```

#### Strengths

- **Flexibility**: Easy to implement time/pitch independence
- **Simplicity**: Conceptually straightforward
- **Real-time friendly**: Low algorithmic latency
- **Creative effects**: Grain randomization, pitch scatter

#### Weaknesses

- **Tonal smearing**: Overlapping grains blur pitch definition
- **Artifacts with small grains**: < 10 ms causes metallic sound
- **Artifacts with large grains**: > 50 ms causes stuttering
- **Poorer quality than PSOLA/phase vocoder**: For precision pitch correction

### 3.4 Trade-offs Summary

```
                    Quality Spectrum
Low Latency                              High Quality
     |                                        |
     v                                        v
[Granular] -----> [PSOLA] -----> [Phase Vocoder]
  1-5 ms           10-20 ms         50-100 ms

  Simple           Moderate         Complex
  artifacts        artifacts        artifacts
```

**For Auto-Tune:**
- **Live performance**: PSOLA or hybrid (fast detection + PSOLA shift)
- **Studio production**: Phase vocoder with formant preservation
- **Extreme effects ("T-Pain" sound)**: Fast, aggressive pitch snapping (artifacts are desirable)

---

## 4. Musical Theory Integration

Auto-Tune must translate detected frequencies into musical notes and apply corrections according to musical rules.

### 4.1 MIDI Note Numbers and Frequency Mapping

The MIDI standard defines note number 69 as A4 = 440 Hz (in equal temperament tuning).

#### Fundamental Formulas

**Frequency to MIDI:**
```
M = 69 + 12 × log₂(f / 440)
```

**MIDI to Frequency:**
```
f = 440 × 2^((M - 69) / 12)
```

**Cents (1/100th of a semitone):**
```
cents = 1200 × log₂(f₁ / f₂)
```

#### Implementation

```python
def freq_to_midi(freq):
    """Convert frequency in Hz to MIDI note number (fractional)."""
    return 69 + 12 * np.log2(freq / 440.0)


def midi_to_freq(midi):
    """Convert MIDI note number to frequency in Hz."""
    return 440.0 * (2 ** ((midi - 69) / 12))


def freq_to_cents(freq, ref_freq):
    """Calculate pitch difference in cents."""
    return 1200 * np.log2(freq / ref_freq)


def nearest_midi_note(freq):
    """Find nearest MIDI note to given frequency."""
    midi_float = freq_to_midi(freq)
    return round(midi_float)


def pitch_error_in_cents(freq, target_freq):
    """Calculate how many cents off from target."""
    return freq_to_cents(freq, target_freq)
```

#### Example Calculations

```python
# A4 = 440 Hz
>>> freq_to_midi(440)
69.0

# C5 (5 semitones above A4)
>>> midi_to_freq(69 + 5)
523.25  # Hz

# Singer hits 445 Hz (slightly sharp A4)
>>> freq_to_cents(445, 440)
19.56  # cents sharp

# Semitone ratio
>>> 2 ** (1/12)
1.0594630943592953  # ~5.95% frequency increase per semitone
```

### 4.2 Musical Scales and Key Signatures

Auto-Tune must know which notes are "correct" in a given key.

#### Major Scale Construction

The major scale follows the pattern: **W-W-H-W-W-W-H** (W=whole step, H=half step)

```python
# Major scale intervals (in semitones from root)
MAJOR_SCALE = [0, 2, 4, 5, 7, 9, 11]  # C major: C D E F G A B

# Minor scale (natural minor)
NATURAL_MINOR_SCALE = [0, 2, 3, 5, 7, 8, 10]  # A minor: A B C D E F G

# Chromatic scale (all 12 notes)
CHROMATIC_SCALE = list(range(12))
```

#### Scale Generation

```python
def generate_scale(root_midi, scale_intervals):
    """
    Generate all valid MIDI notes in a scale.

    Args:
        root_midi: MIDI number of root note (e.g., 60 for C4)
        scale_intervals: List of intervals (e.g., MAJOR_SCALE)

    Returns:
        valid_notes: Set of all valid MIDI notes
    """
    valid_notes = set()

    # Generate scale across all octaves (MIDI 0-127)
    for octave in range(-1, 10):
        for interval in scale_intervals:
            note = root_midi + (octave * 12) + interval
            if 0 <= note <= 127:
                valid_notes.add(note)

    return valid_notes


# Example: C major scale
c_major_notes = generate_scale(root_midi=60, scale_intervals=MAJOR_SCALE)
# Result: {0, 2, 4, 5, 7, 9, 11, 12, 14, 16, 17, ...} (C, D, E, F, G, A, B, C, ...)
```

#### Note Quantization

```python
def quantize_to_scale(input_freq, valid_midi_notes):
    """
    Snap frequency to nearest note in scale.

    Args:
        input_freq: Detected frequency in Hz
        valid_midi_notes: Set of valid MIDI note numbers

    Returns:
        target_freq: Corrected frequency
        target_midi: Corrected MIDI note number
        correction_cents: How many cents the pitch will be shifted
    """
    # Convert frequency to MIDI (fractional)
    input_midi = freq_to_midi(input_freq)

    # Find nearest valid note
    valid_notes_list = sorted(list(valid_midi_notes))
    distances = [abs(input_midi - note) for note in valid_notes_list]
    nearest_idx = np.argmin(distances)
    target_midi = valid_notes_list[nearest_idx]

    # Convert back to frequency
    target_freq = midi_to_freq(target_midi)

    # Calculate correction amount
    correction_cents = freq_to_cents(target_freq, input_freq)

    return target_freq, target_midi, correction_cents
```

### 4.3 Retune Speed and Correction Amount

These parameters control how aggressively Auto-Tune corrects pitch.

#### Retune Speed

**Retune Speed** determines how quickly pitch correction is applied (in milliseconds):

- **0 ms** ("Hard Tune" / T-Pain effect): Instant correction, robotic sound
- **10-20 ms**: Fast correction, natural for sustained notes
- **50-100 ms**: Slow correction, preserves vibrato and expressive pitch bends
- **200+ ms**: Very subtle, only fixes large errors

```python
def apply_retune_speed(current_freq, target_freq, retune_speed_ms, sample_rate):
    """
    Smooth pitch correction over time using exponential approach.

    Args:
        current_freq: Current frequency
        target_freq: Desired frequency
        retune_speed_ms: Time constant in milliseconds
        sample_rate: Audio sample rate

    Returns:
        correction_factor: Multiplier for gradual pitch shift
    """
    if retune_speed_ms == 0:
        # Instant correction
        return target_freq / current_freq

    # Time constant in samples
    tau = (retune_speed_ms / 1000.0) * sample_rate

    # Exponential smoothing coefficient
    alpha = 1.0 - np.exp(-1.0 / tau)

    # Correction factor approaches target
    correction_factor = current_freq / current_freq  # Start at 1.0
    correction_factor += alpha * (target_freq / current_freq - 1.0)

    return correction_factor
```

#### Correction Amount (Strength)

**Correction Amount** (0-100%) determines how far toward the target to correct:

- **100%**: Full correction to nearest scale note
- **50%**: Halfway between detected pitch and target
- **0%**: No correction (bypass)

```python
def apply_correction_amount(input_freq, target_freq, correction_amount):
    """
    Partially correct pitch based on strength parameter.

    Args:
        input_freq: Detected frequency
        target_freq: Target frequency (nearest scale note)
        correction_amount: 0.0 to 1.0 (0% to 100%)

    Returns:
        corrected_freq: Frequency after partial correction
    """
    # Logarithmic interpolation (correct in pitch space, not frequency space)
    input_midi = freq_to_midi(input_freq)
    target_midi = freq_to_midi(target_freq)

    corrected_midi = input_midi + correction_amount * (target_midi - input_midi)
    corrected_freq = midi_to_freq(corrected_midi)

    return corrected_freq
```

#### Vibrato Preservation

Natural vibrato (periodic pitch modulation) should be preserved:

```python
def detect_vibrato(pitch_contour, sample_rate, window_size=0.5):
    """
    Detect vibrato to avoid over-correction.

    Args:
        pitch_contour: Array of pitch values over time
        sample_rate: Sample rate
        window_size: Analysis window in seconds

    Returns:
        is_vibrato: Boolean indicating vibrato presence
        vibrato_rate: Vibrato frequency in Hz (if detected)
    """
    window_samples = int(window_size * sample_rate)

    if len(pitch_contour) < window_samples:
        return False, 0.0

    # Convert to cents relative to mean
    mean_pitch = np.mean(pitch_contour)
    pitch_in_cents = freq_to_cents(pitch_contour, mean_pitch)

    # Check for periodic modulation
    fft = np.fft.rfft(pitch_in_cents)
    freqs = np.fft.rfftfreq(len(pitch_in_cents), 1.0 / sample_rate)

    # Typical vibrato: 4-7 Hz, 50-200 cents width
    vibrato_range = (freqs >= 4) & (freqs <= 7)
    if np.any(vibrato_range):
        peak_idx = np.argmax(np.abs(fft[vibrato_range]))
        vibrato_rate = freqs[vibrato_range][peak_idx]
        vibrato_depth = np.max(np.abs(pitch_in_cents))

        if vibrato_depth > 20:  # cents
            return True, vibrato_rate

    return False, 0.0
```

---

## 5. Mathematical Formulas

### 5.1 Core Pitch Detection

**Autocorrelation:**
```
R(τ) = Σ(t=0 to N-τ-1) x[t] × x[t+τ]
```

**YIN Difference Function:**
```
d(τ) = Σ(t=0 to N-τ-1) (x[t] - x[t+τ])²
```

**YIN Cumulative Mean Normalized Difference:**
```
d'(τ) = d(τ) / [(1/τ) × Σ(j=1 to τ) d(j)]

Special case: d'(0) = 1
```

**Cepstrum:**
```
C(quefrency) = IFFT(log(|FFT(x)|))
```

### 5.2 Frequency-MIDI Conversion

**Frequency to MIDI (equal temperament):**
```
M = 69 + 12 × log₂(f / 440)

Where:
  M = MIDI note number
  f = frequency in Hz
  69 = MIDI number for A4
  440 = reference frequency for A4 in Hz
```

**MIDI to Frequency:**
```
f = 440 × 2^((M - 69) / 12)
```

**Frequency Ratio for Semitone:**
```
semitone_ratio = 2^(1/12) ≈ 1.059463

f(n+1) = f(n) × semitone_ratio
```

**Cents (pitch deviation):**
```
cents = 1200 × log₂(f₁ / f₂)

Where:
  1200 cents = 1 octave
  100 cents = 1 semitone
```

### 5.3 STFT and Phase Vocoder

**Short-Time Fourier Transform:**
```
X(k, m) = Σ(n=0 to N-1) x[n + mH] × w[n] × e^(-j2πkn/N)

Where:
  k = frequency bin
  m = time frame
  H = hop size
  w[n] = window function (Hann, Hamming, etc.)
  N = FFT size
```

**Instantaneous Frequency:**
```
ω(k, m) = ω_k + (φ(k, m) - φ(k, m-1) - ω_k × H) / H

Where:
  ω_k = 2πk/N (expected phase advance for bin k)
  φ(k, m) = angle(X(k, m))
  H = hop size
```

**Phase Propagation:**
```
φ_out(k, m) = φ_out(k, m-1) + ω(k, m) × H_syn

Where:
  H_syn = synthesis hop size
```

### 5.4 Window Functions

**Hann (Hanning) Window:**
```
w[n] = 0.5 × (1 - cos(2πn / (N-1)))    for n = 0, 1, ..., N-1
```

**Hamming Window:**
```
w[n] = 0.54 - 0.46 × cos(2πn / (N-1))  for n = 0, 1, ..., N-1
```

**COLA Constraint (Constant Overlap-Add):**
```
Σ(m=-∞ to ∞) w[n - mH] = constant

For Hann window with 50% overlap (H = N/2): COLA satisfied
For Hann window with 75% overlap (H = N/4): COLA satisfied
```

### 5.5 PSOLA Time/Pitch Modification

**Pitch Modification:**
```
T_synthesis = T_analysis / pitch_ratio

Where:
  T_analysis = original period between pitch marks
  T_synthesis = new spacing for overlap-add
  pitch_ratio = f_target / f_original
```

**Duration Modification:**
```
T_synthesis = T_analysis × duration_ratio

Independent of pitch modification
```

### 5.6 Resampling

**Linear Interpolation:**
```
y[k] = x[floor(k × r)] × (1 - frac) + x[ceil(k × r)] × frac

Where:
  r = input_rate / output_rate
  frac = (k × r) - floor(k × r)
```

**Sinc Interpolation (ideal bandlimited):**
```
y[k] = Σ(n=-∞ to ∞) x[n] × sinc((k × r) - n)

sinc(x) = sin(πx) / (πx)
```

---

## 6. Implementation Challenges

### 6.1 Latency vs Accuracy Trade-offs

Real-time pitch correction faces fundamental constraints:

**Buffer Size Dilemma:**
```
Latency = Buffer Size / Sample Rate

For 44.1 kHz:
  512 samples  →  11.6 ms latency  →  Poor frequency resolution
  2048 samples →  46.4 ms latency  →  Good frequency resolution (but noticeable delay)
```

**Frequency Resolution:**
```
Δf = Sample Rate / FFT Size

For 44.1 kHz:
  512-point FFT  →  86 Hz resolution (can't distinguish nearby notes!)
  2048-point FFT →  21.5 Hz resolution (acceptable)
  8192-point FFT →  5.4 Hz resolution (excellent)
```

**Human Perception Thresholds:**
- **Acceptable latency for singing**: < 10-15 ms (feels real-time)
- **Noticeable latency**: > 20 ms (causes timing issues)
- **Unacceptable latency**: > 30 ms (impossible to sing with)

#### Solutions

**1. Lookahead Buffering**
Accept small latency (10-20 ms) to improve accuracy:
```python
def lookahead_pitch_detection(audio_stream, lookahead_ms=10):
    """Buffer future samples for better pitch detection."""
    buffer_size = int(lookahead_ms * sample_rate / 1000)
    # Detect pitch using current + future samples
    # Apply correction to current samples
    # Introduce exactly lookahead_ms delay
```

**2. Multi-Resolution Analysis**
Fast coarse detection + slow refinement:
```python
def hybrid_pitch_detection(signal, sample_rate):
    # Fast pass: 512 samples, rough estimate
    coarse_pitch = yin_fast(signal[:512], sample_rate)

    # Slow pass: 2048 samples, precise
    fine_pitch = yin_accurate(signal[:2048], sample_rate,
                              initial_guess=coarse_pitch)

    return fine_pitch
```

**3. Predictive Correction**
Anticipate pitch trajectory:
```python
def predictive_correction(pitch_history):
    """Predict next pitch value from recent history."""
    # Fit polynomial to recent pitch contour
    # Extrapolate to next sample
    # Pre-compute correction
```

### 6.2 Handling Voiced vs Unvoiced Segments

**Voiced**: Periodic sounds with clear pitch (vowels, sustained notes)
**Unvoiced**: Aperiodic sounds without pitch (consonants, breath, percussion)

#### Detection Methods

**Energy-based:**
```python
def is_voiced_energy(frame, threshold=0.01):
    """Voiced if RMS energy above threshold."""
    rms = np.sqrt(np.mean(frame ** 2))
    return rms > threshold
```

**Periodicity-based (YIN):**
```python
def is_voiced_yin(cmndf, threshold=0.1):
    """Voiced if CMNDF has strong minimum."""
    return np.min(cmndf) < threshold
```

**Zero-Crossing Rate:**
```python
def zero_crossing_rate(frame):
    """Count sign changes."""
    zcr = np.sum(np.abs(np.diff(np.sign(frame)))) / (2 * len(frame))
    # Voiced: low ZCR (~0.02-0.05)
    # Unvoiced: high ZCR (>0.3)
    return zcr
```

**Spectral Flatness:**
```python
def spectral_flatness(spectrum):
    """Ratio of geometric to arithmetic mean."""
    geometric_mean = np.exp(np.mean(np.log(spectrum + 1e-10)))
    arithmetic_mean = np.mean(spectrum)
    flatness = geometric_mean / arithmetic_mean
    # Voiced: low flatness (<0.1, harmonic peaks)
    # Unvoiced: high flatness (>0.5, noise-like)
    return flatness
```

#### Processing Strategy

```python
def adaptive_autotune(signal, sample_rate):
    """Only correct voiced segments."""
    frames = split_into_frames(signal, frame_size=2048, hop=512)

    for i, frame in enumerate(frames):
        # Voiced/unvoiced classification
        is_voiced = is_voiced_yin(frame) and \
                    is_voiced_energy(frame) and \
                    spectral_flatness(frame) < 0.2

        if is_voiced:
            # Detect and correct pitch
            f0 = yin_pitch_detection(frame, sample_rate)
            target_f0 = quantize_to_scale(f0, scale_notes)
            corrected_frame = pitch_shift(frame, target_f0 / f0)
        else:
            # Pass through unchanged
            corrected_frame = frame

        output_frames[i] = corrected_frame

    return overlap_add(output_frames)
```

### 6.3 Pitch Detection Failures and Smoothing

#### Common Failures

**Octave Errors:**
```python
def octave_error_detection(pitch_contour):
    """Detect and fix sudden octave jumps."""
    for i in range(1, len(pitch_contour)):
        ratio = pitch_contour[i] / pitch_contour[i-1]

        # Check for doubling/halving (octave jump)
        if 1.9 < ratio < 2.1:  # ~2x = up one octave
            pitch_contour[i] /= 2
        elif 0.47 < ratio < 0.53:  # ~0.5x = down one octave
            pitch_contour[i] *= 2

    return pitch_contour
```

**Pitch Tracking Breaks:**
```python
def fill_pitch_gaps(pitch_contour):
    """Interpolate missing pitch values."""
    # Find gaps (where pitch detection failed)
    valid_indices = np.where(pitch_contour > 0)[0]

    if len(valid_indices) < 2:
        return pitch_contour

    # Linear interpolation
    from scipy.interpolate import interp1d
    interp_func = interp1d(valid_indices, pitch_contour[valid_indices],
                           kind='linear', fill_value='extrapolate')

    all_indices = np.arange(len(pitch_contour))
    pitch_contour = interp_func(all_indices)

    return pitch_contour
```

#### Smoothing Techniques

**Median Filter (removes spikes):**
```python
def median_smooth_pitch(pitch_contour, window_size=5):
    """Apply median filter to remove outliers."""
    from scipy.signal import medfilt
    return medfilt(pitch_contour, kernel_size=window_size)
```

**Low-Pass Filter (reduces jitter):**
```python
def lowpass_smooth_pitch(pitch_contour, sample_rate, cutoff_hz=10):
    """Smooth pitch contour with low-pass filter."""
    from scipy.signal import butter, filtfilt

    nyquist = sample_rate / 2
    normalized_cutoff = cutoff_hz / nyquist
    b, a = butter(2, normalized_cutoff, btype='low')

    smoothed = filtfilt(b, a, pitch_contour)
    return smoothed
```

**Kalman Filter (optimal for noisy measurements):**
```python
class PitchKalmanFilter:
    """Kalman filter for pitch tracking."""

    def __init__(self, process_noise=1e-5, measurement_noise=1e-1):
        self.x = 0  # State (pitch)
        self.P = 1  # Uncertainty
        self.Q = process_noise
        self.R = measurement_noise

    def update(self, measurement):
        """Update with new pitch measurement."""
        # Prediction
        x_pred = self.x
        P_pred = self.P + self.Q

        # Update
        K = P_pred / (P_pred + self.R)  # Kalman gain
        self.x = x_pred + K * (measurement - x_pred)
        self.P = (1 - K) * P_pred

        return self.x
```

### 6.4 Artifacts and How to Minimize Them

#### Phasiness (Spectral Smearing)

**Cause:** Loss of phase coherence in phase vocoder
**Sound:** Washy, reverb-like, "underwater"

**Solutions:**
```python
# 1. Phase locking at peaks
def phase_lock_peaks(stft_matrix):
    """Lock phases of spectral peaks."""
    magnitude = np.abs(stft_matrix)

    for frame in range(stft_matrix.shape[1]):
        # Find peaks
        peaks = find_spectral_peaks(magnitude[:, frame])

        # Reset phases at peaks to maintain relationships
        if frame > 0:
            for peak in peaks:
                # Keep phase relationship with previous frame
                phase_diff = calculate_expected_phase(peak, hop_size)
                stft_matrix[peak, frame] = magnitude[peak, frame] * \
                    np.exp(1j * (np.angle(stft_matrix[peak, frame-1]) + phase_diff))

# 2. Vertical phase coherence
def enforce_vertical_coherence(stft_matrix):
    """Maintain phase relationships between harmonics."""
    # For each harmonic, phase should be n × fundamental phase
    fundamental_phase = np.angle(stft_matrix[f0_bin, :])

    for n in range(2, 10):  # Harmonics 2-10
        harmonic_bin = n * f0_bin
        expected_phase = n * fundamental_phase
        stft_matrix[harmonic_bin, :] = np.abs(stft_matrix[harmonic_bin, :]) * \
            np.exp(1j * expected_phase)
```

#### Robotic/Metallic Sound

**Cause:** Over-correction, loss of natural pitch variation, formant distortion
**Sound:** Synthetic, lifeless, "Auto-Tuned to death"

**Solutions:**
```python
# 1. Preserve vibrato
if detect_vibrato(pitch_contour):
    correction_amount *= 0.5  # Reduce correction during vibrato

# 2. Adaptive retune speed
def adaptive_retune_speed(pitch_error_cents):
    """Slower correction for small errors."""
    if abs(pitch_error_cents) < 20:
        return 100  # ms - slow
    elif abs(pitch_error_cents) < 50:
        return 30   # ms - moderate
    else:
        return 10   # ms - fast (large errors need quick fix)

# 3. Preserve formants
corrected_signal = pitch_shift_with_formant_preservation(
    signal, pitch_ratio
)
```

#### Transient Smearing

**Cause:** Attack portions spread across multiple STFT frames
**Sound:** Blurred consonants, soft attacks, loss of "punch"

**Solutions:**
```python
# 1. Transient detection and bypass
def detect_transients(signal, threshold=2.0):
    """Find sudden energy increases."""
    envelope = np.abs(signal)
    diff = np.diff(envelope)
    transients = np.where(diff > threshold * np.std(diff))[0]
    return transients

def protect_transients(signal, transient_indices, protection_ms=10):
    """Don't pitch-shift near transients."""
    protection_samples = int(protection_ms * sample_rate / 1000)

    for t in transient_indices:
        # Mark region around transient as protected
        protected_regions.append((t, t + protection_samples))

# 2. Transient-sensitive analysis
def transient_aware_stft(signal, transient_sensitivity=0.5):
    """Smaller windows near transients."""
    if is_near_transient(position):
        window_size = 512  # Small window = good time resolution
    else:
        window_size = 2048  # Large window = good frequency resolution
```

#### Pre-Echo / Post-Echo

**Cause:** Time-domain discontinuities from pitch shifting
**Sound:** Clicks, stuttering before/after corrected notes

**Solutions:**
```python
# 1. Crossfading between corrected and original
def smooth_transition(original, corrected, fade_ms=5):
    """Crossfade to avoid discontinuities."""
    fade_samples = int(fade_ms * sample_rate / 1000)
    fade_in = np.linspace(0, 1, fade_samples)
    fade_out = 1 - fade_in

    output = original.copy()
    output[:fade_samples] = original[:fade_samples] * fade_out + \
                            corrected[:fade_samples] * fade_in
    return output

# 2. Overlap-add with proper windowing
def cola_compliant_reconstruction(frames, hop_size):
    """Ensure Constant Overlap-Add constraint."""
    window = scipy.signal.hann(frame_size, sym=False)

    # Verify COLA
    assert scipy.signal.check_COLA(window, frame_size, hop_size)

    return overlap_add(frames * window, hop_size)
```

---

## 7. Commercial Auto-Tune Techniques

### 7.1 How Antares Auto-Tune Achieves Its Signature Sound

Antares Auto-Tune, created by Andy Hildebrand in 1997, revolutionized pitch correction and created the iconic "Auto-Tune effect."

#### Key Technologies

**1. Autocorrelation with Optimization**

Hildebrand's breakthrough was making autocorrelation computationally feasible:
> "A simplification changed a million multiply-adds into just four"

Rather than naive O(N²) autocorrelation, Hildebrand used:
- **FFT-based autocorrelation**: O(N log N) complexity
- **Stochastic estimation theory**: From his seismic data processing background
- **Adaptive windowing**: Optimized for vocal ranges

```python
def hildebrand_autocorrelation(signal, sample_rate):
    """
    Fast autocorrelation using FFT (Wiener-Khinchin theorem).

    R(τ) = IFFT(|FFT(x)|²)
    """
    # Zero-pad to avoid circular correlation
    n = len(signal)
    padded = np.pad(signal, (0, n), mode='constant')

    # FFT method: autocorrelation = IFFT of power spectrum
    fft_signal = np.fft.fft(padded)
    power_spectrum = np.abs(fft_signal) ** 2
    autocorr = np.fft.ifft(power_spectrum).real[:n]

    return autocorr
```

**2. Retune Speed Parameter**

The most distinctive feature of Auto-Tune:
- **Retune Speed = 0 ms**: The "Cher effect" / "T-Pain sound"
  - Instant pitch correction
  - Creates robotic, synthetic quality
  - Pitch changes are discontinuous jumps
- **Retune Speed = 20-50 ms**: Natural correction
  - Smoothly approaches target pitch
  - Preserves human expressiveness
  - Fixes errors without obvious processing

```python
def autotune_retune_speed(current_pitch, target_pitch, retune_speed_ms, dt):
    """
    Exponential approach to target pitch.

    Mimics Auto-Tune's retune speed parameter.
    """
    if retune_speed_ms == 0:
        # Instant correction (the "effect")
        return target_pitch

    # Time constant
    tau = retune_speed_ms / 1000.0  # Convert to seconds

    # Exponential smoothing
    alpha = 1.0 - np.exp(-dt / tau)
    new_pitch = current_pitch + alpha * (target_pitch - current_pitch)

    return new_pitch
```

**3. Graphical Mode (Note Objects)**

Auto-Tune Pro's "Graph Mode" allows manual editing:
- Each note appears as a graphical object
- Users can adjust pitch curves by hand
- Fine control over vibrato, pitch drift, correction amount

This inspired Melodyne's even more advanced interface.

**4. Formant Correction**

Auto-Tune preserves formants to avoid chipmunk/monster effects:
- Spectral envelope extracted via cepstral analysis
- Pitch shifted independently of formants
- Formants can be manually shifted (Throat Length parameter)

#### Why the "Auto-Tune Sound" Happens

The robotic quality comes from:
1. **Zero retune speed**: Instantaneous pitch snapping
2. **100% correction**: No preservation of natural pitch variation
3. **Scale quantization**: Forces notes to exact semitones
4. **Vibrato removal**: Fast correction eliminates natural modulation

This creates a perceptually unnatural but musically useful effect that became a defining sound of 2000s-2010s pop music.

### 7.2 Melodyne's Direct Note Access

Celemony Melodyne introduced **Direct Note Access (DNA)** technology, winning a Technical Grammy Award in 2012.

#### Revolutionary Feature: Polyphonic Pitch Editing

Unlike Auto-Tune (monophonic), Melodyne can:
- Detect individual notes in polyphonic recordings (piano chords, guitar strumming)
- Edit pitch, timing, and amplitude of each note independently
- Separate notes by pitch, not by instrument

#### How DNA Works

**1. Spectral Modeling Synthesis**

Melodyne analyzes audio using a sophisticated model:
```
Signal = Σ (sinusoids + transients + noise)
```

For each note:
- **Sinusoidal component**: Harmonic partials (pitch information)
- **Transient component**: Attack (percussive elements)
- **Stochastic component**: Noise (breath, bow scrape, etc.)

```python
def spectral_modeling_analysis(signal, sample_rate):
    """
    Melodyne-style spectral model.

    Decomposes signal into sinusoids, transients, and noise.
    """
    # 1. Transient detection
    transients = detect_transients(signal)

    # 2. Sinusoidal modeling (extract harmonics)
    sinusoids = []
    stft_matrix = librosa.stft(signal)

    for frame in range(stft_matrix.shape[1]):
        # Find spectral peaks (sinusoidal components)
        peaks = find_spectral_peaks(np.abs(stft_matrix[:, frame]))

        for peak in peaks:
            freq = peak['frequency']
            amplitude = peak['amplitude']
            phase = peak['phase']

            sinusoids.append({
                'time': frame * hop_size / sample_rate,
                'frequency': freq,
                'amplitude': amplitude,
                'phase': phase
            })

    # 3. Residual = original - sinusoids (contains noise)
    sinusoid_sum = synthesize_sinusoids(sinusoids)
    residual = signal - sinusoid_sum

    return {
        'sinusoids': sinusoids,
        'transients': transients,
        'noise': residual
    }
```

**2. Note Separation by Pitch**

Melodyne groups sinusoids into note objects:
```python
def separate_notes(sinusoids, tolerance_cents=50):
    """
    Group sinusoidal tracks into note objects.

    Sinusoids with frequencies near harmonics of the same
    fundamental are grouped together.
    """
    notes = []

    # Cluster by fundamental frequency
    for sinusoid in sinusoids:
        freq = sinusoid['frequency']

        # Find which existing note this belongs to (harmonic matching)
        matched = False
        for note in notes:
            f0 = note['fundamental']

            # Check if freq is near any harmonic of f0
            for n in range(1, 20):
                expected_freq = n * f0
                cents_error = freq_to_cents(freq, expected_freq)

                if abs(cents_error) < tolerance_cents:
                    note['partials'].append(sinusoid)
                    matched = True
                    break

            if matched:
                break

        # Create new note if no match
        if not matched:
            notes.append({
                'fundamental': freq,
                'partials': [sinusoid],
                'start_time': sinusoid['time']
            })

    return notes
```

**3. Note Editing**

Once separated, each note can be manipulated:
```python
def edit_note_pitch(note, pitch_shift_semitones):
    """
    Shift all partials of a note by the same ratio.
    """
    ratio = 2 ** (pitch_shift_semitones / 12)

    for partial in note['partials']:
        partial['frequency'] *= ratio

    return note


def edit_note_timing(note, time_shift_ms):
    """
    Move note in time without affecting pitch.
    """
    time_shift_s = time_shift_ms / 1000.0

    for partial in note['partials']:
        partial['time'] += time_shift_s

    return note
```

#### Limitations of DNA

From the search results:
> "DNA is intended for polyphonic instruments recorded singly, as it separates notes by pitch – not by instrument."

This means:
- **Works**: Piano chord (different pitches)
- **Doesn't work**: Two guitars playing the same note (same pitch, different instruments)
- **Limited**: Very dense chords or clusters (too many overlapping partials)

### 7.3 Modern AI-Based Pitch Correction

Recent advances use machine learning for superior pitch detection and correction.

#### Deep Learning Approaches

**1. Neural Pitch Detection**

Convolutional neural networks trained on labeled pitch data:
```python
class NeuralPitchDetector(nn.Module):
    """
    CNN-based pitch detection (conceptual).

    Input: Spectrogram (time × frequency)
    Output: Pitch contour (time × 1)
    """
    def __init__(self):
        super().__init__()
        self.conv1 = nn.Conv2d(1, 32, kernel_size=(3, 3))
        self.conv2 = nn.Conv2d(32, 64, kernel_size=(3, 3))
        self.lstm = nn.LSTM(64, 128, bidirectional=True)
        self.fc = nn.Linear(256, 1)  # Output: single pitch value

    def forward(self, spectrogram):
        # Convolution layers extract features
        x = F.relu(self.conv1(spectrogram))
        x = F.relu(self.conv2(x))

        # LSTM captures temporal dependencies
        x, _ = self.lstm(x)

        # Fully connected layer outputs pitch
        pitch = self.fc(x)
        return pitch
```

**Advantages over traditional methods:**
- **Handles polyphony**: Can detect multiple simultaneous pitches
- **Robust to noise**: Trained on diverse, noisy data
- **No octave errors**: Learns to avoid common failure modes
- **Faster**: Single forward pass (no iterative search)

**2. Source Separation for Pitch Isolation**

AI models like Spleeter or Demucs separate vocals from accompaniment:
```python
def ai_assisted_autotune(mixed_audio):
    """
    Use source separation to isolate vocals before pitch correction.
    """
    # Step 1: Separate vocals using neural network
    vocals, accompaniment = spleeter.separate(mixed_audio)

    # Step 2: Pitch-correct vocals only
    corrected_vocals = autotune(vocals)

    # Step 3: Remix
    corrected_mix = corrected_vocals + accompaniment

    return corrected_mix
```

**3. End-to-End Pitch Correction**

Emerging research: neural networks that perform pitch correction directly:
```python
class E2EPitchCorrector(nn.Module):
    """
    End-to-end pitch correction using deep learning.

    Input: Audio waveform + target scale
    Output: Corrected audio waveform
    """
    def __init__(self):
        super().__init__()
        self.encoder = WaveNetEncoder()
        self.pitch_conditioner = PitchConditioner()
        self.decoder = WaveNetDecoder()

    def forward(self, audio, target_scale):
        # Encode audio to latent representation
        latent = self.encoder(audio)

        # Condition on target scale
        conditioned = self.pitch_conditioner(latent, target_scale)

        # Decode to corrected audio
        corrected_audio = self.decoder(conditioned)

        return corrected_audio
```

**Benefits:**
- **Artifact-free**: Learns to avoid phasiness, robotic sound
- **Formant preservation**: Automatically learns to preserve timbre
- **Adaptive correction**: Can learn stylistic preferences (genre-specific)

#### Commercial AI Pitch Correction

Modern products incorporating AI:
- **iZotope RX**: Machine learning for artifact reduction
- **Waves Tune Real-Time**: Low-latency neural pitch tracking
- **Synchro Arts Revoice Pro**: AI-assisted vocal alignment and tuning

---

## Conclusion

Auto-Tune technology combines:
1. **Signal processing**: Pitch detection (YIN, SWIPE, cepstral)
2. **Audio manipulation**: Pitch shifting (PSOLA, phase vocoder, granular)
3. **Music theory**: MIDI mapping, scale quantization
4. **Psychoacoustics**: Formant preservation, vibrato handling
5. **Modern AI**: Neural networks for detection and separation

Building a high-quality Auto-Tune system requires mastering all these domains and carefully balancing trade-offs between latency, accuracy, and audio quality.

The "Auto-Tune sound" - whether natural correction or robotic effect - emerges from the precise interplay of retune speed, correction amount, formant preservation, and scale constraints. Understanding these parameters allows both replicating commercial tools and creating novel pitch manipulation effects.

---

## References and Sources

### Scientific Papers and Technical Resources

1. **YIN Algorithm**
   - [YIN, A fundamental frequency estimator for speech and music (JASA 2002)](http://audition.ens.fr/adc/pdf/2002_JASA_YIN.pdf)
   - [A comprehensive look into the YIN algorithm - Sarah Hong](https://www.hyuncat.com/blog/yin/)
   - [Pitch detection algorithm - Wikipedia](https://en.wikipedia.org/wiki/Pitch_detection_algorithm)

2. **PSOLA**
   - [PSOLA - Wikipedia](https://en.wikipedia.org/wiki/PSOLA)
   - [Pitch-Synchoronous Overlap-Add (PSOLA) - Aalto University](https://speechprocessingbook.aalto.fi/Representations/Pitch-Synchoronous_Overlap-Add_PSOLA.html)
   - [TD-PSOLA GitHub Implementation](https://github.com/sannawag/TD-PSOLA)

3. **Phase Vocoder**
   - [Phase vocoder - Wikipedia](https://en.wikipedia.org/wiki/Phase_vocoder)
   - [New phase-vocoder techniques for pitch-shifting (Laroche & Dolson, 1999)](https://www.ee.columbia.edu/~dpwe/papers/LaroD99-pvoc.pdf)
   - [Pitch Shifting and Time Dilation Using a Phase Vocoder in MATLAB](https://www.mathworks.com/help/audio/ug/pitch-shifting-and-time-dilation-using-a-phase-vocoder-in-matlab.html)

4. **SWIPE Algorithm**
   - [A sawtooth waveform inspired pitch estimator for speech and music (Camacho & Harris, 2008)](https://www.researchgate.com/publication/23558616_A_sawtooth_waveform_inspired_pitch_estimator_for_speech_and_music)
   - [SWIPE Pitch Estimation](http://psysound.wikidot.com/system:swipep-pitch-estimation)

5. **Cepstral Analysis**
   - [Cepstrum - Wikipedia](https://en.wikipedia.org/wiki/Cepstrum)
   - [Cepstrum, quefrency, & pitch detection](https://www.johndcook.com/blog/2016/05/18/cepstrum-quefrency-and-pitch/)
   - [A Short Tutorial on Cepstral Analysis for Pitch-tracking](http://flothesof.github.io/cepstrum-pitch-tracking.html)

6. **Formant Preservation**
   - [On the Importance Of Formants In Pitch Shifting - Stephan Bernsee](http://blogs.zynaptiq.com/bernsee/formants-pitch-shifting/)
   - [Spectral Envelope Transformation in Singing Voice for Advanced Pitch Shifting (MDPI)](https://www.mdpi.com/2076-3417/6/11/368)
   - [FFT Pitch Shifting with Formant Preservation Revisited](https://synsinger.wordpress.com/2013/03/24/fft-pitch-shifting-with-formant-preservation-revisited/)

7. **Granular Synthesis**
   - [Granular Synthesis - Sound on Sound](https://www.soundonsound.com/techniques/granular-synthesis)
   - [The Basics of Granular Synthesis - iZotope](https://www.izotope.com/en/learn/the-basics-of-granular-synthesis.html)
   - [How it works - DSP Labs](https://lcav.gitbook.io/dsp-labs/granular-synthesis/effect_description)

8. **Psychoacoustics**
   - [Harmonic series (music) - Wikipedia](https://en.wikipedia.org/wiki/Harmonic_series_(music))
   - [Overtone - Wikipedia](https://en.wikipedia.org/wiki/Overtone)
   - [Critical Bandwidths and Just-Noticeable Differences](https://www.phys.uconn.edu/~gibson/Notes/Section7_2/Sec7_2.htm)
   - [Pitch perception and critical bands - Fiveable](https://fiveable.me/acoustics/unit-11/pitch-perception-critical-bands/study-guide/wnFvlBUgvGJox0mD)

9. **STFT and Window Functions**
   - [Short-time Fourier transform - Wikipedia](https://en.wikipedia.org/wiki/Short-time_Fourier_transform)
   - [Window function - Wikipedia](https://en.wikipedia.org/wiki/Window_function)
   - [Overlap-Add (OLA) STFT Processing](https://www.dsprelated.com/freebooks/sasp/Overlap_Add_OLA_STFT_Processing.html)

10. **Musical Theory**
    - [Note names, MIDI numbers and frequencies](https://newt.phys.unsw.edu.au/jw/notes.html)
    - [Frequency and Pitch - dobrian.github.io](https://dobrian.github.io/cmp/topics/physics-of-sound/1.frequency-and-pitch.html)

11. **Antares Auto-Tune**
    - [Auto-Tune - Wikipedia](https://en.wikipedia.org/wiki/Auto-Tune)
    - [Antares Auto-Tune Quickstart Guide - Sweetwater](https://www.sweetwater.com/sweetcare/articles/auto-tune-quickstart-guide/)

12. **Melodyne DNA**
    - [Celemony Melodyne DNA Editor - Sound on Sound](https://www.soundonsound.com/reviews/celemony-melodyne-dna-editor)
    - [Direct Note Access - Melodyne](https://www.soundbridge.io/direct-note-access-melodyne)
    - [The Big Review: Celemony Melodyne 5 - MusicTech](https://musictech.com/reviews/plug-ins/the-big-review-celemony-melodyne-5/)

13. **Artifacts and Quality**
    - [Time & Pitch - RX 9 Help (iZotope)](https://s3.amazonaws.com/izotopedownloads/docs/rx9/en/time-and-pitch/index.html)
    - [Phase Vocoder Done Right (Průša & Holighaus)](https://arxiv.org/pdf/2202.07382)
    - [Suppression of phasiness for time-scale modifications](https://ieeexplore.ieee.org/document/941049/)

---

**Document created**: 2025-12-14
**For**: Changies voice changer project
**Author**: Research compiled from academic and industry sources
