#!/usr/bin/env python3
"""OpenSpec change observer.

Watches terminal output of all Herdr panes for OpenSpec signals and reports
os_change/os_phase tokens per pane, independent of the agent running in the
pane. Runs as a detached daemon behind observer.sh; reconnects with backoff
when the socket goes away.

Herdr 0.9.0 socket semantics: every request/response is one-shot (the server
closes the connection after responding); `events.subscribe` keeps its
connection open and streams events. So the observer uses fresh connections
for requests and one long-lived subscription connection that is re-issued
when the pane set changes.

Usage:
  observer.py              connect and watch (daemon)
  observer.py --test       run the detection rule unit tests
"""

import argparse
import json
import os
import re
import socket
import sys
import tempfile
import time

SOURCE = "openspec"
MAX_LABEL_LEN = 40
RECONNECT_BASE = 1.0
RECONNECT_MAX = 30.0
REQUEST_TIMEOUT = 10.0
RECONCILE_INTERVAL = float(
    os.environ.get("OBSERVER_RECONCILE_INTERVAL", "30")
)

# Detection rules (design D3). The opsx forms cover Claude (/opsx:apply),
# OpenCode (/opsx-apply) and Cursor-style tools; the skill forms cover
# Codex ($openspec-apply-change) and other skills-only agents.
RE_OPSX = re.compile(
    r"(?:^|\s)/?(?:prompts:)?opsx[:-](explore|propose|apply)\b"
    r"(?:\s+([A-Za-z0-9][A-Za-z0-9._-]*))?"
)
RE_SKILL = re.compile(
    r"(?:^|\s)[$@/]?openspec-(explore|propose|apply)(?:-change)?\b"
    r"(?:\s+([A-Za-z0-9][A-Za-z0-9._-]*))?"
)
RE_INSTRUCTIONS_APPLY = re.compile(
    r"openspec\s+instructions\s+apply\s+--change\s+[" + "'" + r"]?"
    r"([A-Za-z0-9._-]+)"
)
RE_NEW_CHANGE = re.compile(
    r"openspec\s+new\s+change\s+[" + "'" + r"]?([A-Za-z0-9._-]+)"
)

# Subscription filter for pane.output_matched. Herdr fires an event only when
# the match state of the pane changes, so the pattern must not match text
# that is always on screen: a bare `openspec` alternative would match the
# shell prompt of every pane whose cwd contains openspec-herdr and suppress
# all events. Phrase alternatives never appear in prompts.
OUTPUT_MATCH_REGEX = (
    r"opsx|openspec instructions apply|openspec new change"
    r"|openspec-apply|openspec-explore|openspec-propose"
)


def find_repo_root(cwd):
    """Walks up from cwd to a directory containing openspec/changes."""
    path = os.path.abspath(cwd or os.curdir)
    while True:
        if os.path.isdir(os.path.join(path, "openspec", "changes")):
            return path
        parent = os.path.dirname(path)
        if parent == path:
            return None
        path = parent


def valid_change(name, cwd):
    """The argument only counts as a change when its directory exists."""
    if not name:
        return None
    root = find_repo_root(cwd)
    if not root:
        return None
    if os.path.isdir(os.path.join(root, "openspec", "changes", name)):
        return name
    return None


def detect(line, cwd):
    """Returns (phase, change) from the last signal in a line, or None.
    phase/change are None when the signal did not carry them."""
    candidates = []
    for match in RE_OPSX.finditer(line):
        command = match.group(1)
        name = valid_change(match.group(2), cwd)
        if command in ("explore", "propose"):
            candidates.append((match.start(), "explore", name))
        else:
            candidates.append((match.start(), "apply", name))
    for match in RE_SKILL.finditer(line):
        command = match.group(1)
        name = valid_change(match.group(2), cwd)
        if command in ("explore", "propose"):
            candidates.append((match.start(), "explore", name))
        else:
            candidates.append((match.start(), "apply", name))
    for match in RE_INSTRUCTIONS_APPLY.finditer(line):
        candidates.append(
            (match.start(), "apply", valid_change(match.group(1), cwd))
        )
    for match in RE_NEW_CHANGE.finditer(line):
        candidates.append(
            (match.start(), None, valid_change(match.group(1), cwd))
        )
    if not candidates:
        return None
    candidates.sort()
    _, phase, change = candidates[-1]
    return (phase, change)


