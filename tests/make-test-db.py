#!/usr/bin/env python3
"""Create a synthetic Chromium cookie database for exercising cleanup_db.py."""

import argparse
import base64
import datetime
import hashlib
import os
import random
import sqlite3

SCHEMA = """
CREATE TABLE meta(key LONGVARCHAR NOT NULL UNIQUE PRIMARY KEY, value LONGVARCHAR);
CREATE TABLE cookies(
  creation_utc INTEGER NOT NULL,
  host_key TEXT NOT NULL,
  top_frame_site_key TEXT NOT NULL,
  name TEXT NOT NULL,
  value TEXT NOT NULL,
  encrypted_value BLOB NOT NULL,
  path TEXT NOT NULL,
  expires_utc INTEGER NOT NULL,
  is_secure INTEGER NOT NULL,
  is_httponly INTEGER NOT NULL,
  last_access_utc INTEGER NOT NULL,
  has_expires INTEGER NOT NULL,
  is_persistent INTEGER NOT NULL,
  priority INTEGER NOT NULL,
  samesite INTEGER NOT NULL,
  source_scheme INTEGER NOT NULL,
  source_port INTEGER NOT NULL,
  last_update_utc INTEGER NOT NULL,
  source_type INTEGER NOT NULL,
  has_cross_site_ancestor INTEGER NOT NULL
);
CREATE UNIQUE INDEX cookies_unique_index ON cookies(
  host_key, top_frame_site_key, has_cross_site_ancestor, name, path, source_scheme, source_port
);
"""

EPOCH = datetime.datetime(1601, 1, 1, tzinfo=datetime.timezone.utc)


def to_chrome(dt):
    return int((dt - EPOCH).total_seconds() * 1_000_000)


def cookie_name(authority):
    digest = hashlib.sha256(authority.encode("utf-8")).digest()
    token = base64.urlsafe_b64encode(digest).decode("ascii").rstrip("=")
    return "dsh-auth-" + token


def auth_row(host, name, issued, expires, last_access):
    # Simulate a v10-encrypted 170-byte value: 3 + 12 + 139 + 16.
    blob = b"v10" + os.urandom(12) + os.urandom(139) + os.urandom(16)
    return (
        to_chrome(issued),
        host,
        "",
        name,
        "",
        blob,
        "/",
        to_chrome(expires),
        0,
        1,
        to_chrome(last_access),
        1,
        1,
        1,
        -1,
        1,
        -1,
        to_chrome(issued),
        0,
        0,
    )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", required=True)
    parser.add_argument("--auth", type=int, default=80)
    parser.add_argument("--other", type=int, default=4)
    parser.add_argument("--expired", type=int, default=0, help="make the first N auth cookies already expired")
    parser.add_argument("--foreign-auth", type=int, default=0, help="add N dsh-auth cookies for evil.example")
    args = parser.parse_args()

    if os.path.exists(args.out):
        os.remove(args.out)
    con = sqlite3.connect(args.out)
    con.executescript(SCHEMA)
    con.execute("INSERT INTO meta(key, value) VALUES('version', '24')")

    now = datetime.datetime.now(datetime.timezone.utc)
    rows = []
    for i in range(args.auth):
        port = 50000 + i
        authority = "127.0.0.1:%d" % port
        name = cookie_name(authority)
        issued = now - datetime.timedelta(hours=i * 7)
        expires = issued + datetime.timedelta(days=30)
        if i < args.expired:
            issued = now - datetime.timedelta(days=40 + i)
            expires = now - datetime.timedelta(days=10)
        rows.append(
            auth_row(
                "127.0.0.1",
                name,
                issued,
                expires,
                now - datetime.timedelta(minutes=i),
            )
        )
    for i in range(args.foreign_auth):
        name = cookie_name("evil.example:%d" % (51000 + i))
        issued = now - datetime.timedelta(hours=i)
        rows.append(
            auth_row(
                "evil.example",
                name,
                issued,
                issued + datetime.timedelta(days=30),
                now - datetime.timedelta(minutes=i),
            )
        )
    for i in range(args.other):
        rows.append(
            (
                to_chrome(now),
                "127.0.0.1",
                "",
                "unrelated-%d" % i,
                "plain-value-%d" % i,
                b"",
                "/",
                to_chrome(now + datetime.timedelta(days=1)),
                0,
                0,
                to_chrome(now),
                1,
                1,
                1,
                -1,
                1,
                -1,
                to_chrome(now),
                0,
                0,
            )
        )
    random.shuffle(rows)
    con.executemany(
        "INSERT INTO cookies VALUES (%s)" % ",".join("?" for _ in range(20)), rows
    )
    con.commit()
    print(args.out, "auth=%d foreign=%d other=%d total=%d" % (args.auth, args.foreign_auth, args.other, len(rows)))
    con.close()


if __name__ == "__main__":
    main()
