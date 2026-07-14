//HolyToy guest GLSL parser. The AST is source-sized and owned by CHtProgram.

#define HT_AST_NUMBER     1
#define HT_AST_NAME       2
#define HT_AST_BINARY     3
#define HT_AST_UNARY      4
#define HT_AST_CALL       5
#define HT_AST_MEMBER     6
#define HT_AST_DECL       7
#define HT_AST_ASSIGN     8
#define HT_AST_EXPR_STMT  9
#define HT_AST_BLOCK      10

#define HT_TYPE_BAD       0
#define HT_TYPE_VOID      1
#define HT_TYPE_FLOAT     2
#define HT_TYPE_VEC2      3
#define HT_TYPE_VEC4      4

#define HT_BIND_NONE      0
#define HT_BIND_FRAGCOORD 1
#define HT_BIND_RESOLUTION 2
#define HT_BIND_TIME      3
#define HT_BIND_FRAGCOLOR 4
#define HT_BIND_LOCAL     5

class CHtAst
{
  I64 kind,tok,a,b,c,next,type,bind;
};

class CHtProgram
{
  CHtLexer *lex;
  I64 pos,node_count,node_cap,root;
  CHtAst *node;
  U8 error[160];
};

U0 HtProgramDel(CHtProgram *p)
{
  Free(p->node);
  p->node=NULL;
  p->node_count=0;
  p->node_cap=0;
}

U0 HtParseError(CHtProgram *p,I64 tok,U8 *msg)
{
  CHtToken *t;
  if (*p->error) return;
  if (tok<0 || tok>=p->lex->count) tok=p->pos;
  t=&p->lex->tok[tok];
  StrPrint(p->error,"line %d:%d: %s",t->line,t->col,msg);
}

Bool HtTake(CHtProgram *p,U8 *s)
{
  if (HtTokEq(p->lex,p->pos,s)) {
    p->pos++;
    return TRUE;
  }
  return FALSE;
}

Bool HtNeed(CHtProgram *p,U8 *s)
{
  U8 *msg;
  if (HtTake(p,s)) return TRUE;
  msg=MStrPrint("expected '%s'",s);
  HtParseError(p,p->pos,msg);
  Free(msg);
  return FALSE;
}

I64 HtNode(CHtProgram *p,I64 kind,I64 tok)
{
  I64 i;
  CHtAst *n;
  if (p->node_count>=p->node_cap) {
    HtParseError(p,tok,"internal AST capacity");
    return -1;
  }
  i=p->node_count++;
  n=&p->node[i];
  MemSet(n,0,sizeof(CHtAst));
  n->kind=kind;
  n->tok=tok;
  n->a=-1;
  n->b=-1;
  n->c=-1;
  n->next=-1;
  return i;
}

I64 HtPrec(CHtProgram *p,I64 tok)
{
  if (HtTokEq(p->lex,tok,"||")) return 1;
  if (HtTokEq(p->lex,tok,"&&")) return 2;
  if (HtTokEq(p->lex,tok,"==") || HtTokEq(p->lex,tok,"!=")) return 3;
  if (HtTokEq(p->lex,tok,"<") || HtTokEq(p->lex,tok,">") ||
      HtTokEq(p->lex,tok,"<=") || HtTokEq(p->lex,tok,">=")) return 4;
  if (HtTokEq(p->lex,tok,"+") || HtTokEq(p->lex,tok,"-")) return 5;
  if (HtTokEq(p->lex,tok,"*") || HtTokEq(p->lex,tok,"/") ||
      HtTokEq(p->lex,tok,"%")) return 6;
  return 0;
}

