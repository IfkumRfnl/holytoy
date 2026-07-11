//Classic per-pixel PLASMA. Full-window effect via direct dc->body pokes
//inside a draw_it callback, animated with tS. Smooth sine RGB palette.

U0 PlasmaPalette()
{//Cyclic sine RGB ramp so palette index wrap (&15) is seamless.
  I64 i;
  CBGR48 bgr;
  F64 a;
  bgr.pad=0;
  for (i=0;i<COLORS_NUM;i++) {
    a=2*π*i/COLORS_NUM;                 // one full turn across the 16 indices
    bgr.r=(Sin(a)        *0.5+0.5)*0xFFFF;  // 6 msbits reach the VGA DAC
    bgr.g=(Sin(a+2*π/3)  *0.5+0.5)*0xFFFF;  // +120deg
    bgr.b=(Sin(a+4*π/3)  *0.5+0.5)*0xFFFF;  // +240deg
    GrPaletteColorSet(i,bgr);
  }
}

U0 DrawIt(CTask *task,CDC *dc)
{//dc is a gr.dc2 alias clipped to us; body pokes are ABSOLUTE screen coords.
  I64 x,y,sx,sy,c,stride=dc->width_internal;
  F64 t=tS,v,fx,fy;
  for (y=0;y<task->pix_height;y++) {
    sy=task->pix_top+y;
    if (0<=sy<dc->height) {             // chained compare; bounds-check the poke
      fy=y;
      for (x=0;x<task->pix_width;x++) {
        sx=task->pix_left+x;
        if (0<=sx<stride) {
          fx=x;
          v=Sin(fx*0.043+t)+
            Sin(fy*0.031-t*0.7)+
            Sin((fx+fy)*0.021+t*0.5)+
            Sin(Sqrt(fx*fx+fy*fy)*0.024-t*1.3);
          c=ToI64(v*4.0)&15;            // * above &; &15 wraps to a 0-15 index
          dc->body[sy*stride+sx]=c;     // * above +: (sy*stride)+sx row-major
        }
      }
    }
  }
}

U0 Plasma()
{
  SettingsPush;                         // snapshots palette,draw_it,border,animate_task
  WinBorder;                            // border off
  WinMax;                               // maximize -> pix_left/top ~0
  DocClear;                             // clear command-line text behind us
  PlasmaPalette;                        // smooth palette set up BEFORE the loop
  Fs->draw_it=&DrawIt;
  try {                                 // survive CTRL-ALT-c
    while (!ScanChar)                   // any key exits
      Sleep(20);
  } catch
    PutExcept;
  SettingsPop;                          // restores palette+draw_it, kills animate_task
}

Plasma;
