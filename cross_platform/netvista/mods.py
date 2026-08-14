from __future__ import annotations

import hashlib
import json
import math
import os
import re
import shutil
import stat
import tempfile
import unicodedata
import uuid
import zipfile
from dataclasses import dataclass, field
from pathlib import Path, PurePosixPath
from typing import Any, Mapping
from urllib.parse import urlparse

from .updater import compare_versions


MOD_SCHEMA_VERSION = 1
THEME_SCHEMA_VERSION = 1
SUPPORTED_MOD_APIS = frozenset({"1.0"})
SUPPORTED_CAPABILITIES = frozenset({"theme", "page", "sceneProp", "sceneMap", "effectPreset"})
CONTENT_KEYS = {
    "theme": "themes",
    "page": "pages",
    "sceneProp": "sceneProps",
    "sceneMap": "sceneMaps",
    "effectPreset": "effectPresets",
}
THEME_TOKENS = frozenset({
    "windowBackground", "topBarBackground", "panelBackground", "workspaceBackground",
    "cardBackground", "controlBackground", "primaryText", "secondaryText", "accent",
    "danger", "separator", "cornerRadius",
})

_ID_PATTERN = re.compile(r"^[a-z0-9]+(?:[.-][a-z0-9]+)+$")
_VERSION_PATTERN = re.compile(r"^[vV]?\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$")
_COLOUR_PATTERN = re.compile(r"^#?[0-9A-Fa-f]{6}(?:[0-9A-Fa-f]{2})?$")
_HASH_PATTERN = re.compile(r"^[0-9A-Fa-f]{64}$")
_PAGE_ACTIONS = frozenset({"importMedia", "open3DScene", "openModsFolder", "showCatalog", "openURL"})
_PAGE_BLOCKS = frozenset({"heading", "text", "image", "divider", "button"})
_ALLOWED_ROOTS = frozenset({
    "themes", "pages", "scene-props", "scene-maps", "effect-presets", "assets", "docs",
})
_JSON_ROOTS = frozenset({"themes", "pages", "scene-props", "scene-maps", "effect-presets"})
_ASSET_EXTENSIONS = frozenset({
    ".json", ".png", ".jpg", ".jpeg", ".heic", ".tif", ".tiff", ".webp",
    ".obj", ".mtl", ".abc", ".ply", ".stl", ".usd", ".usda", ".usdc", ".usdz",
    ".dae", ".scn", ".cube", ".mov", ".mp4", ".m4v", ".wav", ".aiff", ".aif",
    ".mp3", ".m4a", ".md", ".txt",
})
_DOC_EXTENSIONS = frozenset({".md", ".txt", ".png", ".jpg", ".jpeg"})
_PAGE_IMAGE_EXTENSIONS = frozenset({".png", ".jpg", ".jpeg", ".heic", ".tif", ".tiff", ".webp"})
_EXECUTABLE_MAGIC = (
    b"\x7fELF", b"MZ", b"#!", b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe",
    b"\xfe\xed\xfa\xcf", b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe",
)


class ModError(ValueError):
    """A package or Mods-folder operation was rejected safely."""


class ModValidationError(ModError):
    pass


class ModCompatibilityError(ModError):
    pass


@dataclass(frozen=True)
class ModLimits:
    # Kept identical to the native macOS validator so a conforming package is
    # accepted (or rejected) consistently on all supported systems.
    max_archive_bytes: int = 1_073_741_824
    max_unpacked_bytes: int = 2_147_483_648
    max_files: int = 20_000
    max_single_file_bytes: int = 536_870_912
    max_compression_ratio: int = 100


@dataclass(frozen=True)
class ModPublisher:
    name: str
    website: str | None = None


@dataclass(frozen=True)
class ModDependency:
    identifier: str
    min_version: str | None = None


@dataclass(frozen=True)
class ModContent:
    themes: tuple[str, ...] = ()
    pages: tuple[str, ...] = ()
    scene_props: tuple[str, ...] = ()
    scene_maps: tuple[str, ...] = ()
    effect_presets: tuple[str, ...] = ()

    def paths(self) -> tuple[str, ...]:
        return self.themes + self.pages + self.scene_props + self.scene_maps + self.effect_presets


@dataclass(frozen=True)
class ModContentSummary:
    kind: str
    identifier: str
    name: str
    summary: str
    path: str


@dataclass(frozen=True)
class ModPackage:
    identifier: str
    name: str
    version: str
    publisher: ModPublisher
    description: str
    capabilities: tuple[str, ...]
    content: ModContent
    dependencies: tuple[ModDependency, ...]
    path: Path
    manifest_member: str = "mod.json"
    theme_member: str | None = None
    theme_tokens_data: Mapping[str, Any] = field(default_factory=dict)
    content_items: tuple[ModContentSummary, ...] = ()
    compatible: bool = True
    compatibility_message: str = "Compatible"

    @property
    def author(self) -> str:
        return self.publisher.name


