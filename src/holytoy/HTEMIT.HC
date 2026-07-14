//HolyToy HolyC emitter. Vectors lower to scalar HolyC locals and expressions;
//the public generated function still targets the CHtFragColor ABI.

class CHtEmitter
{
  CHtProgram *prog;
  U8 *buf;
  I64 len,cap;
};

Bool HtOutGrow(CHtEmitter *e,I64 extra)
{
  U8 *next;
  I64 cap=e->cap;
  if (e->len+extra+1<=cap) return TRUE;
  while (e->len+extra+1>cap) cap=cap*2;
  next=MAlloc(cap);
  if (e->buf) MemCpy(next,e->buf,e->len+1);
  else next[0]=0;
  Free(e->buf);
  e->buf=next;
  e->cap=cap;
  return TRUE;
}

Bool HtOutRaw(CHtEmitter *e,U8 *s,I64 n)
{
  if (!HtOutGrow(e,n)) return FALSE;
  MemCpy(e->buf+e->len,s,n);
  e->len+=n;
  e->buf[e->len]=0;
  return TRUE;
}

Bool HtOut(CHtEmitter *e,U8 *s)
{
  return HtOutRaw(e,s,StrLen(s));
}

Bool HtOutTok(CHtEmitter *e,I64 tok)
{
  CHtToken *t=&e->prog->lex->tok[tok];
  return HtOutRaw(e,e->prog->lex->src+t->start,t->len);
}

U0 HtEmitError(CHtEmitter *e,I64 tok,U8 *msg)
{
  HtSemaError(e->prog,tok,msg);
}

Bool HtIndent(CHtEmitter *e,I64 indent)
{
  while (indent--) if (!HtOut(e,"  ")) return FALSE;
  return TRUE;
}

Bool HtEmitLocalName(CHtEmitter *e,I64 tok,I64 type,I64 comp)
{
  if (!HtOut(e,"htv_")) return FALSE;
  if (!HtOutTok(e,tok)) return FALSE;
  if (type==HT_TYPE_VEC2) {
    if (comp==0) return HtOut(e,"_x");
    return HtOut(e,"_y");
  }
  if (type==HT_TYPE_VEC4) {
    if (comp==0) return HtOut(e,"_r");
    if (comp==1) return HtOut(e,"_g");
    if (comp==2) return HtOut(e,"_b");
    return HtOut(e,"_a");
  }
  return TRUE;
}

I64 HtCompFor(CHtProgram *p,I64 expr,I64 comp)
{
  if (p->node[expr].type==HT_TYPE_FLOAT) return 0;
  return comp;
}

Bool HtEmitNumber(CHtEmitter *e,I64 tok)
{
  CHtToken *t=&e->prog->lex->tok[tok];
  I64 n=t->len;
  I64 last=e->prog->lex->src[t->start+n-1];
  //HolyC has no numeric suffixes.
  if (last=='f' || last=='F' || last=='u' || last=='U') n--;
  return HtOutRaw(e,e->prog->lex->src+t->start,n);
}

Bool HtEmitExpr(CHtEmitter *e,I64 i,I64 comp)
{
  CHtProgram *p=e->prog;
  CHtAst *n=&p->node[i],*decl,*callee;
  I64 subcomp,arg,a0,a1;
  if (n->kind==HT_AST_NUMBER) {
    return HtEmitNumber(e,n->tok);
  } else if (n->kind==HT_AST_NAME) {
    if (n->bind==HT_BIND_FRAGCOORD) {
      if (comp==0) return HtOut(e,"frag_x");
      return HtOut(e,"frag_y");
    } else if (n->bind==HT_BIND_RESOLUTION) {
      if (comp==0) return HtOut(e,"u->res_x");
      return HtOut(e,"u->res_y");
    } else if (n->bind==HT_BIND_TIME) {
      return HtOut(e,"u->i_time");
    } else if (n->bind==HT_BIND_FRAGCOLOR) {
      if (comp==0) return HtOut(e,"out_color->r");
      if (comp==1) return HtOut(e,"out_color->g");
      if (comp==2) return HtOut(e,"out_color->b");
      return HtOut(e,"out_color->a");
    } else if (n->bind==HT_BIND_LOCAL) {
      decl=&p->node[n->c];
      return HtEmitLocalName(e,decl->tok,decl->type,comp);
    }
  } else if (n->kind==HT_AST_UNARY) {
    if (!HtOut(e,"(")) return FALSE;
    if (!HtOutTok(e,n->tok)) return FALSE;
    if (!HtEmitExpr(e,n->a,HtCompFor(p,n->a,comp))) return FALSE;
    return HtOut(e,")");
  } else if (n->kind==HT_AST_BINARY) {
    if (!HtOut(e,"(")) return FALSE;
    if (!HtEmitExpr(e,n->a,HtCompFor(p,n->a,comp))) return FALSE;
    if (!HtOutTok(e,n->tok)) return FALSE;
    if (!HtEmitExpr(e,n->b,HtCompFor(p,n->b,comp))) return FALSE;
    return HtOut(e,")");
  } else if (n->kind==HT_AST_MEMBER) {
    if (HtTokEq(p->lex,n->tok,"x")) subcomp=0;
    else if (HtTokEq(p->lex,n->tok,"y")) subcomp=1;
    else subcomp=comp;
    return HtEmitExpr(e,n->a,subcomp);
  } else if (n->kind==HT_AST_CALL) {
    callee=&p->node[n->a];
    arg=n->b;
    if (HtTokEq(p->lex,callee->tok,"vec2") ||
        HtTokEq(p->lex,callee->tok,"vec4")) {
      if (HtArgCount(p,arg)==1)
        return HtEmitExpr(e,arg,0);
      return HtEmitExpr(e,HtArgAt(p,arg,comp),0);
    }
    if (HtTokEq(p->lex,callee->tok,"length")) {
      if (!HtOut(e,"Sqrt((")) return FALSE;
      if (!HtEmitExpr(e,arg,0)) return FALSE;
      if (!HtOut(e,")*(")) return FALSE;
      if (!HtEmitExpr(e,arg,0)) return FALSE;
      if (!HtOut(e,")+(")) return FALSE;
      if (!HtEmitExpr(e,arg,1)) return FALSE;
      if (!HtOut(e,")*(")) return FALSE;
      if (!HtEmitExpr(e,arg,1)) return FALSE;
      return HtOut(e,"))");
    }
    if (HtTokEq(p->lex,callee->tok,"step")) {
      a0=arg;
      a1=p->node[arg].next;
      if (!HtOut(e,"ToF64((")) return FALSE;
      if (!HtEmitExpr(e,a1,HtCompFor(p,a1,comp))) return FALSE;
      if (!HtOut(e,")>=(")) return FALSE;
      if (!HtEmitExpr(e,a0,HtCompFor(p,a0,comp))) return FALSE;
      return HtOut(e,"))");
    }
    HtEmitError(e,callee->tok,"cannot emit function");
    return FALSE;
  }
  HtEmitError(e,n->tok,"cannot emit expression");
  return FALSE;
}

