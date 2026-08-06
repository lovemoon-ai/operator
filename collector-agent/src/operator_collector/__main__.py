from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.parse

from . import __version__
from .agent import CollectorAgent
from .config import config_path, load_config, save_config


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(prog="operator-collector")
    root.add_argument("--version", action="version", version=f"%(prog)s {__version__}")
    root.add_argument("--server", help="Operator server URL")
    commands = root.add_subparsers(dest="command")
    run = commands.add_parser("run", help="Run the background collector agent")
    run.add_argument("--no-browser", action="store_true", help="Print enrollment URL without opening it")
    commands.add_parser("status", help="Show local configuration and device state")
    configure = commands.add_parser("configure", help="Set the Station URL before pairing")
    configure.add_argument("server_url", help="For example http://10.10.99.89:6153")
    commands.add_parser("reset", help="Forget this workstation pairing")
    commands.add_parser("config-path", help="Print the local config path")
    return root


def main() -> None:
    args = parser().parse_args()
    command = args.command or "run"
    if command == "config-path":
        print(config_path())
        return
    if command == "configure":
        server_url = args.server_url.rstrip("/")
        parsed = urllib.parse.urlparse(server_url)
        if parsed.scheme not in {"http", "https"} or not parsed.netloc:
            raise SystemExit("Station URL must start with http:// or https://")
        local = load_config()
        if local.get("server_url") != server_url:
            for key in ("agent_id", "token", "remote_config"):
                local.pop(key, None)
        local["server_url"] = server_url
        save_config(local)
        print(f"Station URL saved: {server_url}")
        print("Restart Operator Collector; its browser pairing page will open automatically.")
        return
    agent = CollectorAgent(args.server, open_browser=not getattr(args, "no_browser", False))
    if command == "run":
        agent.run_forever()
    elif command == "status":
        print(json.dumps(agent.status(), ensure_ascii=False, indent=2))
    elif command == "reset":
        if sys.stdin.isatty():
            answer = input("Forget this workstation pairing? Type RESET: ")
            if answer != "RESET":
                print("Cancelled.")
                return
        elif os.environ.get("OPERATOR_COLLECTOR_FORCE_RESET") != "1":
            raise SystemExit("Set OPERATOR_COLLECTOR_FORCE_RESET=1 for non-interactive reset")
        agent.reset()
        print("Pairing reset.")


if __name__ == "__main__":
    main()
