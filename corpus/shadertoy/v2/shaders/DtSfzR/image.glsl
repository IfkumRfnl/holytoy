float remap_clamp(float inp, float inp_start, float inp_end, float out_start, float out_end)
{
    float t = clamp((inp - inp_start) / (inp_end - inp_start), 0.0, 1.0);
    return out_start + t * (out_end - out_start);
}

void mainImage( out vec4 fragColor, in vec2 fragCoord )
{
    // Coordinates
    vec2 uv = fragCoord / iResolution.xy;
    uv.y += -.05 * iTime;
    float x = uv.x + .01 * cos(10. * uv.y) + .002 * cos(40. * uv.y);
    
    // Base color
    vec3 col = vec3(.98, .82, .62);
    
    // Absorption color
    const vec3 sea = vec3(.45, .83, .945);
    
    // Absorb
    float depth = remap_clamp(x, 0.2, 1., 0.0001, 30.);
    col *= pow(sea, vec3(depth));
    
    // Desaturate
    col = mix(col, vec3(.2, 1, 1), .01);
    
    // Output
    col = pow(col, vec3(1. / 2.4));
    fragColor = vec4(col, 1.0);
}
