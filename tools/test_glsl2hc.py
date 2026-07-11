#!/usr/bin/env python3
"""Unit tests for tools/glsl2hc.py (no VM needed).

Usage:  python3 tools/test_glsl2hc.py [-v]
Exit codes: 0 all tests pass, 1 failures (unittest.main semantics).
"""
import os
import re
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import glsl2hc
from glsl2hc import GlslError, lex, transpile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
FIXTURES = os.path.join(REPO, "tests", "glsl")

MAIN_WRAP = ("void mainImage(out vec4 fragColor, in vec2 fragCoord) {\n"
             "%s\n"
             "}\n")


def t(body_or_src, wrap=True, runner="none", scale=4):
    """Transpile a mainImage body (wrap=True) or a whole shader."""
    src = MAIN_WRAP % body_or_src if wrap else body_or_src
    return transpile(src, filename="test.glsl", runner=runner, scale=scale)


def fails(testcase, src, msg_part, wrap=True):
    with testcase.assertRaises(GlslError) as cm:
        t(src, wrap=wrap)
    testcase.assertIn(msg_part, cm.exception.msg)
    testcase.assertGreaterEqual(cm.exception.line, 1)
    return cm.exception


class TestLexer(unittest.TestCase):
    def test_swizzle_tokens(self):
        toks = lex("p.xy")
        self.assertEqual([(k.kind, k.text) for k in toks[:-1]],
                         [("ident", "p"), ("op", "."), ("ident", "xy")])

    def test_float_literal_forms(self):
        toks = lex("1.0 1. .5 2e3 4")
        kinds = [k.kind for k in toks[:-1]]
        self.assertEqual(kinds, ["float", "float", "float", "float", "int"])

    def test_line_numbers_across_comments(self):
        toks = lex("// c1\n/* c2\nc3 */\nfoo")
        self.assertEqual(toks[0].kind, "ident")
        self.assertEqual(toks[0].line, 4)

    def test_non_ascii_rejected_with_line(self):
        with self.assertRaises(GlslError) as cm:
            lex("float a;\nfloat b = 3.14; // \xcf\x80\n")
        self.assertEqual(cm.exception.line, 2)
        self.assertIn("non-ASCII", cm.exception.msg)

    def test_float_dot_swizzle_is_invalid(self):
        # '1.x' lexes as FLOAT('1.') IDENT('x') and must not parse
        with self.assertRaises(GlslError):
            t("float a = 1.x;")


class TestParserAcceptance(unittest.TestCase):
    def test_full_construct_shader(self):
        out = t("""
            float acc(float x) {
                float s = 0.0;
                int i;
                for (i = 0; i < 3; i++) {
                    if (x > 0.5) { s += x; } else s -= x;
                }
                while (s > 10.0) { s = s - 1.0; break; }
                return s;
            }
            void mainImage(out vec4 fragColor, in vec2 fragCoord) {
                fragColor = vec4(acc(fragCoord.x));
                return;
            }
        """, wrap=False)
        self.assertIn("U0 MainImage(CHtUniforms *u", out)
        self.assertIn("F64 acc(F64 x)", out)
        self.assertIn("goto ht_done;", out)
        self.assertIn("ht_done:;", out)

    def test_parse_error_carries_line(self):
        e = fails(self, "void mainImage(out vec4 c, in vec2 p) {\n"
                        "  float a = 1.0\n"
                        "  a = 2.0;\n"
                        "}\n", "expected", wrap=False)
        self.assertEqual(e.line, 3)


class TestRejection(unittest.TestCase):
    def test_arrays(self):
        fails(self, "float a[3];", "arrays are not supported")

    def test_array_indexing(self):
        fails(self, "float a = fragCoord[0];", "array indexing")

    def test_texture2D_unknown(self):
        fails(self, "vec4 c = texture2D(ch0, fragCoord);", "unknown function")

    def test_mat2_deferred(self):
        fails(self, "mat2 m;", "mat2")

    def test_sampler_out_of_subset(self):
        e = fails(self, "void mainImage(out vec4 c, in vec2 p) { c = vec4(0.0); }\n"
                        "sampler2D tex;", "outside the supported", wrap=False)
        self.assertEqual(e.line, 2)

    def test_ternary(self):
        fails(self, "float a = true ? 1.0 : 2.0;", "ternary")

    def test_continue(self):
        fails(self, "for (int i = 0; i < 3; i++) { continue; }", "continue")

    def test_struct(self):
        fails(self, "struct S { float x; };", "struct", wrap=False)

    def test_preprocessor(self):
        fails(self, "#define FOO 1\n", "preprocessor", wrap=False)

    def test_out_param_in_user_function(self):
        fails(self, "void f(out float x) { x = 1.0; }\n"
                    "void mainImage(out vec4 c, in vec2 p) { c = vec4(0.0); }",
              "only supported on", wrap=False)

    def test_missing_mainImage(self):
        fails(self, "float f(float x) { return x; }", "no 'void mainImage",
              wrap=False)

    def test_assign_float_to_int(self):
        fails(self, "int i = 1.5;", "cannot initialize")

    def test_vec_size_mismatch(self):
        fails(self, "vec2 a = vec2(0.0); vec3 b = a;", "cannot initialize")

    def test_uniform_write_rejected(self):
        fails(self, "iTime = 1.0;", "read-only")

    def test_swizzle_repeat_on_lhs(self):
        fails(self, "vec2 p = vec2(0.0); p.xx = p;", "repeats a component")

    def test_bitwise_rejected(self):
        fails(self, "int a = 1 & 2;", "not supported")

    def test_global_variable_rejected(self):
        fails(self, "float g = 1.0;\n"
                    "void mainImage(out vec4 c, in vec2 p) { c = vec4(g); }",
              "global variables", wrap=False)


