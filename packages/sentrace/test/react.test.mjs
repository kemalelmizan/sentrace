import assert from "node:assert/strict";
import fs from "node:fs";
import { createRequire } from "node:module";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath, pathToFileURL } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const pkgRoot = path.resolve(__dirname, "..");

const MOCK_REACT_INDEX_CJS = `"use strict";
const ELEMENT_TYPE = Symbol.for("react.element");
let activeHookDispatcher = null;

function Component(props) {
  this.props = props || {};
  this.state = undefined;
  this.__updater = null;
}
Component.prototype.isReactComponent = {};
Component.prototype.setState = function setState(partial) {
  const nextPartial = typeof partial === "function" ? partial(this.state, this.props) : partial;
  this.state = Object.assign({}, this.state || {}, nextPartial || {});
  if (typeof this.__updater === "function") {
    this.__updater();
  }
};

function createElement(type, config) {
  const props = Object.assign({}, config || {});
  const childCount = arguments.length - 2;
  if (childCount === 1) {
    props.children = arguments[2];
  } else if (childCount > 1) {
    const childArray = new Array(childCount);
    for (let i = 0; i < childCount; i += 1) {
      childArray[i] = arguments[i + 2];
    }
    props.children = childArray;
  }
  return {
    $$typeof: ELEMENT_TYPE,
    type: type,
    props: props
  };
}

function isValidElement(object) {
  return typeof object === "object" && object !== null && object.$$typeof === ELEMENT_TYPE;
}

function useState(initialValue) {
  if (!activeHookDispatcher) {
    throw new Error("Invalid hook call. Hooks can only be called inside of the body of a function component.");
  }
  return activeHookDispatcher.useState(initialValue);
}

function getComponentName(type) {
  if (typeof type === "string") {
    return type;
  }
  if (typeof type === "function") {
    return type.displayName || type.name || "Anonymous";
  }
  return "Unknown";
}

function mountTree(rootElement) {
  const instances = new Map();
  let latestOutput = null;

  function renderNode(node, pathKey, ancestorStack) {
    if (node === null || node === undefined || typeof node === "boolean") {
      return null;
    }
    if (typeof node === "string" || typeof node === "number") {
      return String(node);
    }
    if (Array.isArray(node)) {
      return node.map((item, idx) => renderNode(item, pathKey + "." + idx, ancestorStack));
    }
    if (!isValidElement(node)) {
      return node;
    }

    const type = node.type;
    const nextStack = [getComponentName(type)].concat(ancestorStack);

    if (typeof type === "string") {
      const renderedChildren =
        node.props.children !== undefined
          ? renderNode(node.props.children, pathKey + "/" + type, nextStack)
          : null;
      return {
        tag: type,
        props: node.props,
        children: renderedChildren
      };
    }

    const isClass = Boolean(type && type.prototype && type.prototype.isReactComponent);
    if (isClass) {
      let inst = instances.get(pathKey);
      if (!inst || inst.constructor !== type) {
        inst = new type(node.props);
        inst.__updater = () => {
          latestOutput = renderNode(rootElement, "root", []);
        };
        instances.set(pathKey, inst);
      } else {
        inst.props = node.props;
      }

      try {
        const sub = inst.render();
        return renderNode(sub, pathKey + "/" + getComponentName(type), nextStack);
      } catch (err) {
        const canCatch =
          typeof type.getDerivedStateFromError === "function" ||
          typeof inst.componentDidCatch === "function";
        if (!canCatch) {
          if (!err.__componentStack) {
            err.__componentStack = nextStack.map((n) => "\\n    in " + n).join("");
          }
          throw err;
        }

        const componentStack = err.__componentStack || nextStack.map((n) => "\\n    in " + n).join("");
        if (typeof type.getDerivedStateFromError === "function") {
          const derived = type.getDerivedStateFromError(err);
          inst.state = Object.assign({}, inst.state || {}, derived || {});
        }
        if (typeof inst.componentDidCatch === "function") {
          const prevUpdater = inst.__updater;
          inst.__updater = null;
          try {
            inst.componentDidCatch(err, { componentStack: componentStack });
          } finally {
            inst.__updater = prevUpdater;
          }
        }
        const fallbackSub = inst.render();
        return renderNode(fallbackSub, pathKey + "/" + getComponentName(type) + ":fallback", nextStack);
      }
    }

    if (typeof type === "function") {
      const hookStates = [];
      let hookIdx = 0;
      const prevDispatcher = activeHookDispatcher;
      activeHookDispatcher = {
        useState(initVal) {
          const idx = hookIdx++;
          if (!(idx in hookStates)) {
            hookStates[idx] = typeof initVal === "function" ? initVal() : initVal;
          }
          return [
            hookStates[idx],
            (nextVal) => {
              hookStates[idx] = nextVal;
            }
          ];
        }
      };
      let sub;
      try {
        sub = type(node.props);
      } catch (err) {
        if (!err.__componentStack) {
          err.__componentStack = nextStack.map((n) => "\\n    in " + n).join("");
        }
        throw err;
      } finally {
        activeHookDispatcher = prevDispatcher;
      }
      return renderNode(sub, pathKey + "/" + getComponentName(type), nextStack);
    }

    return null;
  }

  latestOutput = renderNode(rootElement, "root", []);
  return {
    getOutput() {
      return latestOutput;
    },
    rerender(nextRoot) {
      if (nextRoot !== undefined) {
        rootElement = nextRoot;
      }
      latestOutput = renderNode(rootElement, "root", []);
      return latestOutput;
    }
  };
}

module.exports = {
  Component: Component,
  createElement: createElement,
  isValidElement: isValidElement,
  useState: useState,
  __mountTree: mountTree
};
`;

