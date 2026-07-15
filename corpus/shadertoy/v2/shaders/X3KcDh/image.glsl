const float SQRT_2PI = 2.506628274631;

float fetch(vec2 coord)
{
    return texture(iChannel0, coord / vec2(textureSize(iChannel0, 0))).x;
}

float sq(float x)
{
    return x * x;
}

float gaussian_distribution(float x, float standard_deviation)
{
    return exp(-.5 * sq(x / standard_deviation)) / (SQRT_2PI * standard_deviation);
}

// unnormalized, doesn't add up to 1, maximum value is 1.
float gaussian_unnorm(float x, float standard_deviation)
{
    return exp(-.5 * sq(x / standard_deviation));
}

void mainImage(out vec4 frag_col, in vec2 frag_coord)
{
    float sum_values = 0.;
    float sum_weights = 0.;
    for (int offs_y = -5; offs_y <= 5; offs_y++)
    {
        for (int offs_x = -5; offs_x <= 5; offs_x++)
        {
            float v = fetch(frag_coord + vec2(offs_x, offs_y));
            
            float weight = gaussian_unnorm(
                length(vec2(offs_x, offs_y)),
                1.
            );
            
            sum_values += v * weight;
            sum_weights += weight;
        }
    }
    float low_pass = sum_values / sum_weights;
    float high_pass = 2. * (fetch(frag_coord) - low_pass);
    
    vec3 col = vec3(high_pass);
    if (mod(iTime, 1.5) < .75)
    {
        col = vec3(fetch(frag_coord));
    }
    
    frag_col = vec4(pow(col, vec3(1. / 2.2)), 1);
}
