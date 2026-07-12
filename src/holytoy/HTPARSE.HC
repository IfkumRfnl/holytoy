//HolyToy guest GLSL parser. Plan 008 vertical slice parses mainImage and a
//scalar expression with numbers, fragCoord.y, iResolution.y, and + - * /.

#define HT_AST_NUMBER	1
#define HT_AST_NAME	2
#define HT_AST_BINARY	3
#define HT_AST_MAX	64

class CHtAst { I64 kind,left,right,tok; U8 op; };
class CHtProgram
{
  CHtLexer *lex;
  I64 pos,node_count,root;
  CHtAst node[HT_AST_MAX];
  U8 error[96];
};

Bool HtTake(CHtProgram *p,U8 *s)
{
  if (HtTokEq(p->lex,p->pos,s)) { p->pos++; return TRUE; }
  return FALSE;
}

I64 HtNode(CHtProgram *p,I64 kind,I64 tok,I64 left=0,I64 right=0,U8 op=0)
{
  I64 i=p->node_count++;
  if (i>=HT_AST_MAX) { StrCpy(p->error,"AST node limit"); return -1; }
  p->node[i].kind=kind; p->node[i].tok=tok;
  p->node[i].left=left; p->node[i].right=right; p->node[i].op=op;
  return i;
}

I64 HtParseExpr(CHtProgram *p);

I64 HtParsePrimary(CHtProgram *p)
{
  I64 t=p->pos,n,member=-1;
  if (HtTake(p,"(")) {
    n=HtParseExpr(p);
    if (!HtTake(p,")")) StrCpy(p->error,"expected ')'");
    return n;
  }
  if (p->lex->tok[t].kind==HT_TOK_NUMBER) { p->pos++; return HtNode(p,HT_AST_NUMBER,t); }
  if (p->lex->tok[t].kind==HT_TOK_IDENT) {
    p->pos++;
    if (HtTake(p,".")) {
      if (p->lex->tok[p->pos].kind!=HT_TOK_IDENT) {
        StrCpy(p->error,"expected member name"); return -1;
      }
      member=p->pos++;
    }
    return HtNode(p,HT_AST_NAME,t,0,member);
  }
  StrCpy(p->error,"expected expression"); return -1;
}

I64 HtParseMul(CHtProgram *p)
{
  I64 a=HtParsePrimary(p),b; U8 op;
  while (!*p->error && (HtTokEq(p->lex,p->pos,"*") || HtTokEq(p->lex,p->pos,"/"))) {
    op=p->lex->tok[p->pos++].punct; b=HtParsePrimary(p);
    a=HtNode(p,HT_AST_BINARY,0,a,b,op);
  }
  return a;
}

I64 HtParseExpr(CHtProgram *p)
{
  I64 a=HtParseMul(p),b; U8 op;
  while (!*p->error && (HtTokEq(p->lex,p->pos,"+") || HtTokEq(p->lex,p->pos,"-"))) {
    op=p->lex->tok[p->pos++].punct; b=HtParseMul(p);
    a=HtNode(p,HT_AST_BINARY,0,a,b,op);
  }
  return a;
}

Bool HtParse(CHtProgram *p,CHtLexer *l)
{
  MemSet(p,0,sizeof(CHtProgram)); p->lex=l;
  if (!HtTake(p,"void") || !HtTake(p,"mainImage") || !HtTake(p,"("))
    StrCpy(p->error,"expected void mainImage(");
  //The slice validates the standard signature without treating parameters as
  //unstructured text.
  if (!*p->error && (!HtTake(p,"out") || !HtTake(p,"vec4") ||
      !HtTake(p,"fragColor") || !HtTake(p,",") || !HtTake(p,"in") ||
      !HtTake(p,"vec2") || !HtTake(p,"fragCoord") || !HtTake(p,")") ||
      !HtTake(p,"{") || !HtTake(p,"fragColor") || !HtTake(p,"=") ||
      !HtTake(p,"vec4") || !HtTake(p,"(")))
    StrCpy(p->error,"unsupported mainImage shape");
  if (!*p->error) p->root=HtParseExpr(p);
  if (!*p->error && (!HtTake(p,")") || !HtTake(p,";") || !HtTake(p,"}") ||
      p->lex->tok[p->pos].kind!=HT_TOK_EOF))
    StrCpy(p->error,"expected vec4(expr); }");
  return !*p->error;
}
