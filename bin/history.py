#!/usr/bin/env python3
"""Keep recoverable, local plugin removals outside Omarchy's plugin discovery."""

import fcntl
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime, timedelta, timezone
import uuid


MANAGER_ID = "kel.plugin-manager"
MAX_JSON = 1024 * 1024
MAX_RECORDS = 1000
ACTIONS = ("uninstall", "restore", "delete", "prune", "delete-all")


class HistoryError(Exception):
    pass


def valid_id(value):
    return (
        isinstance(value, str)
        and len(value) <= 128
        and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", value) is not None
        and ".." not in value
        and not value.startswith("omarchy.")
        and value != MANAGER_ID
    )


def read_json(path):
    with path.open("rb") as stream:
        content = stream.read(MAX_JSON + 1)
    if len(content) > MAX_JSON:
        raise HistoryError(f"History file is too large: {path.name}")
    return json.loads(content)


def write_json(path, value):
    fd, temporary = tempfile.mkstemp(prefix=".write-", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(value, stream, ensure_ascii=True)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        sync_directory(path.parent)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def sync_directory(path):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def disk_usage(path):
    # lstat without following links: linked installs count only the link itself.
    total = 0
    def report_error(error):
        raise error

    for directory, folders, files in os.walk(path, followlinks=False, onerror=report_error):
        for name in folders + files:
            try:
                total += os.lstat(os.path.join(directory, name)).st_blocks * 512
            except FileNotFoundError:
                # Plugins can remove temporary files while a backup is measured.
                continue
    return total


def command(argv, json_output=False):
    result = subprocess.run(argv, capture_output=True, text=True, timeout=30, check=False)
    if result.returncode:
        raise HistoryError((result.stderr or result.stdout or f"{argv[0]} failed").strip()[:2000])
    if len(result.stdout) > MAX_JSON:
        raise HistoryError(f"{argv[0]} returned too much data.")
    return json.loads(result.stdout) if json_output else result.stdout.strip()


class History:
    def __init__(self, plugins=None):
        self.plugins = plugins or Path.home() / ".config/omarchy/plugins"
        self.root = self.plugins / ".kel.plugin-manager-history"

    def prepare(self):
        if self.root.is_symlink():
            raise HistoryError("The uninstall history directory must not be a symlink.")
        self.root.mkdir(mode=0o700, parents=True, exist_ok=True)

    def lock(self):
        self.prepare()
        return os.fdopen(
            os.open(self.root / ".lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600),
            "r+",
        )

    def record_path(self, key):
        if not isinstance(key, str) or re.fullmatch(r"[a-f0-9]{32}", key) is None:
            raise HistoryError("Invalid history record.")
        path = self.root / key
        if path.is_symlink() or not path.is_dir():
            raise HistoryError("History record is missing or is not a local backup directory.")
        return path

    def read_record(self, key):
        path = self.record_path(key)
        if (path / "record.json").is_symlink():
            raise HistoryError("History metadata must not be a symlink.")
        record = read_json(path / "record.json")
        if (
            not isinstance(record, dict)
            or record.get("key") != key
            or not valid_id(record.get("id"))
            or not isinstance(record.get("name"), str)
            or len(record["name"]) > 160
            or not isinstance(record.get("linked"), bool)
            or not isinstance(record.get("removedAt"), str)
            or len(record["removedAt"]) > 64
        ):
            raise HistoryError(f"Invalid history metadata: {key}")
        try:
            if datetime.fromisoformat(record["removedAt"]).tzinfo is None:
                raise ValueError("Removal date must include its timezone.")
        except ValueError as error:
            raise HistoryError(f"Invalid removal date: {key}") from error
        return path, {field: record[field] for field in ("key", "id", "name", "linked", "removedAt")}

    def operation(self):
        path = self.root / ".operation.json"
        if path.is_symlink():
            raise HistoryError("Operation metadata must not be a symlink.")
        if not path.exists():
            return None
        value = read_json(path)
        if not isinstance(value, dict) or not isinstance(value.get("busy"), bool):
            raise HistoryError("Invalid operation history.")
        return value

    def listing(self):
        with self.lock() as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_SH | fcntl.LOCK_NB)
            except BlockingIOError:
                return {"ok": True, "busy": True, "entries": None, "operation": self.operation()}
            operation = self.operation()
            if operation and operation["busy"]:
                operation = dict(operation, busy=False, ok=False, error=(
                    "The previous history operation was interrupted. "
                    "Review the available backups before retrying."
                ))
            entries = []
            paths = [path for path in self.root.iterdir() if not path.name.startswith(".")]
            if len(paths) > MAX_RECORDS:
                raise HistoryError("Too many history entries. Remove older backups before continuing.")
            for path in paths:
                directory, record = self.read_record(path.name)
                payload = directory / "plugin"
                installed = self.plugins / record["id"]
                entries.append(dict(
                    record,
                    available=os.path.lexists(payload),
                    installed=os.path.lexists(installed),
                    size=disk_usage(directory),
                ))
            entries.sort(key=lambda row: row["removedAt"], reverse=True)
            return {
                "ok": True, "busy": False, "entries": entries, "operation": operation,
                "totalSize": sum(row["size"] for row in entries),
            }

    def installed(self):
        plugins = command(["omarchy", "plugin", "list", "--json"], json_output=True)
        if not isinstance(plugins, list) or len(plugins) > 250:
            raise HistoryError("Invalid installed plugin list.")
        result = {}
        for plugin in plugins:
            if (
                not isinstance(plugin, dict) or not isinstance(plugin.get("id"), str)
                or len(plugin["id"]) > 128 or plugin["id"] in result
            ):
                raise HistoryError("Invalid installed plugin metadata.")
            result[plugin["id"]] = plugin
        return result

    def enabled_references(self, plugin_id):
        config = command(["omarchy-shell", "shell", "listShellConfig"], json_output=True)
        if not isinstance(config, dict):
            raise HistoryError("Could not verify the plugin will remain disabled.")
        bar = config.get("bar", {})
        references = config.get("plugins", [])
        if not isinstance(bar, dict) or not isinstance(references, list):
            raise HistoryError("Invalid shell plugin configuration.")
        layout = bar.get("layout", {})
        if not isinstance(layout, dict) or any(not isinstance(section, list) for section in layout.values()):
            raise HistoryError("Invalid shell bar configuration.")
        references = references + [entry for section in layout.values() for entry in section]
        return sum(
            (entry.get("id") if isinstance(entry, dict) else entry) == plugin_id
            for entry in references
        ) + int(bar.get("id") == plugin_id)

    def disable(self, plugin_id):
        # Omarchy can clear an absent plugin's stale references before a restore.
        for _ in range(251):
            command(["omarchy", "plugin", "disable", plugin_id])
            if self.enabled_references(plugin_id) == 0:
                return
        raise HistoryError("The plugin could not be disabled; its files have not been moved.")

    def uninstall(self, plugin_id, plugins):
        if not valid_id(plugin_id):
            raise HistoryError("Native plugins and the manager itself cannot be archived.")
        plugin = plugins.get(plugin_id)
        if (
            not plugin or plugin.get("firstParty") is not False
            or not isinstance(plugin.get("kinds"), list) or "bar" in plugin["kinds"]
        ):
            raise HistoryError(f"Plugin is not eligible for removal: {plugin_id}")
        name = plugin.get("name")
        if not isinstance(name, str) or len(name) > 160:
            raise HistoryError("Invalid plugin name.")
        source = self.plugins / plugin_id
        if not source.is_dir():
            raise HistoryError(f"Installed plugin directory is missing: {plugin_id}")
        manifest = read_json(source / "manifest.json")
        if not isinstance(manifest, dict) or manifest.get("id") != plugin_id:
            raise HistoryError(f"The plugin folder does not match its manifest: {plugin_id}")
        if len([path for path in self.root.iterdir() if not path.name.startswith(".")]) >= MAX_RECORDS:
            raise HistoryError("Uninstall history is full. Delete an older backup first.")
        key = uuid.uuid4().hex
        directory = self.root / key
        directory.mkdir(mode=0o700)
        sync_directory(self.root)
        record = {
            "key": key,
            "id": plugin_id,
            "name": name,
            "linked": source.is_symlink(),
            "removedAt": datetime.now(timezone.utc).isoformat(),
        }
        write_json(directory / "record.json", record)
        # A same-filesystem rename preserves the entire checkout, including local edits.
        self.disable(plugin_id)
        os.rename(source, directory / "plugin")
        sync_directory(directory)
        sync_directory(self.plugins)

    def restore(self, key):
        directory, record = self.read_record(key)
        source = directory / "plugin"
        target = self.plugins / record["id"]
        if os.path.lexists(target):
            raise HistoryError("A plugin with this ID is already installed; it will not be overwritten.")
        if not os.path.lexists(source):
            raise HistoryError("The local backup is missing. Only its history record remains.")
        if source.is_symlink() != record["linked"]:
            raise HistoryError("The backup type does not match its history record.")
        manifest_path = source / "manifest.json"
        if record["linked"]:
            link = Path(os.readlink(source))
            original_target = link if link.is_absolute() else target.parent / link
            manifest_path = original_target / "manifest.json"
        manifest = read_json(manifest_path)
        if not isinstance(manifest, dict) or manifest.get("id") != record["id"]:
            raise HistoryError("The backup manifest no longer matches this plugin.")
        self.disable(record["id"])
        os.rename(source, target)
        sync_directory(self.plugins)
        sync_directory(directory)
        (directory / "record.json").unlink()
        directory.rmdir()
        sync_directory(self.root)

    def delete(self, key):
        directory, _ = self.read_record(key)
        if any(path.name not in ("record.json", "plugin") for path in directory.iterdir()):
            raise HistoryError("Unexpected files in the backup directory; inspect it before deleting.")
        payload = directory / "plugin"
        # Keep metadata until deletion succeeds so an interrupted delete can be retried.
        if payload.is_symlink() or payload.is_file():
            payload.unlink()
        elif payload.exists():
            shutil.rmtree(payload)
        (directory / "record.json").unlink()
        directory.rmdir()
        sync_directory(self.root)

    def perform(self, request, progress=None):
        action = request.get("action")
        if action == "uninstall":
            ids = request.get("ids")
            if (
                not isinstance(ids, list) or not 1 <= len(ids) <= 250
                or any(not valid_id(plugin_id) for plugin_id in ids)
                or len(set(ids)) != len(ids)
            ):
                raise HistoryError("Select valid, distinct user-installed plugins.")
            plugins = self.installed()
            completed = []
            def label(plugin_id):
                plugin = plugins.get(plugin_id, {})
                name = plugin.get("name")
                return name if isinstance(name, str) and len(name) <= 160 else plugin_id

            for index, plugin_id in enumerate(ids):
                if progress:
                    progress({
                        "current": plugin_id, "total": len(ids),
                        "completedIds": completed[:], "remainingIds": ids[index + 1:],
                        "currentName": label(plugin_id),
                        "completedNames": [label(item) for item in completed],
                        "remainingNames": [label(item) for item in ids[index + 1:]],
                    })
                self.uninstall(plugin_id, plugins)
                completed.append(plugin_id)
                if progress:
                    progress({
                        "current": "", "total": len(ids),
                        "completedIds": completed[:], "remainingIds": ids[index + 1:],
                        "currentName": "",
                        "completedNames": [label(item) for item in completed],
                        "remainingNames": [label(item) for item in ids[index + 1:]],
                    })
            return len(ids)
        if action == "restore":
            self.restore(request.get("key"))
            return 1
        if action == "delete":
            self.delete(request.get("key"))
            return 1
        if action == "prune":
            days = request.get("days")
            if not isinstance(days, int) or isinstance(days, bool) or not 1 <= days <= 3650:
                raise HistoryError("Invalid backup retention period.")
            cutoff = datetime.now(timezone.utc) - timedelta(days=days)
            return self.delete_many(lambda record: datetime.fromisoformat(record["removedAt"]) < cutoff, progress)
        if action == "delete-all":
            return self.delete_many(lambda record: True, progress)
        raise HistoryError("Unknown history action.")

    def delete_many(self, matches, progress=None):
        deleted = 0
        failures = []
        completed_names = []
        paths = [path for path in self.root.iterdir() if not path.name.startswith(".")]
        for index, path in enumerate(paths):
            name = path.name
            try:
                _, record = self.read_record(path.name)
                name = record["name"]
                if progress:
                    progress({"currentName": name, "processed": index, "total": len(paths),
                              "completedNames": completed_names[:]})
                if matches(record):
                    self.delete(path.name)
                    deleted += 1
                    completed_names.append(name)
            except (HistoryError, OSError, ValueError) as error:
                failures.append(f"{name}: {error}")
            if progress:
                progress({"currentName": "", "processed": index + 1, "total": len(paths),
                          "completedNames": completed_names[:]})
        if failures:
            raise HistoryError(f"Deleted {deleted} backups; {len(failures)} failed. " + "; ".join(failures))
        return deleted

    def start(self, request):
        if not isinstance(request, dict) or request.get("action") not in ACTIONS:
            raise HistoryError("Invalid history request.")
        skipped = request.get("skippedNames", [])
        if not isinstance(skipped, list) or len(skipped) > 250 or any(
            not isinstance(name, str) or len(name) > 160 for name in skipped
        ):
            raise HistoryError("Invalid skipped-plugin details.")
        with self.lock() as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as error:
                raise HistoryError("Another history operation is still running.") from error
            token = uuid.uuid4().hex
            operation = {"token": token, "action": request["action"], "busy": True}
            write_json(self.root / ".operation.json", operation)
            log_fd = os.open(self.root / ".worker.log", os.O_CREAT | os.O_APPEND | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
            with os.fdopen(log_fd, "a") as log:
                try:
                    os.set_inheritable(lock.fileno(), True)
                    pid = os.posix_spawn(
                        sys.executable,
                        [sys.executable, str(Path(__file__).resolve()), "worker",
                         json.dumps(request), str(lock.fileno()), token],
                        os.environ,
                        file_actions=[
                            (os.POSIX_SPAWN_OPEN, 0, os.devnull, os.O_RDONLY, 0),
                            (os.POSIX_SPAWN_DUP2, log.fileno(), 1),
                            (os.POSIX_SPAWN_DUP2, log.fileno(), 2),
                        ],
                        setsid=True,
                    )
                except OSError as error:
                    write_json(self.root / ".operation.json", dict(
                        operation, busy=False, ok=False, error=str(error),
                    ))
                    raise
                finally:
                    os.set_inheritable(lock.fileno(), False)
            return {"ok": True, "busy": True, "token": token, "pid": pid}

    def worker(self, request, lock_fd, token):
        with os.fdopen(lock_fd, "r+"):
            operation = {"token": token, "action": request.get("action"), "busy": False}
            if request.get("action") == "uninstall":
                operation["skippedNames"] = request.get("skippedNames", [])
            try:
                restored = None
                if request.get("action") == "restore":
                    _, restored = self.read_record(request.get("key"))
                def report_progress(fields):
                    operation.update(fields)
                    write_json(self.root / ".operation.json", dict(operation, busy=True))

                completed = self.perform(request, progress=report_progress)
                operation.update(ok=True, completed=completed)
                if restored:
                    operation.update(restoredId=restored["id"], restoredName=restored["name"])
            except (HistoryError, OSError, ValueError, subprocess.SubprocessError) as error:
                operation.update(ok=False, error=str(error)[:2000])
                print(f"Omarchy Plugin Manager: {error}", file=sys.stderr, flush=True)
            write_json(self.root / ".operation.json", operation)
            if request.get("action") in ("uninstall", "restore"):
                try:
                    command(["omarchy-shell", "shell", "rescanPlugins"])
                except (HistoryError, OSError, subprocess.SubprocessError) as error:
                    operation.update(ok=False, error=f"Filesystem changes saved, but plugin rescan failed: {error}"[:2000])
                    write_json(self.root / ".operation.json", operation)
                    print(operation["error"], file=sys.stderr, flush=True)


def main():
    history = History()
    try:
        if len(sys.argv) == 2 and sys.argv[1] == "list":
            response = history.listing()
        elif len(sys.argv) == 2 and sys.argv[1] == "start":
            payload = sys.stdin.buffer.read(16385)
            if len(payload) > 16384:
                raise HistoryError("History request is too large.")
            response = history.start(json.loads(payload))
        elif len(sys.argv) == 5 and sys.argv[1] == "worker":
            history.worker(json.loads(sys.argv[2]), int(sys.argv[3]), sys.argv[4])
            return 0
        else:
            raise HistoryError("Usage: history.py list | start")
        print(json.dumps(response))
        return 0
    except (HistoryError, OSError, ValueError, subprocess.SubprocessError) as error:
        print(json.dumps({"ok": False, "error": str(error)[:2000]}))
        print(f"Omarchy Plugin Manager: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
