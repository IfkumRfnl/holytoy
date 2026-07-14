#!/usr/bin/env python3
import importlib.util
import unittest
from pathlib import Path

PATH = Path(__file__).with_name("corpus_compat.py")
SPEC = importlib.util.spec_from_file_location("corpus_compat", PATH)
MOD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MOD)


class CorpusCompatTests(unittest.TestCase):
    def test_vertical_slice(self):
        self.assertEqual(MOD.glsl_reason(
            "void mainImage(out vec4 fragColor,in vec2 fragCoord){"
            "fragColor=vec4(fragCoord.y/iResolution.y);}"), "pass")

    def test_time_uniform_slice(self):
        self.assertEqual(MOD.glsl_reason(
            "void mainImage(out vec4 fragColor,in vec2 fragCoord){"
            "fragColor=vec4(fragCoord.y/iResolution.y+iTime/100.0);}"), "pass")

    def test_typed_circle_slice(self):
        self.assertEqual(MOD.glsl_reason(
            "void mainImage(out vec4 fragColor,in vec2 p){vec2 q=p;"
            "float d=length(q);float x=step(.2,d);"
            "fragColor=vec4(x);}"), "pass")

    def test_declaration_is_not_overclaimed(self):
        self.assertTrue(MOD.glsl_reason(
            "void mainImage(out vec4 c,in vec2 p){float x=1.;c=vec4(x);}").startswith("unsupported:"))

    def test_control_flow_reason(self):
        self.assertIn("control flow", MOD.glsl_reason("void mainImage(){for (int i=0;;){}}"))


if __name__ == "__main__":
    unittest.main()
