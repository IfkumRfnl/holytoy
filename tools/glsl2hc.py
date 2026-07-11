#!/usr/bin/env python3
"""GLSL (Shadertoy subset) -> HolyC transpiler for holytoy.

Host-side development vehicle for VISION step 3: transpiles the deliberately
small GLSL subset (docs/VISION.md:45-51) to HolyC targeting the shader ABI

  class CHtUniforms { F64 i_time; I64 i_frame; I64 res_x,res_y; I64 mouse_x,mouse_y; };
  U0 MainImage(CHtUniforms *u, I64 x, I64 y, U8 *out_color);  // one pixel

Usage:
  glsl2hc.py IN.glsl [-o OUT.HC] [--runner static|none] [--scale N]

  --runner static  (default) append a standalone one-frame proof harness:
                   16-step grayscale palette, evaluate MainImage once per
                   SCALExSCALE block, map fragColor to the palette by
                   luminance (0.299r+0.587g+0.114b -> 0..15).
  --runner none    emit only the preamble, user functions and MainImage
                   (what an app would inject).
  --scale N        static runner block size (default 4 -> 160x120 evals).

Exit codes:
  0  success
  1  transpile error ("file:line: message" on stderr)
  2  usage or I/O error

Deliberate semantic deviations from GLSL/Shadertoy (v0):
  * All math is F64 (GLSL precision qualifiers would be rejected as
    out-of-subset; fixed-point belongs to plan 003).
  * fragCoord matches gl_FragCoord: origin bottom-left, pixel centers at
    +0.5 -- the emitter flips TempleOS's top-down y.
  * Implicit int->float promotion is allowed in arithmetic, calls and
    assignment-to-float (strict GLSL ES forbids it).
  * Uniforms are exactly iTime (float), iResolution (vec3, z=1.0),
    iMouse (vec4, zw=0.0), iFrame (int); the static runner supplies
    iTime=0.0, iFrame=0, iMouse=(0,0,0,0).
  * mod() uses GLSL floor semantics: x - y*Floor(x/y).
  * The static runner quantizes to a 16-gray palette by luminance.
  * Out-of-subset input is rejected with a diagnostic -- a wrong-answer
    transpile is worse than an error.
"""
import argparse
import re
import sys

# ---------------------------------------------------------------------------
# Diagnostics


class GlslError(Exception):
    """Transpile error carrying a 1-based source line number."""

    def __init__(self, line, msg):
        super().__init__(msg)
        self.line = line
        self.msg = msg


# ---------------------------------------------------------------------------
# Lexer

GLSL_KEYWORDS = {
    "if", "else", "for", "while", "return", "break", "continue", "discard",
    "true", "false", "const", "in", "out", "inout", "uniform", "struct",
    "precision", "void",
}
TYPE_NAMES = {"float", "int", "bool", "vec2", "vec3", "vec4"}
# Recognized so we can reject them with a specific message instead of a
# generic parse error.
UNSUPPORTED_TYPES = {
    "mat2", "mat3", "mat4", "uint", "double", "sampler2D", "samplerCube",
    "ivec2", "ivec3", "ivec4", "bvec2", "bvec3", "bvec4", "uvec2", "uvec3",
    "uvec4",
}

_TOKEN_RE = re.compile(r"""
    (?P<ws>[ \t\r]+)
  | (?P<nl>\n)
  | (?P<lc>//[^\n]*)
  | (?P<bc>/\*)
  | (?P<float>(\d+\.\d*|\.\d+)([eE][+-]?\d+)?|\d+[eE][+-]?\d+)
  | (?P<int>0[xX][0-9a-fA-F]+|\d+)
  | (?P<ident>[A-Za-z_]\w*)
  | (?P<op>\+\+|--|<=|>=|==|!=|&&|\|\||\^\^|\+=|-=|\*=|/=
      |[-+*/%<>=!.,;(){}?:\[\]\#&|^~])
""", re.VERBOSE)


class Tok:
    __slots__ = ("kind", "text", "line")

    def __init__(self, kind, text, line):
        self.kind = kind      # 'float','int','ident','kw','op','eof'
        self.text = text
        self.line = line

    def __repr__(self):
        return "Tok(%r,%r,%d)" % (self.kind, self.text, self.line)


def lex(src):
    # Pure-ASCII source is a hard rule (TempleOS charset trap): reject
    # non-ASCII anywhere, comments included.
    for lineno, text in enumerate(src.split("\n"), 1):
        for ch in text:
            if ord(ch) > 127:
                raise GlslError(lineno,
                                "non-ASCII character %r in source" % ch)
    toks = []
    line = 1
    pos = 0
    n = len(src)
    while pos < n:
        ch = src[pos]
        m = _TOKEN_RE.match(src, pos)
        if not m:
            raise GlslError(line, "unexpected character %r" % ch)
        kind = m.lastgroup
        text = m.group()
        if kind == "bc":  # block comment: scan to */
            end = src.find("*/", pos + 2)
            if end < 0:
                raise GlslError(line, "unterminated block comment")
            line += src.count("\n", pos, end)
            pos = end + 2
            continue
        pos = m.end()
        if kind == "ws" or kind == "lc":
            continue
        if kind == "nl":
            line += 1
            continue
        if kind == "ident":
            if any(ord(c) > 127 for c in text):
                raise GlslError(line, "non-ASCII identifier %r" % text)
            if text in GLSL_KEYWORDS:
                toks.append(Tok("kw", text, line))
            else:
                toks.append(Tok("ident", text, line))
        else:
            toks.append(Tok(kind, text, line))
    toks.append(Tok("eof", "", line))
    return toks


# ---------------------------------------------------------------------------
# AST


class Node:
    """Generic AST node: kind + line + keyword attributes."""

    def __init__(self, kind, line, **kw):
        self.kind = kind
        self.line = line
        for k, v in kw.items():
            setattr(self, k, v)

    def __repr__(self):
        return "Node(%s)" % self.kind


# ---------------------------------------------------------------------------
# Parser (recursive descent)


