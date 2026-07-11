//holytoy perf-floor benchmark (plan 003) -- F64 vs LUT fixed-point plasma.
//Drives its OWN render loop (NOT draw_it): the winmgr caps draw_it at ~30fps,
//and a CPU-bound task is never preempted (Kernel/KInts.HC IRQ_TIMER restores
//the interrupted task), so tight loops here time raw math throughput. tS
//reads the HPET directly (Kernel/KMisc.HC:122) and keeps advancing.
//Prints "BENCH <variant> <n> ms/frame" lines; guest/RUN.HC dumps them to the
//run's guest.log. Each variant renders up to BM_MAX_FRAMES frames, stopping
//early after BM_MAX_SECS so the whole run fits RUN_TIMEOUT.

#define BM_MAX_FRAMES	30
#define BM_MAX_SECS	3.0
#define BM_W		640
#define BM_H		480

CDC *bm_dc;      //gr.dc alias: persistent layer, body pokes are screen-absolute
I64 bm_stride;

U0 BmPalette()
{//Cyclic sine RGB ramp (same as src/plasma.HC) so index wrap (&15) is seamless.
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

U0 BmF64Frame(F64 t)
{//Reference workload: src/plasma.HC formula, full 640x480, F64 Sin/Sqrt.
  I64 x,y,c;
  F64 v,fx,fy;
  for (y=0;y<BM_H;y++) {
    fy=y;
    for (x=0;x<BM_W;x++) {
      fx=x;
      v=Sin(fx*0.043+t)+
        Sin(fy*0.031-t*0.7)+
        Sin((fx+fy)*0.021+t*0.5)+
        Sin(Sqrt(fx*fx+fy*fy)*0.024-t*1.3);
      c=ToI64(v*4.0)&15;
      bm_dc->body[y*bm_stride+x]=c;
    }
  }
}

U0 BmF64Frame160(F64 t)
{//Render-scale: shade 160x120 (sampling full-res coords), fill 4x4 blocks.
  I64 bx,by,x0,y0,dy,o,c;
  F64 v,fx,fy;
  for (by=0;by<120;by++) {
    y0=by*4;
    fy=y0;
    for (bx=0;bx<160;bx++) {
      x0=bx*4;
      fx=x0;
      v=Sin(fx*0.043+t)+
        Sin(fy*0.031-t*0.7)+
        Sin((fx+fy)*0.021+t*0.5)+
        Sin(Sqrt(fx*fx+fy*fy)*0.024-t*1.3);
      c=ToI64(v*4.0)&15;
      for (dy=0;dy<4;dy++) {
        o=(y0+dy)*bm_stride+x0;
        bm_dc->body[o]=c;
        bm_dc->body[o+1]=c;
        bm_dc->body[o+2]=c;
        bm_dc->body[o+3]=c;
      }
    }
  }
}

I64 BmTime(I64 which)
{//Frames until cap; returns rounded ms/frame. Times ONLY the render loop.
  I64 frames=0;
  F64 t0;
  t0=tS;
  while (frames<BM_MAX_FRAMES) {
    switch (which) {
      case 0: BmF64Frame(frames*0.1);    break;
      case 1: BmF64Frame160(frames*0.1); break;
    }
    frames++;
    if (frames>=2 && tS-t0>=BM_MAX_SECS)
      break;
  }
  return ToI64(1000.0*(tS-t0)/frames+0.5);
}

U0 BmMain()
{
  BmPalette;
  bm_dc=DCAlias;
  bm_stride=bm_dc->width_internal;
  "BENCH f64_640 %d ms/frame\n",BmTime(0);
  Yield;
  "BENCH f64_160 %d ms/frame\n",BmTime(1);
  Yield;
  DCDel(bm_dc);
}

BmMain;
