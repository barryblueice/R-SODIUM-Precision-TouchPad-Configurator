#include "hid_bridge.h"
#include "dfu_protocol.h"

#include <hidsdi.h>
#include <hidpi.h>
#include <setupapi.h>
#include <initguid.h>
#include <devpkey.h>
#include <cfgmgr32.h>
#include <flutter/standard_method_codec.h>
#include <algorithm>
#include <cwctype>
#include <iomanip>
#include <map>
#include <sstream>
#include <stdexcept>
#include <vector>

namespace {
using Value = flutter::EncodableValue;
using Map = flutter::EncodableMap;
using List = flutter::EncodableList;
struct NativeError {
  // Own both strings: Flutter's standard runner disables STL exception support.
  NativeError(std::string c, std::string m)
      : code(std::move(c)), message(std::move(m)) {}
  std::string code, message;
};
std::string Utf8(const std::wstring& value) {
  if (value.empty()) return {};
  const int size = WideCharToMultiByte(CP_UTF8, 0, value.data(),
      static_cast<int>(value.size()), nullptr, 0, nullptr, nullptr);
  std::string result(size, 0);
  WideCharToMultiByte(CP_UTF8, 0, value.data(), static_cast<int>(value.size()),
      result.data(), size, nullptr, nullptr);
  return result;
}
[[noreturn]] void Fail(const std::string& operation, DWORD error = GetLastError()) {
  std::string code = "io";
  if (error == ERROR_ACCESS_DENIED) code = "access_denied";
  if (error == ERROR_DEVICE_NOT_CONNECTED || error == ERROR_INVALID_HANDLE ||
      error == ERROR_NO_SUCH_DEVICE || error == ERROR_OPERATION_ABORTED) code = "disconnected";
  throw NativeError(code, operation + " (Windows error " + std::to_string(error) + ")");
}
struct ScopedHandle {
  HANDLE value;
  ~ScopedHandle() { if (value != INVALID_HANDLE_VALUE && value != nullptr) CloseHandle(value); }
};
struct DeviceSet {
  HDEVINFO value;
  ~DeviceSet() { if (value != INVALID_HANDLE_VALUE) SetupDiDestroyDeviceInfoList(value); }
};
struct Collection {
  std::wstring path;
  std::string container, name, serial;
  HIDP_CAPS caps{};
  bool press = false, intensity = false;
  USHORT vendor = 0, product = 0;
  int interface_number = -1;
  bool SupportsDfu() const {
    return dfu::IsInterface(vendor, product, interface_number, caps.OutputReportByteLength);
  }
};
std::string Container(HDEVINFO set, SP_DEVINFO_DATA& device, const std::wstring& path) {
  GUID id{};
  DEVPROPTYPE type = 0;
  if (SetupDiGetDevicePropertyW(set, &device, &DEVPKEY_Device_ContainerId,
      &type, reinterpret_cast<PBYTE>(&id), sizeof(id), nullptr, 0) &&
      type == DEVPROP_TYPE_GUID && !IsEqualGUID(id, GUID_NULL)) {
    wchar_t text[40]{};
    StringFromGUID2(id, text, 40);
    return Utf8(text);
  }
  // Fallback: locate the physical USB ancestor, not a shared serial string.
  DEVINST node = device.DevInst;
  for (int depth = 0; depth < 8; depth++) {
    wchar_t text[MAX_DEVICE_ID_LEN]{};
    if (CM_Get_Device_IDW(node, text, MAX_DEVICE_ID_LEN, 0) == CR_SUCCESS) {
      std::wstring instance(text);
      if (instance.find(L"USB\\VID_0D00&PID_072") == 0 &&
          instance.find(L"&MI_") == std::wstring::npos) return Utf8(instance);
    }
    DEVINST parent;
    if (CM_Get_Parent(&parent, node, 0) != CR_SUCCESS) break;
    node = parent;
  }
  return Utf8(path);
}
std::vector<Collection> Enumerate() {
  GUID guid;
  HidD_GetHidGuid(&guid);
  DeviceSet set{SetupDiGetClassDevsW(&guid, nullptr, nullptr,
      DIGCF_PRESENT | DIGCF_DEVICEINTERFACE)};
  if (set.value == INVALID_HANDLE_VALUE) Fail("SetupDiGetClassDevs");
  std::vector<Collection> found;
  for (DWORD index = 0;; index++) {
    SP_DEVICE_INTERFACE_DATA interface_data{};
    interface_data.cbSize = sizeof(interface_data);
    if (!SetupDiEnumDeviceInterfaces(set.value, nullptr, &guid, index, &interface_data)) {
      if (GetLastError() != ERROR_NO_MORE_ITEMS) Fail("SetupDiEnumDeviceInterfaces");
      break;
    }
    DWORD required = 0;
    SetupDiGetDeviceInterfaceDetailW(set.value, &interface_data, nullptr, 0, &required, nullptr);
    if (required < sizeof(SP_DEVICE_INTERFACE_DETAIL_DATA_W)) continue;
    std::vector<uint8_t> storage(required);
    auto* detail = reinterpret_cast<SP_DEVICE_INTERFACE_DETAIL_DATA_W*>(storage.data());
    detail->cbSize = sizeof(SP_DEVICE_INTERFACE_DETAIL_DATA_W);
    SP_DEVINFO_DATA dev{};
    dev.cbSize = sizeof(dev);
    if (!SetupDiGetDeviceInterfaceDetailW(set.value, &interface_data, detail,
        required, nullptr, &dev)) continue;
    ScopedHandle handle{CreateFileW(detail->DevicePath, 0, FILE_SHARE_READ | FILE_SHARE_WRITE,
        nullptr, OPEN_EXISTING, 0, nullptr)};
    if (handle.value == INVALID_HANDLE_VALUE) continue;
    HIDD_ATTRIBUTES attributes{};
    attributes.Size = sizeof(attributes);
    if (!HidD_GetAttributes(handle.value, &attributes) ||
        !dfu::IsTarget(attributes.VendorID, attributes.ProductID)) continue;
    Collection c;
    c.path = detail->DevicePath;
    c.vendor = attributes.VendorID;
    c.product = attributes.ProductID;
    std::wstring normalized_path = c.path;
    std::transform(normalized_path.begin(), normalized_path.end(), normalized_path.begin(),
        [](wchar_t ch) { return static_cast<wchar_t>(std::towlower(ch)); });
    if (normalized_path.find(L"&mi_00") != std::wstring::npos) c.interface_number = 0;
    c.container = Container(set.value, dev, c.path);
    wchar_t product[256]{}, serial[256]{};
    HidD_GetProductString(handle.value, product, sizeof(product));
    HidD_GetSerialNumberString(handle.value, serial, sizeof(serial));
    c.name = Utf8(product); c.serial = Utf8(serial);
    PHIDP_PREPARSED_DATA data = nullptr;
    if (!HidD_GetPreparsedData(handle.value, &data)) continue;
    const auto status = HidP_GetCaps(data, &c.caps);
    if (status == HIDP_STATUS_SUCCESS && c.caps.UsagePage == 0x0D && c.caps.Usage == 5) {
      USHORT count = c.caps.NumberFeatureValueCaps;
      std::vector<HIDP_VALUE_CAPS> values(count);
      if (count != 0 && HidP_GetValueCaps(HidP_Feature, values.data(), &count, data) == HIDP_STATUS_SUCCESS) {
        for (USHORT i = 0; i < count; i++) {
          c.press = c.press || values[i].ReportID == 0x40;
          c.intensity = c.intensity || values[i].ReportID == 0x41;
        }
      }
    }
    HidD_FreePreparsedData(data);
    if (status == HIDP_STATUS_SUCCESS) found.push_back(std::move(c));
  }
  return found;
}
const Value& Arg(const Map& args, const char* name) {
  const auto it = args.find(Value(name));
  if (it == args.end()) throw NativeError("argument", std::string("Missing argument: ") + name);
  return it->second;
}
int Integer(const Map& args, const char* name) {
  const auto* value = std::get_if<int32_t>(&Arg(args, name));
  if (!value) throw NativeError("argument", "Expected integer");
  return *value;
}
}  // namespace

