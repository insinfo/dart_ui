set pagination off
set breakpoint pending on
set print thread-events off
set confirm off
handle SIGPIPE nostop noprint pass

break eglDestroyContext
commands
  silent
  printf "\n[POC-22/GDB] eglDestroyContext\n"
  bt 4
  continue
end

break eglDestroySurface
commands
  silent
  printf "\n[POC-22/GDB] eglDestroySurface\n"
  bt 4
  continue
end

break eglTerminate
commands
  silent
  printf "\n[POC-22/GDB] eglTerminate\n"
  bt 6
  continue
end

break dlclose
commands
  silent
  printf "\n[POC-22/GDB] dlclose(%p)\n", $rdi
  bt 8
  continue
end

run

printf "\n[POC-22/GDB] process stopped\n"
info symbol $pc
info proc mappings
info sharedlibrary
thread apply all bt 20
