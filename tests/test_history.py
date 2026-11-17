import importlib.util
import json
import os
from pathlib import Path
import tempfile
import time
import unittest
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location(
    "history", Path(__file__).resolve().parents[1] / "bin/history.py",
)
history = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(history)


class HistoryTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.home = Path(self.temporary.name)
        self.plugins = self.home / ".config/omarchy/plugins"
        self.plugins.mkdir(parents=True)
        self.manager = history.History(self.plugins)
        self.manager.prepare()
        self.plugin_id = "test.example"
        self.source = self.plugins / self.plugin_id
        self.source.mkdir()
        (self.source / "manifest.json").write_text(json.dumps({"id": self.plugin_id}))
        (self.source / ".git").mkdir()
        (self.source / ".git/config").write_text("local repository settings")
        (self.source / "local-edit.qml").write_text("uncommitted local changes")
        self.plugin = {
            "id": self.plugin_id, "name": '<img src="https://invalid.example/x">',
            "firstParty": False, "kinds": ["bar-widget"], "enabled": True,
        }
        self.config = {"bar": {"layout": {"right": [{"id": self.plugin_id}]}}, "plugins": []}
        self.calls = []
        self.command_patch = patch.object(history, "command", side_effect=self.command)
        self.command_patch.start()
        self.addCleanup(self.command_patch.stop)

    def command(self, argv, json_output=False):
        self.calls.append(argv)
        if argv == ["omarchy", "plugin", "list", "--json"]:
            return [self.plugin]
        if argv == ["omarchy", "plugin", "disable", self.plugin_id]:
            for section in self.config["bar"]["layout"].values():
                section[:] = [entry for entry in section if entry.get("id") != self.plugin_id]
            self.config["plugins"] = [
                entry for entry in self.config["plugins"] if entry.get("id") != self.plugin_id
            ]
            return "Disabled"
        if argv == ["omarchy-shell", "shell", "listShellConfig"]:
            return self.config
        if argv == ["omarchy-shell", "shell", "rescanPlugins"]:
            return "ok"
        raise AssertionError(f"Unexpected command: {argv}")

    def uninstall(self):
        self.manager.perform({"action": "uninstall", "ids": [self.plugin_id]})
        return self.manager.listing()["entries"][0]

    def test_round_trip_preserves_checkout_edits_and_restores_disabled(self):
        row = self.uninstall()
        self.assertFalse(self.source.exists())
        self.assertTrue(row["available"])
        self.assertEqual(row["name"], self.plugin["name"])
        self.assertEqual((self.manager.root / row["key"] / "plugin/.git/config").read_text(),
                         "local repository settings")
        # Stale references must be cleared before the filesystem exposes the plugin.
        self.config["plugins"].append({"id": self.plugin_id})
        original_rename = os.rename

        def verify_disabled(source, target):
            self.assertEqual(self.manager.enabled_references(self.plugin_id), 0)
            original_rename(source, target)

        with patch.object(history.os, "rename", side_effect=verify_disabled):
            self.manager.restore(row["key"])
        self.assertEqual((self.source / "local-edit.qml").read_text(), "uncommitted local changes")
        self.assertEqual(self.manager.listing()["entries"], [])
        self.assertFalse(any("enable" in argv for argv in self.calls))

    def test_restore_refuses_existing_installation(self):
        row = self.uninstall()
        self.source.mkdir()
        (self.source / "new-file").write_text("do not replace")
        with self.assertRaisesRegex(history.HistoryError, "already installed"):
            self.manager.restore(row["key"])
        self.assertEqual((self.source / "new-file").read_text(), "do not replace")
        self.assertTrue((self.manager.root / row["key"] / "plugin/local-edit.qml").exists())

    def test_disabled_failure_preserves_original_and_exposes_incomplete_record(self):
        with patch.object(self.manager, "disable", side_effect=history.HistoryError("IPC unavailable")):
            with self.assertRaisesRegex(history.HistoryError, "IPC unavailable"):
                self.uninstall()
        self.assertTrue((self.source / "local-edit.qml").exists())
        row = self.manager.listing()["entries"][0]
        self.assertFalse(row["available"])
        self.assertTrue(row["installed"])
        self.manager.delete(row["key"])
        self.assertTrue(self.source.exists())

    def test_rename_failure_keeps_original_and_record(self):
        with patch.object(history.os, "rename", side_effect=OSError("disk failure")):
            with self.assertRaisesRegex(OSError, "disk failure"):
                self.uninstall()
        self.assertTrue(self.source.exists())
        self.assertFalse(self.manager.listing()["entries"][0]["available"])

    def test_deletion_affects_only_selected_backup(self):
        first = self.uninstall()
        self.source.mkdir()
        (self.source / "manifest.json").write_text(json.dumps({"id": self.plugin_id}))
        (self.source / "new-version").write_text("another installation of the same plugin")
        second = self.uninstall()
        outside = self.home / "outside"
        outside.mkdir()
        (outside / "keep").write_text("untouched")
        (self.manager.root / second["key"] / "plugin/external").symlink_to(outside, target_is_directory=True)
        self.manager.delete(second["key"])
        self.assertEqual((outside / "keep").read_text(), "untouched")
        remaining = self.manager.listing()["entries"]
        self.assertEqual([row["key"] for row in remaining], [first["key"]])
        self.assertTrue((self.manager.root / first["key"] / "plugin/local-edit.qml").exists())

    def test_interrupted_delete_can_be_retried(self):
        row = self.uninstall()
        with patch.object(history.shutil, "rmtree", side_effect=OSError("cannot delete")):
            with self.assertRaisesRegex(OSError, "cannot delete"):
                self.manager.delete(row["key"])
        self.assertEqual(self.manager.listing()["entries"][0]["key"], row["key"])
        self.manager.delete(row["key"])
        self.assertEqual(self.manager.listing()["entries"], [])

    def test_relative_symlink_round_trip_preserves_external_files(self):
        external = self.home / "linked-source"
        self.source.rename(external)
        self.source.symlink_to(os.path.relpath(external, self.plugins), target_is_directory=True)
        row = self.uninstall()
        self.assertTrue(row["linked"])
        self.assertTrue((external / "local-edit.qml").exists())
        self.manager.restore(row["key"])
        self.assertTrue(self.source.is_symlink())
        self.assertEqual((self.source / "local-edit.qml").read_text(), "uncommitted local changes")
        row = self.uninstall()
        self.manager.delete(row["key"])
        self.assertTrue(external.exists())

    def test_native_self_and_traversal_are_rejected(self):
        for plugin_id in ("omarchy.clock", history.MANAGER_ID, "../outside", "bad..id"):
            with self.subTest(plugin_id=plugin_id):
                with self.assertRaises(history.HistoryError):
                    self.manager.perform({"action": "uninstall", "ids": [plugin_id]})
        for key in ("../outside", "", "a" * 31, "A" * 32):
            with self.subTest(key=key):
                with self.assertRaises(history.HistoryError):
                    self.manager.delete(key)
        for updates in ({"firstParty": True}, {"kinds": ["bar"]}):
            with self.subTest(updates=updates):
                with self.assertRaises(history.HistoryError):
                    self.manager.uninstall(self.plugin_id, {self.plugin_id: dict(self.plugin, **updates)})
        self.assertTrue(self.source.exists())

    def test_tampered_metadata_and_linked_record_directory_are_rejected(self):
        row = self.uninstall()
        directory = self.manager.root / row["key"]
        record = json.loads((directory / "record.json").read_text())
        record["id"] = "../outside"
        (directory / "record.json").write_text(json.dumps(record))
        with self.assertRaisesRegex(history.HistoryError, "Invalid history metadata"):
            self.manager.restore(row["key"])
        linked_key = "a" * 32
        (self.manager.root / linked_key).symlink_to(self.home, target_is_directory=True)
        with self.assertRaises(history.HistoryError):
            self.manager.delete(linked_key)
        self.assertTrue((directory / "plugin/local-edit.qml").exists())

    def test_interruption_reports_error_without_losing_backup(self):
        row = self.uninstall()
        history.write_json(self.manager.root / ".operation.json", {"busy": True, "action": "uninstall"})
        result = self.manager.listing()
        self.assertFalse(result["busy"])
        self.assertFalse(result["operation"]["ok"])
        self.assertIn("interrupted", result["operation"]["error"])
        self.assertEqual(result["entries"][0]["key"], row["key"])

    def test_detached_worker_completes_and_retains_cross_process_lock(self):
        self.command_patch.stop()
        bindir = self.home / "bin"
        bindir.mkdir()
        fake_cli = """#!/usr/bin/env python3
import json, os, sys, time
from pathlib import Path
home = Path(os.environ["HOME"])
args = sys.argv[1:]
if args == ["plugin", "list", "--json"]:
    time.sleep(0.25)
    print((home / "plugins.json").read_text())
elif args[:2] == ["plugin", "disable"]:
    print("Disabled")
elif args == ["shell", "listShellConfig"]:
    print('{"plugins":[],"bar":{"layout":{}}}')
elif args == ["shell", "rescanPlugins"]:
    print("ok")
else:
    sys.exit(99)
"""
        for name in ("omarchy", "omarchy-shell"):
            path = bindir / name
            path.write_text(fake_cli)
            path.chmod(0o700)
        (self.home / "plugins.json").write_text(json.dumps([self.plugin]))
        environment = {"HOME": str(self.home), "PATH": f"{bindir}:{os.environ['PATH']}"}
        with patch.dict(os.environ, environment):
            result = self.manager.start({"action": "uninstall", "ids": [self.plugin_id]})
            self.addCleanup(os.waitpid, result["pid"], 0)
            self.assertTrue(result["busy"])
            self.assertTrue(self.manager.listing()["busy"])
            with self.assertRaisesRegex(history.HistoryError, "still running"):
                self.manager.start({"action": "delete", "key": "a" * 32})
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                listing = self.manager.listing()
                if not listing["busy"]:
                    break
                time.sleep(0.05)
            else:
                self.fail("Detached fixture worker did not finish")
        self.assertTrue(listing["operation"]["ok"], listing["operation"])
        self.assertEqual(listing["operation"]["token"], result["token"])
        self.assertTrue(listing["entries"][0]["available"])
        self.assertFalse(self.source.exists())


if __name__ == "__main__":
    unittest.main()
