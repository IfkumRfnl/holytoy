//HolyToy skeleton (plan 002): editable code pane + live animating viewport.
//The runner owns the pixels: draw_it iterates the viewport at HT_SCALE
//block granularity, calls MainImage through ht_fp for one sample per
//block, and pokes dc->body directly (src/plasma.HC idiom - absolute
//screen coords, stride=width_internal, no clipping).  The code pane is
//GrPrint'd from the same draw_it on the 8x8 font grid so the harness OCR
//(tools/scrtext.py) reads it exactly.
//Harness-mode: install draw_it and return; guest/RUN.HC brackets us.

#include "E:/HTMATH.HC"	//LUT sin/cos (16.16 turns); mkxfer.sh ships it always
#include "E:/HTRENDER.HC"	//RGBA palette quantizer; mkxfer.sh ships it always
#include "E:/HTLEX.HC"	//in-guest GLSL compiler modules (plan 008)
#include "E:/HTPARSE.HC"
#include "E:/HTLOWER.HC"
#include "E:/HTEMIT.HC"
#include "E:/HTCOMP.HC"

#define HT_VIEW_H	288	//viewport: full width x 288 window pixels (~60%)
#define HT_SCALE	4	//shade once per 4x4 block (VISION.md render scale)
#define HT_PANE_ROW	36	//first code-pane text row (window row, 8px cells)
#define HT_SRC_ROWS	20	//source lines shown in the pane
#define HT_STATUS_ROW	58	//status/error line (last window row)
#define HT_SRC_MAX	8192	//transpiled GLSL starts ~2 KB; static global, cheap

class CHtFragColor { F64 r,g,b,a; };
class CHtUniforms
{
  F64 i_time;
  I64 i_frame;
  I64 res_x,res_y;
  I64 mouse_x,mouse_y;	//current viewport px, Y-down (raw)
  I64 mouse_lb;		//1 while left button is held
  I64 click_x,click_y;	//last press, viewport px, Y-down; -1 = never
};

CHtUniforms ht_u;
U0 (*ht_fp)(CHtUniforms *u,F64 frag_x,F64 frag_y,CHtFragColor *out_color);
U8 ht_src[HT_SRC_MAX];		//current shader source (the code pane content)
U8 ht_status[96];		//status/error line text
Bool ht_status_err;		//status line draws LTRED when TRUE
Bool ht_cursor;			//GUI edit mode: draw an end-of-buffer cursor
F64 ht_t0;			//shading-loop timing start (per frame)
I64 ht_shade_ms;		//last frame's shading time, whole ms
Bool ht_mouse_lb_prev;		//rising-edge state for iMouse click position

U8 *ht_src1=
"U0 MainImage(CHtUniforms *u,F64 frag_x,F64 frag_y,CHtFragColor *out_color)\n"
"{//sample 1: plasma bands\n"
"  F64 t=u->i_time,v;\n"
"  v=Sin(frag_x*0.021+t)+\n"
"    Sin(frag_y*0.032-t*0.7)+\n"
"    Sin((frag_x+frag_y)*0.014+t*0.5)+\n"
"    Sin(Sqrt(frag_x*frag_x+frag_y*frag_y)*0.019-t*1.3);\n"
"  out_color->r=0.5+v*0.125;\n"
"  out_color->g=0.5-v*0.125;\n"
"  out_color->b=0.75+v*0.0625;\n"
"  out_color->a=1.0;\n"
"}\n";

U8 *ht_src2=
"U0 MainImage(CHtUniforms *u,F64 frag_x,F64 frag_y,CHtFragColor *out_color)\n"
"{//sample 2: expanding bright rings\n"
"  F64 dx=frag_x-u->res_x/2.0,dy=frag_y-u->res_y/2.0,t=u->i_time,v;\n"
"  v=0.5+0.5*Sin(Sqrt(dx*dx+dy*dy)*0.11-t*9.0);\n"
"  out_color->r=v; out_color->g=v*0.65; out_color->b=1.0-v*0.5;\n"
"  out_color->a=1.0;\n"
"}\n";

