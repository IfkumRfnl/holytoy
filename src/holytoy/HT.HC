//HolyToy skeleton (plan 002): editable code pane + live animating viewport.
//The runner owns the pixels: draw_it iterates the viewport at ht_scale
//block granularity, calls MainImage through ht_fp for one sample per
//block, and pokes dc->body directly (src/plasma.HC idiom - absolute
//screen coords, stride=width_internal, no clipping).  The code pane is
//GrPrint'd from the same draw_it on the 8x8 font grid so the harness OCR
//(tools/scrtext.py) reads it exactly.
//Harness-mode: install draw_it and return; guest/RUN.HC brackets us.

#include "E:/HTMATH.HC"	//LUT sin/cos (16.16 turns); mkxfer.sh ships it always
#include "E:/HTRENDER.HC"	//RGBA palette quantizer; mkxfer.sh ships it always
#include "E:/HTLIB.HC"	//shader runtime: vector/matrix classes + builtins
#include "E:/HTPP.HC"	//in-guest GLSL compiler modules (plans 008/009)
#include "E:/HTLEX.HC"
#include "E:/HTPARSE.HC"
#include "E:/HTLOWER.HC"
#include "E:/HTEMIT.HC"
#include "E:/HTCOMP.HC"

#define HT_VIEW_H	288	//viewport: full width x 288 window pixels (~60%)
#define HT_PANE_ROW	36	//first code-pane text row (window row, 8px cells)
#define HT_SRC_ROWS	20	//source lines shown in the pane
#define HT_STATUS_ROW	58	//status/error line (last window row)
#define HT_GLSL_MAX	32768	//editor source; generated HolyC stays internal

class CHtFragColor { F64 r,g,b,a; };
class CHtUniforms
{
  F64 i_time;
  I64 i_frame;
  I64 res_x,res_y;
  I64 mouse_x,mouse_y;	//current viewport px, Y-down (raw)
  I64 mouse_lb;		//1 while left button is held
  I64 click_x,click_y;	//last press, viewport px, Y-down; -1 = never
  I64 date_year,date_mon,date_day;	//local date (iDate.xyz)
  F64 date_secs;	//seconds since local midnight (iDate.w)
};

CHtUniforms ht_u;

class CHtFrame
{//plan 011: per-frame derived Shadertoy uniforms. Filled once per frame by
 //HtFrameSetup on the control core, read-only during shading, so concurrent
 //ht_fp calls need no lock (see the reentrancy contract on ht_fp below).
  F64 itime,itdelta,ifrate;
  CHtV3 ires;
  CHtV4 imouse,idate;
  I64 iframe;
};
CHtFrame ht_frame;		//filled once/frame; read-only while shading

//plan 011 ht_fp reentrancy contract: ht_fp reads only its scalar frag args
//(per-call, private), the shared read-only ht_frame, and shared read-only
//const globals/LUTs; it writes only through out_color (caller-owned) and its
//own stack (CHtCtx, temps). Concurrent calls from multiple cores are safe
//WITHOUT a lock provided the caller guarantees: (1) ht_frame filled by
//HtFrameSetup before the first worker and not mutated until all workers for
//that frame have joined; (2) each concurrent call has a distinct
//CHtFragColor output; (3) no shader install/rebind runs during fan-out.
U0 (*ht_fp)(F64 frag_x,F64 frag_y,CHtFragColor *out_color);
U0 (*ht_default_fp)(F64 frag_x,F64 frag_y,CHtFragColor *out_color);
U8 ht_glsl_src[HT_GLSL_MAX];	//GLSL editor source; never replaced by HolyC
U8 ht_status[96];		//status/error line text
Bool ht_status_err;		//status line draws LTRED when TRUE
Bool ht_native_editor;		//a native CDoc backs the visible editor pane
I64 ht_edit_line,ht_edit_col;	//zero-based native CDoc cursor position
I64 ht_edit_top,ht_edit_left;	//visible source origin in lines/columns
I64 ht_shade_ms;		//last frame's shading time, whole ms (render task)
Bool ht_mouse_lb_prev;		//rising-edge state for iMouse click position
I64 ht_scale=16;		//runtime shade-block size: 1,2,4,8,16
I64 ht_scale_lock=0;		//0 = adaptive; otherwise pinned by SCALE.TXT
I64 ht_scale_slow=0,ht_scale_fast=0;	//controller consecutive frames

//plan 012: SMP background render task. Shading moves OUT of HtDrawIt into a
//dedicated render task (core 0) that fans contiguous block-row bands across
//worker cores 1..nb via JobQue/JobResGet into an offscreen double buffer;
//HtDrawIt shrinks to a pure blit of the last COMPLETE frame + pane, so the
//editor stays responsive no matter how slow a shader is. Byte-identical to
//the pre-012 single-core output by construction (disjoint bands, snapshotted
//uniforms, identical integer/F64 math). See plans/012-smp-background-render.md
//and the ht_fp reentrancy contract above.
#define HT_FB_MAXW	1024	//palette-index row stride ceiling (>= any viewport)
class CHtFrameBuf { CHtUniforms snap; U8 *pix; U8 *pix_raw; };
CHtFrameBuf ht_fb[2];		//double buffer: front (shown) + back (in work)
I64 ht_fb_stride=HT_FB_MAXW;	//64-aligned row stride into fb->pix
I64 ht_front_idx=0,ht_back_idx=1;	//published index (atomic word) / work index
Bool ht_have_frame=FALSE;	//a complete frame has been published at least once
I64 ht_render_cores;		//cores that shade; 1..mp_cnt (1 => single-core)
I64 ht_render_pause=0;		//nesting pause count (0 = running); NOT a bit
I64 ht_render_busy=0;		//bit 0: a frame's fan-out is in flight
I64 ht_render_exit=0;		//set (with pause held) to tear the task down
CTask *ht_render_task=NULL;	//the spawned frame-loop task
CTask *ht_win_task=NULL;	//the HolyToy window task (viewport geometry)
class CHtBandDesc
{//one contiguous block-row band handed to a worker (or shaded inline).
  I64 band,y0_blk,y1_blk,nbx,vh,fb_idx,scale,pix_left,pix_top;
};
CHtBandDesc ht_desc[MP_PROCESSORS_NUM];

U0 HtRenderPause()
{//Quiesce the render task before touching long-lived shared state (ht_fp
 //rebind, buffer free, single-core visual dump/corpus). On return no worker
 //is executing ht_fp and no new frame will start until HtRenderResume. Uses
 //a nesting COUNT, not a bit, so a shader swap inside an already-paused
 //HtCorpusRun does not resume it early. Defined here (ahead of HtInstallHoly,
 //its first caller) since HolyC resolves calls top-down. Only core-0 tasks
 //call this; the render task never does.
  ht_render_pause++;
  while (Bt(&ht_render_busy,0))
    Yield;			//wait out at most one in-flight frame
}