class Parser:
    def __init__(self, toks):
        self.toks = toks
        self.i = 0

    # -- token helpers ------------------------------------------------------
    def peek(self, ahead=0):
        return self.toks[min(self.i + ahead, len(self.toks) - 1)]

    def next(self):
        t = self.toks[self.i]
        if t.kind != "eof":
            self.i += 1
        return t

    def at(self, kind, text=None):
        t = self.peek()
        return t.kind == kind and (text is None or t.text == text)

    def expect(self, kind, text=None, what=None):
        t = self.peek()
        if not self.at(kind, text):
            want = what or (text if text is not None else kind)
            raise GlslError(t.line, "expected %r, found %r" % (want, t.text or "<eof>"))
        return self.next()

    def err(self, msg, tok=None):
        raise GlslError((tok or self.peek()).line, msg)

    # -- types --------------------------------------------------------------
    def is_type_start(self):
        t = self.peek()
        if t.kind == "kw" and t.text == "void":
            return True
        if t.kind == "ident" and (t.text in TYPE_NAMES or t.text in UNSUPPORTED_TYPES):
            return True
        return False

    def parse_type(self):
        t = self.peek()
        if t.kind == "kw" and t.text == "void":
            self.next()
            return "void"
        if t.kind == "ident" and t.text in UNSUPPORTED_TYPES:
            if t.text == "mat2":
                self.err("type 'mat2' is deferred in glsl2hc v0 (see docs/notes/glsl2hc.md)")
            self.err("type %r is outside the supported GLSL subset" % t.text)
        if t.kind == "ident" and t.text in TYPE_NAMES:
            self.next()
            return t.text
        self.err("expected a type, found %r" % (t.text or "<eof>"))

    # -- top level ----------------------------------------------------------
    def parse_program(self):
        fns = []
        while not self.at("eof"):
            t = self.peek()
            if t.kind == "op" and t.text == "#":
                self.err("preprocessor directives are not supported (out of subset)")
            if t.kind == "kw" and t.text == "struct":
                self.err("'struct' is outside the supported GLSL subset")
            if t.kind == "kw" and t.text == "precision":
                self.err("precision qualifiers are not supported (all math is F64)")
            if t.kind == "kw" and t.text == "uniform":
                self.err("uniform declarations are not supported; "
                         "use the built-in Shadertoy uniforms")
            if t.kind == "kw" and t.text == "const":
                self.err("global variables are not supported in v0 "
                         "(move the constant into a function)")
            line = t.line
            ret = self.parse_type()
            name = self.expect("ident", what="function name").text
            if not self.at("op", "("):
                self.err("global variables are not supported in v0 "
                         "(only function definitions at top level)")
            self.next()
            params = self.parse_params()
            body = self.parse_block()
            fns.append(Node("func", line, ret=ret, name=name, params=params,
                            body=body))
        return fns

    def parse_params(self):
        params = []
        if self.at("op", ")"):
            self.next()
            return params
        if self.at("kw", "void") and self.peek(1).kind == "op" and self.peek(1).text == ")":
            self.next()
            self.next()
            return params
        while True:
            qual = "in"
            while self.peek().kind == "kw" and self.peek().text in ("in", "out", "inout", "const"):
                q = self.next().text
                if q in ("in", "out", "inout"):
                    qual = q
            line = self.peek().line
            gtype = self.parse_type()
            if gtype == "void":
                self.err("'void' is not a parameter type")
            pname = self.expect("ident", what="parameter name").text
            if self.at("op", "["):
                self.err("arrays are not supported (out of GLSL subset)")
            params.append(Node("param", line, qual=qual, gtype=gtype, name=pname))
            if self.at("op", ","):
                self.next()
                continue
            self.expect("op", ")")
            return params

    # -- statements ---------------------------------------------------------
    def parse_block(self):
        lb = self.expect("op", "{")
        stmts = []
        while not self.at("op", "}"):
            if self.at("eof"):
                raise GlslError(lb.line, "unterminated block (missing '}')")
            stmts.append(self.parse_stmt())
        self.next()
        return Node("block", lb.line, stmts=stmts)

    def parse_stmt(self):
        t = self.peek()
        if t.kind == "op" and t.text == "{":
            return self.parse_block()
        if t.kind == "op" and t.text == ";":
            self.next()
            return Node("empty", t.line)
        if t.kind == "op" and t.text == "#":
            self.err("preprocessor directives are not supported (out of subset)")
        if t.kind == "kw":
            if t.text == "if":
                return self.parse_if()
            if t.text == "for":
                return self.parse_for()
            if t.text == "while":
                return self.parse_while()
            if t.text == "return":
                self.next()
                expr = None
                if not self.at("op", ";"):
                    expr = self.parse_expr()
                self.expect("op", ";")
                return Node("return", t.line, expr=expr)
            if t.text == "break":
                self.next()
                self.expect("op", ";")
                return Node("break", t.line)
            if t.text == "continue":
                self.err("'continue' is not supported (HolyC has no continue; "
                         "restructure the loop)")
            if t.text == "discard":
                self.err("'discard' is not supported (out of GLSL subset)")
            if t.text == "struct":
                self.err("'struct' is outside the supported GLSL subset")
            if t.text == "const":
                self.next()
                return self.parse_decl()
        if self.is_type_start():
            return self.parse_decl()
        expr = self.parse_expr()
        self.expect("op", ";")
        return Node("exprstmt", t.line, expr=expr)

    def parse_decl(self):
        line = self.peek().line
        gtype = self.parse_type()
        if gtype == "void":
            self.err("cannot declare a variable of type 'void'")
        decls = []
        while True:
            name_t = self.expect("ident", what="variable name")
            if self.at("op", "["):
                self.err("arrays are not supported (out of GLSL subset)")
            init = None
            if self.at("op", "="):
                self.next()
                init = self.parse_assign()
            decls.append((name_t.text, init, name_t.line))
            if self.at("op", ","):
                self.next()
                continue
            self.expect("op", ";")
            return Node("decl", line, gtype=gtype, decls=decls)

    def parse_if(self):
        t = self.expect("kw", "if")
        self.expect("op", "(")
        cond = self.parse_expr()
        self.expect("op", ")")
        then = self.parse_stmt()
        els = None
        if self.at("kw", "else"):
            self.next()
            els = self.parse_stmt()
        return Node("if", t.line, cond=cond, then=then, els=els)

    def parse_while(self):
        t = self.expect("kw", "while")
        self.expect("op", "(")
        cond = self.parse_expr()
        self.expect("op", ")")
        body = self.parse_stmt()
        return Node("while", t.line, cond=cond, body=body)

    def parse_for(self):
        t = self.expect("kw", "for")
        self.expect("op", "(")
        if self.at("op", ";"):
            init = None
            self.next()
        elif self.is_type_start() or self.at("kw", "const"):
            if self.at("kw", "const"):
                self.next()
            init = self.parse_decl()
        else:
            e = self.parse_expr()
            self.expect("op", ";")
            init = Node("exprstmt", t.line, expr=e)
        cond = None
        if not self.at("op", ";"):
            cond = self.parse_expr()
        self.expect("op", ";")
        inc = None
        if not self.at("op", ")"):
            inc = self.parse_expr()
        self.expect("op", ")")
        body = self.parse_stmt()
        return Node("for", t.line, init=init, cond=cond, inc=inc, body=body)

    # -- expressions ---------------------------------------------------------
    def parse_expr(self):
        return self.parse_assign()

    ASSIGN_OPS = {"=", "+=", "-=", "*=", "/="}

    def parse_assign(self):
        lhs = self.parse_or()
        t = self.peek()
        if t.kind == "op" and t.text in self.ASSIGN_OPS:
            self.next()
            rhs = self.parse_assign()
            return Node("assign", t.line, op=t.text, lhs=lhs, rhs=rhs)
        if t.kind == "op" and t.text == "?":
            self.err("the ternary operator '?:' is not supported "
                     "(out of subset; use if/else)")
        if t.kind == "op" and t.text in ("&", "|", "^", "~"):
            self.err("bitwise operator %r is not supported (out of subset)"
                     % t.text)
        return lhs

    def _binop_level(self, sub, ops):
        node = sub()
        while True:
            t = self.peek()
            if t.kind == "op" and t.text in ops:
                self.next()
                rhs = sub()
                node = Node("binary", t.line, op=t.text, lhs=node, rhs=rhs)
            else:
                return node

    def parse_or(self):
        node = self._binop_level(self.parse_and, {"||"})
        if self.at("op", "^^"):
            self.err("logical XOR '^^' is not supported (out of subset)")
        return node

    def parse_and(self):
        return self._binop_level(self.parse_equality, {"&&"})

    def parse_equality(self):
        return self._binop_level(self.parse_relational, {"==", "!="})

    def parse_relational(self):
        return self._binop_level(self.parse_additive, {"<", ">", "<=", ">="})

    def parse_additive(self):
        return self._binop_level(self.parse_multiplicative, {"+", "-"})

    def parse_multiplicative(self):
        return self._binop_level(self.parse_unary, {"*", "/", "%"})

    def parse_unary(self):
        t = self.peek()
        if t.kind == "op" and t.text in ("-", "+", "!"):
            self.next()
            return Node("unary", t.line, op=t.text, expr=self.parse_unary())
        if t.kind == "op" and t.text in ("++", "--"):
            self.next()
            target = self.parse_unary()
            return Node("incdec", t.line, op=t.text, target=target, prefix=True)
        if t.kind == "op" and t.text in ("&", "|", "^", "~"):
            self.err("bitwise operator %r is not supported (out of subset)" % t.text)
        return self.parse_postfix()

    def parse_postfix(self):
        node = self.parse_primary()
        while True:
            t = self.peek()
            if t.kind == "op" and t.text == ".":
                self.next()
                mem = self.expect("ident", what="swizzle component").text
                node = Node("swizzle", t.line, base=node, sw=mem)
            elif t.kind == "op" and t.text in ("++", "--"):
                self.next()
                node = Node("incdec", t.line, op=t.text, target=node, prefix=False)
            elif t.kind == "op" and t.text == "[":
                self.err("array indexing is not supported (out of GLSL subset)")
            else:
                return node

    def parse_primary(self):
        t = self.peek()
        if t.kind == "float":
            self.next()
            return Node("num_float", t.line, text=t.text)
        if t.kind == "int":
            self.next()
            return Node("num_int", t.line, text=t.text)
        if t.kind == "kw" and t.text in ("true", "false"):
            self.next()
            return Node("bool_lit", t.line, value=(t.text == "true"))
        if t.kind == "op" and t.text == "(":
            self.next()
            e = self.parse_expr()
            self.expect("op", ")")
            return e
        if t.kind == "ident" and t.text in UNSUPPORTED_TYPES:
            if t.text == "mat2":
                self.err("type 'mat2' is deferred in glsl2hc v0 (see docs/notes/glsl2hc.md)")
            self.err("type %r is outside the supported GLSL subset" % t.text)
        if t.kind == "ident":
            self.next()
            if self.at("op", "("):
                self.next()
                args = []
                if not self.at("op", ")"):
                    while True:
                        args.append(self.parse_assign())
                        if self.at("op", ","):
                            self.next()
                            continue
                        break
                self.expect("op", ")")
                return Node("call", t.line, name=t.text, args=args)
            return Node("var", t.line, name=t.text)
        self.err("unexpected %r in expression" % (t.text or "<eof>"))


