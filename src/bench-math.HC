//holytoy perf-floor benchmark (plan 003) -- F64 vs LUT fixed-point plasma.
//Drives its OWN render loop (NOT draw_it): the winmgr caps draw_it at ~30fps,
//and a CPU-bound task is never preempted (Kernel/KInts.HC IRQ_TIMER restores
//the interrupted task), so tight loops here time raw math throughput. tS
//reads the HPET directly (Kernel/KMisc.HC:122) and keeps advancing.
//Prints "BENCH <variant> <n> ms/frame" lines; guest/RUN.HC dumps them to the
//run's guest.log. Each variant renders up to BM_MAX_FRAMES frames, stopping
//early after BM_MAX_SECS so the whole run fits RUN_TIMEOUT.

//==== BEGIN HTMATH (pasted copy -- canonical: src/holytoy/HTMATH.HC; only
//==== MAIN.HC reaches the guest, so the library rides along inline).

#define HTM_BITS	12
#define HTM_N		4096
#define HTM_MASK	4095

I64 htm_sin_tbl[HTM_N];   //sin(2*pi*i/HTM_N) * 2^30

U0 HTMInit()
{//Build the sine table. Once, at startup; NOT per frame.
  I64 i;
  for (i=0;i<HTM_N;i++)
    htm_sin_tbl[i]=ToI64(Round(Sin(2*pi*i/HTM_N)*0x40000000));
}

I64 HTMSin16(I64 a)
{//sin of angle a (turns, 16.16); returns 16.16 in [-0x10000,0x10000].
  I64 i=(a>>4)&HTM_MASK,f=a&15,s0=htm_sin_tbl[i];
  return (s0+(((htm_sin_tbl[(i+1)&HTM_MASK]-s0)*f)>>4))>>14;
}

I64 HTMCos16(I64 a)
{//cos = quarter-turn-shifted sin.
  return HTMSin16(a+0x4000);
}

I64 HTMSin22(I64 a)
{//sin of angle a (turns, 10.22); returns 10.22 in [-0x400000,0x400000].
  I64 i=(a>>10)&HTM_MASK,f=a&1023,s0=htm_sin_tbl[i];
  return (s0+(((htm_sin_tbl[(i+1)&HTM_MASK]-s0)*f)>>10))>>8;
}

I64 HTMCos22(I64 a)
{
  return HTMSin22(a+0x100000);
}

I64 HTMRad16(F64 r)
{//Radians -> turns in 16.16 (per-frame phase setup, not per-pixel).
  return ToI64(Round(r*(0x10000/(2*pi))));
}

I64 HTMRad22(F64 r)
{//Radians -> turns in 10.22.
  return ToI64(Round(r*(0x400000/(2*pi))));
}

//==== END HTMATH

#define BM_MAX_FRAMES	30
#define BM_MAX_SECS	3.0
#define BM_W		640
#define BM_H		480

CDC *bm_dc;      //gr.dc alias: persistent layer, body pokes are screen-absolute
I64 bm_stride;

//Plasma constants scaled to turns in each fixed format (set in BmMain).
I64 bm_k1_16,bm_k2_16,bm_k3_16,   //0.043 / 0.031 / 0.021 rad per pixel
    bm_k1_22,bm_k2_22,bm_k3_22;
F64 bm_k4t16,bm_k4t22;            //0.024 rad per dist unit -> fixed turns

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

U0 BmF64FrameNd(F64 t)
{//F64 formula minus the Sqrt-distance term (3 sines) -- the LUT variants
 //keep that term in F64, so nd variants expose the unmasked sin delta.
  I64 x,y,c;
  F64 v,fx,fy;
  for (y=0;y<BM_H;y++) {
    fy=y;
    for (x=0;x<BM_W;x++) {
      fx=x;
      v=Sin(fx*0.043+t)+
        Sin(fy*0.031-t*0.7)+
        Sin((fx+fy)*0.021+t*0.5);
      c=ToI64(v*4.0)&15;
      bm_dc->body[y*bm_stride+x]=c;
    }
  }
}

U0 BmFx16Frame(F64 t)
{//Same formula/constants scaled to 16.16 turns; the Sqrt-distance term stays
 //F64 (no fixed sqrt yet -- see the nd variants). c=(v>>14)&15 floors where
 //ToI64 truncates; differs only for v<0 and &15 wraps either way.
  I64 x,y,c,v,a2,a4;
  I64 p1=HTMRad16(t),p2=HTMRad16(-0.7*t),p3=HTMRad16(0.5*t),p4=HTMRad16(-1.3*t);
  F64 fx,fy;
  for (y=0;y<BM_H;y++) {
    fy=y;
    a2=y*bm_k2_16+p2;
    for (x=0;x<BM_W;x++) {
      fx=x;
      a4=ToI64(Sqrt(fx*fx+fy*fy)*bm_k4t16)+p4;
      v=HTMSin16(x*bm_k1_16+p1)+HTMSin16(a2)+
        HTMSin16((x+y)*bm_k3_16+p3)+HTMSin16(a4);
      c=(v>>14)&15;
      bm_dc->body[y*bm_stride+x]=c;
    }
  }
}