U0 HtRenderResume()
{
  if (ht_render_pause>0)
    ht_render_pause--;
}

U8 *ht_glsl1=
"void mainImage(out vec4 fragColor, in vec2 fragCoord) {\n"
"  fragColor = vec4(fragCoord.y / iResolution.y);\n"
"}\n";

U8 *ht_glsl2=
"void mainImage(out vec4 fragColor, in vec2 fragCoord) {\n"
"  fragColor = vec4(1.0 - fragCoord.y / iResolution.y);\n"
"}\n";

U8 *ht_glsl_bad=
"void mainImage(out vec4 fragColor, in vec2 fragCoord) {\n"
"  fragColor = vec4(unknownName);\n"
"}\n";

U8 *ht_glsl_slow=
"// Deliberately expensive adaptive-scale fixture.\n"
"void mainImage(out vec4 fragColor, in vec2 fragCoord) {\n"
"  float v = fragCoord.x / iResolution.x;\n"
"  for (int i = 0; i < 40000; i++)\n"
"    v = fract(sin(v * 12.9898 + float(i)) * 43758.5453);\n"
"  fragColor = vec4(v);\n"
"}\n";

U8 *ht_glsl_ctx=
"// plan 011 per-invocation ctx self-test: a mutable global initialized to\n"
"// 2 each invocation, then bumped by +2 through a nested helper chain, must\n"
"// read back as 4 (=>1.0) on EVERY call - never accumulating across pixels.\n"
"int g_acc = 2;\n"
"void addOne() { g_acc += 1; }\n"
"void addTwo() { addOne(); addOne(); }\n"
"void mainImage(out vec4 fragColor, in vec2 fragCoord) {\n"
"  addTwo();\n"
"  fragColor = vec4(float(g_acc) / 4.0);\n"
"}\n";

U0 HtScaleReset()
{//A newly installed shader starts coarse; history never crosses shaders.
  ht_scale_slow=0;
  ht_scale_fast=0;
  if (!ht_scale_lock)
    ht_scale=16;
}

U0 MainImage(F64 frag_x,F64 frag_y,CHtFragColor *out_color)
{//Built-in last-good shader: plasma bands while GLSL is being edited.
  F64 t=ht_frame.itime,v;
  v=Sin(frag_x*0.021+t)+
    Sin(frag_y*0.032-t*0.7)+
    Sin((frag_x+frag_y)*0.014+t*0.5)+
    Sin(Sqrt(frag_x*frag_x+frag_y*frag_y)*0.019-t*1.3);
  out_color->r=0.5+v*0.125;
  out_color->g=0.5-v*0.125;
  out_color->b=0.75+v*0.0625;
  out_color->a=1.0;
}

U0 HtStatus(Bool err,U8 *fmt,...)
{//Set the pane status line (drawn by HtDrawPane).
  U8 *st=StrPrintJoin(NULL,fmt,argc,argv);
  StrCpy(ht_status,st);
  Free(st);
  ht_status_err=err;
}

U0 HtDrawPane(CTask *task,CDC *dc)
{//Code pane: draw the native CDoc's plain-text snapshot below the viewport.
  I64 sy,row,n,i,line_num=0,stride=dc->width_internal,
      y0=task->pix_top+HT_VIEW_H,y1=task->pix_top+task->pix_height;
  U8 *p=ht_glsl_src,line[81];
  if (y1>dc->height) y1=dc->height;
  for (sy=y0;sy<y1;sy++)
    MemSet(&dc->body[sy*stride+task->pix_left],BLACK,task->pix_width);
  dc->color=LTGRAY;
  GrPrint(dc,0,HT_PANE_ROW*FONT_HEIGHT,
          " HolyToy %3dms 1:%-2d F5 compile  F1-F2 samples  ESC exit",
          ht_shade_ms,ht_scale);
  while (*p && line_num<ht_edit_top) {
    while (*p && *p!='\n') p++;
    if (*p=='\n') p++;
    line_num++;
  }
  dc->color=WHITE;
  row=HT_PANE_ROW+1;
  while (row<HT_PANE_ROW+1+HT_SRC_ROWS &&
        (*p || line_num==ht_edit_line)) {
    n=0;
    i=0;
    while (*p && *p!='\n' && i<ht_edit_left) { p++; i++; }
    while (*p && *p!='\n' && n<78)
      line[n++]=*p++;
    line[n]=0;
    while (*p && *p!='\n') p++;
    if (*p=='\n') p++;
    GrPrint(dc,8,row*FONT_HEIGHT,"%s",line);
    row++;
    line_num++;
  }
  if (ht_native_editor && ht_edit_top<=ht_edit_line<ht_edit_top+HT_SRC_ROWS &&
      ht_edit_left<=ht_edit_col<ht_edit_left+78) {
    dc->color=YELLOW;
    GrPrint(dc,8+(ht_edit_col-ht_edit_left)*FONT_WIDTH,
            (HT_PANE_ROW+1+ht_edit_line-ht_edit_top)*FONT_HEIGHT,"_");
  }
  if (ht_status_err)
    dc->color=LTRED;
  else
    dc->color=LTGREEN;
  GrPrint(dc,0,HT_STATUS_ROW*FONT_HEIGHT," %s",ht_status);
}

U0 (*ht_new_fp)(F64 frag_x,F64 frag_y,CHtFragColor *out_color);

Bool HtInstallHoly(U8 *holy)
{//Compile generated HolyC in-task (ExePutS2, Compiler/CMain.HC:631 throws
 //catchable exceptions); rebind ht_fp only on success.  The fresh
 //&MainImage is taken INSIDE the compiled unit (src/reload.HC pattern) so
 //it binds the newly JITed code, not the code current when this function
 //was compiled. On failure the old shader keeps rendering. Generated HolyC
 //is never copied into the GLSL editor buffer.
  Bool ok=FALSE;
  I64 n=StrLen(holy),ec;
  U8 *buf,ecs[9];
  buf=MStrPrint("%s\nht_new_fp=&MainImage;\n",holy);
  ht_new_fp=NULL;
  try {
    ExePutS2(buf);
    ok=TRUE;
  } catch {
    Fs->catch_except=TRUE;
    ec=Fs->except_ch;
    MemCpy(ecs,&ec,8);
    ecs[8]=0;
    HtStatus(TRUE,"COMPILE ERR [%s]  previous shader kept",ecs);
  }
  Free(buf);
  if (ok) {
    if (ht_new_fp) {
      //plan 012: quiesce the render task so no worker is executing the old
      //ht_fp when we flip the pointer (011 contract 3: no rebind during
      //fan-out). The old shader stays live until the barrier, satisfying
      //"previous shader kept on error." ExePutS2 above ran unguarded because
      //it only APPENDS new JITed code; workers keep using the old ht_fp.
      HtRenderPause;
      ht_fp=ht_new_fp;
      HtRenderResume;
      HtStatus(FALSE,"OK  GLSL compiled (%d HolyC bytes)",n);
    } else {
      ok=FALSE;
      HtStatus(TRUE,"COMPILE ERR no MainImage bound");
    }
  }
  return ok;
}

