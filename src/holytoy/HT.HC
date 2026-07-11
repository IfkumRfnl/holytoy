//HolyToy skeleton (plan 002): editable code pane + live animating viewport.
//The runner owns the pixels: draw_it iterates the viewport at HT_SCALE
//block granularity, calls MainImage through ht_fp for one sample per
//block, and pokes dc->body directly (src/plasma.HC idiom - absolute
//screen coords, stride=width_internal, no clipping).  The code pane is
//GrPrint'd from the same draw_it on the 8x8 font grid so the harness OCR
//(tools/scrtext.py) reads it exactly.
//Harness-mode: install draw_it and return; guest/RUN.HC brackets us.

#include "E:/HTMATH.HC"	//LUT sin/cos (16.16 turns); mkxfer.sh ships it always

#define HT_VIEW_H	288	//viewport: full width x 288 window pixels (~60%)
#define HT_SCALE	4	//shade once per 4x4 block (VISION.md render scale)
#define HT_PANE_ROW	36	//first code-pane text row (window row, 8px cells)
#define HT_SRC_ROWS	20	//source lines shown in the pane
#define HT_STATUS_ROW	58	//status/error line (last window row)
#define HT_SRC_MAX	4096

class CHtUniforms { F64 i_time; I64 i_frame; I64 res_x,res_y; I64 mouse_x,mouse_y; };

CHtUniforms ht_u;
U0 (*ht_fp)(CHtUniforms *u,I64 x,I64 y,U8 *out_color);
U8 ht_src[HT_SRC_MAX];		//current shader source (the code pane content)
U8 ht_status[96];		//status/error line text
Bool ht_status_err;		//status line draws LTRED when TRUE
Bool ht_cursor;			//GUI edit mode: draw an end-of-buffer cursor
F64 ht_t0;			//shading-loop timing start (per frame)
I64 ht_shade_ms;		//last frame's shading time, whole ms

U8 *ht_src1=
"U0 MainImage(CHtUniforms *u,I64 x,I64 y,U8 *out_color)\n"
"{//sample 1: plasma bands\n"
"  F64 fx=x,fy=y,t=u->i_time,v;\n"
"  v=Sin(fx*0.021+t)+\n"
"    Sin(fy*0.032-t*0.7)+\n"
"    Sin((fx+fy)*0.014+t*0.5)+\n"
"    Sin(Sqrt(fx*fx+fy*fy)*0.019-t*1.3);\n"
"  *out_color=ToI64(v*2.0+8.0)&15;\n"
"}\n";

U8 *ht_src2=
"U0 MainImage(CHtUniforms *u,I64 x,I64 y,U8 *out_color)\n"
"{//sample 2: expanding bright rings\n"
"  F64 dx=x-u->res_x/2.0,dy=y-u->res_y/2.0,t=u->i_time;\n"
"  *out_color=(ToI64(Sqrt(dx*dx+dy*dy)*0.11-t*9.0)&7)+8;\n"
"}\n";

U8 *ht_src3=
"U0 MainImage(CHtUniforms *u,I64 x,I64 y,U8 *out_color)\n"
"{//sample 3: fixed-point plasma (HTMATH 16.16-turn LUT sines)\n"
"  I64 t16=ToI64(u->i_time*0x3000),v;\n"
"  F64 fx=x,fy=y;\n"
"  v=HTMSin16(x*449+t16)+\n"
"    HTMSin16(y*323-t16*7/10)+\n"
"    HTMSin16((x+y)*219+t16/2)+\n"
"    HTMSin16(ToI64(Sqrt(fx*fx+fy*fy)*250.0)-t16*13/10);\n"
"  *out_color=(v>>14)&15;\n"
"}\n";

U8 *ht_bad=
"U0 MainImage(CHtUniforms *u,I64 x,I64 y,U8 *out_color)\n"
"{//deliberately broken: missing expression\n"
"  *out_color=;\n"
"}\n";

U0 MainImage(CHtUniforms *u,I64 x,I64 y,U8 *out_color)
{//Built-in sample shader v1: plasma bands (same text as ht_src1).
  F64 fx=x,fy=y,t=u->i_time,v;
  v=Sin(fx*0.021+t)+
    Sin(fy*0.032-t*0.7)+
    Sin((fx+fy)*0.014+t*0.5)+
    Sin(Sqrt(fx*fx+fy*fy)*0.019-t*1.3);
  *out_color=ToI64(v*2.0+8.0)&15;
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

U0 (*ht_new_fp)(CHtUniforms *u,I64 x,I64 y,U8 *out_color);

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
  I64 bx,by,i,j,sx0,sy,stride=dc->width_internal;
  I64 vw=task->pix_width,vh=HT_VIEW_H;
  I64 nbx=vw/HT_SCALE,nby=vh/HT_SCALE;
  U8 c,*p;
  if (vh>task->pix_height)
    vh=task->pix_height;
  ht_u.i_time=tS;
  ht_u.i_frame++;
  ht_u.res_x=vw;
  ht_u.res_y=vh;
  ht_u.mouse_x=ms.pos.x-task->pix_left;
  ht_u.mouse_y=ms.pos.y-task->pix_top;
  ht_t0=tS;			//time the shading work only, not the winmgr
				//frame cadence (docs/notes/perf-floor.md)
  if (ht_fp) {
    for (by=0;by<nby;by++) {
      for (bx=0;bx<nbx;bx++) {
        c=0;
        ht_fp(&ht_u,bx*HT_SCALE,by*HT_SCALE,&c);
        c&=15;
        sx0=task->pix_left+bx*HT_SCALE;
        if (0<=sx0<=dc->width-HT_SCALE) {
          for (i=0;i<HT_SCALE;i++) {
            sy=task->pix_top+by*HT_SCALE+i;
            if (0<=sy<dc->height) {
              p=&dc->body[sy*stride+sx0];
              for (j=0;j<HT_SCALE;j++)
                p[j]=c;
            }
          }
        }
      }
    }
  }
  ht_shade_ms=ToI64((tS-ht_t0)*1000.0);
  HtDrawPane(task,dc);
}

U0 HtSelfTest()
{//Headless proof driven by guest/RUN.HC; markers land in guest.log via
 //the task-doc dump.  Leaves the failed-compile state on screen at the
 //end so the final screenshot shows the error line over a live viewport.
  U0 (*before)(CHtUniforms *u,I64 x,I64 y,U8 *out_color);
  I64 f1,f2;
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
Fs->draw_it=&HtDrawIt;
if (ht_gui)
  HtInteract;
else
  HtSelfTest;
