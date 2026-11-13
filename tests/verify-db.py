#!/usr/bin/env python3
"""Print row counts and PRAGMA quick_check for one or more cookie databases."""

import sqlite3
import sys
from pathlib import Path

AUTH_HOST = "127.0.0.1"
AUTH_PREFIX = "dsh-auth-"


def verify(path):
    # Build a proper file: URI.  Raw interpolation would let "#", "?" or
    # "%XX" in the path change which file SQLite opens.
    uri = Path(path).resolve().as_uri() + "?mode=ro"
    con = sqlite3.connect(uri, uri=True)
    try:
        total = con.execute("select count(1) from cookies").fetchone()[0]
        auth = con.execute(
            "select count(1) from cookies "
            "where host_key = ? and substr(name, 1, ?) = ?",
            (AUTH_HOST, len(AUTH_PREFIX), AUTH_PREFIX),
        ).fetchone()[0]
        names = [
            row[0]
            for row in con.execute(
                "select name from cookies "
                "where not (host_key = ? and substr(name, 1, ?) = ?)",
                (AUTH_HOST, len(AUTH_PREFIX), AUTH_PREFIX),
            )
        ]
        quick = con.execute("pragma quick_check").fetchone()[0]
    finally:
        con.close()
    print(path)
    print("  total=%d auth=%d other=%s quick=%s" % (total, auth, names, quick))
    return quick == "ok"


def main(argv):
    ok = True
    for path in argv:
        try:
            ok = verify(path) and ok
        except sqlite3.Error as exc:
            print(path)
            print("  error=%s" % exc)
            ok = False
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