HidBridge::HidBridge(flutter::BinaryMessenger* messenger, HWND window) : window_(window) {
  channel_ = std::make_unique<flutter::MethodChannel<Value>>(
      messenger, "technology.rsodium/hid", &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, std::unique_ptr<Result> result) {
    Map args;
    if (call.arguments() && !std::holds_alternative<std::monostate>(*call.arguments())) {
      const auto* map = std::get_if<Map>(call.arguments());
      if (!map) { result->Error("argument", "Expected map"); return; }
      args = *map;
    }
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (stopping_) { result->Error("disconnected", "HID bridge is closing"); return; }
      jobs_.push(Job{call.method_name(), std::move(args), std::shared_ptr<Result>(std::move(result))});
    }
    ready_.notify_one();
  });
  worker_ = std::thread([this] { Worker(); });
}
HidBridge::~HidBridge() {
  channel_->SetMethodCallHandler(nullptr);
  {
    std::lock_guard<std::mutex> lock(mutex_);
    stopping_ = true;
    while (!jobs_.empty()) jobs_.pop();
  }
  ready_.notify_one();
  if (worker_.joinable()) worker_.join();
  DrainCompletions();
}
void HidBridge::Worker() {
  for (;;) {
    Job job;
    {
      std::unique_lock<std::mutex> lock(mutex_);
      ready_.wait(lock, [this] { return stopping_ || !jobs_.empty(); });
      if (stopping_) break;
      job = std::move(jobs_.front()); jobs_.pop();
    }
    std::function<void()> completion;
    try {
      Value value = Run(job.method, job.args);
      completion = [result = job.result, value = std::move(value)] { result->Success(value); };
    } catch (const NativeError& e) {
      completion = [result = job.result, code = e.code, message = e.message] {
        result->Error(code, message);
      };
    } catch (const std::exception& e) {
      completion = [result = job.result, message = std::string(e.what())] { result->Error("native", message); };
    }
    {
      std::lock_guard<std::mutex> lock(mutex_);
      completions_.push(std::move(completion));
    }
    PostMessage(window_, kCompleteMessage, 0, 0);
  }
  CloseHandles();
}
void HidBridge::DrainCompletions() {
  std::queue<std::function<void()>> queue;
  { std::lock_guard<std::mutex> lock(mutex_); queue.swap(completions_); }
  while (!queue.empty()) { queue.front()(); queue.pop(); }
}
void HidBridge::CloseHandles() {
  if (generic_ != INVALID_HANDLE_VALUE) CloseHandle(generic_);
  generic_ = INVALID_HANDLE_VALUE;
  for (auto& handle : features_) {
    if (handle != INVALID_HANDLE_VALUE) CloseHandle(handle);
    handle = INVALID_HANDLE_VALUE;
  }
  feature_lengths_[0] = feature_lengths_[1] = 0;
}
HidBridge::Value HidBridge::Run(const std::string& method, const Map& args) {
  if (method == "enumerate") {
    std::map<std::string, std::vector<Collection>> groups;
    for (auto& c : Enumerate()) groups[c.container].push_back(std::move(c));
    List result;
    for (const auto& pair : groups) {
      const auto& first = pair.second.front();
      std::string dfu_path;
      int dfu_count = 0;
      std::ostringstream details;
      for (const auto& c : pair.second) {
        if (c.SupportsDfu()) { dfu_path = Utf8(c.path); dfu_count++; }
        details << "Usage " << std::hex << std::setw(4) << std::setfill('0') << c.caps.UsagePage
                << ":" << std::setw(4) << c.caps.Usage << std::dec
                << " | IN " << c.caps.InputReportByteLength << " OUT " << c.caps.OutputReportByteLength
                << " FEATURE " << c.caps.FeatureReportByteLength << "\n";
      }
      // Never guess between multiple writable interface-0 collections.
      if (dfu_count != 1) dfu_path.clear();
      result.emplace_back(Map{{Value("id"), Value(pair.first)},
        {Value("name"), Value(first.name.empty() ? "R-SODIUM TouchPad" : first.name)},
        {Value("serial"), Value(first.serial)},
        {Value("collections"), Value(static_cast<int32_t>(pair.second.size()))},
        {Value("vendorId"), Value(static_cast<int32_t>(first.vendor))},
        {Value("productId"), Value(static_cast<int32_t>(first.product))},
        {Value("dfuPath"), Value(dfu_path)},
        {Value("details"), Value(details.str())}});
    }
    return Value(result);
  }
  if (method == "enterDfu") {
    const auto* id = std::get_if<std::string>(&Arg(args, "id"));
    const auto* path = std::get_if<std::string>(&Arg(args, "path"));
    if (!id || !path || path->empty()) throw NativeError("argument", "Expected DFU target id and path");
    // Fresh enumeration binds this write to the requested physical device and
    // exact collection, independently of whether RSTP configuration is supported.
    std::vector<Collection> targets;
    for (auto& c : Enumerate()) {
      if (c.container == *id && c.SupportsDfu()) targets.push_back(std::move(c));
    }
    if (targets.size() != 1 || Utf8(targets.front().path) != *path) {
      throw NativeError("disconnected", "DFU target unavailable or ambiguous; command not sent");
    }
    ScopedHandle handle{CreateFileW(targets.front().path.c_str(), GENERIC_WRITE,
        FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_EXISTING, FILE_FLAG_OVERLAPPED, nullptr)};
    if (handle.value == INVALID_HANDLE_VALUE) Fail("Open DFU interface");
    const auto report = dfu::Report();
    ScopedHandle event{CreateEventW(nullptr, TRUE, FALSE, nullptr)};
    if (!event.value) Fail("Create DFU event");
    OVERLAPPED overlapped{};
    overlapped.hEvent = event.value;
    if (!WriteFile(handle.value, report.data(), static_cast<DWORD>(report.size()), nullptr, &overlapped)) {
      if (GetLastError() != ERROR_IO_PENDING) Fail("Write DFU command");
      const DWORD wait = WaitForSingleObject(event.value, 1500);
      if (wait != WAIT_OBJECT_0) {
        const DWORD error = GetLastError();
        CancelIoEx(handle.value, &overlapped);
        DWORD cancelled = 0;
        GetOverlappedResult(handle.value, &overlapped, &cancelled, TRUE);
        if (wait == WAIT_TIMEOUT) throw NativeError("timeout", "DFU write timed out; check device before retrying");
        Fail("Wait for DFU write", error);
      }
    }
    DWORD written = 0;
    if (!GetOverlappedResult(handle.value, &overlapped, &written, FALSE)) Fail("Complete DFU write");
    if (written != report.size()) {
      throw NativeError("short_write", "Incomplete DFU write: " + std::to_string(written) + "/65 bytes");
    }
    // This DFU handle is scoped to its target. The controller closes the
    // configuration connection only when that same device enters DFU.
    return Value();
  }
  if (method == "open") {
    const auto* id = std::get_if<std::string>(&Arg(args, "id"));
    if (!id) throw NativeError("argument", "Expected device id");
    CloseHandles();
    bool found = false;
    for (const auto& c : Enumerate()) {
      if (c.container != *id) continue;
      found = true;
      // Other product IDs are exposed for DFU only; do not assume their
      // configuration reports share the 072C protocol.
      if (c.product != 0x072C) continue;
      if (c.caps.UsagePage == 0xFF00 && c.caps.Usage == 1 &&
          c.caps.InputReportByteLength == 65 && c.caps.OutputReportByteLength == 65 &&
          generic_ == INVALID_HANDLE_VALUE) {
        generic_ = CreateFileW(c.path.c_str(), GENERIC_READ | GENERIC_WRITE,
          FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_EXISTING, FILE_FLAG_OVERLAPPED, nullptr);
        if (generic_ != INVALID_HANDLE_VALUE) HidD_FlushQueue(generic_);
      }
      const bool supported[] = {c.press, c.intensity};
      for (int i = 0; i < 2; i++) {
        if (supported[i] && c.caps.FeatureReportByteLength >= 2 && features_[i] == INVALID_HANDLE_VALUE) {
          features_[i] = CreateFileW(c.path.c_str(), 0, FILE_SHARE_READ | FILE_SHARE_WRITE,
              nullptr, OPEN_EXISTING, 0, nullptr);
          if (features_[i] != INVALID_HANDLE_VALUE) feature_lengths_[i] = c.caps.FeatureReportByteLength;
        }
      }
    }
    if (!found) throw NativeError("disconnected", "Target device is no longer present");
    if (generic_ == INVALID_HANDLE_VALUE && features_[0] == INVALID_HANDLE_VALUE && features_[1] == INVALID_HANDLE_VALUE) {
      throw NativeError("access_denied", "No accessible configuration collection for 0D00:072C");
    }
    return Value();
  }
  if (method == "close") { CloseHandles(); return Value(); }
  if (method == "send") {
    if (generic_ == INVALID_HANDLE_VALUE) throw NativeError("no_generic", "Vendor HID interface unavailable");
    const auto* packet = std::get_if<std::vector<uint8_t>>(&Arg(args, "packet"));
    if (!packet || packet->size() != 64 || (*packet)[0] != 0x52) {
      throw NativeError("argument", "Only 64-byte RSTP configuration packets are accepted");
    }
    // The leading zero is the Windows report-ID slot, not a firmware byte.
    std::vector<uint8_t> report(65, 0);
    std::copy(packet->begin(), packet->end(), report.begin() + 1);
    if (!HidD_SetOutputReport(generic_, report.data(), static_cast<ULONG>(report.size()))) Fail("HidD_SetOutputReport");
    return Value();
  }
  if (method == "read") {
    if (generic_ == INVALID_HANDLE_VALUE) throw NativeError("no_generic", "Vendor HID interface unavailable");
    const int timeout = Integer(args, "timeoutMs");
    if (timeout < 1 || timeout > 1500) throw NativeError("argument", "Invalid read timeout");
    std::vector<uint8_t> report(65, 0);
    ScopedHandle event{CreateEventW(nullptr, TRUE, FALSE, nullptr)};
    if (!event.value) Fail("CreateEvent");
    OVERLAPPED overlapped{};
    overlapped.hEvent = event.value;
    DWORD received = 0;
    if (!ReadFile(generic_, report.data(), static_cast<DWORD>(report.size()), &received, &overlapped)) {
      if (GetLastError() != ERROR_IO_PENDING) Fail("ReadFile");
      const DWORD wait = WaitForSingleObject(event.value, static_cast<DWORD>(timeout));
      if (wait != WAIT_OBJECT_0) {
        const DWORD error = GetLastError();
        CancelIoEx(generic_, &overlapped);
        // OVERLAPPED and buffer must outlive completion, including cancellation.
        GetOverlappedResult(generic_, &overlapped, &received, TRUE);
        if (wait == WAIT_TIMEOUT) throw NativeError("timeout", "HID response timed out");
        Fail("WaitForSingleObject", error);
      }
      if (!GetOverlappedResult(generic_, &overlapped, &received, FALSE)) Fail("GetOverlappedResult");
    }
    if (received != 65 || report[0] != 0) throw NativeError("report", "Expected report ID 0 and 64 payload bytes");
    return Value(std::vector<uint8_t>(report.begin() + 1, report.end()));
  }
  if (method == "getFeature" || method == "setFeature") {
    const int id = Integer(args, "reportId");
    if (id != 0x40 && id != 0x41) throw NativeError("argument", "Only feature reports 0x40 and 0x41 are allowed");
    const int index = id - 0x40;
    if (features_[index] == INVALID_HANDLE_VALUE) throw NativeError("unsupported", "Feature collection is unavailable");
    std::vector<uint8_t> report(feature_lengths_[index], 0);
    report[0] = static_cast<uint8_t>(id);
    if (method == "setFeature") {
      const int value = Integer(args, "value");
      if ((id == 0x40 && (value < 1 || value > 3)) || (id == 0x41 && (value < 0 || value > 100))) {
        throw NativeError("argument", "Feature value is out of range");
      }
      report[1] = static_cast<uint8_t>(value);
      if (!HidD_SetFeature(features_[index], report.data(), static_cast<ULONG>(report.size()))) Fail("HidD_SetFeature");
      return Value();
    }
    if (!HidD_GetFeature(features_[index], report.data(), static_cast<ULONG>(report.size()))) Fail("HidD_GetFeature");
    if (report[0] != id) throw NativeError("report", "Feature report ID mismatch");
    return Value(static_cast<int32_t>(report[1]));
  }
  throw NativeError("unsupported", "Unknown HID method");
}
