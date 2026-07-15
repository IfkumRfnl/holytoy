// Deliberately expensive adaptive-scale fixture.
void mainImage(out vec4 fragColor, in vec2 fragCoord) {
  float v = fragCoord.x / iResolution.x;
  for (int i = 0; i < 40000; i++)
    v = fract(sin(v * 12.9898 + float(i)) * 43758.5453);
  fragColor = vec4(v);
}
