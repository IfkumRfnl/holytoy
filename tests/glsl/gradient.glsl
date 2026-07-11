// holytoy fixture (plan 004): full-screen vertical gradient.
// Static-runner expectation: >= 8 gray levels in the screenshot.
void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    fragColor = vec4(fragCoord.y / iResolution.y);
}
