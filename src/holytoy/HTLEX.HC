//HolyToy guest GLSL lexer. ASCII source only; all storage belongs to one
//compile attempt and is released by HtLexDel.

#define HT_TOK_EOF       0
#define HT_TOK_IDENT     1
#define HT_TOK_NUMBER    2
#define HT_TOK_OP        3

class CHtToken
{
  I64 kind,start,len,line,col;
};

class CHtLexer
{
  U8 *src;
  I64 src_len,pos,line,col,count,cap;
  CHtToken *tok;
  U8 error[160];
};

Bool HtIsAlpha(U8 ch)
{
  return ch=='_' || 'a'<=ch<='z' || 'A'<=ch<='Z';
}

Bool HtIsDigit(U8 ch)
{
  return '0'<=ch<='9';
}

Bool HtIsHex(U8 ch)
{
  return HtIsDigit(ch) || 'a'<=ch<='f' || 'A'<=ch<='F';
}

U0 HtLexDel(CHtLexer *l)
{
  Free(l->tok);
  l->tok=NULL;
  l->count=0;
  l->cap=0;
}

U0 HtLexError(CHtLexer *l,I64 line,I64 col,U8 *msg)
{
  StrPrint(l->error,"line %d:%d: %s",line,col,msg);
}

U0 HtLexBump(CHtLexer *l)
{
  if (l->src[l->pos]=='\n') {
    l->pos++;
    l->line++;
    l->col=1;
  } else {
    l->pos++;
    l->col++;
  }
}

CHtToken *HtLexToken(CHtLexer *l,I64 kind,I64 start,I64 line,I64 col)
{
  CHtToken *t;
  if (l->count>=l->cap) {
    HtLexError(l,line,col,"internal token capacity");
    return NULL;
  }
  t=&l->tok[l->count++];
  t->kind=kind;
  t->start=start;
  t->len=l->pos-start;
  t->line=line;
  t->col=col;
  return t;
}

Bool HtLexNumber(CHtLexer *l)
{
  I64 start=l->pos,line=l->line,col=l->col;
  Bool saw_digit=FALSE;
  if (l->src[l->pos]=='0' &&
      (l->src[l->pos+1]=='x' || l->src[l->pos+1]=='X')) {
    HtLexBump(l);
    HtLexBump(l);
    if (!HtIsHex(l->src[l->pos])) {
      HtLexError(l,line,col,"expected hexadecimal digit");
      return FALSE;
    }
    while (HtIsHex(l->src[l->pos])) HtLexBump(l);
    if (l->src[l->pos]=='u' || l->src[l->pos]=='U') HtLexBump(l);
    return HtLexToken(l,HT_TOK_NUMBER,start,line,col)!=NULL;
  }
  while (HtIsDigit(l->src[l->pos])) {
    saw_digit=TRUE;
    HtLexBump(l);
  }
  if (l->src[l->pos]=='.') {
    HtLexBump(l);
    while (HtIsDigit(l->src[l->pos])) {
      saw_digit=TRUE;
      HtLexBump(l);
    }
  }
  if (!saw_digit) {
    HtLexError(l,line,col,"expected digit");
    return FALSE;
  }
  if (l->src[l->pos]=='e' || l->src[l->pos]=='E') {
    HtLexBump(l);
    if (l->src[l->pos]=='+' || l->src[l->pos]=='-') HtLexBump(l);
    if (!HtIsDigit(l->src[l->pos])) {
      HtLexError(l,line,col,"expected exponent digit");
      return FALSE;
    }
    while (HtIsDigit(l->src[l->pos])) HtLexBump(l);
  }
  //GLSL permits a floating suffix. HolyC does not, so the emitter removes it.
  if (l->src[l->pos]=='f' || l->src[l->pos]=='F' ||
      l->src[l->pos]=='u' || l->src[l->pos]=='U')
    HtLexBump(l);
  return HtLexToken(l,HT_TOK_NUMBER,start,line,col)!=NULL;
}

