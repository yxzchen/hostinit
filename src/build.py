#!/usr/bin/env python3

from __future__ import annotations

import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import yaml
from yaml.constructor import ConstructorError


PROJECT_DIR = Path(__file__).resolve().parent.parent
SOURCE_DIR = PROJECT_DIR / "src"
CONFIG_PATH = SOURCE_DIR / "config.yaml"
OUTPUT_PATH = PROJECT_DIR / "hostinit.sh"
RUNTIME_PATHS = (
    SOURCE_DIR / "runtime" / "common.sh",
    SOURCE_DIR / "runtime" / "platform.sh",
    SOURCE_DIR / "runtime" / "tui.sh",
    SOURCE_DIR / "runtime" / "packages.sh",
    SOURCE_DIR / "runtime" / "executor.sh",
    SOURCE_DIR / "runtime" / "main.sh",
)

PLATFORMS = ("debian", "ubuntu", "macos")
KEY_PATTERN = re.compile(r"^[A-Za-z_][A-Za-z0-9_-]*$")


class BuildError(Exception):
    pass


class UniqueKeyLoader(yaml.SafeLoader):
    pass


def construct_unique_mapping(
    loader: UniqueKeyLoader, node: yaml.MappingNode, deep: bool = False
) -> dict[Any, Any]:
    loader.flatten_mapping(node)
    mapping: dict[Any, Any] = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node, deep=deep)
        try:
            duplicate = key in mapping
        except TypeError as error:
            raise ConstructorError(
                "while constructing a mapping",
                node.start_mark,
                "found an unhashable key",
                key_node.start_mark,
            ) from error
        if duplicate:
            raise ConstructorError(
                "while constructing a mapping",
                node.start_mark,
                f"found duplicate key {key!r}",
                key_node.start_mark,
            )
        mapping[key] = loader.construct_object(value_node, deep=deep)
    return mapping


UniqueKeyLoader.add_constructor(
    yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, construct_unique_mapping
)


@dataclass(frozen=True)
class PlatformConfig:
    source: str
    packages: tuple[str, ...]
    brew_type: str
    script: Path | None


@dataclass(frozen=True)
class Tool:
    path: tuple[str, ...]
    platforms: dict[str, PlatformConfig]

    @property
    def stable_id(self) -> str:
        return "/".join(self.path)

    @property
    def name(self) -> str:
        return self.path[-1]

    @property
    def label(self) -> str:
        return " / ".join(self.path)


@dataclass(frozen=True)
class Node:
    path: tuple[str, ...]
    parent_index: int
    tool_index: int

    @property
    def stable_id(self) -> str:
        return "/".join(self.path)

    @property
    def label(self) -> str:
        return self.path[-1]


