// Changies Control Center - WebSocket Client
class ChangiesClient {
    constructor() {
        this.ws = null;
        this.reconnectTimer = null;
        this.reconnectInterval = 2000;
        this.lastMessageTime = 0;
        this.latency = 0;

        // UI Elements
        this.elements = {
            connectionStatus: document.getElementById('connection-status'),
            latencyDisplay: document.getElementById('latency-display'),

            // Meters
            inputMeter: document.getElementById('input-meter'),
            inputPeak: document.getElementById('input-peak'),
            inputRms: document.getElementById('input-rms'),
            inputPeakValue: document.getElementById('input-peak-value'),

            outputMeter: document.getElementById('output-meter'),
            outputPeak: document.getElementById('output-peak'),
            outputRms: document.getElementById('output-rms'),
            outputPeakValue: document.getElementById('output-peak-value'),

            clippingIndicator: document.getElementById('clipping-indicator'),

            // Controls
            pitchSlider: document.getElementById('pitch-slider'),
            pitchValue: document.getElementById('pitch-value'),
            gateSlider: document.getElementById('gate-slider'),
            gateValue: document.getElementById('gate-value'),
            gateState: document.getElementById('gate-state'),

            // Stats
            bufferSize: document.getElementById('buffer-size'),
            sampleRate: document.getElementById('sample-rate'),
            processingTime: document.getElementById('processing-time'),
            activeEffect: document.getElementById('active-effect')
        };

        this.initEventListeners();
        this.connect();
    }

