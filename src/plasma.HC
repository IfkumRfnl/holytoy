//holytoy plasma — per-pixel dc->body pokes in draw_it, sine RGB palette.
//Harness-mode: set palette, install draw_it, return (guest/RUN.HC brackets us).

U0 PlasmaPalette()
{//Cyclic sine RGB ramp so palette index wrap (&15) is seamless.
  I64 i;
  CBGR48 bgr;
  F64 a;
  bgr.pad=0;
  for (i=0;i<COLORS_NUM;i++) {
    a=2*pi*i/COLORS_NUM;
    bgr.r=(Sin(a)       *0.5+0.5)*0xFFFF;
    bgr.g=(Sin(a+2*pi/3)*0.5+0.5)*0xFFFF;
    bgr.b=(Sin(a+4*pi/3)*0.5+0.5)*0xFFFF;
    GrPaletteColorSet(i,bgr);
  }
}

U0 DrawIt(CTask *task,CDC *dc)
{//dc aliases gr.dc2 (full 640x480); raw body pokes are ABSOLUTE screen coords.
  I64 x,y,sx,sy,c,stride=dc->width_internal;
  F64 t=tS,v,fx,fy;
  for (y=0;y<task->pix_height;y++) {
    sy=task->pix_top+y;
    if (0<=sy<dc->height) {
      fy=y;
      for (x=0;x<task->pix_width;x++) {
        sx=task->pix_left+x;
        if (0<=sx<dc->width) {
          fx=x;
          v=Sin(fx*0.043+t)+
            Sin(fy*0.031-t*0.7)+
            Sin((fx+fy)*0.021+t*0.5)+
            Sin(Sqrt(fx*fx+fy*fy)*0.024-t*1.3);
          c=ToI64(v*4.0)&15;
          dc->body[sy*stride+sx]=c;
        }
      }
    }
  }
}

PlasmaPalette;
Fs->draw_it=&DrawIt;
