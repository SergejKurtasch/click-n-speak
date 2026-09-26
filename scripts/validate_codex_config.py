from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path
from typing import Any, Sequence

import tomllib

SENSITIVE_KEY_PARTS = ("KEY", "TOKEN", "SECRET", "PASSWORD", "CREDENTIAL")
ENVIRONMENT_REFERENCE = re.compile(r"^\$(?:[A-Za-z_][A-Za-z0-9_]*|\{[A-Za-z_][A-Za-z0-9_]*\})$")
PINNED_NPM_PACKAGE = re.compile(
    r"^(?:@[A-Za-z0-9][A-Za-z0-9_.-]*/)?[A-Za-z0-9][A-Za-z0-9_.-]*@"
    r"\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$"
)
NPM_PACKAGE = re.compile(r"^(?:@[A-Za-z0-9][A-Za-z0-9_.-]*/)?[A-Za-z0-9][A-Za-z0-9_.-]*(?:@.+)?$")
NPM_OPTIONS_WITH_VALUES = (
    "--cache",
    "--call",
    "--loglevel",
    "--node-options",
    "--prefix",
    "--registry",
    "--shell",
    "--userconfig",
    "-c",
)
NPM_PACKAGE_OPTIONS = ("--package", "-p")


def validate_codex_config(path: Path) -> list[str]:
    """Return redacted credential and MCP pin hygiene diagnostics for a TOML config."""
    with path.open("rb") as config_file:
        config = tomllib.load(config_file)

    errors: list[str] = []
    _validate_credentials(config, (), errors)
    _validate_mcp_packages(config, errors)
    return errors


def _validate_credentials(value: Any, path: tuple[str, ...], errors: list[str]) -> None:
    if isinstance(value, dict):
        for key, nested_value in value.items():
            nested_path = (*path, key)
            if _is_sensitive_key(key) and _is_literal(nested_value):
                errors.append(f"{'.'.join(nested_path)} contains a literal credential")
            _validate_credentials(nested_value, nested_path, errors)
    elif isinstance(value, list):
        for index, nested_value in enumerate(value):
            _validate_credentials(nested_value, (*path, str(index)), errors)


def _validate_mcp_packages(config: dict[str, Any], errors: list[str]) -> None:
    servers = config.get("mcp_servers")
    if not isinstance(servers, dict):
        return

    for server_name, server in servers.items():
        if not isinstance(server, dict):
            continue
        arguments = server.get("args")
        if not isinstance(arguments, list):
            continue
        package_arguments = _npm_package_arguments(server.get("command"), arguments)
        if any(_is_unpinned_npm_package(argument) for argument in package_arguments):
            errors.append(f"mcp_servers.{server_name} uses an unpinned npm package")


def _is_sensitive_key(key: str) -> bool:
    uppercase_key = key.upper()
    return any(part in uppercase_key for part in SENSITIVE_KEY_PARTS)


def _is_literal(value: Any) -> bool:
    return not (isinstance(value, str) and ENVIRONMENT_REFERENCE.fullmatch(value))


def _npm_package_arguments(command: Any, arguments: list[Any]) -> list[Any]:
    if not isinstance(command, str):
        return []

    executable = Path(command).name
    if executable == "npx":
        return _executable_package_arguments(arguments)
    if executable == "npm" and arguments[:1] == ["exec"]:
        return _executable_package_arguments(arguments[1:])
    return []


def _executable_package_arguments(arguments: list[Any]) -> list[Any]:
    package_arguments: list[Any] = []
    expect_package_value = False
    parsing_options = True
    skip_next = False
    for argument in arguments:
        if expect_package_value:
            expect_package_value = False
            if isinstance(argument, str) and argument != "--":
                package_arguments.append(argument)
                continue
            if argument == "--":
                parsing_options = False
            continue
        if skip_next:
            skip_next = False
            continue
        if not isinstance(argument, str):
            continue
        if parsing_options and argument == "--":
            parsing_options = False
            continue
        if not parsing_options:
            return package_arguments or [argument]
        if argument in NPM_PACKAGE_OPTIONS:
            expect_package_value = True
            continue
        if argument in NPM_OPTIONS_WITH_VALUES:
            skip_next = True
            continue
        if _is_option_with_value(argument):
            continue
        package_option_value = _package_option_value(argument)
        if package_option_value is not None:
            package_arguments.append(package_option_value)
            continue
        if not argument.startswith("-"):
            return package_arguments or [argument]
    return package_arguments


def _is_option_with_value(argument: str) -> bool:
    return any(argument.startswith(f"{option}=") for option in NPM_OPTIONS_WITH_VALUES)


def _package_option_value(argument: str) -> str | None:
    for option in NPM_PACKAGE_OPTIONS:
        prefix = f"{option}="
        if argument.startswith(prefix):
            return argument.removeprefix(prefix)
    return None


def _is_unpinned_npm_package(argument: Any) -> bool:
    if not isinstance(argument, str) or argument.startswith("-"):
        return False
    return NPM_PACKAGE.fullmatch(argument) is not None and PINNED_NPM_PACKAGE.fullmatch(argument) is None


def main(argv: Sequence[str] | None = None) -> int:
    """Validate a Codex TOML configuration from the command line."""
    parser = argparse.ArgumentParser(description="Validate Codex credential hygiene and MCP dependency pins.")
    parser.add_argument("config", type=Path, help="Path to the Codex TOML configuration")
    arguments = parser.parse_args(argv)

    errors = validate_codex_config(arguments.config)
    for error in errors:
        print(error, file=sys.stderr)
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
