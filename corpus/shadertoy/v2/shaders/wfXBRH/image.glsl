#define CH_INPUT iChannel0
#define CH_BLUE_NOISE iChannel1

void mainImage(out vec4 frag_col, in vec2 frag_coord)
{
    vec3 col = pow(texture(CH_INPUT, frag_coord / iResolution.xy).rgb, vec3(2.2));

    vec3 bn = texelFetch(
        CH_BLUE_NOISE,
        ivec2(frag_coord) % textureSize(CH_BLUE_NOISE, 0),
        0
    ).rgb;
    col += bn - .5;
    col = round(col);
    
    frag_col = vec4(col, 1);
}
