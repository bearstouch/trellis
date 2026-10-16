#ifndef UTERM_POSIX_H
#define UTERM_POSIX_H
#include <sys/types.h>
struct uterm_spawn_result { pid_t pid; int master_fd; int error_code; };
struct uterm_spawn_result uterm_spawn_pty(const char *executable, char *const argv[],
    char *const envp[], const char *directory, unsigned short columns, unsigned short rows);
#endif
