// colormap source:
// https://www.shadertoy.com/view/MfjBDV

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
    
    c = mix(c, c + vec3(.04, 0, .03), smoothstep(.1, 0., x));
    
    return c;
}

float spow(float a, float b)
{
    return sign(a) * pow(abs(a), b);
}

void mainImage(out vec4 frag_col, in vec2 frag_coord)
{
    vec2 uv = (2. * frag_coord - iResolution.xy) / min(iResolution.x, iResolution.y);
    
    float v = 0.;
    for (float x = -2.; x <= 2.; x++)
    {
        vec2 center = vec2(.2 * x, -.9);
        float dist = distance(uv, center);
        v += sin(100. * dist - 5. * iTime) / (dist + .05);
    }
    
    vec3 col = vec3(colormap(.05 * v));
    
    col = pow(col, vec3(1. / 2.2));
    frag_col = vec4(col, 1);
}