# ---------------------------------------------------------------------------
# Code generation

SCALAR_TYPES = {"float", "int", "bool"}
VEC_SIZES = {"vec2": 2, "vec3": 3, "vec4": 4}
COMP_SUFFIX = ("x", "y", "z", "w")
SWIZZLE_SETS = ({"x": 0, "y": 1, "z": 2, "w": 3},
                {"r": 0, "g": 1, "b": 2, "a": 3},
                {"s": 0, "t": 1, "p": 2, "q": 3})
HOLYC_TYPE = {"float": "F64", "int": "I64", "bool": "Bool"}

_SIMPLE_RE = re.compile(r"[A-Za-z_]\w*(_[xyzw])?\Z")
_INT_LIT_RE = re.compile(r"\d+\Z")
_NUM_LIT_RE = re.compile(r"(\d+(\.\d*)?|\.\d+)\Z")

# HolyC names the emitted code must never shadow (keywords, types, defines,
# kernel symbols we call, and the emitter's own definitions).
HOLYC_RESERVED = set("""
include define union catch class try if else for while extern _extern return
sizeof _intern do asm goto exe break switch start end case default public
offset import _import ifdef ifndef ifaot ifjit endif assert reg noreg
lastclass no_warn help_index help_file static lock defined interrupt
haserrcode argpop noargpop
U0 I8 U8 I16 U16 I32 U32 I64 U64 F64 Bool
TRUE FALSE NULL ON OFF pi Fs tS argc argv
COLORS_NUM GR_WIDTH GR_HEIGHT TRANSPARENT
Sin Cos Tan ATan Arg Sqrt Pow Exp Ln Log2 Log10 Floor Ceil Round Trunc
Abs Sign Min Max Clamp ToI64 ToF64 ToBool AbsI64 SignI64 MinI64 MaxI64
ClampI64 SqrI64 MAlloc Free MemSet MemCpy GrPaletteColorSet Sleep Print
Rand Seed Reboot
MainImage CHtUniforms CBGR48 CDC CTask
HtGrayPalette HtRenderStatic HtDrawIt HtFract HtMod HtMix HtStep HtSmooth
HT_SCALE
""".split())

HELPER_DEFS = {
    "HtFract": ("F64 HtFract(F64 x)\n"
                "{\n"
                "  return x-Floor(x);\n"
                "}\n"),
    "HtMod": ("F64 HtMod(F64 a,F64 b)\n"
              "{//GLSL mod(): floor semantics, sign follows b.\n"
              "  return a-b*Floor(a/b);\n"
              "}\n"),
    "HtMix": ("F64 HtMix(F64 a,F64 b,F64 t)\n"
              "{\n"
              "  return a+(b-a)*t;\n"
              "}\n"),
    "HtStep": ("F64 HtStep(F64 e,F64 x)\n"
               "{\n"
               "  if (x<e)\n"
               "    return 0.0;\n"
               "  return 1.0;\n"
               "}\n"),
    "HtSmooth": ("F64 HtSmooth(F64 e0,F64 e1,F64 x)\n"
                 "{//GLSL smoothstep() incl. its clamp.\n"
                 "  F64 t=Clamp((x-e0)/(e1-e0),0.0,1.0);\n"
                 "  return t*t*(3.0-2.0*t);\n"
                 "}\n"),
}
HELPER_ORDER = ("HtFract", "HtMod", "HtMix", "HtStep", "HtSmooth")

UNIFORMS = {
    # glsl name -> (gtype, emitted component names)
    "iTime": ("float", ["ht_iTime"]),
    "iFrame": ("int", ["ht_iFrame"]),
    "iResolution": ("vec3", ["ht_iRes_x", "ht_iRes_y", "ht_iRes_z"]),
    "iMouse": ("vec4", ["ht_iMouse_x", "ht_iMouse_y", "ht_iMouse_z",
                        "ht_iMouse_w"]),
}


class Var:
    __slots__ = ("gtype", "comps", "readonly")

    def __init__(self, gtype, comps, readonly=False):
        self.gtype = gtype
        self.comps = comps
        self.readonly = readonly


class Func:
    __slots__ = ("gtype", "params", "emitted")

    def __init__(self, gtype, params, emitted):
        self.gtype = gtype
        self.params = params  # list of param Nodes
        self.emitted = emitted


def ncomps(gtype):
    return 1 if gtype in SCALAR_TYPES else VEC_SIZES[gtype]


def fmt_float(text):
    """Format a GLSL float literal as a HolyC F64 literal (no exponent)."""
    v = float(text)
    if v != v or v in (float("inf"), float("-inf")):
        raise ValueError("non-finite float literal")
    s = repr(v)
    if "e" in s or "E" in s:
        s = format(v, ".20f").rstrip("0")
        if s.endswith("."):
            s += "0"
    return s