class TestEmitter(unittest.TestCase):
    def fixture(self, name):
        with open(os.path.join(FIXTURES, name), encoding="ascii") as f:
            return f.read()

    def test_fixtures_transpile_ascii_with_abi(self):
        for name in ("gradient.glsl", "circle.glsl", "plasma.glsl"):
            for runner in ("none", "static"):
                out = transpile(self.fixture(name), filename=name,
                                runner=runner)
                self.assertTrue(all(ord(c) < 128 for c in out), name)
                self.assertIn("U0 MainImage(CHtUniforms *u,I64 x,I64 y,"
                              "U8 *out_color)", out)

    def test_gradient_expressions(self):
        out = transpile(self.fixture("gradient.glsl"), runner="none")
        # fragCoord.y / iResolution.y with Shadertoy bottom-left origin
        self.assertIn("=u->res_y-y-0.5;", out)
        self.assertIn("/ht_iRes_y)", out)
        # luminance quantization to the 16-entry palette
        self.assertIn("ht_lum=Clamp(0.299*", out)
        self.assertIn("*out_color=ClampI64(ToI64(ht_lum*16.0),0,15);", out)

    def test_circle_length_and_step(self):
        out = transpile(self.fixture("circle.glsl"), runner="none")
        self.assertIn("Sqrt(", out)      # length() scalarized
        self.assertIn("HtStep(", out)    # step() helper call
        self.assertIn("F64 HtStep(F64 e,F64 x)", out)

    def test_plasma_constructs(self):
        out = transpile(self.fixture("plasma.glsl"), runner="none")
        self.assertIn("F64 wave(F64 p_x,F64 p_y,F64 t)", out)
        self.assertIn("for (i=0;(i<4);i++) {", out)
        self.assertIn("ToF64(i)", out)   # float(i)
        self.assertIn("I64 i;", out)     # int loop var is I64
        self.assertIn("Sin(", out)

    def test_swizzle_assign_aliasing_uses_temps(self):
        out = t("vec2 p = fragCoord; p.xy = p.yx; fragColor = vec4(p, 0.0, 1.0);")
        # the store must go through temps: ht_N=p_y; ht_M=p_x; p_x=ht_N; p_y=ht_M;
        m = re.search(r"(ht_\d+)=p_y;\n\s*(ht_\d+)=p_x;\n\s*p_x=\1;\n\s*p_y=\2;",
                      out)
        self.assertIsNotNone(m, out)

    def test_vec_assign_no_alias_is_direct(self):
        out = t("vec2 p = fragCoord; vec2 q = vec2(0.0); q = p;")
        self.assertIn("q_x=p_x;", out)
        self.assertIn("q_y=p_y;", out)

    def test_runner_none_has_no_runner(self):
        out = transpile(self.fixture("gradient.glsl"), runner="none")
        self.assertNotIn("GrPaletteColorSet", out)
        self.assertNotIn("draw_it", out)
        self.assertNotIn("HT_SCALE", out)

    def test_runner_static_contents_and_scale(self):
        out = transpile(self.fixture("gradient.glsl"), runner="static", scale=4)
        self.assertIn("#define HT_SCALE 4", out)
        self.assertIn("GrPaletteColorSet(i,bgr);", out)
        self.assertIn("Fs->draw_it=&HtDrawIt;", out)
        self.assertIn("MainImage(&u,cx*HT_SCALE,cy*HT_SCALE,&c);", out)
        out8 = transpile(self.fixture("gradient.glsl"), runner="static", scale=8)
        self.assertIn("#define HT_SCALE 8", out8)

    def test_helpers_emitted_only_when_used(self):
        out = transpile(self.fixture("gradient.glsl"), runner="none")
        self.assertNotIn("HtFract", out)
        self.assertNotIn("HtMod", out)
        out2 = t("fragColor = vec4(fract(fragCoord.x));")
        self.assertIn("F64 HtFract(F64 x)", out2)

    def test_mod_glsl_floor_semantics(self):
        out = t("fragColor = vec4(mod(fragCoord.x, 3.0));")
        self.assertIn("a-b*Floor(a/b)", out)
        self.assertIn("HtMod(", out)

    def test_atan_two_arg_maps_to_Arg_swapped(self):
        out = t("vec2 p = fragCoord; float a = atan(p.y, p.x); "
                "fragColor = vec4(a);")
        self.assertIn("Arg(p_x,p_y)", out)

    def test_atan_one_arg(self):
        out = t("float a = atan(fragCoord.y); fragColor = vec4(a);")
        self.assertIn("ATan(", out)

    def test_vec_ctor_flattening(self):
        out = t("vec2 p = fragCoord; vec4 c = vec4(p, 0.0, 1.0); fragColor = c;")
        self.assertIn("c_x=p_x;", out)
        self.assertIn("c_w=1.0;", out)

    def test_vec_ctor_truncation(self):
        t("vec4 a = vec4(1.0); vec3 b = vec3(a); fragColor = vec4(b, 1.0);")

    def test_vec_ctor_arity_error(self):
        fails(self, "vec3 a = vec3(1.0, 2.0);", "components")

    def test_dot_cross_normalize(self):
        out = t("vec3 a = vec3(1.0, 0.0, 0.0); vec3 b = vec3(0.0, 1.0, 0.0);"
                "float d = dot(a, b); vec3 c = cross(a, b);"
                "vec3 n = normalize(c); fragColor = vec4(n, d);")
        self.assertIn("a_x*b_x+a_y*b_y+a_z*b_z", out)
        self.assertIn("Sqrt(", out)

    def test_min_max_clamp_int_variants(self):
        out = t("int a = min(1, 2); int b = max(3, 4); int c = clamp(a, 0, b);"
                "fragColor = vec4(float(c));")
        self.assertIn("MinI64(1,2)", out)
        self.assertIn("MaxI64(3,4)", out)
        self.assertIn("ClampI64(", out)

    def test_smoothstep_scalar_broadcast_over_vec(self):
        out = t("vec2 s = smoothstep(0.0, 1.0, fragCoord); "
                "fragColor = vec4(s, 0.0, 1.0);")
        self.assertIn("HtSmooth(0.0,1.0,", out)

    def test_uniform_names_do_not_leak_raw(self):
        out = t("fragColor = vec4(iTime, float(iFrame), iMouse.x, "
                "iResolution.z);")
        self.assertIn("ht_iTime", out)
        self.assertIn("ht_iFrame", out)
        self.assertIn("ht_iMouse_x", out)
        self.assertIn("ht_iRes_z=1.0;", out)

    def test_reserved_name_collision_renamed(self):
        # 'pi' is a TempleOS #define; 'x'/'u' collide with MainImage params
        out = t("float pi = 3.0; float x = pi * 2.0; float u = x;"
                "fragColor = vec4(u);")
        self.assertIn("pi_2", out)
        self.assertNotIn("F64 pi;", out)
        self.assertNotIn("F64 pi,", out)
        self.assertIn("x_2", out)
        self.assertIn("u_2", out)

    def test_while_loop_emitted(self):
        out = t("float s = 0.0; while (s < 3.0) { s += 1.0; } "
                "fragColor = vec4(s);")
        self.assertIn("while ((s<3.0)) {", out)

    def test_chained_compare_impossible(self):
        # every comparison is parenthesized, so HolyC chaining can't trigger
        out = t("bool b = fragCoord.x < 1.0 && fragCoord.y < 2.0;"
                "if (b) fragColor = vec4(1.0);")
        m = re.search(r"b=\(\(.*<1\.0\)&&\(.*<2\.0\)\);", out)
        self.assertIsNotNone(m, out)