Bool HtEmitAssignment(CHtEmitter *e,CHtAst *stmt,I64 indent)
{
  CHtProgram *p=e->prog;
  CHtAst *lhs=&p->node[stmt->a];
  I64 count=1,k;
  if (lhs->type==HT_TYPE_VEC2) count=2;
  else if (lhs->type==HT_TYPE_VEC4) count=4;
  for (k=0;k<count;k++) {
    if (!HtIndent(e,indent)) return FALSE;
    if (lhs->bind==HT_BIND_FRAGCOLOR) {
      if (k==0) HtOut(e,"out_color->r");
      else if (k==1) HtOut(e,"out_color->g");
      else if (k==2) HtOut(e,"out_color->b");
      else HtOut(e,"out_color->a");
    } else if (!HtEmitLocalName(e,lhs->tok,lhs->type,k))
      return FALSE;
    if (!HtOut(e,"=")) return FALSE;
    if (!HtEmitExpr(e,stmt->b,HtCompFor(p,stmt->b,k))) return FALSE;
    if (!HtOut(e,";\n")) return FALSE;
  }
  return TRUE;
}

Bool HtEmitDecl(CHtEmitter *e,CHtAst *n,I64 indent)
{
  I64 count=1,k;
  if (n->type==HT_TYPE_VEC2) count=2;
  else if (n->type==HT_TYPE_VEC4) count=4;
  for (k=0;k<count;k++) {
    if (!HtIndent(e,indent) || !HtOut(e,"F64 ")) return FALSE;
    if (!HtEmitLocalName(e,n->tok,n->type,k) || !HtOut(e,"=")) return FALSE;
    if (n->a>=0) {
      if (!HtEmitExpr(e,n->a,HtCompFor(e->prog,n->a,k))) return FALSE;
    } else if (!HtOut(e,"0.0")) return FALSE;
    if (!HtOut(e,";\n")) return FALSE;
  }
  return TRUE;
}

Bool HtEmitBlock(CHtEmitter *e,I64 block,I64 indent,Bool braces)
{
  CHtProgram *p=e->prog;
  I64 i=p->node[block].a;
  CHtAst *n;
  if (braces) {
    if (!HtIndent(e,indent) || !HtOut(e,"{\n")) return FALSE;
    indent++;
  }
  while (i>=0) {
    n=&p->node[i];
    if (n->kind==HT_AST_BLOCK) {
      if (!HtEmitBlock(e,i,indent,TRUE)) return FALSE;
    } else if (n->kind==HT_AST_DECL) {
      if (!HtEmitDecl(e,n,indent)) return FALSE;
    } else if (n->kind==HT_AST_ASSIGN) {
      if (!HtEmitAssignment(e,n,indent)) return FALSE;
    } else if (n->kind==HT_AST_EXPR_STMT) {
      if (!HtIndent(e,indent) || !HtEmitExpr(e,n->a,0) || !HtOut(e,";\n"))
        return FALSE;
    }
    i=n->next;
  }
  if (braces) {
    indent--;
    if (!HtIndent(e,indent) || !HtOut(e,"}\n")) return FALSE;
  }
  return TRUE;
}

U8 *HtEmit(CHtProgram *p)
{
  CHtEmitter e;
  MemSet(&e,0,sizeof(CHtEmitter));
  e.prog=p;
  e.cap=p->lex->src_len*2+512;
  if (e.cap<1024) e.cap=1024;
  e.buf=MAlloc(e.cap);
  e.buf[0]=0;
  if (!HtOut(&e,"U0 MainImage(CHtUniforms *u,F64 frag_x,F64 frag_y,CHtFragColor *out_color)\n{\n") ||
      !HtEmitBlock(&e,p->root,1,FALSE) || !HtOut(&e,"}\n")) {
    Free(e.buf);
    return NULL;
  }
  return e.buf;
}
