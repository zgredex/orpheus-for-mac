#!/usr/bin/env python3
"""Frozen entrypoint used by OrpheusUI.app.

The Swift app owns UI and metadata preview. This helper only runs OrpheusDL
from the mutable runtime copy under Application Support.
"""

from __future__ import annotations

import argparse
import os
import runpy
import sys


def configure_portable_environment() -> None:
    os.environ.setdefault("OPENSSL_CONF", os.devnull)
    try:
        import certifi
    except Exception:
        return

    certificate_bundle = certifi.where()
    os.environ.setdefault("SSL_CERT_FILE", certificate_bundle)
    os.environ.setdefault("REQUESTS_CA_BUNDLE", certificate_bundle)


def main() -> int:
    configure_portable_environment()

    parser = argparse.ArgumentParser(description="Run bundled OrpheusDL")
    parser.add_argument("--project", required=True, help="Mutable OrpheusDL runtime path")
    parser.add_argument("--output", required=True, help="Download output path")
    parser.add_argument("arguments", nargs=argparse.REMAINDER)
    args = parser.parse_args()

    cli_arguments = list(args.arguments)
    if cli_arguments and cli_arguments[0] == "--":
        cli_arguments = cli_arguments[1:]

    project = os.path.abspath(args.project)
    entrypoint = os.path.join(project, "orpheus.py")
    if not os.path.exists(entrypoint):
        raise SystemExit(f"Missing OrpheusDL entrypoint: {entrypoint}")

    os.makedirs(args.output, exist_ok=True)
    os.chdir(project)
    sys.path.insert(0, project)
    sys.argv = [entrypoint, "-o", args.output, *cli_arguments]
    runpy.run_path(entrypoint, run_name="__main__")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
