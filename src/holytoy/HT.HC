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
U0 (*ht_fp)(CHtUniforms *u,F64 frag_x,F64 frag_y,CHtFragColor *out_color);
U0 (*ht_default_fp)(CHtUniforms *u,F64 frag_x,F64 frag_y,CHtFragColor *out_color);
U8 ht_glsl_src[HT_GLSL_MAX];	//GLSL editor source; never replaced by HolyC
U8 ht_status[96];		//status/error line text
Bool ht_status_err;		//status line draws LTRED when TRUE
Bool ht_native_editor;		//a native CDoc backs the visible editor pane
I64 ht_edit_line,ht_edit_col;	//zero-based native CDoc cursor position
I64 ht_edit_top,ht_edit_left;	//visible source origin in lines/columns
F64 ht_t0;			//shading-loop timing start (per frame)
I64 ht_shade_ms;		//last frame's shading time, whole ms
Bool ht_mouse_lb_prev;		//rising-edge state for iMouse click position
I64 ht_scale=16;		//runtime shade-block size: 1,2,4,8,16
I64 ht_scale_lock=0;		//0 = adaptive; otherwise pinned by SCALE.TXT
I64 ht_scale_slow=0,ht_scale_fast=0;	//controller consecutive frames

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

U0 HtScaleReset()
{//A newly installed shader starts coarse; history never crosses shaders.
  ht_scale_slow=0;
  ht_scale_fast=0;
  if (!ht_scale_lock)
    ht_scale=16;
}

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

