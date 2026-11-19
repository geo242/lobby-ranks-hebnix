"""Run the Lobby Ranks plugin against a mocked Hebnix host in Lua 5.4.

Hebnix embeds Lua 5.4 (mlua), and lupa ships the same version, so no system Lua is needed.

    python -m pip install lupa
    python tests/run_tests.py
"""

import sys
from pathlib import Path

from lupa import lua54

ROOT = Path(__file__).resolve().parent.parent


def main() -> int:
    lua = lua54.LuaRuntime()
    lua.globals().arg_path = str(ROOT / "lobby_ranks" / "main.lua")
    harness = (ROOT / "tests" / "harness.lua").read_text(encoding="utf-8")
    try:
        lua.execute(harness)
    except Exception as error:  # Lua errors surface as LuaError
        print(f"FAILED: {error}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
