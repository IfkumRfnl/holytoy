// holytoy fixture (plan 004): sines plasma -- the widest subset slice:
// user-defined function, for loop over an int, float(i) conversion,
// swizzles (.xy/.yx), vec constructors incl. splat, componentwise sin
// on a vec3, length, scalar broadcast arithmetic, iTime.
float wave(vec2 p, float t) {
    return sin(p.x * 6.0 + t) + sin(p.y * 5.0 - t * 0.7);
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 uv = fragCoord / iResolution.xy;
    float v = 0.0;
    for (int i = 0; i < 4; i++) {
        float fi = float(i);
        v += sin(length(uv - vec2(0.5)) * (8.0 + 3.0 * fi) - iTime);
        v += wave(uv.yx * (1.0 + fi), iTime + fi);
    }
    vec3 col = 0.5 + 0.5 * sin(vec3(v, v + 2.0, v + 4.0));
    fragColor = vec4(col, 1.0);
}