U0 BmFx16Frame160(F64 t)
{//16.16 at render-scale: shade 160x120, fill 4x4 blocks.
  I64 bx,by,x0,y0,dy,o,c,v,a2,a4;
  I64 p1=HTMRad16(t),p2=HTMRad16(-0.7*t),p3=HTMRad16(0.5*t),p4=HTMRad16(-1.3*t);
  F64 fx,fy;
  for (by=0;by<120;by++) {
    y0=by*4;
    fy=y0;
    a2=y0*bm_k2_16+p2;
    for (bx=0;bx<160;bx++) {
      x0=bx*4;
      fx=x0;
      a4=ToI64(Sqrt(fx*fx+fy*fy)*bm_k4t16)+p4;
      v=HTMSin16(x0*bm_k1_16+p1)+HTMSin16(a2)+
        HTMSin16((x0+y0)*bm_k3_16+p3)+HTMSin16(a4);
      c=(v>>14)&15;
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

U0 BmFx16FrameNd(F64 t)
{//16.16, distance term dropped (3 LUT sines, no F64 per pixel at all).
  I64 x,y,c,v,a2;
  I64 p1=HTMRad16(t),p2=HTMRad16(-0.7*t),p3=HTMRad16(0.5*t);
  for (y=0;y<BM_H;y++) {
    a2=y*bm_k2_16+p2;
    for (x=0;x<BM_W;x++) {
      v=HTMSin16(x*bm_k1_16+p1)+HTMSin16(a2)+
        HTMSin16((x+y)*bm_k3_16+p3);
      c=(v>>14)&15;
      bm_dc->body[y*bm_stride+x]=c;
    }
  }
}

U0 BmFx22Frame(F64 t)
{//10.22 turns; v is a sum of four 10.22 sines; v*4 -> c is (v>>20)&15.
  I64 x,y,c,v,a2,a4;
  I64 p1=HTMRad22(t),p2=HTMRad22(-0.7*t),p3=HTMRad22(0.5*t),p4=HTMRad22(-1.3*t);
  F64 fx,fy;
  for (y=0;y<BM_H;y++) {
    fy=y;
    a2=y*bm_k2_22+p2;
    for (x=0;x<BM_W;x++) {
      fx=x;
      a4=ToI64(Sqrt(fx*fx+fy*fy)*bm_k4t22)+p4;
      v=HTMSin22(x*bm_k1_22+p1)+HTMSin22(a2)+
        HTMSin22((x+y)*bm_k3_22+p3)+HTMSin22(a4);
      c=(v>>20)&15;
      bm_dc->body[y*bm_stride+x]=c;
    }
  }
}

U0 BmFx22Frame160(F64 t)
{//10.22 at render-scale.
  I64 bx,by,x0,y0,dy,o,c,v,a2,a4;
  I64 p1=HTMRad22(t),p2=HTMRad22(-0.7*t),p3=HTMRad22(0.5*t),p4=HTMRad22(-1.3*t);
  F64 fx,fy;
  for (by=0;by<120;by++) {
    y0=by*4;
    fy=y0;
    a2=y0*bm_k2_22+p2;
    for (bx=0;bx<160;bx++) {
      x0=bx*4;
      fx=x0;
      a4=ToI64(Sqrt(fx*fx+fy*fy)*bm_k4t22)+p4;
      v=HTMSin22(x0*bm_k1_22+p1)+HTMSin22(a2)+
        HTMSin22((x0+y0)*bm_k3_22+p3)+HTMSin22(a4);
      c=(v>>20)&15;
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

U0 BmFx22FrameNd(F64 t)
{//10.22, distance term dropped.
  I64 x,y,c,v,a2;
  I64 p1=HTMRad22(t),p2=HTMRad22(-0.7*t),p3=HTMRad22(0.5*t);
  for (y=0;y<BM_H;y++) {
    a2=y*bm_k2_22+p2;
    for (x=0;x<BM_W;x++) {
      v=HTMSin22(x*bm_k1_22+p1)+HTMSin22(a2)+
        HTMSin22((x+y)*bm_k3_22+p3);
      c=(v>>20)&15;
      bm_dc->body[y*bm_stride+x]=c;
    }
  }
}

U0 BmParity(F64 t)
{//Visual parity: left half F64, right half 16.16 LUT, same t. Continuous
 //pattern across the x=320 seam = the LUT matches. Left as the final frame
 //for the host screenshot.
  I64 x,y,c,v16,a2,a4;
  I64 p1=HTMRad16(t),p2=HTMRad16(-0.7*t),p3=HTMRad16(0.5*t),p4=HTMRad16(-1.3*t);
  F64 v,fx,fy;
  for (y=0;y<BM_H;y++) {
    fy=y;
    a2=y*bm_k2_16+p2;
    for (x=0;x<BM_W;x++) {
      fx=x;
      if (x<BM_W/2) {
        v=Sin(fx*0.043+t)+
          Sin(fy*0.031-t*0.7)+
          Sin((fx+fy)*0.021+t*0.5)+
          Sin(Sqrt(fx*fx+fy*fy)*0.024-t*1.3);
        c=ToI64(v*4.0)&15;
      } else {
        a4=ToI64(Sqrt(fx*fx+fy*fy)*bm_k4t16)+p4;
        v16=HTMSin16(x*bm_k1_16+p1)+HTMSin16(a2)+
          HTMSin16((x+y)*bm_k3_16+p3)+HTMSin16(a4);
        c=(v16>>14)&15;
      }
      bm_dc->body[y*bm_stride+x]=c;
    }
  }
  for (y=0;y<8;y++)                    //seam ticks, top and bottom
    bm_dc->body[y*bm_stride+BM_W/2]=WHITE;
  for (y=BM_H-8;y<BM_H;y++)
    bm_dc->body[y*bm_stride+BM_W/2]=WHITE;
}

U0 BmSanity()
{//LUT sin at 0 / quarter / half turn: catches off-by-one table indexing.
  "BENCH sanity16 %d %d %d expect 0 65536 0\n",
    HTMSin16(0),HTMSin16(0x4000),HTMSin16(0x8000);
  "BENCH sanity22 %d %d %d expect 0 4194304 0\n",
    HTMSin22(0),HTMSin22(0x100000),HTMSin22(0x200000);
}

U0 BmAccuracy()
{//Max |LUT sin - Sin| over 10k angles, both formats, angle quantization
 //included (angles pass through the fixed format like real callers').
 //Gate tightened to 10/65536 because lookups interpolate: the bound is
 //dominated by 16.16 angle quantization (2*pi/65536 =~ 6.3/65536), not by
 //the plan's no-interpolation table bound (2/4096 = 32/65536).
  I64 i;
  F64 a,ref,got,err,maxe=0;
  for (i=0;i<10000;i++) {
    a=i/10000.0;                        //turns
    ref=Sin(2*pi*a);
    got=HTMSin16(ToI64(a*0x10000))/65536.0;
    err=Abs(got-ref);
    if (err>maxe) maxe=err;
    got=HTMSin22(ToI64(a*0x400000))/4194304.0;
    err=Abs(got-ref);
    if (err>maxe) maxe=err;
  }
  i=ToI64(Ceil(maxe*0x10000));
  if (maxe<=10.0/0x10000)
    "BENCH maxerr %d/65536 OK\n",i;
  else
    "BENCH maxerr %d/65536 FAIL\n",i;
}

I64 BmTime(I64 which)
{//Frames until cap; returns rounded ms/frame. Times ONLY the render loop.
  I64 frames=0;
  F64 t0;
  t0=tS;
  while (frames<BM_MAX_FRAMES) {
    switch (which) {
      case 0: BmF64Frame(frames*0.1);     break;
      case 1: BmF64Frame160(frames*0.1);  break;
      case 2: BmFx16Frame(frames*0.1);    break;
      case 3: BmFx16Frame160(frames*0.1); break;
      case 4: BmFx22Frame(frames*0.1);    break;
      case 5: BmFx22Frame160(frames*0.1); break;
      case 6: BmF64FrameNd(frames*0.1);   break;
      case 7: BmFx16FrameNd(frames*0.1);  break;
      case 8: BmFx22FrameNd(frames*0.1);  break;
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
  HTMInit;                       //table generation excluded from timing
  bm_k1_16=HTMRad16(0.043);
  bm_k2_16=HTMRad16(0.031);
  bm_k3_16=HTMRad16(0.021);
  bm_k1_22=HTMRad22(0.043);
  bm_k2_22=HTMRad22(0.031);
  bm_k3_22=HTMRad22(0.021);
  bm_k4t16=0.024*0x10000/(2*pi);
  bm_k4t22=0.024*0x400000/(2*pi);
  bm_dc=DCAlias;
  bm_stride=bm_dc->width_internal;
  BmSanity;
  BmAccuracy;
  "BENCH f64_640 %d ms/frame\n",BmTime(0);
  Yield;
  "BENCH f64_160 %d ms/frame\n",BmTime(1);
  Yield;
  "BENCH fx16_640 %d ms/frame\n",BmTime(2);
  Yield;
  "BENCH fx16_160 %d ms/frame\n",BmTime(3);
  Yield;
  "BENCH fx22_640 %d ms/frame\n",BmTime(4);
  Yield;
  "BENCH fx22_160 %d ms/frame\n",BmTime(5);
  Yield;
  "BENCH f64nd_640 %d ms/frame\n",BmTime(6);
  Yield;
  "BENCH fx16nd_640 %d ms/frame\n",BmTime(7);
  Yield;
  "BENCH fx22nd_640 %d ms/frame\n",BmTime(8);
  Yield;
  BmParity(1.0);
  DCDel(bm_dc);
}

BmMain;
