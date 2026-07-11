// holytoy fixture (plan 004): centered disc via length/step.
// Static-runner expectation: >= 2 colors (white disc on black).
void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 p = (fragCoord - 0.5 * iResolution.xy) / iResolution.y;
    float d = length(p);
    float c = 1.0 - step(0.2, d);
    fragColor = vec4(c, c, c, 1.0);
}
