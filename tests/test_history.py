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

    def test_batch_uninstall_progress_identifies_completed_failed_and_remaining(self):
        ids = ["test.one", "test.two", "test.three"]
        plugins = {plugin_id: {"name": name} for plugin_id, name in zip(ids, ("One", "Two", "Three"))}
        updates = []
        with patch.object(self.manager, "installed", return_value=plugins), \
             patch.object(self.manager, "uninstall", side_effect=[None, history.HistoryError("disk full")]):
            with self.assertRaisesRegex(history.HistoryError, "disk full"):
                self.manager.perform({"action": "uninstall", "ids": ids}, progress=updates.append)
        self.assertEqual(updates[-1]["completedNames"], ["One"])
        self.assertEqual(updates[-1]["currentName"], "Two")
        self.assertEqual(updates[-1]["remainingNames"], ["Three"])
        self.assertEqual(updates[-1]["total"], 3)

    def test_restore_refuses_existing_installation(self):
        row = self.uninstall()
        self.source.mkdir()
        (self.source / "new-file").write_text("do not replace")
        with self.assertRaisesRegex(history.HistoryError, "already installed"):
            self.manager.restore(row["key"])
        self.assertEqual((self.source / "new-file").read_text(), "do not replace")
        self.assertTrue((self.manager.root / row["key"] / "plugin/local-edit.qml").exists())

    def test_worker_persists_identity_of_successfully_restored_plugin(self):
        row = self.uninstall()
        lock_fd = os.open(self.manager.root / ".lock", os.O_RDWR)
        self.manager.worker({"action": "restore", "key": row["key"]}, lock_fd, "a" * 32)
        result = self.manager.listing()["operation"]
        self.assertTrue(result["ok"])
        self.assertEqual(result["restoredId"], self.plugin_id)
        self.assertEqual(result["restoredName"], self.plugin["name"])
        self.assertTrue(self.source.exists())
        self.assertFalse(any("enable" in argv for argv in self.calls))

    def test_worker_does_not_report_restore_success_for_a_conflict(self):
        row = self.uninstall()
        self.source.mkdir()
        lock_fd = os.open(self.manager.root / ".lock", os.O_RDWR)
        self.manager.worker({"action": "restore", "key": row["key"]}, lock_fd, "b" * 32)
        result = self.manager.listing()["operation"]
        self.assertFalse(result["ok"])
        self.assertNotIn("restoredId", result)
        self.assertTrue((self.manager.root / row["key"] / "plugin").exists())

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

    def test_prune_deletes_only_expired_backups_and_delete_all_clears_history(self):
        old = self.uninstall()
        record_path = self.manager.root / old["key"] / "record.json"
        record = json.loads(record_path.read_text())
        record["removedAt"] = "2000-01-01T00:00:00+00:00"
        record_path.write_text(json.dumps(record))
        self.source.mkdir()
        (self.source / "manifest.json").write_text(json.dumps({"id": self.plugin_id}))
        recent = self.uninstall()
        listing = self.manager.listing()
        self.assertGreater(listing["totalSize"], 0)
        self.assertEqual(self.manager.perform({"action": "prune", "days": 30}), 1)
        self.assertEqual([row["key"] for row in self.manager.listing()["entries"]], [recent["key"]])
        for days in (0, True, "30", 5000):
            with self.subTest(days=days), self.assertRaises(history.HistoryError):
                self.manager.perform({"action": "prune", "days": days})
        self.assertEqual(self.manager.perform({"action": "delete-all"}), 1)
        self.assertEqual(self.manager.listing()["entries"], [])

    def test_usage_does_not_follow_links_and_bulk_delete_keeps_installed_files(self):
        row = self.uninstall()
        directory = self.manager.root / row["key"]
        outside = self.home / "outside"
        outside.mkdir()
        (outside / "large-file").write_bytes(b"x" * 100000)
        (directory / "plugin/external").symlink_to(outside, target_is_directory=True)
        self.source.mkdir()
        (self.source / "keep").write_text("installed copy")
        self.assertLess(self.manager.listing()["totalSize"], 100000)
        self.manager.perform({"action": "delete-all"})
        self.assertEqual((self.source / "keep").read_text(), "installed copy")
        self.assertEqual((outside / "large-file").stat().st_size, 100000)

    def test_bulk_delete_reports_partial_failure_and_continues(self):
        first = self.uninstall()
        self.source.mkdir()
        (self.source / "manifest.json").write_text(json.dumps({"id": self.plugin_id}))
        second = self.uninstall()
        (self.manager.root / first["key"] / "unexpected").write_text("do not remove")
        with self.assertRaisesRegex(history.HistoryError, "Deleted 1 backups; 1 failed"):
            self.manager.perform({"action": "delete-all"})
        self.assertTrue((self.manager.root / first["key"]).is_dir())
        self.assertFalse((self.manager.root / second["key"]).exists())

    def test_bulk_cleanup_reports_each_failure_and_completed_progress(self):
        names = {"a": "Alpha", "b": "Beta", "c": "Gamma"}
        for key in names:
            (self.manager.root / key).mkdir()
        updates = []

        def delete(key):
            if key != "b":
                raise history.HistoryError("cannot delete")

        with patch.object(self.manager, "read_record", side_effect=lambda key: (None, {"name": names[key]})), \
             patch.object(self.manager, "delete", side_effect=delete):
            with self.assertRaises(history.HistoryError) as failure:
                self.manager.delete_many(lambda record: True, progress=updates.append)
        self.assertIn("Alpha: cannot delete", str(failure.exception))
        self.assertIn("Gamma: cannot delete", str(failure.exception))
        self.assertEqual(updates[-1]["completedNames"], ["Beta"])
        self.assertEqual(updates[-1]["processed"], 3)

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
