import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import vm from "node:vm";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const pkgRoot = path.resolve(__dirname, "..");
const repoRoot = path.resolve(pkgRoot, "../..");

const REGEX_PRECEDING_KEYWORDS = new Set([
  "return",
  "throw",
  "case",
  "typeof",
  "void",
  "delete",
  "in",
  "of",
  "instanceof",
  "new",
  "yield",
  "await",
  "else",
  "do"
]);

const REGEX_PRECEDING_PUNCTUATORS = new Set([
  "(",
  "[",
  "{",
  "}",
  ",",
  ";",
  ":",
  "=",
  "!",
  "?",
  "&",
  "|",
  "^",
  "~",
  "+",
  "-",
  "*",
  "%",
  "<",
  ">"
]);

/**
 * Strips comments, string literals, template literal text chunks, and RegExp literals
 * into spaces while preserving newlines and `${...}` template expression code.
 */
export function maskNonCodeSegments(source) {
  const out = [];
  const len = source.length;
  let i = 0;
  let lastSigChar = "{";
  let lastWord = "";
  const templateBraceStack = [];

  const pushMask = (ch) => {
    out.push(ch === "\n" ? "\n" : " ");
  };

  while (i < len) {
    const ch = source[i];
    const next = source[i + 1];

    // Single-line comment
    if (ch === "/" && next === "/") {
      while (i < len && source[i] !== "\n") {
        pushMask(source[i]);
        i += 1;
      }
      continue;
    }

    // Multi-line comment
    if (ch === "/" && next === "*") {
      pushMask(ch);
      pushMask(next);
      i += 2;
      while (i < len && !(source[i] === "*" && source[i + 1] === "/")) {
        pushMask(source[i]);
        i += 1;
      }
      if (i < len) {
        pushMask(source[i]);
        pushMask(source[i + 1]);
        i += 2;
      }
      continue;
    }

    // Single or double quoted string
    if (ch === "'" || ch === '"') {
      const quote = ch;
      out.push('"');
      i += 1;
      while (i < len && source[i] !== quote) {
        if (source[i] === "\\") {
          pushMask(source[i]);
          i += 1;
          if (i < len) {
            pushMask(source[i]);
            i += 1;
          }
          continue;
        }
        pushMask(source[i]);
        i += 1;
      }
      if (i < len) {
        out.push('"');
        i += 1;
      }
      lastSigChar = '"';
      lastWord = "";
      continue;
    }

    // Template literal start
    if (ch === "`") {
      out.push('"');
      i += 1;
      while (i < len && source[i] !== "`") {
        if (source[i] === "\\") {
          pushMask(source[i]);
          i += 1;
          if (i < len) {
            pushMask(source[i]);
            i += 1;
          }
          continue;
        }
        if (source[i] === "$" && source[i + 1] === "{") {
          out.push("+(");
          i += 2;
          templateBraceStack.push(0);
          lastSigChar = "(";
          lastWord = "";
          break;
        }
        pushMask(source[i]);
        i += 1;
      }
      if (i < len && source[i] === "`") {
        out.push('"');
        i += 1;
        lastSigChar = '"';
        lastWord = "";
      }
      continue;
    }

    // Inside `${ ... }` of a template literal
    if (templateBraceStack.length > 0) {
      if (ch === "{") {
        templateBraceStack[templateBraceStack.length - 1] += 1;
      } else if (ch === "}") {
        const depth = templateBraceStack[templateBraceStack.length - 1];
        if (depth === 0) {
          templateBraceStack.pop();
          out.push(')+"');
          i += 1;
          // Resume scanning template literal text
          while (i < len && source[i] !== "`") {
            if (source[i] === "\\") {
              pushMask(source[i]);
              i += 1;
              if (i < len) {
                pushMask(source[i]);
                i += 1;
              }
              continue;
            }
            if (source[i] === "$" && source[i + 1] === "{") {
              out.push('"+(');
              i += 2;
              templateBraceStack.push(0);
              lastSigChar = "(";
              lastWord = "";
              break;
            }
            pushMask(source[i]);
            i += 1;
          }
          if (i < len && source[i] === "`") {
            out.push('"');
            i += 1;
            lastSigChar = '"';
            lastWord = "";
          }
          continue;
        }
        templateBraceStack[templateBraceStack.length - 1] -= 1;
      }
    }

    // RegExp literal vs division operator
    if (ch === "/") {
      const canStartRegex =
        REGEX_PRECEDING_PUNCTUATORS.has(lastSigChar) ||
        (lastWord.length > 0 && REGEX_PRECEDING_KEYWORDS.has(lastWord));
      if (canStartRegex) {
        out.push("0");
        i += 1;
        let inCharClass = false;
        while (i < len) {
          const rch = source[i];
          if (rch === "\\") {
            pushMask(rch);
            i += 1;
            if (i < len) {
              pushMask(source[i]);
              i += 1;
            }
            continue;
          }
          if (rch === "[") {
            inCharClass = true;
          } else if (rch === "]") {
            inCharClass = false;
          } else if (rch === "/" && !inCharClass) {
            pushMask(rch);
            i += 1;
            while (i < len && /[a-z]/i.test(source[i])) {
              pushMask(source[i]);
              i += 1;
            }
            break;
          }
          pushMask(rch);
          i += 1;
        }
        lastSigChar = "0";
        lastWord = "";
        continue;
      }
    }

    // Identifier / keyword tracking
    if (/[A-Za-z_$]/.test(ch)) {
      let word = "";
      while (i < len && /[A-Za-z0-9_$]/.test(source[i])) {
        word += source[i];
        out.push(source[i]);
        i += 1;
      }
      lastWord = word;
      lastSigChar = word[word.length - 1];
      continue;
    }

    out.push(ch);
    if (!/\s/.test(ch)) {
      lastSigChar = ch;
      lastWord = "";
    }
    i += 1;
  }

  return out.join("");
}

