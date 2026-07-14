//HolyToy in-guest GLSL compiler orchestration and public interface.

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
  U8 *holy=NULL;
  MemSet(r,0,sizeof(CHtCompileResult));
  MemSet(&lex,0,sizeof(CHtLexer));
  MemSet(&prog,0,sizeof(CHtProgram));
  if (!HtLex(&lex,src)) {
    StrCpy(r->error,lex.error);
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
  if (!holy) return FALSE;
  //The generated source is the sole allocation detached from the attempt.
  r->holy=holy;
  r->ok=TRUE;
  return TRUE;
}
