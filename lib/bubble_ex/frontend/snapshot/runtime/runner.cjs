const fs = require('node:fs');
const {capture} = require('./capture.cjs');
const {build} = require('./package.cjs');
(async () => {
  const [input, output] = process.argv.slice(2);
  const timer = setTimeout(() => process.exit(91), 125000);
  try {
    if (fs.statSync(input).size > 150 * 1024 * 1024) throw new Error('input_too_large');
    const config = JSON.parse(fs.readFileSync(input,'utf8'));
    const result = config.operation === 'capture'
      ? await capture(config.url,config.options,config.modules)
      : build(config.capture,config.modules);
    fs.writeFileSync(output,JSON.stringify({ok:result}),{mode:0o600});
  } catch {
    // Never print page content, request URLs, or browser exceptions containing secrets.
    fs.writeFileSync(output,JSON.stringify({error:'snapshot_backend_failed'}),{mode:0o600});
    process.exitCode = 1;
  } finally { clearTimeout(timer); }
})();
