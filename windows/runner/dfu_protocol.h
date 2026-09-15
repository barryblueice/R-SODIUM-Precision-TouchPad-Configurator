#ifndef RUNNER_DFU_PROTOCOL_H_
#define RUNNER_DFU_PROTOCOL_H_

#include <array>
#include <cstdint>

namespace dfu {
// Matches esp32-haptic-precision-touchpad/dfu/usb_module.py.
constexpr bool IsTarget(uint16_t vendor, uint16_t product) {
  return vendor == 0x0D00 && product >= 0x072A && product <= 0x072D;
}
constexpr bool IsInterface(uint16_t vendor, uint16_t product,
                           int interface_number, uint16_t output_length) {
  return IsTarget(vendor, product) && interface_number == 0 && output_length == 65;
}
constexpr std::array<uint8_t, 65> Report() {
  std::array<uint8_t, 65> report{};
  // Includes the report-ID slot: do not prepend a zero or wrap in RSTP.
  for (auto& byte : report) byte = 0xFF;
  return report;
}
}  // namespace dfu
#endif
