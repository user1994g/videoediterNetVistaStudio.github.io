from __future__ import annotations

import hashlib
import json
import shutil
import stat
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from netvista.mods import (ModCompatibilityError, ModLimits, ModManager,
                           ModValidationError, default_mods_directory)
from netvista.theme import DEFAULT_THEME, build_app_style


def json_bytes(value: dict) -> bytes:
    return json.dumps(value, sort_keys=True).encode("utf-8")


def theme_document(tokens: dict | None = None) -> dict:
    return {
        "schemaVersion": 1,
        "id": "midnight",
        "name": "Midnight Test",
        "tokens": tokens if tokens is not None else {
            "accent": "#8844EE", "windowBackground": "#090A0B", "cornerRadius": 9,
        },
    }


def shared_manifest(
    payloads: dict[str, bytes],
    *,
    identifier: str = "studio.test.theme",
    capabilities: list[str] | None = None,
    content: dict[str, list[str]] | None = None,
    minimum: str = "1.3.0-beta.1",
    maximum: str | None = None,
) -> dict:
    data = {
        "schemaVersion": 1,
        "modAPI": "1.0",
        "id": identifier,
        "name": "Midnight Test",
        "version": "1.0.0",
        "publisher": {"name": "NetVista Test", "website": "https://example.com/mods"},
        "description": "A shared, data-only test mod.",
        "minAppVersion": minimum,
        "capabilities": capabilities or ["theme"],
        "content": content or {"themes": ["themes/midnight.json"]},
        "integrity": {
            "algorithm": "sha256",
            "files": {name: hashlib.sha256(value).hexdigest() for name, value in payloads.items()},
        },
    }
    if maximum:
        data["maxAppVersion"] = maximum
    return data


def theme_payloads(tokens: dict | None = None) -> dict[str, bytes]:
    return {"themes/midnight.json": json_bytes(theme_document(tokens))}


def make_directory_package(
    parent: Path,
    *,
    payloads: dict[str, bytes] | None = None,
    package_manifest: dict | None = None,
) -> Path:
    parent.mkdir(parents=True, exist_ok=True)
    package = parent / "source.netvistamod"
    package.mkdir()
    files = payloads or theme_payloads()
    for relative, data in files.items():
        target = package / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
    (package / "mod.json").write_bytes(json_bytes(package_manifest or shared_manifest(files)))
    return package


def make_zip_package(
    path: Path,
    *,
    payloads: dict[str, bytes] | None = None,
    package_manifest: dict | None = None,
) -> Path:
    files = payloads or theme_payloads()
    manifest = package_manifest or shared_manifest(files)
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as archive:
        archive.writestr("mod.json", json_bytes(manifest))
        for relative, data in files.items():
            archive.writestr(relative, data)
    return path