    connect() {
        try {
            const protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
            const wsUrl = `${protocol}//${window.location.host}/ws`;

            this.ws = new WebSocket(wsUrl);

            this.ws.onopen = () => this.onOpen();
            this.ws.onmessage = (event) => this.onMessage(event);
            this.ws.onclose = () => this.onClose();
            this.ws.onerror = (error) => this.onError(error);
        } catch (error) {
            console.error('WebSocket connection error:', error);
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
            } else if (data.type === 'config') {
                this.updateConfig(data);
            }
        } catch (error) {
            console.error('Error processing message:', error);
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
            console.log('Attempting to reconnect...');
            this.connect();
        }, this.reconnectInterval);
    }

    updateConnectionStatus(connected) {
        if (connected) {
            this.elements.connectionStatus.textContent = 'Connected';
            this.elements.connectionStatus.className = 'connected';
        } else {
            this.elements.connectionStatus.textContent = 'Disconnected';
            this.elements.connectionStatus.className = 'disconnected';
        }
    }

    updateStats(data) {
        // Update latency
        this.latency = Date.now() - this.lastMessageTime;
        this.elements.latencyDisplay.textContent = `Latency: ${this.latency}ms`;

        // Update input meters
        if (data.input_rms !== undefined) {
            const inputRmsDb = this.linearToDb(data.input_rms);
            const inputRmsPercent = this.dbToPercent(inputRmsDb);
            this.elements.inputMeter.style.width = `${inputRmsPercent}%`;
            this.elements.inputRms.textContent = `${inputRmsDb.toFixed(1)} dB`;
        }

        if (data.input_peak !== undefined) {
            const inputPeakDb = this.linearToDb(data.input_peak);
            const inputPeakPercent = this.dbToPercent(inputPeakDb);
            this.elements.inputPeak.style.left = `${inputPeakPercent}%`;
            this.elements.inputPeakValue.textContent = `Peak: ${inputPeakDb.toFixed(1)} dB`;
        }

        // Update output meters
        if (data.output_rms !== undefined) {
            const outputRmsDb = this.linearToDb(data.output_rms);
            const outputRmsPercent = this.dbToPercent(outputRmsDb);
            this.elements.outputMeter.style.width = `${outputRmsPercent}%`;
            this.elements.outputRms.textContent = `${outputRmsDb.toFixed(1)} dB`;
        }

        if (data.output_peak !== undefined) {
            const outputPeakDb = this.linearToDb(data.output_peak);
            const outputPeakPercent = this.dbToPercent(outputPeakDb);
            this.elements.outputPeak.style.left = `${outputPeakPercent}%`;
            this.elements.outputPeakValue.textContent = `Peak: ${outputPeakDb.toFixed(1)} dB`;

            // Clipping indicator (threshold at 0.95)
            if (data.output_peak > 0.95) {
                this.elements.clippingIndicator.classList.add('active');
            } else {
                this.elements.clippingIndicator.classList.remove('active');
            }
        }

        // Update gate state
        if (data.gate_open !== undefined) {
            if (data.gate_open) {
                this.elements.gateState.textContent = 'OPEN';
                this.elements.gateState.className = 'gate-open';
            } else {
                this.elements.gateState.textContent = 'CLOSED';
                this.elements.gateState.className = 'gate-closed';
            }
        }

        // Update processing time
        if (data.processing_time_us !== undefined) {
            const processingTimeMs = (data.processing_time_us / 1000).toFixed(2);
            this.elements.processingTime.textContent = `${processingTimeMs} ms`;
        }
    }

    updateConfig(data) {
        if (data.effect !== undefined) {
            this.elements.activeEffect.textContent = data.effect;
            this.setActiveEffect(data.effect);
        }

        if (data.pitch_shift !== undefined) {
            this.elements.pitchSlider.value = data.pitch_shift;
            this.elements.pitchValue.textContent = `${data.pitch_shift.toFixed(2)}x`;
        }

        if (data.buffer_size !== undefined) {
            this.elements.bufferSize.textContent = data.buffer_size;
        }

        if (data.sample_rate !== undefined) {
            this.elements.sampleRate.textContent = `${data.sample_rate} Hz`;
        }
    }

    linearToDb(linear) {
        if (linear <= 0.0) return -Infinity;
        return 20 * Math.log10(linear);
    }

    dbToPercent(db) {
        // Map -60dB to 0%, 0dB to 100%
        const minDb = -60;
        const maxDb = 0;
        const percent = ((db - minDb) / (maxDb - minDb)) * 100;
        return Math.max(0, Math.min(100, percent));
    }

    initEventListeners() {
        // Effect buttons
        const effectButtons = document.querySelectorAll('.effect-btn');
        effectButtons.forEach(btn => {
            btn.addEventListener('click', () => {
                const effect = btn.dataset.effect;
                this.sendCommand('effect', effect);
                this.setActiveEffect(effect);
            });
        });

        // Pitch slider
        this.elements.pitchSlider.addEventListener('input', (e) => {
            const value = parseFloat(e.target.value);
            this.elements.pitchValue.textContent = `${value.toFixed(2)}x`;
        });

        this.elements.pitchSlider.addEventListener('change', (e) => {
            const value = parseFloat(e.target.value);
            this.sendCommand('pitch', value);
        });

        // Gate slider
        this.elements.gateSlider.addEventListener('input', (e) => {
            const value = parseInt(e.target.value);
            this.elements.gateValue.textContent = `${value} dB`;
        });

        this.elements.gateSlider.addEventListener('change', (e) => {
            const value = parseInt(e.target.value);
            // Convert dB to linear
            const linear = Math.pow(10, value / 20);
            this.sendCommand('gate_threshold', linear);
        });
    }

    setActiveEffect(effect) {
        const effectButtons = document.querySelectorAll('.effect-btn');
        effectButtons.forEach(btn => {
            if (btn.dataset.effect === effect) {
                btn.classList.add('active');
            } else {
                btn.classList.remove('active');
            }
        });
    }

    sendCommand(command, value) {
        if (this.ws && this.ws.readyState === WebSocket.OPEN) {
            const message = JSON.stringify({
                type: 'command',
                command: command,
                value: value
            });
            this.ws.send(message);
            console.log('Sent command:', command, value);
        } else {
            console.error('WebSocket not connected');
        }
    }
}

// Initialize the client when the page loads
document.addEventListener('DOMContentLoaded', () => {
    window.changiesClient = new ChangiesClient();
});
