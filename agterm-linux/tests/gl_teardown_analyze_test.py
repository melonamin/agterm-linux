#!/usr/bin/env python3
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gl_teardown_analyze import BASELINE_EXPECTED, PATHS, PREFIX, analyze  # noqa: E402

TID = "tid=1"
OWNER = "0xa"
SIBLING = "0xb"
GTK = "0xc"
OTHER_GROUP = "0xd"


def rec(body, ctx="0"):
    return f"{body} {TID} ctx={ctx}"


def ghostty(body, ctx):
    return rec(f"{body} caller=libghostty.so", ctx)


def host(call, ctx, arg="0", ret="0"):
    return rec(f"HOST call={call} arg={arg} ret={ret} caller=main", ctx)


def new(surface, ctx, gdk, objects=()):
    return [
        host("area_context", ctx, ret=gdk), host("ref", ctx, arg=gdk), rec("NEW_BEGIN", ctx),
        *[ghostty(f"GL_CREATE kind={kind} name={name}", ctx) for kind, name in objects],
        rec(f"NEW_END surface={surface}", ctx),
    ]


def free(surface, owner_gdk, owner_ctx, deletes=(), prior_gdk="0xf", prior_ctx=GTK, delete_ctx=None, restore=True,
         unref_owner=True):
    delete_ctx = owner_ctx if delete_ctx is None else delete_ctx
    lines = [host("get_current", prior_ctx, ret=prior_gdk)]
    if prior_gdk != "0":
        lines.append(host("ref", prior_ctx, arg=prior_gdk))
    lines += [host("make_current", owner_ctx, arg=owner_gdk), host("get_current", owner_ctx, ret=owner_gdk),
              rec(f"FREE_BEGIN surface={surface}", delete_ctx)]
    lines += [ghostty(f"GL_DELETE kind={kind} name={name} err=0x0", delete_ctx) for kind, name in deletes]
    lines.append(rec(f"FREE_END surface={surface}", delete_ctx))
    if restore:
        if prior_gdk == "0":
            lines += [host("clear_current", "0"), host("get_current", "0")]
        else:
            lines += [host("make_current", prior_ctx, arg=prior_gdk), host("get_current", prior_ctx, ret=prior_gdk)]
    if prior_gdk != "0":
        lines.append(host("unref", prior_ctx, arg=prior_gdk))
    if unref_owner:
        lines.append(host("unref", prior_ctx, arg=owner_gdk))
    return lines


def contexts():
    return [
        rec(f"CONTEXT_CREATE api=egl handle={GTK} share=0 ok=1 caller=libepoxy.so.0"),
        rec(f"CONTEXT_CREATE api=egl handle={OWNER} share={GTK} ok=1 caller=libepoxy.so.0"),
        rec(f"CONTEXT_CREATE api=egl handle={SIBLING} share={GTK} ok=1 caller=libepoxy.so.0"),
        rec(f"CONTEXT_CREATE api=egl handle={OTHER_GROUP} share=0 ok=1 caller=libepoxy.so.0"),
        rec("GL_CREATE kind=framebuffer name=900 caller=libgtk-4.so.1", GTK),
    ]


def seeded_surface(surface="0xc0", ctx=OWNER, gdk="0xe0", sampler=True):
    lines = new(surface, ctx, gdk, [("sampler", 71)] if sampler else [])
    lines += ["SEED background session-background 37 23", "SEED image session-background 29 31",
              rec(f"DRAW_BEGIN surface={surface}", ctx),
              ghostty("GL_CREATE kind=texture name=81", ctx), ghostty("GL_CREATE kind=texture name=82", ctx),
              ghostty("TEX_IMAGE width=37 height=23 name=81", ctx), ghostty("TEX_IMAGE width=29 height=31 name=82", ctx),
              rec(f"DRAW_END surface={surface}", ctx)]
    return lines


SEED_DELETES = (("texture", 81), ("texture", 82), ("sampler", 71))


def path_block(index, name):
    """A clean, otherwise empty exercise of one path on a surface of its own."""
    surface = f"0xd{index}"
    gdk = f"0xe{index + 1}"
    if name == "session-background":
        return [*seeded_surface(), f"MARK {name} begin", *free("0xc0", "0xe0", OWNER, SEED_DELETES), f"MARK {name} end"]
    return [*new(surface, OWNER, gdk), f"MARK {name} begin", *free(surface, gdk, OWNER), f"MARK {name} end"]


def clean_log(replacements=None, extra=()):
    lines = [*contexts(), rec("GL_RENDERER text=Mesa llvmpipe (LLVM 20)", GTK)]
    for index, name in enumerate(PATHS):
        lines += (replacements or {}).get(name) or path_block(index, name)
    return [*lines, *extra, "END"]


