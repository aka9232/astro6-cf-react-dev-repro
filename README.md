# Astro 6 + @astrojs/cloudflare + React 19 + Actions — dev-time SyntaxError repro

When the combination of `@astrojs/cloudflare` adapter + `@astrojs/react` + Astro Actions + a React island is enabled on the Astro 6 dev server, the served `@astrojs/react/dist/client.js` imports `react-dom/client` directly from the raw pnpm CJS file instead of via `.vite/deps`, which raises the following error in the browser at hydrate time:

```
Uncaught SyntaxError: The requested module
  '/node_modules/.pnpm/react-dom@19.2.5_react@19.2.5/node_modules/react-dom/client.js?v=xxxx'
  does not provide an export named 'createRoot'
```

## Reproduction

```bash
pnpm install
pnpm dev
# open http://127.0.0.1:4321/ with DevTools Console
```

Or, without a browser:

```bash
scripts/check.sh
# VERDICT: BUG (react-dom/client NOT optimized — raw CJS served) → exit 0
```

## Workaround

Uncomment the `vite` block at the bottom of `astro.config.mjs`:

```js
vite: {
  environments: {
    client: {
      optimizeDeps: {noDiscovery: true}
    }
  }
}
```

Re-run `pnpm dev` and confirm `VERDICT: FIX` via `scripts/check.sh`.

The adapter stays enabled in dev (so Cloudflare bindings still work). Keep in mind this is only a **stopgap**:

- With `noDiscovery: true`, the Vite docs explicitly warn that *"CJS-only dependencies must be present in `include` during dev"*. Any user dep that is CJS-only (or has ESM wrappers with CJS-style exports) will fail to import the same way this bug fails, unless you add it to `optimizeDeps.include` manually.
- New user deps are no longer auto-pre-bundled, so the initial page load makes more HTTP requests (usually fine for light islands, potentially slow for React-heavy pages).
- HMR itself still works; only dep optimization is affected.

For a proper fix, upstream this patch to Astro itself (see "Smallest upstream fix" below).

## Environment

- `astro` 6.1.8
- `@astrojs/cloudflare` 13.1.10
- `@astrojs/react` 5.0.3
- `react` / `react-dom` 19.2.5
- `vite` 7.3.2 (resolved via the astro 6 dep range)
- `@cloudflare/vite-plugin` 1.32.3 (resolved via @astrojs/cloudflare)
- pnpm 10.29.3, Node 24, darwin

## Minimal reproduction conditions (bisected)

The bug only reproduces when **all four** of the following are in place — removing any one of them makes the bug disappear:

1. `adapter: cloudflare(...)` is active in dev
2. `integrations: [react()]`
3. `src/actions/index.ts` exports at least one `defineAction` (zod is not required)
4. At least one React island hydrated with `client:*`

The following were confirmed irrelevant by bisection: Content Layer, `astro:env`, `@astrojs/sitemap`, custom integrations, `@tailwindcss/vite`, `trailingSlash`, non-prerendered API routes, and the heavy island deps (radix-ui, react-hook-form, FontAwesome, Turnstile, lucide-react, etc.).

## Root cause

A temporary patch was applied to the Vite bundle (`vite/dist/node/chunks/config.js`) to log `env name / id / importer` right before every `depsOptimizer.registerMissingImport()` call inside `tryNodeResolve()`. That produced the following single line:

```
[VITE-PATCH registerMissingImport] {
  "env": "client",
  "id": "astro/actions/runtime/entrypoints/route.js",
  "resolved": "./node_modules/.pnpm/astro@.../astro/dist/actions/runtime/entrypoints/route.js",
  "importer": "./index.html"
}
```

`./index.html` is the default importer Vite uses when `pluginContainer.resolveId(id)` is invoked without an importer argument. The important fact is that a **server-only entry (`astro/actions/runtime/entrypoints/route.js`) is being registered against the client environment's depsOptimizer**. That registration is the origin of the bug.

