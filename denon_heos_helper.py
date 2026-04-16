#!/usr/bin/env python3
"""Small HEOS CLI helper used by denon_release_candidate.sh."""

from __future__ import annotations

import json
import os
import socket
import sys
from typing import Any
from urllib.parse import quote


TIMEOUT = float(os.environ.get("DENON_HEOS_TIMEOUT", "1.5"))


def usage() -> int:
    print(
        """Usage: denon heos <command> [arguments]

Commands:
  now
  play | pause | stop | next | prev
  queue [play <item>|remove <item>|move <from> <to>|clear|save <name>]
  groups
  group info [gid]
  group set <pid,pid,...>
  group volume [gid] <level>
  group mute [gid] <on|off>
  browse sources
  browse <sid> [cid]
  search <sid|source-name> <query> [criteria]
  play-stream <sid> <cid> <mid> [name]
  repeat <off|all|one>
  shuffle <on|off>
  update
""".rstrip(),
        file=sys.stderr,
    )
    return 1


def send(ip: str, path: str) -> dict[str, Any]:
    command = f"heos://{path}\r\n".encode()
    chunks: list[bytes] = []
    with socket.create_connection((ip, 1255), timeout=TIMEOUT) as sock:
        sock.settimeout(TIMEOUT)
        sock.sendall(command)
        while True:
            try:
                chunk = sock.recv(65536)
            except socket.timeout:
                break
            if not chunk:
                break
            chunks.append(chunk)

    text = b"".join(chunks).decode("utf-8", "replace").strip()
    if not text:
        raise RuntimeError("no HEOS response")

    last_error: Exception | None = None
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            return json.loads(line)
        except json.JSONDecodeError as exc:
            last_error = exc
    raise RuntimeError(f"invalid HEOS JSON: {last_error or text}")


def heos_ok(data: dict[str, Any]) -> bool:
    return data.get("heos", {}).get("result") == "success"


def message_value(data: dict[str, Any], key: str) -> str:
    message = data.get("heos", {}).get("message", "")
    for part in str(message).split("&"):
        if "=" not in part:
            continue
        k, v = part.split("=", 1)
        if k.strip() == key:
            return v.strip().strip("'\"")
    return ""


def require_ok(data: dict[str, Any]) -> None:
    if heos_ok(data):
        return
    heos = data.get("heos", {})
    message = heos.get("message") or "unsupported or failed HEOS command"
    raise RuntimeError(f"{heos.get('command', 'HEOS command')}: {message}")


def get_pid(ip: str) -> str:
    env_pid = os.environ.get("DENON_HEOS_PID", "").strip()
    if env_pid:
        return env_pid
    data = send(ip, "player/get_players")
    require_ok(data)
    players = data.get("payload") or []
    if not players:
        raise RuntimeError("no HEOS players returned")
    return str(players[0].get("pid", "")).strip()


def get_gid(ip: str) -> str:
    env_gid = os.environ.get("DENON_HEOS_GID", "").strip()
    if env_gid:
        return env_gid
    data = send(ip, "group/get_groups")
    require_ok(data)
    groups = data.get("payload") or []
    if not groups:
        raise RuntimeError("no HEOS groups returned; create one with: denon heos group set <pid,pid,...>")
    return str(groups[0].get("gid", "")).strip()


def resolve_source(ip: str, query: str) -> str:
    if query.isdigit():
        return query
    data = send(ip, "browse/get_music_sources")
    require_ok(data)
    wanted = "".join(ch for ch in query.lower() if ch.isalnum())
    for source in data.get("payload") or []:
        sid = str(source.get("sid", ""))
        name = str(source.get("name", ""))
        norm = "".join(ch for ch in name.lower() if ch.isalnum())
        if wanted == norm or wanted in norm:
            return sid
    raise RuntimeError(f"unknown HEOS source: {query}")


def queue_items(ip: str, pid: str) -> list[dict[str, Any]]:
    data = send(ip, f"player/get_queue?pid={quote(pid)}&range=0,99")
    require_ok(data)
    return data.get("payload") or []


def qid_for(ip: str, pid: str, value: str) -> str:
    if not value.isdigit():
        return value
    items = queue_items(ip, pid)
    index = int(value)
    if 1 <= index <= len(items):
        qid = items[index - 1].get("qid")
        if qid is not None:
            return str(qid)
    return value


def print_json(data: Any) -> None:
    print(json.dumps(data, ensure_ascii=False, indent=2))


