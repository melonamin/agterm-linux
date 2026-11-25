#!/usr/bin/env python3
"""Replay a gl_teardown_shim.c log and judge every libghostty GL delete against its surface's owner context.

    gl_teardown_analyze.py LOG --app-stderr FILE [--baseline] [--require-api glx]

Prints `DIAG <CODE> <path> <detail>` per finding and `INFO renderer <GL_RENDERER>`. Exit 0 means clean: no DIAG at
all, or with --baseline no harness fault and every code in BASELINE_EXPECTED. Exit 1 otherwise, 2 on bad usage.

Log grammar, one line per record. The first token is the type, the rest `key=value`. Pointers are hex, none is `0`.
Every shim record carries `tid`, `ctx` (the real current native context) and, where a caller exists, `caller`, the
base name of the calling object with the main executable spelled `main`.

    GL_RENDERER text=<rest of line>        CONTEXT_CREATE api= handle= share= ok=    CONTEXT_DESTROY api= handle= ok=
    GL_CREATE kind= name=                  GL_DELETE kind= name= err=<hex|none>      GL_ERROR value=
    TEX_IMAGE width= height= name=         NEW_BEGIN / NEW_END surface=              DRAW_BEGIN / DRAW_END surface=
    FREE_BEGIN / FREE_END surface=         SYMBOL_MISSING name=                      END
    HOST call=<area_context|get_current|make_current|clear_current|ref|unref> arg= ret=

From the harness, written with O_APPEND between shim records:

    MARK <path> begin|end                  SEED <name> <path> <width> <height>

Replay state: a generation per context create, so a reused handle is a new context; share groups from the share
argument; each surface's owner is the context current at its NEW_END, rechecked at every DRAW_BEGIN. A Ghostty object
belongs to the surface whose bracket created it, keyed (generation, kind, name) for the LOCAL_KINDS and (group, kind,
name) otherwise. GTK's objects are ledgered for name accounting only and carry no rule.

Harness faults, failing in every mode:
    LOG_EMPTY, LOG_TRUNCATED (no END), LOG_MALFORMED, SYMBOL_MISSING, RENDERER_MISSING, GTK_TRAFFIC_MISSING (no create
    tagged libgtk-4 or libepoxy), BRACKET_MISSING, PATH_NOT_EXERCISED, SEED_NOT_UPLOADED, SEED_GONE_BEFORE_FREE,
    UNKNOWN_CONTEXT

Violations:
    DELETE_FOREIGN_CONTEXT     non-owner context in the owner's share group, owning no live surface (GTK's)
    DELETE_SIBLING_CONTEXT     non-owner context owning another live surface
    DELETE_NO_CONTEXT          nothing current; GL silently leaves the object alive
    DELETE_CROSS_SHARE_GROUP   current context outside the owner's share group
    DELETE_UNKNOWN             name absent from the ledger
    DELETE_WRONG_SURFACE       name belongs to another surface or to GTK
    CREATE_NO_CONTEXT          a libghostty create with nothing current
    DRAW_CONTEXT_MISMATCH      a draw not under the surface's owner
    GL_ERROR                   a libghostty record with a real GL error
    SHARED_SURVIVOR            a shared-kind Ghostty object alive after its surface's free
    SEED_NOT_DELETED           a seeded texture left alive by its surface's free
    OWNER_API                  --require-api saw an owner from another API

Normal mode only, because the unfixed baseline has no host sequence:
    OWNER_GONE_AT_FREE         the owner generation was destroyed before its free
    HOST_ORDER                 not save, ref prior, owner make-current, verify immediately before FREE_BEGIN
    RESTORE_MISSED             no verified return to the prior context after FREE_END, native context included
    REF_IMBALANCE              main-executable refs on a GDK context beyond those held by surfaces live at END
    DEGRADED_LOG               a `agterm: retained GL context:` line in the app's stderr
"""

import argparse
import collections
import sys

PATHS = ("session-selected", "session-background", "split", "scratch", "overlay", "hud", "quick-exit", "restart",
         "window")
BASELINE_EXPECTED = (("DELETE_FOREIGN_CONTEXT", "session-selected"), ("DELETE_NO_CONTEXT", "quick-exit"),
                     ("DELETE_SIBLING_CONTEXT", "restart"))