Bool HtCompileAndSwapGlsl(U8 *glsl)
{//The one editor/startup compile path: preserve attempted GLSL in the pane,
 //compile it with the in-guest compiler, then atomically install generated
 //HolyC. The current shader remains live after either kind of failure.
  Bool ok;
  F64 started=tS;
  I64 n=StrLen(glsl),holy_n;
  CHtCompileResult result;
  if (n>HT_GLSL_MAX-1) {
    HtStatus(TRUE,"GLSL ERR source too long (%d>%d)",n,HT_GLSL_MAX-1);
    return FALSE;
  }
  if (glsl!=ht_glsl_src)
    StrCpy(ht_glsl_src,glsl);
  if (!HtCompileGlsl(ht_glsl_src,&result)) {
    HtStatus(TRUE,"GLSL ERR %s  previous shader kept",result.error);
    return FALSE;
  }
  ok=HtInstallHoly(result.holy);
  holy_n=StrLen(result.holy);
  HtCompileResultDel(&result);
  if (ok) {
    HtScaleReset;
    HtStatus(FALSE,"OK  GLSL->viewport %dms (%d HolyC bytes)",
             ToI64((tS-started)*1000.0),holy_n);
  }
  return ok;
}

U0 HtFrameSetup(CHtUniforms *u)
{//plan 011: derive the current frame's read-only uniforms from the raw
 //CHtUniforms once per frame, on the control core, before any worker runs.
 //This is the OLD generated stamp block, lifted verbatim to the runtime.
  ht_frame.itime=u->i_time;
  ht_frame.itdelta=1.0/30.0;
  ht_frame.ifrate=30.0;
  ht_frame.iframe=u->i_frame;
  ht_frame.ires.x=u->res_x;
  ht_frame.ires.y=u->res_y;
  ht_frame.ires.z=1.0;
  ht_frame.imouse.x=u->mouse_x;
  ht_frame.imouse.y=u->res_y-u->mouse_y;
  if (u->click_x<0) {
    ht_frame.imouse.z=0.0;
    ht_frame.imouse.w=0.0;
  } else {
    ht_frame.imouse.z=u->click_x;
    ht_frame.imouse.w=u->res_y-u->click_y;
    if (!u->mouse_lb) {
      ht_frame.imouse.z=-ht_frame.imouse.z;
      ht_frame.imouse.w=-ht_frame.imouse.w;
    }
  }
  ht_frame.idate.x=u->date_year;
  ht_frame.idate.y=u->date_mon;
  ht_frame.idate.z=u->date_day;
  ht_frame.idate.w=u->date_secs;
}

U0 HtShadeBand(CHtBandDesc *d)
{//plan 012: shade one contiguous block-row band into ht_fb[d->fb_idx].pix,
 //reproducing the pre-012 inline HtDrawIt block loop BYTE-FOR-BYTE: same
 //ToI64(fc.*256.0) 8.8 clamp, same htr_bofs Bayer phase from ABSOLUTE screen
 //coords ((pix_top+y)&3,(pix_left+x)&3), same htr_lut palette index. Writes
 //viewport-relative pixels at row stride ht_fb_stride; HtDrawIt copies them
 //to dc->body. Pure/reentrant: reads only its args + read-only LUTs, calls
 //ht_fp (reentrant contract), writes only its disjoint fb rows.
  I64 bx,by,i,j,r88,g88,b88,rr,gg,bb,o,r5,g5,b5,x0,y;
  I64 scale=d->scale,nbx=d->nbx,vh=d->vh,pl=d->pix_left,pt=d->pix_top;
  U8 *pix=ht_fb[d->fb_idx].pix,*p;
  CHtFragColor fc;
  for (by=d->y0_blk;by<d->y1_blk;by++) {
    for (bx=0;bx<nbx;bx++) {
      fc.r=0.0; fc.g=0.0; fc.b=0.0; fc.a=0.0;
      //At scale=1 this is the exact Shadertoy pixel center (Y-up).
      ht_fp(bx*scale+scale*0.5,vh-(by*scale+scale*0.5),&fc);
      r88=ToI64(fc.r*256.0);
      g88=ToI64(fc.g*256.0);
      b88=ToI64(fc.b*256.0);
      if (r88<0) r88=0; else if (r88>256) r88=256;
      if (g88<0) g88=0; else if (g88>256) g88=256;
      if (b88<0) b88=0; else if (b88>256) b88=256;
      rr=r88*31;
      gg=g88*31;
      bb=b88*31;
      x0=bx*scale;
      for (i=0;i<scale;i++) {
        y=by*scale+i;
        p=&pix[y*ht_fb_stride+x0];
        for (j=0;j<scale;j++) {
          o=htr_bofs[(((pt+y)&3)*4)+((pl+x0+j)&3)]*31;
          r5=(rr+o)>>8;
          g5=(gg+o)>>8;
          b5=(bb+o)>>8;
          if (r5<0) r5=0; else if (r5>31) r5=31;
          if (g5<0) g5=0; else if (g5>31) g5=31;
          if (b5<0) b5=0; else if (b5>31) b5=31;
          p[j]=htr_lut[(r5<<10)+(g5<<5)+b5];
        }
      }
    }
  }
}

I64 HtShadeBandJob(U8 *data)
{//Worker (Seth-task) entry for one band. Absorbs any HolyC throw so a
 //faulting shader keeps the last-good front buffer instead of aborting the
 //JobResGet barrier; JobRunOne additionally wraps the JOBT_CALL. Returns TRUE
 //when the band shaded cleanly; the render task ANDs these across bands.
  CHtBandDesc *d=data;
  Bool ok=TRUE;
  try {
    HtShadeBand(d);
  } catch {
    Fs->catch_except=TRUE;
    ok=FALSE;
  }
  return ok;
}

U0 HtScaleController(I64 ms)
{//plan 012: lifted verbatim out of HtDrawIt; consumes the render task's
 //measured frame time. KVM-era budget (docs/notes/perf-floor.md): coarsen
 //past two ~33 ms periods; refine only if the projected next-finer cost (4x
 //samples) stays interactive. TCG values were 250/150.
  if (ht_scale_lock)
    return;
  if (ms>70 && ht_scale<16) {
    ht_scale_slow++;
    ht_scale_fast=0;
    if (ht_scale_slow>=2) {
      ht_scale*=2;
      ht_scale_slow=ht_scale_fast=0;
    }
  } else if (ms*4<60 && ht_scale>1) {
    ht_scale_fast++;
    ht_scale_slow=0;
    if (ht_scale_fast>=4) {
      ht_scale/=2;
      ht_scale_slow=ht_scale_fast=0;
    }
  } else
    ht_scale_slow=ht_scale_fast=0;
}

