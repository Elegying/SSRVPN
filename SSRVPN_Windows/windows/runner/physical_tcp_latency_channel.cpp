#include "physical_tcp_latency_channel.h"
#include "physical_tcp_latency_probe.h"

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <atomic>
#include <thread>
#include <vector>

namespace {
constexpr UINT_PTR kTimer = 0x5353564c;
std::atomic<int> active_workers{0};
using Value = flutter::EncodableValue;
using Result = flutter::MethodResult<Value>;
struct Work { std::atomic<int> value{-2}; };
struct Pending {
  std::shared_ptr<Work> work;
  std::unique_ptr<Result> result;
  ULONGLONG deadline;
};
int ReadInt(const flutter::EncodableMap& args, const char* key) {
  auto found = args.find(Value(key));
  if (found == args.end()) return 0;
  const auto* value = std::get_if<int32_t>(&found->second);
  return value ? *value : 0;
}
}  // namespace

struct PhysicalTcpLatencyChannel::State {
  HWND window;
  flutter::MethodChannel<Value> channel;
  std::vector<Pending> pending;

  State(flutter::BinaryMessenger* messenger, HWND hwnd)
      : window(hwnd), channel(messenger, "com.ssrvpn/physical_latency",
                             &flutter::StandardMethodCodec::GetInstance()) {
    channel.SetMethodCallHandler([this](const flutter::MethodCall<Value>& call,
                                        std::unique_ptr<Result> result) {
      if (call.method_name() != "probe") { result->NotImplemented(); return; }
      const auto* args = call.arguments() ? std::get_if<flutter::EncodableMap>(call.arguments()) : nullptr;
      if (!args) { result->Success(Value(-1)); return; }
      const auto host_entry = args->find(Value("server"));
      const auto* host = host_entry == args->end() ? nullptr : std::get_if<std::string>(&host_entry->second);
      const int port = ReadInt(*args, "port");
      const int timeout = ReadInt(*args, "timeoutMs");
      if (!host || !physical_tcp_latency::ValidArguments(*host, port, timeout) ||
          pending.size() >= 16 || !SetTimer(window, kTimer, 20, nullptr)) {
        result->Success(Value(-1)); return;
      }
      if (active_workers.fetch_add(1) >= 16) {
        active_workers.fetch_sub(1);
        result->Success(Value(-1)); return;
      }
      auto work = std::make_shared<Work>();
      try {
        // Detached workers own only plain native data, never the window or
        // Flutter callbacks. UI delivery and destruction stay on the UI thread.
        std::thread([work, server = *host, port, timeout]() {
          int value = -1;
          try { value = physical_tcp_latency::Probe(server, port, timeout); } catch (...) { }
          work->value.store(value);
          active_workers.fetch_sub(1);
        }).detach();
      } catch (...) {
        active_workers.fetch_sub(1);
        result->Success(Value(-1)); return;
      }
      pending.push_back({work, std::move(result), GetTickCount64() + timeout});
    });
  }

  ~State() {
    channel.SetMethodCallHandler(nullptr);
    KillTimer(window, kTimer);
  }

  void Poll() {
    for (auto it = pending.begin(); it != pending.end();) {
      int value = it->work->value.load();
      if (value == -2 && GetTickCount64() >= it->deadline) value = -1;
      if (value == -2) { ++it; continue; }
      it->result->Success(Value(value));
      it = pending.erase(it);
    }
    if (pending.empty()) KillTimer(window, kTimer);
  }
};

PhysicalTcpLatencyChannel::PhysicalTcpLatencyChannel(flutter::BinaryMessenger* messenger, HWND window)
    : state_(std::make_unique<State>(messenger, window)) {}
PhysicalTcpLatencyChannel::~PhysicalTcpLatencyChannel() = default;
bool PhysicalTcpLatencyChannel::HandleMessage(UINT message, WPARAM wparam) {
  if (message != WM_TIMER || wparam != kTimer) return false;
  state_->Poll();
  return true;
}
