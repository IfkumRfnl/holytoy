//HolyToy in-guest GLSL compiler orchestration and public interface.
//Pipeline: HtPreprocess -> HtLex -> HtParse -> HtLower (typed sema) ->
//HtEmit. All intermediate storage belongs to one compile attempt; the
//generated HolyC source is the sole allocation handed to the caller.

class CHtCompileResult
{
  Bool ok;
  U8 *holy;
  U8 error[160];
};

U0 HtCompileResultDel(CHtCompileResult *r)
{
  Free(r->holy);
  MemSet(r,0,sizeof(CHtCompileResult));
}

Bool HtCompileGlsl(U8 *src,CHtCompileResult *r)
{
  CHtLexer lex;
  CHtProgram prog;
  U8 *holy=NULL,*pp;
  MemSet(r,0,sizeof(CHtCompileResult));
  MemSet(&lex,0,sizeof(CHtLexer));
  MemSet(&prog,0,sizeof(CHtProgram));
  pp=HtPreprocess(src,r->error);
  if (!pp) return FALSE;
  if (!HtLex(&lex,pp)) {
    StrCpy(r->error,lex.error);
    Free(pp);
    return FALSE;
  }
  if (!HtParse(&prog,&lex)) {
    StrCpy(r->error,prog.error);
  } else if (!HtLower(&prog)) {
    StrCpy(r->error,prog.error);
  } else {
    holy=HtEmit(&prog);
    if (!holy) StrCpy(r->error,prog.error);
  }
  HtProgramDel(&prog);
  HtLexDel(&lex);
  Free(pp);
  if (!holy) return FALSE;
  r->holy=holy;
  r->ok=TRUE;
  return TRUE;
}