U0 HtRenderTask(U8 *ignored)
{//plan 012 frame loop (spawned once on core 0): snapshot the uniforms, fan
 //contiguous band jobs across cores 1..nb, drain the JobResGet barrier, and
 //publish the completed buffer with one aligned-word store. Spends almost
 //the whole frame inside JobResGet (which Yields), so the winmgr and editor
 //keep core 0 while workers shade on cores 1..nb.
  I64 nb,k,cores,vw,vh,nbx,nby,scale,pl,pt,nbands,y0,y1,pace;
  Bool ok;
  CJob *jobs[MP_PROCESSORS_NUM];
  CHtFrameBuf *fb;
  F64 t0,bt,acc;
  while (TRUE) {
    if (ht_render_exit)
      goto rt_done;
    LBts(&ht_render_busy,0);	//claim busy BEFORE re-reading pause so a
				//pauser can never slip past a starting frame
    if (ht_render_pause || !ht_fp || !ht_win_task) {
      LBtr(&ht_render_busy,0);
      Sleep(2);
      goto rt_cont;
    }
    pl=ht_win_task->pix_left;
    pt=ht_win_task->pix_top;
    vw=ht_win_task->pix_width;
    vh=HT_VIEW_H;
    if (vh>ht_win_task->pix_height)
      vh=ht_win_task->pix_height;
    if (vw>ht_fb_stride)
      vw=ht_fb_stride;
    scale=ht_scale;
    if (vw<scale || vh<scale) {	//window not laid out yet: skip this frame
      LBtr(&ht_render_busy,0);
      Sleep(2);
      goto rt_cont;
    }
    nbx=vw/scale;
    nby=vh/scale;
    fb=&ht_fb[ht_back_idx];
    //Snapshot the raw uniforms ONCE, then derive ht_frame; every worker for
    //this frame reads the same read-only ht_frame (011 contract 1). HtDrawIt
    //may keep mutating ht_u for the NEXT snapshot; in-flight workers never
    //see it. HtDrawIt no longer calls HtFrameSetup (plan 012 reconciliation).
    MemCpy(&fb->snap,&ht_u,sizeof(CHtUniforms));
    HtFrameSetup(&fb->snap);
    cores=ht_render_cores;
    if (cores<1) cores=1;
    if (cores>mp_cnt) cores=mp_cnt;
    nb=cores-1;
    if (nb>nby) nb=nby;
    if (nb<0) nb=0;
    ok=TRUE;
    if (nb<1) {
      //Single-core fallback (pinned cores=1 or a uniprocessor guest): shade
      //every band on core 0, Yield between contiguous bands so the winmgr /
      //editor still run. Measure ONLY the shading time (exclude the Yields)
      //so the adaptive controller behaves exactly like the validated pre-012
      //inline path. Strictly better than the old monolithic draw_it.
      nbands=nby;
      if (nbands>8) nbands=8;
      if (nbands<1) nbands=1;
      for (k=0;k<nbands;k++) {
        y0=nby*k/nbands;
        y1=nby*(k+1)/nbands;
        ht_desc[k].band=k;
        ht_desc[k].y0_blk=y0;
        ht_desc[k].y1_blk=y1;
        ht_desc[k].nbx=nbx;
        ht_desc[k].vh=vh;
        ht_desc[k].fb_idx=ht_back_idx;
        ht_desc[k].scale=scale;
        ht_desc[k].pix_left=pl;
        ht_desc[k].pix_top=pt;
      }
      acc=0.0;
      for (k=0;k<nbands;k++) {
        bt=tS;
        HtShadeBand(&ht_desc[k]);
        acc+=tS-bt;
        Yield;
      }
      ht_shade_ms=ToI64(acc*1000.0);
    } else {
      //Static contiguous row-bands, one per worker core (cores 1..nb): band
      //boundaries are 64-aligned (fb_stride is), so writes never false-share.
      for (k=0;k<nb;k++) {
        y0=nby*k/nb;
        y1=nby*(k+1)/nb;
        ht_desc[k].band=k;
        ht_desc[k].y0_blk=y0;
        ht_desc[k].y1_blk=y1;
        ht_desc[k].nbx=nbx;
        ht_desc[k].vh=vh;
        ht_desc[k].fb_idx=ht_back_idx;
        ht_desc[k].scale=scale;
        ht_desc[k].pix_left=pl;
        ht_desc[k].pix_top=pt;
      }
      t0=tS;
      for (k=0;k<nb;k++)
        jobs[k]=JobQue(&HtShadeBandJob,&ht_desc[k],1+k,0);
      for (k=0;k<nb;k++)
        if (!JobResGet(jobs[k]))
          ok=FALSE;		//a band faulted: keep the last-good front buffer
      ht_shade_ms=ToI64((tS-t0)*1000.0);
    }
    LBtr(&ht_render_busy,0);
    if (ok) {
      ht_front_idx=ht_back_idx;	//PUBLISH: single aligned word store (atomic)
      ht_back_idx=ht_back_idx^1;
      ht_have_frame=TRUE;
    }
    HtScaleController(ht_shade_ms);
    pace=33-ht_shade_ms;	//pace to ~30 fps; also a guaranteed yield point
    if (pace<1)
      pace=1;
    Sleep(pace);
rt_cont:;
  }
rt_done:
  LBtr(&ht_render_busy,0);
}

U0 HtDrawIt(CTask *task,CDC *dc)
{//plan 012: NO shading here. Update ht_u for the NEXT snapshot (time, frame,
 //resolution, mouse, date), then blit the last COMPLETE frame the render
 //task published, plus the pane. A screendump can only ever see a whole
 //frame (double buffered) -> no tearing, and the editor never blocks on a
 //slow shade. Raw body pokes are ABSOLUTE screen coords.
  I64 y,sy,cw,stride=dc->width_internal,f;
  I64 vw=task->pix_width,vh=HT_VIEW_H;
  CDateStruct ds;
  if (vh>task->pix_height)
    vh=task->pix_height;
  Date2Struct(&ds,Now);
  ht_u.date_year=ds.year;
  ht_u.date_mon=ds.mon;
  ht_u.date_day=ds.day_of_mon;
  ht_u.date_secs=ds.hour*3600.0+ds.min*60.0+ds.sec;
  ht_u.i_time=tS;
  ht_u.i_frame++;
  ht_u.res_x=vw;
  ht_u.res_y=vh;
  ht_u.mouse_x=ms.pos.x-task->pix_left;
  ht_u.mouse_y=ms.pos.y-task->pix_top;
  ht_u.mouse_lb=ms.lb;
  if (ht_u.mouse_lb && !ht_mouse_lb_prev) {
    ht_u.click_x=ht_u.mouse_x;
    ht_u.click_y=ht_u.mouse_y;
  }
  ht_mouse_lb_prev=ht_u.mouse_lb;
  ht_win_task=task;		//keep the render task's geometry source current
  f=ht_front_idx;		//read the published index once (atomic word)
  if (ht_have_frame && ht_fb[f].pix) {
    cw=vw;
    if (cw>ht_fb_stride)
      cw=ht_fb_stride;
    if (task->pix_left+cw>dc->width)
      cw=dc->width-task->pix_left;
    for (y=0;y<vh;y++) {
      sy=task->pix_top+y;
      if (0<=sy<dc->height && cw>0)
        MemCpy(&dc->body[sy*stride+task->pix_left],
               &ht_fb[f].pix[y*ht_fb_stride],cw);
    }
  }
  HtDrawPane(task,dc);
}

