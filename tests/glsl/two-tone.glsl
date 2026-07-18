// plan 015 Stage C palette fixture: a static two-tone scene whose colors
// sit far from every standard 16-color palette entry - left half deep
// orange, right half deep teal. With HOLYTOY_PAL=adaptive the non-reserved
// DAC entries must converge onto these two colors (proof 17; the expected
// values ride along in PALCHK.TXT as 0-255 triplets: 230,89,13 13,128,115).
void mainImage(out vec4 fragColor, in vec2 fragCoord) {
  if (fragCoord.x < iResolution.x * 0.5)
    fragColor = vec4(0.9, 0.35, 0.05, 1.0);
  else
    fragColor = vec4(0.05, 0.5, 0.45, 1.0);
}
