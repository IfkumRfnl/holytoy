void mainImage(out vec4 fragColor, in vec2 fragCoord)
{
    vec2 uv = (2. * fragCoord - iResolution.xy) / min(iResolution.x, iResolution.y);
    
    vec3 col = .5 + .5 * cos(iTime+uv.xyx+vec3(0, 2, 4));
    
    float a = atan(uv.y, uv.x);
    if (a < 0.)
        a += 6.2831853;
    
    col *= a / 6.2831853;
    
    col = pow(col, vec3(1. / 2.2));
    fragColor = vec4(col, 1);
}