U0 HtDrawIt(CTask *task,CDC *dc)
{//dc aliases gr.dc2; raw body pokes are ABSOLUTE screen coords.
  I64 bx,by,i,j,sx0,sy,stride=dc->width_internal,r88,g88,b88;
  I64 rr,gg,bb,o,r5,g5,b5;
  I64 vw=task->pix_width,vh=HT_VIEW_H;
  I64 nbx=vw/ht_scale,nby=vh/ht_scale;
  U8 *p,q[256];
  CHtFragColor fc;
  if (vh>task->pix_height)
    vh=task->pix_height;
  CDateStruct ds;
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
  ht_t0=tS;			//time the shading work only, not the winmgr
				//frame cadence (docs/notes/perf-floor.md)
  if (ht_fp) {
    for (by=0;by<nby;by++) {
      for (bx=0;bx<nbx;bx++) {
        fc.r=0.0; fc.g=0.0; fc.b=0.0; fc.a=0.0;
        //At ht_scale=1 this is the exact Shadertoy pixel center (Y-up).
        ht_fp(&ht_u,bx*ht_scale+ht_scale*0.5,
              vh-(by*ht_scale+ht_scale*0.5),&fc);
        r88=ToI64(fc.r*256.0);
        g88=ToI64(fc.g*256.0);
        b88=ToI64(fc.b*256.0);
        if (r88<0) r88=0; else if (r88>256) r88=256;
        if (g88<0) g88=0; else if (g88>256) g88=256;
        if (b88<0) b88=0; else if (b88>256) b88=256;
        rr=r88*31;
        gg=g88*31;
        bb=b88*31;
        sx0=task->pix_left+bx*ht_scale;
        if (0<=sx0<=dc->width-ht_scale) {
          //Inline path matches HtQuantize at every block size: absolute
          //screen coordinates select the Bayer offset for each output pixel.
          for (i=0;i<ht_scale;i++) {
            sy=task->pix_top+by*ht_scale+i;
            for (j=0;j<ht_scale;j++) {
              o=htr_bofs[((sy&3)*4)+((sx0+j)&3)]*31;
              r5=(rr+o)>>8;
              g5=(gg+o)>>8;
              b5=(bb+o)>>8;
              if (r5<0) r5=0; else if (r5>31) r5=31;
              if (g5<0) g5=0; else if (g5>31) g5=31;
              if (b5<0) b5=0; else if (b5>31) b5=31;
              q[i*ht_scale+j]=htr_lut[(r5<<10)+(g5<<5)+b5];
            }
          }
          for (i=0;i<ht_scale;i++) {
            sy=task->pix_top+by*ht_scale+i;
            if (0<=sy<dc->height) {
              p=&dc->body[sy*stride+sx0];
              for (j=0;j<ht_scale;j++)
                p[j]=q[i*ht_scale+j];
            }
          }
        }
      }
    }
  }
  ht_shade_ms=ToI64((tS-ht_t0)*1000.0);
  if (!ht_scale_lock) {
    if (ht_shade_ms>250 && ht_scale<16) {
      ht_scale_slow++;
      ht_scale_fast=0;
      if (ht_scale_slow>=2) {
        ht_scale*=2;
        ht_scale_slow=ht_scale_fast=0;
      }
    } else if (ht_shade_ms*4<150 && ht_scale>1) {
      ht_scale_fast++;
      ht_scale_slow=0;
      if (ht_scale_fast>=4) {
        ht_scale/=2;
        ht_scale_slow=ht_scale_fast=0;
      }
    } else
      ht_scale_slow=ht_scale_fast=0;
  }
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
  I64 f1,f2,dx,dy,n=0,first=-1,scale_lock_save,scale_up,scale_down;
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
  scale_lock_save=ht_scale_lock;
  ht_scale_lock=0;
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
  U8 *man,*p,*src,name[16],id[16],path[24];
  I64 sz,i,k,n=0,pass=0;
  F64 t0,px,py;
  CHtCompileResult r;
  CHtFragColor fc;
  Bool ok;
  man=FileRead("E:/CORPUS.TXT",&sz);
  if (!man) {
    "HT CORPUS FAIL manifest\n";
    return;
  }
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
    while (*p && *p!='\n' && *p!='\r' && i<15) id[i++]=*p++;
    id[i]=0;
    while (*p=='\n' || *p=='\r') p++;
    if (!*name || !*id) break;
    n++;
    StrPrint(path,"E:/%s.GLS",name);
    src=FileRead(path,&sz);
    if (!src) {
      "HT CORPUS %s read ERR missing\n",id;
      goto corpus_next;
    }
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
    t0=tS;
    try {
      for (k=0;k<4;k++) {
        //Interior, edge and corner sample points at viewport 640x288.
        if (k==0) { px=320.5; py=144.5; }
        else if (k==1) { px=2.5; py=285.5; }
        else if (k==2) { px=600.5; py=20.5; }
        else { px=16.5; py=16.5; }
        fc.r=0.0; fc.g=0.0; fc.b=0.0; fc.a=0.0;
        ht_fp(&ht_u,px,py,&fc);
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
    } else
      "HT CORPUS %s exec ERR nonfinite\n",id;
    HtCompileResultDel(&r);
    Free(src);
corpus_next:;
  }
  Free(man);
  "HT CORPUS DONE %d/%d\n",pass,n;
  ht_fp=ht_default_fp;		//park on the built-in shader for the screenshot
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
StrCpy(ht_glsl_src,ht_glsl1);
HtStatus(FALSE,"READY  sample 1 (built-in)");
ht_fp=&MainImage;
ht_default_fp=ht_fp;
HTMInit;			//build the LUT once, before any F3/GLSL shading
HTRInit;			//build the palette LUT and Bayer offsets once
HtLibInit;			//F64 sine table for generated shader code
ht_u.click_x=-1;
ht_u.click_y=-1;
ht_native_editor=FALSE;
ht_edit_line=ht_edit_col=ht_edit_top=ht_edit_left=0;
if (ht_gui) {
  SettingsPush;			//HtInteract restores all task settings on exit
  ht_ac_was_on=AutoComplete(OFF);
  WinFocus(Fs);
}
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
if (ht_ac_was_on)
  AutoComplete(ON);
