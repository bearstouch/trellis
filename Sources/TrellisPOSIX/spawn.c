#if defined(__linux__)
#define _GNU_SOURCE
#endif
#include "TrellisPOSIX.h"
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/utsname.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>
#if defined(__APPLE__)
#include <libproc.h>
#include <sys/un.h>
#include <util.h>
#include <uuid/uuid.h>
#else
#include <pty.h>
#include <sys/random.h>
#include <sys/syscall.h>
#endif

#if defined(__APPLE__)
struct trellis_process_identity trellis_read_process_identity(pid_t pid) {
    struct trellis_process_identity result = {0};
    struct proc_bsdinfo info = {0};
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) == sizeof(info)) {
        result.valid = 1; result.parent_pid = (pid_t)info.pbi_ppid;
        result.group_id = getpgid(pid);
        result.started_seconds = info.pbi_start_tvsec;
        result.started_microseconds = info.pbi_start_tvusec;
    }
    return result;
}
#else
struct trellis_process_identity trellis_read_process_identity(pid_t pid) {
    struct trellis_process_identity result = {0};
    char path[64], text[1024];
    snprintf(path, sizeof(path), "/proc/%d/stat", (int)pid);
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return result;
    ssize_t count = read(fd, text, sizeof(text) - 1);
    close(fd);
    if (count <= 0) return result;
    text[count] = 0;
    // The command name can hold spaces and parentheses; fields resume after the last ')'.
    char *rest = strrchr(text, ')');
    if (!rest) return result;
    rest++;
    unsigned long long started = 0;
    int parent = 0, group = 0;
    if (sscanf(rest, " %*c %d %d %*d %*d %*d %*u %*u %*u %*u %*u %*u %*u %*d %*d %*d %*d %*d %*d %llu", &parent, &group, &started) != 3)
        return result;
    long ticks = sysconf(_SC_CLK_TCK);
    if (ticks <= 0) ticks = 100;
    result.valid = 1; result.parent_pid = parent; result.group_id = group;
    result.started_seconds = started / (unsigned long long)ticks;
    result.started_microseconds = (started % (unsigned long long)ticks) * 1000000ULL / (unsigned long long)ticks;
    return result;
}
#endif

/// Signals the C library reserves (glibc's real-time 32 and 33) can't be changed; skipping them is correct.
static int reset_signal(int number) {
    struct sigaction defaults;
    memset(&defaults, 0, sizeof(defaults));
    defaults.sa_handler = SIG_DFL;
    sigemptyset(&defaults.sa_mask);
    if (sigaction(number, &defaults, NULL) == 0 || errno == EINVAL) return 0;
    return errno;
}

/// Closes every descriptor from 3 up except `keep` (itself at least 3). Containers often allow a million descriptors;
/// Linux's close_range spares the child that many close calls, and the loop covers kernels without it.
static void close_descriptors(int keep, int limit) {
#if defined(SYS_close_range)
    if ((keep == 3 || syscall(SYS_close_range, 3U, (unsigned)keep - 1, 0U) == 0) && syscall(SYS_close_range, (unsigned)keep + 1, ~0U, 0U) == 0) return;
#endif
    for (int fd = 3; fd < limit; fd++) {
        if (fd != keep) close(fd);
    }
}

static void report_child_error(int descriptor, int failure) {
    const char *bytes = (const char *)&failure;
    size_t remaining = sizeof(failure);
    while (remaining) {
        ssize_t n = write(descriptor, bytes, remaining);
        if (n > 0) { bytes += n; remaining -= (size_t)n; }
        else if (n < 0 && errno == EINTR) continue;
        else break;
    }
    _exit(127);
}

