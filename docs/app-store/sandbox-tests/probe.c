// Sandbox probe (docs/app-store/test-results.md §2). Build and run:
//   clang -o probe probe.c -Wl,-sectcreate,__TEXT,__info_plist,Info.plist   (Info.plist: CFBundleIdentifier com.udsy.superconverter.probe)
//   codesign -f -s - -i com.udsy.superconverter.probe --entitlements ent.plist probe   (app-sandbox, user-selected.read-write, downloads.read-write)
//   ./probe ~/Desktop ~/Downloads <container>/tree.dmg <container>/mnt
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <spawn.h>
#include <sys/wait.h>
extern char **environ;
static int run(char *const argv[]) {
  pid_t pid; int st;
  if (posix_spawn(&pid, argv[0], NULL, NULL, argv, environ) != 0) { perror("spawn"); return -1; }
  waitpid(pid, &st, 0); return WIFEXITED(st) ? WEXITSTATUS(st) : 128;
}
int main(int argc, char **argv) {
  printf("HOME=%s TMPDIR=%s\n", getenv("HOME"), getenv("TMPDIR"));
  char *a1[] = {"/usr/bin/sandbox-exec", "-p", "(version 1)(allow default)", "/usr/bin/true", NULL};
  printf("sandbox-exec exit=%d\n", run(a1));
  printf("access(W_OK,%s)=%d\n", argv[1], access(argv[1], W_OK));
  printf("access(W_OK,%s)=%d\n", argv[2], access(argv[2], W_OK));
  char *a3[] = {"/usr/bin/pluginkit", "-m", "-i", "com.apple.share.Mail.compose", NULL};
  printf("pluginkit exit=%d\n", run(a3));
  if (argc > 4) {
    char *a4[] = {"/usr/bin/hdiutil", "attach", "-readonly", "-nobrowse", "-noverify", "-noautoopen", "-mountrandom", argv[4], "-plist", argv[3], NULL};
    printf("hdiutil exit=%d\n", run(a4));
  }
  return 0;
}
