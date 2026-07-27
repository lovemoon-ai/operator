"""`pyoperator` command line: run the host-side services an app connects to."""

from __future__ import annotations

import argparse

from .services import retargeting as retargeting_service

SERVICES = {"retargeting": retargeting_service}


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="pyoperator", description="Operator host-side services"
    )
    subparsers = parser.add_subparsers(dest="command", required=True)
    serve = subparsers.add_parser("serve", help="serve one Operator service")
    serve.add_argument(
        "--service",
        choices=sorted(SERVICES),
        default="retargeting",
        help="which service to run (default: retargeting)",
    )
    retargeting_service.add_arguments(serve)
    return parser


def main(argv: list[str] | None = None) -> None:
    args = build_parser().parse_args(argv)
    service = SERVICES[args.service]
    service.serve(host=args.host, port=args.port, log_level=args.log_level)


if __name__ == "__main__":  # `python -m pyoperator.cli`
    main()