struct trellis_spawn_result trellis_spawn_pty(const char *executable, char *const argv[],
    char *const envp[], const char *directory, unsigned short columns, unsigned short rows) {
    struct trellis_spawn_result result = { .pid = -1, .master_fd = -1, .error_code = 0 };
    int errors[2];
    if (pipe(errors) < 0) { result.error_code = errno; return result; }
    // forkpty replaces 0, 1 and 2 in its child. Keep the handshake outside
    // that range even when the host application was launched without stdio.
    for (int i = 0; i < 2; i++) {
        if (errors[i] < 3) {
            int replacement = fcntl(errors[i], F_DUPFD_CLOEXEC, 3);
            if (replacement < 0) {
                result.error_code = errno; close(errors[0]); close(errors[1]); return result;
            }
            close(errors[i]);
            errors[i] = replacement;
        }
    }
    if (fcntl(errors[0], F_SETFD, FD_CLOEXEC) < 0 || fcntl(errors[1], F_SETFD, FD_CLOEXEC) < 0) {
        result.error_code = errno; close(errors[0]); close(errors[1]); return result;
    }
    struct winsize size = { .ws_col = columns, .ws_row = rows };
    // Resolve this before fork: only async-signal-safe operations belong in
    // the multithreaded application's child before exec.
    int descriptor_limit = getdtablesize();
    int master;
    pid_t child = forkpty(&master, NULL, NULL, &size);
    if (child < 0) {
        result.error_code = errno; close(errors[0]); close(errors[1]); return result;
    }
    if (child == 0) {
        close(errors[0]);
        // Worker threads may block signals and the application may ignore them.
        // Neither policy belongs to a new interactive process. exec resets
        // caught handlers, but preserves ignored handlers and the signal mask.
        for (int number = 1; number < NSIG; number++) {
            int failure = number != SIGKILL && number != SIGSTOP ? reset_signal(number) : 0;
            if (failure) report_child_error(errors[1], failure);
        }
        sigset_t unblocked;
        sigemptyset(&unblocked);
        if (sigprocmask(SIG_SETMASK, &unblocked, NULL) < 0) report_child_error(errors[1], errno);
        // Never pass application files, sockets, or another pane's PTY to the
        // shell, including descriptors opened without FD_CLOEXEC by libraries.
        close_descriptors(errors[1], descriptor_limit);
        if (chdir(directory) < 0) report_child_error(errors[1], errno);
        execve(executable, argv, envp);
        report_child_error(errors[1], errno);
    }
    close(errors[1]);
    int failure = 0;
    size_t count = 0;
    while (count < sizeof(failure)) {
        ssize_t n = read(errors[0], (char *)&failure + count, sizeof(failure) - count);
        if (n > 0) count += (size_t)n;
        else if (n == 0) break; /* successful exec closed the error pipe */
        else if (errno == EINTR) continue;
        else { failure = errno; break; }
    }
    close(errors[0]);
    if (count > 0 && count != sizeof(failure)) failure = EIO;
    if (!failure && fcntl(master, F_SETFD, FD_CLOEXEC) < 0) failure = errno;
    if (failure) {
        close(master);
        kill(child, SIGKILL); /* own unreaped child: PID cannot be reused */
        while (waitpid(child, NULL, 0) < 0 && errno == EINTR) {}
        result.error_code = failure;
        return result;
    }
    result.pid = child;
    result.master_fd = master;
    return result;
}

int trellis_spawn_detached(const char *executable, char *const argv[], char *const envp[]) {
    int errors[2];
    if (pipe(errors) < 0) return errno;
    // stdio is replaced in the daemon; keep the handshake above it, like trellis_spawn_pty.
    for (int i = 0; i < 2; i++) {
        int replacement = fcntl(errors[i], F_DUPFD_CLOEXEC, 3);
        if (replacement < 0) { int failure = errno; close(errors[0]); close(errors[1]); return failure; }
        close(errors[i]);
        errors[i] = replacement;
    }
    int descriptor_limit = getdtablesize();
    pid_t middle = fork();
    if (middle < 0) { int failure = errno; close(errors[0]); close(errors[1]); return failure; }
    if (middle == 0) {
        close(errors[0]);
        if (setsid() < 0) report_child_error(errors[1], errno);
        pid_t daemon = fork();
        if (daemon < 0) report_child_error(errors[1], errno);
        if (daemon > 0) _exit(0); /* the daemon is reparented to launchd (or init) and can never reacquire a terminal */
        for (int number = 1; number < NSIG; number++) {
            if (number != SIGKILL && number != SIGSTOP) reset_signal(number);
        }
        sigset_t unblocked;
        sigemptyset(&unblocked);
        sigprocmask(SIG_SETMASK, &unblocked, NULL);
        int null = open("/dev/null", O_RDWR);
        if (null < 0) report_child_error(errors[1], errno);
        if (dup2(null, 0) < 0 || dup2(null, 1) < 0 || dup2(null, 2) < 0) report_child_error(errors[1], errno);
        close_descriptors(errors[1], descriptor_limit);
        if (chdir("/") < 0) report_child_error(errors[1], errno);
        execve(executable, argv, envp);
        report_child_error(errors[1], errno);
    }
    close(errors[1]);
    int status = 0;
    while (waitpid(middle, &status, 0) < 0 && errno == EINTR) {}
    int failure = 0;
    size_t count = 0;
    while (count < sizeof(failure)) {
        ssize_t n = read(errors[0], (char *)&failure + count, sizeof(failure) - count);
        if (n > 0) count += (size_t)n;
        else if (n == 0) break; /* exec closed the last write end */
        else if (errno == EINTR) continue;
        else { failure = errno; break; }
    }
    close(errors[0]);
    if (count > 0 && count != sizeof(failure)) failure = EIO;
    if (!failure && !(WIFEXITED(status) && WEXITSTATUS(status) == 0)) failure = ECHILD;
    return failure;
}