U8 *ht_src3=
"U0 MainImage(CHtUniforms *u,F64 frag_x,F64 frag_y,CHtFragColor *out_color)\n"
"{//sample 3: fixed-point plasma (HTMATH 16.16-turn LUT sines)\n"
"  I64 t16=ToI64(u->i_time*0x3000),v;\n"
"  F64 fx=frag_x,fy=frag_y;\n"
"  v=HTMSin16(ToI64(frag_x*449.0)+t16)+\n"
"    HTMSin16(ToI64(frag_y*323.0)-t16*7/10)+\n"
"    HTMSin16(ToI64((frag_x+frag_y)*219.0)+t16/2)+\n"
"    HTMSin16(ToI64(Sqrt(fx*fx+fy*fy)*250.0)-t16*13/10);\n"
"  out_color->r=(v+0x40000)/524288.0;\n"
"  out_color->g=1.0-out_color->r;\n"
"  out_color->b=0.5+v/1048576.0;\n"
"  out_color->a=1.0;\n"
"}\n";

U8 *ht_bad=
"U0 MainImage(CHtUniforms *u,F64 frag_x,F64 frag_y,CHtFragColor *out_color)\n"
"{//deliberately broken: missing expression\n"
"  out_color->r=;\n"
"}\n";

U0 MainImage(CHtUniforms *u,F64 frag_x,F64 frag_y,CHtFragColor *out_color)
{//Built-in sample shader v1: plasma bands (same text as ht_src1).
  F64 t=u->i_time,v;
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
{//Code pane: black band under the viewport, source text + status line.
  I64 sy,row,n,stride=dc->width_internal,
      y0=task->pix_top+HT_VIEW_H,y1=task->pix_top+task->pix_height;
  U8 *p=ht_src,line[81];
  if (y1>dc->height) y1=dc->height;
  for (sy=y0;sy<y1;sy++)
    MemSet(&dc->body[sy*stride+task->pix_left],BLACK,task->pix_width);
  dc->color=LTGRAY;
  GrPrint(dc,0,HT_PANE_ROW*8," HolyToy %3dms  F5 recompile  F1-F3 samples  ESC exit",ht_shade_ms);
  dc->color=WHITE;
  row=HT_PANE_ROW+1;
  n=0;
  while (*p && row<HT_PANE_ROW+1+HT_SRC_ROWS) {
    n=0;
    while (*p && *p!='\n' && n<78)
      line[n++]=*p++;
    line[n]=0;
    while (*p && *p!='\n')
      p++;
    if (*p=='\n') p++;
    GrPrint(dc,8,row*8,"%s",line);
    row++;
  }
  if (ht_cursor && !*p && row<=HT_PANE_ROW+HT_SRC_ROWS) {
    sy=StrLen(ht_src);		//cursor cell: end of buffer
    dc->color=YELLOW;
    if (!sy || ht_src[sy-1]=='\n')
      GrPrint(dc,8,row*8,"_");
    else
      GrPrint(dc,8+n*8,(row-1)*8,"_");
  }
  if (ht_status_err)
    dc->color=LTRED;
  else
    dc->color=LTGREEN;
  GrPrint(dc,0,HT_STATUS_ROW*8," %s",ht_status);
}

U0 (*ht_new_fp)(CHtUniforms *u,F64 frag_x,F64 frag_y,CHtFragColor *out_color);

Bool HtRecompile(U8 *src)
{//Compile shader source in-task (ExePutS2, Compiler/CMain.HC:631 throws
 //catchable exceptions); rebind ht_fp only on success.  The fresh
 //&MainImage is taken INSIDE the compiled unit (src/reload.HC pattern) so
 //it binds the newly JITed code, not the code current when this function
 //was compiled.  On failure the old shader keeps rendering.
  Bool ok=FALSE;
  I64 n=StrLen(src),ec;
  U8 *buf,ecs[9];
  if (n>HT_SRC_MAX-1) {
    HtStatus(TRUE,"COMPILE ERR source too long (%d>%d)",n,HT_SRC_MAX-1);
    return FALSE;
  }
  if (src!=ht_src)
    StrCpy(ht_src,src);		//pane always shows what was attempted
  buf=MStrPrint("%s\nht_new_fp=&MainImage;\n",ht_src);
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
      ht_fp=ht_new_fp;
      HtStatus(FALSE,"OK  compiled %d bytes",n);
    } else {
      ok=FALSE;
      HtStatus(TRUE,"COMPILE ERR no MainImage bound");
    }
  }
  return ok;
}

