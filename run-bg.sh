#!/bin/bash

# Changies Background Launcher Script
# Kills any existing instance and starts in background

echo "🎙️  Starting Changies Voice Changer (background mode)..."
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

# Run changies in background
echo "🚀 Starting changies in background..."

LOG_FILE="/tmp/changies.log"
./zig-out/bin/changies > "$LOG_FILE" 2>&1 &
CHANGIES_PID=$!

sleep 2

# Check if it's still running
if ps -p $CHANGIES_PID > /dev/null; then
    echo "✅ Changies running (PID: $CHANGIES_PID)"
    echo "📡 Web interface: http://localhost:8080"
    echo "📝 Logs: tail -f $LOG_FILE"
    echo "🛑 Stop: pkill changies"
else
    echo "❌ Failed to start changies. Check log:"
    tail -20 "$LOG_FILE"
    exit 1
fi
