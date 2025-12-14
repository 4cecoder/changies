# Changies - Professional Voice Changer

A real-time voice changer written in Zig, using PulseAudio for audio processing.

## Features

- **Multiple Voice Effects**
  - Male voice
  - Female voice
  - Robot
  - Alien
  - Deep voice
  - High pitch
  - Custom pitch adjustment

- **Real-time Processing**: Low-latency audio processing
- **CLI Interface**: Simple command-line interface
- **PulseAudio Integration**: Works with any PulseAudio-compatible system

## Building

Requires Zig 0.16.0-dev or later.

```bash
zig build
```

## Usage

Basic usage:
```bash
# Apply a voice effect
./zig-out/bin/changies --effect male

# Use custom pitch
./zig-out/bin/changies --effect custom --pitch 1.5

# Specify input device
./zig-out/bin/changies --effect female --input alsa_input.usb-Device.mono-fallback
```

### Available Effects

- `none` - No effect, pass-through
- `male` - Lower pitch, masculine formants
- `female` - Higher pitch, feminine formants
- `robot` - Quantized, robotic sound
- `alien` - High pitch with chorus effect
- `deep` - Very low pitch
- `high` - Very high pitch
- `custom` - Use with `--pitch` for custom adjustment

### Options

- `-e, --effect <EFFECT>` - Voice effect to apply
- `-p, --pitch <FACTOR>` - Custom pitch shift factor (0.5-2.0)
- `-i, --input <DEVICE>` - PulseAudio input device name
- `-h, --help` - Show help message

## Architecture

The project follows professional Zig patterns:

- **Error Handling**: Custom error sets with proper propagation
- **Memory Management**: Arena allocators with defer cleanup
- **Module Organization**: Logical separation of concerns
- **Type Safety**: Strong typing with compile-time guarantees

### Key Components

1. **AudioContext**: Manages PulseAudio connections and configuration
2. **Voice Effects**: Pitch shifting and formant filtering algorithms
3. **Processing Thread**: Real-time audio processing loop

## Development

See [CLAUDE.md](CLAUDE.md) for development guidelines and best practices.

### Project Structure

```
changies/
├── src/
│   └── main.zig          # Main application code
├── build.zig             # Build configuration
├── CLAUDE.md             # Project constitution
└── README.md             # This file
```

## License

MIT
