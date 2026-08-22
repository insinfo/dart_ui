#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

static void fatal_signal(int signal_number) {
  static const char message[] = "fatal signal while touching DAX mapping\n";
  (void)write(STDERR_FILENO, message, sizeof(message) - 1);
  _exit(128 + signal_number);
}

static void print_result(const char *operation, int result) {
  if (result == 0) {
    printf("%-18s ok\n", operation);
  } else {
    printf("%-18s rc=%d errno=%d (%s)\n", operation, result, errno,
           strerror(errno));
  }
  fflush(stdout);
}

int main(int argc, char **argv) {
  const char *path = argc > 1 ? argv[1] : "/mnt/shared_memory/dax_probe";
  const size_t file_size = 4096;
  const size_t mapping_size = 2 * 1024 * 1024;

  setvbuf(stdout, NULL, _IONBF, 0);
  signal(SIGBUS, fatal_signal);
  signal(SIGSEGV, fatal_signal);
  signal(SIGALRM, fatal_signal);

  printf("path=%s\n", path);
  printf("file_size=%zu mapping_size=%zu\n", file_size, mapping_size);

  puts("open               begin");
  alarm(10);
  errno = 0;
  int fd = open(path, O_CREAT | O_RDWR | O_EXCL | O_CLOEXEC, 0600);
  alarm(0);
  if (fd < 0) {
    print_result("open", fd);
    return 1;
  }
  print_result("open", 0);

  errno = 0;
  int result = fallocate(fd, 0, 0, (off_t)file_size);
  print_result("fallocate", result);
  if (result != 0) {
    close(fd);
    unlink(path);
    return 2;
  }

  errno = 0;
  void *mapping = mmap(NULL, mapping_size, PROT_READ | PROT_WRITE, MAP_SHARED,
                       fd, 0);
  if (mapping == MAP_FAILED) {
    print_result("mmap", -1);
    close(fd);
    unlink(path);
    return 3;
  }
  print_result("mmap", 0);

  volatile uint8_t *bytes = (volatile uint8_t *)mapping;
  puts("touch-first-page   begin");
  fflush(stdout);
  bytes[0] = 0x5a;
  bytes[file_size - 1] = 0xa5;
  puts("touch-first-page   ok");

  errno = 0;
  result = msync(mapping, file_size, MS_SYNC);
  print_result("msync", result);

  errno = 0;
  result = munmap(mapping, mapping_size);
  print_result("munmap", result);

  errno = 0;
  result = close(fd);
  print_result("close", result);

  errno = 0;
  result = unlink(path);
  print_result("unlink", result);
  return 0;
}
