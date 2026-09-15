#include "../../windows/runner/dfu_protocol.h"

constexpr bool AllBytesAreFF() {
  for (const auto byte : dfu::Report()) {
    if (byte != 0xFF) return false;
  }
  return true;
}
static_assert(dfu::Report().size() == 65);
static_assert(AllBytesAreFF());
static_assert(dfu::IsInterface(0x0D00, 0x072A, 0, 65));
static_assert(dfu::IsInterface(0x0D00, 0x072B, 0, 65));
static_assert(dfu::IsInterface(0x0D00, 0x072C, 0, 65));
static_assert(dfu::IsInterface(0x0D00, 0x072D, 0, 65));
static_assert(!dfu::IsInterface(0x0D01, 0x072C, 0, 65));
static_assert(!dfu::IsInterface(0x0D00, 0x0729, 0, 65));
static_assert(!dfu::IsInterface(0x0D00, 0x072E, 0, 65));
static_assert(!dfu::IsInterface(0x0D00, 0x072C, 1, 65));
static_assert(!dfu::IsInterface(0x0D00, 0x072C, -1, 65));
static_assert(!dfu::IsInterface(0x0D00, 0x072C, 0, 64));
static_assert(!dfu::IsInterface(0x0D00, 0x072C, 0, 66));
int main() { return 0; }
