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

//plan 015 Stage C: scene-adaptive palette. When htr_pal_mode is on
//(E:/PAL.TXT "adaptive"; HT.HC gates it to single-shader GLSL runs and GUI
//sessions only), the 10 non-reserved DAC entries {1,2,3,4,5,6,8,9,11,13}
//track the scene while {0,7,10,12,14,15} (BLACK, LTGRAY, LTGREEN, LTRED,
//YELLOW, WHITE - every color HtDrawPane uses) keep their standard values.
//HtShadeBand piggybacks a per-band 3:3:3 RGB histogram (count + 8.16
//channel sums per bin, NO shared mutable state across workers) on the
//shading loop; the render task merges the partials in FIXED band-index
//order at the publish point and runs a warm-started weighted k-means
//(k=10, 3 Lloyd iterations; the 6 reserved entries participate as
//immovable anchors so near-standard mass never wastes an adaptive entry),
//luminance-orders the centroids for stable index identity, smooths them
//(alpha 0.15 with an exact L1 snap so a static scene reaches a bit-exact
//fixed point in ~40 frames), and re-programs DAC + htr_lut TOGETHER, at
//most every HTR_PAL_PERIOD frames and only when a 6-bit DAC channel
//actually changes (hysteresis; keeps the LUT and the DAC consistent at
//every instant). Everything is a pure function of frame content: no wall
//clock, no completion-order dependence, integer histogram merges are
//exact, and F64 reductions run in fixed bin order - so CORES=1 and
//CORES=4 stay byte-identical (proof 17). The fixed path (mode off, the
//default) never touches any of this state.
#define HTR_PAL_BINS	512	//3:3:3 RGB histogram bins
#define HTR_PAL_BANDS	64	//>= HT.HC's HT_BANDS_MAX band ceiling
#define HTR_PAL_K	10	//adaptive DAC entries
#define HTR_PAL_ANCH	6	//reserved (fixed) DAC entries
#define HTR_PAL_PERIOD	8	//min frames between DAC+LUT reprograms
#define HTR_PAL_ALPHA	0.15	//centroid smoothing factor
#define HTR_PAL_SNAP	0.004	//L1 snap: static scenes reach an exact fixed point

I64 htr_pal_mode=0;		//0 fixed (default); 1 adaptive (HT.HC gates)
I64 htr_pal_idx[HTR_PAL_K]={1,2,3,4,5,6,8,9,11,13};
I64 htr_pal_resv[HTR_PAL_ANCH]={0,7,10,12,14,15};
I64 *htr_pal_hist=NULL;		//per-band partials [band][bin*4]: cnt,r,g,b
I64 *htr_pal_merge=NULL;	//core-0 merged histogram [bin*4]
F64 *htr_pal_binm=NULL;		//scratch: compacted nonempty bin means [n*3]
I64 *htr_pal_binw=NULL;		//scratch: compacted nonempty bin weights
I64 *htr_pal_rank=NULL;		//scratch: bins by descending weight (lazy)
F64 htr_pal_cent[HTR_PAL_K*3];	//smoothed centroids, luminance-ordered
I64 htr_pal_dac[HTR_PAL_K*3];	//programmed 6-bit DAC values; -1 = never
I64 htr_pal_since=99999;	//frames since last DAC+LUT reprogram

U0 HtrPalReset()
{//Deterministic gray-ramp centroid seed (already luminance-ordered) and an
 //unprogrammed DAC, so the first published frame reprograms immediately.
 //Called at init and on every successful shader swap (palette history never
 //crosses shaders - the swap point holds HtRenderPause, so this never races
 //HtrPalFrame, which runs inside the render task's busy window).
  I64 j;
  for (j=0;j<HTR_PAL_K;j++) {
    htr_pal_cent[(j*3)+0]=(j+0.5)/HTR_PAL_K;
    htr_pal_cent[(j*3)+1]=(j+0.5)/HTR_PAL_K;
    htr_pal_cent[(j*3)+2]=(j+0.5)/HTR_PAL_K;
    htr_pal_dac[(j*3)+0]=-1;
    htr_pal_dac[(j*3)+1]=-1;
    htr_pal_dac[(j*3)+2]=-1;
  }
  htr_pal_since=99999;
}

