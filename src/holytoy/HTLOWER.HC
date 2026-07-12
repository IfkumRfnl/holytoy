//HolyToy typed semantic/lowering pass for the plan 008 scalar slice.

Bool HtLowerNode(CHtProgram *p,I64 i)
{
  CHtAst *n=&p->node[i];
  if (n->kind==HT_AST_NUMBER) return TRUE;
  if (n->kind==HT_AST_BINARY)
    return HtLowerNode(p,n->left) && HtLowerNode(p,n->right);
  if (n->kind==HT_AST_NAME) {
    if ((HtTokEq(p->lex,n->tok,"fragCoord") ||
         HtTokEq(p->lex,n->tok,"iResolution")) &&
        n->right>=0 && HtTokEq(p->lex,n->right,"y"))
      return TRUE;
    StrPrint(p->error,"line %d: unknown name",p->lex->tok[n->tok].line);
    return FALSE;
  }
  StrCpy(p->error,"invalid AST node"); return FALSE;
}

Bool HtLower(CHtProgram *p) { return HtLowerNode(p,p->root); }