# Per-context objects, which `Pipeline.deinit` leaves for the context's death, so lifetime checks skip them.
LOCAL_KINDS = frozenset(("framebuffer", "vertex_array", "query", "transform_feedback", "program_pipeline"))
SHADER_SEED_PATH = "session-background"
GHOSTTY = "libghostty"
PREFIX = "agterm: retained GL context:"
HARNESS_FAULTS = frozenset((
    "LOG_EMPTY", "LOG_TRUNCATED", "LOG_MALFORMED", "SYMBOL_MISSING", "RENDERER_MISSING", "GTK_TRAFFIC_MISSING",
    "BRACKET_MISSING", "PATH_NOT_EXERCISED", "SEED_NOT_UPLOADED", "SEED_GONE_BEFORE_FREE", "UNKNOWN_CONTEXT"))
KEYED_TYPES = frozenset((
    "GL_RENDERER", "CONTEXT_CREATE", "CONTEXT_DESTROY", "GL_CREATE", "GL_DELETE", "GL_ERROR", "TEX_IMAGE", "NEW_BEGIN",
    "NEW_END", "DRAW_BEGIN", "DRAW_END", "FREE_BEGIN", "FREE_END", "SYMBOL_MISSING", "HOST"))


class Context:
    def __init__(self, handle, api, group):
        self.handle, self.api, self.group = handle, api, group
        self.alive = True


class Surface:
    def __init__(self):
        self.pointer = self.owner = self.gdk_owner = None
        self.sampler_created = False
        self.drawn = False
        self.freed_in = None


class Seed:
    def __init__(self, name, path, width, height):
        self.name, self.path, self.width, self.height = name, path, int(width), int(height)
        self.surface = self.key = None
        self.live_at_free = self.deleted_in_free = False


class Entry:
    def __init__(self, kind, name, surface, caller):
        self.kind, self.name, self.surface, self.caller = kind, name, surface, caller


