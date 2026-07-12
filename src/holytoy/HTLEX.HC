//HolyToy guest GLSL lexer. ASCII source only; no host runtime dependency.

#define HT_TOK_EOF	0
#define HT_TOK_IDENT	1
#define HT_TOK_NUMBER	2
#define HT_TOK_PUNCT	3
#define HT_TOK_MAX	128

class CHtToken { I64 kind,start,len,line; U8 punct; };
class CHtLexer
{
  U8 *src;
  I64 pos,line,count;
  CHtToken tok[HT_TOK_MAX];
  U8 error[96];
};

Bool HtIsAlpha(U8 ch) { return ch=='_' || 'a'<=ch<='z' || 'A'<=ch<='Z'; }
Bool HtIsDigit(U8 ch) { return '0'<=ch<='9'; }

Bool HtLex(CHtLexer *l,U8 *src)
{
  I64 p=0,n=0,line=1,start;
  U8 ch;
  MemSet(l,0,sizeof(CHtLexer));
  l->src=src;
  while (src[p]) {
    ch=src[p];
    if (ch==' ' || ch=='\t' || ch=='\r') { p++; }
    else if (ch=='\n') { line++; p++; }
    else if (ch=='/' && src[p+1]=='/') {
      p+=2; while (src[p] && src[p]!='\n') p++;
    } else {
      if (n>=HT_TOK_MAX-1) {
        StrPrint(l->error,"line %d: token limit",line); return FALSE;
      }
      start=p;
      l->tok[n].start=start; l->tok[n].line=line;
      if (HtIsAlpha(ch)) {
        p++; while (HtIsAlpha(src[p]) || HtIsDigit(src[p])) p++;
        l->tok[n].kind=HT_TOK_IDENT;
      } else if (HtIsDigit(ch) || ch=='.' && HtIsDigit(src[p+1])) {
        p++; while (HtIsDigit(src[p]) || src[p]=='.') p++;
        l->tok[n].kind=HT_TOK_NUMBER;
      } else {
        p++; l->tok[n].kind=HT_TOK_PUNCT; l->tok[n].punct=ch;
      }
      l->tok[n].len=p-start; n++;
    }
  }
  l->tok[n].kind=HT_TOK_EOF; l->tok[n].line=line;
  l->count=n+1;
  return TRUE;
}

Bool HtTokEq(CHtLexer *l,I64 i,U8 *s)
{
  I64 n=StrLen(s);
  return l->tok[i].len==n && !StrNCmp(l->src+l->tok[i].start,s,n);
}
