void mainImage( out vec4 fragColor, in vec2 fragCoord )
{
    // UV
    vec2 uv = 3. * (fragCoord - .5*iResolution.xy) / iResolution.y;
    
    // Wavy pattern
    float f = cos(6.28 * (uv.x*uv.x*uv.x+uv.y*uv.y*uv.y))*.5+.5;
    
    // Dither
    if (mod(iTime, 3.) < 1.5)
        f = (f > texture(iChannel0, fragCoord / vec2(textureSize(iChannel0, 0))).x) ? 1. : 0.;
    
    // OETF 2.2 (Gamma)
    f = pow(f, 1. / 2.2);
    
    fragColor = vec4(f, f, f, 1.0);
}