class Case(unittest.TestCase):
    def assert_clean(self, lines, stderr=()):
        status, diags, _ = analyze(lines, stderr)
        self.assertEqual([], diags)
        self.assertEqual(0, status)

    def assert_diag(self, lines, code, stderr=(), **options):
        status, diags, _ = analyze(lines, stderr, **options)
        self.assertEqual(1, status)
        self.assertIn(code, [row[0] for row in diags], diags)


class Harness(Case):
    def test_a_clean_log_passes(self):
        self.assert_clean(clean_log())

    def test_empty_log(self):
        self.assertEqual("LOG_EMPTY", analyze([], [])[1][0][0])

    def test_truncated_log(self):
        self.assert_diag(clean_log()[:-1], "LOG_TRUNCATED")

    def test_a_torn_record(self):
        self.assert_diag([*clean_log()[:-1], "GL_DEL", "END"], "LOG_MALFORMED")

    def test_missing_path(self):
        self.assert_diag(clean_log({"hud": ["MARK hud begin", "MARK hud end"]}), "PATH_NOT_EXERCISED")

    def test_missing_free_end_bracket(self):
        lines = [*new("0xd9", OWNER, "0xe9"), rec("FREE_BEGIN surface=0xd9", OWNER)]
        self.assert_diag(clean_log({"hud": ["MARK hud begin", *lines, "MARK hud end"]}), "BRACKET_MISSING")

    def test_a_draw_of_a_surface_with_no_new_bracket(self):
        self.assert_diag(clean_log(extra=[rec("DRAW_BEGIN surface=0x99", OWNER), rec("DRAW_END surface=0x99", OWNER)]),
                         "BRACKET_MISSING")

    def test_gtk_traffic_missing(self):
        lines = [line for line in clean_log() if "kind=framebuffer name=900" not in line]
        self.assert_diag(lines, "GTK_TRAFFIC_MISSING")

    def test_an_unknown_context(self):
        self.assert_diag(clean_log(extra=[rec("GL_CREATE kind=buffer name=4 caller=libgtk-4.so.1", "0x77")]),
                         "UNKNOWN_CONTEXT")


class Deletes(Case):
    def scenario(self, deletes, delete_ctx, objects):
        return clean_log({"hud": [
            *new("0xd9", SIBLING, "0xe8"),
            *new("0xda", OWNER, "0xe9", objects), "MARK hud begin",
            *free("0xda", "0xe9", OWNER, deletes, delete_ctx=delete_ctx),
            *free("0xd9", "0xe8", SIBLING),
            "MARK hud end"]})

    def test_a_local_name_shared_by_two_contexts_passes_under_its_owner(self):
        lines = clean_log({"hud": [
            *new("0xd9", SIBLING, "0xe8", [("framebuffer", 3)]),
            *new("0xda", OWNER, "0xe9", [("framebuffer", 3)]), "MARK hud begin",
            *free("0xda", "0xe9", OWNER, [("framebuffer", 3)]),
            *free("0xd9", "0xe8", SIBLING, [("framebuffer", 3)]), "MARK hud end"]})
        self.assert_clean(lines)

    def test_an_owner_local_name_deleted_where_the_sibling_has_the_same_name(self):
        lines = clean_log({"hud": [
            *new("0xd9", SIBLING, "0xe8", [("framebuffer", 3)]),
            *new("0xda", OWNER, "0xe9", [("framebuffer", 3)]), "MARK hud begin",
            *free("0xda", "0xe9", OWNER, [("framebuffer", 3)], delete_ctx=SIBLING),
            *free("0xd9", "0xe8", SIBLING), "MARK hud end"]})
        self.assert_diag(lines, "DELETE_SIBLING_CONTEXT")

    def test_a_foreign_delete_inside_free_fails_though_gl_allows_it(self):
        self.assert_diag(self.scenario([("texture", 5)], GTK, [("texture", 5)]), "DELETE_FOREIGN_CONTEXT")

    def test_a_same_group_shared_delete_outside_free_passes(self):
        lines = clean_log({"hud": [
            *new("0xda", OWNER, "0xe9", [("texture", 5)]),
            rec("DRAW_BEGIN surface=0xda", OWNER),
            ghostty("GL_DELETE kind=texture name=5 err=0x0", SIBLING),
            rec("DRAW_END surface=0xda", OWNER),
            "MARK hud begin", *free("0xda", "0xe9", OWNER), "MARK hud end"]})
        self.assert_clean(lines)

    def test_a_delete_with_no_bracket_in_the_share_group_passes(self):
        lines = clean_log({"hud": [
            *new("0xda", OWNER, "0xe9", [("texture", 5)]),
            ghostty("GL_DELETE kind=texture name=5 err=0x0", GTK),
            "MARK hud begin", *free("0xda", "0xe9", OWNER), "MARK hud end"]})
        self.assert_clean(lines)

    def test_a_delete_outside_the_share_group(self):
        self.assert_diag(self.scenario([("texture", 5)], OTHER_GROUP, [("texture", 5)]), "DELETE_CROSS_SHARE_GROUP")

    def test_a_no_context_delete(self):
        self.assert_diag(self.scenario([("texture", 5)], "0", [("texture", 5)]), "DELETE_NO_CONTEXT")

    def test_an_unknown_delete(self):
        self.assert_diag(self.scenario([("texture", 6)], OWNER, []), "DELETE_UNKNOWN")

    def test_another_surfaces_shared_name(self):
        lines = clean_log({"hud": [
            *new("0xd9", SIBLING, "0xe8", [("texture", 5)]),
            *new("0xda", OWNER, "0xe9"), "MARK hud begin",
            *free("0xda", "0xe9", OWNER, [("texture", 5)]),
            *free("0xd9", "0xe8", SIBLING), "MARK hud end"]})
        self.assert_diag(lines, "DELETE_WRONG_SURFACE")

    def test_a_real_gl_error_on_a_delete(self):
        lines = clean_log({"hud": [
            *new("0xda", OWNER, "0xe9", [("texture", 5)]), "MARK hud begin",
            *[line.replace("err=0x0", "err=0x502")
              for line in free("0xda", "0xe9", OWNER, [("texture", 5)])], "MARK hud end"]})
        self.assert_diag(lines, "GL_ERROR")

    def test_a_reused_handle_is_a_new_context(self):
        lines = clean_log({"hud": [
            *new("0xda", OWNER, "0xe9"),
            rec(f"CONTEXT_DESTROY api=egl handle={OWNER} ok=1 caller=libepoxy.so.0"),
            rec(f"CONTEXT_CREATE api=egl handle={OWNER} share={GTK} ok=1 caller=libepoxy.so.0"),
            rec("DRAW_BEGIN surface=0xda", OWNER), rec("DRAW_END surface=0xda", OWNER),
            "MARK hud begin", *free("0xda", "0xe9", OWNER), "MARK hud end"]})
        self.assert_diag(lines, "DRAW_CONTEXT_MISMATCH")
        self.assert_diag(lines, "OWNER_GONE_AT_FREE")


