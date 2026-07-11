//holytoy palette cycling — concentric rings drawn ONCE on the persistent layer
//(gr.dc), then a spawned task rotates palette entries 1..15 (~20Hz). The winmgr
//re-emits the unchanged gr.dc body to VGA every frame, so only DAC writes animate.
//Harness-mode: draw, spawn the cycler, return (guest/RUN.HC brackets us).

#define RING_WIDTH	6

CBGR48 palcyc_pal[COLORS_NUM];   //rainbow in [0..COLORS_NUM-2]; globals: task shares them

U0 CycleTask(I64)
{
  I64 i,j,offset=0;
  while (TRUE) {
    for (i=1;i<COLORS_NUM;i++) {          //rotate 1..15, keep 0 fixed
      j=(i-1+offset)%(COLORS_NUM-1);
      GrPaletteColorSet(i,palcyc_pal[j]);
    }
    offset++;
    Sleep(50);
  }
}

U0 PalCycle()
{
  CDC *dc=DCAlias;                        //persistent gr.dc layer
  I64 i,r,cx,cy,maxr;
  F64 a;
  for (i=0;i<COLORS_NUM-1;i++) {
    a=2*pi*i/(COLORS_NUM-1);
    palcyc_pal[i].r=32767.5*(Sin(a)+1);
    palcyc_pal[i].g=32767.5*(Sin(a+2*pi/3)+1);
    palcyc_pal[i].b=32767.5*(Sin(a+4*pi/3)+1);
    palcyc_pal[i].pad=0;
  }
  cx=Fs->pix_width/2;
  cy=Fs->pix_height/2;
  maxr=ToI64(Sqrt(cx*cx+cy*cy))+1;
  DCFill(dc,BLACK);
  for (r=maxr;r>0;r-=RING_WIDTH) {        //filled discs large-to-small: gap-free rings
    dc->color=((r/RING_WIDTH)%(COLORS_NUM-1))+1;
    GrFillCircle(dc,cx,cy,,2*r);          //non-trailing dft z; takes DIAMETER
  }
  DCDel(dc);
  Fs->animate_task=Spawn(&CycleTask,NULL,"Cycle",,Fs);  //SettingsPop kills it
}

PalCycle;
