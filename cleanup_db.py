#!/usr/bin/env python3
"""Delete stale dsh-auth-* browser-session cookies from a Chromium/Electron
cookie database.

The DSH Desktop shell mints one cookie per launch because each launch uses a
new loopback port and the cookie name is derived from the authority (host:port).
Each cookie lives for 30 days, and nothing deletes the old ones.  After roughly
72 launches the Cookie request header exceeds Node's 16 KiB header limit and
the host rejects the request (HTTP 431), which the shell surfaces as a startup
failure.

This tool only touches ``dsh-auth-`` rows for 127.0.0.1.  It never decrypts
values, never changes the schema, and leaves a consistent SQLite backup when
it deletes anything (unless --no-backup is passed explicitly).

It prints one JSON object on stdout so the PowerShell front-end can format the
result without depending on the console code page.
"""

from __future__ import annotations

import argparse
import datetime as _dt
import json
import os
import sqlite3
import sys

AUTH_PREFIX = "dsh-auth-"
# The DSH host is hard-coded to --host 127.0.0.1, so only that host's cookies
# are ours to delete.  Other sites' cookies live in the same Chromium DB.
AUTH_HOST = "127.0.0.1"
# node:http's default maxHeaderSize, which the DSH host inherits.
HEADER_LIMIT_BYTES = 16 * 1024
# Bytes outside the cookie pairs: the "Cookie: " prefix plus Host, User-Agent,
# Accept, Connection, and similar headers that share the same 16 KiB block.
# A rough constant is enough for a warning threshold.
HEADER_OVERHEAD_BYTES = 1024
# Chromium's Windows cookie encryption overhead (v10: 3-byte prefix,
# 12-byte nonce, 16-byte GCM tag).  v20 app-bound cookies carry a little more;
# the result is only an estimate used for the warning threshold.
ENCRYPTION_OVERHEAD = 31

_EPOCH = _dt.datetime(1601, 1, 1, tzinfo=_dt.timezone.utc)


def _chrome_time(value):
    try:
        micros = int(value or 0)
    except (TypeError, ValueError):
        return None
    if micros <= 0:
        return None
    try:
        return _EPOCH + _dt.timedelta(microseconds=micros)
    except OverflowError:
        return None


def _iso_local(value):
    if value is None:
        return None
    return value.astimezone().isoformat(timespec="seconds")


def _cookie_value_bytes(row):
    """Best-effort size of the value Chromium sends for this row."""
    plain = row["value"] or ""
    if plain:
        return len(plain.encode("utf-8"))
    return max(0, int(row["enc_len"] or 0) - ENCRYPTION_OVERHEAD)


def _header_bytes(rows):
    total = 0
    for row in rows:
        # "name=value; " — the final separator is a negligible overshoot.
        total += len((row["name"] or "").encode("utf-8")) + 1
        total += _cookie_value_bytes(row) + 2
    return total


def _fail(message, *, locked=False, code=1):
    print(json.dumps({"ok": False, "locked": locked, "error": message}, ensure_ascii=True))
    return code


def _is_lock_error(exc):
    """Chromium opens its cookie DB without sharing, so a read attempt while
    the app is running surfaces as "unable to open database file" rather than
    the usual SQLITE_BUSY text."""
    code = getattr(exc, "sqlite_errorcode", None)
    if code is not None:
        busy = getattr(sqlite3, "SQLITE_BUSY", None)
        locked = getattr(sqlite3, "SQLITE_LOCKED", None)
        if code in (busy, locked):
            return True
        ioerr = getattr(sqlite3, "SQLITE_IOERR", None)
        if ioerr is not None and (code & 0xFF) == ioerr:
            # A real I/O error (bad disk, corrupt file, etc.) must not be
            # reported as "the app is running"; surface it as a normal failure.
            return False
    text = str(exc).lower()
    # Match specific SQLite messages.  A bare "locked" would also match an
    # unrelated path.  "disk i/o error" is deliberately not a lock symptom:
    # the operator needs to investigate the disk/database, not the app.
    return (
        "database is locked" in text
        or "database table is locked" in text
        or "unable to open database file" in text
    )


def _open_readwrite(path):
    # isolation_level=None keeps our explicit transaction boundaries predictable;
    # Chromium stores cookies in a plain rollback-journal database.
    con = sqlite3.connect(path, timeout=6.0, isolation_level=None)
    con.row_factory = sqlite3.Row
    con.execute("PRAGMA busy_timeout = 6000")
    return con