class Survivors(Case):
    def test_a_closed_surfaces_shared_survivor_fails(self):
        lines = clean_log({"hud": [*new("0xda", OWNER, "0xe9", [("buffer", 5)]), "MARK hud begin",
                                   *free("0xda", "0xe9", OWNER), "MARK hud end"]})
        self.assert_diag(lines, "SHARED_SURVIVOR")

    def test_gtks_survivor_and_a_surfaces_framebuffer_pass(self):
        lines = clean_log({"hud": [*new("0xda", OWNER, "0xe9", [("framebuffer", 5), ("vertex_array", 6)]),
                                   rec("GL_CREATE kind=texture name=500 caller=libgtk-4.so.1", GTK),
                                   "MARK hud begin", *free("0xda", "0xe9", OWNER), "MARK hud end"]})
        self.assert_clean(lines)


class Host(Case):
    def hud(self, **options):
        return clean_log({"hud": [*new("0xda", OWNER, "0xe9"), "MARK hud begin",
                                  *free("0xda", "0xe9", OWNER, **options), "MARK hud end"]})

    def test_nil_prior_passes(self):
        self.assert_clean(self.hud(prior_gdk="0", prior_ctx="0"))

    def test_prior_equal_to_owner_passes(self):
        self.assert_clean(self.hud(prior_gdk="0xe9", prior_ctx=OWNER))

    def test_a_skipped_restore(self):
        self.assert_diag(self.hud(restore=False), "RESTORE_MISSED")

    def test_a_skipped_clear_with_no_prior(self):
        self.assert_diag(self.hud(prior_gdk="0", prior_ctx="0", restore=False), "RESTORE_MISSED")

    def test_an_owner_ref_never_released(self):
        self.assert_diag(self.hud(unref_owner=False), "REF_IMBALANCE")

    def test_a_surface_live_at_end_holds_its_owner(self):
        self.assert_clean(clean_log(extra=new("0xdb", OWNER, "0xea")))

    def test_an_extra_ref_beside_a_live_surface(self):
        self.assert_diag(clean_log(extra=[*new("0xdb", OWNER, "0xea"), host("ref", OWNER, arg="0xea")]), "REF_IMBALANCE")

    def test_free_without_making_the_owner_current(self):
        lines = clean_log({"hud": [*new("0xda", OWNER, "0xe9"), "MARK hud begin",
                                   rec("FREE_BEGIN surface=0xda", OWNER), rec("FREE_END surface=0xda", OWNER),
                                   "MARK hud end"]})
        self.assert_diag(lines, "HOST_ORDER")

    def test_a_dead_prior_ending_with_no_context_and_its_log_line(self):
        restored = free("0xda", "0xe9", OWNER)
        dead = []
        for line in restored[restored.index(rec("FREE_END surface=0xda", OWNER)):]:
            dead.append(line.replace(f"ctx={GTK}", "ctx=0") if "make_current" in line or "get_current" in line else line)
        lines = clean_log({"hud": [*new("0xda", OWNER, "0xe9"), "MARK hud begin",
                                   *restored[:restored.index(rec("FREE_END surface=0xda", OWNER))], *dead,
                                   "MARK hud end"]})
        status, diags, _ = analyze(lines, [f"{PREFIX} restore failed\n"])
        self.assertEqual(1, status)
        self.assertIn("DEGRADED_LOG", [row[0] for row in diags])
        self.assertIn("RESTORE_MISSED", [row[0] for row in diags])

    def test_a_prefixed_line_alone_fails_a_clean_log(self):
        self.assert_diag(clean_log(), "DEGRADED_LOG", stderr=[f"{PREFIX} possible GPU leak\n"])

    def test_an_egl_owner_under_require_api_glx(self):
        self.assert_diag(clean_log(), "OWNER_API", require_api="glx")


