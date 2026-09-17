#!/usr/bin/env python3
"""Dispatch real-model benchmarks. Scripted references are not XR coverage."""
import argparse
import sys


def main():
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--controller", choices=("scalebfm", "sonic"), required=True)
    args, remaining = parser.parse_known_args()
    if args.controller == "scalebfm":
        from wbc.controllers.scalebfm.benchmark import main as benchmark
    else:
        from wbc.controllers.sonic.benchmark import main as benchmark
    sys.argv = [sys.argv[0], *remaining]
    benchmark()


if __name__ == "__main__":
    main()
