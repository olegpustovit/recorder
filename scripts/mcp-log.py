#!/usr/bin/env python3
"""Usage: mcp-log.py <out.jsonl> -- <command> [args ...]"""

import os
import subprocess
import sys
import threading


def main():
    if len(sys.argv) < 4 or sys.argv[2] != "--":
        sys.exit(__doc__)
    lock = threading.Lock()
    with open(sys.argv[1], "ab", opener=lambda path, flags: os.open(path, flags, 0o600)) as log:
        with subprocess.Popen(sys.argv[3:], stdin=subprocess.PIPE, stdout=subprocess.PIPE) as child:
            def forward(data, destination):
                with lock:
                    if log.closed:
                        return
                    log.write(data)
                    log.flush()
                destination.write(data)
                destination.flush()

            def requests():
                try:
                    with child.stdin:
                        pending = bytearray()
                        while chunk := os.read(sys.stdin.fileno(), 65536):
                            pending.extend(chunk)
                            end = pending.rfind(b"\n") + 1
                            if end:
                                forward(pending[:end], child.stdin)
                                del pending[:end]
                        if pending:
                            forward(pending, child.stdin)
                except BrokenPipeError:
                    pass

            reader = threading.Thread(target=requests, daemon=True)
            reader.start()
            try:
                for line in child.stdout:
                    forward(line, sys.stdout.buffer)
                return child.wait()
            except (OSError, KeyboardInterrupt):
                child.terminate()
                raise
            finally:
                with lock:
                    log.close()


if __name__ == "__main__":
    sys.exit(main())
