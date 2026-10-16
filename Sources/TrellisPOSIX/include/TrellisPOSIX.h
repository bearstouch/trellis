#ifndef TRELLIS_POSIX_H
#define TRELLIS_POSIX_H
#include <sys/types.h>
#include <stdint.h>
struct trellis_process_identity { int valid; pid_t parent_pid; pid_t group_id; uint64_t started_seconds; uint64_t started_microseconds; };
struct trellis_process_identity trellis_read_process_identity(pid_t pid);
struct trellis_spawn_result { pid_t pid; int master_fd; int error_code; };
struct trellis_spawn_result trellis_spawn_pty(const char *executable, char *const argv[],
    char *const envp[], const char *directory, unsigned short columns, unsigned short rows);
#endif