I64 HtDump8(F64 v)
{//Clamp to [0,1] then round-half-up to a byte (ToI64 truncates); NaN
 //fails both comparisons and clamps to 0 like the renderer's clamp.
  if (!(v>0.0)) return 0;
  if (v>=1.0) return 255;
  return ToI64(v*255.0+0.5);
}

Bool HtVisualDump(U8 *path,F64 time,I64 frame)
{//Visual-oracle sample dump (plan 010): pre-quantization clamped RGB on
 //the fixed 80x36 block-center grid (fragCoord (bx*8+4, 288-(by*8+4)))
 //at a pinned uniform state. Independent of ht_scale by construction;
 //host side compares against committed GL reference DATs
 //(tools/visual_compare.py vs tests/corpus-visual/).
  CHtUniforms u;
  CHtFragColor fc;
  I64 bx,by,o=0;
  F64 px,py;
  U8 *buf=MAlloc(8640);
  Bool ok=TRUE;
  MemSet(&u,0,sizeof(CHtUniforms));
  u.i_time=time;
  u.res_x=640;
  u.res_y=288;
  u.click_x=-1;
  u.click_y=-1;
  u.date_year=2026;
  u.date_mon=1;
  u.date_day=1;
  u.date_secs=0.0;
  try {
    //plan 011: HtFrameSetup fills the shared read-only ht_frame once for
    //this pinned state; every sample then shades deterministically with no
    //stamp cache or sentinel to prime (the frame-rebind race is gone).
    u.i_frame=frame;
    HtFrameSetup(&u);
    for (by=0;by<36;by++)
      for (bx=0;bx<80;bx++) {
        px=bx*8+4;
        py=288-(by*8+4);
        fc.r=0.0; fc.g=0.0; fc.b=0.0; fc.a=0.0;
        ht_fp(px,py,&fc);
        buf[o++]=HtDump8(fc.r);
        buf[o++]=HtDump8(fc.g);
        buf[o++]=HtDump8(fc.b);
      }
  } catch {
    Fs->catch_except=TRUE;
    ok=FALSE;
  }
  if (ok)
    FileWrite(path,buf,8640);
  Free(buf);
  return ok;
}

Bool HtLoadGlsl()
{//Read GLSL and run the same in-guest compile path used by the editor.
 //Return TRUE when a source file was present, even if compilation failed:
 //a handled GLSL error must stay visible instead of starting the self-test.
  U8 *buf; I64 sz;
  Bool ok;
  if (!FileFind("E:/SHADER.GLS")) return FALSE;
  buf=FileRead("E:/SHADER.GLS",&sz);
  if (!buf) { "HT GUEST GLSL FAIL read\n"; return FALSE; }
  ok=HtCompileAndSwapGlsl(buf);
  if (ok)
    "HT GUEST GLSL OK\n";
  else
    "HT GUEST GLSL FAIL\n";
  if (ok && FileFind("E:/VISDUMP.TXT")) {
    //Single-shader oracle dump: must run single-core on core 0. plan 012:
    //pause the render task so no background frame calls ht_fp concurrently,
    //then dump deterministically. draw_it is also parked (it no longer
    //shades, but keep the historical park for a still screenshot).
    HtRenderPause;
    Fs->draw_it=NULL;
    Sleep(250);
    if (HtVisualDump("E:/V00A.DAT",0.5,15) &&
        HtVisualDump("E:/V00B.DAT",8.0,240))
      "HT VISUAL DUMP OK\n";
    else
      "HT VISUAL DUMP ERR\n";
    Fs->draw_it=&HtDrawIt;
    HtRenderResume;
  }
  Free(buf);
  return TRUE;
}

