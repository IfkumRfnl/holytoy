//HolyToy renderer color library (HTRENDER) -- RGBA quantization and dither.
//
//Shaders return unclamped RGBA. The renderer converts RGB to 8.8 fixed point,
//then HtQuantize maps it and the absolute screen position to a TempleOS
//palette index. Alpha is deliberately ignored. Call HTRInit once at startup.

#define HTR_SPREAD	0.18

class CHtRenderRgb { F64 r,g,b; };

CHtRenderRgb htr_palette[16];
U8 htr_lut[32768];
I64 htr_bayer[16]={0,8,2,10,12,4,14,6,3,11,1,9,15,7,13,5};
I64 htr_bofs[16];

U8 HtQuantize(I64 r88,I64 g88,I64 b88,I64 sx,I64 sy)
{//RGBA RGB (8.8 fixed, 0..0x100 = 0..1.0) + screen position -> index.
 //Deterministic: the same inputs give the same output; screen coords select
 //the Bayer cell. Parentheses are explicit because HolyC precedence is not C.
  I64 o=htr_bofs[((sy&3)*4)+(sx&3)],r5,g5,b5;
  r5=ClampI64(((r88+o)*31)>>8,0,31);
  g5=ClampI64(((g88+o)*31)>>8,0,31);
  b5=ClampI64(((b88+o)*31)>>8,0,31);
  return htr_lut[(r5<<10)+(g5<<5)+b5];
}

U0 HTRInit()
{//Build the standard-palette nearest-color LUT and fixed Bayer offsets once.
 //Palette ground truth: vendor/TempleOS/Adam/Gr/GrPalette.HC:64-68.
 //Each component below is the corresponding CBGR48 U16 divided by 65535.
  I64 i,r5,g5,b5,p,best;
  F64 r,g,b,dr,dg,db,d,best_d;
  htr_palette[0].r=0.0;       htr_palette[0].g=0.0;       htr_palette[0].b=0.0;
  htr_palette[1].r=0.0;       htr_palette[1].g=0.0;       htr_palette[1].b=2.0/3.0;
  htr_palette[2].r=0.0;       htr_palette[2].g=2.0/3.0;   htr_palette[2].b=0.0;
  htr_palette[3].r=0.0;       htr_palette[3].g=2.0/3.0;   htr_palette[3].b=2.0/3.0;
  htr_palette[4].r=2.0/3.0;   htr_palette[4].g=0.0;       htr_palette[4].b=0.0;
  htr_palette[5].r=2.0/3.0;   htr_palette[5].g=0.0;       htr_palette[5].b=2.0/3.0;
  htr_palette[6].r=2.0/3.0;   htr_palette[6].g=1.0/3.0;   htr_palette[6].b=0.0;
  htr_palette[7].r=2.0/3.0;   htr_palette[7].g=2.0/3.0;   htr_palette[7].b=2.0/3.0;
  htr_palette[8].r=1.0/3.0;   htr_palette[8].g=1.0/3.0;   htr_palette[8].b=1.0/3.0;
  htr_palette[9].r=1.0/3.0;   htr_palette[9].g=1.0/3.0;   htr_palette[9].b=1.0;
  htr_palette[10].r=1.0/3.0;  htr_palette[10].g=1.0;      htr_palette[10].b=1.0/3.0;
  htr_palette[11].r=1.0/3.0;  htr_palette[11].g=1.0;      htr_palette[11].b=1.0;
  htr_palette[12].r=1.0;      htr_palette[12].g=1.0/3.0;  htr_palette[12].b=1.0/3.0;
  htr_palette[13].r=1.0;      htr_palette[13].g=1.0/3.0;  htr_palette[13].b=1.0;
  htr_palette[14].r=1.0;      htr_palette[14].g=1.0;      htr_palette[14].b=1.0/3.0;
  htr_palette[15].r=1.0;      htr_palette[15].g=1.0;      htr_palette[15].b=1.0;
  for (i=0;i<16;i++)
    htr_bofs[i]=ToI64(Round((((htr_bayer[i]+0.5)/16.0-0.5)*HTR_SPREAD)*256.0));
  for (r5=0;r5<32;r5++) {
    r=r5/31.0;
    for (g5=0;g5<32;g5++) {
      g=g5/31.0;
      for (b5=0;b5<32;b5++) {
        b=b5/31.0;
        best=0;
        best_d=1e30;
        for (p=0;p<16;p++) {
          dr=r-htr_palette[p].r;
          dg=g-htr_palette[p].g;
          db=b-htr_palette[p].b;
          d=dr*dr+dg*dg+db*db;
          if (d<best_d) {
            best_d=d;
            best=p;
          }
        }
        htr_lut[(r5<<10)+(g5<<5)+b5]=best;
      }
    }
  }
}
