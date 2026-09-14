#ifndef RUNNER_HID_BRIDGE_H_
#define RUNNER_HID_BRIDGE_H_

#include <windows.h>
#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <condition_variable>
#include <functional>
#include <memory>
#include <mutex>
#include <queue>
#include <thread>

// All HID handles belong to the single worker. Flutter replies are delivered
// only on the platform thread via the runner's message loop.
class HidBridge {
 public:
  static constexpr UINT kCompleteMessage = WM_APP + 72;
  HidBridge(flutter::BinaryMessenger* messenger, HWND window);
  ~HidBridge();
  void DrainCompletions();

 private:
  using Value = flutter::EncodableValue;
  using Map = flutter::EncodableMap;
  using Result = flutter::MethodResult<Value>;
  struct Job { std::string method; Map args; std::shared_ptr<Result> result; };
  void Worker();
  Value Run(const std::string& method, const Map& args);
  void CloseHandles();
  HWND window_;
  std::unique_ptr<flutter::MethodChannel<Value>> channel_;
  std::mutex mutex_;
  std::condition_variable ready_;
  std::queue<Job> jobs_;
  std::queue<std::function<void()>> completions_;
  bool stopping_ = false;
  std::thread worker_;
  HANDLE generic_ = INVALID_HANDLE_VALUE;
  HANDLE features_[2] = {INVALID_HANDLE_VALUE, INVALID_HANDLE_VALUE};
  USHORT feature_lengths_[2] = {0, 0};
};
#endif
