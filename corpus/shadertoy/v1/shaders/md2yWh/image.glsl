float map_range(float inp, float inp_start, float inp_end, float out_start, float out_end)
{
    return out_start + ((out_end - out_start) / (inp_end - inp_start)) * (inp - inp_start);
}

float map_range_clamp(float inp, float inp_start, float inp_end, float out_start, float out_end)
{
    float t = clamp((inp - inp_start) / (inp_end - inp_start), 0.0, 1.0);
    float v = out_start + t * (out_end - out_start);
    return v;
}

vec3 colormap(float x)
{
    vec3 c = vec3(1.0);
    c = mix(c, 1.2 * vec3(0.3, 0.5, 0.8), map_range_clamp(x, -1.0, -0.6, 0.0, 1.0));
    c = mix(c, 1.2 * vec3(0.1, 0.02, 0.4), map_range_clamp(x, -0.6, -0.25, 0.0, 1.0));
    c = mix(c, vec3(0.0), map_range_clamp(x, -0.25, 0.0, 0.0, 1.0));
    c = mix(c, 1.2 * vec3(0.4, 0.1, 0.02), map_range_clamp(x, 0.0, 0.25, 0.0, 1.0));
    c = mix(c, 1.2 * vec3(0.8, 0.5, 0.3), map_range_clamp(x, 0.25, 0.6, 0.0, 1.0));
    c = mix(c, vec3(1.0), map_range_clamp(x, 0.6, 1.0, 0.0, 1.0));
    
    c = pow(c, vec3(1.8));
    c += vec3(0.03, 0.0, 0.02);
    
    return c;
}

void mainImage( out vec4 fragColor, in vec2 fragCoord )
{
    vec2 uv = fragCoord/iResolution.xy;
    
    vec3 col = colormap(uv.x * 2.0 - 1.0);
    
    col = pow(col, vec3(1.0 / 2.2));

    fragColor = vec4(col,1.0);
}