class Emitter:
    def __init__(self, fns, runner="static", scale=4):
        self.fns = fns
        self.runner = runner
        self.scale = scale
        self.funcs = {}            # glsl name -> Func
        self.global_taken = set()  # emitted global names
        self.helpers_used = set()
        self.out_funcs = []        # emitted function texts, in order
        # per-function state
        self.taken = None
        self.decls = None          # list of (holyc type, name)
        self.body = None           # list of emitted lines
        self.indent = 0
        self.scopes = None
        self.tmp_n = 0
        self.cur_ret = None
        self.cur_ret_ptrs = None
        self.in_main = False
        self.main_done_used = False

    # -- names ---------------------------------------------------------------
    def claim(self, want, gtype, line):
        """Reserve emitted name(s) for a GLSL identifier in current scope."""
        base = want
        if base.startswith("ht_") or base.startswith("Ht"):
            base = "g_" + base
        n = ncomps(gtype)
        cand = base
        bump = 1
        while True:
            names = ([cand] if n == 1
                     else ["%s_%s" % (cand, COMP_SUFFIX[i]) for i in range(n)])
            if not any(x in HOLYC_RESERVED or x in self.taken
                       or x in self.global_taken for x in names):
                for x in names:
                    self.taken.add(x)
                return names
            bump += 1
            cand = "%s_%d" % (base, bump)

    def temp(self, ctype="F64"):
        name = "ht_%d" % self.tmp_n
        self.tmp_n += 1
        self.decls.append((ctype, name))
        return name

    def declare(self, ctype, name):
        self.decls.append((ctype, name))

    # -- statement output -----------------------------------------------------
    def put(self, text):
        self.body.append("  " * (self.indent + 1) + text)

    # -- scopes ----------------------------------------------------------------
    def lookup(self, name, line):
        for scope in reversed(self.scopes):
            if name in scope:
                return scope[name]
        raise GlslError(line, "unknown identifier %r" % name)

    def define_var(self, name, var, line):
        if name in self.scopes[-1]:
            raise GlslError(line, "redefinition of %r" % name)
        self.scopes[-1][name] = var

    # -- values ----------------------------------------------------------------
    def is_simple(self, expr):
        return bool(_SIMPLE_RE.match(expr) or _NUM_LIT_RE.match(expr))

    def mat_scalar(self, gtype, expr):
        """Materialize a scalar expression to a reusable simple name/literal."""
        if self.is_simple(expr):
            return expr
        t = self.temp(HOLYC_TYPE[gtype])
        self.put("%s=%s;" % (t, expr))
        return t

    def mat_vec(self, gtype, comp_exprs):
        """Materialize computed vector components into temps -> simple names."""
        out = []
        for e in comp_exprs:
            if self.is_simple(e):
                out.append(e)
            else:
                t = self.temp("F64")
                self.put("%s=%s;" % (t, e))
                out.append(t)
        return (gtype, out)

    def promote(self, val, line, want="float"):
        """int -> float promotion of a scalar value."""
        gtype, comps = val
        if gtype == want:
            return val
        if gtype == "int" and want == "float":
            e = comps[0]
            if _INT_LIT_RE.match(e):
                return ("float", [e + ".0"])
            return ("float", ["ToF64(%s)" % e])
        raise GlslError(line, "cannot convert %s to %s" % (gtype, want))

    # ==========================================================================
    # Expressions
    # ==========================================================================
    def gen_expr(self, node):
        m = getattr(self, "gen_" + node.kind, None)
        if m is None:
            raise GlslError(node.line, "unsupported construct %r" % node.kind)
        return m(node)

    def gen_num_float(self, node):
        try:
            return ("float", [fmt_float(node.text)])
        except ValueError:
            raise GlslError(node.line, "bad float literal %r" % node.text)

    def gen_num_int(self, node):
        if node.text.lower().startswith("0x"):
            return ("int", [node.text])
        return ("int", [str(int(node.text, 10))])

    def gen_bool_lit(self, node):
        return ("bool", ["TRUE" if node.value else "FALSE"])

    def gen_var(self, node):
        var = self.lookup(node.name, node.line)
        return (var.gtype, list(var.comps))

    def swizzle_indices(self, sw, size, line):
        for charset in SWIZZLE_SETS:
            if all(c in charset for c in sw):
                idx = [charset[c] for c in sw]
                if len(idx) < 1 or len(idx) > 4:
                    raise GlslError(line, "swizzle %r has bad length" % sw)
                if any(i >= size for i in idx):
                    raise GlslError(line, "swizzle %r out of range for vec%d"
                                    % (sw, size))
                return idx
        raise GlslError(line, "invalid swizzle %r" % sw)

    def gen_swizzle(self, node):
        gtype, comps = self.gen_expr(node.base)
        if gtype in SCALAR_TYPES:
            raise GlslError(node.line, "cannot swizzle a %s" % gtype)
        idx = self.swizzle_indices(node.sw, len(comps), node.line)
        picked = [comps[i] for i in idx]
        if len(picked) == 1:
            return ("float", picked)
        return ("vec%d" % len(picked), picked)

    def gen_unary(self, node):
        gtype, comps = self.gen_expr(node.expr)
        if node.op == "!":
            if gtype != "bool":
                raise GlslError(node.line, "'!' needs a bool operand, got %s" % gtype)
            return ("bool", ["(!%s)" % comps[0]])
        if gtype == "bool":
            raise GlslError(node.line, "unary %r on bool" % node.op)
        if node.op == "+":
            return (gtype, comps)
        if gtype in SCALAR_TYPES:
            return (gtype, ["(-%s)" % comps[0]])
        return self.mat_vec(gtype, ["(-%s)" % c for c in comps])

    def gen_binary(self, node):
        op = node.op
        lt, lc = lv = self.gen_expr(node.lhs)
        rt, rc = rv = self.gen_expr(node.rhs)
        line = node.line
        if op in ("&&", "||"):
            if lt != "bool" or rt != "bool":
                raise GlslError(line, "%r needs bool operands (got %s, %s)"
                                % (op, lt, rt))
            return ("bool", ["(%s%s%s)" % (lc[0], op, rc[0])])
        if op in ("==", "!="):
            if lt == rt and lt in ("bool", "int", "float"):
                return ("bool", ["(%s%s%s)" % (lc[0], op, rc[0])])
            if lt == rt and lt in VEC_SIZES:
                per = ["(%s%s%s)" % (a, op, b) for a, b in zip(lc, rc)]
                join = "&&" if op == "==" else "||"
                return ("bool", ["(%s)" % join.join(per)])
            if {lt, rt} <= {"int", "float"}:
                (_, lc), (_, rc) = (self.promote(lv, line), self.promote(rv, line))
                return ("bool", ["(%s%s%s)" % (lc[0], op, rc[0])])
            raise GlslError(line, "cannot compare %s with %s" % (lt, rt))
        if op in ("<", ">", "<=", ">="):
            if not ({lt, rt} <= {"int", "float"}):
                raise GlslError(line, "relational %r needs scalar numeric "
                                      "operands (got %s, %s)" % (op, lt, rt))
            if lt != rt:
                (_, lc) = self.promote(lv, line)
                (_, rc) = self.promote(rv, line)
            return ("bool", ["(%s%s%s)" % (lc[0], op, rc[0])])
        if op == "%":
            if lt == "int" and rt == "int":
                return ("int", ["(%s%%%s)" % (lc[0], rc[0])])
            raise GlslError(line, "'%%' is int-only; use mod() for floats")
        if op not in ("+", "-", "*", "/"):
            raise GlslError(line, "operator %r is not supported" % op)
        if "bool" in (lt, rt):
            raise GlslError(line, "arithmetic on bool")
        # scalar op scalar
        if lt in SCALAR_TYPES and rt in SCALAR_TYPES:
            if lt == "int" and rt == "int":
                return ("int", ["(%s%s%s)" % (lc[0], op, rc[0])])
            (_, lc) = self.promote(lv, line)
            (_, rc) = self.promote(rv, line)
            return ("float", ["(%s%s%s)" % (lc[0], op, rc[0])])
        # vec op vec (componentwise)
        if lt in VEC_SIZES and rt in VEC_SIZES:
            if lt != rt:
                raise GlslError(line, "componentwise %r needs equal vector "
                                      "sizes (got %s, %s)" % (op, lt, rt))
            return self.mat_vec(lt, ["(%s%s%s)" % (a, op, b)
                                     for a, b in zip(lc, rc)])
        # vec op scalar / scalar op vec (broadcast)
        if lt in VEC_SIZES:
            (_, rc) = self.promote(rv, line)
            s = self.mat_scalar("float", rc[0])
            return self.mat_vec(lt, ["(%s%s%s)" % (c, op, s) for c in lc])
        (_, lc) = self.promote(lv, line)
        s = self.mat_scalar("float", lc[0])
        return self.mat_vec(rt, ["(%s%s%s)" % (s, op, c) for c in rc])

    # -- calls: constructors, builtins, user functions -------------------------
    def gen_call(self, node):
        name = node.name
        if name in VEC_SIZES:
            return self.gen_vec_ctor(node)
        if name in ("float", "int", "bool"):
            return self.gen_scalar_ctor(node)
        if name in BUILTINS:
            return BUILTINS[name](self, node)
        if name in self.funcs:
            return self.gen_user_call(node)
        raise GlslError(node.line, "unknown function %r (not in the GLSL "
                                   "subset and not defined earlier)" % name)

    def gen_vec_ctor(self, node):
        size = VEC_SIZES[node.name]
        args = [self.gen_expr(a) for a in node.args]
        if not args:
            raise GlslError(node.line, "%s() needs arguments" % node.name)
        if len(args) == 1 and args[0][0] in SCALAR_TYPES:
            (_, c) = self.promote(args[0], node.line)
            s = self.mat_scalar("float", c[0])
            return ("vec%d" % size, [s] * size)
        if len(args) == 1 and args[0][0] in VEC_SIZES:
            comps = args[0][1]
            if len(comps) < size:
                raise GlslError(node.line, "%s(%s) needs at least %d components"
                                % (node.name, args[0][0], size))
            return ("vec%d" % size, comps[:size])
        comps = []
        for a in args:
            gtype, c = a
            if gtype in SCALAR_TYPES:
                (_, c) = self.promote(a, node.line)
                comps.append(self.mat_scalar("float", c[0]))
            else:
                comps.extend(c)
        if len(comps) != size:
            raise GlslError(node.line, "%s() got %d components, needs %d"
                            % (node.name, len(comps), size))
        return ("vec%d" % size, comps)

    def gen_scalar_ctor(self, node):
        if len(node.args) != 1:
            raise GlslError(node.line, "%s() takes one argument" % node.name)
        gtype, comps = self.gen_expr(node.args[0])
        if gtype not in SCALAR_TYPES:
            raise GlslError(node.line, "%s() of a %s is not supported"
                            % (node.name, gtype))
        e = comps[0]
        if node.name == "float":
            if gtype == "float":
                return ("float", [e])
            return self.promote((gtype, comps), node.line) if gtype == "int" \
                else ("float", ["ToF64(%s)" % e])
        if node.name == "int":
            if gtype == "int":
                return ("int", [e])
            if gtype == "float":
                return ("int", ["ToI64(%s)" % e])  # truncates, like GLSL
            return ("int", ["ToI64(%s)" % e])
        # bool()
        if gtype == "bool":
            return ("bool", [e])
        zero = "0.0" if gtype == "float" else "0"
        return ("bool", ["(%s!=%s)" % (e, zero)])

    def gen_user_call(self, node):
        fn = self.funcs[node.name]
        if len(node.args) != len(fn.params):
            raise GlslError(node.line, "%s() takes %d argument(s), got %d"
                            % (node.name, len(fn.params), len(node.args)))
        flat = []
        for p, a in zip(fn.params, node.args):
            val = self.gen_expr(a)
            gtype, comps = val
            if p.gtype == "float" and gtype == "int":
                gtype, comps = self.promote(val, node.line)
            if gtype != p.gtype:
                raise GlslError(node.line,
                                "argument %r of %s(): expected %s, got %s"
                                % (p.name, node.name, p.gtype, gtype))
            flat.extend(comps)
        if fn.gtype == "void":
            self.put("%s(%s);" % (fn.emitted, ",".join(flat)))
            return ("void", [])
        if fn.gtype in SCALAR_TYPES:
            return (fn.gtype, ["%s(%s)" % (fn.emitted, ",".join(flat))])
        # vec return: out-pointer protocol
        rets = [self.temp("F64") for _ in range(ncomps(fn.gtype))]
        args = ["&%s" % r for r in rets] + flat
        self.put("%s(%s);" % (fn.emitted, ",".join(args)))
        return (fn.gtype, rets)

    def gen_incdec(self, node):
        # only as a statement / for-increment (checked by caller context: the
        # value of the expression is never consumed by gen_exprstmt/for)
        t = node.target
        if t.kind != "var":
            raise GlslError(node.line, "%s needs a plain variable" % node.op)
        var = self.lookup(t.name, node.line)
        if var.readonly:
            raise GlslError(node.line, "cannot modify read-only %r" % t.name)
        if var.gtype not in ("int", "float"):
            raise GlslError(node.line, "%s needs a scalar variable" % node.op)
        self.put("%s%s;" % (var.comps[0], node.op))
        return (var.gtype, list(var.comps))

    def gen_assign(self, node):
        self.do_assign(node)
        # assignment as an expression returns the assigned variable; the
        # subset treats assignment as statement-level, so return the LHS value
        return self.gen_expr(node.lhs)

    def do_assign(self, node):
        lhs, rhs, op = node.lhs, node.rhs, node.op
        # resolve target: plain var, swizzle of var, or component
        if lhs.kind == "var":
            var = self.lookup(lhs.name, node.line)
            if var.readonly:
                raise GlslError(node.line, "cannot assign to read-only %r" % lhs.name)
            tgt_type, tgt_comps = var.gtype, list(var.comps)
        elif lhs.kind == "swizzle" and lhs.base.kind == "var":
            var = self.lookup(lhs.base.name, node.line)
            if var.readonly:
                raise GlslError(node.line, "cannot assign to read-only %r"
                                % lhs.base.name)
            if var.gtype in SCALAR_TYPES:
                raise GlslError(node.line, "cannot swizzle a %s" % var.gtype)
            idx = self.swizzle_indices(lhs.sw, len(var.comps), node.line)
            if len(set(idx)) != len(idx):
                raise GlslError(node.line, "swizzle %r repeats a component on "
                                           "the left of an assignment" % lhs.sw)
            tgt_comps = [var.comps[i] for i in idx]
            tgt_type = "float" if len(idx) == 1 else "vec%d" % len(idx)
        else:
            raise GlslError(node.line, "left side of assignment must be a "
                                       "variable or swizzle")
        if op != "=":
            rhs = Node("binary", node.line, op=op[0], lhs=lhs, rhs=rhs)
        val = self.gen_expr(rhs)
        gtype, comps = val
        if tgt_type == "float" and gtype == "int":
            gtype, comps = self.promote(val, node.line)
        if tgt_type in SCALAR_TYPES:
            if gtype != tgt_type:
                raise GlslError(node.line, "cannot assign %s to %s"
                                % (gtype, tgt_type))
            self.put("%s=%s;" % (tgt_comps[0], comps[0]))
            return
        if gtype != tgt_type:
            raise GlslError(node.line, "cannot assign %s to %s" % (gtype, tgt_type))
        # aliasing-safe vector store: copy through temps when RHS names
        # overlap the target components (e.g. p.xy = p.yx)
        if set(comps) & set(tgt_comps):
            copies = []
            for c in comps:
                t = self.temp("F64")
                self.put("%s=%s;" % (t, c))
                copies.append(t)
            comps = copies
        for tc, c in zip(tgt_comps, comps):
            self.put("%s=%s;" % (tc, c))

    # ==========================================================================
    # Statements
    # ==========================================================================
    def gen_stmt(self, node):
        if node.kind == "block":
            self.scopes.append({})
            for s in node.stmts:
                self.gen_stmt(s)
            self.scopes.pop()
            return
        if node.kind == "empty":
            return
        if node.kind == "decl":
            for name, init, line in node.decls:
                names = self.claim(name, node.gtype, line)
                ctype = HOLYC_TYPE.get(node.gtype, "F64")
                for x in names:
                    self.declare(ctype, x)
                var = Var(node.gtype, names)
                if init is not None:
                    val = self.gen_expr(init)
                    gtype, comps = val
                    if node.gtype == "float" and gtype == "int":
                        gtype, comps = self.promote(val, line)
                    if gtype != node.gtype:
                        raise GlslError(line, "cannot initialize %s %r with %s"
                                        % (node.gtype, name, gtype))
                    for tc, c in zip(names, comps):
                        self.put("%s=%s;" % (tc, c))
                self.define_var(name, var, line)
            return
        if node.kind == "exprstmt":
            e = node.expr
            if e.kind in ("assign", "incdec", "call"):
                self.gen_expr(e)
            else:
                raise GlslError(node.line, "expression statement has no effect")
            return
        if node.kind == "if":
            cond = self.gen_bool(node.cond)
            self.put("if (%s) {" % cond)
            self.indent += 1
            self.gen_stmt(node.then)
            self.indent -= 1
            if node.els is not None:
                self.put("} else {")
                self.indent += 1
                self.gen_stmt(node.els)
                self.indent -= 1
            self.put("}")
            return
        if node.kind == "while":
            mark = len(self.body)
            cond = self.gen_bool(node.cond)
            prelude = self.body[mark:]
            del self.body[mark:]
            if not prelude:
                self.put("while (%s) {" % cond)
                self.indent += 1
                self.gen_stmt(node.body)
                self.indent -= 1
                self.put("}")
            else:
                self.put("while (TRUE) {")
                self.indent += 1
                self.body.extend("  " + ln for ln in prelude)
                self.put("if (!%s)" % cond)
                self.put("  break;")
                self.gen_stmt(node.body)
                self.indent -= 1
                self.put("}")
            return
        if node.kind == "for":
            self.scopes.append({})
            init_line = None
            if node.init is not None:
                mark = len(self.body)
                self.gen_stmt(node.init)
                init_lines = [ln.strip() for ln in self.body[mark:]]
                if len(init_lines) == 1:
                    del self.body[mark:]
                    init_line = init_lines[0].rstrip(";")
            cond = "TRUE"
            cond_prelude = []
            if node.cond is not None:
                mark = len(self.body)
                cond = self.gen_bool(node.cond)
                cond_prelude = self.body[mark:]
                del self.body[mark:]
            inc_lines = []
            if node.inc is not None:
                mark = len(self.body)
                e = node.inc
                if e.kind in ("assign", "incdec", "call"):
                    self.gen_expr(e)
                else:
                    raise GlslError(e.line, "for-increment has no effect")
                inc_lines = [ln.strip() for ln in self.body[mark:]]
                del self.body[mark:]
            simple = not cond_prelude and len(inc_lines) <= 1
            if simple:
                inc = inc_lines[0].rstrip(";") if inc_lines else ""
                self.put("for (%s;%s;%s) {" % (init_line or "", cond, inc))
                self.indent += 1
                self.gen_stmt(node.body)
                self.indent -= 1
                self.put("}")
            else:
                if init_line:
                    self.put(init_line + ";")
                self.put("while (TRUE) {")
                self.indent += 1
                for ln in cond_prelude:
                    self.body.append("  " + ln)
                self.put("if (!%s)" % cond)
                self.put("  break;")
                self.gen_stmt(node.body)
                for ln in inc_lines:
                    self.put(ln)
                self.indent -= 1
                self.put("}")
            self.scopes.pop()
            return
        if node.kind == "return":
            self.gen_return(node)
            return
        if node.kind == "break":
            self.put("break;")
            return
        raise GlslError(node.line, "unsupported statement %r" % node.kind)

    def gen_bool(self, node):
        gtype, comps = self.gen_expr(node)
        if gtype != "bool":
            raise GlslError(node.line, "condition must be bool, got %s" % gtype)
        return comps[0]

    def gen_return(self, node):
        if self.in_main:
            if node.expr is not None:
                raise GlslError(node.line, "mainImage returns void")
            self.main_done_used = True
            self.put("goto ht_done;")
            return
        if self.cur_ret == "void":
            if node.expr is not None:
                raise GlslError(node.line, "void function cannot return a value")
            self.put("return;")
            return
        if node.expr is None:
            raise GlslError(node.line, "missing return value")
        val = self.gen_expr(node.expr)
        gtype, comps = val
        if self.cur_ret == "float" and gtype == "int":
            gtype, comps = self.promote(val, node.line)
        if gtype != self.cur_ret:
            raise GlslError(node.line, "return type mismatch: function returns "
                                       "%s, got %s" % (self.cur_ret, gtype))
        if self.cur_ret in SCALAR_TYPES:
            self.put("return %s;" % comps[0])
        else:
            for ptr, c in zip(self.cur_ret_ptrs, comps):
                self.put("*%s=%s;" % (ptr, c))
            self.put("return;")

    # ==========================================================================
    # Functions & program
    # ==========================================================================
    def begin_function(self):
        self.taken = set()
        self.decls = []
        self.body = []
        self.indent = 0
        self.scopes = [dict()]
        self.tmp_n = 0
        # uniforms visible everywhere (read-only)
        for gname, (gtype, comps) in UNIFORMS.items():
            self.scopes[0][gname] = Var(gtype, comps, readonly=True)

    def finish_function(self, header):
        lines = [header, "{"]
        # group declarations by type, in claim order, 8 names per line
        by_type = []
        for ctype, name in self.decls:
            if by_type and by_type[-1][0] == ctype and len(by_type[-1][1]) < 8:
                by_type[-1][1].append(name)
            else:
                by_type.append((ctype, [name]))
        for ctype, names in by_type:
            lines.append("  %s %s;" % (ctype, ",".join(names)))
        lines.extend(self.body)
        lines.append("}")
        self.out_funcs.append("\n".join(lines) + "\n")

    def emit_user_function(self, fn):
        if fn.name in self.funcs or fn.name in ("mainImage",):
            raise GlslError(fn.line, "redefinition of function %r" % fn.name)
        if fn.name in BUILTINS or fn.name in VEC_SIZES or fn.name in SCALAR_TYPES:
            raise GlslError(fn.line, "cannot redefine builtin %r" % fn.name)
        self.begin_function()
        # emitted function name
        base = fn.name
        if base.startswith("ht_") or base.startswith("Ht"):
            base = "g_" + base
        cand, bump = base, 1
        while cand in HOLYC_RESERVED or cand in self.global_taken:
            bump += 1
            cand = "%s_%d" % (base, bump)
        self.global_taken.add(cand)
        emitted = cand
        # parameters
        hdr_params = []
        self.cur_ret = fn.ret
        self.cur_ret_ptrs = None
        self.in_main = False
        if fn.ret not in SCALAR_TYPES and fn.ret != "void":
            self.cur_ret_ptrs = ["ht_ret_%s" % COMP_SUFFIX[i]
                                 for i in range(ncomps(fn.ret))]
            hdr_params.extend("F64 *%s" % p for p in self.cur_ret_ptrs)
            for p in self.cur_ret_ptrs:
                self.taken.add(p)
        scope = {}
        for p in fn.params:
            if p.qual != "in":
                raise GlslError(p.line, "%r parameters are only supported on "
                                        "mainImage in v0 (deferred)" % p.qual)
            names = self.claim(p.name, p.gtype, p.line)
            ctype = HOLYC_TYPE.get(p.gtype, "F64")
            hdr_params.extend("%s %s" % (ctype, x) for x in names)
            if p.name in scope:
                raise GlslError(p.line, "duplicate parameter %r" % p.name)
            scope[p.name] = Var(p.gtype, names)
        # register before the body so the signature exists for (self-)calls
        self.funcs[fn.name] = Func(fn.ret, fn.params, emitted)
        self.scopes.append(scope)
        ret_ctype = "U0" if (fn.ret == "void" or fn.ret in VEC_SIZES) \
            else HOLYC_TYPE[fn.ret]
        self.scopes.append({})
        for s in fn.body.stmts:
            self.gen_stmt(s)
        self.scopes.pop()
        self.scopes.pop()
        header = "%s %s(%s)" % (ret_ctype, emitted, ",".join(hdr_params))
        self.finish_function(header)

    def emit_main_image(self, fn):
        if fn.ret != "void" or len(fn.params) != 2:
            raise GlslError(fn.line, "mainImage must be "
                            "'void mainImage(out vec4 fragColor, in vec2 fragCoord)'")
        p_color, p_coord = fn.params
        if p_color.gtype != "vec4" or p_color.qual != "out":
            raise GlslError(p_color.line, "mainImage's first parameter must be "
                                          "'out vec4'")
        if p_coord.gtype != "vec2" or p_coord.qual not in ("in",):
            raise GlslError(p_coord.line, "mainImage's second parameter must be "
                                          "'in vec2'")
        self.begin_function()
        self.in_main = True
        self.main_done_used = False
        self.cur_ret = "void"
        self.taken.update(("u", "x", "y", "out_color", "ht_lum", "ht_done"))
        color_names = self.claim(p_color.name, "vec4", p_color.line)
        coord_names = self.claim(p_coord.name, "vec2", p_coord.line)
        for nm in color_names + coord_names:
            self.declare("F64", nm)
        self.declare("F64", "ht_lum")
        scope = {p_color.name: Var("vec4", color_names),
                 p_coord.name: Var("vec2", coord_names)}
        # uniforms from the ABI struct
        self.put("ht_iTime=u->i_time;")
        self.put("ht_iFrame=u->i_frame;")
        self.put("ht_iRes_x=u->res_x;")
        self.put("ht_iRes_y=u->res_y;")
        self.put("ht_iRes_z=1.0;")
        self.put("ht_iMouse_x=u->mouse_x;")
        self.put("ht_iMouse_y=u->mouse_y;")
        self.put("ht_iMouse_z=0.0;")
        self.put("ht_iMouse_w=0.0;")
        # Shadertoy fragCoord: origin bottom-left, pixel centers at +0.5
        self.put("%s=x+0.5;" % coord_names[0])
        self.put("%s=u->res_y-y-0.5;" % coord_names[1])
        for nm in color_names:
            self.put("%s=0.0;" % nm)
        self.scopes.append(scope)
        self.scopes.append({})
        for s in fn.body.stmts:
            self.gen_stmt(s)
        self.scopes.pop()
        self.scopes.pop()
        if self.main_done_used:
            self.put("ht_done:;")
        self.put("ht_lum=Clamp(0.299*%s+0.587*%s+0.114*%s,0.0,1.0);"
                 % tuple(color_names[:3]))
        self.put("*out_color=ClampI64(ToI64(ht_lum*16.0),0,15);")
        self.in_main = False
        header = "U0 MainImage(CHtUniforms *u,I64 x,I64 y,U8 *out_color)"
        self.finish_function(header)

    def emit_program(self, src_name):
        main_fn = None
        for fn in self.fns:
            if fn.name == "mainImage":
                if main_fn is not None:
                    raise GlslError(fn.line, "duplicate mainImage")
                main_fn = fn
                self.emit_main_image(fn)
            else:
                self.emit_user_function(fn)
        if main_fn is None:
            raise GlslError(1, "no 'void mainImage(out vec4, in vec2)' found")
        # mainImage was emitted at its source position; keep output order:
        # helpers, then functions in source order with MainImage where
        # mainImage was (GLSL define-before-use makes this always valid).
        parts = []
        parts.append("//Generated by tools/glsl2hc.py from %s -- DO NOT EDIT.\n"
                     "//Runner: %s, scale: %d. Fix the emitter, not this file.\n"
                     % (src_name, self.runner, self.scale))
        parts.append(
            "class CHtUniforms\n"
            "{\n"
            "  F64 i_time;\n"
            "  I64 i_frame;\n"
            "  I64 res_x,res_y;\n"
            "  I64 mouse_x,mouse_y;\n"
            "};\n")
        parts.append(
            "//Shadertoy uniforms; MainImage refreshes them from the ABI "
            "struct.\n"
            "F64 ht_iTime;\n"
            "I64 ht_iFrame;\n"
            "F64 ht_iRes_x,ht_iRes_y,ht_iRes_z;\n"
            "F64 ht_iMouse_x,ht_iMouse_y,ht_iMouse_z,ht_iMouse_w;\n")
        for h in HELPER_ORDER:
            if h in self.helpers_used:
                parts.append(HELPER_DEFS[h])
        parts.extend(self.out_funcs)
        if self.runner == "static":
            parts.append(RUNNER_STATIC.replace("@SCALE@", str(self.scale)))
        text = "\n".join(parts)
        bad = [c for c in text if ord(c) > 127]
        assert not bad, "emitter produced non-ASCII output: %r" % bad[:5]
        return text