U0 HtSelfTest()
{//Headless proof driven by guest/RUN.HC; markers land in guest.log via
 //the task-doc dump.  Leaves the failed-compile state on screen at the
 //end so the final screenshot shows the error line over a live viewport.
  U0 (*before)(F64 frag_x,F64 frag_y,CHtFragColor *out_color);
  I64 f1,f2,dx,dy,n=0,first=-1,scale_lock_save,scale_up,scale_down,cores_save;
  Bool mono=TRUE,vary=FALSE,ctx_ok=FALSE;
  CHtFragColor c1,c2,c3;
  Sleep(2000);			//~2s of shader v1 for the rolling frame dump
  before=ht_fp;
  if (HtCompileAndSwapGlsl(ht_glsl2) && ht_fp!=before && ht_fp==ht_new_fp)
    "HT SWAP OK\n";
  else
    "HT SWAP FAIL\n";
  if (HtCompileAndSwapGlsl(ht_glsl2)) //identical GLSL is harmless
    "HT IDENT OK\n";
  else
    "HT IDENT FAIL\n";
  before=ht_fp;
  f1=ht_u.i_frame;
  if (!HtCompileAndSwapGlsl(ht_glsl_bad) && ht_fp==before) {
    Sleep(500);
    f2=ht_u.i_frame;
    if (f2>f1)
      "HT ERRSURVIVE OK\n";
    else
      "HT ERRSURVIVE FAIL frames frozen\n";
  } else
    "HT ERRSURVIVE FAIL bad source compiled\n";
  if (HtCompileAndSwapGlsl(ht_glsl2)) //compiler still usable after failure
    "HT RECOVER OK\n";
  else
    "HT RECOVER FAIL\n";
  if (HTMSin16(0x4000)==0x10000 && HTMCos16(0)==0x10000 &&
      HTMSin16(0x8000)==0)
    "HT MATH OK\n";
  else
    "HT MATH FAIL\n";
  HtLibSelfTest;		//prints HT LIB OK/FAIL (F64 LUT + bit ops)
  for (dy=0;dy<4;dy++)
    for (dx=0;dx<4;dx++) {
      if (HtQuantize(0,0,0,dx,dy)!=BLACK ||
          HtQuantize(256,256,256,dx,dy)!=WHITE)
        mono=FALSE;
      n=HtQuantize(128,128,128,dx,dy);
      if (first<0)
        first=n;
      else if (n!=first)
        vary=TRUE;
    }
  if (mono && vary)
    "HT DITHER OK\n";
  else
    "HT DITHER FAIL\n";
  //plan 011: per-invocation context. The ctx fixture bumps a mutable global
  //(g_acc, initialized to 2 per invocation) by +2 through a nested helper
  //chain, so it must read back as 4 (=>r=1.0) on EVERY call and never
  //accumulate. This guards the needs_ctx transitive analysis (g_acc is only
  //touched via addTwo->addOne) and the per-invocation ctx re-initialization.
  if (HtCompileAndSwapGlsl(ht_glsl_ctx)) {
    HtFrameSetup(&ht_u);
    c1.r=0.0; c1.g=0.0; c1.b=0.0; c1.a=0.0;
    ht_fp(40.5,40.5,&c1);
    c2.r=0.0; c2.g=0.0; c2.b=0.0; c2.a=0.0;
    ht_fp(40.5,40.5,&c2);
    c3.r=0.0; c3.g=0.0; c3.b=0.0; c3.a=0.0;
    ht_fp(40.5,40.5,&c3);
    if (Abs(c1.r-1.0)<0.01 && Abs(c2.r-1.0)<0.01 && Abs(c3.r-1.0)<0.01)
      ctx_ok=TRUE;
  }
  if (ctx_ok)
    "HT CTX OK\n";
  else
    "HT CTX FAIL r=%d,%d,%d\n",
      ToI64(c1.r*1000.0),ToI64(c2.r*1000.0),ToI64(c3.r*1000.0);
  scale_lock_save=ht_scale_lock;
  ht_scale_lock=0;
  //plan 012: pin the render task to single-core for the SCALE sub-test. The
  //KVM controller thresholds were validated against single-core frame time,
  //and single-core fallback measures pure shading ms (Yields excluded), so
  //the slow fixture still coarsens to 1:16 and the fast one refines to <=1:4
  //independently of mp_cnt. (An aligned-word write; the render task re-reads
  //ht_render_cores each frame, no handshake needed.)
  cores_save=ht_render_cores;
  ht_render_cores=1;
  if (HtCompileAndSwapGlsl(ht_glsl_slow)) {
    Sleep(8000);
    scale_up=ht_scale;
  } else
    scale_up=-1;
  if (HtCompileAndSwapGlsl(ht_glsl1)) {
    Sleep(8000);
    scale_down=ht_scale;
  } else
    scale_down=-1;
  ht_render_cores=cores_save;
  if (scale_up==16 && 0<scale_down<=4)
    "HT SCALE OK\n";
  else
    "HT SCALE FAIL up=%d down=%d\n",scale_up,scale_down;
  ht_scale_lock=scale_lock_save;
  if (ht_scale_lock)
    ht_scale=ht_scale_lock;
  else
    ht_scale=16;
  ht_scale_slow=ht_scale_fast=0;
  ht_fp=ht_default_fp;		//park on the animated default shader
  HtCompileAndSwapGlsl(ht_glsl_bad); //show GLSL error over live viewport
}

Bool HtFinite(F64 x)
{//NaN fails x==x; huge magnitudes are treated as runaway shader output.
  if (!(x==x)) return FALSE;
  if (x>1e30 || x<-1e30) return FALSE;
  return TRUE;
}

U0 HtCorpusRun()
{//Batch mode (E:/CORPUS.TXT present): compile every shipped corpus shader
 //in one boot and print one marker line per stage; tools/corpus_report.py
 //turns guest.log into the staged compatibility table. No rendering here:
 //visual checks are separate single-shader runs.
  U8 *man,*p,*src,name[16],id[16],path[24],vpath[24];
  I64 sz,i,k,n=0,pass=0;
  F64 t0,px,py;
  CHtCompileResult r;
  CHtUniforms eu;
  CHtFragColor fc;
  Bool ok,vok;
  man=FileRead("E:/CORPUS.TXT",&sz);
  if (!man) {
    "HT CORPUS FAIL manifest\n";
    return;
  }
  //plan 012: keep the whole corpus batch single-core on core 0 (ht_fp called
  //in a synchronous loop, not via the render task). Pause once for the whole
  //batch; the nested HtInstallHoly/HtVisualDump pauses just bump the count.
  HtRenderPause;
  ht_u.i_time=0.5;
  ht_u.res_x=640;
  ht_u.res_y=288;
  p=man;
  while (*p) {
    i=0;
    while (*p && *p!=' ' && *p!='\n' && i<15) name[i++]=*p++;
    name[i]=0;
    while (*p==' ') p++;
    i=0;
    while (*p && *p!=' ' && *p!='\n' && *p!='\r' && i<15) id[i++]=*p++;
    id[i]=0;
    //Optional third CORPUS.TXT field (stratum) is host-side metadata only.
    while (*p && *p!='\n' && *p!='\r') p++;
    while (*p=='\n' || *p=='\r') p++;
    if (!*name || !*id) break;
    n++;
    StrPrint(path,"E:/%s.GLS",name);
    src=FileRead(path,&sz);
    if (!src) {
      "HT CORPUS %s read ERR missing\n",id;
      goto corpus_next;
    }
    "HT CORPUS %s read OK %d\n",id,sz;
    if (!HtCompileGlsl(src,&r)) {
      "HT CORPUS %s compile ERR %s\n",id,r.error;
      Free(src);
      goto corpus_next;
    }
    "HT CORPUS %s compile OK %d\n",id,StrLen(r.holy);
    if (!HtInstallHoly(r.holy)) {
      "HT CORPUS %s install ERR %s\n",id,ht_status;
      HtCompileResultDel(&r);
      Free(src);
      goto corpus_next;
    }
    "HT CORPUS %s install OK\n",id;
    ok=TRUE;
    //Pin the exec-sample uniforms to the oracle's state A (HtDrawIt keeps
    //rewriting ht_u with live wall-clock time, and under F32 semantics a
    //shader can legitimately overflow to inf at large iTime - plan 013's
    //XdsGWH did). A MemSet'd local mirrors HtVisualDump's uniform state.
    MemSet(&eu,0,sizeof(CHtUniforms));
    eu.i_time=0.5;
    eu.i_frame=15;
    eu.res_x=640;
    eu.res_y=288;
    HtFrameSetup(&eu);
    t0=tS;
    try {
      for (k=0;k<4;k++) {
        //Interior, edge and corner sample points at viewport 640x288.
        if (k==0) { px=320.5; py=144.5; }
        else if (k==1) { px=2.5; py=285.5; }
        else if (k==2) { px=600.5; py=20.5; }
        else { px=16.5; py=16.5; }
        fc.r=0.0; fc.g=0.0; fc.b=0.0; fc.a=0.0;
        ht_fp(px,py,&fc);
        if (!HtFinite(fc.r) || !HtFinite(fc.g) ||
            !HtFinite(fc.b) || !HtFinite(fc.a))
          ok=FALSE;
      }
    } catch {
      Fs->catch_except=TRUE;
      ok=FALSE;
    }
    if (ok) {
      pass++;
      "HT CORPUS %s exec OK %dms\n",id,ToI64((tS-t0)*1000.0);
      t0=tS;
      StrPrint(vpath,"E:/V%02dA.DAT",n);
      vok=HtVisualDump(vpath,0.5,15);
      StrPrint(vpath,"E:/V%02dB.DAT",n);
      vok=HtVisualDump(vpath,8.0,240) && vok;
      if (vok)
        "HT CORPUS %s visual OK %dms\n",id,ToI64((tS-t0)*1000.0);
      else
        "HT CORPUS %s visual ERR dump\n",id;
    } else
      "HT CORPUS %s exec ERR nonfinite\n",id;
    HtCompileResultDel(&r);
    Free(src);
corpus_next:;
  }
  Free(man);
  "HT CORPUS DONE %d/%d\n",pass,n;
  ht_fp=ht_default_fp;		//park on the built-in shader for the screenshot
  HtRenderResume;		//resume background render for the final frame
}