def show_sources(data: dict[str, Any]) -> None:
    require_ok(data)
    for source in data.get("payload") or []:
        sid = source.get("sid", "")
        name = source.get("name", "Unknown")
        typ = source.get("type", "")
        available = source.get("available", "")
        suffix = f" [{typ}]" if typ else ""
        if str(available).lower() == "false":
            suffix += " unavailable"
        print(f"{sid:>5}  {name}{suffix}")


def show_queue(items: list[dict[str, Any]]) -> None:
    if not items:
        print("Queue is empty")
        return
    for idx, item in enumerate(items, 1):
        title = item.get("song") or item.get("name") or "Unknown"
        artist = item.get("artist") or ""
        qid = item.get("qid", "")
        extra = f" - {artist}" if artist else ""
        print(f"{idx:>3}. qid {qid}: {title}{extra}")


def show_now(ip: str, pid: str) -> None:
    media = send(ip, f"player/get_now_playing_media?pid={quote(pid)}")
    require_ok(media)
    state = send(ip, f"player/get_play_state?pid={quote(pid)}")
    payload = media.get("payload") or {}
    print(f"State: {message_value(state, 'state') or 'unknown'}")
    print(f"Type: {payload.get('type', 'Unknown')}")
    print(f"Title: {payload.get('song') or payload.get('station') or payload.get('name') or 'Unknown'}")
    print(f"Artist: {payload.get('artist', 'Unknown')}")
    print(f"Album: {payload.get('album', 'Unknown')}")
    if payload.get("sid") is not None:
        print(f"Source ID: {payload.get('sid')}")
    if payload.get("qid") is not None:
        print(f"Queue ID: {payload.get('qid')}")


def show_groups(data: dict[str, Any]) -> None:
    require_ok(data)
    groups = data.get("payload") or []
    if not groups:
        print("No HEOS groups")
        return
    for group in groups:
        gid = group.get("gid", "")
        print(f"Group {gid}: {group.get('name', 'Unknown')}")
        for player in group.get("players") or []:
            print(f"  {player.get('pid', ''):>5}  {player.get('role', ''):<6} {player.get('name', 'Unknown')}")


def show_browse(data: dict[str, Any]) -> None:
    require_ok(data)
    payload = data.get("payload") or []
    if isinstance(payload, dict):
        print_json(payload)
        return
    if not payload:
        print("No items returned")
        return
    for idx, item in enumerate(payload, 1):
        ident = item.get("sid") or item.get("cid") or item.get("mid") or ""
        flags = []
        if item.get("container"):
            flags.append(f"container={item.get('container')}")
        if item.get("playable"):
            flags.append(f"playable={item.get('playable')}")
        if item.get("type"):
            flags.append(str(item.get("type")))
        artist = f" - {item.get('artist')}" if item.get("artist") else ""
        flag_text = f" [{' '.join(flags)}]" if flags else ""
        print(f"{idx:>3}. {ident}  {item.get('name', 'Unknown')}{artist}{flag_text}")


def set_play_mode(ip: str, pid: str, repeat: str | None = None, shuffle: str | None = None) -> None:
    current = send(ip, f"player/get_play_mode?pid={quote(pid)}")
    require_ok(current)
    cur_repeat = message_value(current, "repeat") or "off"
    cur_shuffle = message_value(current, "shuffle") or "off"
    if repeat is None:
        repeat = cur_repeat
    if shuffle is None:
        shuffle = cur_shuffle
    data = send(ip, f"player/set_play_mode?pid={quote(pid)}&repeat={quote(repeat)}&shuffle={quote(shuffle)}")
    require_ok(data)
    print(f"HEOS play mode: repeat={repeat} shuffle={shuffle}")


