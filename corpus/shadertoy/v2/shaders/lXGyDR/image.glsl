// interleaved gradient noise
float ign(ivec2 icoord)
{
    float d = .06711056 * float(icoord.x) + .00583715 * float(icoord.y);
    return mod(52.9829189 * mod(d, 1.), 1.);
}

void mainImage(out vec4 frag_col, in vec2 frag_coord)
{
    vec3 col = vec3(ign(ivec2(frag_coord)));
    frag_col = vec4(pow(col, vec3(1. / 2.2)), 1);
}