@dataclass
class ModCatalog:
    packages: list[ModPackage] = field(default_factory=list)
    errors: list[str] = field(default_factory=list)

    def package(self, identifier: str) -> ModPackage | None:
        return next((item for item in self.packages if item.identifier == identifier), None)


@dataclass
class _PackageView:
    path: Path
    prefix: str
    files: dict[str, str]
    archive: bool

    def read(self, logical_path: str, maximum: int | None = None) -> bytes:
        member = self.files.get(logical_path)
        if member is None:
            raise ModValidationError(f"package file is missing: {logical_path}")
        try:
            if self.archive:
                with zipfile.ZipFile(self.path) as source:
                    info = source.getinfo(member)
                    if maximum is not None and info.file_size > maximum:
                        raise ModValidationError(f"{logical_path} is too large")
                    return source.read(member)
            target = self.path / PurePosixPath(member)
            if maximum is not None and target.stat().st_size > maximum:
                raise ModValidationError(f"{logical_path} is too large")
            return target.read_bytes()
        except ModValidationError:
            raise
        except (OSError, KeyError, RuntimeError, zipfile.BadZipFile) as error:
            raise ModValidationError(f"cannot read package file {logical_path}: {error}") from error

    def digest_and_prefix(self, logical_path: str) -> tuple[str, bytes]:
        member = self.files.get(logical_path)
        if member is None:
            raise ModValidationError(f"package file is missing: {logical_path}")
        try:
            digest = hashlib.sha256()
            prefix = b""
            if self.archive:
                with zipfile.ZipFile(self.path) as archive:
                    with archive.open(member) as stream:
                        prefix = _hash_stream(stream, digest)
            else:
                with (self.path / PurePosixPath(member)).open("rb") as stream:
                    prefix = _hash_stream(stream, digest)
            return digest.hexdigest(), prefix
        except (OSError, KeyError, RuntimeError, zipfile.BadZipFile) as error:
            raise ModValidationError(f"cannot verify package file {logical_path}: {error}") from error


def default_mods_directory(
    system_name: str | None = None,
    environ: Mapping[str, str] | None = None,
    home: Path | None = None,
) -> Path:
    """Return a per-user writable folder that survives application updates."""
    env = dict(os.environ if environ is None else environ)
    system = (system_name or os.name).lower()
    user_home = Path(home) if home is not None else Path.home()
    if system in {"windows", "win32", "nt"}:
        base = Path(env.get("APPDATA") or user_home / "AppData" / "Roaming")
        return base / "NetVista Studio" / "Mods"
    if system in {"darwin", "macos"}:
        return user_home / "Library" / "Application Support" / "NetVista Studio" / "Mods"
    base = Path(env.get("XDG_DATA_HOME") or user_home / ".local" / "share")
    return base / "netvista-studio" / "mods"


