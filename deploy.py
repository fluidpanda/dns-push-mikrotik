#!/usr/bin/env python3.14
"""Deploy MikroTik RouterOS scripts from a local repo directory.

Each local file is uploaded via SFTP and then registered on the router
as a named /system script with a "master-" prefix, e.g. dns-sync.rsc
becomes the router script "master-dns-sync".

Usage:
    uv run deploy_scripts.py --host domain.com --user admin --repo-dir ./
"""

import argparse
import io
from pathlib import Path

import paramiko


def sanitize_name(stem: str) -> str:
    """RouterOS identifiers dislike spaces; keep names simple and predictable."""
    return stem.strip().replace(" ", "-")


def relative_key(path: Path, root: Path) -> str:
    """Flatten a path's location under root into one identifier-safe string,
    e.g. root/subdir/foo.rsc -> "subdir-foo", so files with the same name
    in different subdirectories don't collide once uploaded."""
    rel_parts = path.relative_to(root).with_suffix("").parts
    return sanitize_name("-".join(rel_parts))


def script_exists(ssh: paramiko.SSHClient, name: str) -> bool:
    cmd = f'/system script print count-only where name="{name}"'
    _, stdout, _ = ssh.exec_command(cmd)
    result = stdout.read().decode().strip()
    return result not in ("", "0")


def to_lf(raw: bytes) -> bytes:
    """Normalize line endings to LF"""
    return raw.replace(b"\r\n", b"\n").replace(b"\r", b"\n")


def deploy_one(
    ssh: paramiko.SSHClient,
    sftp: paramiko.SFTPClient,
    path: Path,
    repo_dir: Path,
    policy: str,
    keep_remote_file: bool,
) -> None:
    key = relative_key(path, repo_dir)
    script_name = f"master-{key}"
    remote_name = f"{key}{path.suffix}"

    print(f"-> {path.relative_to(repo_dir)}  =>  {script_name}")

    content = to_lf(path.read_bytes())
    sftp.putfo(io.BytesIO(content), remote_name)

    exists = script_exists(ssh, script_name)

    cmd: str = ""
    match exists:
        case True:
            cmd = (
                f'/system script set [find name="{script_name}"] '
                f'source=[:tocrlf [/file get [find name="{remote_name}"] contents]]'
            )
        case False:
            cmd = (
                f'/system script add name="{script_name}" '
                f"policy={policy} "
                f'source=[:tocrlf [/file get [find name="{remote_name}"] contents]]'
            )

    _, _, stderr = ssh.exec_command(cmd)
    err = stderr.read().decode().strip()

    match err:
        case "":
            print(f"   ok ({'updated' if exists else 'created'})")
        case _:
            print(f"   ! error: {err}")

    if not keep_remote_file:
        ssh.exec_command(f'/file remove "{remote_name}"')


def deploy(
    host: str,
    port: int,
    user: str,
    key_file: Path | None,
    key_passphrase: str | None,
    repo_dir: Path,
    ext: str,
    policy: str,
    keep_remote_file: bool,
) -> None:
    ssh = paramiko.SSHClient()
    ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())

    connect_kwargs: dict = dict(hostname=host, port=port, username=user)

    if key_file is not None:
        connect_kwargs["key_filename"] = str(key_file)
        if key_passphrase:
            connect_kwargs["passphrase"] = key_passphrase
    else:
        # fall back to ssh-agent and default keys (~/.ssh/id_ed25519, id_rsa, ...)
        connect_kwargs["look_for_keys"] = True
        connect_kwargs["allow_agent"] = True

    ssh.connect(**connect_kwargs)

    try:
        sftp = ssh.open_sftp()
        try:
            files = sorted(repo_dir.rglob(f"*{ext}"))
            if not files:
                print(f"No *{ext} files found in {repo_dir} (recursive)")
                return

            for path in files:
                deploy_one(ssh, sftp, path, repo_dir, policy, keep_remote_file)
        finally:
            sftp.close()
    finally:
        ssh.close()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", required=True)
    parser.add_argument("--port", type=int, default=22)
    parser.add_argument("--user", required=True)
    parser.add_argument(
        "--key-file",
        type=Path,
        default=None,
        help="path to private key, e.g. ~/.ssh/id_ed25519 "
        "(default: ssh-agent / default key locations)",
    )
    parser.add_argument(
        "--key-passphrase",
        default=None,
        help="passphrase for the private key, if it's encrypted",
    )
    parser.add_argument("--repo-dir", type=Path, default=Path("."))
    parser.add_argument("--ext", default=".rsc")
    parser.add_argument(
        "--policy",
        default="read,write,test",
        help="comma-separated policy list for newly created scripts",
    )
    parser.add_argument(
        "--keep-remote-file",
        action="store_true",
        help="do not delete the uploaded raw file on the router after import",
    )
    args = parser.parse_args()

    deploy(
        args.host,
        args.port,
        args.user,
        args.key_file,
        args.key_passphrase,
        args.repo_dir,
        args.ext,
        args.policy,
        args.keep_remote_file,
    )


if __name__ == "__main__":
    main()