class Replay:
    def __init__(self, require_api=None):
        self.require_api = require_api
        self.diags = []
        self.contexts = {}
        self.next_group = 0
        self.live_surfaces = {}
        self.brackets = {}
        self.ledger = {}
        self.path = None
        self.path_state = {path: collections.Counter() for path in PATHS}
        self.seeds = {}
        self.seed_surfaces = set()
        self.renderer = None
        self.gtk_traffic = False
        self.ended = False
        self.host = []
        self.frees = []
        self.free_floor = 0
        self.refs = collections.Counter()

    def diag(self, code, detail):
        self.diags.append((code, self.path or "-", detail))

    def context(self, handle, record_type):
        if handle == "0":
            return None
        found = self.contexts.get(handle)
        if found is None:
            self.diag("UNKNOWN_CONTEXT", f"{record_type} ctx={handle}")
        return found

    def key(self, kind, name, context):
        return (id(context), kind, name) if kind in LOCAL_KINDS else (context.group, kind, name)

    def bracket(self, record, kind):
        opened = self.brackets.get(record["tid"])
        if opened is None or opened[0] != kind:
            self.diag("BRACKET_MISSING", f"no open {kind} bracket for {record['_type']}")
            return None
        return opened

    def open_bracket(self, record, kind, surface):
        if record["tid"] in self.brackets:
            self.diag("BRACKET_MISSING", f"{record['_type']} inside {self.brackets[record['tid']][0]}")
        self.brackets[record["tid"]] = (kind, surface)

    def feed(self, line):
        tokens = line.split()
        if not tokens:
            return
        kind = tokens[0]
        if kind == "END":
            self.ended = True
        elif kind == "MARK" and len(tokens) == 3 and tokens[2] in ("begin", "end"):
            self.mark(tokens[1], tokens[2])
        elif kind == "SEED" and len(tokens) == 5:
            self.seeds[tokens[1]] = Seed(*tokens[1:])
        elif kind == "GL_RENDERER" and "text=" in line:
            if self.renderer is None:
                self.renderer = line.split("text=", 1)[1].strip()
        elif kind in KEYED_TYPES:
            try:
                record = dict(token.split("=", 1) for token in tokens[1:])
            except ValueError:
                self.diag("LOG_MALFORMED", line[:120])
                return
            record["_type"] = kind
            try:
                getattr(self, "on_" + kind.lower())(record)
            except KeyError as error:
                self.diag("LOG_MALFORMED", f"{kind} lacks {error}")
        else:
            self.diag("LOG_MALFORMED", line[:120])

    def mark(self, path, phase):
        if path not in self.path_state:
            self.diag("LOG_MALFORMED", f"unknown path {path}")
            return
        self.path_state[path][phase] += 1
        self.path = path if phase == "begin" else None

    def on_symbol_missing(self, record):
        self.diag("SYMBOL_MISSING", record["name"])

    def on_context_create(self, record):
        if record["ok"] != "1":
            return
        share = record["share"]
        if share == "0":
            self.next_group += 1
            group = self.next_group
        else:
            parent = self.context(share, "CONTEXT_CREATE share")
            group = parent.group if parent else -1
        self.contexts[record["handle"]] = Context(record["handle"], record["api"], group)

    def on_context_destroy(self, record):
        found = self.contexts.get(record["handle"])
        if found and record["ok"] == "1":
            found.alive = False

    def on_gl_create(self, record):
        caller = record["caller"]
        if "libgtk-4" in caller or "libepoxy" in caller:
            self.gtk_traffic = True
        current = self.context(record["ctx"], "GL_CREATE")
        ghostty = GHOSTTY in caller
        if ghostty and record["ctx"] == "0":
            self.diag("CREATE_NO_CONTEXT", f"{record['kind']} {record['name']}")
        if current is None:
            return
        surface = None
        if ghostty:
            opened = self.brackets.get(record["tid"])
            if opened is None:
                self.diag("BRACKET_MISSING", f"libghostty create {record['kind']} {record['name']} outside a bracket")
                return
            surface = opened[1]
            if record["kind"] == "sampler" and opened[0] in ("new", "draw"):
                surface.sampler_created = True
        self.ledger[self.key(record["kind"], record["name"], current)] = Entry(
            record["kind"], record["name"], surface, caller)

    def on_gl_delete(self, record):
        if record["name"] == "0":
            return
        current = self.context(record["ctx"], "GL_DELETE")
        if GHOSTTY not in record["caller"]:
            if current:
                self.ledger.pop(self.key(record["kind"], record["name"], current), None)
            return
        kind, name = record["kind"], record["name"]
        detail = f"{kind} {name} ctx={record['ctx']}"
        if record["ctx"] == "0":
            self.diag("DELETE_NO_CONTEXT", detail)
            return
        if current is None:
            return
        if record["err"] not in ("none", "0x0", "0"):
            self.diag("GL_ERROR", f"delete {detail} err={record['err']}")
        opened = self.brackets.get(record["tid"])
        violated = self.judge_context(opened, current, kind, detail)
        key = self.key(kind, name, current)
        entry = self.ledger.get(key)
        if entry is None:
            if not violated:
                self.diag("DELETE_UNKNOWN", detail)
            return
        if not violated and opened and entry.surface is not opened[1]:
            self.diag("DELETE_WRONG_SURFACE", detail)
        del self.ledger[key]
        for seed in self.seeds.values():
            if seed.key == key and opened and opened[0] == "free" and opened[1] is seed.surface:
                seed.deleted_in_free = True

    def judge_context(self, opened, current, kind, detail):
        """The owner rule, independent of name lookup: a local name deleted elsewhere can match by accident."""
        if opened is None or opened[1].owner is None or current is opened[1].owner:
            return False
        owner = opened[1].owner
        if current.group != owner.group:
            self.diag("DELETE_CROSS_SHARE_GROUP", detail)
            return True
        if opened[0] != "free" and kind not in LOCAL_KINDS:
            return False
        sibling = any(surface.owner is current for surface in self.live_surfaces.values())
        self.diag("DELETE_SIBLING_CONTEXT" if sibling else "DELETE_FOREIGN_CONTEXT", detail)
        return True

    def on_gl_error(self, record):
        if GHOSTTY in record["caller"]:
            self.diag("GL_ERROR", f"glGetError {record['value']} ctx={record['ctx']}")

    def on_tex_image(self, record):
        opened = self.brackets.get(record["tid"])
        if GHOSTTY not in record["caller"] or opened is None or opened[0] != "draw":
            return
        size = (int(record["width"]), int(record["height"]))
        current = self.context(record["ctx"], "TEX_IMAGE")
        for seed in self.seeds.values():
            if seed.surface is None and size == (seed.width, seed.height) and current:
                key = self.key("texture", record["name"], current)
                entry = self.ledger.get(key)
                if entry and entry.surface is opened[1]:
                    seed.surface, seed.key = opened[1], key
                    self.seed_surfaces.add(opened[1])

    def on_new_begin(self, record):
        surface = Surface()
        tail = self.host[self.free_floor:][-2:]
        if len(tail) == 2 and tail[0]["call"] == "area_context" and tail[1]["call"] == "ref" \
                and tail[1]["arg"] == tail[0]["ret"]:
            surface.gdk_owner = tail[0]["ret"]
        self.open_bracket(record, "new", surface)

    def on_new_end(self, record):
        opened = self.bracket(record, "new")
        if opened is None:
            return
        del self.brackets[record["tid"]]
        if record["surface"] == "0":
            return
        surface = opened[1]
        surface.pointer = record["surface"]
        surface.owner = self.context(record["ctx"], "NEW_END")
        if surface.owner is None:
            self.diag("BRACKET_MISSING", f"surface {surface.pointer} created with no context current")
        elif self.require_api and surface.owner.api != self.require_api:
            self.diag("OWNER_API", f"surface {surface.pointer} owner {surface.owner.handle} is {surface.owner.api}")
        self.live_surfaces[surface.pointer] = surface

    def surface_for(self, record):
        surface = self.live_surfaces.get(record["surface"])
        if surface is None:
            self.diag("BRACKET_MISSING", f"{record['_type']} of {record['surface']} without a NEW bracket")
        return surface

    def on_draw_begin(self, record):
        surface = self.surface_for(record) or Surface()
        current = self.context(record["ctx"], "DRAW_BEGIN")
        if surface.owner is not None and current is not surface.owner:
            self.diag("DRAW_CONTEXT_MISMATCH", f"surface {record['surface']} ctx={record['ctx']}")
        surface.drawn = True
        self.open_bracket(record, "draw", surface)

    def on_draw_end(self, record):
        if self.bracket(record, "draw"):
            del self.brackets[record["tid"]]

    def on_free_begin(self, record):
        surface = self.surface_for(record) or Surface()
        surface.freed_in = self.path
        if surface.owner is not None and not surface.owner.alive:
            self.diag("OWNER_GONE_AT_FREE", f"surface {record['surface']}")
        for seed in self.seeds.values():
            if seed.surface is surface and self.path == seed.path:
                seed.live_at_free = seed.key in self.ledger
        self.open_bracket(record, "free", surface)
        self.frees.append({"surface": surface, "path": self.path, "pre": self.host[self.free_floor:],
                           "post": len(self.host)})

    def on_free_end(self, record):
        opened = self.bracket(record, "free")
        if opened is None:
            return
        del self.brackets[record["tid"]]
        surface = opened[1]
        self.frees[-1]["post"] = self.free_floor = len(self.host)
        if self.path:
            self.path_state[self.path]["frees"] += 1
        if surface.pointer == record["surface"]:
            self.live_surfaces.pop(record["surface"], None)
        for key, entry in list(self.ledger.items()):
            if entry.surface is surface and entry.kind not in LOCAL_KINDS:
                self.diag("SHARED_SURVIVOR", f"{entry.kind} {entry.name} of surface {surface.pointer}")
                del self.ledger[key]

    def on_host(self, record):
        self.host.append(record)
        if record["call"] == "ref":
            self.refs[record["arg"]] += 1
        elif record["call"] == "unref":
            self.refs[record["arg"]] -= 1

    def finish(self, baseline, stderr_lines):
        if not self.ended:
            self.diag("LOG_TRUNCATED", "no END")
        if self.renderer is None:
            self.diag("RENDERER_MISSING", "no GL_RENDERER record")
        if not self.gtk_traffic:
            self.diag("GTK_TRAFFIC_MISSING", "no create tagged libgtk-4 or libepoxy")
        for tid, opened in self.brackets.items():
            self.diag("BRACKET_MISSING", f"{opened[0]} bracket open at END on tid {tid}")
        for path, state in self.path_state.items():
            if not (state["begin"] and state["end"] and state["frees"]):
                self.path = path
                self.diag("PATH_NOT_EXERCISED", f"begin={state['begin']} end={state['end']} frees={state['frees']}")
        self.path = None
        self.check_seeds()
        if not baseline:
            self.check_host()
            for line in stderr_lines:
                if PREFIX in line:
                    self.diag("DEGRADED_LOG", line.strip())

    def check_seeds(self):
        for name in ("background", "image"):
            if name not in self.seeds:
                self.diag("SEED_NOT_UPLOADED", f"{name}: no SEED record")
        for seed in self.seeds.values():
            self.path = seed.path
            if seed.surface is None:
                self.diag("SEED_NOT_UPLOADED", f"{seed.name}: no {seed.width}x{seed.height} upload in a draw")
            elif seed.surface.freed_in != seed.path or not seed.live_at_free:
                self.diag("SEED_GONE_BEFORE_FREE", f"{seed.name}: freed in {seed.surface.freed_in}")
            elif not seed.deleted_in_free:
                self.diag("SEED_NOT_DELETED", seed.name)
        self.path = SHADER_SEED_PATH
        if not any(surface.sampler_created and surface.drawn and surface.freed_in == SHADER_SEED_PATH
                   for surface in self.seed_surfaces):
            self.diag("SEED_NOT_UPLOADED", "shader: no sampler in the seeded surface's NEW/DRAW brackets plus a draw")
        self.path = None

    def check_host(self):
        for free in self.frees:
            self.path = free["path"]
            prior = self.check_save(free)
            if prior is not None:
                self.check_restore(free, prior)
        self.path = None
        # No quit-time sweep exists, so a surface still live at END legitimately holds its owner.
        held = collections.Counter(surface.gdk_owner for surface in self.live_surfaces.values())
        for handle, balance in self.refs.items():
            if balance != held[handle]:
                self.diag("REF_IMBALANCE", f"context {handle} off by {balance - held[handle]}")

    @staticmethod
    def steps(rows):
        return [(row["call"], row["ret"] if row["call"] == "get_current" else row["arg"]) for row in rows]

    def check_save(self, free):
        """Returns the prior's (gdk, native), or None when the sequence before FREE_BEGIN is wrong."""
        pre, owner = free["pre"], free["surface"].gdk_owner
        steps = self.steps(pre[-4:])
        detail = f"surface {free['surface'].pointer}: {steps}"
        if owner is None or steps[-2:] != [("make_current", owner), ("get_current", owner)]:
            self.diag("HOST_ORDER", detail)
            return None
        if len(steps) == 4 and steps[0][0] == "get_current" and steps[1] == ("ref", steps[0][1]):
            return steps[0][1], pre[-4]["ctx"]
        if len(steps) >= 3 and steps[-3] == ("get_current", "0"):
            return "0", pre[-3]["ctx"]
        self.diag("HOST_ORDER", detail)
        return None

    def check_restore(self, free, prior):
        post = self.host[free["post"]:free["post"] + 2]
        gdk, native = prior
        first = ("make_current", gdk) if gdk != "0" else ("clear_current", "0")
        steps = self.steps(post)
        restored = steps == [first, ("get_current", gdk)] and post[1]["ctx"] == native
        if restored and gdk != "0" and native == "0":
            restored = False
        if not restored:
            self.diag("RESTORE_MISSED", f"surface {free['surface'].pointer}: expected {first}, got {steps}")


