// Guest-compiler live-loop fixture: a slowly moving vertical gradient.
void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    fragColor = vec4(fragCoord.y / iResolution.y * 0.5 + iTime / 100.0);
}