class Seeds(Case):
    def test_a_seed_gone_before_its_target_free(self):
        block = [*seeded_surface(), rec("DRAW_BEGIN surface=0xc0", OWNER),
                 ghostty("GL_DELETE kind=texture name=82 err=0x0", OWNER), rec("DRAW_END surface=0xc0", OWNER),
                 "MARK session-background begin",
                 *free("0xc0", "0xe0", OWNER, (("texture", 81), ("sampler", 71))), "MARK session-background end"]
        self.assert_diag(clean_log({"session-background": block}), "SEED_GONE_BEFORE_FREE")

    def test_a_seed_never_uploaded(self):
        lines = [line for line in clean_log() if "width=37" not in line]
        self.assert_diag(lines, "SEED_NOT_UPLOADED")

    def test_a_seed_uploaded_outside_a_draw(self):
        lines = [line.replace("DRAW_BEGIN surface=0xc0", "NEW_BEGIN").replace("DRAW_END surface=0xc0", "NEW_END surface=0")
                 for line in clean_log()]
        self.assert_diag(lines, "SEED_NOT_UPLOADED")

    def test_a_shader_sampler_created_on_first_draw(self):
        # Ghostty 1.4 creates GPU state lazily in its owner's first draw.
        lines = clean_log()
        sampler = next(line for line in lines if "GL_CREATE kind=sampler name=71" in line)
        lines.remove(sampler)
        drawn = next(index for index, line in enumerate(lines) if "DRAW_BEGIN surface=0xc0" in line)
        lines.insert(drawn + 1, sampler)
        self.assert_clean(lines)

    def test_a_missing_shader_sampler(self):
        block = [*seeded_surface(sampler=False), "MARK session-background begin",
                 *free("0xc0", "0xe0", OWNER, SEED_DELETES[:2]), "MARK session-background end"]
        self.assert_diag(clean_log({"session-background": block}), "SEED_NOT_UPLOADED")


class Baseline(Case):
    def baseline_log(self):
        def unfixed(name, surface, context):
            return [*new(surface, OWNER, "0xe9", [("texture", 5)]), f"MARK {name} begin",
                    rec(f"FREE_BEGIN surface={surface}", context),
                    ghostty("GL_DELETE kind=texture name=5 err=0x0", context),
                    rec(f"FREE_END surface={surface}", context), f"MARK {name} end"]
        return clean_log({
            "session-selected": unfixed("session-selected", "0xda", GTK),
            "quick-exit": unfixed("quick-exit", "0xdb", "0"),
            "restart": [*new("0xd9", SIBLING, "0xe8"), *unfixed("restart", "0xdc", SIBLING)]})

    def test_expected_codes_pass(self):
        status, diags, _ = analyze(self.baseline_log(), [], baseline=True)
        self.assertEqual(0, status, diags)
        self.assertTrue(all(expected in {(row[0], row[1]) for row in diags} for expected in BASELINE_EXPECTED))

    def test_the_same_log_fails_outside_baseline(self):
        self.assert_diag(self.baseline_log(), "DELETE_FOREIGN_CONTEXT")

    def test_a_missing_expected_code_fails(self):
        self.assertEqual(1, analyze(clean_log(), [], baseline=True)[0])

    def test_a_harness_fault_fails(self):
        self.assert_diag(self.baseline_log()[:-1], "LOG_TRUNCATED", baseline=True)


if __name__ == "__main__":
    unittest.main()