# ---------------------------------------------------------------------------
# Builtin functions


def _b_componentwise1(hc_name, promote_int=True):
    def gen(em, node):
        if len(node.args) != 1:
            raise GlslError(node.line, "%s() takes 1 argument" % node.name)
        val = em.gen_expr(node.args[0])
        gtype, comps = val
        if gtype == "bool" or gtype == "void":
            raise GlslError(node.line, "%s() of a %s" % (node.name, gtype))
        if gtype == "int" and promote_int:
            gtype, comps = em.promote(val, node.line)
        if gtype in SCALAR_TYPES:
            return (gtype, ["%s(%s)" % (hc_name, comps[0])])
        return em.mat_vec(gtype, ["%s(%s)" % (hc_name, c) for c in comps])
    return gen


def _b_int_or_float1(f_name, i_name):
    def gen(em, node):
        if len(node.args) != 1:
            raise GlslError(node.line, "%s() takes 1 argument" % node.name)
        gtype, comps = em.gen_expr(node.args[0])
        if gtype == "int":
            return ("int", ["%s(%s)" % (i_name, comps[0])])
        if gtype == "float":
            return ("float", ["%s(%s)" % (f_name, comps[0])])
        if gtype in VEC_SIZES:
            return em.mat_vec(gtype, ["%s(%s)" % (f_name, c) for c in comps])
        raise GlslError(node.line, "%s() of a %s" % (node.name, gtype))
    return gen