def _open_readonly(path):
    # --verify must not attempt journal recovery or create side files; mode=ro
    # keeps a hot journal a hard error instead of "attempt to write a readonly
    # database" from an accidental read-write open.
    from pathlib import Path
    uri = Path(path).as_uri() + "?mode=ro"
    con = sqlite3.connect(uri, uri=True, timeout=6.0)
    con.row_factory = sqlite3.Row
    con.execute("PRAGMA busy_timeout = 6000")
    return con


def run(args):
    db = os.path.abspath(args.db)
    if not os.path.isfile(db):
        return _fail("cookie database not found: %s" % db, code=3)

    try:
        con = _open_readonly(db) if (args.verify or args.dry_run or args.report_only) else _open_readwrite(db)
    except sqlite3.OperationalError as exc:
        locked = _is_lock_error(exc)
        return _fail(str(exc), locked=locked, code=4 if locked else 1)
    except sqlite3.Error as exc:
        return _fail(str(exc))

    try:
        cur = con.cursor()
        exists = cur.execute(
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'cookies'"
        ).fetchone()
        if exists is None:
            return _fail("not a Chromium cookie database (no cookies table): %s" % db)

        if args.verify:
            # Read-only sanity check used after a restore and by the heartbeat.
            try:
                check = cur.execute("PRAGMA quick_check").fetchone()
                total = cur.execute("SELECT count(*) FROM cookies").fetchone()[0]
                auth = cur.execute(
                    "SELECT count(*) FROM cookies "
                    "WHERE host_key = ? AND substr(name, 1, ?) = ?",
                    (AUTH_HOST, len(AUTH_PREFIX), AUTH_PREFIX),
                ).fetchone()[0]
            except sqlite3.Error as exc:
                con.close()
                return _fail(str(exc))
            con.close()
            quick_check = str(check[0]) if check is not None else "unknown"
            print(json.dumps({
                "ok": quick_check == "ok",
                "db": db,
                "total": int(total),
                "auth": int(auth),
                "quick_check": quick_check,
            }, ensure_ascii=True))
            return 0 if quick_check == "ok" else 1

        cur.execute(
            "SELECT rowid, host_key, name, value, length(encrypted_value) AS enc_len, "
            "expires_utc, last_access_utc, creation_utc, path "
            "FROM cookies"
        )
        all_rows = cur.fetchall()
    except sqlite3.OperationalError as exc:
        con.close()
        locked = _is_lock_error(exc)
        return _fail(str(exc), locked=locked, code=4 if locked else 1)
    except sqlite3.Error as exc:
        con.close()
        return _fail(str(exc))

    auth_rows = [
        row
        for row in all_rows
        if row["host_key"] == AUTH_HOST
        and (row["name"] or "").startswith(AUTH_PREFIX)
    ]
    now = _dt.datetime.now(_dt.timezone.utc)
    expiries = [t for t in (_chrome_time(row["expires_utc"]) for row in auth_rows) if t is not None]
    expired = sum(1 for t in expiries if t <= now)

    # Only unexpired cookies are actually sent in the Cookie header.  Rows past
    # their expiry may still sit in the database until Chromium purges them, so
    # counting every row would overstate the header size and raise false alarms.
    active_rows = []
    for row in auth_rows:
        expires = _chrome_time(row["expires_utc"])
        if expires is None or expires > now:
            active_rows.append(row)
    header_bytes = _header_bytes(active_rows)

    keep_ids = set()
    if args.keep_latest > 0 and auth_rows:
        ordered = sorted(
            auth_rows,
            key=lambda row: (
                int(row["last_access_utc"] or 0),
                int(row["creation_utc"] or 0),
            ),
            reverse=True,
        )
        keep_ids = {row["rowid"] for row in ordered[: args.keep_latest]}

    to_delete = [row for row in auth_rows if row["rowid"] not in keep_ids]
    deleting = bool(to_delete) and not (args.dry_run or args.report_only)

    backup_path = None
    quick_check = None
    error = None

    if deleting:
        if not args.backup_dir and not args.no_backup:
            con.close()
            return _fail(
                "refusing to delete without --backup-dir; pass --no-backup to override"
            )
        try:
            if args.backup_dir:
                try:
                    os.makedirs(args.backup_dir, exist_ok=True)
                except OSError as exc:
                    con.close()
                    return _fail("cannot create backup directory %s: %s" % (args.backup_dir, exc))
                backup_path = os.path.join(args.backup_dir, "Cookies")
                if os.path.normcase(os.path.abspath(backup_path)) == os.path.normcase(db):
                    con.close()
                    return _fail("backup path is the database itself: %s" % backup_path)
                target = sqlite3.connect(backup_path)
                try:
                    con.backup(target)
                finally:
                    target.close()

            cur.execute("BEGIN IMMEDIATE")
            try:
                ids = [row["rowid"] for row in to_delete]
                for start in range(0, len(ids), 400):
                    chunk = ids[start : start + 400]
                    placeholders = ",".join("?" for _ in chunk)
                    cur.execute(
                        "DELETE FROM cookies WHERE rowid IN (%s)" % placeholders, chunk
                    )
                cur.execute("COMMIT")
            except BaseException:
                cur.execute("ROLLBACK")
                raise

            mode = cur.execute("PRAGMA journal_mode").fetchone()
            if mode is not None and str(mode[0]).lower() == "wal":
                try:
                    cur.execute("PRAGMA wal_checkpoint(TRUNCATE)")
                except sqlite3.Error:
                    pass

            if args.vacuum:
                cur.execute("VACUUM")

            check = cur.execute("PRAGMA quick_check").fetchone()
            quick_check = str(check[0]) if check is not None else None
        except sqlite3.OperationalError as exc:
            locked = _is_lock_error(exc)
            error = str(exc)
            if backup_path and os.path.isfile(backup_path) and locked:
                # The transaction never committed; the backup is still valid.
                pass
            con.close()
            return _fail(error, locked=locked, code=4 if locked else 1)
        except sqlite3.Error as exc:
            con.close()
            return _fail(str(exc))

    try:
        total_after = cur.execute("SELECT count(*) FROM cookies").fetchone()[0]
        auth_after = cur.execute(
            "SELECT count(*) FROM cookies "
            "WHERE host_key = ? AND substr(name, 1, ?) = ?",
            (AUTH_HOST, len(AUTH_PREFIX), AUTH_PREFIX),
        ).fetchone()[0]
        con.close()
    except sqlite3.Error:
        total_after = None
        auth_after = None

    result = {
        "ok": True,
        "db": db,
        "total": len(all_rows),
        "auth": len(auth_rows),
        "active": len(active_rows),
        "keep": len(keep_ids),
        "deleted": len(to_delete) if deleting else 0,
        "planned": len(to_delete),
        "remaining": auth_after if auth_after is not None else len(auth_rows) - len(to_delete),
        "total_after": total_after,
        "header_bytes": header_bytes,
        "header_overhead": HEADER_OVERHEAD_BYTES,
        "header_total": header_bytes + HEADER_OVERHEAD_BYTES,
        "header_limit": HEADER_LIMIT_BYTES,
        "expired": expired,
        "oldest_expires": _iso_local(min(expiries)) if expiries else None,
        "newest_expires": _iso_local(max(expiries)) if expiries else None,
        "backup": backup_path,
        "quick_check": quick_check,
        "dry_run": bool(args.dry_run or args.report_only),
        "report_only": bool(args.report_only),
    }
    print(json.dumps(result, ensure_ascii=True))
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", required=True, help="path to a Chromium Cookies database")
    parser.add_argument("--dry-run", action="store_true", help="report only, change nothing")
    parser.add_argument("--report-only", action="store_true", help="same as --dry-run")
    parser.add_argument("--keep-latest", type=int, default=0, help="keep the N most recently used dsh-auth cookies")
    parser.add_argument("--backup-dir", default=None, help="directory that receives a consistent Cookies backup")
    parser.add_argument("--no-backup", action="store_true", help="allow deleting without a backup (not recommended)")
    parser.add_argument("--vacuum", action="store_true", help="compact the database after deletion")
    parser.add_argument("--verify", action="store_true", help="only run quick_check and counts (for restore verification)")
    parser.add_argument("--json", action="store_true", help="emit one JSON object (always on; kept for the front-end)")
    args = parser.parse_args(argv)
    if args.keep_latest < 0:
        parser.error("--keep-latest must be >= 0")
    try:
        return run(args)
    except KeyboardInterrupt:
        return _fail("interrupted", code=1)
    except Exception as exc:
        return _fail("%s: %s" % (type(exc).__name__, exc), code=1)


if __name__ == "__main__":
    sys.exit(main())