def run(ip: str, argv: list[str]) -> int:
    if not argv:
        return usage()
    cmd = argv[0].lower()
    pid = get_pid(ip)

    if cmd == "now":
        show_now(ip, pid)
    elif cmd in {"play", "pause", "stop"}:
        data = send(ip, f"player/set_play_state?pid={quote(pid)}&state={cmd}")
        require_ok(data)
        print(f"HEOS {cmd}")
    elif cmd in {"next", "prev", "previous"}:
        action = "play_next" if cmd == "next" else "play_previous"
        data = send(ip, f"player/{action}?pid={quote(pid)}")
        require_ok(data)
        print(f"HEOS {cmd}")
    elif cmd == "queue":
        sub = argv[1].lower() if len(argv) > 1 else ""
        if not sub:
            show_queue(queue_items(ip, pid))
        elif sub == "play" and len(argv) == 3:
            qid = qid_for(ip, pid, argv[2])
            data = send(ip, f"player/play_queue?pid={quote(pid)}&qid={quote(qid)}")
            require_ok(data)
            print(f"Playing queue item {argv[2]} (qid {qid})")
        elif sub == "remove" and len(argv) == 3:
            qid = qid_for(ip, pid, argv[2])
            data = send(ip, f"player/remove_from_queue?pid={quote(pid)}&qid={quote(qid)}")
            require_ok(data)
            print(f"Removed queue item {argv[2]} (qid {qid})")
        elif sub == "move" and len(argv) == 4:
            sqid = qid_for(ip, pid, argv[2])
            dqid = qid_for(ip, pid, argv[3])
            data = send(ip, f"player/move_queue_item?pid={quote(pid)}&sqid={quote(sqid)}&dqid={quote(dqid)}")
            require_ok(data)
            print(f"Moved queue item {argv[2]} to {argv[3]}")
        elif sub == "clear" and len(argv) == 2:
            data = send(ip, f"player/clear_queue?pid={quote(pid)}")
            require_ok(data)
            print("Queue cleared")
        elif sub == "save" and len(argv) >= 3:
            name = " ".join(argv[2:])
            data = send(ip, f"player/save_queue?pid={quote(pid)}&name={quote(name)}")
            require_ok(data)
            print(f"Queue saved as playlist: {name}")
        else:
            return usage()
    elif cmd == "groups":
        show_groups(send(ip, "group/get_groups"))
    elif cmd == "group":
        sub = argv[1].lower() if len(argv) > 1 else ""
        if sub == "info":
            gid = argv[2] if len(argv) > 2 else get_gid(ip)
            data = send(ip, f"group/get_group_info?gid={quote(gid)}")
            require_ok(data)
            print_json(data)
        elif sub == "set" and len(argv) == 3:
            data = send(ip, f"group/set_group?pid={quote(argv[2], safe=',')}")
            require_ok(data)
            print(f"HEOS group set: {argv[2]}")
        elif sub == "volume" and len(argv) in {3, 4}:
            gid = argv[2] if len(argv) == 4 else get_gid(ip)
            level = argv[3] if len(argv) == 4 else argv[2]
            data = send(ip, f"group/set_volume?gid={quote(gid)}&level={quote(level)}")
            require_ok(data)
            print(f"Group {gid} volume set to {level}")
        elif sub == "mute" and len(argv) in {3, 4}:
            gid = argv[2] if len(argv) == 4 else get_gid(ip)
            state = argv[3].lower() if len(argv) == 4 else argv[2].lower()
            if state not in {"on", "off"}:
                return usage()
            data = send(ip, f"group/set_mute?gid={quote(gid)}&state={state}")
            require_ok(data)
            print(f"Group {gid} mute {state}")
        else:
            return usage()
    elif cmd == "browse":
        if len(argv) == 2 and argv[1].lower() == "sources":
            show_sources(send(ip, "browse/get_music_sources"))
        elif len(argv) in {2, 3}:
            sid = resolve_source(ip, argv[1])
            path = f"browse/browse?sid={quote(sid)}"
            if len(argv) == 3:
                path += f"&cid={quote(argv[2])}"
            show_browse(send(ip, path))
        else:
            return usage()
    elif cmd == "search" and len(argv) >= 3:
        sid = resolve_source(ip, argv[1])
        query = argv[2]
        scid = argv[3] if len(argv) > 3 else "1"
        path = f"browse/search?sid={quote(sid)}&search={quote(query)}&scid={quote(scid)}&range=0,49"
        show_browse(send(ip, path))
    elif cmd == "play-stream" and len(argv) >= 4:
        sid, cid, mid = argv[1], argv[2], argv[3]
        path = f"browse/play_stream?pid={quote(pid)}&sid={quote(sid)}&cid={quote(cid)}&mid={quote(mid)}"
        if len(argv) > 4:
            path += f"&name={quote(' '.join(argv[4:]))}"
        data = send(ip, path)
        require_ok(data)
        print("HEOS stream requested")
    elif cmd == "repeat" and len(argv) == 2:
        repeat_map = {"off": "off", "all": "on_all", "one": "on_one"}
        if argv[1].lower() not in repeat_map:
            return usage()
        set_play_mode(ip, pid, repeat=repeat_map[argv[1].lower()])
    elif cmd == "shuffle" and len(argv) == 2:
        state = argv[1].lower()
        if state not in {"on", "off"}:
            return usage()
        set_play_mode(ip, pid, shuffle=state)
    elif cmd == "update":
        print_json(send(ip, f"player/check_update?pid={quote(pid)}"))
    else:
        return usage()
    return 0


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        return usage()
    ip = argv[0]
    try:
        return run(ip, argv[1:])
    except (OSError, RuntimeError, ValueError) as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
