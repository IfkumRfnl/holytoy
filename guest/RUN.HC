//holytoy guest runner — refreshed onto the transfer disk every run by
//tools/mkxfer.sh, executed by the Once.HC boot hook.
//
//Protocol (all files on E:, single-dot UPPERCASE names — two dots would
//trigger TempleOS .Z auto-compression, see Kernel/BlkDev/DskStrA.HC IsDotZ):
//  reads   E:/MAIN.HC   user source (absent => "OK NOSRC")
//          E:/GUI.TXT   marker: interactive session, never reboot
//  writes  E:/STAT.TXT  "OK" | "ERR" | "OK NOSRC"
//          E:/LOG.TXT   dump of this task's Doc — includes compiler errors
//  then    holds the picture HT_SHOW_MS for the host screenshot, Reboot
//          (host runs QEMU with -no-reboot, so Reboot = clean VM exit).
//
//ExeFile2 (not ExeFile) is essential: ExeFile swallows 'Compiler'
//exceptions internally (Compiler/CMain.HC:589), ExeFile2 lets them reach
//our catch{}.

#define HT_SHOW_MS	4000

U0 HtReport(U8 *stat)
{
  U8 *dump;
  I64 sz;
  FileWrite("E:/STAT.TXT",stat,StrLen(stat));
  dump=DocSave(DocPut,&sz);
  if (dump) {
    FileWrite("E:/LOG.TXT",dump,sz);
    Free(dump);
  }
}

U0 HtRun()
{
  Bool gui=FileFind("E:/GUI.TXT"),ok=FALSE;
  I64 ec;
  U8 ecs[9];
  if (!FileFind("E:/MAIN.HC")) {
    HtReport("OK NOSRC");
    if (!gui) {
      Sleep(1000);
      Reboot;
    }
    return;
  }
  //Compile errors before RLf_ADAM_SERVER drop into the interactive
  //debugger instead of throwing (Compiler/CExcept.HC LexExcept), and this
  //hook runs early in boot — so wait for the run level before compiling.
  while (!Bt(&sys_run_level,RLf_ADAM_SERVER))
    Sleep(100);
  SettingsPush;
  WinBorder(OFF);
  WinMax;
  DocClear;
  DCFill;
  try {
    ExeFile2("E:/MAIN.HC");
    ok=TRUE;
  } catch {
    Fs->catch_except=TRUE;
    ec=Fs->except_ch;
    MemCpy(ecs,&ec,8);
    ecs[8]=0;
    "\nHOLYTOY EXCEPT [%s]\n",ecs;
  }
  if (ok)
    HtReport("OK");
  else
    HtReport("ERR");
  WinToTop;    //cover the AutoComplete standby popup for the screenshot
  if (!gui) {
    Sleep(HT_SHOW_MS);
    Reboot;
  }
}

HtRun;
