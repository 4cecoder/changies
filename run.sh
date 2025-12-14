#!/bin/bash

# Changies Launcher Script
# Kills any existing instance and starts fresh

echo "🎙️  Starting Changies Real-Time Vocal Designer..."
echo ""

# Kill any existing changies process
if pgrep -x "changies" > /dev/null; then
    echo "⚠️  Stopping existing changies process..."
    pkill -9 changies
    sleep 1
fi

# Kill anything using port 8080
PORT_PID=$(lsof -ti:8080 2>/dev/null)
if [ -n "$PORT_PID" ]; then
    echo "⚠️  Killing process using port 8080 (PID: $PORT_PID)..."
    kill -9 $PORT_PID 2>/dev/null
    sleep 1
fi

# Build the project
echo "🔨 Building changies..."
if ! zig build -Doptimize=ReleaseFast; then
    echo "❌ Build failed!"
    exit 1
fi

echo "✅ Build successful!"
echo ""

# Run changies
echo "🚀 Starting changies..."
echo "📡 Web interface: http://localhost:8080"
echo "🎧 Press Ctrl+C to stop"
echo ""

# try to open the browser on run so its easy AS FUKKKK
exec xdg-open http://localhost:8080 &

exec ./zig-out/bin/changies
