void mainImage(out vec4 frag_col, in vec2 frag_coord)
{
    // Normalized pixel coordinates (from 0 to 1)
    vec2 uv = frag_coord / iResolution.xy;

    // Pixel color
    vec3 col = mix(
        vec3(0, 0, 1),
        vec3(1, 1, 0),
        uv.x
    );

    // Output to screen
    frag_col = vec4(col, 1);
}
