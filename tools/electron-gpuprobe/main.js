// SPDX-License-Identifier: MIT
// Prints Electron's GPU feature status and the WebGL renderer, then exits.
// Usage: electron --ozone-platform=wayland --enable-logging=stderr <this dir>
const { app, BrowserWindow } = require('electron');
app.whenReady().then(async () => {
  const win = new BrowserWindow({ width: 800, height: 600, show: true });
  await win.loadURL('data:text/html,<canvas id=c></canvas>');
  const webgl = await win.webContents.executeJavaScript(`(() => {
    const out = {};
    for (const t of ['webgl2', 'webgl']) {
      const gl = document.getElementById('c').getContext(t);
      if (!gl) { out[t] = null; continue; }
      const d = gl.getExtension('WEBGL_debug_renderer_info');
      out[t] = d ? gl.getParameter(d.UNMASKED_RENDERER_WEBGL) : gl.getParameter(gl.RENDERER);
      break;
    }
    return out;
  })()`);
  let info = {}; try { info = await app.getGPUInfo('basic'); } catch (e) { console.log('PROBE gpuInfoError', e.message); }
  console.log('PROBE featureStatus', JSON.stringify(app.getGPUFeatureStatus()));
  console.log('PROBE gpuDevice', JSON.stringify((info.gpuDevice || []).map(d => [d.vendorString, d.deviceString, d.driverVendor, d.driverVersion])));
  console.log('PROBE webgl', JSON.stringify(webgl));
  app.exit(0);
});