function createSimulatedNodeModulesWorkspace() {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "sentrace-react-test-"));
  fs.writeFileSync(
    path.join(tmpDir, "package.json"),
    JSON.stringify({ name: "consumer-app", private: true }, null, 2)
  );

  // Install simulated `react` 17 package
  const reactPkgDir = path.join(tmpDir, "node_modules/react");
  fs.mkdirSync(reactPkgDir, { recursive: true });
  fs.writeFileSync(
    path.join(reactPkgDir, "package.json"),
    JSON.stringify({ name: "react", version: "17.0.2", main: "./index.js" }, null, 2)
  );
  fs.writeFileSync(path.join(reactPkgDir, "index.js"), MOCK_REACT_INDEX_CJS);

  // Copy published `sentrace` files (`package.json`, `dist/`, `react/`) into `node_modules/sentrace`
  const sentracePkgDir = path.join(tmpDir, "node_modules/sentrace");
  fs.mkdirSync(sentracePkgDir, { recursive: true });
  fs.copyFileSync(path.join(pkgRoot, "package.json"), path.join(sentracePkgDir, "package.json"));
  fs.cpSync(path.join(pkgRoot, "dist"), path.join(sentracePkgDir, "dist"), { recursive: true });
  fs.cpSync(path.join(pkgRoot, "react"), path.join(sentracePkgDir, "react"), { recursive: true });

  return {
    tmpDir,
    sentracePkgDir,
    cleanup() {
      fs.rmSync(tmpDir, { recursive: true, force: true });
    }
  };
}

test("package.json declares zero runtime dependencies and optional react >= 16.8.0 peerDependency with legacy react/ directory", () => {
  const pkgJson = JSON.parse(fs.readFileSync(path.join(pkgRoot, "package.json"), "utf8"));
  assert.equal(pkgJson.dependencies, undefined);
  assert.deepEqual(pkgJson.peerDependencies, { react: ">=16.8.0" });
  assert.deepEqual(pkgJson.peerDependenciesMeta, { react: { optional: true } });
  assert.ok(pkgJson.files.includes("dist"));
  assert.ok(pkgJson.files.includes("react"));
  assert.deepEqual(pkgJson.exports["./react"], {
    types: "./dist/react.d.ts",
    import: "./dist/react.mjs",
    require: "./dist/react.cjs"
  });

  // Verify legacy Webpack 4 & TypeScript 4.4 (`"moduleResolution": "node"`) files exist and avoid TS 4.5+ syntax
  const reactSubPkg = JSON.parse(fs.readFileSync(path.join(pkgRoot, "react/package.json"), "utf8"));
  assert.equal(reactSubPkg.type, "commonjs");
  assert.equal(reactSubPkg.main, "./index.js");
  assert.equal(reactSubPkg.module, "./index.mjs");
  assert.equal(reactSubPkg.types, "./index.d.ts");

  const reactSubDts = fs.readFileSync(path.join(pkgRoot, "react/index.d.ts"), "utf8");
  const distReactDts = fs.readFileSync(path.join(pkgRoot, "dist/react.d.ts"), "utf8");
  for (const dtsContent of [reactSubDts, distReactDts]) {
    assert.ok(!/from\s+["'][^"']+\.d\.ts["']/.test(dtsContent), "Must not use .d.ts specifier extensions in TS 4.4");
    assert.ok(!/import\s*\{[^}]*\btype\s+/.test(dtsContent), "Must not use TS 4.5 inline import { type X } modifier");
  }
});