def is_shell_prompt(title):
    """Shell prompt titles (user@host: dir) are not session titles."""
    if not title:
        return True
    return "@" in title and ":" in title


class RequestClient:
    """One-shot request/response client; one fresh connection per call."""

    def __init__(self, socket_path, log=None):
        self.socket_path = socket_path
        self.log = log or (lambda msg: None)
        self.next_id = 0

    def call(self, method, params):
        """Returns the result payload, None on error, raises on transport
        loss. pane_not_found returns None as well."""
        self.next_id += 1
        request_id = "%s:%d" % (SOURCE, self.next_id)
        payload = json.dumps(
            {"id": request_id, "method": method, "params": params}
        ) + "\n"
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            sock.connect(self.socket_path)
            sock.settimeout(REQUEST_TIMEOUT)
            sock.sendall(payload.encode("utf-8"))
            buffer = b""
            while b"\n" not in buffer:
                chunk = sock.recv(65536)
                if not chunk:
                    raise ConnectionError("connection closed")
                buffer += chunk
            line, _ = buffer.split(b"\n", 1)
            try:
                message = json.loads(line.decode("utf-8"))
            except (ValueError, UnicodeDecodeError):
                return None
            if message.get("id") != request_id:
                return None
            if "error" in message:
                self.log("error %s: %s" % (method, message["error"]))
                return None
            return message.get("result")
        finally:
            sock.close()


