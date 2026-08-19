/* landlock-exec — confine a child before exec (mediated launch contract §2.1).
 *
 * Installs a Landlock ruleset and execs. The restriction is therefore in place BEFORE the
 * foreign code runs, and a Landlock ruleset cannot be revoked by the restricted process —
 * the two properties §2.1 relies on. This is explicitly NOT self-sandboxing by the party
 * being constrained.
 *
 *   LL_RO=colon:separated:paths   read + execute
 *   LL_RW=colon:separated:paths   full filesystem rights
 *
 * Everything not listed is DENIED (allowlist, not blocklist). Network access is deliberately
 * left unhandled: handling the net rights without granting any would deny every connect.
 *
 * The caller decides the paths, and per the wire-format spec they are derived from the
 * REGISTRY, never from the request — a cage whose bars the prisoner chooses is not a cage.
 *
 * Built at install time, not shipped as a binary: an architecture- and libc-specific blob
 * asks for trust in a build nobody can reproduce, in a repository whose purpose is the
 * opposite. See docs/CONFINEMENT.md.
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
#include <linux/types.h>

struct rs_attr { __u64 handled_access_fs; __u64 handled_access_net; __u64 scoped; };
struct pb_attr { __u64 allowed_access; __s32 parent_fd; } __attribute__((packed));

#define A_EXECUTE   (1ULL<<0)
#define A_WRITE     (1ULL<<1)
#define A_READ_FILE (1ULL<<2)
#define A_READ_DIR  (1ULL<<3)
#define A_IOCTL_DEV (1ULL<<15)

static long ll_create(struct rs_attr *a, size_t s, __u32 f){ return syscall(444,a,s,f); }
static long ll_add(int fd,int t,const void*a,__u32 f){ return syscall(445,fd,t,a,f); }
static long ll_self(int fd,__u32 f){ return syscall(446,fd,f); }

static int add_path(int rs, const char *p, __u64 rights){
  int fd = open(p, O_PATH|O_CLOEXEC);
  if (fd < 0) { fprintf(stderr,"landlock-exec: open %s: %s\n",p,strerror(errno)); return -1; }
  struct pb_attr pb = { .allowed_access = rights, .parent_fd = fd };
  int r = ll_add(rs, 1 /*LANDLOCK_RULE_PATH_BENEATH*/, &pb, 0);
  if (r) fprintf(stderr,"landlock-exec: add_rule %s: %s\n",p,strerror(errno));
  close(fd);
  return r;
}
static int add_list(int rs, const char *env, __u64 rights){
  const char *v = getenv(env); if (!v || !*v) return 0;
  char *d = strdup(v), *save=NULL;
  for (char *t = strtok_r(d,":",&save); t; t = strtok_r(NULL,":",&save))
    if (*t && add_path(rs,t,rights)) { free(d); return -1; }
  free(d); return 0;
}

int main(int argc, char **argv){
  if (argc < 2){ fprintf(stderr,"usage: landlock-exec CMD [ARGS...]\n"); return 2; }
  int abi = ll_create(NULL,0,1 /*VERSION*/);
  if (abi < 1){ fprintf(stderr,"landlock-exec: unavailable (%s)\n",strerror(errno)); return 3; }

  __u64 all = (1ULL<<13)-1;              /* ABI1: EXECUTE..MAKE_SYM */
  if (abi >= 2) all |= (1ULL<<13);       /* REFER    */
  if (abi >= 3) all |= (1ULL<<14);       /* TRUNCATE */
  if (abi >= 5) all |= A_IOCTL_DEV;      /* IOCTL_DEV*/
  __u64 ro = A_EXECUTE|A_READ_FILE|A_READ_DIR|(abi>=5?A_IOCTL_DEV:0);

  struct rs_attr a = { .handled_access_fs = all, .handled_access_net = 0, .scoped = 0 };
  int rs = ll_create(&a,sizeof(a),0);
  if (rs < 0){ fprintf(stderr,"landlock-exec: create: %s\n",strerror(errno)); return 3; }
  if (add_list(rs,"LL_RO",ro) || add_list(rs,"LL_RW",all)) return 3;
  if (prctl(PR_SET_NO_NEW_PRIVS,1,0,0,0)){ perror("no_new_privs"); return 3; }
  if (ll_self(rs,0)){ fprintf(stderr,"landlock-exec: restrict_self: %s\n",strerror(errno)); return 3; }
  close(rs);
  fprintf(stderr,"landlock-exec: confined (ABI %d)\n",abi);
  execvp(argv[1],&argv[1]);
  fprintf(stderr,"landlock-exec: exec %s: %s\n",argv[1],strerror(errno));
  return 127;
}
