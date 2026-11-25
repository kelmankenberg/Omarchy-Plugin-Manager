const assert = require("node:assert/strict");
const { readFileSync } = require("node:fs");
const { join } = require("node:path");
const { test } = require("node:test");
const vm = require("node:vm");

const qml = readFileSync(join(__dirname, "../BarWidget.qml"), "utf8");
const source = ["selectVisible", "matchesCustomFilter", "addCustomFilter", "removeCustomFilter", "clearFilters",
  "chooseRetention", "confirmRetention", "findRestored",
  "removable", "unavailableReason", "beginUninstall", "changeOne", "startBatch", "finishCommand", "finishHistory"]
  .map(name => {
    const match = qml.match(new RegExp(`^  function ${name}\\([^)]*\\) \\{[\\s\\S]*?^  \\}`, "m"));
    assert.ok(match, `missing ${name}`);
    return match[0];
  }).join("\n");
const user = { id: "third.example", name: "Example", firstParty: false, kinds: ["bar-widget"], canDisable: true, enabled: true };
const hidden = { id: "third.hidden", name: "Hidden", firstParty: false, kinds: ["panel"], canDisable: true, enabled: false };
const native = { id: "omarchy.clock", name: "Clock", firstParty: true, kinds: ["bar-widget"], canDisable: true, enabled: true };
const bar = { id: "third.bar", name: "Bar", firstParty: false, kinds: ["bar"], canDisable: true, enabled: false };

function context() {
  const c = vm.createContext({
    moduleName: "kel.plugin-manager",
    preferences: { skipUninstallConfirm: false },
    selectableIds: [user.id, native.id],
    selectedIds: [hidden.id],
    customFilterTerms: [],
    filterText: "",
    selectedPlugins: [user, hidden, native, bar],
    pendingUninstallIds: [],
    pendingUninstallSkipped: [],
    strings: { t: key => key },
    Qt: { callLater: () => {} },
    busy: false,
    queueActions: (args, names) => { c.queued = { args, names }; },
    startHistoryAction: request => { c.started = request; },
  });
  c.root = c;
  vm.runInContext(source, c);
  return c;
}

test("select visible retains hidden selections and never duplicates IDs", () => {
  const c = context();
  c.selectVisible();
  c.selectVisible();
  assert.deepEqual(Array.from(c.selectedIds), [hidden.id, user.id, native.id]);
});

test("custom filters trim terms, avoid duplicates, and can be removed independently", () => {
  const c = context();
  c.filterText = " Example ";
  c.addCustomFilter();
  c.filterText = "hidden";
  c.addCustomFilter();
  c.filterText = "EXAMPLE";
  c.addCustomFilter();
  assert.deepEqual(Array.from(c.customFilterTerms), ["Example", "hidden"]);
  assert.equal(c.filterText, "");
  c.removeCustomFilter(0);
  assert.deepEqual(Array.from(c.customFilterTerms), ["hidden"]);
  c.clearFilters();
  assert.deepEqual(Array.from(c.customFilterTerms), []);
  assert.deepEqual(Array.from(c.selectedIds), [hidden.id]);
});

test("custom chips and the current search match any name or ID, case-insensitively", () => {
  const c = context();
  c.customFilterTerms = ["EXAMPLE", "third.hidden"];
  assert.equal(c.matchesCustomFilter(user), true);
  assert.equal(c.matchesCustomFilter(hidden), true);
  assert.equal(c.matchesCustomFilter(native), false);
  c.filterText = "clock";
  assert.equal(c.matchesCustomFilter(native), true);
  c.customFilterTerms = [];
  c.filterText = "  ";
  assert.equal(c.matchesCustomFilter(native), true);
});

test("batch uninstall reviews eligible visible and hidden targets and identifies protected skips", () => {
  const c = context();
  c.startBatch("remove");
  assert.deepEqual(Array.from(c.pendingUninstallIds), [user.id, hidden.id]);
  assert.deepEqual(Array.from(c.pendingUninstallSkipped, p => p.id), [native.id, bar.id]);
  assert.equal(c.started, undefined);
});

test("skip confirmation is opt-in and still excludes protected plugins", () => {
  const c = context();
  c.preferences.skipUninstallConfirm = true;
  c.startBatch("remove");
  assert.deepEqual(Array.from(c.started.ids), [user.id, hidden.id]);
  assert.equal(c.started.action, "uninstall");
});

