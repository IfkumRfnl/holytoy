void mainImage(out vec4 frag_col, in vec2 frag_coord)
{
    // uv
    vec2 uv = frag_coord / iResolution.xy;

    // render
    const vec3 a = vec3(1, 0, 0);
    const vec3 b = vec3(0, 1, 1);
    vec3 col = iFrame % 2 == 0 ? a : b;
    
    // output
    col = pow(col, vec3(1. / 2.2));
    frag_col = vec4(col, 1);
}