void mainImage(out vec4 fragcol, in vec2 fragcoord)
{
    // UV (0 to 1 stretched)
    vec2 uv = fragcoord / iResolution.xy;

    // linear gradient
    vec3 col = vec3(uv.x * .3 + .05);

    // OETF (Linear BT.709 I-D65 --> sRGB 2.2)
    col = pow(col, vec3(1. / 2.2));
    
    // alternate dither mode
    bool dither = mod(iTime, 2.) < 1.;
    
    // dither
    if (dither)
    {
        float bn = texelFetch(
            iChannel0,
            ivec2(fragcoord) % textureSize(iChannel0, 0),
            0
        ).x;
        col += 2. * (bn - .5) / 254.9;
    }
    
    // indicator at the corner
    if (uv.x > .97 && uv.y < .05)
    {
        col = dither ? vec3(0, 1, 0) : vec3(1, 0, 0);
    }
    
    // output
    fragcol = vec4(col, 1);
}
