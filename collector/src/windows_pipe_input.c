#define _WIN32_WINNT 0x0600
#include <windows.h>

// The error must be captured before returning through the Dart FFI boundary.
// Neither the buffer nor OVERLAPPED can leave this call with pending I/O.
__declspec(dllexport) DWORD quotabot_read_pipe(
    HANDLE input, BYTE* buffer, DWORD capacity, OVERLAPPED* overlapped,
    DWORD* transferred) {
  *transferred = 0;
  BOOL ok = ReadFile(input, buffer, capacity, NULL, overlapped);
  DWORD error = ok ? ERROR_SUCCESS : GetLastError();
  if (ok || error == ERROR_IO_PENDING || error == ERROR_MORE_DATA) {
    do {
      ok = GetOverlappedResult(input, overlapped, transferred, TRUE);
      error = ok ? ERROR_SUCCESS : GetLastError();
    } while (error == ERROR_IO_INCOMPLETE || error == ERROR_IO_PENDING);
  }
  return error;
}

__declspec(dllexport) DWORD quotabot_pipe_input_abi(void) { return 1; }
