#include "TrellisPOSIX.h"
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdlib.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <unistd.h>
#include <util.h>
#include <libproc.h>

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
        struct sigaction defaults = { .sa_handler = SIG_DFL, .sa_flags = 0 };
        sigemptyset(&defaults.sa_mask);
        for (int number = 1; number < NSIG; number++) {
            if (number != SIGKILL && number != SIGSTOP && sigaction(number, &defaults, NULL) < 0)
                report_child_error(errors[1], errno);
        }
        sigset_t unblocked;
        sigemptyset(&unblocked);
        if (sigprocmask(SIG_SETMASK, &unblocked, NULL) < 0) report_child_error(errors[1], errno);
        // Never pass application files, sockets, or another pane's PTY to the
        // shell, including descriptors opened without FD_CLOEXEC by libraries.
        for (int fd = 3; fd < descriptor_limit; fd++) {
            if (fd != errors[1]) close(fd);
        }
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