def _pairwise_args(em, node, n, broadcast_from=1, broadcast_first=False,
                   vals=None):
    """Evaluate n args; promote ints; broadcast trailing (or leading) scalars
    over a vector first (or last) arg. Returns (gtype, [comps-lists])."""
    if len(node.args) != n:
        raise GlslError(node.line, "%s() takes %d arguments" % (node.name, n))
    if vals is None:
        vals = [em.gen_expr(a) for a in node.args]
    vals = [em.promote(v, node.line) if v[0] == "int" else v for v in vals]
    for v in vals:
        if v[0] not in VEC_SIZES and v[0] != "float":
            raise GlslError(node.line, "%s() of a %s" % (node.name, v[0]))
    ref = vals[0][0] if not broadcast_first else vals[-1][0]
    if ref == "float":
        if any(v[0] != "float" for v in vals):
            raise GlslError(node.line, "%s(): mixed scalar/vector arguments"
                            % node.name)
        return ("float", [v[1] for v in vals])
    size = VEC_SIZES[ref]
    out = []
    for i, v in enumerate(vals):
        gtype, comps = v
        is_bc_slot = (i >= broadcast_from) if not broadcast_first \
            else (i < len(vals) - 1)
        if gtype == ref:
            out.append(comps)
        elif gtype == "float" and is_bc_slot:
            s = em.mat_scalar("float", comps[0])
            out.append([s] * size)
        else:
            raise GlslError(node.line, "%s(): argument %d must be %s or float"
                            % (node.name, i + 1, ref))
    return (ref, out)


