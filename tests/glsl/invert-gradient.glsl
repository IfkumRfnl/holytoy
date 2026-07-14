// Interactive editor target: replacing the source flips the viewport.
void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    fragColor = vec4(1.0 - fragCoord.y / iResolution.y);
}
