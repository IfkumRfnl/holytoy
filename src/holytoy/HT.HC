//HolyToy skeleton (plan 002): editable code pane + live animating viewport.
//The runner owns the pixels: draw_it iterates the viewport at HT_SCALE
//block granularity, calls MainImage through ht_fp for one sample per
//block, and pokes dc->body directly (src/plasma.HC idiom - absolute
//screen coords, stride=width_internal, no clipping).  The code pane is
//GrPrint'd from the same draw_it on the 8x8 font grid so the harness OCR
//(tools/scrtext.py) reads it exactly.
//Harness-mode: install draw_it and return; guest/RUN.HC brackets us.

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
  GrPrint(dc,0,HT_PANE_ROW*8," HolyToy  F5 recompile  F1/F2 samples  ESC exit");
  dc->color=WHITE;
  row=HT_PANE_ROW+1;
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
  if (ht_status_err)
    dc->color=LTRED;
  else
    dc->color=LTGREEN;
  GrPrint(dc,0,HT_STATUS_ROW*8," %s",ht_status);
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
  HtDrawPane(task,dc);
}

StrCpy(ht_src,ht_src1);
HtStatus(FALSE,"READY  sample 1 (built-in)");
ht_fp=&MainImage;
Fs->draw_it=&HtDrawIt;