def _b_map_n(hc_name, n, broadcast_from=1, broadcast_first=False):
    def gen(em, node, vals=None):
        gtype, arglists = _pairwise_args(em, node, n, broadcast_from,
                                         broadcast_first, vals)
        if gtype == "float":
            return ("float", ["%s(%s)" % (hc_name,
                                          ",".join(a[0] for a in arglists))])
        size = VEC_SIZES[gtype]
        exprs = ["%s(%s)" % (hc_name, ",".join(arglists[j][i] for j in range(n)))
                 for i in range(size)]
        return em.mat_vec(gtype, exprs)
    return gen


def _b_minmax(hc_f, hc_i):
    def gen(em, node):
        if len(node.args) != 2:
            raise GlslError(node.line, "%s() takes 2 arguments" % node.name)
        vals = [em.gen_expr(a) for a in node.args]
        if vals[0][0] == "int" and vals[1][0] == "int":
            return ("int", ["%s(%s,%s)" % (hc_i, vals[0][1][0], vals[1][1][0])])
        return _b_map_n(hc_f, 2)(em, node, vals=vals)
    return gen


def _b_clamp(em, node):
    if len(node.args) != 3:
        raise GlslError(node.line, "clamp() takes 3 arguments")
    vals = [em.gen_expr(a) for a in node.args]
    if all(v[0] == "int" for v in vals):
        return ("int", ["ClampI64(%s,%s,%s)" % tuple(v[1][0] for v in vals)])
    return _b_map_n("Clamp", 3)(em, node, vals=vals)


def _b_atan(em, node):
    if len(node.args) == 1:
        return _b_componentwise1("ATan")(em, node)
    if len(node.args) == 2:
        # GLSL atan(y, x) == HolyC Arg(x, y) (FPATAN quadrant-aware)
        gtype, (ycomps, xcomps) = _pairwise_args(em, node, 2, broadcast_from=2)
        exprs = ["Arg(%s,%s)" % (xc, yc) for yc, xc in zip(ycomps, xcomps)]
        if gtype == "float":
            return ("float", [exprs[0]])
        return em.mat_vec(gtype, exprs)
    raise GlslError(node.line, "atan() takes 1 or 2 arguments")


def _b_length(em, node):
    if len(node.args) != 1:
        raise GlslError(node.line, "length() takes 1 argument")
    val = em.gen_expr(node.args[0])
    gtype, comps = val
    if gtype == "int":
        gtype, comps = em.promote(val, node.line)
    if gtype == "float":
        return ("float", ["Abs(%s)" % comps[0]])
    if gtype not in VEC_SIZES:
        raise GlslError(node.line, "length() of a %s" % gtype)
    sq = "+".join("%s*%s" % (c, c) for c in comps)
    return ("float", ["Sqrt(%s)" % sq])


