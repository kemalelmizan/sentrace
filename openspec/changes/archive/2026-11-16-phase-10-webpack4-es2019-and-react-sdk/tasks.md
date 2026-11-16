# Tasks

## 1. ES2018 / ES2019 Syntax Compatibility & XHR Hardening (`packages/sentrace`)

- [x] 1.1 Refactor `packages/sentrace/src/{dsn,stacktrace,scope,envelope,transport,browser,rails,client}.ts` to eliminate all ES2020+ syntax (`?.`, `??`, `??=`, `||=`, `&&=`, non-`declare` class fields, private `#fields`, and parameterless `catch {}`) while preserving nullish boolean/numeric semantics and wrapping `xhr.getResponseHeader("x-request-id")` in `try { ... } catch (_err) {}`
- [x] 1.2 Rebuild `packages/sentrace/dist/*` and synced `app/assets/javascripts/sentrace*.js`, and add `packages/sentrace/test/es2019-compat.test.mjs` plus XHR `getResponseHeader` exception tests verifying zero ES2020+ syntax tokens across all emitted bundles and safe aborted/cross-origin XHR breadcrumb capture

## 2. React `<ErrorBoundary>` (`sentrace/react`) & Legacy Bundler / TypeScript 4.4 Resolution

- [x] 2.1 Implement `packages/sentrace/src/react.ts` (`ErrorBoundary` and `withErrorBoundary`) supporting function/class `FallbackComponent`, React element, and render-function `fallback` forms, `onError`, `onReset`, `beforeCapture`, and `mechanism: { type: "react.error_boundary", handled: false }` + `contexts.react.componentStack`, and update `packages/sentrace/scripts/build.mjs` and `package.json` (`exports`, `files`, optional `react >= 16.8.0` `peerDependencies`, `dist/react.{mjs,cjs,d.ts}`, and top-level `react/{package.json,index.js,index.mjs,index.d.ts}`)
- [x] 2.2 Add `packages/sentrace/test/react.test.mjs` verifying `<ErrorBoundary>`, `withErrorBoundary`, all three `fallback` forms, `resetError()`, event envelope `mechanism` + `componentStack`, ES2019 bundle syntax compliance on `dist/react.*` + `react/*`, and both modern `"exports"` and legacy `node_modules/sentrace/react` module resolution

## 3. `<head>` Meta Ordering Guidance, Documentation & Cross-Stack Verification

- [x] 3.1 Update `lib/generators/sentrace/install/install_generator.rb`, `spec/generators/sentrace/install_generator_spec.rb`, `README.md`, and `packages/sentrace/README.md` to document `<%= sentrace_meta_tags %>` `<head>` script-ordering requirements and `sentrace/react` `<ErrorBoundary>` usage, and verify the generator RSpec spec passes
- [x] 3.2 Run full cross-stack verification (`npm --prefix packages/sentrace run build`, `npm --prefix packages/sentrace test`, `npm pack --dry-run ./packages/sentrace`, `bundle exec rubocop`, Rails 8.1 RSpec, and Rails 6.1 RSpec) and confirm zero regressions

## Workflow follow-up

- Sync delta specs and archive `phase-10-webpack4-es2019-and-react-sdk` once all tasks and verifications pass.
- Validate all main specs with `openspec validate --all --strict --no-interactive`.
