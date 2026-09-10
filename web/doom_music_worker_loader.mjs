import {compileStreaming} from './doom_music_worker.mjs';

try {
  const compiled = await compileStreaming(fetch('./doom_music_worker.wasm'));
  const application = await compiled.instantiate();
  application.invokeMain();
  postMessage({type: 'ready'});
} catch (error) {
  const message = error instanceof Error ? error.message : String(error);
  postMessage({type: 'fault', fatal: true, message});
  throw error;
}
