//reload.HC - JIT live-reload PROOF + HolyC language-corner exercise.
//Written ONLY from skills/holyc (no vendor peeking) to test skill sufficiency.
//
//Run me in a task (F5 / #include). Running me a SECOND time in the SAME task
//additionally demonstrates cross-reload shadowing (globals below lose state,
//an already-installed draw_it keeps running the previous load's code, etc.).
//
//The core claim under test: you can REDEFINE Effect *later in the same file*
//(here via ExePrint, which compiles a string into THIS task's hash table), and
//  - a pointer captured BEFORE the redefinition still calls the OLD code,
//  - a fresh &Effect taken AFTER the redefinition binds the NEW code,
//  - re-running Fs->draw_it=&Effect; hot-swaps the live callback.

U0 (*old_ptr)(CTask *task,CDC *dc);    //captured BEFORE redefinition (must stay v1)
U0 (*new_ptr)(CTask *task,CDC *dc);    //set INSIDE the ExePrint unit -> guaranteed v2
U0 (*new_ptr2)(CTask *task,CDC *dc);   //fresh &Effect in THIS file AFTER redef (the gap test)
I64 g_last_ver;                        //each Effect version stamps this when it actually runs

U0 Effect(CTask *task,CDC *dc)
{//---- VERSION 1: RED bar sweeping RIGHT ----
  I64 w=task->pix_width,h=task->pix_height;
  I64 x=ToI64(tS*160.0)%w;
  g_last_ver=1;
  dc->color=RED;
  GrRect(dc,x,h/2-8,16,16);
}

U0 Banner()
{
  "=== reload.HC : JIT live-reload proof ===\n";
}

U0 DefArgs(I64 a=10,I64 b=0,I64 c=30)
{//default args need not be trailing; skip the middle one with a bare comma
  "default-arg skip  DefArgs(,7): a=%d b=%d c=%d  (expect 10 7 30)\n",a,b,c;
}

I64 Classify(I64 n)
{//case-range + empty-case auto-numbering, all inside one jump table
  I64 r;
  switch (n) {
    case 0...9:  r=100; break;   //range case
    case 10:     r=200; break;
    case:        r=201; break;   //empty case = previous+1 = 11
    case:        r=202; break;   //           = 12
    default:     r=-1;
  }
  return r;
}

U0 ExcDemo()
{//try/catch with Fs->except_ch dispatch (throw is a FUNCTION; catch takes no arg)
  try {
    throw('Bar');
  } catch {
    if (Fs->except_ch=='Bar') {
      "try/catch dispatch: caught Fs->except_ch=='Bar'\n";
      Fs->catch_except=TRUE;     //consume it, otherwise it auto-rethrows
    }
  }
}

//---------------- TEXT-MODE EVIDENCE PHASE (top-level statements) ----------------
Banner;                              //paren-less call: no & and no ()

old_ptr=&Effect;                     //& needed: a bare Effect would CALL it
Fs->draw_it=&Effect;                 //install v1 as the live callback
"old &Effect : 0x%08X   symbolic %P\n",old_ptr,old_ptr;

//--- Redefine Effect in the SAME task. ExePrint("%s",code) protects the '%' (modulo)
//    in the body from being read as a Print format spec. ---
ExePrint("%s",
  "U0 Effect(CTask *task,CDC *dc)"
  "{"
  "  I64 w=task->pix_width,h=task->pix_height;"
  "  I64 x=w-1-ToI64(tS*160.0)%w;"   //VERSION 2: BLUE bar sweeping LEFT
  "  g_last_ver=2;"
  "  dc->color=BLUE;"
  "  GrRect(dc,x,h/2-8,16,16);"
  "}"
  "new_ptr=&Effect;");               //compiled while v2 is current -> guaranteed v2

new_ptr2=&Effect;                    //fresh reference in THIS file, AFTER ExePrint ran

"new &Effect : 0x%08X   symbolic %P   (captured inside ExePrint unit)\n",new_ptr,new_ptr;
"file &Effect: 0x%08X   symbolic %P   (this file, post-redef)\n",new_ptr2,new_ptr2;
"old!=new  (new code shadow-allocated)              : %d\n",new_ptr!=old_ptr;
"file-ref == ExePrint new  (same-file redef worked) : %d\n",new_ptr2==new_ptr;

//--- Behaviour proof: OLD pointer must still run OLD code; fresh ref runs NEW code ---
CDC *probe=DCNew(64,64);             //throwaway offscreen DC so we don't touch the screen
g_last_ver=0; old_ptr(Fs,probe);  "captured old_ptr ran version %d  (expect 1)\n",g_last_ver;
g_last_ver=0; new_ptr(Fs,probe);  "fresh   new_ptr ran version %d  (expect 2)\n",g_last_ver;
DCDel(probe);

//--- Live-callback swap ---
"draw_it before swap: 0x%08X  (==old_ptr? %d)\n",Fs->draw_it,Fs->draw_it==old_ptr;
Fs->draw_it=&Effect;                 //re-run the assignment -> hot-swap to v2
"draw_it after  swap: 0x%08X  (==new_ptr? %d)\n",Fs->draw_it,Fs->draw_it==new_ptr;

//---------------- LANGUAGE-CORNER EXERCISES ----------------
"\n-- language corners --\n";
DefArgs(,7);                                              //default-arg skipping
"switch: 3->%d 10->%d 11->%d 12->%d 99->%d  (100 200 201 202 -1)\n",
  Classify(3),Classify(10),Classify(11),Classify(12),Classify(99);
{ I64 v=Fs->pix_width;
  "chained compare 0<=pix_width(%d)<2000 : %d\n",v,0<=v<2000; }   //chained comparison
{ I64 packed=0x11223344AABBCCDD;
  "sub-int  packed.u8[0]=0x%02X  packed.u32[1]=0x%08X  (DD  11223344)\n",
    packed.u8[0],packed.u32[1]; }                                //sub-int access
ExcDemo;                                                 //paren-less call + try/catch demo
"power operator  ToI64(2`10) = %d  (expect 1024)\n",ToI64(2`10); //` yields F64
"postfix cast  old_ptr(U8*) = %P\n",old_ptr(U8*);        //postfix typecast

//------------- VISUAL PHASE (defined AFTER redef, so its &Effect binds v2) -------------
//------------- VISUAL PHASE (harness-mode: draw_it already hot-swapped to v2 above;
//              guest/RUN.HC holds the picture — screenshot must show the BLUE bar) ---
"\nharness mode: leaving v2 draw_it installed.\n";
