#ifndef TRELLIS_POSIX_H
#define TRELLIS_POSIX_H
#include <sys/types.h>
#include <stddef.h>
#include <stdint.h>
/// Darwin: start time in seconds and microseconds. Linux: `starttime` clock ticks, split at the tick rate.
/// Only compared for equality, never shown.
struct trellis_process_identity { int valid; pid_t parent_pid; pid_t group_id; uint64_t started_seconds; uint64_t started_microseconds; };
struct trellis_process_identity trellis_read_process_identity(pid_t pid);
struct trellis_spawn_result { pid_t pid; int master_fd; int error_code; };
struct trellis_spawn_result trellis_spawn_pty(const char *executable, char *const argv[],
    char *const envp[], const char *directory, unsigned short columns, unsigned short rows);
/// Starts `executable` as a daemon: double fork, new session, stdio on /dev/null, default signals,
/// no inherited descriptors. The intermediate child is reaped here. Returns 0 or the exec errno.
int trellis_spawn_detached(const char *executable, char *const argv[], char *const envp[]);
/// A remote workspace link (FR-RW03): `executable` (ssh) gets one end of a socket pair as stdin and stdout, and a new
/// PTY as its controlling terminal and stderr, so authentication prompts reach a console while the protocol stays binary.
struct trellis_link_result { pid_t pid; int data_fd; int console_fd; int error_code; };
struct trellis_link_result trellis_spawn_link(const char *executable, char *const argv[], char *const envp[]);

// Portable wrappers for calls Swift can't make the same way on Darwin and Linux (variadic ioctl,
// enum-typed constants, platform-specific peer credentials).

/// The connected AF_UNIX peer's uid and pid. Returns 0 or an errno.
int trellis_peer_credentials(int fd, uid_t *uid, pid_t *pid);
/// A live process's executable path (not resolved), NUL-terminated. Returns its length or -1.
long trellis_executable_path(pid_t pid, char *buffer, size_t size);
int trellis_set_window_size(int fd, unsigned short columns, unsigned short rows);
/// Cryptographically random bytes. Returns 0 or an errno.
int trellis_random_bytes(void *buffer, size_t count);
/// A new close-on-exec AF_UNIX stream socket, or -1.
int trellis_unix_socket(void);
/// Darwin: SO_NOSIGPIPE. Elsewhere a no-op; those processes ignore SIGPIPE. Returns 0 or an errno.
int trellis_prevent_sigpipe(int fd);
void trellis_disable_core_dumps(void);
/// A stable per-machine identifier (Darwin host UUID, Linux machine-id), NUL-terminated. Returns its length or -1.
long trellis_machine_id(char *buffer, size_t size);
/// Runs a program with its output captured and a time limit (git status, FR-PL09).
int trellis_run_capture(const char *executable, char *const argv[], char *const envp[], const char *directory, char *buffer, size_t size,
                        size_t *length, int timeout_ms);
/// `uname` system name and machine, NUL-terminated. Returns 0 or an errno.
int trellis_uname(char *system, size_t system_size, char *machine, size_t machine_size);
#endif
