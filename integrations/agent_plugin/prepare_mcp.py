"""Print a personal MCP configuration using explicit, nonsecret directory paths."""

from __future__ import annotations

import argparse
import json
from pathlib import Path


ROOT = Path(__file__).resolve().parent
PATH_FIELDS = {
    "home": ("HOME", "USERPROFILE"),
    "app_data": ("APPDATA",),
    "local_app_data": ("LOCALAPPDATA",),
    "xdg_config_home": ("XDG_CONFIG_HOME",),
    "xdg_data_home": ("XDG_DATA_HOME",),
}


def directory_value(value: str | Path) -> str:
    path = Path(value)
    if not path.is_absolute():
        raise ValueError("Directory paths must be absolute")
    path = path.resolve()
    if any(ord(char) < 32 for char in str(path)) or "${" in str(path):
        raise ValueError("Directory paths cannot contain controls or placeholders")
    if not path.is_dir():
        raise ValueError("Directory paths must name existing directories")
    return str(path)


def prepare_mcp(*, home: str | Path, **paths: str | Path | None) -> dict:
    unknown = paths.keys() - PATH_FIELDS.keys()
    if unknown:
        raise ValueError("Only documented nonsecret directory fields are accepted")
    supplied = {"home": home, **paths}
    environment = {}
    for field, value in supplied.items():
        if value is not None:
            validated = directory_value(value)
            for name in PATH_FIELDS[field]:
                environment[name] = validated
    template = (ROOT / "mcp.json").resolve()
    if not template.is_relative_to(ROOT):
        raise ValueError("MCP template must remain inside the plugin package")
    config = json.loads(template.read_text(encoding="utf-8"))
    config["mcpServers"]["quotabot"]["env"] = environment
    return config


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--home", required=True, type=Path)
    for field in PATH_FIELDS:
        if field != "home":
            parser.add_argument("--" + field.replace("_", "-"), type=Path)
    args = parser.parse_args(argv)
    try:
        result = prepare_mcp(**vars(args))
    except (OSError, ValueError) as error:
        parser.error(str(error))
    print(json.dumps(result, indent=2, ensure_ascii=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