def analyze(lines, stderr_lines, baseline=False, require_api=None):
    """Returns (exit status, diags, renderer)."""
    replay = Replay(require_api)
    count = 0
    for line in lines:
        count += 1
        replay.feed(line)
    if count == 0:
        return 1, [("LOG_EMPTY", "-", "no records")], None
    replay.finish(baseline, stderr_lines)
    diags = replay.diags
    if baseline:
        found = {(code, path) for code, path, _ in diags}
        clean = not any(code in HARNESS_FAULTS for code, _, _ in diags) and all(
            expected in found for expected in BASELINE_EXPECTED)
    else:
        clean = not diags
    return (0 if clean else 1), diags, replay.renderer


def main(argv=None):
    parser = argparse.ArgumentParser(description="judge a GL teardown shim log")
    parser.add_argument("log")
    parser.add_argument("--app-stderr", required=True)
    parser.add_argument("--baseline", action="store_true")
    parser.add_argument("--require-api", choices=("glx", "egl"))
    arguments = parser.parse_args(argv)
    with open(arguments.app_stderr, encoding="utf-8", errors="replace") as file:
        stderr_lines = file.readlines()
    with open(arguments.log, encoding="utf-8", errors="replace") as file:
        status, diags, renderer = analyze(file, stderr_lines, arguments.baseline, arguments.require_api)
    for (code, path), count in collections.Counter((row[0], row[1]) for row in diags).items():
        print(f"SUMMARY {code} {path} count={count}")
    for code, path, detail in diags:
        print(f"DIAG {code} {path} {detail}")
    print(f"INFO renderer {renderer}")
    return status


if __name__ == "__main__":
    sys.exit(main())
