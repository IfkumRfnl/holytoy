//holytoy hello-world: full-screen vertical gradient.
//
//The "shader" model: install a draw_it callback and the window manager
//calls it every frame (~30fps) — same idiom as Demo/Graphics/Box.HC.
//The harness (guest/RUN.HC) has already gone borderless-fullscreen and
//keeps the task alive while the host grabs screendumps.
U0 DrawIt(CTask *,CDC *dc)
{
  I64 y,h=Fs->pix_height,w=Fs->pix_width;
  for (y=0;y<h;y++) {
    dc->color=y*COLORS_NUM/h;
    GrLine(dc,0,y,w-1,y);
  }
}
Fs->draw_it=&DrawIt;
