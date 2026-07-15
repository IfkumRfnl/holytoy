/*
#define POISSON_DISK_SIZE 4

vec2 poissonDisk[POISSON_DISK_SIZE] = vec2[](
    vec2(-0.73,  0.15),
    vec2( 0.42,  0.37),
    vec2(-0.11, -0.52),
    vec2( 0.65, -0.31)
);
*/


#define POISSON_DISK_SIZE 8

vec2 poissonDisk[POISSON_DISK_SIZE] = vec2[](
    vec2(-0.94201624, -0.39906216),
    vec2( 0.94558609, -0.76890725),
    vec2(-0.09418410, -0.92938870),
    vec2( 0.34495938,  0.29387760),
    vec2(-0.91588581,  0.45771432),
    vec2(-0.81544232, -0.87912464),
    vec2(-0.38277543,  0.27676845),
    vec2( 0.97484398,  0.75648379)
);


vec4 PoissonDiskFiltering(vec2 uv)
{
    vec2 pixelHalfSize = fwidth(uv) * 0.5;
    
    vec4 sum = vec4(0.0);
    for (int i = 0; i < POISSON_DISK_SIZE; i++)
        sum += textureLod(iChannel0, uv.xy + poissonDisk[i].xy * pixelHalfSize.xy, 0.0);
    
    return sum / float(POISSON_DISK_SIZE);
}

vec4 BilinearFiltering(vec2 uv)
{
    return textureLod(iChannel0, uv, 0.0);
}

void mainImage( out vec4 fragColor, in vec2 fragCoord )
{
    vec2 uv = fragCoord.xy / 98.4 + iTime * 0.03;
    
    // Bilinear filtering for the left side of the screen
    // Poisson disk filtering for the right side
    vec4 color;
    if (fragCoord.x < iResolution.x * 0.5)
        color = BilinearFiltering(uv);
    else
        color = PoissonDiskFiltering(uv);    
        
    fragColor = vec4(color);
}