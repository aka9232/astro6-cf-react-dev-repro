// @ts-check
import {defineConfig} from 'astro/config';
import react from '@astrojs/react';
import cloudflare from '@astrojs/cloudflare';

// Reproducer: dev 時に client deps optimizer が壊れて react-dom/client が
// 生 CJS で配信され、ブラウザで SyntaxError が出る。
//
// 下の `vite.environments.client.optimizeDeps.noDiscovery: true` を
// コメントアウトすると BUG が再現する。
export default defineConfig({
  output: 'static',
  adapter: cloudflare({imageService: 'passthrough', prerenderEnvironment: 'node'}),
  integrations: [react()],
  devToolbar: {enabled: false},
  server: {port: 4321, host: '127.0.0.1'},
  // vite: {
  //   environments: {
  //     client: {
  //       optimizeDeps: {noDiscovery: true}
  //     }
  //   }
  // }
});