U0 HtrPalInit()
{//Allocate the per-band partials and core-0 scratch once (called from HT.HC
 //startup only when adaptive mode is on; the fixed path allocates nothing).
  htr_pal_hist=MAlloc(HTR_PAL_BANDS*HTR_PAL_BINS*4*sizeof(I64));
  MemSet(htr_pal_hist,0,HTR_PAL_BANDS*HTR_PAL_BINS*4*sizeof(I64));
  htr_pal_merge=MAlloc(HTR_PAL_BINS*4*sizeof(I64));
  htr_pal_binm=MAlloc(HTR_PAL_BINS*3*sizeof(F64));
  htr_pal_binw=MAlloc(HTR_PAL_BINS*sizeof(I64));
  htr_pal_rank=MAlloc(HTR_PAL_BINS*sizeof(I64));
  HtrPalReset;
}

U0 HtrPalLutRebuild()
{//Rebuild htr_lut in place against the CURRENT display palette: reserved
 //entries at their standard colors, adaptive entries at their programmed
 //6-bit DAC values (DAC-quantized, so the LUT is a pure function of the
 //programmed palette). 2-4 ms; called only from the render task between
 //frames while no worker is shading (the JobResGet barrier has drained),
 //so the in-place rewrite is race-free. HtQuantize also reads htr_lut, but
 //only from HtSelfTest, where adaptive mode never engages.
  F64 tr[16],tg[16],tb[16],r,g,b,dr,dg,db,d,best_d;
  I64 i,j,r5,g5,b5,best;
  for (i=0;i<16;i++) {
    tr[i]=htr_palette[i].r;
    tg[i]=htr_palette[i].g;
    tb[i]=htr_palette[i].b;
  }
  for (j=0;j<HTR_PAL_K;j++) {
    i=htr_pal_idx[j];
    tr[i]=htr_pal_dac[(j*3)+0]/63.0;
    tg[i]=htr_pal_dac[(j*3)+1]/63.0;
    tb[i]=htr_pal_dac[(j*3)+2]/63.0;
  }
  for (r5=0;r5<32;r5++) {
    r=r5/31.0;
    for (g5=0;g5<32;g5++) {
      g=g5/31.0;
      for (b5=0;b5<32;b5++) {
        b=b5/31.0;
        best=0;
        best_d=1e30;
        for (i=0;i<16;i++) {
          dr=r-tr[i];
          dg=g-tg[i];
          db=b-tb[i];
          d=(dr*dr)+(dg*dg)+(db*db);
          if (d<best_d) {
            best_d=d;
            best=i;
          }
        }
        htr_lut[(r5<<10)+(g5<<5)+b5]=best;
      }
    }
  }
}

