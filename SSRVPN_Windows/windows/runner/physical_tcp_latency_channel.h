#ifndef SSRVPN_PHYSICAL_TCP_LATENCY_CHANNEL_H_
#define SSRVPN_PHYSICAL_TCP_LATENCY_CHANNEL_H_

#include <flutter/binary_messenger.h>
#include <windows.h>
#include <memory>

class PhysicalTcpLatencyChannel {
 public:
  PhysicalTcpLatencyChannel(flutter::BinaryMessenger* messenger, HWND window);
  ~PhysicalTcpLatencyChannel();
  bool HandleMessage(UINT message, WPARAM wparam);

 private:
  struct State;
  std::unique_ptr<State> state_;
};

#endif
