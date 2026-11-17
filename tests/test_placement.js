const assert = require("node:assert/strict");
const { execFileSync } = require("node:child_process");
const { mkdtempSync, readFileSync, rmSync, mkdirSync, writeFileSync } = require("node:fs");
const { tmpdir } = require("node:os");
const { join } = require("node:path");
const { test } = require("node:test");
const vm = require("node:vm");

const qml = readFileSync(join(__dirname, "../BarWidget.qml"), "utf8");
const functions = ["readSection", "finishCommand"].map(name => {
  const match = qml.match(new RegExp(`^  function ${name}\\([^)]*\\) \\{[\\s\\S]*?^  \\}`, "m"));
  assert.ok(match, `${name} must be available to exercise the real QML command handling`);
  return match[0];
}).join("\n");

function detectPosition(layout) {
  const home = mkdtempSync(join(tmpdir(), "plugin-manager-placement-"));
  try {
    const config = join(home, ".config/omarchy");
    mkdirSync(config, { recursive: true });
    writeFileSync(join(config, "shell.json"), JSON.stringify({ bar: { layout } }));
    const warnings = [];
    const context = vm.createContext({
      moduleName: "kel.plugin-manager",
      helper: { running: false },
      Quickshell: { env: () => home },
      Qt: { callLater: () => {} },
      strings: { t: key => key },
      console: { warn: message => warnings.push(message) },
      currentSection: "right",
      statusText: "",
    });
    vm.runInContext(functions + "\nreadSection();", context);
    const output = execFileSync(context.commandProgram, Array.from(context.commandArgs), {
      encoding: "utf8",
    });
    context.finishCommand(0, output, "");
    return { section: context.currentSection, error: context.statusText, warnings };
  } finally {
    rmSync(home, { recursive: true });
  }
}

for (const section of ["left", "centerBegin", "center", "centerEnd", "right", "tray"]) {
  for (const entry of ["kel.plugin-manager", { id: "kel.plugin-manager" }]) {
    test(`detects ${section} with ${typeof entry} entries in a mixed layout`, () => {
      const layout = {
        left: ["omarchy.menu", { id: "omarchy.workspaces" }],
        [section]: ["omarchy.clock", entry, { id: "omarchy.audio" }],
      };
      assert.deepEqual(detectPosition(layout), { section, error: "", warnings: [] });
    });
  }
}

test("unknown sections still report an error", () => {
  const result = detectPosition({ unsupported: ["kel.plugin-manager"] });
  assert.equal(result.error, "positionFailed");
  assert.equal(result.warnings.length, 1);
});
