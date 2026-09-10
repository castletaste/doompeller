{{flutter_js}}
{{flutter_build_config}}

(() => {
  const fail = (error) => {
    console.error('Doompeller startup failed', error);
    window.doomLoader.fail();
  };
  try {
    Promise.resolve(_flutter.loader.load({
      onEntrypointLoaded: async (initializer) => {
        try {
          const runner = await initializer.initializeEngine();
          await runner.runApp();
          window.doomLoader.complete();
        } catch (error) { fail(error); }
      }
    })).catch(fail);
  } catch (error) { fail(error); }
})();
