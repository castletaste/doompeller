import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import test from 'node:test';
import vm from 'node:vm';

async function loadProcessor() {
  let Processor;
  class AudioWorkletProcessor {
    constructor() {
      this.port = new FakePort();
    }
  }
  const context = vm.createContext({
    AudioWorkletProcessor,
    Float32Array,
    Number,
    String,
    registerProcessor(name, implementation) {
      assert.equal(name, 'doompeller-music-output');
      Processor = implementation;
    },
  });
  const source = await readFile(
    new URL('../../web/doom_music_worklet.js', import.meta.url),
    'utf8',
  );
  vm.runInContext(source, context);
  return new Processor();
}

class FakePort {
  messages = [];
  onmessage = null;
  onmessageerror = null;

  postMessage(message) {
    this.messages.push(message);
  }

  start() {}

  send(message) {
    this.onmessage?.({data: message});
  }
}

test('configured-before-retire is cleared and subsequent stale data is fenced', async () => {
  const processor = await loadProcessor();
  const workerPort = new FakePort();
  processor.port.send({type: 'attach', port: workerPort});
  workerPort.send({type: 'configured', epoch: 4});

  assert.equal(
    workerPort.messages.filter((message) => message.type === 'credit').length,
    8,
  );
  for (let index = 0; index < 8; index += 1) {
    workerPort.send({
      type: 'pcm',
      epoch: 4,
      samples: new Float32Array(4096).fill((index + 1) / 10),
    });
  }
  assert.equal(processor.queue.length, 8);

  const left = new Float32Array(128);
  const right = new Float32Array(128);
  processor.process([], [[left, right]]);
  assert.ok(Math.abs(left[0] - 0.1) < 1e-6);
  assert.deepEqual(left, right);

  for (let index = 0; index < 31; index += 1) {
    processor.process([], [[new Float32Array(128), new Float32Array(128)]]);
  }
  assert.equal(processor.queue.length, 7);
  assert.equal(
    workerPort.messages.filter((message) => message.type === 'credit').length,
    9,
  );

  processor.port.send({type: 'retire', epoch: 5});
  assert.equal(processor.queue.length, 0);

  // stopMusic deliberately stays silent until a new configuration. Running
  // the output clock again must neither revive PCM nor replenish old credits.
  const creditsAfterStop = workerPort.messages.filter(
    (message) => message.type === 'credit',
  ).length;
  for (let index = 0; index < 10; index += 1) {
    const stoppedOutput = new Float32Array(128);
    processor.process([], [[stoppedOutput, new Float32Array(128)]]);
    assert.ok(stoppedOutput.every((sample) => sample === 0));
  }
  assert.equal(workerPort.messages.filter(
    (message) => message.type === 'credit',
  ).length, creditsAfterStop);
  workerPort.send({type: 'configured', epoch: 4});
  assert.ok(
    processor.port.messages.some(
      (message) => message.type === 'configured' && message.epoch === 4,
    ),
  );
  workerPort.send({
    type: 'pcm',
    epoch: 4,
    samples: new Float32Array(4096).fill(1),
  });
  assert.equal(processor.queue.length, 0);
});

test('retire-ack-before-configure admits the equal-epoch successor', async () => {
  const processor = await loadProcessor();
  const workerPort = new FakePort();
  processor.port.send({type: 'attach', port: workerPort});

  processor.port.send({type: 'retire', epoch: 7});
  assert.equal(workerPort.messages.at(-1).type, 'retire');
  assert.equal(workerPort.messages.at(-1).epoch, 7);
  workerPort.send({type: 'retired', epoch: 7});
  assert.equal(processor.port.messages.at(-1).type, 'retired');
  assert.equal(processor.port.messages.at(-1).epoch, 7);

  workerPort.send({type: 'configured', epoch: 7});
  assert.equal(
    workerPort.messages.filter((message) => message.type === 'credit').length,
    8,
  );
  workerPort.send({
    type: 'pcm',
    epoch: 7,
    samples: new Float32Array(4096).fill(0.25),
  });
  assert.equal(processor.queue.length, 1);
  const output = new Float32Array(128);
  processor.process([], [[output, new Float32Array(128)]]);
  assert.equal(output[0], 0.25);
});

test('worklet reports a permanent protocol fault on queue overflow', async () => {
  const processor = await loadProcessor();
  const workerPort = new FakePort();
  processor.port.send({type: 'attach', port: workerPort});
  workerPort.send({type: 'configured', epoch: 1});
  for (let index = 0; index < 9; index += 1) {
    workerPort.send({
      type: 'pcm',
      epoch: 1,
      samples: new Float32Array(4096),
    });
  }
  const faults = processor.port.messages.filter(
    (message) => message.type === 'fault',
  );
  assert.equal(faults.length, 1);
  assert.equal(faults[0].fatal, true);
  assert.equal(processor.queue.length, 0);
});