U8 *HtEditorSave(CDoc *doc)
{//DocSave otherwise serializes its temporary cursor marker. Hide it only
 //for the snapshot; the native editor cursor remains enabled for display.
  I64 flags=doc->flags;
  Bool unlock=DocLock(doc);
  U8 *res;
  doc->flags|=DOCF_NO_CURSOR;
  res=DocSave(doc);
  doc->flags=flags;
  if (unlock)
    DocUnlock(doc);
  return res;
}

Bool HtEditorSync(CDoc *doc,Bool changed_by_user)
{//Mirror plain GLSL out of CDoc. Comparing serialized text makes cursor,
 //selection and scrolling keys compile-neutral.
  Bool changed=FALSE;
  I64 n;
  U8 *src=HtEditorSave(doc);
  n=StrLen(src);
  if (n>=HT_GLSL_MAX) {
    HtStatus(TRUE,"GLSL ERR source too long (%d>%d)",n,HT_GLSL_MAX-1);
  } else if (StrCmp(src,ht_glsl_src)) {
    StrCpy(ht_glsl_src,src);
    changed=TRUE;
    if (changed_by_user)
      HtStatus(FALSE,"EDIT  compiling after pause...");
  }
  ht_edit_line=doc->line-1;
  ht_edit_col=doc->col-1;
  if (ht_edit_line<0) ht_edit_line=0;
  if (ht_edit_col<0) ht_edit_col=0;
  if (ht_edit_line<ht_edit_top)
    ht_edit_top=ht_edit_line;
  else if (ht_edit_line>=ht_edit_top+HT_SRC_ROWS)
    ht_edit_top=ht_edit_line-HT_SRC_ROWS+1;
  if (ht_edit_col<ht_edit_left)
    ht_edit_left=ht_edit_col;
  else if (ht_edit_col>=ht_edit_left+78)
    ht_edit_left=ht_edit_col-77;
  Free(src);
  return changed;
}

U0 HtEditorLoad(CDoc *doc,U8 *src)
{//Replace the native editor text and reset its undo history.
  DocRst(doc,TRUE);
  doc->flags|=DOCF_PLAIN_TEXT|DOCF_ALLOW_UNDO;
  DocLoad(doc,src,StrLen(src));
  HtEditorSync(doc,FALSE);
}

U0 HtInteract()
{//GUI sessions only (E:/GUI.TXT present): own the keyboard until ESC.
 //CDoc provides the native insertion, deletion, navigation, selection,
 //clipboard and undo behavior. ScanKey keeps this task responsive enough
 //to debounce recompiles while WinMgr continues animating the viewport.
  CDoc *doc=DocNew("SHADER.GLS");
  I64 ch,sc;
  Bool done=FALSE,dirty=FALSE;
  F64 changed_at=0.0;
  doc->flags|=DOCF_PLAIN_TEXT|DOCF_ALLOW_UNDO;
  DocLoad(doc,ht_glsl_src,StrLen(ht_glsl_src));
  doc->win_task=Fs;
  ht_edit_top=ht_edit_left=0;
  HtEditorSync(doc,FALSE);
  ht_native_editor=TRUE;
  HtStatus(FALSE,"EDIT  native GLSL; changes compile after 200ms");
  Refresh(2,TRUE);
  try {
    while (!done) {
      if (ScanKey(&ch,&sc,FALSE)) {
        switch (ch) {
          case 0:
            switch (sc.u8[0]) {
              case SC_F1:
                HtEditorLoad(doc,ht_glsl1);
                dirty=FALSE;
                HtCompileAndSwapGlsl(ht_glsl_src);
                break;
              case SC_F2:
                HtEditorLoad(doc,ht_glsl2);
                dirty=FALSE;
                HtCompileAndSwapGlsl(ht_glsl_src);
                break;
              case SC_F5:
                HtEditorSync(doc,FALSE);
                dirty=FALSE;
                HtCompileAndSwapGlsl(ht_glsl_src);
                break;
              default:
                DocPutKey(doc,ch,sc);
                if (HtEditorSync(doc,TRUE)) {
                  dirty=TRUE;
                  changed_at=tS;
                }
            }
            break;
          case CH_ESC:
          case CH_SHIFT_ESC:
            done=TRUE;
            break;
          case CH_CTRLA:
            //TempleOS normally maps Ctrl-A to Save As. HolyToy follows the
            //common editor binding and leaves deletion/copy to DocPutKey.
            EdSelAll(doc,TRUE);
            break;
          default:
            DocPutKey(doc,ch,sc);
            if (HtEditorSync(doc,TRUE)) {
              dirty=TRUE;
              changed_at=tS;
            }
        }
      } else {
        if (dirty && tS-changed_at>=0.2) {
          dirty=FALSE;
          HtCompileAndSwapGlsl(ht_glsl_src);
        }
        Sleep(10);
      }
    }
  } catch
    PutExcept;
  ht_native_editor=FALSE;
  DocDel(doc);
  SettingsPop;			//also restores the pre-HolyToy draw_it
}

