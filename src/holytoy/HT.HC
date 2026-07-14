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
};

CHtUniforms ht_u;
U0 (*ht_fp)(CHtUniforms *u,F64 frag_x,F64 frag_y,CHtFragColor *out_color);
U0 (*ht_default_fp)(CHtUniforms *u,F64 frag_x,F64 frag_y,CHtFragColor *out_color);
U8 ht_glsl_src[HT_GLSL_MAX];	//GLSL editor source; never replaced by HolyC
U8 ht_status[96];		//status/error line text
Bool ht_status_err;		//status line draws LTRED when TRUE
Bool ht_cursor;			//GUI edit mode: draw an end-of-buffer cursor
F64 ht_t0;			//shading-loop timing start (per frame)
I64 ht_shade_ms;		//last frame's shading time, whole ms
Bool ht_mouse_lb_prev;		//rising-edge state for iMouse click position

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

U0 MainImage(CHtUniforms *u,F64 frag_x,F64 frag_y,CHtFragColor *out_color)
{//Built-in last-good shader: plasma bands while GLSL is being edited.
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
  U8 *p=ht_glsl_src,line[81];
  if (y1>dc->height) y1=dc->height;
  for (sy=y0;sy<y1;sy++)
    MemSet(&dc->body[sy*stride+task->pix_left],BLACK,task->pix_width);
  dc->color=LTGRAY;
  GrPrint(dc,0,HT_PANE_ROW*8," HolyToy %3dms  F5 compile GLSL  F1-F2 samples  ESC exit",ht_shade_ms);
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
    sy=StrLen(ht_glsl_src);	//cursor cell: end of buffer
    dc->color=YELLOW;
    if (!sy || ht_glsl_src[sy-1]=='\n')
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
      ht_fp=ht_new_fp;
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
  I64 n=StrLen(glsl);
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
  return HtInstallHoly(result.holy);
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
  ht_fp=ht_default_fp;		//park on the animated default shader
  HtCompileAndSwapGlsl(ht_glsl_bad); //show GLSL error over live viewport
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
      n=StrLen(ht_glsl_src);
      switch (ch) {
        case 0:
          switch (sc.u8[0]) {
            case SC_F1: HtCompileAndSwapGlsl(ht_glsl1); break;
            case SC_F2: HtCompileAndSwapGlsl(ht_glsl2); break;
            case SC_F5: HtCompileAndSwapGlsl(ht_glsl_src); break;
          }
          break;
        case CH_ESC:
        case CH_SHIFT_ESC:
          done=TRUE;
          break;
        case CH_BACKSPACE:
          if (n)
            ht_glsl_src[n-1]=0;
          break;
        default:
          if (ch=='\n' || 32<=ch<127) {
            if (n<HT_GLSL_MAX-1) {
              ht_glsl_src[n]=ch;
              ht_glsl_src[n+1]=0;
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
StrCpy(ht_glsl_src,ht_glsl1);
HtStatus(FALSE,"READY  sample 1 (built-in)");
ht_fp=&MainImage;
ht_default_fp=ht_fp;
HTMInit;			//build the LUT once, before any F3/GLSL shading
HTRInit;			//build the palette LUT and Bayer offsets once
ht_u.click_x=-1;
ht_u.click_y=-1;
Fs->draw_it=&HtDrawIt;
Bool ht_had_shader=HtLoadGlsl();
if (ht_gui)
  HtInteract;			//shader (if any) already live in the viewport
else if (ht_had_shader)
  Sleep(3000);			//headless GLSL mode: just let the rolling
				//screendumps capture the animating shader;
				//the recompile markers are the no-shader
				//run's job (keep the two modes separate)
else
  HtSelfTest;
