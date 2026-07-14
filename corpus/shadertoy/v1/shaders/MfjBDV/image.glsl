// https://www.desmos.com/calculator/n4mfhffj1n
float colormap_expf(float x, float v)
{
    if (abs(v) < .0001) v = .0001;
    float p = pow(2., v);
    return (1. - pow(p, -x)) / (1. - 1. / p);
}

vec3 colormap(float x)
{
    float t = .18 * abs(x);
    if (x < 0.)
    {
        x = -x;
        t = -.37 - .14 * x;
    }
    
    // https://www.desmos.com/calculator/sdqk904uu9
    vec3 tone = 8. * vec3(
        cos(6.283 * t),
        cos(6.283 * (t - .3333)),
        cos(6.283 * (t - .6667))
    );
    
    x = smoothstep(0., 1., x);
    vec3 c = vec3(
        colormap_expf(x, tone.r),
        colormap_expf(x, tone.g),
        colormap_expf(x, tone.b)
    );
    
    c = mix(c, c + vec3(.03, 0, .03), smoothstep(.1, 0., x));
    
    return c;
}

void mainImage( out vec4 fragColor, in vec2 fragCoord )
{
    vec2 uv = fragCoord/iResolution.xy;
    vec3 col = colormap(uv.x * 2. - 1.);
    col = pow(col, vec3(.45));
    fragColor = vec4(col,1.0);
}
