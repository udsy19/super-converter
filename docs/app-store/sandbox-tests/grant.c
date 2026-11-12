// Grant-inheritance experiment (test-results.md §3). `issue` (unsandboxed) issues a read-write sandbox extension for a
// file, as powerbox does for an open panel; `grant` (sandboxed, main executable of P.app whose Contents/Helpers/ffprobe is
// signed app-sandbox + inherit) consumes it, opens the file itself, then spawns the child on the same file.
//   int main(int c,char**v){char*t=sandbox_extension_issue_file("com.apple.app-sandbox.read-write",v[1],0);printf("%s",t);}  // issue.c
#include <stdio.h>
#include <stdint.h>
#include <spawn.h>
#include <sys/wait.h>
#include <fcntl.h>
#include <unistd.h>
extern char **environ;
extern int64_t sandbox_extension_consume(const char *token);
int main(int c, char **v) {
  printf("consume=%lld\n", (long long)sandbox_extension_consume(v[1]));
  int fd = open(v[2], O_RDONLY); printf("parent open=%s\n", fd >= 0 ? "ok" : "DENIED"); if (fd >= 0) close(fd);
  pid_t pid; int st;
  if (posix_spawn(&pid, v[3], NULL, NULL, &v[3], environ) != 0) { perror("spawn"); return 1; }
  waitpid(pid, &st, 0); printf("child exit=%d\n", WEXITSTATUS(st));
  return 0;
}