U0 HtrPalFrame(I64 nbands)
{//Core-0 publish-point palette update (see the module comment above).
 //Deterministic by construction: fixed band merge order, fixed bin
 //iteration order, warm start from the luminance-ordered smoothed
 //centroids, first-wins nearest-target ties.
  I64 i,j,k,n,w,best,cyc,qq[HTR_PAL_K*3],q,ranked;
  I64 *hp;
  Bool changed;
  F64 tr[16],tg[16],tb[16],wr[HTR_PAL_K],wg[HTR_PAL_K],wb[HTR_PAL_K],
      ar[HTR_PAL_K],ag[HTR_PAL_K],ab[HTR_PAL_K],aw[HTR_PAL_K],
      r,g,b,d,dr,dg,db,best_d,lum,lum2;
  if (!htr_pal_hist) return;
  if (nbands>HTR_PAL_BANDS) nbands=HTR_PAL_BANDS;
  //1. Merge the per-band partials in band-index order (integer adds: exact
  //and decomposition-invariant; the band sample sets are disjoint by the
  //HtShadeBand accumulation contract).
  MemSet(htr_pal_merge,0,HTR_PAL_BINS*4*sizeof(I64));
  for (k=0;k<nbands;k++) {
    hp=&htr_pal_hist[k*(HTR_PAL_BINS*4)];
    for (i=0;i<HTR_PAL_BINS*4;i++)
      htr_pal_merge[i]+=hp[i];
  }
  //2. Compact the nonempty bins: exact mean color (8.16 sums / count) and
  //weight, in ascending bin order.
  n=0;
  for (i=0;i<HTR_PAL_BINS;i++) {
    w=htr_pal_merge[i*4];
    if (w>0) {
      htr_pal_binw[n]=w;
      htr_pal_binm[(n*3)+0]=htr_pal_merge[(i*4)+1]/(w*65536.0);
      htr_pal_binm[(n*3)+1]=htr_pal_merge[(i*4)+2]/(w*65536.0);
      htr_pal_binm[(n*3)+2]=htr_pal_merge[(i*4)+3]/(w*65536.0);
      n++;
    }
  }
  if (!n) return;		//nothing shaded: keep the current palette
  ranked=FALSE;
  //3. Weighted k-means, warm-started from the smoothed centroids. Targets
  //are the 16 display slots: 6 immovable anchors (reserved standard colors,
  //slots 0..5) + 10 movable work centroids (slots 6..15).
  for (j=0;j<HTR_PAL_K;j++) {
    wr[j]=htr_pal_cent[(j*3)+0];
    wg[j]=htr_pal_cent[(j*3)+1];
    wb[j]=htr_pal_cent[(j*3)+2];
  }
  for (k=0;k<3;k++) {
    for (i=0;i<HTR_PAL_ANCH;i++) {
      tr[i]=htr_palette[htr_pal_resv[i]].r;
      tg[i]=htr_palette[htr_pal_resv[i]].g;
      tb[i]=htr_palette[htr_pal_resv[i]].b;
    }
    for (j=0;j<HTR_PAL_K;j++) {
      tr[HTR_PAL_ANCH+j]=wr[j];
      tg[HTR_PAL_ANCH+j]=wg[j];
      tb[HTR_PAL_ANCH+j]=wb[j];
      ar[j]=0.0; ag[j]=0.0; ab[j]=0.0; aw[j]=0.0;
    }
    for (i=0;i<n;i++) {
      r=htr_pal_binm[(i*3)+0];
      g=htr_pal_binm[(i*3)+1];
      b=htr_pal_binm[(i*3)+2];
      best=0;
      best_d=1e30;
      for (j=0;j<16;j++) {
        dr=r-tr[j];
        dg=g-tg[j];
        db=b-tb[j];
        d=(dr*dr)+(dg*dg)+(db*db);
        if (d<best_d) {
          best_d=d;
          best=j;
        }
      }
      if (best>=HTR_PAL_ANCH) {
        w=htr_pal_binw[i];
        ar[best-HTR_PAL_ANCH]+=w*r;
        ag[best-HTR_PAL_ANCH]+=w*g;
        ab[best-HTR_PAL_ANCH]+=w*b;
        aw[best-HTR_PAL_ANCH]+=w;
      }
    }
    cyc=0;
    for (j=0;j<HTR_PAL_K;j++) {
      if (aw[j]>0.0) {
        wr[j]=ar[j]/aw[j];
        wg[j]=ag[j]/aw[j];
        wb[j]=ab[j]/aw[j];
      } else {
        //Empty cluster: move it onto the worst-served bin (max weight *
        //distance^2 to its nearest CURRENT target, anchors + updated work
        //centroids including earlier refills this pass). If every bin sits
        //exactly on a target already (degenerate scenes with fewer distinct
        //colors than entries), duplicate the heaviest bins round-robin so
        //all 10 entries land on scene colors. Both rules are deterministic.
        best=0;
        best_d=-1.0;
        for (i=0;i<n;i++) {
          r=htr_pal_binm[(i*3)+0];
          g=htr_pal_binm[(i*3)+1];
          b=htr_pal_binm[(i*3)+2];
          //nearest current target (anchors + work; skip THIS empty slot)
          lum=1e30;
          for (q=0;q<HTR_PAL_ANCH;q++) {
            dr=r-htr_palette[htr_pal_resv[q]].r;
            dg=g-htr_palette[htr_pal_resv[q]].g;
            db=b-htr_palette[htr_pal_resv[q]].b;
            d=(dr*dr)+(dg*dg)+(db*db);
            if (d<lum) lum=d;
          }
          for (q=0;q<HTR_PAL_K;q++) {
            if (q!=j) {
              dr=r-wr[q];
              dg=g-wg[q];
              db=b-wb[q];
              d=(dr*dr)+(dg*dg)+(db*db);
              if (d<lum) lum=d;
            }
          }
          d=htr_pal_binw[i]*lum;
          if (d>best_d) {
            best_d=d;
            best=i;
          }
        }
        if (best_d<=1e-12) {
          //all bins served exactly: duplicate heaviest bins round-robin
          if (!ranked) {
            for (i=0;i<n;i++)
              htr_pal_rank[i]=i;
            for (i=1;i<n;i++) {
              q=htr_pal_rank[i];
              w=i-1;
              while (w>=0 && htr_pal_binw[htr_pal_rank[w]]<htr_pal_binw[q]) {
                htr_pal_rank[w+1]=htr_pal_rank[w];
                w--;
              }
              htr_pal_rank[w+1]=q;
            }
            ranked=TRUE;
          }
          best=htr_pal_rank[cyc%n];
          cyc++;
        }
        wr[j]=htr_pal_binm[(best*3)+0];
        wg[j]=htr_pal_binm[(best*3)+1];
        wb[j]=htr_pal_binm[(best*3)+2];
      }
    }
  }
  //4. Luminance-order the work centroids (stable index identity across
  //frames; deterministic tie-break by r, then g, then b).
  for (i=1;i<HTR_PAL_K;i++) {
    r=wr[i]; g=wg[i]; b=wb[i];
    lum=(0.299*r)+(0.587*g)+(0.114*b);
    j=i-1;
    while (j>=0) {
      lum2=(0.299*wr[j])+(0.587*wg[j])+(0.114*wb[j]);
      if (lum2>lum ||
          (lum2==lum && (wr[j]>r ||
           (wr[j]==r && (wg[j]>g || (wg[j]==g && wb[j]>b)))))) {
        wr[j+1]=wr[j]; wg[j+1]=wg[j]; wb[j+1]=wb[j];
        j--;
      } else
        break;
    }
    wr[j+1]=r; wg[j+1]=g; wb[j+1]=b;
  }
  //5. Exponential smoothing with an exact snap (static scenes converge to
  //a bit-exact fixed point, so DAC/LUT churn provably stops).
  for (j=0;j<HTR_PAL_K;j++) {
    dr=wr[j]-htr_pal_cent[(j*3)+0];
    dg=wg[j]-htr_pal_cent[(j*3)+1];
    db=wb[j]-htr_pal_cent[(j*3)+2];
    if (Abs(dr)+Abs(dg)+Abs(db)<HTR_PAL_SNAP) {
      htr_pal_cent[(j*3)+0]=wr[j];
      htr_pal_cent[(j*3)+1]=wg[j];
      htr_pal_cent[(j*3)+2]=wb[j];
    } else {
      htr_pal_cent[(j*3)+0]+=HTR_PAL_ALPHA*dr;
      htr_pal_cent[(j*3)+1]+=HTR_PAL_ALPHA*dg;
      htr_pal_cent[(j*3)+2]+=HTR_PAL_ALPHA*db;
    }
  }
  //6. Reprogram DAC + LUT together, at most every HTR_PAL_PERIOD frames and
  //only when a quantized 6-bit channel actually changed (hysteresis).
  changed=FALSE;
  for (i=0;i<HTR_PAL_K*3;i++) {
    q=ToI64((htr_pal_cent[i]*63.0)+0.5);
    if (q<0) q=0; else if (q>63) q=63;
    qq[i]=q;
    if (q!=htr_pal_dac[i])
      changed=TRUE;
  }
  htr_pal_since++;
  if (changed && htr_pal_since>=HTR_PAL_PERIOD) {
    for (i=0;i<HTR_PAL_K*3;i++)
      htr_pal_dac[i]=qq[i];
    HtrPalLutRebuild;
    htr_pal_since=0;
  }
  //7. Re-assert the adaptive DAC entries every published frame (5 port
  //writes each; guards against any external SettingsPop restoring the
  //standard palette mid-session). CBGR48 is an I64-typed class (U16 b,g,r):
  //a 6-bit value v displays as v<<10 in its channel (GrPalette.HC:30-44).
  for (j=0;j<HTR_PAL_K;j++) {
    if (htr_pal_dac[(j*3)+0]>=0)
      GrPaletteColorSet(htr_pal_idx[j],
        (htr_pal_dac[(j*3)+0]<<42)+(htr_pal_dac[(j*3)+1]<<26)+
        (htr_pal_dac[(j*3)+2]<<10));
  }
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
