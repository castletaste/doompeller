const BLOCK_FRAMES = 4096;
const MAX_QUEUE_BLOCKS = 8;

class DoompellerMusicOutput extends AudioWorkletProcessor {
  constructor() {
    super();
    this.epoch = 0;
    this.workerPort = null;
    this.queue = [];
    this.offset = 0;
    this.started = false;
    this.playedFrames = 0;
    this.underruns = 0;
    this.latestWorkerStats = null;
    this.failed = false;
    this.port.onmessage = (event) => this.onControl(event.data);
  }

  onControl(message) {
    if (this.failed && message?.type !== 'stats') return;
    if (!message || typeof message.type !== 'string') return;
    switch (message.type) {
      case 'attach':
        if (!message.port || this.workerPort) return;
        this.workerPort = message.port;
        this.workerPort.onmessage = (event) => this.onWorkerMessage(event.data);
        this.workerPort.onmessageerror = () => {
          this.reportFault('The music PCM channel received an invalid message.', true);
        };
        this.workerPort.start();
        break;
      case 'retire':
        // Retirement discards this score and its credits. Only a subsequent
        // configure starts a new score with eight fresh credits. Pause/blur
        // suspend the AudioContext instead and never retire this queue.
        if (!Number.isSafeInteger(message.epoch) || message.epoch < this.epoch) return;
        this.epoch = message.epoch;
        this.queue.length = 0;
        this.offset = 0;
        this.started = false;
        this.workerPort?.postMessage({type: 'retire', epoch: this.epoch});
        break;
      case 'stats':
        this.port.postMessage({
          type: 'stats',
          epoch: this.epoch,
          queuedBlocks: this.queue.length,
          playedFrames: this.playedFrames,
          underruns: this.underruns,
          worker: this.latestWorkerStats,
        });
        break;
    }
  }

  onWorkerMessage(message) {
    if (this.failed) return;
    if (!message || typeof message.type !== 'string') return;
    switch (message.type) {
      case 'configured':
        if (!Number.isSafeInteger(message.epoch)) return;
        this.port.postMessage({type: 'configured', epoch: message.epoch});
        if (message.epoch < this.epoch) return;
        this.epoch = message.epoch;
        this.queue.length = 0;
        this.offset = 0;
        this.started = false;
        for (let index = 0; index < MAX_QUEUE_BLOCKS; index += 1) {
          this.requestBlock();
        }
        break;
      case 'retired':
        if (!Number.isSafeInteger(message.epoch)) return;
        this.port.postMessage({type: 'retired', epoch: message.epoch});
        break;
      case 'pcm':
        if (message.epoch !== this.epoch || !(message.samples instanceof Float32Array)) {
          return;
        }
        if (message.samples.length !== BLOCK_FRAMES || this.queue.length >= MAX_QUEUE_BLOCKS) {
          this.reportFault('The music worker violated the bounded PCM protocol.', true);
          return;
        }
        this.queue.push(message.samples);
        break;
      case 'fault':
        this.port.postMessage({
          type: 'fault',
          epoch: message.epoch,
          fatal: message.fatal === true,
          message: String(message.message || 'The OPL2 worker failed.'),
        });
        if (message.epoch === this.epoch) {
          this.queue.length = 0;
          this.offset = 0;
          this.started = false;
        }
        break;
      case 'workerStats':
        if (message.epoch === this.epoch) this.latestWorkerStats = message;
        break;
    }
  }

  requestBlock() {
    this.workerPort?.postMessage({
      type: 'credit',
      epoch: this.epoch,
      frames: BLOCK_FRAMES,
    });
  }

  reportFault(message, fatal) {
    this.queue.length = 0;
    this.offset = 0;
    this.started = false;
    if (fatal) this.failed = true;
    this.port.postMessage({type: 'fault', epoch: this.epoch, fatal, message});
  }

  process(_inputs, outputs) {
    const output = outputs[0];
    if (!output || output.length === 0) return true;
    const left = output[0];
    const right = output[1] || left;
    let frame = 0;

    while (frame < left.length && this.queue.length > 0) {
      const block = this.queue[0];
      const count = Math.min(left.length - frame, block.length - this.offset);
      for (let index = 0; index < count; index += 1) {
        const sample = block[this.offset + index];
        left[frame + index] = sample;
        right[frame + index] = sample;
      }
      frame += count;
      this.offset += count;
      this.playedFrames += count;
      if (this.offset === block.length) {
        this.queue.shift();
        this.offset = 0;
        this.requestBlock();
      }
    }

    if (frame < left.length && this.started) this.underruns += 1;
    if (frame > 0) this.started = true;
    return true;
  }
}

registerProcessor('doompeller-music-output', DoompellerMusicOutput);
