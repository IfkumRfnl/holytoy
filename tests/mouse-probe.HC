//Mouse-injection probe (plan 006): prints MOUSE READY on the fullscreen
//task doc (visible to tools/scrtext.py in the rolling frames), then samples
//the TempleOS mouse state for ~15 s while the host drives QMP
//input-send-event (tools/qmp.py mouse-to / mouse-btn), and reports the
//final position plus whether a left-button press was ever seen.
//Marker style matches src/holytoy/HT.HC HtSelfTest.
U0 MouseProbe()
{
  I64 i;
  Bool lb_seen=FALSE;
  "MOUSE READY\n";
  for (i=0;i<50;i++) {
    Sleep(300);
    lb_seen|=ms.lb;
  }
  "MOUSE FINAL %d %d %d\n",ms.pos.x,ms.pos.y,lb_seen;
}

MouseProbe;