Searching the Astro source for the code that calls `this.resolve(route.entrypoint)` pinpoints the `buildStart` hook of `astro/dist/vite-plugin-integrations-container/index.js`:

```js
return {
  name: "astro:integration-container",
  // NOTE: no applyToEnvironment filter
  async buildStart() {
    ...
    settings.resolvedInjectedRoutes = await Promise.all(
      settings.injectedRoutes.map((route) => resolveEntryPoint.call(this, route))
    );
  }
};

async function resolveEntryPoint(route) {
  const resolvedId = await this.resolve(route.entrypoint.toString())...;
}
```

Because this plugin has no `applyToEnvironment` filter, it runs in every environment. Meanwhile `@cloudflare/vite-plugin` explicitly kicks `buildStart` on the client environment:

```js
// @cloudflare/vite-plugin/dist/index.mjs:11338
await viteDevServer.environments.client.pluginContainer.buildStart();
```

So on the client environment, Astro's `astro:integration-container` plugin calls `this.resolve('astro/actions/runtime/entrypoints/route.js')` from a *client*-environment context, which flows through Vite's `tryNodeResolve` and lands on the **client** depsOptimizer's `registerMissingImport`.

On the Vite side, if that registration lands before `depsOptimizer.init()` has had a chance to seed `addManuallyIncludedOptimizeDeps()`, the subsequent `debouncedProcessing()` triggers `runOptimizeDeps()` while `prepareKnownDeps()` only sees `{route.js}`. The resulting `_metadata.json` then contains `astro/actions/runtime/entrypoints/route.js` as the sole entry, and the manual includes (`react`, `react-dom`, `react-dom/client`, `@astrojs/react/client.js`, …) never recover for the rest of the dev server lifetime.

## Smallest upstream fix (one line, on the Astro side)

Adding an `applyToEnvironment` filter to `astro/dist/vite-plugin-integrations-container/index.js` breaks the chain:

```js
import {isAstroClientEnvironment} from '../environments.js';

return {
  name: "astro:integration-container",
  applyToEnvironment(environment) {
    return !isAstroClientEnvironment(environment); // run in ssr | prerender | astro, not in client
  },
  // ...
};
```

Notes:

- The filter excludes the `client` environment only. The plugin still runs in `ssr`, `prerender`, and `astro` (the Runnable dev SSR env), so `settings.resolvedInjectedRoutes` is still populated by the first non-client env to reach `buildStart`. The state is shared via the `settings` closure so other non-client envs early-return on the `length` check.
- `configureServer` keeps working: Vite executes `configureServer` hooks from the top-level plugin list (`config.getSortedPluginHooks("configureServer")`), not via the per-environment plugin pipeline, so `applyToEnvironment` has no effect on it.
- Alternative minimal patch: keep the plugin in all envs and early-return inside `buildStart` when `this.environment.name === "client"`. Works, but the `applyToEnvironment` version is more declarative and protects future env-sensitive hooks added to the same plugin.

What the `buildStart` hook is doing here is resolving server-only injected route entrypoints, so there is no reason to run it on the client environment at all.

## Related issues

- [vitejs/vite#19323](https://github.com/vitejs/vite/issues/19323) — covers the same environment-aware optimizer territory, but the issue and the proposed fix in [vitejs/vite#21818](https://github.com/vitejs/vite/pull/21818) are explicitly scoped to **server** environments ("Client dep optimization is unchanged"). This bug is about the **client** environment and is not covered by that fix.

## Repository layout

```
.
├── astro.config.mjs              # minimal config; uncomment the vite block
│                                  # at the bottom to apply the workaround
├── package.json                  # deps: astro, @astrojs/cloudflare,
│                                  # @astrojs/react, react, react-dom
├── tsconfig.json
├── src/
│   ├── actions/index.ts          # one defineAction (no zod)
│   ├── components/react/
│   │   └── Counter.tsx           # useState only
│   └── pages/
│       └── index.astro           # <Counter client:load />
└── scripts/
    └── check.sh                  # start dev → inspect _metadata.json → kill
```
