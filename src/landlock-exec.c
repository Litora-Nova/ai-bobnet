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
 *
 *   LL_STATUS_FD=<n>   exec-status channel (slice 3, docs/CONFINEMENT.md).
 *
 * execvp() never returns on success, so no exit code from THIS process is ever available
 * to the caller to distinguish "confinement was never attempted" from "the confined
 * provider itself exited 3, 127 or any other number" once exec has handed off — the
 * child owns the whole exit-code space after that point. LL_STATUS_FD is the caller's
 * side channel for that distinction: if it names an open fd, this process marks it
 * CLOEXEC FIRST (fcntl, before any Landlock work), then writes ONE line naming the
 * reason to it on every failure path that returns before a successful execvp — ruleset
 * create/add-rule/no_new_privs/restrict_self, and execvp itself failing. On a
 * successful execvp the fd is still open at that instant, but CLOEXEC means the kernel
 * closes it as part of that very exec, before the replacement image's first
 * instruction runs — the caller reads it only AFTER the child ends, and empty then
 * means exec succeeded (the wait status is the provider's own). The fd is deliberately
 * unset before a successful execvp too (belt and suspenders alongside CLOEXEC: a
 * provider that somehow inherited it across an exec that failed to honour CLOEXEC must
 * still not find it) — see status_close() below.
 *
 *   LL_STDERR_FD=<n>   provider-stderr relay channel (gate delta D2, Ikarus, HIGH).
 *
 * The contract's minimum ("read access to the credential directory only as far as the
 * adapter needs") says nothing about the PROVIDER's own stderr, and it must reach the
 * caller like stdout does — but this process's OWN stderr (the fprintf diagnostics
 * above, every one of them) must stay on the journal, never the caller's stream
 * (docs/CONFINEMENT.md, "Diagnostics go to the broker's journal, never the caller's
 * stream"). This process dup2()s LL_STDERR_FD onto fd 2 before execvp, after every
 * diagnostic printed ABOVE this point — but execvp can still fail AFTER the redirect
 * (gate delta 2, Riker HIGH / Ikarus MEDIUM: the ONE diagnostic this process can still
 * emit past that point is execvp's own failure, and "doing the redirect last" put fd 2
 * already aliasing the caller's relay by then, so that one diagnostic — including the
 * adapter's absolute path — leaked onto the wire instead of the journal). Fixed by
 * saving the ORIGINAL fd 2 with dup() (CLOEXEC'd, so a successful exec still closes it
 * same as everything else) before the redirect: the post-execvp diagnostic always goes
 * to that saved journal fd, never to fd 2, so it reaches the journal whether execvp
 * succeeds or fails. LL_STATUS_FD (unaffected by any of this) is still the caller's
 * PRIMARY signal that exec failed; the saved-fd diagnostic is belt-and-suspenders for
 * the journal, matching every earlier failure path's fprintf.
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <grp.h>
#include <limits.h>
#include <unistd.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <linux/capability.h>
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

/* status_fd: -1 if LL_STATUS_FD was absent/unparsable — every status_fail() call below
 * then becomes a silent no-op, so a caller that does not use the channel sees exactly
 * the pre-slice-3 behaviour (stderr only). */
static int status_fd = -1;

static void status_init(void){
  const char *v = getenv("LL_STATUS_FD");
  if (!v || !*v) return;
  char *end = NULL;
  long n = strtol(v, &end, 10);
  if (!end || *end || n < 0 || n > 65535) return; /* malformed: treat as absent, fail-closed on stderr only */
  status_fd = (int)n;
  /* CLOEXEC set HERE, by the helper, not assumed from the caller (docs/CONFINEMENT.md,
   * D-A2): this is what makes a later successful execvp() close the fd automatically,
   * while it stays open in THIS process for every failure path below. */
  if (fcntl(status_fd, F_SETFD, FD_CLOEXEC) < 0) status_fd = -1;
}

/* One line, no trailing content beyond the newline this always appends — the caller
 * reads the whole fd after the child ends and only cares whether it is empty. */
static void status_fail(const char *reason){
  if (status_fd < 0) return;
  size_t len = strlen(reason);
  ssize_t off = 0;
  while ((size_t)off < len) {
    ssize_t w = write(status_fd, reason + off, len - off);
    if (w <= 0) return; /* best-effort: stderr already has the same reason */
    off += w;
  }
  (void)write(status_fd, "\n", 1);
}

static int decimal_id(const char *text, unsigned long *value){
  if (!text || !*text) return -1;
  for (const unsigned char *p = (const unsigned char *)text; *p; ++p)
    if (*p < '0' || *p > '9') return -1;
  errno = 0;
  char *end = NULL;
  unsigned long parsed = strtoul(text, &end, 10);
  if (errno || !end || *end || parsed > UINT_MAX) return -1;
  *value = parsed;
  return 0;
}

static int group_list(const char *text, gid_t **groups, size_t *count){
  if (!text || !*text) return -1;
  size_t n = 1;
  for (const char *p = text; *p; ++p) if (*p == ',') ++n;
  gid_t *parsed = calloc(n, sizeof(*parsed));
  if (!parsed) return -1;
  const char *p = text;
  for (size_t i = 0; i < n; ++i){
    unsigned long value = 0;
    const char *start = p;
    while (*p >= '0' && *p <= '9'){
      unsigned int digit = (unsigned int)(*p - '0');
      if (value > (UINT_MAX - digit) / 10){ free(parsed); return -1; }
      value = value * 10 + digit;
      ++p;
    }
    if (p == start || (*p && *p != ',') || (unsigned long)(gid_t)value != value){
      free(parsed);
      return -1;
    }
    parsed[i] = (gid_t)value;
    if (!*p){
      if (i + 1 != n){ free(parsed); return -1; }
      break;
    }
    ++p;
    if (!*p){ free(parsed); return -1; }
  }
  *groups = parsed;
  *count = n;
  return 0;
}

static int uid_allowed(uid_t uid){
  const char *raw = getenv("AIB_ROLE_UIDS");
  if (!raw || !*raw) return 0;
  char *copy = strdup(raw), *save = NULL;
  if (!copy) return 0;
  int allowed = 0;
  for (char *part = strtok_r(copy, ",", &save); part; part = strtok_r(NULL, ",", &save)){
    unsigned long value = 0;
    if (!decimal_id(part, &value) && (uid_t)value == uid){ allowed = 1; break; }
  }
  free(copy);
  return allowed;
}

static int group_allowed(gid_t gid){
  gid_t *allowed_groups = NULL;
  size_t allowed_count = 0;
  if (group_list(getenv("AIB_ROLE_GROUPS"), &allowed_groups, &allowed_count)) return 0;
  int allowed = 0;
  for (size_t i = 0; i < allowed_count; ++i){
    if (allowed_groups[i] == gid){ allowed = 1; break; }
  }
  free(allowed_groups);
  return allowed;
}

static int shared_group_gid(gid_t *gid){
  struct group *shared = getgrnam("aib-shared");
  if (shared){ *gid = shared->gr_gid; return 1; }
  /* Pure policy specs compile a synthetic gid into their throwaway helper.
   * Production builds have no runtime switch that can replace this identity. */
#ifdef AIB_TEST_SHARED_GID
  if ((unsigned long)(gid_t)AIB_TEST_SHARED_GID == (unsigned long)AIB_TEST_SHARED_GID &&
      AIB_TEST_SHARED_GID != 0){
    *gid = (gid_t)AIB_TEST_SHARED_GID;
    return 1;
  }
#endif
  return -1;
}

static int role_refuse(const char *message){
  fprintf(stderr, "landlock-exec: %s\n", message);
  char status[256];
  snprintf(status, sizeof(status), "confine: %s", message);
  status_fail(status);
  return 3;
}

static int runtime_last_cap(void){
  int fd = open("/proc/sys/kernel/cap_last_cap", O_RDONLY | O_CLOEXEC);
  if (fd < 0) return -1;
  char raw[32] = {0};
  ssize_t length = read(fd, raw, sizeof(raw) - 1);
  close(fd);
  if (length <= 0) return -1;
  char *end = NULL;
  errno = 0;
  long value = strtol(raw, &end, 10);
  while (end && (*end == '\n' || *end == '\r')) ++end;
  if (errno || !end || *end || value < 0 || value > INT_MAX) return -1;
  return (int)value;
}

static int drop_capability_bounding_set(int last_cap){
  int saw_eperm = 0, saw_other_failure = 0;
  for (int cap = 0; cap <= last_cap; ++cap){
    if (!prctl(PR_CAPBSET_DROP, cap, 0, 0, 0)) continue;
    if (errno == EPERM) saw_eperm = 1;
    else saw_other_failure = 1;
  }
  if (saw_other_failure) return -1;
  return saw_eperm;
}

static int clear_capabilities(void){
  if (prctl(PR_CAP_AMBIENT, PR_CAP_AMBIENT_CLEAR_ALL, 0, 0, 0)) return -1;
  struct __user_cap_header_struct header = {
    .version = _LINUX_CAPABILITY_VERSION_3,
    .pid = 0,
  };
  struct __user_cap_data_struct data[2] = {{0}};
  return (int)syscall(SYS_capset, &header, data);
}

static int unprivileged_state_verified(int last_cap){
  if (prctl(PR_GET_NO_NEW_PRIVS, 0, 0, 0, 0) != 1) return 0;
  struct __user_cap_header_struct header = {
    .version = _LINUX_CAPABILITY_VERSION_3,
    .pid = 0,
  };
  struct __user_cap_data_struct data[2] = {{0}};
  if (syscall(SYS_capget, &header, data)) return 0;
  for (size_t i = 0; i < sizeof(data) / sizeof(data[0]); ++i)
    if (data[i].permitted || data[i].effective || data[i].inheritable) return 0;
  for (int cap = 0; cap <= last_cap; ++cap)
    if (prctl(PR_CAP_AMBIENT, PR_CAP_AMBIENT_IS_SET, cap, 0, 0) != 0) return 0;
  return 1;
}

int main(int argc, char **argv){
  status_init();
  if (argc < 2){
    fprintf(stderr,"usage: landlock-exec CMD [ARGS...]\n");
    status_fail("confine: usage: landlock-exec CMD [ARGS...]");
    return 2;
  }
  int argi = 1, saw_uid = 0, saw_gid = 0, saw_groups = 0, role_switch = 0;
  unsigned long uid_value = 0, gid_value = 0;
  gid_t *groups = NULL;
  size_t group_count = 0;
  while (argi < argc && (!strcmp(argv[argi], "--uid") || !strcmp(argv[argi], "--gid") ||
                         !strcmp(argv[argi], "--groups"))){
    if (!strcmp(argv[argi], "--groups")){
      if (argi + 1 >= argc || saw_groups || !saw_uid || !saw_gid ||
          group_list(argv[argi + 1], &groups, &group_count)){
        fprintf(stderr, "usage: landlock-exec [--uid N --gid N [--groups G,...]] CMD [ARGS...]\n");
        status_fail("confine: usage: invalid supplementary group switch");
        return 2;
      }
      saw_groups = 1;
      argi += 2;
      continue;
    }
    int is_uid = !strcmp(argv[argi], "--uid");
    if (argi + 1 >= argc || saw_groups || (is_uid ? saw_uid : saw_gid) ||
        decimal_id(argv[argi + 1], is_uid ? &uid_value : &gid_value)){
      fprintf(stderr, "usage: landlock-exec [--uid N --gid N [--groups G,...]] CMD [ARGS...]\n");
      status_fail("confine: usage: invalid uid/gid switch");
      return 2;
    }
    if (is_uid) saw_uid = 1; else saw_gid = 1;
    argi += 2;
  }
  if (saw_uid != saw_gid || argi >= argc){
    fprintf(stderr, "usage: landlock-exec [--uid N --gid N [--groups G,...]] CMD [ARGS...]\n");
    status_fail("confine: usage: uid and gid must be supplied together");
    return 2;
  }
  role_switch = saw_uid && saw_gid;
  if (role_switch){
    if (uid_value == 0) return role_refuse("uid 0 is never an allowed role uid");
    if (uid_value < 1000) return role_refuse("uid below 1000 is never an allowed role uid");
    if (gid_value == 0) return role_refuse("gid 0 is refused for a role uid");
    if (!uid_allowed((uid_t)uid_value)) return role_refuse("uid is not present in AIB_ROLE_UIDS");
    gid_t forbidden_group = 0;
    int has_forbidden_group = shared_group_gid(&forbidden_group);
    if (has_forbidden_group < 0)
      return role_refuse("confinement_unavailable: cannot resolve the aib-shared group");
    if (has_forbidden_group && (gid_t)gid_value == forbidden_group)
      return role_refuse("aib-shared is forbidden as the confined primary group");
    for (size_t i = 0; i < group_count; ++i){
      if (groups[i] == 0) return role_refuse("supplementary group 0 is never allowed");
      if (!group_allowed(groups[i])) return role_refuse("supplementary group is not present in AIB_ROLE_GROUPS");
      if (has_forbidden_group && groups[i] == forbidden_group)
        return role_refuse("aib-shared is forbidden in confined supplementary groups");
    }
  }
  /* Reserve the journal channel before Landlock work. Descriptor failures
   * remain distinguishable even when this host cannot install a ruleset.
   * Only preparation moves: provider stderr is redirected after confinement. */
  int journal_fd = 2, relay_fd = -1;
  { const char *v = getenv("LL_STDERR_FD");
    if (v && *v){
      char *end = NULL; long n = strtol(v,&end,10);
      if (end && !*end && n >= 0 && n <= 65535){
        /* Never redirect without a saved, CLOEXEC journal descriptor: an exec
         * failure would leak diagnostics to the relay, or a successful exec
         * would inherit the journal. Both preparation failures refuse exec. */
        int saved = dup(2);
        if (saved < 0){
          fprintf(stderr,"landlock-exec: dup 2 (journal fd): %s\n",strerror(errno));
          status_fail("confine: dup(2) failed");
          return 3;
        }
        if (fcntl(saved, F_SETFD, FD_CLOEXEC) < 0){
          fprintf(stderr,"landlock-exec: fcntl FD_CLOEXEC (journal fd): %s\n",strerror(errno));
          close(saved);
          status_fail("confine: fcntl FD_CLOEXEC (journal fd) failed");
          return 3;
        }
        journal_fd = saved;
        relay_fd = (int)n;
      }
    }
  }
  int abi = ll_create(NULL,0,1 /*VERSION*/);
  if (abi < 1){
    fprintf(stderr,"landlock-exec: unavailable (%s)\n",strerror(errno));
    status_fail("confine: landlock unavailable");
    return 3;
  }

  __u64 all = (1ULL<<13)-1;              /* ABI1: EXECUTE..MAKE_SYM */
  if (abi >= 2) all |= (1ULL<<13);       /* REFER    */
  if (abi >= 3) all |= (1ULL<<14);       /* TRUNCATE */
  if (abi >= 5) all |= A_IOCTL_DEV;      /* IOCTL_DEV*/
  __u64 ro = A_EXECUTE|A_READ_FILE|A_READ_DIR|(abi>=5?A_IOCTL_DEV:0);

  struct rs_attr a = { .handled_access_fs = all, .handled_access_net = 0, .scoped = 0 };
  int rs = ll_create(&a,sizeof(a),0);
  if (rs < 0){
    fprintf(stderr,"landlock-exec: create: %s\n",strerror(errno));
    status_fail("confine: ruleset create failed");
    return 3;
  }
  if (add_list(rs,"LL_RO",ro) || add_list(rs,"LL_RW",all)){
    status_fail("confine: add-rule failed (see journal for the path)");
    return 3;
  }
  if (prctl(PR_SET_NO_NEW_PRIVS,1,0,0,0)){
    perror("no_new_privs");
    status_fail("confine: no_new_privs failed");
    return 3;
  }
  if (ll_self(rs,0)){
    fprintf(stderr,"landlock-exec: restrict_self: %s\n",strerror(errno));
    status_fail("confine: restrict_self failed");
    return 3;
  }
  close(rs);
  if (role_switch){
    int last_cap = runtime_last_cap();
    if (last_cap < 0) return role_refuse("uid switch could not read the kernel capability range");
    int bounding_drop = drop_capability_bounding_set(last_cap);
    if (bounding_drop < 0) return role_refuse("uid switch could not clear the capability bounding set");
    if (setgroups(group_count, groups) &&
        !(group_count == 0 && errno == EPERM && getuid() == (uid_t)uid_value && getgid() == (gid_t)gid_value))
      return role_refuse("uid switch could not set supplementary groups");
    if (setgid((gid_t)gid_value)) return role_refuse("uid switch setgid failed");
    if (setuid((uid_t)uid_value)) return role_refuse("uid switch setuid failed");
    if (clear_capabilities()) return role_refuse("uid switch could not clear capabilities");
    if (bounding_drop > 0 && !unprivileged_state_verified(last_cap))
      return role_refuse("uid switch could not verify cleared capabilities after bounding-set EPERM");
  }
  fprintf(stderr,"landlock-exec: confined (ABI %d)\n",abi);
  if (relay_fd >= 0 && dup2(relay_fd,2) < 0)
    fprintf(stderr,"landlock-exec: dup2 LL_STDERR_FD: %s\n",strerror(errno));
  /* This process's own configuration ends here — the child gets a ruleset, not a
   * memo about how it was built. LL_RO/LL_RW have done their job; LL_STATUS_FD is
   * closed by CLOEXEC on a successful exec below regardless, but unsetting all four
   * is cheap and removes any dependence on that being the only backstop. */
  unsetenv("LL_RO"); unsetenv("LL_RW"); unsetenv("LL_STATUS_FD"); unsetenv("LL_STDERR_FD");
  unsetenv("AIB_ROLE_UIDS"); unsetenv("AIB_ROLE_GROUPS");
  execvp(argv[argi],&argv[argi]);
  /* execvp failed: fd 2 may already be the PROVIDER's relay (LL_STDERR_FD above) —
   * this diagnostic goes to journal_fd (the saved original stderr when that
   * happened, plain fd 2 otherwise), never to fd 2 itself, so it can never land on
   * the caller's wire. LL_STATUS_FD (status_fail below) is still the caller's
   * primary signal; this is the journal's copy of the same failure. */
  dprintf(journal_fd,"landlock-exec: exec %s: %s\n",argv[argi],strerror(errno));
  status_fail("exec: execvp failed");
  return 127;
}
