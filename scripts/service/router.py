#!/usr/bin/env python3
"""Run a router with bounded, compressed stdout and stderr, without restart rotation."""

import argparse
import fcntl
import gzip
import logging
from logging.handlers import RotatingFileHandler
import os
from pathlib import Path
import shutil
import signal
import subprocess


def compress(source, destination):
    # Retain the source if compression fails. Never truncate a live writer.
    temporary = destination + ".partial"
    with open(source, "rb") as incoming, gzip.open(temporary, "wb") as outgoing:
        shutil.copyfileobj(incoming, outgoing)
    os.replace(temporary, destination)
    os.unlink(source)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--log", required=True)
    parser.add_argument("--max-bytes", type=int, default=200 * 1024 * 1024)
    parser.add_argument("--backups", type=int, default=5)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command or args.max_bytes < 1024 or args.backups < 1:
        parser.error("a command, max-bytes >= 1024, and backups >= 1 are required")

    os.umask(0o077)
    log = Path(args.log)
    # A second supervisor must not rotate the first one's output.
    with open(str(log) + ".lock", "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        handler = RotatingFileHandler(log, maxBytes=args.max_bytes,
                                      backupCount=args.backups, encoding="utf-8")
        handler.namer = lambda name: name + ".gz"
        handler.rotator = compress
        env = dict(os.environ, NO_COLOR="1")
        child = subprocess.Popen(command, stdout=subprocess.PIPE,
                                 stderr=subprocess.STDOUT, text=True,
                                 encoding="utf-8", errors="replace", env=env)

        def stop(_signum, _frame):
            if child.poll() is None:
                child.terminate()

        signal.signal(signal.SIGTERM, stop)
        signal.signal(signal.SIGINT, stop)
        try:
            # Bounded reads also handle a child emitting a line without a newline.
            for text in iter(lambda: child.stdout.readline(65536), ""):
                record = logging.LogRecord("router", logging.INFO, "", 0, text, (), None)
                if handler.shouldRollover(record):
                    handler.doRollover()
                # Write directly so IO errors propagate instead of logging's
                # default handleError swallowing a failed log write.
                handler.stream.write(text)
                handler.flush()
            return child.wait()
        finally:
            if child.poll() is None:
                child.terminate()
                try:
                    child.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.wait()
            child.stdout.close()
            handler.close()


if __name__ == "__main__":
    raise SystemExit(main())