class ModManager:
    """Cross-platform reader for NetVista's shared, declarative Mod API v1.

    No package content is imported as Python, loaded as a native library, sent
    to a shell, or treated as HTML. Integrity-checked JSON is the only active
    input; other package assets remain inert catalog resources.
    """

    def __init__(
        self,
        app_version: str,
        root: str | Path | None = None,
        limits: ModLimits | None = None,
    ) -> None:
        self.app_version = app_version
        self.root = Path(root) if root is not None else default_mods_directory()
        self.limits = limits or ModLimits()
        self.state_path = self.root / "mods-state.json"
        self.root.mkdir(parents=True, exist_ok=True)
        self._enabled, self.state_error = self._read_state()

    @property
    def enabled_ids(self) -> tuple[str, ...]:
        return tuple(self._enabled)

    def scan(self) -> ModCatalog:
        catalog = ModCatalog()
        if self.state_error:
            catalog.errors.append(self.state_error)
        seen: set[str] = set()
        for path in sorted(self.root.iterdir(), key=lambda item: item.name.lower()):
            if path.name.startswith(".") or path == self.state_path or not self.is_package_source(path):
                continue
            try:
                package = self.validate(path)
                if package.identifier in seen:
                    raise ModValidationError(f"duplicate mod ID {package.identifier!r}")
                seen.add(package.identifier)
                catalog.packages.append(package)
            except ModError as error:
                catalog.errors.append(f"{path.name}: {error}")
        return catalog

    @staticmethod
    def is_package_source(path: str | Path) -> bool:
        source = Path(path)
        if source.is_file():
            return source.suffix.lower() == ".netvistamod"
        if source.is_dir():
            return source.suffix.lower() == ".netvistamod" or (source / "mod.json").is_file()
        return False

    def validate(self, source: str | Path) -> ModPackage:
        path = Path(source)
        if not path.exists():
            raise ModValidationError("package does not exist")
        if path.is_symlink():
            raise ModValidationError("symbolic-link packages are not allowed")
        view = self._inspect_archive(path) if path.is_file() else self._inspect_directory(path)
        manifest_data = view.read("mod.json", 262_144)
        manifest = self._validate_manifest_json(manifest_data)
        content = self._validate_content(manifest["content"], manifest["capabilities"])
        referenced = set(content.paths())
        integrity = self._validate_integrity(manifest["integrity"], view, referenced)
        del integrity  # Validation has already compared every declared digest.

        theme_tokens: Mapping[str, Any] = {}
        theme_member = content.themes[0] if content.themes else None
        summaries: list[ModContentSummary] = []
        for content_path in content.themes:
            document = self._validate_theme_json(view.read(content_path, 1_048_576), content_path)
            if content_path == theme_member:
                theme_tokens = document["tokens"]
            summaries.append(ModContentSummary("Theme", document["id"], document["name"], "Visual theme", content_path))
        for content_path in content.pages:
            document = self._validate_page_json(view.read(content_path, 1_048_576), content_path, view)
            summaries.append(ModContentSummary("Page", document["id"], document["title"], document.get("summary") or "Declarative page", content_path))
        for label, paths in (("Scene Prop", content.scene_props), ("Scene Map", content.scene_maps),
                             ("Effect Preset", content.effect_presets)):
            for content_path in paths:
                document = self._validate_catalog_json(view.read(content_path, 1_048_576), content_path, view)
                summaries.append(ModContentSummary(label, document["id"], document["name"], document.get("summary") or label, content_path))

        publisher_data = manifest["publisher"]
        minimum = manifest["minAppVersion"]
        maximum = manifest.get("maxAppVersion")
        if compare_versions(self.app_version, minimum) < 0:
            raise ModCompatibilityError(f"Requires NetVista Studio {minimum} or newer")
        elif maximum and compare_versions(self.app_version, maximum) > 0:
            raise ModCompatibilityError(f"Supports NetVista Studio {maximum} or older")
        dependencies = tuple(
            ModDependency(item["id"], item.get("minVersion"))
            for item in manifest.get("dependencies", [])
        )
        return ModPackage(
            identifier=manifest["id"], name=manifest["name"].strip(), version=manifest["version"],
            publisher=ModPublisher(publisher_data["name"].strip(), publisher_data.get("website")),
            description=manifest["description"].strip(), capabilities=tuple(manifest["capabilities"]),
            content=content, dependencies=dependencies, path=path, manifest_member=f"{view.prefix}mod.json",
            theme_member=f"{view.prefix}{theme_member}" if theme_member else None,
            theme_tokens_data=theme_tokens, content_items=tuple(summaries), compatible=True,
            compatibility_message="Compatible",
        )

    def install(self, source: str | Path) -> ModPackage:
        source_path = Path(source)
        package = self.validate(source_path)
        destination = self.root / f"{package.identifier}.netvistamod"
        self._assert_direct_child(destination)
        try:
            if source_path.resolve() == destination.resolve():
                return package
        except OSError:
            pass
        staging = self.root / f".{package.identifier}.install-{uuid.uuid4().hex}.netvistamod"
        backup = self.root / f".{package.identifier}.backup-{uuid.uuid4().hex}.netvistamod"
        self._assert_direct_child(staging)
        self._assert_direct_child(backup)
        moved_existing = False
        try:
            if source_path.is_dir():
                shutil.copytree(source_path, staging, symlinks=False)
            else:
                shutil.copy2(source_path, staging)
            self.validate(staging)
            if destination.exists():
                destination.rename(backup)
                moved_existing = True
            staging.rename(destination)
            if moved_existing:
                self._delete_package_path(backup)
            return self.validate(destination)
        except Exception:
            if staging.exists():
                self._delete_package_path(staging)
            if moved_existing and backup.exists() and not destination.exists():
                backup.rename(destination)
            raise

    def remove(self, identifier: str) -> None:
        package = self.scan().package(identifier)
        if package is None:
            raise ModError(f"Mod {identifier!r} is not installed")
        self._assert_direct_child(package.path)
        self._delete_package_path(package.path)
        if identifier in self._enabled:
            self._enabled = [item for item in self._enabled if item != identifier]
            self._write_state()

    def is_enabled(self, identifier: str) -> bool:
        return identifier in self._enabled

    def set_enabled(self, identifier: str, enabled: bool) -> None:
        catalog = self.scan()
        package = catalog.package(identifier)
        if package is None:
            raise ModError(f"Mod {identifier!r} is not installed")
        if enabled and not package.compatible:
            raise ModCompatibilityError(package.compatibility_message)
        if enabled:
            for dependency in package.dependencies:
                installed = catalog.package(dependency.identifier)
                if installed is None or not self.is_enabled(dependency.identifier):
                    raise ModCompatibilityError(f"Enable required mod {dependency.identifier} first")
                if dependency.min_version and compare_versions(installed.version, dependency.min_version) < 0:
                    raise ModCompatibilityError(
                        f"{dependency.identifier} {dependency.min_version} or newer is required"
                    )
        self._enabled = [item for item in self._enabled if item != identifier]
        if enabled:
            self._enabled.append(identifier)
        self._write_state()

    def active_theme_tokens(self, catalog: ModCatalog | None = None) -> dict[str, Any]:
        current = catalog or self.scan()
        packages = {package.identifier: package for package in current.packages}
        tokens: dict[str, Any] = {}
        for identifier in self._enabled:
            package = packages.get(identifier)
            if package and package.compatible and "theme" in package.capabilities:
                tokens.update(package.theme_tokens_data)
        return tokens

    def theme_tokens(self, package: ModPackage) -> dict[str, Any]:
        return dict(package.theme_tokens_data)

    def _inspect_archive(self, path: Path) -> _PackageView:
        try:
            if path.stat().st_size > self.limits.max_archive_bytes:
                raise ModValidationError("archive is larger than the Mods v1 safety limit")
        except OSError as error:
            raise ModValidationError(f"cannot read package: {error}") from error
        if not zipfile.is_zipfile(path):
            raise ModValidationError(".netvistamod files must use ZIP format")
        try:
            with zipfile.ZipFile(path) as archive:
                members: dict[str, zipfile.ZipInfo] = {}
                canonical_paths: set[str] = set()
                total = 0
                entry_count = 0
                for info in archive.infolist():
                    entry_count += 1
                    if entry_count > self.limits.max_files:
                        raise ModValidationError("package contains too many entries")
                    normalized = _safe_package_path(info.filename, directory=info.is_dir())
                    canonical = _canonical_package_path(normalized)
                    if canonical in canonical_paths:
                        raise ModValidationError(f"duplicate or case-colliding path: {normalized}")
                    canonical_paths.add(canonical)
                    if info.is_dir():
                        continue
                    if info.flag_bits & 0x1:
                        raise ModValidationError(f"encrypted file is not allowed: {normalized}")
                    unix_mode = info.external_attr >> 16
                    file_type = unix_mode & 0o170000
                    if file_type == stat.S_IFLNK:
                        raise ModValidationError(f"symbolic link is not allowed: {normalized}")
                    if file_type not in {0, stat.S_IFREG}:
                        raise ModValidationError(f"special file is not allowed: {normalized}")
                    if unix_mode & 0o111:
                        raise ModValidationError(f"executable file permissions are not allowed: {normalized}")
                    if info.file_size > self.limits.max_single_file_bytes:
                        raise ModValidationError(f"file exceeds the per-file size limit: {normalized}")
                    if info.file_size > 1_024 and (
                        info.compress_size <= 0 or info.file_size // max(1, info.compress_size) > self.limits.max_compression_ratio
                    ):
                        raise ModValidationError(f"unsafe compression ratio: {normalized}")
                    total += info.file_size
                    if total > self.limits.max_unpacked_bytes:
                        raise ModValidationError("unpacked package exceeds the Mods v1 safety limit")
                    members[normalized] = info
                if "mod.json" not in members:
                    raise ModValidationError("mod.json must be at the archive root")
                return _PackageView(path, "", {name: name for name in members}, True)
        except (OSError, zipfile.BadZipFile) as error:
            raise ModValidationError(f"cannot read ZIP package: {error}") from error

    def _inspect_directory(self, path: Path) -> _PackageView:
        root = path.resolve()
        if not (root / "mod.json").is_file():
            raise ModValidationError("directory package is missing root mod.json")
        files: dict[str, str] = {}
        canonical_paths: set[str] = set()
        total = 0
        for candidate in root.rglob("*"):
            if candidate.is_symlink():
                raise ModValidationError(f"symbolic links are not allowed: {candidate.name}")
            try:
                relative = candidate.relative_to(root).as_posix()
                metadata = candidate.stat()
            except (OSError, ValueError) as error:
                raise ModValidationError(f"cannot inspect package file: {error}") from error
            is_directory = candidate.is_dir()
            relative = _safe_package_path(relative, directory=is_directory)
            canonical = _canonical_package_path(relative)
            if canonical in canonical_paths:
                raise ModValidationError(f"duplicate or case-colliding path: {relative}")
            canonical_paths.add(canonical)
            if len(canonical_paths) > self.limits.max_files:
                raise ModValidationError("package contains too many entries")
            if is_directory:
                continue
            if not candidate.is_file():
                raise ModValidationError(f"special files are not allowed: {relative}")
            if metadata.st_mode & 0o111:
                raise ModValidationError(f"executable file permissions are not allowed: {relative}")
            size = metadata.st_size
            files[relative] = relative
            total += size
            if size > self.limits.max_single_file_bytes:
                raise ModValidationError(f"file exceeds the per-file size limit: {relative}")
            if total > self.limits.max_unpacked_bytes:
                raise ModValidationError("package exceeds the Mods v1 safety limit")
        return _PackageView(path, "", files, False)

    def _validate_manifest_json(self, data: bytes) -> dict[str, Any]:
        manifest = _json_object(data, "mod.json")
        _exact_keys(
            manifest,
            allowed={"schemaVersion", "modAPI", "id", "name", "version", "publisher", "description",
                     "minAppVersion", "maxAppVersion", "capabilities", "dependencies", "content", "integrity"},
            required={"schemaVersion", "modAPI", "id", "name", "version", "publisher", "description",
                      "minAppVersion", "capabilities", "content", "integrity"},
            context="manifest",
        )
        if type(manifest.get("schemaVersion")) is not int or manifest["schemaVersion"] != MOD_SCHEMA_VERSION:
            raise ModValidationError(f"schemaVersion must be {MOD_SCHEMA_VERSION}")
        if manifest.get("modAPI") not in SUPPORTED_MOD_APIS:
            raise ModValidationError("modAPI must be 1.0")
        identifier = manifest.get("id")
        if not isinstance(identifier, str) or len(identifier) > 100 or not _ID_PATTERN.fullmatch(identifier):
            raise ModValidationError("id must be a lowercase reverse-DNS identifier")
        for key, maximum in (("name", 80), ("description", 500)):
            value = manifest.get(key)
            _bounded_text(value, key, maximum)
        version = manifest.get("version")
        if not isinstance(version, str) or not _VERSION_PATTERN.fullmatch(version):
            raise ModValidationError("version must use semantic versioning, such as 1.0.0")
        for key in ("minAppVersion", "maxAppVersion"):
            value = manifest.get(key)
            if (key == "minAppVersion" and value is None) or (value is not None and (not isinstance(value, str) or not _VERSION_PATTERN.fullmatch(value))):
                raise ModValidationError(f"{key} must use semantic versioning")
        publisher = manifest.get("publisher")
        if not isinstance(publisher, dict):
            raise ModValidationError("publisher must be an object")
        _exact_keys(publisher, {"name", "website"}, {"name"}, "publisher")
        _bounded_text(publisher.get("name"), "publisher.name", 80)
        website = publisher.get("website")
        if website is not None:
            parsed = urlparse(website) if isinstance(website, str) else None
            if not parsed or parsed.scheme.lower() != "https" or not parsed.hostname or len(website) > 500:
                raise ModValidationError("publisher.website must be an HTTPS URL")
        capabilities = manifest.get("capabilities")
        if not isinstance(capabilities, list) or not all(isinstance(item, str) for item in capabilities):
            raise ModValidationError("capabilities must be a string array")
        if len(capabilities) != len(set(capabilities)):
            raise ModValidationError("capabilities cannot contain duplicates")
        unsupported = sorted(set(capabilities) - SUPPORTED_CAPABILITIES)
        if unsupported:
            raise ModValidationError(f"unsupported capability: {', '.join(unsupported)}")
        if not isinstance(manifest.get("content"), dict):
            raise ModValidationError("content must be an object")
        _exact_keys(manifest["content"], set(CONTENT_KEYS.values()), set(), "content")
        if not isinstance(manifest.get("integrity"), dict):
            raise ModValidationError("integrity must be an object")
        _exact_keys(manifest["integrity"], {"algorithm", "files"}, {"algorithm", "files"}, "integrity")
        dependencies = manifest.get("dependencies", [])
        if dependencies is not None:
            if not isinstance(dependencies, list):
                raise ModValidationError("dependencies must be an array")
            dependency_ids: set[str] = set()
            for dependency in dependencies:
                if not isinstance(dependency, dict):
                    raise ModValidationError("dependency must be an object")
                _exact_keys(dependency, {"id", "minVersion"}, {"id"}, "dependency")
                dependency_id = dependency.get("id")
                if (not isinstance(dependency_id, str) or len(dependency_id) > 100
                        or not _ID_PATTERN.fullmatch(dependency_id)):
                    raise ModValidationError("dependency id is invalid")
                if dependency_id == identifier or dependency_id in dependency_ids:
                    raise ModValidationError("dependencies must be unique and cannot reference the mod itself")
                dependency_ids.add(dependency_id)
                minimum = dependency.get("minVersion")
                if minimum is not None and (not isinstance(minimum, str) or not _VERSION_PATTERN.fullmatch(minimum)):
                    raise ModValidationError("dependency minVersion is invalid")
        return manifest

    def _validate_content(self, data: dict[str, Any], capabilities: list[str]) -> ModContent:
        allowed = set(CONTENT_KEYS.values())
        unknown = sorted(set(data) - allowed)
        if unknown:
            raise ModValidationError(f"unknown content collection: {', '.join(unknown)}")
        values: dict[str, tuple[str, ...]] = {}
        declared_paths: set[str] = set()
        expected_prefixes = {
            "themes": "themes/", "pages": "pages/", "sceneProps": "scene-props/",
            "sceneMaps": "scene-maps/", "effectPresets": "effect-presets/",
        }
        for key in allowed:
            items = data.get(key, [])
            if not isinstance(items, list) or not all(isinstance(item, str) for item in items):
                raise ModValidationError(f"content.{key} must be a string array")
            safe = tuple(_safe_package_path(item) for item in items)
            if len(safe) != len(set(safe)):
                raise ModValidationError(f"content.{key} contains duplicate paths")
            for path in safe:
                if not path.startswith(expected_prefixes[key]) or not path.endswith(".json"):
                    raise ModValidationError(
                        f"content.{key} paths must be JSON files inside {expected_prefixes[key]}"
                    )
                if path in declared_paths:
                    raise ModValidationError("declared content paths must be unique")
                declared_paths.add(path)
            values[key] = safe
        for capability, key in CONTENT_KEYS.items():
            if values[key] and capability not in capabilities:
                raise ModValidationError(f"content.{key} requires capability {capability}")
        return ModContent(values["themes"], values["pages"], values["sceneProps"],
                          values["sceneMaps"], values["effectPresets"])

    def _validate_integrity(self, data: dict[str, Any], view: _PackageView, referenced: set[str]) -> dict[str, str]:
        if not isinstance(data.get("algorithm"), str) or data["algorithm"].lower() != "sha256":
            raise ModValidationError("integrity.algorithm must be sha256")
        hashes = data.get("files")
        if not isinstance(hashes, dict) or not all(isinstance(key, str) and isinstance(value, str) for key, value in hashes.items()):
            raise ModValidationError("integrity.files must map package paths to SHA-256 values")
        normalized: dict[str, str] = {}
        for raw_path, raw_hash in hashes.items():
            path = _safe_package_path(raw_path)
            if not _HASH_PATTERN.fullmatch(raw_hash):
                raise ModValidationError(f"invalid SHA-256 for {path}")
            if path in normalized:
                raise ModValidationError(f"duplicate integrity path: {path}")
            normalized[path] = raw_hash.lower()
        payload_files = set(view.files) - {"mod.json"}
        if set(normalized) != payload_files:
            missing = sorted(payload_files - set(normalized))
            extra = sorted(set(normalized) - payload_files)
            detail = f"missing {', '.join(missing)}" if missing else f"unknown {', '.join(extra)}"
            raise ModValidationError(f"integrity.files must cover every payload file ({detail})")
        if not referenced.issubset(normalized):
            raise ModValidationError("every content file must have an integrity digest")
        for path, expected in normalized.items():
            actual, prefix = view.digest_and_prefix(path)
            _reject_executable_magic(prefix, path)
            if actual != expected:
                raise ModValidationError(f"SHA-256 mismatch for {path}")
        return normalized

    def _validate_theme_json(self, data: bytes, source_name: str) -> dict[str, Any]:
        document = _json_object(data, source_name)
        _exact_keys(document, {"schemaVersion", "id", "name", "tokens"},
                    {"schemaVersion", "id", "name", "tokens"}, "theme")
        if type(document.get("schemaVersion")) is not int or document["schemaVersion"] != THEME_SCHEMA_VERSION:
            raise ModValidationError(f"{source_name}: schemaVersion must be {THEME_SCHEMA_VERSION}")
        identifier = document.get("id")
        if not isinstance(identifier, str) or not identifier or len(identifier) > 100:
            raise ModValidationError(f"{source_name}: id is invalid")
        _bounded_text(document.get("name"), f"{source_name} name", 80)
        tokens = document.get("tokens")
        if not isinstance(tokens, dict):
            raise ModValidationError(f"{source_name}: tokens must be an object")
        unknown = sorted(set(tokens) - THEME_TOKENS)
        if unknown:
            raise ModValidationError(f"{source_name}: unknown theme token {', '.join(unknown)}")
        normalized: dict[str, Any] = {}
        for key, value in tokens.items():
            if key == "cornerRadius":
                if (not isinstance(value, (int, float)) or isinstance(value, bool)
                        or not math.isfinite(float(value)) or not 0 <= float(value) <= 16):
                    raise ModValidationError(f"{source_name}: cornerRadius must be between 0 and 16")
                normalized[key] = float(value)
            else:
                if not isinstance(value, str) or not _COLOUR_PATTERN.fullmatch(value):
                    raise ModValidationError(f"{source_name}: {key} must be #RRGGBB or #RRGGBBAA")
                normalized[key] = value if value.startswith("#") else f"#{value}"
        document["tokens"] = normalized
        return document

    def _validate_page_json(self, data: bytes, source_name: str, view: _PackageView) -> dict[str, Any]:
        document = _json_object(data, source_name)
        _exact_keys(document, {"schemaVersion", "id", "title", "summary", "blocks"},
                    {"schemaVersion", "id", "title", "blocks"}, "page")
        if type(document.get("schemaVersion")) is not int or document["schemaVersion"] != 1:
            raise ModValidationError(f"{source_name}: schemaVersion must be 1")
        identifier = document.get("id")
        if not isinstance(identifier, str) or not identifier or len(identifier) > 100:
            raise ModValidationError(f"{source_name}: id is invalid")
        _bounded_text(document.get("title"), f"{source_name} title", 100)
        summary = document.get("summary")
        if summary is not None:
            _bounded_text(summary, f"{source_name} summary", 2_000)
        blocks = document.get("blocks")
        if not isinstance(blocks, list) or len(blocks) > 100:
            raise ModValidationError(f"{source_name}: blocks must be an array with at most 100 items")
        for block in blocks:
            if not isinstance(block, dict):
                raise ModValidationError(f"{source_name}: every block must be an object")
            _exact_keys(block, {"kind", "title", "text", "image", "action", "arguments"},
                        {"kind"}, "page block")
            kind = block.get("kind")
            if not isinstance(kind, str) or kind not in _PAGE_BLOCKS:
                raise ModValidationError(f"{source_name}: every block requires a kind")
            title = block.get("title")
            if title is not None:
                _bounded_text(title, f"{source_name} block title", 160)
            text = block.get("text")
            if text is not None:
                _bounded_text(text, f"{source_name} block text", 4_000)
            image = block.get("image")
            if image:
                if not isinstance(image, str):
                    raise ModValidationError(f"{source_name}: block image is invalid")
                image = _safe_package_path(image)
                if image not in view.files or Path(image).suffix.lower() not in _PAGE_IMAGE_EXTENSIONS:
                    raise ModValidationError(f"{source_name}: block image must be a hashed image asset: {image}")
            action = block.get("action")
            if action is not None and (not isinstance(action, str) or action not in _PAGE_ACTIONS):
                raise ModValidationError(f"{source_name}: unsupported page action {action}")
            arguments = block.get("arguments")
            if arguments is not None:
                if (not isinstance(arguments, dict) or len(arguments) > 12
                        or not all(isinstance(k, str) and isinstance(v, str)
                                   and len(k) <= 50 and len(v) <= 500 for k, v in arguments.items())):
                    raise ModValidationError(f"{source_name}: action arguments are too large or invalid")
            if action == "openURL" and isinstance(arguments, dict) and "url" in arguments:
                target = urlparse(arguments["url"])
                if target.scheme.lower() != "https" or not target.hostname:
                    raise ModValidationError(f"{source_name}: page URLs must use HTTPS")
        return document

    def _validate_catalog_json(self, data: bytes, source_name: str, view: _PackageView) -> dict[str, Any]:
        document = _json_object(data, source_name)
        _exact_keys(document, {"schemaVersion", "id", "name", "summary", "asset", "parameters"},
                    {"schemaVersion", "id", "name"}, "catalog item")
        if type(document.get("schemaVersion")) is not int or document["schemaVersion"] != 1:
            raise ModValidationError(f"{source_name}: schemaVersion must be 1")
        identifier = document.get("id")
        if not isinstance(identifier, str) or not identifier or len(identifier) > 100:
            raise ModValidationError(f"{source_name}: id is invalid")
        _bounded_text(document.get("name"), f"{source_name} name", 100)
        summary = document.get("summary")
        if summary is not None:
            _bounded_text(summary, f"{source_name} summary", 2_000)
        asset = document.get("asset")
        if asset is not None:
            if not isinstance(asset, str):
                raise ModValidationError(f"{source_name}: asset must be a package path")
            asset = _safe_package_path(asset)
            if asset not in view.files:
                raise ModValidationError(f"{source_name}: asset is missing: {asset}")
        parameters = document.get("parameters")
        if parameters is not None:
            if (not isinstance(parameters, dict) or len(parameters) > 100
                    or not all(isinstance(key, str) and len(key) <= 80
                               and isinstance(value, (int, float)) and not isinstance(value, bool)
                               and math.isfinite(float(value)) and abs(float(value)) <= 1_000_000
                               for key, value in parameters.items())):
                raise ModValidationError(f"{source_name}: parameters are outside safe limits")
        return document

    def _read_state(self) -> tuple[list[str], str | None]:
        if not self.state_path.exists():
            return [], None
        try:
            data = json.loads(self.state_path.read_text(encoding="utf-8"))
            if not isinstance(data, dict) or data.get("schemaVersion") != 1:
                raise ValueError("unsupported state schema")
            enabled = data.get("enabled", [])
            if not isinstance(enabled, list) or not all(isinstance(item, str) and _ID_PATTERN.fullmatch(item) for item in enabled):
                raise ValueError("enabled must be a list of mod IDs")
            return list(dict.fromkeys(enabled)), None
        except (OSError, UnicodeDecodeError, json.JSONDecodeError, ValueError) as error:
            return [], f"Mods state was reset because it could not be read: {error}"

    def _write_state(self) -> None:
        payload = json.dumps({"schemaVersion": 1, "enabled": self._enabled}, indent=2) + "\n"
        handle, temporary_name = tempfile.mkstemp(prefix=".mods-state-", suffix=".json", dir=self.root)
        temporary = Path(temporary_name)
        try:
            with os.fdopen(handle, "w", encoding="utf-8") as output:
                output.write(payload)
                output.flush()
                os.fsync(output.fileno())
            os.replace(temporary, self.state_path)
        finally:
            if temporary.exists():
                temporary.unlink()

    def _assert_direct_child(self, path: Path) -> None:
        try:
            if path.parent.resolve() != self.root.resolve():
                raise ModError("refusing to change a path outside the Mods folder")
        except OSError as error:
            raise ModError(f"cannot verify Mods folder path: {error}") from error

    @staticmethod
    def _delete_package_path(path: Path) -> None:
        if path.is_symlink() or path.is_file():
            path.unlink()
        elif path.is_dir():
            shutil.rmtree(path)


