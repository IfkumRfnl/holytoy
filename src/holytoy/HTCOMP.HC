//HolyToy in-guest GLSL compiler orchestration and public interface.

class CHtCompileResult { Bool ok; U8 *holy; U8 error[96]; };

Bool HtCompileGlsl(U8 *src,CHtCompileResult *r)
{
  CHtLexer lex; CHtProgram prog;
  MemSet(r,0,sizeof(CHtCompileResult));
  if (!HtLex(&lex,src)) { StrCpy(r->error,lex.error); return FALSE; }
  if (!HtParse(&prog,&lex) || !HtLower(&prog)) {
    StrCpy(r->error,prog.error); return FALSE;
  }
  r->holy=HtEmit(&prog);
  if (!r->holy) { StrCpy(r->error,prog.error); return FALSE; }
  r->ok=TRUE;
  return TRUE;
}
