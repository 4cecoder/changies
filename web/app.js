// CHANGIES VOX CHAIN - Web Interface

// Preset configurations (display only - actual processing is in backend)
const PRESETS = {
    broadcast: {
        hpf: '80Hz',
        eqLow: '+3dB @ 120Hz',
        eqMid: '+5dB @ 3kHz Q:2',
        eqHigh: '+2dB @ 10kHz',
        deess: '-38dB Ratio:4:1',
        comp: '-18dB 4:1 A:5 R:50'
    },
    podcast: {
        hpf: '100Hz',
        eqLow: '+2dB @ 150Hz',
        eqMid: '+4dB @ 2.5kHz Q:2',
        eqHigh: '+1dB @ 8kHz',
        deess: '-40dB Ratio:3:1',
        comp: '-20dB 3:1 A:10 R:100'
    },
    gaming: {
        hpf: '120Hz',
        eqLow: 'Flat',
        eqMid: '+8dB @ 3kHz Q:2',
        eqHigh: 'Flat',
        deess: '-35dB Ratio:3:1',
        comp: '-15dB 2.5:1 A:3 R:30'
    },
    clean: {
        hpf: '60Hz',
        eqLow: 'Flat',
        eqMid: 'Flat',
        eqHigh: 'Flat',
        deess: '-45dB Ratio:2:1',
        comp: '-25dB 2:1 A:10 R:100'
    }
};

class ChangiesClient {
    constructor() {
        this.ws = null;
        this.reconnectTimer = null;
        this.reconnectInterval = 2000;
        this.lastMessageTime = 0;

        this.initUI();
        this.loadDevices();
        this.connect();
    }

    initUI() {
        // Effect buttons
        document.querySelectorAll('.effect-btn').forEach(btn => {
            btn.addEventListener('click', () => {
                this.setActiveButton('.effect-btn', btn);
                this.sendCommand('effect', btn.dataset.effect);
            });
        });

        // Preset buttons
        document.querySelectorAll('.preset-btn').forEach(btn => {
            btn.addEventListener('click', () => {
                this.setActiveButton('.preset-btn', btn);
                this.loadPreset(btn.dataset.preset);
            });
        });

        // Pitch slider
        const pitchSlider = document.getElementById('pitch-slider');
        const pitchValue = document.getElementById('pitch-value');
        pitchSlider.addEventListener('input', (e) => {
            pitchValue.textContent = parseFloat(e.target.value).toFixed(2) + 'x';
        });
        pitchSlider.addEventListener('change', (e) => {
            this.sendCommand('pitch', parseFloat(e.target.value));
        });

        // Gate slider
        const gateSlider = document.getElementById('gate-slider');
        const gateValue = document.getElementById('gate-value');
        gateSlider.addEventListener('input', (e) => {
            gateValue.textContent = e.target.value + ' dB';
        });
        gateSlider.addEventListener('change', (e) => {
            const db = parseInt(e.target.value);
            const linear = Math.pow(10, db / 20);
            this.sendCommand('gate_threshold', linear);
        });

        // Vox chain enable toggle
        const voxEnabled = document.getElementById('vox-enabled');
        voxEnabled.addEventListener('change', (e) => {
            this.sendCommand('vox_enabled', e.target.checked);
        });

        // Monitor mode toggle
        const monitorEnabled = document.getElementById('monitor-enabled');
        monitorEnabled.addEventListener('change', (e) => {
            this.sendCommand('monitor', e.target.checked);
            console.log(e.target.checked ? 'Monitor ON - Speakers' : 'Monitor OFF - Virtual Device');
        });

        // Input device selection
        const inputDeviceSelect = document.getElementById('input-device-select');
        inputDeviceSelect.addEventListener('change', (e) => {
            this.sendCommand('input_device', e.target.value);
            console.log('Input device changed to:', e.target.value);
        });

        // Output device selection
        const outputDeviceSelect = document.getElementById('output-device-select');
        outputDeviceSelect.addEventListener('change', (e) => {
            this.sendCommand('output_device', e.target.value);
            console.log('Output device changed to:', e.target.value);
        });

        // Latency compensation slider
        const latencySlider = document.getElementById('latency-slider');
        const latencyValue = document.getElementById('latency-value');
        latencySlider.addEventListener('input', (e) => {
            latencyValue.textContent = e.target.value + ' ms';
        });
        latencySlider.addEventListener('change', (e) => {
            const latency_ms = parseInt(e.target.value);
            this.sendCommand('latency_compensation', latency_ms);
            console.log('Latency compensation:', latency_ms, 'ms');
        });

        // Initialize with broadcast preset display
        this.updatePresetDisplay('broadcast');
    }