I64 HtParseExprPrec(CHtProgram *p,I64 min_prec)
{
  I64 t=p->pos,n,left,right,op,prec,first,last,arg,call,member;
  if (HtTake(p,"(")) {
    left=HtParseExprPrec(p,1);
    HtNeed(p,")");
  } else if (HtTokEq(p->lex,p->pos,"+") ||
             HtTokEq(p->lex,p->pos,"-") ||
             HtTokEq(p->lex,p->pos,"!")) {
    p->pos++;
    left=HtNode(p,HT_AST_UNARY,t);
    if (left>=0) p->node[left].a=HtParseExprPrec(p,7);
  } else if (p->lex->tok[t].kind==HT_TOK_NUMBER) {
    p->pos++;
    left=HtNode(p,HT_AST_NUMBER,t);
  } else if (p->lex->tok[t].kind==HT_TOK_IDENT) {
    p->pos++;
    left=HtNode(p,HT_AST_NAME,t);
  } else {
    HtParseError(p,t,"expected expression");
    return -1;
  }
  while (!*p->error) {
    if (HtTake(p,"(")) {
      call=HtNode(p,HT_AST_CALL,t);
      if (call<0) return -1;
      p->node[call].a=left;
      first=-1;
      last=-1;
      if (!HtTake(p,")")) {
        while (!*p->error) {
          arg=HtParseExprPrec(p,1);
          if (arg<0) return -1;
          if (first<0) first=arg;
          else p->node[last].next=arg;
          last=arg;
          if (HtTake(p,")")) break;
          if (!HtNeed(p,",")) return -1;
        }
      }
      p->node[call].b=first;
      left=call;
    } else if (HtTake(p,".")) {
      member=p->pos;
      if (p->lex->tok[member].kind!=HT_TOK_IDENT) {
        HtParseError(p,member,"expected member name");
        return -1;
      }
      p->pos++;
      n=HtNode(p,HT_AST_MEMBER,member);
      if (n<0) return -1;
      p->node[n].a=left;
      left=n;
    } else
      break;
  }
  while (!*p->error) {
    op=p->pos;
    prec=HtPrec(p,op);
    if (prec<min_prec) break;
    p->pos++;
    right=HtParseExprPrec(p,prec+1);
    n=HtNode(p,HT_AST_BINARY,op);
    if (n<0) return -1;
    p->node[n].a=left;
    p->node[n].b=right;
    left=n;
  }
  return left;
}

I64 HtParseExpr(CHtProgram *p)
{
  return HtParseExprPrec(p,1);
}

I64 HtParseType(CHtProgram *p)
{
  if (HtTake(p,"float")) return HT_TYPE_FLOAT;
  if (HtTake(p,"vec2")) return HT_TYPE_VEC2;
  if (HtTake(p,"vec4")) return HT_TYPE_VEC4;
  return HT_TYPE_BAD;
}

I64 HtParseBlock(CHtProgram *p)
{
  I64 block,first=-1,last=-1,stmt,t,name,type,expr;
  if (!HtNeed(p,"{")) return -1;
  block=HtNode(p,HT_AST_BLOCK,p->pos-1);
  while (!*p->error && !HtTake(p,"}")) {
    if (p->lex->tok[p->pos].kind==HT_TOK_EOF) {
      HtParseError(p,p->pos,"expected '}'");
      break;
    }
    if (HtTokEq(p->lex,p->pos,"{")) {
      stmt=HtParseBlock(p);
    } else if (HtTokEq(p->lex,p->pos,"float") ||
               HtTokEq(p->lex,p->pos,"vec2") ||
               HtTokEq(p->lex,p->pos,"vec4")) {
      t=p->pos;
      type=HtParseType(p);
      name=p->pos;
      if (p->lex->tok[name].kind!=HT_TOK_IDENT) {
        HtParseError(p,name,"expected variable name");
        break;
      }
      p->pos++;
      stmt=HtNode(p,HT_AST_DECL,t);
      p->node[stmt].type=type;
      p->node[stmt].tok=name;
      if (HtTake(p,"=")) p->node[stmt].a=HtParseExpr(p);
      if (!HtNeed(p,";")) break;
    } else {
      expr=HtParseExpr(p);
      if (expr<0) break;
      if (HtTake(p,"=")) {
        stmt=HtNode(p,HT_AST_ASSIGN,p->pos-1);
        p->node[stmt].a=expr;
        p->node[stmt].b=HtParseExpr(p);
      } else {
        stmt=HtNode(p,HT_AST_EXPR_STMT,p->node[expr].tok);
        p->node[stmt].a=expr;
      }
      if (!HtNeed(p,";")) break;
    }
    if (stmt<0) break;
    if (first<0) first=stmt;
    else p->node[last].next=stmt;
    last=stmt;
  }
  if (block>=0) p->node[block].a=first;
  return block;
}

Bool HtParse(CHtProgram *p,CHtLexer *l)
{
  MemSet(p,0,sizeof(CHtProgram));
  p->lex=l;
  p->root=-1;
  //Each AST node consumes at least one source token in this grammar.
  p->node_cap=l->count+8;
  p->node=CAlloc(p->node_cap*sizeof(CHtAst));
  if (!HtNeed(p,"void") || !HtNeed(p,"mainImage") || !HtNeed(p,"(") ||
      !HtNeed(p,"out") || !HtNeed(p,"vec4") || !HtNeed(p,"fragColor") ||
      !HtNeed(p,",") || !HtNeed(p,"in") || !HtNeed(p,"vec2") ||
      !HtNeed(p,"fragCoord") || !HtNeed(p,")"))
    return FALSE;
  p->root=HtParseBlock(p);
  if (!*p->error && p->lex->tok[p->pos].kind!=HT_TOK_EOF)
    HtParseError(p,p->pos,"expected end of file");
  return !*p->error;
}
