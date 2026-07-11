//holytoy boot hook — installed as C:/Home/Once.HC on the golden image.
//Source of truth: this file (guest/ONCE.HC); tools/install_os.sh copies it in.
//User terminal 1 #includes ~/Once.HC at every boot (see ~/HomeSys.HC
//StartUpTasks), so this runs on each VM start.
//
//It mounts the FAT32 transfer disk (QEMU primary-slave, next free ATA
//letter = E) and executes its payload. With no payload present it drops
//back to the normal desktop.
try {
  if (ATAMount('E',BDT_ATA,0x1F0,0x3F6,1) && FileFind("E:/RUN.HC"))
    ExeFile("E:/RUN.HC");
} catch {
  PutExcept;
}