test("single-plugin state action never changes the batch selection", () => {
  const c = context();
  c.changeOne(user);
  assert.deepEqual(Array.from(c.queued.args[0]), ["plugin", "disable", user.id]);
  assert.deepEqual(Array.from(c.selectedIds), [hidden.id]);
  c.changeOne(hidden);
  assert.deepEqual(Array.from(c.queued.args[0]), ["plugin", "enable", hidden.id]);
});

test("batch enable reports ineligible selected items as skipped", () => {
  const c = context();
  c.startBatch("enable");
  assert.deepEqual(Array.from(c.queued.names), ["Hidden", "Bar"]);
  assert.deepEqual(Array.from(c.skippedActionNames), ["Example", "Clock"]);
});

test("a failed batch retains skipped items in the failure summary", () => {
  const c = context();
  vm.runInContext(`String.prototype.arg = function(value) {
    return this.replace(/%[1-9]/, String(value));
  }`, c);
  c.strings.t = key => ({
    actionPartial: "Completed: %1. Failed: %2. Not attempted: %3. Error: %4.",
    willSkip: "Skipped: %1",
  }[key] || key);
  c.requestType = "action";
  c.completedActionNames = ["One"];
  c.actionNames = ["One", "Two", "Three"];
  c.actionIndex = 1;
  c.skippedActionNames = ["Protected"];
  c.actionQueue = [["plugin"]];
  c.Qt = { callLater: () => {} };
  c.console = { warn: () => {} };
  c.finishCommand(1, "", "error");
  assert.match(c.statusText, /Completed: One.*Failed: Two.*Not attempted: Three.*error/);
  assert.match(c.statusText, /Skipped: Protected/);
});

test("expiring retention requires confirmation and cancelling preserves the old value", () => {
  const c = context();
  c.preferences.retentionDays = 0;
  c.pendingRetentionDays = -1;
  c.chooseRetention("30");
  assert.equal(c.preferences.retentionDays, 0);
  assert.equal(c.pendingRetentionDays, 30);
  c.pendingRetentionDays = -1;
  c.confirmRetention();
  assert.equal(c.preferences.retentionDays, 0);
  c.chooseRetention("90");
  c.confirmRetention();
  assert.equal(c.preferences.retentionDays, 90);
  c.chooseRetention("0");
  assert.equal(c.preferences.retentionDays, 0);
});

test("find restored plugin clears conflicting filters and searches its exact ID", () => {
  const c = context();
  c.restoredPluginId = hidden.id;
  c.filterText = "old";
  c.customFilterTerms = ["old chip"];
  c.showDisabledOnly = true;
  c.showUserInstalledOnly = true;
  c.reviewHiddenSelection = true;
  c.showHistory = true;
  c.refresh = value => { c.refreshed = value; };
  c.findRestored();
  assert.equal(c.showHistory, false);
  assert.equal(c.filterText, hidden.id);
  assert.deepEqual(Array.from(c.customFilterTerms), []);
  assert.equal(c.showDisabledOnly, false);
  assert.equal(c.showUserInstalledOnly, false);
  assert.equal(c.reviewHiddenSelection, false);
  assert.equal(c.restoredPluginId, "");
  assert.equal(c.refreshed, false);
});

test("successful restore feedback retains the restored ID for navigation", () => {
  const c = context();
  vm.runInContext(`String.prototype.arg = function(value) {
    return this.replace(/%[1-9]/, String(value));
  }`, c);
  c.strings.t = key => ({ historyRestored: "%1 restored and disabled" }[key] || key);
  c.historyMode = "list";
  c.lastHistoryToken = "";
  c.restoredPluginId = "";
  c.refresh = () => {};
  c.console = { warn: () => {} };
  c.finishHistory(0, JSON.stringify({
    ok: true, busy: false, entries: [], totalSize: 0,
    operation: { token: "a".repeat(32), ok: true, action: "restore",
      restoredId: hidden.id, restoredName: hidden.name },
  }), "");
  assert.equal(c.restoredPluginId, hidden.id);
  assert.equal(c.statusText, "Hidden restored and disabled");
});