class TestCLI(unittest.TestCase):
    SCRIPT = os.path.join(HERE, "glsl2hc.py")

    def run_cli(self, *args):
        return subprocess.run([sys.executable, self.SCRIPT] + list(args),
                              capture_output=True, text=True)

    def test_exit_0_and_output_file(self):
        with tempfile.TemporaryDirectory() as td:
            out_path = os.path.join(td, "g.HC")
            r = self.run_cli(os.path.join(FIXTURES, "gradient.glsl"),
                             "-o", out_path)
            self.assertEqual(r.returncode, 0, r.stderr)
            with open(out_path, "rb") as f:
                data = f.read()
            self.assertTrue(all(b < 128 for b in data))

    def test_exit_1_with_file_line_diagnostic(self):
        with tempfile.TemporaryDirectory() as td:
            bad = os.path.join(td, "bad.glsl")
            with open(bad, "w") as f:
                f.write("void mainImage(out vec4 c, in vec2 p) {\n"
                        "  float a[3];\n"
                        "}\n")
            r = self.run_cli(bad)
            self.assertEqual(r.returncode, 1)
            self.assertIn("%s:2: " % bad, r.stderr)

    def test_exit_2_on_missing_file(self):
        r = self.run_cli("/nonexistent/nope.glsl")
        self.assertEqual(r.returncode, 2)

    def test_exit_2_on_bad_usage(self):
        r = self.run_cli()
        self.assertEqual(r.returncode, 2)


if __name__ == "__main__":
    unittest.main()