Bool HtLex(CHtLexer *l,U8 *src)
{
  I64 start,line,col,n;
  I64 ch;
  MemSet(l,0,sizeof(CHtLexer));
  l->src=src;
  l->src_len=StrLen(src);
  l->line=1;
  l->col=1;
  //No valid token is empty, so source bytes + EOF is a strict upper bound.
  l->cap=l->src_len+2;
  l->tok=CAlloc(l->cap*sizeof(CHtToken));
  while (l->pos<l->src_len) {
    ch=src[l->pos];
    if (ch==' ' || ch=='\t' || ch=='\r' || ch=='\n') {
      HtLexBump(l);
    } else if (ch=='/' && src[l->pos+1]=='/') {
      HtLexBump(l);
      HtLexBump(l);
      while (l->pos<l->src_len && src[l->pos]!='\n') HtLexBump(l);
    } else if (ch=='/' && src[l->pos+1]=='*') {
      line=l->line;
      col=l->col;
      HtLexBump(l);
      HtLexBump(l);
      while (l->pos<l->src_len &&
             !(src[l->pos]=='*' && src[l->pos+1]=='/'))
        HtLexBump(l);
      if (l->pos>=l->src_len) {
        HtLexError(l,line,col,"unterminated block comment");
        HtLexDel(l);
        return FALSE;
      }
      HtLexBump(l);
      HtLexBump(l);
    } else if (HtIsAlpha(ch)) {
      start=l->pos;
      line=l->line;
      col=l->col;
      HtLexBump(l);
      while (HtIsAlpha(src[l->pos]) || HtIsDigit(src[l->pos])) HtLexBump(l);
      if (!HtLexToken(l,HT_TOK_IDENT,start,line,col)) {
        HtLexDel(l);
        return FALSE;
      }
    } else if (HtIsDigit(ch) || ch=='.' && HtIsDigit(src[l->pos+1])) {
      if (!HtLexNumber(l)) {
        HtLexDel(l);
        return FALSE;
      }
    } else {
      start=l->pos;
      line=l->line;
      col=l->col;
      //Longest match first for every common multi-character GLSL operator.
      n=1;
      if ((!StrNCmp(src+l->pos,"<<=",3)) ||
          (!StrNCmp(src+l->pos,">>=",3)))
        n=3;
      else if ((!StrNCmp(src+l->pos,"++",2)) ||
               (!StrNCmp(src+l->pos,"--",2)) ||
               (!StrNCmp(src+l->pos,"+=",2)) ||
               (!StrNCmp(src+l->pos,"-=",2)) ||
               (!StrNCmp(src+l->pos,"*=",2)) ||
               (!StrNCmp(src+l->pos,"/=",2)) ||
               (!StrNCmp(src+l->pos,"%=",2)) ||
               (!StrNCmp(src+l->pos,"&=",2)) ||
               (!StrNCmp(src+l->pos,"|=",2)) ||
               (!StrNCmp(src+l->pos,"^=",2)) ||
               (!StrNCmp(src+l->pos,"==",2)) ||
               (!StrNCmp(src+l->pos,"!=",2)) ||
               (!StrNCmp(src+l->pos,"<=",2)) ||
               (!StrNCmp(src+l->pos,">=",2)) ||
               (!StrNCmp(src+l->pos,"&&",2)) ||
               (!StrNCmp(src+l->pos,"||",2)) ||
               (!StrNCmp(src+l->pos,"^^",2)) ||
               (!StrNCmp(src+l->pos,"<<",2)) ||
               (!StrNCmp(src+l->pos,">>",2)))
        n=2;
      while (n--) HtLexBump(l);
      if (!HtLexToken(l,HT_TOK_OP,start,line,col)) {
        HtLexDel(l);
        return FALSE;
      }
    }
  }
  start=l->pos;
  if (!HtLexToken(l,HT_TOK_EOF,start,l->line,l->col)) {
    HtLexDel(l);
    return FALSE;
  }
  return TRUE;
}

Bool HtTokEq(CHtLexer *l,I64 i,U8 *s)
{
  I64 n=StrLen(s);
  if (i<0 || i>=l->count) return FALSE;
  return l->tok[i].len==n && !StrNCmp(l->src+l->tok[i].start,s,n);
}

Bool HtTokSame(CHtLexer *l,I64 a,I64 b)
{
  CHtToken *x=&l->tok[a],*y=&l->tok[b];
  return x->len==y->len && !StrNCmp(l->src+x->start,l->src+y->start,x->len);
}

U0 HtTokText(CHtLexer *l,I64 i,U8 *buf,I64 buf_len)
{//Copy token text into a fixed buffer, truncating safely.
  I64 n=l->tok[i].len;
  if (n>buf_len-1) n=buf_len-1;
  MemCpy(buf,l->src+l->tok[i].start,n);
  buf[n]=0;
}