test("sentrace/react resolves via modern ESM/CJS exports AND legacy Webpack 4 react/ directory and supports all 3 fallback forms", async () => {
  const ws = createSimulatedNodeModulesWorkspace();
  try {
    const consumerRequire = createRequire(path.join(ws.tmpDir, "index.js"));
    const React = consumerRequire("react");

    // 1. Modern CommonJS resolution (`require("sentrace")` + `require("sentrace/react")`)
    const SentraceCjs = consumerRequire("sentrace");
    const SentraceReactCjs = consumerRequire("sentrace/react");
    assert.equal(typeof SentraceReactCjs.ErrorBoundary, "function");
    assert.equal(typeof SentraceReactCjs.withErrorBoundary, "function");
    assert.equal(SentraceReactCjs.default.ErrorBoundary, SentraceReactCjs.ErrorBoundary);

    // 2. Legacy CommonJS directory resolution (`node_modules/sentrace/react/index.js`, ignoring root exports)
    const LegacyReactCjs = consumerRequire(path.join(ws.sentracePkgDir, "react/index.js"));
    assert.equal(LegacyReactCjs.ErrorBoundary, SentraceReactCjs.ErrorBoundary);

    // 3. Modern ESM + Legacy Webpack 4 ESM (`module: "./index.mjs"`) resolution
    const esmRunnerPath = path.join(ws.tmpDir, "verify-esm.mjs");
    fs.writeFileSync(
      esmRunnerPath,
      [
        'import * as Sentrace from "sentrace";',
        'import SentraceReactDefault, { ErrorBoundary, withErrorBoundary } from "sentrace/react";',
        'import { ErrorBoundary as LegacyEsmBoundary } from "./node_modules/sentrace/react/index.mjs";',
        "export { Sentrace, SentraceReactDefault, ErrorBoundary, withErrorBoundary, LegacyEsmBoundary };"
      ].join("\n")
    );
    const esmLoaded = await import(pathToFileURL(esmRunnerPath).href);
    assert.equal(esmLoaded.ErrorBoundary, esmLoaded.LegacyEsmBoundary);
    assert.equal(esmLoaded.SentraceReactDefault.ErrorBoundary, esmLoaded.ErrorBoundary);

    // Exercise ErrorBoundary end-to-end with Sentrace ESM client
    const { Sentrace, ErrorBoundary, withErrorBoundary } = esmLoaded;
    Sentrace.resetClient();

    const envelopes = [];
    Sentrace.init({
      dsn: "https://pub_react@errors.example.com/sentrace/12",
      environment: "production",
      release: "2026.11.16",
      autoInstrumentBrowser: false,
      railsIntegration: false,
      transport: () => ({
        send: async (raw) => {
          const [, , payload] = raw.trimEnd().split("\n");
          envelopes.push(JSON.parse(payload));
          return { statusCode: 200 };
        },
        flush: async () => true
      })
    });

    let shouldCrash = true;
    function BrokenWidget(props) {
      if (shouldCrash) {
        throw new TypeError(`Cannot render widget ${props.label}`);
      }
      return React.createElement("span", { id: "healthy" }, `Healthy: ${props.label}`);
    }

    // Case A: Function FallbackComponent using React Hooks (`useState`) + beforeCapture + onError + resetError/onReset
    function HookFallbackComponent(props) {
      const [badge] = React.useState("hook-ok");
      return React.createElement(
        "div",
        {
          id: "fn-fallback",
          "data-badge": badge,
          "data-event-id": props.eventId,
          onResetClick: props.resetError
        },
        props.error.message
      );
    }

    let onErrorArgs = null;
    let onResetArgs = null;

    const mountedA = React.__mountTree(
      React.createElement(
        ErrorBoundary,
        {
          fallback: HookFallbackComponent,
          beforeCapture(scope) {
            scope.setTag("react.surface", "dashboard");
          },
          onError(error, componentStack, eventId) {
            onErrorArgs = { error, componentStack, eventId };
          },
          onReset(error, componentStack, eventId) {
            onResetArgs = { error, componentStack, eventId };
          }
        },
        React.createElement(BrokenWidget, { label: "chart" })
      )
    );

    const outA = mountedA.getOutput();
    assert.equal(outA.tag, "div");
    assert.equal(outA.props.id, "fn-fallback");
    assert.equal(outA.props["data-badge"], "hook-ok");
    assert.equal(outA.children, "Cannot render widget chart");
    assert.match(outA.props["data-event-id"], /^[0-9a-f]{32}$/);

    // Verify captured Sentry v7 event envelope contract
    assert.equal(envelopes.length, 1);
    const evA = envelopes[0];
    assert.equal(evA.event_id, outA.props["data-event-id"]);
    assert.equal(evA.exception.values[0].type, "TypeError");
    assert.equal(evA.exception.values[0].value, "Cannot render widget chart");
    assert.deepEqual(evA.exception.values[0].mechanism, {
      type: "react.error_boundary",
      handled: false
    });
    assert.equal(evA.tags["react.surface"], "dashboard");
    assert.ok(evA.contexts.react.componentStack.includes("in BrokenWidget"));
    assert.ok(evA.contexts.react.componentStack.includes("in ErrorBoundary"));

    assert.ok(onErrorArgs);
    assert.equal(onErrorArgs.eventId, evA.event_id);
    assert.equal(onErrorArgs.componentStack, evA.contexts.react.componentStack);

    // Scoped tag from beforeCapture must NOT leak outside ErrorBoundary capture
    Sentrace.captureMessage("Outside boundary");
    assert.equal(envelopes.length, 2);
    assert.equal(envelopes[1].tags?.["react.surface"], undefined);

    // Calling resetError() triggers onReset and restores healthy children!
    shouldCrash = false;
    outA.props.onResetClick();
    assert.ok(onResetArgs);
    assert.equal(onResetArgs.eventId, evA.event_id);
    const recoveredA = mountedA.getOutput();
    assert.equal(recoveredA.tag, "span");
    assert.equal(recoveredA.children, "Healthy: chart");

    // Case B: Class FallbackComponent (`extends React.Component`)
    shouldCrash = true;
    class ClassFallbackComponent extends React.Component {
      render() {
        return React.createElement("section", { id: "class-fallback" }, `Class caught: ${this.props.error.message}`);
      }
    }
    const mountedB = React.__mountTree(
      React.createElement(
        ErrorBoundary,
        { fallback: ClassFallbackComponent },
        React.createElement(BrokenWidget, { label: "table" })
      )
    );
    assert.equal(mountedB.getOutput().tag, "section");
    assert.equal(mountedB.getOutput().children, "Class caught: Cannot render widget table");

    // Case C: React Element fallback (`fallback={<div />}`)
    const staticElement = React.createElement("p", { id: "element-fallback" }, "Static fallback UI");
    const mountedC = React.__mountTree(
      React.createElement(
        ErrorBoundary,
        { fallback: staticElement },
        React.createElement(BrokenWidget, { label: "sidebar" })
      )
    );
    assert.equal(mountedC.getOutput().tag, "p");
    assert.equal(mountedC.getOutput().children, "Static fallback UI");

    // Case D: Render function fallback & `withErrorBoundary` HOC
    const GuardedWidget = withErrorBoundary(BrokenWidget, {
      fallback: ({ error, eventId }) =>
        React.createElement("aside", { "data-eid": eventId }, `RenderFn: ${error.message}`)
    });
    assert.equal(GuardedWidget.displayName, "errorBoundary(BrokenWidget)");

    const mountedD = React.__mountTree(React.createElement(GuardedWidget, { label: "hoc" }));
    assert.equal(mountedD.getOutput().tag, "aside");
    assert.equal(mountedD.getOutput().children, "RenderFn: Cannot render widget hoc");
    assert.match(mountedD.getOutput().props["data-eid"], /^[0-9a-f]{32}$/);

    // Case E: Graceful fallback when Sentrace is NOT initialized
    await Sentrace.close();
    const mountedE = React.__mountTree(
      React.createElement(
        ErrorBoundary,
        { fallback: ({ eventId }) => React.createElement("div", { "data-eid": eventId }, "Offline fallback") },
        React.createElement(BrokenWidget, { label: "uninitialized" })
      )
    );
    assert.equal(mountedE.getOutput().children, "Offline fallback");
    assert.match(mountedE.getOutput().props["data-eid"], /^[0-9a-f]{32}$/);
  } finally {
    ws.cleanup();
  }
});
