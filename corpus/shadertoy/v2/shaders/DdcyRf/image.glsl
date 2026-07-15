// https://www.desmos.com/calculator/n4mfhffj1n
float f(float x, float v)
{
    if (abs(v) < .0001) v = .0001;
    float p = pow(2., v);
    return (1. - pow(p, -x)) / (1. - 1. / p);
}

vec3 colormap(float x)
{
    //float t = .1 * iTime;
    //float t = .75 - 1.1 * x;
    //float t = .25 * x;
    float t = .6 + .8 * x;
    
    // https://www.desmos.com/calculator/sdqk904uu9
    vec3 tone = 10. * vec3(
        cos(6.283 * t),
        cos(6.283 * (t - .3333)),
        cos(6.283 * (t - .6667))
    );
    
    x = smoothstep(-.04, 1., x);
    vec3 c = vec3(
        f(x, tone.r),
        f(x, tone.g),
        f(x, tone.b)
    );
    
    return c;
}

void mainImage( out vec4 fragColor, in vec2 fragCoord )
{
    vec2 uv = fragCoord/iResolution.xy;
    vec3 col = colormap(uv.x);
    col = pow(col, vec3(.45));
    fragColor = vec4(col,1.0);
}