class SubscriptionClient:
    """Long-lived subscription connection for pane events."""

    def __init__(self, socket_path, log=None):
        self.socket_path = socket_path
        self.log = log or (lambda msg: None)
        self.sock = None
        self.buffer = b""
        self.next_id = 0

    def connect(self):
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.connect(self.socket_path)
        sock.settimeout(0.25)
        self.sock = sock
        self.buffer = b""
        self.log("subscribed via %s" % self.socket_path)

    def close(self):
        if self.sock:
            try:
                self.sock.close()
            except OSError:
                pass
        self.sock = None
        self.buffer = b""

    def subscribe(self, subscriptions):
        self.next_id += 1
        request_id = "%s:sub:%d" % (SOURCE, self.next_id)
        payload = json.dumps(
            {
                "id": request_id,
                "method": "events.subscribe",
                "params": {"subscriptions": subscriptions},
            }
        ) + "\n"
        self.sock.sendall(payload.encode("utf-8"))
        deadline = time.time() + REQUEST_TIMEOUT
        while time.time() < deadline:
            message = self.recv_message()
            if message is None:
                continue
            if message.get("id") == request_id:
                return "error" not in message
        return False

    def recv_message(self):
        while b"\n" not in self.buffer:
            try:
                chunk = self.sock.recv(65536)
            except socket.timeout:
                return None
            if not chunk:
                raise ConnectionError("subscription closed")
            self.buffer += chunk
        line, self.buffer = self.buffer.split(b"\n", 1)
        try:
            return json.loads(line.decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            return None

    def wait_event(self, timeout):
        deadline = time.time() + timeout
        while time.time() < deadline:
            message = self.recv_message()
            if message is None:
                continue
            if "event" in message:
                return message["event"], message.get("data") or {}
        return None, None


class Observer:
    def __init__(self, socket_path, log=None):
        self.log = log or (lambda msg: None)
        self.requests = RequestClient(socket_path, log=self.log)
        self.subscription = SubscriptionClient(socket_path, log=self.log)
        self.panes = {}
        self.skip_panes = set()
        # Timestamp-based so a restarted observer's reports are accepted
        # after the previous instance's sequence numbers.
        self.seq = int(time.time() * 1000)
        self.resubscribe = False
        self.reconcile = False

    # --- state helpers -------------------------------------------------

    def next_seq(self):
        self.seq += 1
        return self.seq

    def pane(self, pane_id):
        pane = self.panes.get(pane_id)
        if pane is None:
            pane = {
                "pane_id": pane_id,
                "cwd": None,
                "tab_id": None,
                "phase": None,
                "change": None,
                "labeled_for": None,
                "last_title": None,
            }
            self.panes[pane_id] = pane
        return pane

    def refresh_pane(self, pane_id):
        """Refreshes cwd/tab_id via pane.get; returns the pane state."""
        result = self.requests.call("pane.get", {"pane_id": pane_id})
        pane = self.pane(pane_id)
        if result and "pane" in result:
            info = result["pane"]
            pane["cwd"] = info.get("cwd") or info.get("foreground_cwd")
            pane["tab_id"] = info.get("tab_id")
        return pane

    def report_tokens(self, pane_id, phase, change):
        tokens = {}
        if phase:
            tokens["os_phase"] = phase
        if change:
            tokens["os_change"] = change
        if not tokens:
            return
        self.requests.call(
            "pane.report_metadata",
            {
                "pane_id": pane_id,
                "source": SOURCE,
                "seq": self.next_seq(),
                "tokens": tokens,
            },
        )

    def rename_tab(self, tab_id, label):
        if not tab_id or not label:
            return
        self.requests.call(
            "tab.rename", {"tab_id": tab_id, "label": label}
        )

    # --- signal handling ------------------------------------------------

    def apply_signal(self, pane_id, phase, change):
        pane = self.pane(pane_id)
        if phase is not None:
            pane["phase"] = phase
        if change is not None:
            pane["change"] = change
        self.log(
            "signal %s phase=%s change=%s"
            % (pane_id, pane["phase"], pane["change"])
        )
        self.report_tokens(pane_id, pane["phase"], pane["change"])
        self.update_label(pane_id)

    def update_label(self, pane_id):
        pane = self.pane(pane_id)
        change = pane["change"]
        phase = pane["phase"]
        if change:
            if pane["labeled_for"] == change:
                return
            if phase == "apply":
                label = change
            else:
                label = "? %s" % change
            pane["labeled_for"] = change
            self.rename_tab(pane["tab_id"], label)
            return
        if phase == "explore":
            title = pane.get("last_title")
            if title:
                self.rename_tab(
                    pane["tab_id"], "? %s" % title[:MAX_LABEL_LEN]
                )
            else:
                self.rename_tab(pane["tab_id"], "? explore")

    def handle_title(self, pane_id, title):
        """Follows the stripped terminal title while no change is known."""
        pane = self.pane(pane_id)
        if pane["change"] is not None:
            return
        if pane["phase"] != "explore":
            return
        if is_shell_prompt(title):
            return
        if title == pane["last_title"]:
            return
        pane["last_title"] = title
        self.log("title %s %s" % (pane_id, title))
        self.rename_tab(pane["tab_id"], "? %s" % title[:MAX_LABEL_LEN])

    def handle_line(self, pane_id, line):
        pane = self.pane(pane_id)
        cwd = pane.get("cwd")
        if cwd is None:
            pane = self.refresh_pane(pane_id)
            cwd = pane.get("cwd")
            if cwd is None:
                # pane.get answered pane_not_found: stale pane.
                self.panes.pop(pane_id, None)
                self.skip_panes.add(pane_id)
                return
        result = detect(line, cwd)
        if result is not None:
            self.apply_signal(pane_id, result[0], result[1])

    # --- subscriptions ---------------------------------------------------

    def build_subscriptions(self):
        subscriptions = [
            {"type": "pane.created"},
            {"type": "pane.closed"},
            {"type": "pane.updated"},
            {"type": "tab.closed"},
        ]
        for pane_id in self.panes:
            if pane_id in self.skip_panes:
                continue
            subscriptions.append(
                {
                    "type": "pane.output_matched",
                    "pane_id": pane_id,
                    "source": "recent",
                    "strip_ansi": True,
                    "match": {"type": "regex", "value": OUTPUT_MATCH_REGEX},
                }
            )
        return subscriptions

    def subscribe_all(self):
        """(Re-)issues the subscription for the current pane set."""
        if not self.subscription.subscribe(self.build_subscriptions()):
            raise ConnectionError("subscription rejected")
        self.log("subscribed to %d subscriptions"
                 % len(self.build_subscriptions()))

    # --- lifecycle --------------------------------------------------------

    def reconstruct(self):
        """Reads existing panes once and applies the rules to their output.
        The pane set is pruned to the current pane.list, so panes that
        closed while the observer was disconnected are forgotten."""
        result = self.requests.call("pane.list", {})
        if not result:
            self.log("pane.list failed; nothing reconstructed")
            return
        panes = result.get("panes") or []
        live = {info.get("pane_id") for info in panes}
        for dead in [pid for pid in self.panes if pid not in live]:
            self.panes.pop(dead, None)
            self.log("pane %s gone; forgotten" % dead)
        self.skip_panes.intersection_update(live)
        for info in panes:
            pane_id = info.get("pane_id")
            if not pane_id:
                continue
            pane = self.pane(pane_id)
            pane["cwd"] = info.get("cwd") or info.get("foreground_cwd")
            pane["tab_id"] = info.get("tab_id")
            title = info.get("terminal_title_stripped")
            if title and not is_shell_prompt(title):
                pane["last_title"] = title
            read = self.requests.call(
                "pane.read",
                {"pane_id": pane_id, "source": "recent", "strip_ansi": True},
            )
            if read is None:
                self.skip_panes.add(pane_id)
                self.log("pane %s not readable; skipping" % pane_id)
                continue
            text = (read.get("read") or {}).get("text")
            if text:
                for line in text.splitlines():
                    result = detect(line, pane["cwd"])
                    if result is not None:
                        phase, change = result
                        if phase is not None:
                            pane["phase"] = phase
                        if change is not None:
                            pane["change"] = change
            self.report_tokens(pane_id, pane["phase"], pane["change"])
            self.update_label(pane_id)
        self.log("reconstructed %d panes" % len(panes))

    def handle_event(self, name, data):
        # The event field is delivered with dotted names on some Herdr
        # builds and with underscores on others; normalize the all-
        # underscore form ("pane_created" -> "pane.created") while keeping
        # mixed names like "pane.output_matched" as they are.
        if "." not in name:
            name = name.replace("_", ".")
        if name == "pane.created":
            info = data.get("pane") or {}
            pane_id = info.get("pane_id")
            if pane_id:
                self.skip_panes.discard(pane_id)
                pane = self.pane(pane_id)
                pane["cwd"] = info.get("cwd") or info.get("foreground_cwd")
                pane["tab_id"] = info.get("tab_id")
                self.log("pane created %s" % pane_id)
                self.resubscribe = True
        elif name == "pane.closed":
            pane_id = data.get("pane_id")
            if pane_id:
                self.panes.pop(pane_id, None)
                self.skip_panes.discard(pane_id)
                self.log("pane closed %s" % pane_id)
                self.resubscribe = True
        elif name == "pane.updated":
            info = data.get("pane") or {}
            pane_id = info.get("pane_id")
            if not pane_id:
                return
            pane = self.pane(pane_id)
            pane["cwd"] = info.get("cwd") or info.get("foreground_cwd")
            pane["tab_id"] = info.get("tab_id")
            title = info.get("terminal_title_stripped")
            if title:
                self.handle_title(pane_id, title)
        elif name == "tab.closed":
            # Closing a tab emits tab.closed but no pane.closed for its
            # panes; forget them immediately.
            tab_id = data.get("tab_id")
            if tab_id:
                for pane_id in [
                    pid
                    for pid, pane in self.panes.items()
                    if pane.get("tab_id") == tab_id
                ]:
                    self.panes.pop(pane_id, None)
                    self.log("pane closed %s" % pane_id)
                self.resubscribe = True
        elif name == "pane.output_matched":
            pane_id = data.get("pane_id")
            line = data.get("matched_line")
            if pane_id and line:
                self.handle_line(pane_id, line)

    def run(self):
        self.reconstruct()
        while True:
            self.subscription.connect()
            self.subscribe_all()
            self.resubscribe = False
            self.reconcile = False
            self.log("watching")
            next_reconcile = time.time() + RECONCILE_INTERVAL
            while not self.resubscribe:
                name, data = self.subscription.wait_event(1)
                if name:
                    self.handle_event(name, data)
                # Herdr 0.9.0 delivers subscription events unreliably, so
                # periodically re-scan the pane set and their output. The
                # re-subscribe also replays all current matches.
                if time.time() >= next_reconcile:
                    self.reconcile = True
                    break
            self.subscription.close()
            if self.reconcile:
                self.log("reconciling")
                self.reconstruct()
            else:
                self.log("re-subscribing after pane change")


def run_tests():
    """Unit tests for the detection rules. Returns True when all pass."""
    fixture = tempfile.mkdtemp(prefix="observer-test-")
    os.makedirs(os.path.join(fixture, "openspec", "changes", "add-auth"))
    os.makedirs(
        os.path.join(
            fixture, "openspec", "changes", "publish-the-picker-plugin"
        )
    )
    repo = fixture
    cases = [
        # (line, cwd, expected (phase, change))
        ("/opsx:apply add-auth", repo, ("apply", "add-auth")),
        ("/opsx-apply add-auth", repo, ("apply", "add-auth")),
        ("$openspec-apply-change add-auth", repo, ("apply", "add-auth")),
        ("/openspec-apply-change add-auth", repo, ("apply", "add-auth")),
        ("/opsx:explore add-auth", repo, ("explore", "add-auth")),
        ("/opsx-explore", repo, ("explore", None)),
        ("/opsx:propose add-auth", repo, ("explore", "add-auth")),
        (
            "openspec instructions apply --change add-auth",
            repo,
            ("apply", "add-auth"),
        ),
        (
            "openspec instructions apply --change 'add-auth'",
            repo,
            ("apply", "add-auth"),
        ),
        ("openspec new change add-auth", repo, (None, "add-auth")),
        # glued typing echo: the later occurrence wins
        (
            "/opsx-apply publish-the-picker-pluginps@host:~ $ /opsx-apply "
            "publish-the-picker-plugin",
            repo,
            ("apply", "publish-the-picker-plugin"),
        ),
        # free text without a change directory: phase only
        ("/opsx-explore irgendein freitext", repo, ("explore", None)),
        # unknown directory: phase only
        ("/opsx:apply nope", repo, ("apply", None)),
        # no signal
        ("git status", repo, None),
        ("some random text", repo, None),
    ]
    failures = 0
    for line, cwd, expected in cases:
        actual = detect(line, cwd)
        status = "ok" if actual == expected else "FAIL"
        if status == "FAIL":
            failures += 1
        print(
            "%s  %-52s -> %s (expected %s)"
            % (status, line[:52], actual, expected)
        )
    print(
        "detection: %d/%d tests passed"
        % (len(cases) - failures, len(cases))
    )
    if run_event_tests(repo):
        print("handle_event: all tests passed")
        print("2/2 test groups passed")
        return failures == 0
    print("1/2 test groups passed")
    return False


class FakeRequests:
    """Records calls instead of talking to a socket."""

    def __init__(self):
        self.calls = []

    def call(self, method, params):
        self.calls.append((method, params))
        if method == "pane.get":
            return {
                "pane": {
                    "pane_id": params["pane_id"],
                    "cwd": "/repo",
                    "tab_id": "t1",
                }
            }
        if method == "pane.list":
            return {"panes": []}
        if method == "pane.read":
            return {"read": {"text": ""}}
        return {"type": "ok"}


def make_observer(repo):
    logs = []
    observer = Observer("unused.sock", log=logs.append)
    observer.requests = FakeRequests()
    return observer, logs


def run_event_tests(repo):
    """handle_event tests with the delivered dotted event names."""
    failures = 0

    def check(label, condition, detail=""):
        nonlocal failures
        status = "ok" if condition else "FAIL"
        if status == "FAIL":
            failures += 1
        print("%s  %s %s" % (status, label, detail))

    # pane.created (dotted) -> pane state added, resubscribe requested
    observer, logs = make_observer(repo)
    observer.handle_event(
        "pane.created",
        {"pane": {"pane_id": "p9", "cwd": "/repo", "tab_id": "t9"}},
    )
    check(
        "pane.created adds pane state",
        observer.pane("p9")["tab_id"] == "t9",
    )
    check(
        "pane.created requests resubscribe",
        observer.resubscribe is True,
    )
    check(
        "pane.created logs",
        any("pane created p9" in entry for entry in logs),
    )

    # pane.closed -> pane forgotten, resubscribe requested
    observer.handle_event("pane.closed", {"pane_id": "p9"})
    check(
        "pane.closed forgets the pane",
        "p9" not in observer.panes,
    )
    check(
        "pane.closed requests resubscribe",
        observer.resubscribe is True,
    )
    check(
        "pane.closed logs",
        any("pane closed p9" in entry for entry in logs),
    )

    # pane.updated -> session title followed while exploring without change
    observer, logs = make_observer(repo)
    pane = observer.pane("p2")
    pane["cwd"] = "/repo"
    pane["tab_id"] = "t2"
    pane["phase"] = "explore"
    observer.resubscribe = False
    observer.handle_event(
        "pane.updated",
        {
            "pane": {
                "pane_id": "p2",
                "tab_id": "t2",
                "terminal_title_stripped": "Drafting the plan",
            }
        },
    )
    check(
        "pane.updated follows terminal_title_stripped",
        ("tab.rename", {"tab_id": "t2", "label": "? Drafting the plan"})
        in observer.requests.calls,
    )

    # shell prompt titles are not followed
    observer.requests.calls.clear()
    observer.handle_event(
        "pane.updated",
        {
            "pane": {
                "pane_id": "p2",
                "tab_id": "t2",
                "terminal_title_stripped": "ps@host: ~/work",
            }
        },
    )
    check(
        "pane.updated ignores shell prompt titles",
        not any(
            method == "tab.rename" for method, _ in observer.requests.calls
        ),
    )

    # after a change name is known, titles stop renaming
    pane["change"] = "add-auth"
    pane["labeled_for"] = "add-auth"
    observer.requests.calls.clear()
    observer.handle_event(
        "pane.updated",
        {
            "pane": {
                "pane_id": "p2",
                "tab_id": "t2",
                "terminal_title_stripped": "Another title",
            }
        },
    )
    check(
        "pane.updated stops renaming after the change is known",
        not any(
            method == "tab.rename" for method, _ in observer.requests.calls
        ),
    )

    # pane.output_matched -> tokens reported
    observer, logs = make_observer(repo)
    pane = observer.pane("p3")
    pane["cwd"] = repo
    pane["tab_id"] = "t3"
    observer.handle_event(
        "pane.output_matched",
        {"pane_id": "p3", "matched_line": "/opsx:apply add-auth"},
    )
    reported = [
        params
        for method, params in observer.requests.calls
        if method == "pane.report_metadata"
    ]
    check(
        "pane.output_matched reports tokens",
        any(
            params.get("tokens", {}).get("os_phase") == "apply"
            and params.get("tokens", {}).get("os_change") == "add-auth"
            for params in reported
        ),
    )

    # underscore forms are tolerated (older Herdr builds deliver them)
    observer, logs = make_observer(repo)
    observer.handle_event(
        "pane_created",
        {"pane": {"pane_id": "p4", "cwd": "/repo", "tab_id": "t4"}},
    )
    check(
        "underscore pane_created is tolerated",
        "p4" in observer.panes,
    )

    # the subscription pattern must not match a plain shell prompt
    prompt = "ps@gateway-host:~/work/openspec-herdr $ "
    check(
        "subscription pattern does not match the shell prompt",
        re.search(OUTPUT_MATCH_REGEX, prompt) is None,
    )

    return failures == 0


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--test", action="store_true", help="run rule tests")
    args = parser.parse_args()

    socket_path = os.environ.get("HERDR_SOCKET_PATH")
    state_dir = os.environ.get(
        "HERDR_PLUGIN_STATE_DIR",
        os.path.join(
            os.environ.get("HOME", "/tmp"),
            ".config/herdr/plugins/config/openspec.picker/state",
        ),
    )
    log_file = os.path.join(state_dir, "observer.log")

    def log(message):
        try:
            os.makedirs(os.path.dirname(log_file), exist_ok=True)
            with open(log_file, "a", encoding="utf-8") as handle:
                handle.write(
                    "[%s] %s\n"
                    % (time.strftime("%Y-%m-%dT%H:%M:%S"), message)
                )
        except OSError:
            pass

    if args.test:
        sys.exit(0 if run_tests() else 1)

    if not socket_path:
        log("HERDR_SOCKET_PATH not set; exiting")
        sys.exit(0)

    observer = Observer(socket_path, log=log)
    backoff = RECONNECT_BASE
    while True:
        try:
            observer.run()
            backoff = RECONNECT_BASE
        except (ConnectionError, OSError) as error:
            observer.subscription.close()
            log("socket lost (%s); reconnecting in %.1fs"
                % (error, backoff))
            time.sleep(backoff)
            backoff = min(backoff * 2, RECONNECT_MAX)


if __name__ == "__main__":
    main()
