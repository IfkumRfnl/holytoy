//HolyToy skeleton (plan 002, step 1): viewport-only render loop.
//The runner owns the pixels: draw_it iterates the viewport at HT_SCALE
//block granularity, calls MainImage through ht_fp for one sample per
//block, and pokes dc->body directly (src/plasma.HC idiom - absolute
//screen coords, stride=width_internal, no clipping).
//Harness-mode: install draw_it and return; guest/RUN.HC brackets us.

#define HT_VIEW_H	288	//viewport: full width x 288 window pixels (~60%)
#define HT_SCALE	4	//shade once per 4x4 block (VISION.md render scale)

class CHtUniforms { F64 i_time; I64 i_frame; I64 res_x,res_y; I64 mouse_x,mouse_y; };

CHtUniforms ht_u;
U0 (*ht_fp)(CHtUniforms *u,I64 x,I64 y,U8 *out_color);

U0 MainImage(CHtUniforms *u,I64 x,I64 y,U8 *out_color)
{//Built-in sample shader v1: plasma bands, time-varying, std palette.
  F64 fx=x,fy=y,t=u->i_time,v;
  v=Sin(fx*0.021+t)+
    Sin(fy*0.032-t*0.7)+
    Sin((fx+fy)*0.014+t*0.5)+
    Sin(Sqrt(fx*fx+fy*fy)*0.019-t*1.3);
  *out_color=ToI64(v*2.0+8.0)&15;
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
  if (!ht_fp) return;
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

ht_fp=&MainImage;
Fs->draw_it=&HtDrawIt;