def read_utf8(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as error:
        raise BuildError(f"cannot read {path}: {error}") from error


def load_config(path: Path) -> dict[str, Any]:
    try:
        raw = yaml.load(read_utf8(path), Loader=UniqueKeyLoader)
    except yaml.YAMLError as error:
        raise BuildError(f"cannot read {path}: {error}") from error
    if not isinstance(raw, dict):
        raise BuildError("configuration root must be a mapping")
    if tuple(raw) != ("tui",):
        raise BuildError("configuration root must contain only the 'tui' key")
    if not isinstance(raw["tui"], dict) or not raw["tui"]:
        raise BuildError("'tui' must be a non-empty mapping")
    return raw


def validate_key(key: Any, path: tuple[str, ...]) -> str:
    location = "/".join(path) or "tui"
    if not isinstance(key, str) or not KEY_PATTERN.fullmatch(key):
        raise BuildError(f"invalid key {key!r} below {location}")
    return key


def expand_platform_key(key: Any) -> tuple[str, ...] | None:
    if not isinstance(key, str):
        return None
    platforms = tuple(key.split("|"))
    if (
        not platforms
        or any(platform not in PLATFORMS for platform in platforms)
        or len(platforms) != len(set(platforms))
    ):
        return None
    return platforms


def parse_platform_config(
    tool_path: tuple[str, ...], platform: str, value: Any
) -> PlatformConfig:
    location = f"{'/'.join(tool_path)}:{platform}"
    if not isinstance(value, dict) or not value:
        raise BuildError(f"{location} must be a non-empty mapping")
    if any(not isinstance(field, str) for field in value):
        raise BuildError(f"{location} contains a non-string field")

    allowed_fields = {"source", "packages", "brew_type"}
    unknown_fields = set(value) - allowed_fields
    if unknown_fields:
        fields = ", ".join(sorted(unknown_fields))
        raise BuildError(f"{location} contains unsupported fields: {fields}")

    source = value.get("source")
    if not isinstance(source, str) or not source:
        raise BuildError(f"{location}.source must be apt, brew, or a script path")

    packages_value = value.get("packages", [tool_path[-1]])
    if not isinstance(packages_value, list) or not packages_value:
        raise BuildError(f"{location}.packages must be a non-empty list")
    if any(not isinstance(package, str) or not package for package in packages_value):
        raise BuildError(f"{location}.packages must contain non-empty strings")
    if len(packages_value) != len(set(packages_value)):
        raise BuildError(f"{location}.packages must not contain duplicates")
    packages = tuple(packages_value)

    script: Path | None = None
    brew_type = "formula"
    if source == "apt":
        if "brew_type" in value:
            raise BuildError(f"{location}: apt forbids brew_type")
    elif source == "brew":
        brew_type = value.get("brew_type", "formula")
        if brew_type not in ("formula", "cask"):
            raise BuildError(f"{location}.brew_type must be formula or cask")
    else:
        forbidden = set(value) & {"packages", "brew_type"}
        if forbidden:
            raise BuildError(f"{location}: custom forbids packages and brew_type")
        script_value = source
        if Path(script_value).is_absolute():
            raise BuildError(f"{location}.source must be relative to config.yaml")
        script = CONFIG_PATH.parent / script_value
        script = script.resolve()
        if not script.is_file() or not os.access(script, os.R_OK):
            raise BuildError(f"{location}.source is not a readable script: {script_value}")
        source = "custom"
        packages = ()

    return PlatformConfig(
        source=source,
        packages=packages,
        brew_type=brew_type,
        script=script,
    )


def parse_tool(path: tuple[str, ...], value: dict[str, Any]) -> Tool:
    if not path:
        raise BuildError("'tui' cannot be a tool")
    expanded: dict[str, PlatformConfig] = {}
    for platform_key, platform_value in value.items():
        targets = expand_platform_key(platform_key)
        if targets is None:
            raise BuildError(f"{'/'.join(path)} has an invalid platform key")
        for platform in targets:
            if platform in expanded:
                raise BuildError(
                    f"{'/'.join(path)} has conflicting configuration for {platform}"
                )
            expanded[platform] = parse_platform_config(path, platform, platform_value)
    return Tool(path=path, platforms=expanded)


def walk_config(
    value: Any, path: tuple[str, ...], tools: list[Tool]
) -> None:
    location = "/".join(path) or "tui"
    if not isinstance(value, dict):
        raise BuildError(f"{location} must be a mapping")
    if not value:
        raise BuildError(f"{location} must not be empty")

    platform_children = [expand_platform_key(key) is not None for key in value]
    if all(platform_children):
        tools.append(parse_tool(path, value))
        return
    if any(platform_children):
        raise BuildError(f"{location} mixes platform keys and category keys")

    for raw_key, child in value.items():
        key = validate_key(raw_key, path)
        walk_config(child, (*path, key), tools)


def parse_tools(config: dict[str, Any]) -> list[Tool]:
    tools: list[Tool] = []
    walk_config(config["tui"], (), tools)
    if not tools:
        raise BuildError("'tui' must contain at least one tool")
    return tools


def run_bash_syntax_check(path: Path) -> None:
    bash = shutil.which("bash")
    if bash is None:
        raise BuildError("bash is required to build hostinit.sh")
    result = subprocess.run(
        [bash, "-n", str(path)],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode != 0:
        detail = result.stderr.strip() or "syntax check failed"
        raise BuildError(f"{path}: {detail}")


def validate_custom_scripts(tools: list[Tool]) -> None:
    scripts = {
        config.script
        for tool in tools
        for config in tool.platforms.values()
        if config.script is not None
    }
    for script in sorted(scripts):
        run_bash_syntax_check(script)


def shell_quote(value: str) -> str:
    return shlex.quote(value)


def build_nodes(tools: list[Tool]) -> list[Node]:
    nodes: list[Node] = []
    node_indexes: dict[tuple[str, ...], int] = {}

    for tool_index, tool in enumerate(tools):
        for depth in range(1, len(tool.path)):
            path = tool.path[:depth]
            if path in node_indexes:
                continue
            parent_index = node_indexes.get(path[:-1], -1)
            node_indexes[path] = len(nodes)
            nodes.append(Node(path=path, parent_index=parent_index, tool_index=-1))

        parent_index = node_indexes.get(tool.path[:-1], -1)
        node_indexes[tool.path] = len(nodes)
        nodes.append(
            Node(
                path=tool.path,
                parent_index=parent_index,
                tool_index=tool_index,
            )
        )

    return nodes


def generate_tool_data(tools: list[Tool]) -> str:
    nodes = build_nodes(tools)
    lines = [f"TOOL_COUNT={len(tools)}", ""]
    for index, tool in enumerate(tools):
        lines.extend(
            (
                f"TOOL_IDS[{index}]={shell_quote(tool.stable_id)}",
                f"TOOL_NAMES[{index}]={shell_quote(tool.name)}",
                f"TOOL_LABELS[{index}]={shell_quote(tool.label)}",
            )
        )

    lines.extend(("", f"NODE_COUNT={len(nodes)}", ""))
    for index, node in enumerate(nodes):
        lines.extend(
            (
                f"NODE_IDS[{index}]={shell_quote(node.stable_id)}",
                f"NODE_LABELS[{index}]={shell_quote(node.label)}",
                f"NODE_DEPTHS[{index}]={len(node.path) - 1}",
                f"NODE_PARENTS[{index}]={node.parent_index}",
                f"NODE_TOOL_INDEXES[{index}]={node.tool_index}",
            )
        )

    lines.extend(("", "configure_tools() {", "    local index=0"))
    lines.extend(
        (
            "    while [ \"$index\" -lt \"$TOOL_COUNT\" ]; do",
            "        TOOL_ENABLED[$index]=0",
            "        TOOL_SOURCES[$index]=''",
            "        TOOL_BREW_TYPES[$index]=''",
            "        index=$((index + 1))",
            "    done",
            "",
            "    case \"$PLATFORM\" in",
        )
    )
    for platform in PLATFORMS:
        lines.append(f"        {platform})")
        for index, tool in enumerate(tools):
            config = tool.platforms.get(platform)
            if config is None:
                continue
            lines.extend(
                (
                    f"            TOOL_ENABLED[{index}]=1",
                    f"            TOOL_SOURCES[{index}]={shell_quote(config.source)}",
                    f"            TOOL_BREW_TYPES[{index}]={shell_quote(config.brew_type)}",
                )
            )
        lines.append("            ;;")
    lines.extend(("    esac", "}", ""))

    lines.extend(("append_tool_packages() {", "    case \"$PLATFORM:$1\" in"))
    for platform in PLATFORMS:
        for index, tool in enumerate(tools):
            config = tool.platforms.get(platform)
            if config is None or config.source == "custom":
                continue
            lines.append(f"        {platform}:{index})")
            for package in config.packages:
                lines.append(
                    "            BATCH_PACKAGES[${#BATCH_PACKAGES[@]}]="
                    + shell_quote(package)
                )
            lines.append("            ;;")
    lines.extend(("    esac", "}", ""))
    return "\n".join(lines)


def generate_custom_loaders(tools: list[Tool]) -> str:
    module_ids: dict[Path, int] = {}
    modules: list[Path] = []
    platform_modules: dict[str, list[int]] = {platform: [] for platform in PLATFORMS}
    for platform in PLATFORMS:
        for tool in tools:
            config = tool.platforms.get(platform)
            if config is None or config.script is None:
                continue
            if config.script not in module_ids:
                module_ids[config.script] = len(modules)
                modules.append(config.script)
            module_id = module_ids[config.script]
            if module_id not in platform_modules[platform]:
                platform_modules[platform].append(module_id)

    lines: list[str] = []
    for module_id, script in enumerate(modules):
        content = read_utf8(script).rstrip("\n")
        lines.extend((f"__load_custom_{module_id}() {{", content, "}", ""))

    lines.extend(("load_custom_modules() {", "    local status", "    case \"$PLATFORM\" in"))
    for platform in PLATFORMS:
        lines.append(f"        {platform})")
        if platform_modules[platform]:
            for module_id in platform_modules[platform]:
                lines.extend(
                    (
                        f"            __load_custom_{module_id}",
                        "            status=$?",
                        "            [ \"$status\" -eq 0 ] || exit \"$status\"",
                    )
                )
        else:
            lines.append("            :")
        lines.append("            ;;")
    lines.extend(("    esac", "}", ""))
    return "\n".join(lines)


def read_runtime() -> str:
    return "\n\n".join(read_utf8(path).rstrip("\n") for path in RUNTIME_PATHS)


def generate_script(tools: list[Tool]) -> str:
    sections = (
        "#!/usr/bin/env bash",
        "# Generated by build.sh. Do not edit this file directly.",
        generate_tool_data(tools).rstrip("\n"),
        generate_custom_loaders(tools).rstrip("\n"),
        read_runtime(),
    )
    return "\n\n".join(sections) + "\n"


def write_output(content: str) -> None:
    OUTPUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    temporary_name: str | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            dir=OUTPUT_PATH.parent,
            prefix=".hostinit.",
            suffix=".sh",
            delete=False,
        ) as temporary:
            temporary.write(content)
            temporary_name = temporary.name
        temporary_path = Path(temporary_name)
        temporary_path.chmod(0o755)
        run_bash_syntax_check(temporary_path)
        os.replace(temporary_path, OUTPUT_PATH)
    finally:
        if temporary_name is not None:
            Path(temporary_name).unlink(missing_ok=True)


def main() -> int:
    try:
        config = load_config(CONFIG_PATH)
        tools = parse_tools(config)
        validate_custom_scripts(tools)
        write_output(generate_script(tools))
    except BuildError as error:
        print(f"build error: {error}", file=sys.stderr)
        return 1
    print(OUTPUT_PATH)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