U0 HtDrawIt(CTask *task,CDC *dc)
{//dc aliases gr.dc2; raw body pokes are ABSOLUTE screen coords.
  I64 bx,by,i,j,sx0,sy,stride=dc->width_internal,r88,g88,b88;
  I64 rr,gg,bb,o,r5,g5,b5;
  I64 vw=task->pix_width,vh=HT_VIEW_H;
  I64 nbx=vw/HT_SCALE,nby=vh/HT_SCALE;
  U8 *p,q[16];
  CHtFragColor fc;
  if (vh>task->pix_height)
    vh=task->pix_height;
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
  ht_t0=tS;			//time the shading work only, not the winmgr
				//frame cadence (docs/notes/perf-floor.md)
  if (ht_fp) {
    for (by=0;by<nby;by++) {
      for (bx=0;bx<nbx;bx++) {
        fc.r=0.0; fc.g=0.0; fc.b=0.0; fc.a=0.0;
        //At HT_SCALE=1 this is the exact Shadertoy pixel center (Y-up).
        ht_fp(&ht_u,bx*HT_SCALE+HT_SCALE*0.5,
              vh-(by*HT_SCALE+HT_SCALE*0.5),&fc);
        r88=ToI64(fc.r*256.0);
        g88=ToI64(fc.g*256.0);
        b88=ToI64(fc.b*256.0);
        if (r88<0) r88=0; else if (r88>256) r88=256;
        if (g88<0) g88=0; else if (g88>256) g88=256;
        if (b88<0) b88=0; else if (b88>256) b88=256;
        rr=r88*31;
        gg=g88*31;
        bb=b88*31;
        sx0=task->pix_left+bx*HT_SCALE;
        if (0<=sx0<=dc->width-HT_SCALE) {
          //Inline path must match HtQuantize semantics exactly. HT_SCALE=4
          //aligns with the Bayer tile, so compute its 16 indices once/block.
          for (i=0;i<HT_SCALE;i++) {
            sy=task->pix_top+by*HT_SCALE+i;
            for (j=0;j<HT_SCALE;j++) {
              o=htr_bofs[((sy&3)*4)+((sx0+j)&3)]*31;
              r5=(rr+o)>>8;
              g5=(gg+o)>>8;
              b5=(bb+o)>>8;
              if (r5<0) r5=0; else if (r5>31) r5=31;
              if (g5<0) g5=0; else if (g5>31) g5=31;
              if (b5<0) b5=0; else if (b5>31) b5=31;
              q[i*HT_SCALE+j]=htr_lut[(r5<<10)+(g5<<5)+b5];
            }
          }
          for (i=0;i<HT_SCALE;i++) {
            sy=task->pix_top+by*HT_SCALE+i;
            if (0<=sy<dc->height) {
              p=&dc->body[sy*stride+sx0];
              for (j=0;j<HT_SCALE;j++)
                p[j]=q[i*HT_SCALE+j];
            }
          }
        }
      }
    }
  }
  ht_shade_ms=ToI64((tS-ht_t0)*1000.0);
  HtDrawPane(task,dc);
}

Bool HtLoadShader()
{//Compile a host-transpiled shader off the transfer disk, if present.
 //FileRead NUL-terminates (Kernel/BlkDev/FileSysFAT.HC FAT32FileRead).
  U8 *buf;
  I64 sz;
  Bool ok=FALSE;
  if (!FileFind("E:/SHADER.HC"))
    return FALSE;
  buf=FileRead("E:/SHADER.HC",&sz);
  if (buf) {
    ok=HtRecompile(buf);
    Free(buf);
  }
  if (ok)
    "HT GLSL OK\n";
  else
    "HT GLSL FAIL\n";
  return TRUE;
}

Bool HtLoadGlsl()
{//Product path: read GLSL, compile to internal HolyC in this guest task,
 //then use the existing failure-safe JIT swap and RGBA renderer pipeline.
  U8 *buf; I64 sz; CHtCompileResult result;
  if (!FileFind("E:/SHADER.GLS")) return FALSE;
  buf=FileRead("E:/SHADER.GLS",&sz);
  if (!buf) { "HT GUEST GLSL FAIL read\n"; return FALSE; }
  if (HtCompileGlsl(buf,&result) && HtRecompile(result.holy))
    "HT GUEST GLSL OK\n";
  else {
    HtStatus(TRUE,"GLSL ERR %s",result.error);
    "HT GUEST GLSL FAIL %s\n",result.error;
    Free(buf);
    return FALSE;
  }
  Free(buf);
  return TRUE;
}