int trellis_peer_credentials(int fd, uid_t *uid, pid_t *pid) {
#if defined(__APPLE__)
    gid_t group = 0;
    pid_t peer = 0;
    socklen_t length = sizeof(peer);
    if (getpeereid(fd, uid, &group) < 0) return errno;
    if (getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &peer, &length) < 0) return errno;
    *pid = peer;
#else
    struct ucred credentials;
    socklen_t length = sizeof(credentials);
    if (getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &credentials, &length) < 0) return errno;
    *uid = credentials.uid;
    *pid = credentials.pid;
#endif
    return 0;
}

long trellis_executable_path(pid_t pid, char *buffer, size_t size) {
    if (size < 2) return -1;
#if defined(__APPLE__)
    int length = proc_pidpath(pid, buffer, (uint32_t)size);
    if (length <= 0) return -1;
    buffer[length < (int)size ? length : (int)size - 1] = 0;
    return length;
#else
    char link[64];
    snprintf(link, sizeof(link), "/proc/%d/exe", (int)pid);
    ssize_t length = readlink(link, buffer, size - 1);
    if (length <= 0) return -1;
    buffer[length] = 0;
    return (long)length;
#endif
}

int trellis_set_window_size(int fd, unsigned short columns, unsigned short rows) {
    struct winsize size;
    memset(&size, 0, sizeof(size));
    size.ws_col = columns;
    size.ws_row = rows;
    return ioctl(fd, TIOCSWINSZ, &size) < 0 ? errno : 0;
}

int trellis_random_bytes(void *buffer, size_t count) {
#if defined(__APPLE__)
    arc4random_buf(buffer, count);
    return 0;
#else
    char *bytes = buffer;
    while (count) {
        ssize_t n = getrandom(bytes, count, 0);
        if (n < 0) { if (errno == EINTR) continue; return errno; }
        bytes += n; count -= (size_t)n;
    }
    return 0;
#endif
}

int trellis_unix_socket(void) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd >= 0 && fcntl(fd, F_SETFD, FD_CLOEXEC) < 0) { close(fd); return -1; }
    return fd;
}

int trellis_prevent_sigpipe(int fd) {
#if defined(__APPLE__)
    int one = 1;
    return setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one)) < 0 ? errno : 0;
#else
    (void)fd;
    return 0;
#endif
}

void trellis_disable_core_dumps(void) {
    struct rlimit limit = { 0, 0 };
    setrlimit(RLIMIT_CORE, &limit);
}

long trellis_machine_id(char *buffer, size_t size) {
    if (size < 37) return -1;
#if defined(__APPLE__)
    uuid_t identifier;
    struct timespec wait = { 1, 0 };
    if (gethostuuid(identifier, &wait) < 0) return -1;
    uuid_unparse_lower(identifier, buffer);
    return (long)strlen(buffer);
#else
    const char *paths[] = { "/etc/machine-id", "/var/lib/dbus/machine-id" };
    for (int i = 0; i < 2; i++) {
        int fd = open(paths[i], O_RDONLY | O_CLOEXEC);
        if (fd < 0) continue;
        ssize_t count = read(fd, buffer, size - 1);
        close(fd);
        while (count > 0 && (buffer[count - 1] == '\n' || buffer[count - 1] == ' ')) count--;
        if (count > 0) { buffer[count] = 0; return (long)count; }
    }
    return -1;
#endif
}

int trellis_uname(char *system, size_t system_size, char *machine, size_t machine_size) {
    struct utsname names;
    if (uname(&names) < 0 || system_size == 0 || machine_size == 0) return errno ? errno : EINVAL;
    snprintf(system, system_size, "%s", names.sysname);
    snprintf(machine, machine_size, "%s", names.machine);
    return 0;
}