    async loadDevices() {
        try {
            const response = await fetch('/api/devices');
            const data = await response.json();

            const inputSelect = document.getElementById('input-device-select');
            const outputSelect = document.getElementById('output-device-select');

            // Populate input devices (sources)
            inputSelect.innerHTML = '';
            data.sources.forEach(source => {
                const option = document.createElement('option');
                option.value = source.name;
                option.textContent = this.formatDeviceName(source.name);
                if (source.state === 'RUNNING') {
                    option.selected = true;
                }
                inputSelect.appendChild(option);
            });

            // Populate output devices (sinks)
            outputSelect.innerHTML = '';
            data.sinks.forEach(sink => {
                const option = document.createElement('option');
                option.value = sink.name;
                option.textContent = this.formatDeviceName(sink.name);
                if (sink.name === 'changies_output' && sink.state === 'RUNNING') {
                    option.selected = true;
                }
                outputSelect.appendChild(option);
            });

            console.log('Loaded devices:', data.sources.length, 'sources,', data.sinks.length, 'sinks');
        } catch (error) {
            console.error('Failed to load devices:', error);
        }
    }

    formatDeviceName(name) {
        // Simplify device names for display
        if (name.includes('changies_output')) return 'Changies Output (Virtual Device)';
        if (name.includes('.monitor')) return name.replace('.monitor', ' (Monitor)');

        // Clean up ALSA names
        const cleaned = name
            .replace('alsa_input.', '')
            .replace('alsa_output.', '')
            .replace('usb-', '')
            .replace('.mono-fallback', '')
            .replace('.analog-stereo', '')
            .replace('.iec958-stereo', '');

        return cleaned.length > 50 ? cleaned.substring(0, 47) + '...' : cleaned;
    }

    setActiveButton(selector, activeBtn) {
        document.querySelectorAll(selector).forEach(btn => {
            btn.classList.remove('active');
        });
        activeBtn.classList.add('active');
    }

    loadPreset(presetName) {
        this.sendCommand('vox_preset', presetName);
        this.updatePresetDisplay(presetName);
    }

    updatePresetDisplay(presetName) {
        const preset = PRESETS[presetName];
        if (preset) {
            document.getElementById('hpf-display').textContent = preset.hpf;
            document.getElementById('eq-low-display').textContent = preset.eqLow;
            document.getElementById('eq-mid-display').textContent = preset.eqMid;
            document.getElementById('eq-high-display').textContent = preset.eqHigh;
            document.getElementById('deess-display').textContent = preset.deess;
            document.getElementById('comp-display').textContent = preset.comp;
        }
    }

    connect() {
        try {
            const protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
            const wsUrl = `${protocol}//${window.location.host}/ws`;
            this.ws = new WebSocket(wsUrl);

            this.ws.onopen = () => this.onOpen();
            this.ws.onmessage = (e) => this.onMessage(e);
            this.ws.onclose = () => this.onClose();
            this.ws.onerror = (e) => this.onError(e);
        } catch (error) {
            console.error('WebSocket error:', error);
            this.scheduleReconnect();
        }
    }

    onOpen() {
        console.log('WebSocket connected');
        this.updateConnectionStatus(true);
        if (this.reconnectTimer) {
            clearTimeout(this.reconnectTimer);
            this.reconnectTimer = null;
        }
    }