function lineNumberAt(source, index) {
  let line = 1;
  for (let i = 0; i < index && i < source.length; i += 1) {
    if (source[i] === "\n") {
      line += 1;
    }
  }
  return line;
}

function detectClassFieldViolations(maskedCode) {
  const violations = [];
  const classRegex = /\bclass(?:\s+[A-Za-z_$][A-Za-z0-9_$]*)?(?:\s+extends\s+[^{]+)?\s*\{/g;
  let match;

  while ((match = classRegex.exec(maskedCode)) !== null) {
    let idx = match.index + match[0].length;
    let braceDepth = 1;
    let memberStart = idx;

    while (idx < maskedCode.length && braceDepth > 0) {
      const ch = maskedCode[idx];
      if (ch === "{") {
        if (braceDepth === 1) {
          // Verify header before `{` is a method/constructor/getter/setter, not `prop = { ... }` or `prop = () => { ... }`
          const header = maskedCode.slice(memberStart, idx).trim();
          const eqIdx = header.indexOf("=");
          const parenIdx = header.indexOf("(");
          if (eqIdx !== -1 && (parenIdx === -1 || eqIdx < parenIdx)) {
            violations.push({
              rule: "es2022-class-field",
              line: lineNumberAt(maskedCode, memberStart),
              snippet: header.slice(0, 60)
            });
          }
        }
        braceDepth += 1;
      } else if (ch === "}") {
        braceDepth -= 1;
        if (braceDepth === 1) {
          memberStart = idx + 1;
        } else if (braceDepth === 0) {
          const trailing = maskedCode.slice(memberStart, idx).trim();
          if (trailing && trailing !== ";") {
            violations.push({
              rule: "es2022-class-field",
              line: lineNumberAt(maskedCode, memberStart),
              snippet: trailing.slice(0, 60)
            });
          }
        }
      } else if (ch === ";" && braceDepth === 1) {
        const statement = maskedCode.slice(memberStart, idx).trim();
        if (statement.length > 0) {
          violations.push({
            rule: "es2022-class-field",
            line: lineNumberAt(maskedCode, memberStart),
            snippet: statement.slice(0, 60)
          });
        }
        memberStart = idx + 1;
      }
      idx += 1;
    }
  }

  return violations;
}

export function findEs2020PlusViolations(source) {
  const masked = maskNonCodeSegments(source);
  const violations = [];

  const rules = [
    { name: "optional-chaining", regex: /\?\.(?![0-9])/g },
    { name: "nullish-coalescing", regex: /\?\?/g },
    { name: "logical-or-assignment", regex: /\|\|=/g },
    { name: "logical-and-assignment", regex: /&&=/g },
    { name: "private-class-identifier", regex: /#[A-Za-z_$][A-Za-z0-9_$]*/g },
    { name: "optional-catch-binding", regex: /\bcatch\s*\{/g }
  ];

  for (const rule of rules) {
    let m;
    while ((m = rule.regex.exec(masked)) !== null) {
      // Ignore top-level shebang `#!` if any
      if (rule.name === "private-class-identifier" && m.index === 0 && source.startsWith("#!")) {
        continue;
      }
      violations.push({
        rule: rule.name,
        line: lineNumberAt(masked, m.index),
        snippet: m[0]
      });
    }
  }

  violations.push(...detectClassFieldViolations(masked));
  return violations;
}

test("ES2020+ syntax scanner accurately flags ES2020-ES2022 tokens and ignores strings/comments/regexes", () => {
  assert.equal(findEs2020PlusViolations('const s = "a?.b ?? c"; // x?.y\nconst r = /\\?\\.|\\?\\?/g;').length, 0);
  assert.equal(
    findEs2020PlusViolations(
      "class Clean { constructor(x) { this.x = x; } run(d = 20) { try { return this.x + d; } catch (e) { return null; } } }"
    ).length,
    0
  );

  assert.equal(findEs2020PlusViolations("const v = obj?.prop;")[0]?.rule, "optional-chaining");
  assert.equal(findEs2020PlusViolations("const v = fn?.();")[0]?.rule, "optional-chaining");
  assert.equal(findEs2020PlusViolations("const v = a ?? b;")[0]?.rule, "nullish-coalescing");
  assert.equal(findEs2020PlusViolations("a ??= 1;")[0]?.rule, "nullish-coalescing");
  assert.equal(findEs2020PlusViolations("a ||= 1;")[0]?.rule, "logical-or-assignment");
  assert.equal(findEs2020PlusViolations("a &&= 1;")[0]?.rule, "logical-and-assignment");
  assert.equal(findEs2020PlusViolations("try {} catch {}")[0]?.rule, "optional-catch-binding");
  assert.equal(findEs2020PlusViolations("class Bad { field = 1; }")[0]?.rule, "es2022-class-field");
  assert.equal(findEs2020PlusViolations("class Bad { arrow = () => {}; }")[0]?.rule, "es2022-class-field");
  assert.equal(findEs2020PlusViolations("class Bad { bareField; }")[0]?.rule, "es2022-class-field");
  assert.equal(findEs2020PlusViolations("class Bad { #secret() {} }")[0]?.rule, "private-class-identifier");
});

test("All emitted JS/MJS/CJS bundles in dist/, react/, and app/assets/javascripts/ contain zero ES2020+ syntax tokens", () => {
  const dirsToScan = [
    path.join(pkgRoot, "dist"),
    path.join(pkgRoot, "react"),
    path.join(repoRoot, "app/assets/javascripts")
  ];

  const bundleFiles = [];
  for (const dir of dirsToScan) {
    if (!fs.existsSync(dir)) {
      continue;
    }
    for (const entry of fs.readdirSync(dir)) {
      if (/\.(?:js|mjs|cjs)$/.test(entry)) {
        bundleFiles.push(path.join(dir, entry));
      }
    }
  }

  assert.ok(bundleFiles.length >= 5, `Expected at least 5 emitted JS bundles, found ${bundleFiles.length}`);

  for (const filePath of bundleFiles) {
    const relPath = path.relative(repoRoot, filePath);
    const code = fs.readFileSync(filePath, "utf8");
    const violations = findEs2020PlusViolations(code);

    assert.deepEqual(
      violations,
      [],
      `Bundle ${relPath} contains ES2020+ syntax incompatible with Webpack 4 / Acorn 6: ${JSON.stringify(violations)}`
    );

    if (filePath.endsWith(".cjs") || filePath.endsWith(".browser.js") || filePath.endsWith("react/index.js")) {
      assert.doesNotThrow(() => new vm.Script(code, { filename: relPath }));
    }
  }
});