U0 HtSelfTest()
{//Headless proof driven by guest/RUN.HC; markers land in guest.log via
 //the task-doc dump.  Leaves the failed-compile state on screen at the
 //end so the final screenshot shows the error line over a live viewport.
  U0 (*before)(CHtUniforms *u,F64 frag_x,F64 frag_y,CHtFragColor *out_color);
  I64 f1,f2,dx,dy,n=0,first=-1;
  Bool mono=TRUE,vary=FALSE;
  Sleep(2000);			//~2s of shader v1 for the rolling frame dump
  before=ht_fp;
  if (HtRecompile(ht_src2) && ht_fp!=before && ht_fp==ht_new_fp)
    "HT SWAP OK\n";
  else
    "HT SWAP FAIL\n";
  if (HtRecompile(ht_src2))	//recompile of identical source is harmless
    "HT IDENT OK\n";
  else
    "HT IDENT FAIL\n";
  before=ht_fp;
  f1=ht_u.i_frame;
  if (!HtRecompile(ht_bad) && ht_fp==before) {
    Sleep(500);
    f2=ht_u.i_frame;
    if (f2>f1)
      "HT ERRSURVIVE OK\n";
    else
      "HT ERRSURVIVE FAIL frames frozen\n";
  } else
    "HT ERRSURVIVE FAIL bad source compiled\n";
  if (HtRecompile(ht_src2))	//compiler still usable after a failure
    "HT RECOVER OK\n";
  else
    "HT RECOVER FAIL\n";
  if (HTMSin16(0x4000)==0x10000 && HTMCos16(0)==0x10000 &&
      HTMSin16(0x8000)==0 && HtRecompile(ht_src3))
    "HT MATH OK\n";		//exact LUT entries + F3 sample compiles
  else
    "HT MATH FAIL\n";
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
  HtRecompile(ht_bad);		//park in the survived-error demo state
}

U0 HtInteract()
{//GUI sessions only (E:/GUI.TXT present): own the keyboard until ESC.
 //Minimal live loop: printable keys append at the end of the buffer,
 //BACKSPACE deletes, ENTER inserts a newline, F5 recompiles the buffer,
 //F1/F2 load the samples.  Blocking GetKey is fine here - the winmgr
 //task keeps animating the viewport; headless runs never enter this.
  I64 ch,sc,n;
  Bool done=FALSE;
  ht_cursor=TRUE;
  HtStatus(FALSE,"EDIT  keys append at end of buffer; F5 recompiles");
  try {
    while (!done) {
      ch=GetKey(&sc,FALSE);
      n=StrLen(ht_src);
      switch (ch) {
        case 0:
          switch (sc.u8[0]) {
            case SC_F1: HtRecompile(ht_src1); break;
            case SC_F2: HtRecompile(ht_src2); break;
            case SC_F3: HtRecompile(ht_src3); break;
            case SC_F5: HtRecompile(ht_src);  break;
          }
          break;
        case CH_ESC:
        case CH_SHIFT_ESC:
          done=TRUE;
          break;
        case CH_BACKSPACE:
          if (n)
            ht_src[n-1]=0;
          break;
        default:
          if (ch=='\n' || 32<=ch<127) {
            if (n<HT_SRC_MAX-1) {
              ht_src[n]=ch;
              ht_src[n+1]=0;
            }
          }
      }
    }
  } catch
    PutExcept;
  ht_cursor=FALSE;
  Fs->draw_it=NULL;		//hand the screen back to the shell
}

Bool ht_gui=FileFind("E:/GUI.TXT");
StrCpy(ht_src,ht_src1);
HtStatus(FALSE,"READY  sample 1 (built-in)");
ht_fp=&MainImage;
HTMInit;			//build the LUT once, before any F3/GLSL shading
HTRInit;			//build the palette LUT and Bayer offsets once
ht_u.click_x=-1;
ht_u.click_y=-1;
Fs->draw_it=&HtDrawIt;
Bool ht_had_shader=HtLoadGlsl();
if (!ht_had_shader)
  ht_had_shader=HtLoadShader();	//temporary host-generated compatibility path
if (ht_gui)
  HtInteract;			//shader (if any) already live in the viewport
else if (ht_had_shader)
  Sleep(3000);			//headless GLSL mode: just let the rolling
				//screendumps capture the animating shader;
				//the recompile markers are the no-shader
				//run's job (keep the two modes separate)
else
  HtSelfTest;