    onMessage(event) {
        try {
            const data = JSON.parse(event.data);
            this.lastMessageTime = Date.now();

            if (data.type === 'stats') {
                this.updateStats(data);
            }
        } catch (error) {
            console.error('Message parse error:', error);
        }
    }

    onClose() {
        console.log('WebSocket disconnected');
        this.updateConnectionStatus(false);
        this.scheduleReconnect();
    }

    onError(error) {
        console.error('WebSocket error:', error);
    }

    scheduleReconnect() {
        if (this.reconnectTimer) return;
        this.reconnectTimer = setTimeout(() => {
            console.log('Reconnecting...');
            this.connect();
        }, this.reconnectInterval);
    }

    updateConnectionStatus(connected) {
        const status = document.getElementById('connection-status');
        if (connected) {
            status.textContent = 'CONNECTED';
            status.className = 'status-badge connected';
        } else {
            status.textContent = 'DISCONNECTED';
            status.className = 'status-badge disconnected';
        }
    }

    updateStats(data) {
        // Update latency
        const latency = Date.now() - this.lastMessageTime;
        document.getElementById('latency').textContent = latency + 'ms';

        // Update processing time
        if (data.processing_time_us !== undefined) {
            const ms = (data.processing_time_us / 1000).toFixed(2);
            document.getElementById('processing-time').textContent = ms + 'ms';
        }

        // Update input meter
        if (data.input_rms !== undefined) {
            const db = this.linearToDb(data.input_rms);
            const percent = this.dbToPercent(db);
            document.getElementById('input-meter').style.width = percent + '%';
            document.getElementById('input-db').textContent = db.toFixed(1) + ' dB';
        }

        if (data.input_peak !== undefined) {
            const db = this.linearToDb(data.input_peak);
            const percent = this.dbToPercent(db);
            document.getElementById('input-peak').style.left = percent + '%';
        }

        // Update output meter
        if (data.output_rms !== undefined) {
            const db = this.linearToDb(data.output_rms);
            const percent = this.dbToPercent(db);
            document.getElementById('output-meter').style.width = percent + '%';
            document.getElementById('output-db').textContent = db.toFixed(1) + ' dB';
        }

        if (data.output_peak !== undefined) {
            const db = this.linearToDb(data.output_peak);
            const percent = this.dbToPercent(db);
            document.getElementById('output-peak').style.left = percent + '%';

            // Clip indicator
            const clipIndicator = document.getElementById('clip-indicator');
            if (data.output_peak > 0.95) {
                clipIndicator.classList.add('active');
            } else {
                clipIndicator.classList.remove('active');
            }
        }

        // Update gate state
        if (data.gate_open !== undefined) {
            const gateBadge = document.getElementById('gate-state');
            if (data.gate_open) {
                gateBadge.textContent = 'OPEN';
                gateBadge.className = 'gate-badge open';
            } else {
                gateBadge.textContent = 'CLOSED';
                gateBadge.className = 'gate-badge closed';
            }
        }
    }

    linearToDb(linear) {
        if (linear <= 0.0) return -Infinity;
        return 20 * Math.log10(linear);
    }

    dbToPercent(db) {
        const minDb = -60;
        const maxDb = 0;
        const percent = ((db - minDb) / (maxDb - minDb)) * 100;
        return Math.max(0, Math.min(100, percent));
    }

    sendCommand(command, value) {
        if (this.ws && this.ws.readyState === WebSocket.OPEN) {
            const message = JSON.stringify({
                type: 'command',
                command: command,
                value: value
            });
            this.ws.send(message);
            console.log('Sent:', command, value);
        } else {
            console.warn('WebSocket not connected');
        }
    }
}

// Section collapse/expand
function toggleSection(sectionId) {
    const section = document.getElementById(sectionId);
    section.classList.toggle('collapsed');
}

// Initialize on page load
document.addEventListener('DOMContentLoaded', () => {
    window.changiesClient = new ChangiesClient();
    console.log('CHANGIES VOX CHAIN initialized');
});