Bool ht_gui=FileFind("E:/GUI.TXT") || FileFind("E:/EDIT.TXT");
Bool ht_ac_was_on=FALSE;
U8 *ht_scale_buf,*ht_scale_p,ht_scale_tok[8];
I64 ht_scale_sz,ht_scale_i=0;
if (FileFind("E:/SCALE.TXT")) {
  ht_scale_buf=FileRead("E:/SCALE.TXT",&ht_scale_sz);
  if (ht_scale_buf) {
    ht_scale_p=ht_scale_buf;
    while (*ht_scale_p==' ' || *ht_scale_p=='\t' ||
           *ht_scale_p=='\n' || *ht_scale_p=='\r') ht_scale_p++;
    while (*ht_scale_p && *ht_scale_p!=' ' && *ht_scale_p!='\t' &&
           *ht_scale_p!='\n' && *ht_scale_p!='\r' && ht_scale_i<7)
      ht_scale_tok[ht_scale_i++]=*ht_scale_p++;
    ht_scale_tok[ht_scale_i]=0;
    if (!StrCmp(ht_scale_tok,"auto")) {
      ht_scale_lock=0;
      ht_scale=16;
    } else if (!StrCmp(ht_scale_tok,"1"))
      ht_scale_lock=ht_scale=1;
    else if (!StrCmp(ht_scale_tok,"2"))
      ht_scale_lock=ht_scale=2;
    else if (!StrCmp(ht_scale_tok,"4"))
      ht_scale_lock=ht_scale=4;
    else if (!StrCmp(ht_scale_tok,"8"))
      ht_scale_lock=ht_scale=8;
    else if (!StrCmp(ht_scale_tok,"16"))
      ht_scale_lock=ht_scale=16;
    else {
      ht_scale_lock=0;
      ht_scale=16;
      "HT SCALE BADPIN\n";
    }
    Free(ht_scale_buf);
  }
}
//plan 012: shading-core count. Auto = mp_cnt; pin 1..mp_cnt via E:/CORES.TXT
//(mirrors the SCALE.TXT block; host plumbing is HOLYTOY_CORES -> mkxfer.sh).
//Values >mp_cnt clamp to mp_cnt with an HT CORES BADPIN line; junk => auto.
U8 *ht_cores_buf,*ht_cores_p,ht_cores_tok[8];
I64 ht_cores_sz,ht_cores_i=0,ht_cores_n;
ht_render_cores=mp_cnt;
if (FileFind("E:/CORES.TXT")) {
  ht_cores_buf=FileRead("E:/CORES.TXT",&ht_cores_sz);
  if (ht_cores_buf) {
    ht_cores_p=ht_cores_buf;
    while (*ht_cores_p==' ' || *ht_cores_p=='\t' ||
           *ht_cores_p=='\n' || *ht_cores_p=='\r') ht_cores_p++;
    while (*ht_cores_p && *ht_cores_p!=' ' && *ht_cores_p!='\t' &&
           *ht_cores_p!='\n' && *ht_cores_p!='\r' && ht_cores_i<7)
      ht_cores_tok[ht_cores_i++]=*ht_cores_p++;
    ht_cores_tok[ht_cores_i]=0;
    if (!StrCmp(ht_cores_tok,"auto"))
      ht_render_cores=mp_cnt;
    else {
      ht_cores_n=Str2I64(ht_cores_tok);
      if (ht_cores_n<1) {
        ht_render_cores=mp_cnt;
        "HT CORES BADPIN\n";
      } else if (ht_cores_n>mp_cnt) {
        ht_render_cores=mp_cnt;
        "HT CORES BADPIN\n";
      } else
        ht_render_cores=ht_cores_n;
    }
    Free(ht_cores_buf);
  }
}
//plan 013: HOLYTOY_F32=0 escape hatch (E:/F32.TXT holding "0") turns the
//emitter's F32-semantics mode off so the F64 path can be A/B-checked.
if (FileFind("E:/F32.TXT")) {
  U8 *f32b;
  I64 f32sz;
  f32b=FileRead("E:/F32.TXT",&f32sz);
  if (f32b) {
    if (f32sz>0 && f32b[0]=='0') {
      ht_f32_mode=FALSE;
      "HT F32 MODE OFF\n";
    }
    Free(f32b);
  }
}
StrCpy(ht_glsl_src,ht_glsl1);
HtStatus(FALSE,"READY  sample 1 (built-in)");
ht_fp=&MainImage;
ht_default_fp=ht_fp;
HTMInit;			//build the LUT once, before any F3/GLSL shading
HTRInit;			//build the palette LUT and Bayer offsets once
HtLibInit;			//F64 sine table for generated shader code
HtF32Init;			//plan 013: fold Cephes-F32 sin/cos constants
ht_u.click_x=-1;
ht_u.click_y=-1;
ht_native_editor=FALSE;
ht_edit_line=ht_edit_col=ht_edit_top=ht_edit_left=0;
if (ht_gui) {
  SettingsPush;			//HtInteract restores all task settings on exit
  ht_ac_was_on=AutoComplete(OFF);
  WinFocus(Fs);
}
//plan 012: allocate the offscreen double buffer (64-aligned base, 64-aligned
//stride => band boundaries never share a cache line), capture the window
//task for viewport geometry, then Spawn the render task on core 0 (-1). All
//shared state it reads (LUTs, ht_fp, ht_render_cores, ht_u) is set above.
I64 ht_fb_need=ht_fb_stride*HT_VIEW_H,ht_fb_base;
ht_win_task=Fs;
ht_fb[0].pix_raw=MAlloc(ht_fb_need+64);
ht_fb_base=(ht_fb[0].pix_raw(I64)+63)&(~63);
ht_fb[0].pix=ht_fb_base(U8 *);
MemSet(ht_fb[0].pix,0,ht_fb_need);
ht_fb[1].pix_raw=MAlloc(ht_fb_need+64);
ht_fb_base=(ht_fb[1].pix_raw(I64)+63)&(~63);
ht_fb[1].pix=ht_fb_base(U8 *);
MemSet(ht_fb[1].pix,0,ht_fb_need);
ht_render_task=Spawn(&HtRenderTask,NULL,"HT Render",-1,NULL,0x40000);
Bool ht_had_shader=FALSE;
if (FileFind("E:/CORPUS.TXT")) {
  //Batch measurement first, with no draw_it installed: rendering the
  //previous shader at full viewport would starve every later compile.
  HtCorpusRun;
  Fs->draw_it=&HtDrawIt;
} else {
  Fs->draw_it=&HtDrawIt;
  ht_had_shader=HtLoadGlsl();
  if (ht_gui)
    HtInteract;			//shader (if any) already live in the viewport
  else if (ht_had_shader)
    Sleep(3000);		//headless GLSL mode: just let the rolling
				//screendumps capture the animating shader;
				//the recompile markers are the no-shader
				//run's job (keep the two modes separate)
  else
    HtSelfTest;
}
//plan 012 teardown. Only on GUI exit (ESC): HtInteract already popped our
//draw_it via SettingsPop, so nothing blits ht_fb anymore -> drain any
//in-flight frame, reap the render task, and free the buffers with no
//use-after-free. In the HEADLESS paths (self-test / GLSL / corpus) we
//deliberately leave the render task running and draw_it installed: the
//winmgr keeps blitting the live, animating frame through guest/RUN.HC's
//4 s picture hold (matching the pre-012 behavior the screenshot proofs rely
//on), and the imminent Reboot reclaims everything.
if (ht_gui) {
  HtRenderPause;
  ht_render_exit=TRUE;
  HtRenderResume;
  if (ht_render_task)
    DeathWait(&ht_render_task);
  Fs->draw_it=NULL;
  ht_have_frame=FALSE;
  if (ht_fb[0].pix_raw) Free(ht_fb[0].pix_raw);
  if (ht_fb[1].pix_raw) Free(ht_fb[1].pix_raw);
}
if (ht_ac_was_on)
  AutoComplete(ON);
