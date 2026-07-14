//HolyToy typed semantic pass. AST nodes are annotated with GLSL types and
//name bindings before the emitter sees them.

class CHtSymbol
{
  I64 tok,type,decl;
};

U0 HtSemaError(CHtProgram *p,I64 tok,U8 *msg)
{
  CHtToken *t;
  if (*p->error) return;
  if (tok<0 || tok>=p->lex->count) tok=0;
  t=&p->lex->tok[tok];
  StrPrint(p->error,"line %d:%d: %s",t->line,t->col,msg);
}

Bool HtTokSame(CHtLexer *l,I64 a,I64 b)
{
  CHtToken *x=&l->tok[a],*y=&l->tok[b];
  return x->len==y->len && !StrNCmp(l->src+x->start,l->src+y->start,x->len);
}

I64 HtFindSymbol(CHtProgram *p,CHtSymbol *sym,I64 count,I64 tok)
{
  I64 i;
  for (i=count-1;i>=0;i--)
    if (HtTokSame(p->lex,sym[i].tok,tok)) return i;
  return -1;
}

I64 HtArgCount(CHtProgram *p,I64 i)
{
  I64 n=0;
  while (i>=0) {
    n++;
    i=p->node[i].next;
  }
  return n;
}

I64 HtArgAt(CHtProgram *p,I64 i,I64 wanted)
{
  while (i>=0 && wanted) {
    i=p->node[i].next;
    wanted--;
  }
  return i;
}

I64 HtVectorType(I64 a,I64 b)
{
  if (a==b) return a;
  if (a==HT_TYPE_FLOAT && (b==HT_TYPE_VEC2 || b==HT_TYPE_VEC4)) return b;
  if (b==HT_TYPE_FLOAT && (a==HT_TYPE_VEC2 || a==HT_TYPE_VEC4)) return a;
  return HT_TYPE_BAD;
}

I64 HtSemaExpr(CHtProgram *p,I64 i,CHtSymbol *sym,I64 sym_count)
{
  CHtAst *n,*callee;
  I64 a,b,s,t,arg,count,k,a0,a1;
  if (i<0) return HT_TYPE_BAD;
  n=&p->node[i];
  if (n->kind==HT_AST_NUMBER) {
    n->type=HT_TYPE_FLOAT;
  } else if (n->kind==HT_AST_NAME) {
    if (HtTokEq(p->lex,n->tok,"fragCoord")) {
      n->type=HT_TYPE_VEC2;
      n->bind=HT_BIND_FRAGCOORD;
    } else if (HtTokEq(p->lex,n->tok,"iResolution")) {
      n->type=HT_TYPE_VEC2;
      n->bind=HT_BIND_RESOLUTION;
    } else if (HtTokEq(p->lex,n->tok,"iTime")) {
      n->type=HT_TYPE_FLOAT;
      n->bind=HT_BIND_TIME;
    } else if (HtTokEq(p->lex,n->tok,"fragColor")) {
      n->type=HT_TYPE_VEC4;
      n->bind=HT_BIND_FRAGCOLOR;
    } else {
      s=HtFindSymbol(p,sym,sym_count,n->tok);
      if (s<0) {
        HtSemaError(p,n->tok,"unknown name");
        return HT_TYPE_BAD;
      }
      n->type=sym[s].type;
      n->bind=HT_BIND_LOCAL;
      n->c=sym[s].decl;
    }
  } else if (n->kind==HT_AST_UNARY) {
    a=HtSemaExpr(p,n->a,sym,sym_count);
    if (a!=HT_TYPE_FLOAT && a!=HT_TYPE_VEC2 && a!=HT_TYPE_VEC4) {
      HtSemaError(p,n->tok,"invalid unary operand");
      return HT_TYPE_BAD;
    }
    n->type=a;
  } else if (n->kind==HT_AST_BINARY) {
    a=HtSemaExpr(p,n->a,sym,sym_count);
    b=HtSemaExpr(p,n->b,sym,sym_count);
    t=HtVectorType(a,b);
    if (t==HT_TYPE_BAD) {
      HtSemaError(p,n->tok,"incompatible arithmetic operands");
      return HT_TYPE_BAD;
    }
    if (HtTokEq(p->lex,n->tok,"+") || HtTokEq(p->lex,n->tok,"-") ||
        HtTokEq(p->lex,n->tok,"*") || HtTokEq(p->lex,n->tok,"/"))
      n->type=t;
    else if (HtTokEq(p->lex,n->tok,"<") || HtTokEq(p->lex,n->tok,">") ||
             HtTokEq(p->lex,n->tok,"<=") || HtTokEq(p->lex,n->tok,">=") ||
             HtTokEq(p->lex,n->tok,"==") || HtTokEq(p->lex,n->tok,"!=") ||
             HtTokEq(p->lex,n->tok,"&&") || HtTokEq(p->lex,n->tok,"||"))
      n->type=t;
    else {
      HtSemaError(p,n->tok,"unsupported binary operator");
      return HT_TYPE_BAD;
    }
  } else if (n->kind==HT_AST_MEMBER) {
    a=HtSemaExpr(p,n->a,sym,sym_count);
    if ((a==HT_TYPE_VEC2 || a==HT_TYPE_VEC4) &&
        (HtTokEq(p->lex,n->tok,"x") || HtTokEq(p->lex,n->tok,"y")))
      n->type=HT_TYPE_FLOAT;
    else if ((a==HT_TYPE_VEC2 || a==HT_TYPE_VEC4) &&
             HtTokEq(p->lex,n->tok,"xy"))
      n->type=HT_TYPE_VEC2;
    else {
      HtSemaError(p,n->tok,"unsupported swizzle");
      return HT_TYPE_BAD;
    }
  } else if (n->kind==HT_AST_CALL) {
    if (n->a<0 || p->node[n->a].kind!=HT_AST_NAME) {
      HtSemaError(p,n->tok,"callee must be a name");
      return HT_TYPE_BAD;
    }
    callee=&p->node[n->a];
    arg=n->b;
    count=HtArgCount(p,arg);
    k=arg;
    while (k>=0) {
      if (HtSemaExpr(p,k,sym,sym_count)==HT_TYPE_BAD) return HT_TYPE_BAD;
      k=p->node[k].next;
    }
    if (HtTokEq(p->lex,callee->tok,"vec2")) {
      if (count==1 && p->node[arg].type==HT_TYPE_FLOAT) t=HT_TYPE_VEC2;
      else if (count==2 && p->node[arg].type==HT_TYPE_FLOAT &&
              p->node[p->node[arg].next].type==HT_TYPE_FLOAT) t=HT_TYPE_VEC2;
      else {
        HtSemaError(p,callee->tok,"vec2 expects one or two floats");
        t=HT_TYPE_BAD;
      }
    } else if (HtTokEq(p->lex,callee->tok,"vec4")) {
      if (count==1 && p->node[arg].type==HT_TYPE_FLOAT) t=HT_TYPE_VEC4;
      else if (count==4) {
        t=HT_TYPE_VEC4;
        k=arg;
        while (k>=0)
          if (p->node[k].type!=HT_TYPE_FLOAT) {
            HtSemaError(p,p->node[k].tok,"vec4 components must be floats");
            t=HT_TYPE_BAD;
            break;
          } else
            k=p->node[k].next;
      } else {
        HtSemaError(p,callee->tok,"vec4 expects one or four floats");
        t=HT_TYPE_BAD;
      }
    } else if (HtTokEq(p->lex,callee->tok,"length")) {
      if (count==1 && p->node[arg].type==HT_TYPE_VEC2) t=HT_TYPE_FLOAT;
      else {
        HtSemaError(p,callee->tok,"length expects vec2");
        t=HT_TYPE_BAD;
      }
    } else if (HtTokEq(p->lex,callee->tok,"step")) {
      if (count!=2) {
        HtSemaError(p,callee->tok,"step expects two arguments");
        t=HT_TYPE_BAD;
      } else {
        a0=p->node[arg].type;
        a1=p->node[p->node[arg].next].type;
        t=HtVectorType(a0,a1);
        if (t==HT_TYPE_BAD)
          HtSemaError(p,callee->tok,"incompatible step arguments");
      }
    } else {
      HtSemaError(p,callee->tok,"unknown function");
      t=HT_TYPE_BAD;
    }
    n->type=t;
  } else {
    HtSemaError(p,n->tok,"expected value expression");
    return HT_TYPE_BAD;
  }
  return n->type;
}