class ModManagerTests(unittest.TestCase):
    def test_platform_mod_directories_are_per_user(self) -> None:
        self.assertEqual(
            default_mods_directory("Windows", {"APPDATA": "C:/Users/Test/AppData/Roaming"}, Path("C:/Users/Test")),
            Path("C:/Users/Test/AppData/Roaming/NetVista Studio/Mods"),
        )
        self.assertEqual(
            default_mods_directory("Linux", {"XDG_DATA_HOME": "/home/test/.data"}, Path("/home/test")),
            Path("/home/test/.data/netvista-studio/mods"),
        )
        self.assertEqual(
            default_mods_directory("Linux", {}, Path("/home/test")),
            Path("/home/test/.local/share/netvista-studio/mods"),
        )

    def test_directory_install_is_disabled_then_persists_enabled_theme(self) -> None:
        with tempfile.TemporaryDirectory() as folder:
            base = Path(folder)
            source = make_directory_package(base / "source")
            manager = ModManager("1.3.0-beta.1", base / "mods")
            installed = manager.install(source)
            self.assertEqual(installed.path, base / "mods" / "studio.test.theme.netvistamod")
            self.assertFalse(manager.is_enabled(installed.identifier))
            manager.set_enabled(installed.identifier, True)
            self.assertEqual(manager.active_theme_tokens()["accent"], "#8844EE")

            reopened = ModManager("1.3.0-beta.1", base / "mods")
            self.assertTrue(reopened.is_enabled(installed.identifier))
            self.assertEqual(reopened.active_theme_tokens()["windowBackground"], "#090A0B")
            reopened.remove(installed.identifier)
            self.assertFalse(installed.path.exists())
            self.assertFalse(reopened.is_enabled(installed.identifier))

    def test_shared_root_zip_installs_without_extraction(self) -> None:
        with tempfile.TemporaryDirectory() as folder:
            base = Path(folder)
            source = make_zip_package(base / "cool-theme.netvistamod")
            manager = ModManager("1.3.0-beta.1", base / "mods")
            installed = manager.install(source)
            self.assertTrue(installed.path.is_file())
            self.assertEqual(installed.manifest_member, "mod.json")
            self.assertEqual(installed.theme_member, "themes/midnight.json")
            manager.set_enabled(installed.identifier, True)
            self.assertEqual(manager.active_theme_tokens()["cornerRadius"], 9.0)

    def test_declarative_pages_and_catalogs_are_exposed(self) -> None:
        with tempfile.TemporaryDirectory() as folder:
            base = Path(folder)
            payloads = theme_payloads()
            payloads["pages/welcome.json"] = json_bytes({
                "schemaVersion": 1, "id": "welcome", "title": "Welcome", "summary": "Mod help",
                "blocks": [{"kind": "text", "title": "Hello", "text": "Safe declarative text."}],
            })
            payloads["scene-props/lamp.json"] = json_bytes({
                "schemaVersion": 1, "id": "lamp", "name": "Studio Lamp", "summary": "A scene prop",
                "asset": "assets/lamp.obj", "parameters": {"scale": 1.0},
            })
            payloads["assets/lamp.obj"] = b"o StudioLamp\n"
            content = {"themes": ["themes/midnight.json"], "pages": ["pages/welcome.json"],
                       "sceneProps": ["scene-props/lamp.json"]}
            manifest = shared_manifest(payloads, capabilities=["theme", "page", "sceneProp"], content=content)
            source = make_zip_package(base / "catalog.netvistamod", payloads=payloads, package_manifest=manifest)
            package = ModManager("1.3.0-beta.1", base / "mods").install(source)
            self.assertEqual([item.kind for item in package.content_items], ["Theme", "Page", "Scene Prop"])
            self.assertEqual(package.content_items[1].name, "Welcome")

    def test_manually_copied_package_is_found_on_refresh(self) -> None:
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder) / "mods"
            root.mkdir()
            make_zip_package(root / "copied-by-user.netvistamod")
            catalog = ModManager("1.3.0-beta.1", root).scan()
            self.assertEqual([item.identifier for item in catalog.packages], ["studio.test.theme"])
            self.assertEqual(catalog.errors, [])

    def test_archive_traversal_is_rejected_and_never_written(self) -> None:
        with tempfile.TemporaryDirectory() as folder:
            base = Path(folder)
            source = base / "bad.netvistamod"
            files = theme_payloads()
            with zipfile.ZipFile(source, "w") as archive:
                archive.writestr("mod.json", json_bytes(shared_manifest(files)))
                archive.writestr("themes/midnight.json", files["themes/midnight.json"])
                archive.writestr("../outside.txt", "escape")
            manager = ModManager("1.3.0-beta.1", base / "mods")
            with self.assertRaisesRegex(ModValidationError, "unsafe package path"):
                manager.install(source)
            self.assertFalse((base / "outside.txt").exists())
            self.assertEqual(manager.scan().packages, [])

    def test_archive_requires_mod_json_at_literal_root(self) -> None:
        with tempfile.TemporaryDirectory() as folder:
            base = Path(folder)
            source = base / "wrapped.netvistamod"
            files = theme_payloads()
            with zipfile.ZipFile(source, "w") as archive:
                archive.writestr("Wrapped/mod.json", json_bytes(shared_manifest(files)))
                archive.writestr("Wrapped/themes/midnight.json", files["themes/midnight.json"])
            with self.assertRaisesRegex(ModValidationError, "unsupported top-level folder|archive root"):
                ModManager("1.3.0-beta.1", base / "mods").install(source)

    def test_archive_case_collisions_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as folder:
            base = Path(folder)
            source = make_zip_package(base / "collision.netvistamod")
            with zipfile.ZipFile(source, "a") as archive:
                archive.writestr("assets/Readme.txt", b"one")
                archive.writestr("assets/readme.txt", b"two")
            with self.assertRaisesRegex(ModValidationError, "case-colliding"):
                ModManager("1.3.0-beta.1", base / "mods").install(source)

    def test_archive_symbolic_links_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as folder:
            base = Path(folder)
            source = make_zip_package(base / "link.netvistamod")
            with zipfile.ZipFile(source, "a") as archive:
                link = zipfile.ZipInfo("assets/shortcut.txt")
                link.create_system = 3
                link.external_attr = (stat.S_IFLNK | 0o777) << 16
                archive.writestr(link, "themes/midnight.json")
            with self.assertRaisesRegex(ModValidationError, "symbolic link"):
                ModManager("1.3.0-beta.1", base / "mods").install(source)

    def test_scripts_entrypoints_and_unknown_capabilities_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as folder:
            base = Path(folder)
            source = make_directory_package(base / "one")
            (source / "assets").mkdir()
            (source / "assets" / "run.py").write_text("print('never')", encoding="utf-8")
            with self.assertRaisesRegex(ModValidationError, "unsupported asset type"):
                ModManager("1.3.0-beta.1", base / "mods").install(source)

            shutil.rmtree(source)
            files = theme_payloads()
            bad_manifest = shared_manifest(files)
            bad_manifest["entrypoint"] = "run.py"
            source = make_directory_package(base / "two", payloads=files, package_manifest=bad_manifest)
            with self.assertRaisesRegex(ModValidationError, "unknown manifest field"):
                ModManager("1.3.0-beta.1", base / "mods").install(source)

            bad_manifest.pop("entrypoint")
            bad_manifest["capabilities"] = ["native-code"]
            (source / "mod.json").write_bytes(json_bytes(bad_manifest))
            with self.assertRaisesRegex(ModValidationError, "unsupported capability"):
                ModManager("1.3.0-beta.1", base / "mods").install(source)

    def test_integrity_mismatch_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as folder:
            base = Path(folder)
            source = make_directory_package(base / "source")
            (source / "themes" / "midnight.json").write_text("{}", encoding="utf-8")
            with self.assertRaisesRegex(ModValidationError, "SHA-256 mismatch"):
                ModManager("1.3.0-beta.1", base / "mods").install(source)

    def test_renamed_executable_magic_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as folder:
            base = Path(folder)
            payloads = theme_payloads()
            payloads["assets/readme.txt"] = b"#! /bin/sh\necho unsafe\n"
            source = make_zip_package(base / "magic.netvistamod", payloads=payloads,
                                      package_manifest=shared_manifest(payloads))
            with self.assertRaisesRegex(ModValidationError, "executable content"):
                ModManager("1.3.0-beta.1", base / "mods").install(source)

    def test_size_limits_reject_oversized_payload(self) -> None:
        with tempfile.TemporaryDirectory() as folder:
            base = Path(folder)
            source = make_directory_package(base / "source")
            (source / "assets").mkdir(exist_ok=True)
            (source / "assets" / "large.txt").write_bytes(b"x" * 2_048)
            limits = ModLimits(max_archive_bytes=10_000, max_unpacked_bytes=10_000,
                               max_files=10, max_single_file_bytes=1_024)
            with self.assertRaisesRegex(ModValidationError, "per-file size limit"):
                ModManager("1.3.0-beta.1", base / "mods", limits).install(source)

    def test_incompatible_mod_is_rejected_before_install(self) -> None:
        with tempfile.TemporaryDirectory() as folder:
            base = Path(folder)
            files = theme_payloads()
            manifest = shared_manifest(files, minimum="2.0.0")
            source = make_directory_package(base / "source", payloads=files, package_manifest=manifest)
            manager = ModManager("1.3.0-beta.1", base / "mods")
            with self.assertRaisesRegex(ModCompatibilityError, "Requires NetVista Studio 2.0.0"):
                manager.install(source)
            self.assertEqual(manager.scan().packages, [])

    def test_invalid_shared_theme_tokens_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as folder:
            base = Path(folder)
            files = theme_payloads({"accent": "red; background: url(file:///secret)"})
            source = make_zip_package(base / "unsafe-style.netvistamod", payloads=files,
                                      package_manifest=shared_manifest(files))
            with self.assertRaisesRegex(ModValidationError, "must be #RRGGBB"):
                ModManager("1.3.0-beta.1", base / "mods").install(source)

    def test_unknown_manifest_fields_and_http_publishers_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as folder:
            base = Path(folder)
            files = theme_payloads()
            manifest = shared_manifest(files)
            manifest["script"] = "assets/readme.txt"
            source = make_directory_package(base / "one", payloads=files, package_manifest=manifest)
            with self.assertRaisesRegex(ModValidationError, "unknown manifest field"):
                ModManager("1.3.0-beta.1", base / "mods").install(source)

            shutil.rmtree(source)
            manifest.pop("script")
            manifest["publisher"]["website"] = "http://example.com"
            source = make_directory_package(base / "two", payloads=files, package_manifest=manifest)
            with self.assertRaisesRegex(ModValidationError, "HTTPS"):
                ModManager("1.3.0-beta.1", base / "mods").install(source)

    def test_empty_theme_token_object_is_portable_and_safe(self) -> None:
        with tempfile.TemporaryDirectory() as folder:
            base = Path(folder)
            files = theme_payloads({})
            source = make_zip_package(base / "empty-theme.netvistamod", payloads=files,
                                      package_manifest=shared_manifest(files))
            package = ModManager("1.3.0-beta.1", base / "mods").install(source)
            self.assertEqual(package.theme_tokens_data, {})

    def test_theme_builder_ignores_unapproved_values(self) -> None:
        styled = build_app_style({"accent": "#123456", "unknown": "#FFFFFF", "panelBackground": "url(x)"})
        self.assertIn("#123456", styled)
        self.assertIn(DEFAULT_THEME["panelBackground"], styled)
        self.assertNotIn("url(x)", styled)

    def test_corrupt_state_fails_closed_and_is_reported(self) -> None:
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder) / "mods"
            root.mkdir()
            (root / "mods-state.json").write_text("not json", encoding="utf-8")
            manager = ModManager("1.3.0-beta.1", root)
            self.assertEqual(manager.enabled_ids, ())
            self.assertIn("Mods state was reset", manager.scan().errors[0])


if __name__ == "__main__":
    unittest.main()
