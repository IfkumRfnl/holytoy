const ivec2 downscale_res = ivec2(90, 60);

vec3 fetch(ivec2 icoord)
{
    return pow(texelFetch(iChannel0, icoord, 0).rgb, vec3(2.2));
}

void mainImage(out vec4 frag_col, in vec2 frag_coord)
{
    if (any(greaterThanEqual(ivec2(frag_coord), downscale_res)))
    {
        discard;
    }
    
    // alternate between normal bilinear
    if (mod(iTime, 2.) > 1.)
    {
        frag_col = texture(
            iChannel0,
            frag_coord / vec2(downscale_res)
        );
        return;
    }
    
    // bottom left and top right corners of the current pixel in the pixel
    // space of the downscaled image (bottom left, top right, etc.).
    vec2 bl = frag_coord - .5;
    vec2 tr = frag_coord + .5;
    
    // transform the corners to the pixel space at the original resolution
    vec2 scale = vec2(textureSize(iChannel0, 0)) / vec2(downscale_res);
    bl *= scale;
    tr *= scale;
    
    // average out pixels in the AABB (axis-aligned bounding box) formed
    // by these corner points.
    vec3 col = vec3(0);
    float sum_weights = 0.;
    for (int y = int(floor(bl.y)); y <= int(floor(tr.y)); y++)
    {
        for (int x = int(floor(bl.x)); x <= int(floor(tr.x)); x++)
        {
            // corners of the current pixel
            vec2 curr_bl = vec2(x, y);
            vec2 curr_tr = curr_bl + 1.;
            
            // intersect this pixel's AABB with the AABB formed by the
            // corner points from before.
            vec2 intr_bl = max(bl, curr_bl);
            vec2 intr_tr = min(tr, curr_tr);
        
            // sample weight = area of intersection / area of the pixel (1)
            vec2 intr_diagonal = max(intr_tr - intr_bl, 0.);
            float intr_area = intr_diagonal.x * intr_diagonal.y;
            
            // accumulate
            col += intr_area * fetch(ivec2(x, y));
            sum_weights += intr_area;
        }
    }
    col /= sum_weights;;

    // OETF (Linear BT.709 I-D65 to sRGB 2.2)
    col = pow(max(col, 0.), vec3(1. / 2.2));

    // output
    frag_col = vec4(col, 1);
}