def _json_object(data: bytes, source_name: str) -> dict[str, Any]:
    if len(data) > 1_048_576:
        raise ModValidationError(f"{source_name} is too large")
    try:
        value = json.loads(data.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ModValidationError(f"{source_name} is not valid UTF-8 JSON: {error}") from error
    if not isinstance(value, dict):
        raise ModValidationError(f"{source_name} must contain an object")
    return value


def _exact_keys(
    value: Mapping[str, Any], allowed: set[str], required: set[str], context: str,
) -> None:
    keys = set(value)
    missing = sorted(required - keys)
    if missing:
        raise ModValidationError(f"{context} is missing required fields: {', '.join(missing)}")
    unknown = sorted(keys - allowed)
    if unknown:
        raise ModValidationError(f"unknown {context} field: {', '.join(unknown)}")


def _bounded_text(value: Any, field: str, maximum: int) -> None:
    if (not isinstance(value, str) or not value.strip() or len(value) > maximum
            or any(unicodedata.category(character) == "Cc" and character != "\n" for character in value)):
        raise ModValidationError(f"{field} is empty, too long, or contains control characters")


def _safe_package_path(raw_name: str, directory: bool = False) -> str:
    if (not isinstance(raw_name, str) or not raw_name or len(raw_name.encode("utf-8")) > 1_024
            or raw_name.startswith(("/", "~")) or "\\" in raw_name or ":" in raw_name):
        raise ModValidationError("package contains an invalid path")
    normalized = raw_name[:-1] if directory and raw_name.endswith("/") else raw_name
    parts = normalized.split("/")
    if (not parts or any(not part or part in {".", ".."} or len(part.encode("utf-8")) > 255
                         for part in parts)):
        raise ModValidationError(f"unsafe package path is not allowed: {raw_name}")
    if any(part.startswith(".") or any(unicodedata.category(character) == "Cc" for character in part)
           for part in parts):
        raise ModValidationError(f"hidden or control-character path is not allowed: {raw_name}")
    if normalized != "mod.json":
        root = parts[0]
        if root not in _ALLOWED_ROOTS:
            raise ModValidationError(f"unsupported top-level folder: {root}")
        if not directory:
            if len(parts) < 2:
                raise ModValidationError(f"payload files must be inside an allowed folder: {raw_name}")
            extension = Path(normalized).suffix.lower()
            if root in _JSON_ROOTS and extension != ".json":
                raise ModValidationError(f"{root} accepts JSON only: {raw_name}")
            if root == "assets" and extension not in _ASSET_EXTENSIONS:
                raise ModValidationError(f"unsupported asset type: {raw_name}")
            if root == "docs" and extension not in _DOC_EXTENSIONS:
                raise ModValidationError(f"unsupported documentation type: {raw_name}")
    return PurePosixPath(normalized).as_posix()


def _canonical_package_path(name: str) -> str:
    return unicodedata.normalize("NFC", name).lower()


def _hash_stream(stream: Any, digest: Any) -> bytes:
    prefix = b""
    while True:
        chunk = stream.read(4 * 1_024 * 1_024)
        if not chunk:
            break
        if len(prefix) < 8:
            prefix += chunk[:8 - len(prefix)]
        digest.update(chunk)
    return prefix


def _reject_executable_magic(data: bytes, name: str) -> None:
    prefix = data[:8]
    if any(prefix.startswith(signature) for signature in _EXECUTABLE_MAGIC):
        raise ModValidationError(f"executable content is not allowed, even when renamed: {name}")