def _b_dot(em, node):
    if len(node.args) != 2:
        raise GlslError(node.line, "dot() takes 2 arguments")
    a = em.gen_expr(node.args[0])
    b = em.gen_expr(node.args[1])
    if a[0] != b[0] or a[0] not in VEC_SIZES:
        raise GlslError(node.line, "dot() needs two vectors of the same size "
                                   "(got %s, %s)" % (a[0], b[0]))
    s = "+".join("%s*%s" % (x, y) for x, y in zip(a[1], b[1]))
    return ("float", ["(%s)" % s])


def _b_cross(em, node):
    if len(node.args) != 2:
        raise GlslError(node.line, "cross() takes 2 arguments")
    a = em.gen_expr(node.args[0])
    b = em.gen_expr(node.args[1])
    if a[0] != "vec3" or b[0] != "vec3":
        raise GlslError(node.line, "cross() needs two vec3s (got %s, %s)"
                        % (a[0], b[0]))
    (ax, ay, az), (bx, by, bz) = a[1], b[1]
    return em.mat_vec("vec3", ["(%s*%s-%s*%s)" % (ay, bz, az, by),
                               "(%s*%s-%s*%s)" % (az, bx, ax, bz),
                               "(%s*%s-%s*%s)" % (ax, by, ay, bx)])


def _b_normalize(em, node):
    if len(node.args) != 1:
        raise GlslError(node.line, "normalize() takes 1 argument")
    gtype, comps = em.gen_expr(node.args[0])
    if gtype not in VEC_SIZES:
        raise GlslError(node.line, "normalize() needs a vector, got %s" % gtype)
    sq = "+".join("%s*%s" % (c, c) for c in comps)
    ln = em.temp("F64")
    em.put("%s=Sqrt(%s);" % (ln, sq))
    return em.mat_vec(gtype, ["(%s/%s)" % (c, ln) for c in comps])


BUILTINS = {
    "sin": _b_componentwise1("Sin"),
    "cos": _b_componentwise1("Cos"),
    "tan": _b_componentwise1("Tan"),
    "sqrt": _b_componentwise1("Sqrt"),
    "exp": _b_componentwise1("Exp"),
    "log": _b_componentwise1("Ln"),
    "floor": _b_componentwise1("Floor"),
    "atan": _b_atan,
    "abs": _b_int_or_float1("Abs", "AbsI64"),
    "sign": _b_int_or_float1("Sign", "SignI64"),
    "pow": _b_map_n("Pow", 2, broadcast_from=2),
    "min": _b_minmax("Min", "MinI64"),
    "max": _b_minmax("Max", "MaxI64"),
    "clamp": _b_clamp,
    "length": _b_length,
    "dot": _b_dot,
    "cross": _b_cross,
    "normalize": _b_normalize,
}


def _late_bind_helpers():
    """fract/mod/mix/step/smoothstep need helpers_used bookkeeping."""
    def fract(em, node):
        em.helpers_used.add("HtFract")
        return _b_componentwise1("HtFract")(em, node)

    def mod(em, node):
        em.helpers_used.add("HtMod")
        return _b_map_n("HtMod", 2, broadcast_from=1)(em, node)

    def mix(em, node):
        em.helpers_used.add("HtMix")
        return _b_map_n("HtMix", 3, broadcast_from=2)(em, node)

    def step(em, node):
        em.helpers_used.add("HtStep")
        return _b_map_n("HtStep", 2, broadcast_first=True)(em, node)

    def smoothstep(em, node):
        em.helpers_used.add("HtSmooth")
        return _b_map_n("HtSmooth", 3, broadcast_first=True)(em, node)

    BUILTINS["fract"] = fract
    BUILTINS["mod"] = mod
    BUILTINS["mix"] = mix
    BUILTINS["step"] = step
    BUILTINS["smoothstep"] = smoothstep


_late_bind_helpers()


# ---------------------------------------------------------------------------
# Static runner (proof harness): grayscale palette, one static frame at
# iTime=0, evaluated once per HT_SCALE x HT_SCALE block, blitted by a
# draw_it callback (survives window redraws; pattern: src/plasma.HC).

RUNNER_STATIC = """\
//--- standalone one-frame runner (--runner static) -----------------------
#define HT_SCALE @SCALE@

U8 *ht_cells=NULL;
I64 ht_cw=0,ht_ch=0;

U0 HtGrayPalette()
{//16-step grayscale ramp: luminance index 0 (black) .. 15 (white).
  I64 i;
  CBGR48 bgr;
  bgr.pad=0;
  for (i=0;i<COLORS_NUM;i++) {
    bgr.r=0xFFFF*i/15;
    bgr.g=0xFFFF*i/15;
    bgr.b=0xFFFF*i/15;
    GrPaletteColorSet(i,bgr);
  }
}

U0 HtRenderStatic()
{//Evaluate MainImage once per HT_SCALE block for the static frame.
  CHtUniforms u;
  I64 cx,cy;
  U8 c;
  u.i_time=0.0;
  u.i_frame=0;
  u.res_x=GR_WIDTH;
  u.res_y=GR_HEIGHT;
  u.mouse_x=0;
  u.mouse_y=0;
  ht_cw=(GR_WIDTH+HT_SCALE-1)/HT_SCALE;
  ht_ch=(GR_HEIGHT+HT_SCALE-1)/HT_SCALE;
  ht_cells=MAlloc(ht_cw*ht_ch);
  for (cy=0;cy<ht_ch;cy++)
    for (cx=0;cx<ht_cw;cx++) {
      MainImage(&u,cx*HT_SCALE,cy*HT_SCALE,&c);
      ht_cells[cy*ht_cw+cx]=c;
    }
}

U0 HtDrawIt(CTask *task,CDC *dc)
{//Blit the precomputed cell grid; raw body pokes are ABSOLUTE screen coords.
  I64 x,y,sx,sy,stride=dc->width_internal;
  for (y=0;y<task->pix_height;y++) {
    sy=task->pix_top+y;
    if (0<=sy<dc->height) {
      for (x=0;x<task->pix_width;x++) {
        sx=task->pix_left+x;
        if (0<=sx<dc->width)
          dc->body[sy*stride+sx]=ht_cells[y/HT_SCALE*ht_cw+x/HT_SCALE];
      }
    }
  }
}

HtGrayPalette;
HtRenderStatic;
Fs->draw_it=&HtDrawIt;
"""


# ---------------------------------------------------------------------------
# API + CLI


def transpile(source, filename="<glsl>", runner="static", scale=4):
    """Transpile GLSL source text to HolyC. Raises GlslError on bad input."""
    toks = lex(source)
    fns = Parser(toks).parse_program()
    em = Emitter(fns, runner=runner, scale=scale)
    import os.path
    return em.emit_program(os.path.basename(filename))


def main(argv=None):
    ap = argparse.ArgumentParser(
        prog="glsl2hc.py",
        description="Transpile a Shadertoy-subset GLSL fragment shader to HolyC.")
    ap.add_argument("input", metavar="IN.glsl")
    ap.add_argument("-o", "--output", metavar="OUT.HC",
                    help="output path (default: stdout)")
    ap.add_argument("--runner", choices=("static", "none"), default="static",
                    help="append the standalone proof runner (default: static)")
    ap.add_argument("--scale", type=int, default=4, metavar="N",
                    help="static runner block size, 1-32 (default: 4)")
    args = ap.parse_args(argv)
    if not 1 <= args.scale <= 32:
        ap.error("--scale must be in 1..32")
    try:
        with open(args.input, "r", encoding="ascii", errors="strict") as f:
            src = f.read()
    except UnicodeDecodeError:
        print("%s: not an ASCII file" % args.input, file=sys.stderr)
        return 2
    except OSError as e:
        print("%s: %s" % (args.input, e.strerror), file=sys.stderr)
        return 2
    try:
        out = transpile(src, filename=args.input, runner=args.runner,
                        scale=args.scale)
    except GlslError as e:
        print("%s:%d: %s" % (args.input, e.line, e.msg), file=sys.stderr)
        return 1
    if args.output:
        try:
            with open(args.output, "w", encoding="ascii") as f:
                f.write(out)
        except OSError as e:
            print("%s: %s" % (args.output, e.strerror), file=sys.stderr)
            return 2
    else:
        sys.stdout.write(out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
