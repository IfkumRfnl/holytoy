const float DISK_RADIUS = .1;
const float DISK_RADIUS_SQ = DISK_RADIUS * DISK_RADIUS;

const float DISK_ROTATION_FREQ = 1.;
const float ONE_OVER_2PI_DISK_ROTATION_FREQ = 1. / (DISK_ROTATION_FREQ * 6.28318530717959);

float rotating_disk_with_analytical_motion_blur(
    vec2 uv,
    float start_time,
    float end_time
)
{
    float len_sq = dot(uv, uv);
    float idk = (len_sq - DISK_RADIUS_SQ + 1.) / (2. * sqrt(len_sq));
    if (uv.x < 0.)
    {
        idk = -idk;
    }
    
    if (abs(idk) > 1.)
    {
        return 0.;
    }
    
    float v = 0.;
    for (int k = 0; k <= 0; k++)
    {
        float interval_start = start_time;
        float interval_end = end_time;
        
        if (uv.x < 0.)
        {
            interval_start = max(
                interval_start,
                ONE_OVER_2PI_DISK_ROTATION_FREQ * (acos(idk) + atan(uv.y / uv.x))
                - (float(k) / DISK_ROTATION_FREQ)
            );
        }
        else
        {
            interval_end = min(
                interval_end,
                ONE_OVER_2PI_DISK_ROTATION_FREQ * (acos(idk) + atan(uv.y / uv.x))
                - (float(k) / DISK_ROTATION_FREQ)
            );
        }
        
        if (interval_start > interval_end)
        {
            continue;
        }
        
        v = max(
            v,
            (interval_end - interval_start) / (end_time - start_time)
        );
    }
    return v;
}

vec3 render(vec2 coord)
{
    vec2 uv = (2. * coord - iResolution.xy) / min(iResolution.x, iResolution.y);
    uv *= 1.5;
    
    vec3 col = vec3(rotating_disk_with_analytical_motion_blur(
        uv,
        iTime - .1,
        iTime
    ));
    
    return col;
}

void mainImage(out vec4 frag_col, in vec2 frag_coord)
{
    vec3 col = render(frag_coord);
    frag_col = vec4(pow(col, vec3(1. / 2.2)), 1);
}
