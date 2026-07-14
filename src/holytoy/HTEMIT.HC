//HolyToy HolyC emitter. Output targets the frozen plan 007 RGBA ABI.

#define HT_EMIT_MAX	4096
U8 ht_emit_buf[HT_EMIT_MAX];

Bool HtEmitExpr(CHtProgram *p,I64 i)
{
  CHtAst *n=&p->node[i]; CHtToken *t; U8 text[32];
  if (StrLen(ht_emit_buf)>HT_EMIT_MAX-128) { StrCpy(p->error,"emitter limit"); return FALSE; }
  if (n->kind==HT_AST_NUMBER) {
    t=&p->lex->tok[n->tok];
    if (t->len>=sizeof(text)) { StrCpy(p->error,"number too long"); return FALSE; }
    MemCpy(text,p->lex->src+t->start,t->len); text[t->len]=0;
    CatPrint(ht_emit_buf,"%s",text);
  } else if (n->kind==HT_AST_NAME) {
    if (HtTokEq(p->lex,n->tok,"fragCoord")) CatPrint(ht_emit_buf,"frag_y");
    else if (HtTokEq(p->lex,n->tok,"iResolution")) CatPrint(ht_emit_buf,"u->res_y");
    else CatPrint(ht_emit_buf,"u->i_time");
  } else if (n->kind==HT_AST_BINARY) {
    CatPrint(ht_emit_buf,"(");
    if (!HtEmitExpr(p,n->left)) return FALSE;
    CatPrint(ht_emit_buf,"%c",n->op);
    if (!HtEmitExpr(p,n->right)) return FALSE;
    CatPrint(ht_emit_buf,")");
  } else return FALSE;
  return TRUE;
}

U8 *HtEmit(CHtProgram *p)
{
  ht_emit_buf[0]=0;
  CatPrint(ht_emit_buf,"U0 MainImage(CHtUniforms *u,F64 frag_x,F64 frag_y,CHtFragColor *out_color)\n{\n  F64 v=");
  if (!HtEmitExpr(p,p->root)) return NULL;
  CatPrint(ht_emit_buf,";\n  out_color->r=v; out_color->g=v; out_color->b=v; out_color->a=v;\n}\n");
  return ht_emit_buf;
}