Bool HtSemaBlock(CHtProgram *p,I64 block,CHtSymbol *sym,I64 *sym_count)
{
  I64 saved=*sym_count,i,t,s;
  CHtAst *n,*lhs;
  i=p->node[block].a;
  while (i>=0 && !*p->error) {
    n=&p->node[i];
    if (n->kind==HT_AST_BLOCK) {
      HtSemaBlock(p,i,sym,sym_count);
    } else if (n->kind==HT_AST_DECL) {
      for (s=*sym_count-1;s>=saved;s--)
        if (HtTokSame(p->lex,sym[s].tok,n->tok)) {
          HtSemaError(p,n->tok,"duplicate local name");
          break;
        }
      if (*p->error) break;
      if (n->a>=0) {
        t=HtSemaExpr(p,n->a,sym,*sym_count);
        if (t!=n->type)
          HtSemaError(p,n->tok,"initializer type mismatch");
      }
      sym[*sym_count].tok=n->tok;
      sym[*sym_count].type=n->type;
      sym[*sym_count].decl=i;
      (*sym_count)++;
    } else if (n->kind==HT_AST_ASSIGN) {
      if (n->a<0 || p->node[n->a].kind!=HT_AST_NAME) {
        HtSemaError(p,n->tok,"assignment target must be a name");
        break;
      }
      t=HtSemaExpr(p,n->a,sym,*sym_count);
      if (HtSemaExpr(p,n->b,sym,*sym_count)!=t)
        HtSemaError(p,n->tok,"assignment type mismatch");
      lhs=&p->node[n->a];
      if (lhs->bind!=HT_BIND_LOCAL && lhs->bind!=HT_BIND_FRAGCOLOR)
        HtSemaError(p,lhs->tok,"cannot assign to input");
    } else if (n->kind==HT_AST_EXPR_STMT) {
      HtSemaExpr(p,n->a,sym,*sym_count);
    } else {
      HtSemaError(p,n->tok,"invalid statement");
    }
    i=n->next;
  }
  *sym_count=saved;
  return !*p->error;
}

Bool HtLower(CHtProgram *p)
{
  CHtSymbol *sym;
  I64 sym_count=0;
  Bool ok;
  sym=CAlloc((p->node_count+8)*sizeof(CHtSymbol));
  ok=HtSemaBlock(p,p->root,sym,&sym_count);
  Free(sym);
  return ok;
}
