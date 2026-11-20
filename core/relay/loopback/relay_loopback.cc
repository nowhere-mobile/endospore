// relay_loopback: the two-process loopback call of slice R1 (NWP-20261210-12, docs/call-relay.md section 14).
//
//   relay_loopback --role offer|answer --sock <path> [--seconds N] [--out <wav>]
//
// Two processes, one PeerConnection each, one Opus audio track each way, over DTLS-SRTP on 127.0.0.1 with no
// STUN and no TURN server. The answer side listens on the Unix socket <path>; SDP and ICE candidates go over it
// as frames (1 type byte, a 4-byte big-endian length, the payload; at most 64 KiB). Each side's audio comes from
// webrtc's TestAudioDeviceModule with a capturer that emits a 1 kHz sine; what each side receives is written to
// <out> as a 48 kHz mono WAV. N seconds (default 10) after the call connects, the answer side measures what it
// received (RMS level in dBFS and the dominant frequency) and prints
//   LOOPBACK <PASS|FAIL> level=<dBFS> freq=<Hz>
// It exits 0 only when the call negotiated Opus over DTLS-SRTP, the level is above -40 dBFS and the frequency
// is within 1000 +/- 20 Hz. The offer side exits 0 when its call connected and the answer side said it is done.
//
// Least knowledge: a candidate that is not a UDP host candidate on 127.0.0.1 is neither sent nor accepted, and
// webrtc's own log is off. The output holds counts and levels only: no SDP, candidate, key or sample.
//
// Built by core/relay/build/build-libwebrtc.sh against the pinned WebRTC revision (libwebrtc.pin).

#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <cctype>
#include <cerrno>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <memory>
#include <mutex>
#include <span>
#include <sstream>
#include <string>
#include <thread>
#include <utility>
#include <vector>

#include "api/audio/audio_device.h"
#include "api/audio_codecs/builtin_audio_decoder_factory.h"
#include "api/audio_codecs/builtin_audio_encoder_factory.h"
#include "api/audio_options.h"
#include "api/candidate.h"
#include "api/create_peerconnection_factory.h"
#include "api/dtls_transport_interface.h"
#include "api/environment/environment.h"
#include "api/environment/environment_factory.h"
#include "api/jsep.h"
#include "api/make_ref_counted.h"
#include "api/media_stream_interface.h"
#include "api/media_types.h"
#include "api/peer_connection_interface.h"
#include "api/rtc_error.h"
#include "api/rtp_parameters.h"
#include "api/rtp_sender_interface.h"
#include "api/rtp_transceiver_interface.h"
#include "api/scoped_refptr.h"
#include "api/set_local_description_observer_interface.h"
#include "api/set_remote_description_observer_interface.h"
#include "modules/audio_device/include/test_audio_device.h"
#include "rtc_base/buffer.h"
#include "rtc_base/ip_address.h"
#include "rtc_base/logging.h"
#include "rtc_base/network_constants.h"
#include "rtc_base/socket_address.h"
#include "rtc_base/thread.h"

namespace {

using Clock = std::chrono::steady_clock;

constexpr int kRate = 48000;
constexpr double kToneHz = 1000.0;
constexpr double kToneAmplitude = 0.5;  // of full scale: about -9 dBFS RMS
constexpr double kPassLevelDbfs = -40.0;
constexpr double kFreqToleranceHz = 20.0;
constexpr double kFloorDbfs = -120.0;
constexpr int kArrivalThreshold = 300;  // |sample| above this marks the first received audio
constexpr int kSettleMs = 500;          // skipped after the first received audio
constexpr size_t kMaxFrame = 64 * 1024;
constexpr auto kConnectTimeout = std::chrono::seconds(30);
constexpr double kPi = 3.14159265358979323846;

enum FrameType : char { kOffer = 'O', kAnswer = 'A', kCandidate = 'C', kDone = 'D' };

struct Args {
  std::string role;
  std::string sock;
  std::string out;
  int seconds = 10;
};

bool ParseArgs(int argc, char** argv, Args* a) {
  for (int i = 1; i < argc; ++i) {
    std::string k = argv[i];
    if (i + 1 >= argc) return false;
    std::string v = argv[++i];
    if (k == "--role") {
      a->role = v;
    } else if (k == "--sock") {
      a->sock = v;
    } else if (k == "--out") {
      a->out = v;
    } else if (k == "--seconds") {
      char* end = nullptr;
      long n = std::strtol(v.c_str(), &end, 10);
      if (end == v.c_str() || *end != '\0' || n < 1 || n > 600) return false;
      a->seconds = static_cast<int>(n);
    } else {
      return false;
    }
  }
  if (a->role != "offer" && a->role != "answer") return false;
  if (a->sock.empty()) return false;
  if (a->role == "answer" && a->out.empty()) return false;
  return true;
}

// ---- signalling over the Unix socket ------------------------------------------------------------------------

bool WriteAll(int fd, const char* p, size_t n) {
  while (n > 0) {
    ssize_t w = ::send(fd, p, n, MSG_NOSIGNAL);
    if (w < 0 && errno == EINTR) continue;
    if (w <= 0) return false;
    p += w;
    n -= static_cast<size_t>(w);
  }
  return true;
}

bool ReadAll(int fd, char* p, size_t n) {
  while (n > 0) {
    ssize_t r = ::read(fd, p, n);
    if (r < 0 && errno == EINTR) continue;
    if (r <= 0) return false;
    p += r;
    n -= static_cast<size_t>(r);
  }
  return true;
}

class Signal {
 public:
  ~Signal() { Close(); }

  // Answer side: listen on `path` and accept one peer before `deadline`.
  bool Listen(const std::string& path, Clock::time_point deadline) {
    sockaddr_un addr;
    if (!Address(path, &addr)) return false;
    ::unlink(path.c_str());
    int lfd = ::socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (lfd < 0) return false;
    if (::bind(lfd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) != 0 || ::listen(lfd, 1) != 0) {
      ::close(lfd);
      return false;
    }
    bool ok = false;
    while (Clock::now() < deadline) {
      pollfd p{lfd, POLLIN, 0};
      int r = ::poll(&p, 1, 200);
      if (r < 0 && errno != EINTR) break;
      if (r > 0) {
        fd_ = ::accept4(lfd, nullptr, nullptr, SOCK_CLOEXEC);
        ok = fd_ >= 0;
        break;
      }
    }
    ::close(lfd);
    ::unlink(path.c_str());
    return ok;
  }

  // Offer side: connect to `path`, retrying until `deadline` (the answer side may not be listening yet).
  bool Connect(const std::string& path, Clock::time_point deadline) {
    sockaddr_un addr;
    if (!Address(path, &addr)) return false;
    while (Clock::now() < deadline) {
      int fd = ::socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
      if (fd < 0) return false;
      if (::connect(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) == 0) {
        fd_ = fd;
        return true;
      }
      ::close(fd);
      std::this_thread::sleep_for(std::chrono::milliseconds(100));
    }
    return false;
  }

  bool Send(char type, const std::string& payload) {
    if (payload.size() > kMaxFrame) return false;
    std::lock_guard<std::mutex> lock(write_mu_);
    if (fd_ < 0) return false;
    const uint32_t n = static_cast<uint32_t>(payload.size());
    const char head[5] = {type, static_cast<char>(n >> 24), static_cast<char>(n >> 16),
                          static_cast<char>(n >> 8), static_cast<char>(n)};
    return WriteAll(fd_, head, sizeof(head)) && WriteAll(fd_, payload.data(), payload.size());
  }

  // Reader thread only. False at end of stream, on an error, an unknown type or an oversized frame.
  bool Recv(char* type, std::string* payload) {
    unsigned char head[5];
    if (!ReadAll(fd_, reinterpret_cast<char*>(head), sizeof(head))) return false;
    const uint32_t n = (uint32_t{head[1]} << 24) | (uint32_t{head[2]} << 16) | (uint32_t{head[3]} << 8) |
                       uint32_t{head[4]};
    if (n > kMaxFrame) return false;
    *type = static_cast<char>(head[0]);
    if (*type != kOffer && *type != kAnswer && *type != kCandidate && *type != kDone) return false;
    payload->assign(n, '\0');
    return n == 0 || ReadAll(fd_, payload->data(), n);
  }

  // Unblocks the reader; the descriptor is closed by Close().
  void Shutdown() {
    if (fd_ >= 0) ::shutdown(fd_, SHUT_RDWR);
  }

  void Close() {
    std::lock_guard<std::mutex> lock(write_mu_);
    if (fd_ >= 0) ::close(fd_);
    fd_ = -1;
  }

 private:
  static bool Address(const std::string& path, sockaddr_un* addr) {
    std::memset(addr, 0, sizeof(*addr));
    addr->sun_family = AF_UNIX;
    if (path.empty() || path.size() >= sizeof(addr->sun_path)) return false;
    std::memcpy(addr->sun_path, path.c_str(), path.size());
    return true;
  }

  int fd_ = -1;
  std::mutex write_mu_;
};

// ---- audio ---------------------------------------------------------------------------------------------------

class SineCapturer : public webrtc::TestAudioDeviceModule::Capturer {
 public:
  int SamplingFrequency() const override { return kRate; }
  int NumChannels() const override { return 1; }
  bool Capture(webrtc::BufferT<int16_t>* buffer) override {
    const size_t n = webrtc::TestAudioDeviceModule::SamplesPerFrame(kRate);
    buffer->SetSize(n);
    int16_t* d = buffer->data();
    const double step = 2.0 * kPi * kToneHz / kRate;
    for (size_t i = 0; i < n; ++i) {
      d[i] = static_cast<int16_t>(std::lround(kToneAmplitude * 32767.0 * std::sin(phase_)));
      phase_ += step;
      if (phase_ >= 2.0 * kPi) phase_ -= 2.0 * kPi;
    }
    return true;
  }

 private:
  double phase_ = 0.0;
};

// Keeps what the ADM plays out (the decoded far end). Bounded, so a stuck run cannot grow it without end.
class Recorder : public webrtc::TestAudioDeviceModule::Renderer {
 public:
  explicit Recorder(size_t max_samples) : max_samples_(max_samples) {}
  int SamplingFrequency() const override { return kRate; }
  int NumChannels() const override { return 1; }
  bool Render(std::span<const int16_t> data) override {
    std::lock_guard<std::mutex> lock(mu_);
    const size_t room = max_samples_ - samples_.size();
    const size_t n = data.size() < room ? data.size() : room;
    samples_.insert(samples_.end(), data.begin(), data.begin() + static_cast<std::ptrdiff_t>(n));
    return true;
  }
  std::vector<int16_t> Snapshot() {
    std::lock_guard<std::mutex> lock(mu_);
    return samples_;
  }

 private:
  const size_t max_samples_;
  std::mutex mu_;
  std::vector<int16_t> samples_;
};

bool WriteWav(const std::string& path, const std::vector<int16_t>& s) {
  FILE* f = std::fopen(path.c_str(), "wb");
  if (!f) return false;
  auto u32 = [f](uint32_t v) {
    const unsigned char b[4] = {static_cast<unsigned char>(v), static_cast<unsigned char>(v >> 8),
                                static_cast<unsigned char>(v >> 16), static_cast<unsigned char>(v >> 24)};
    std::fwrite(b, 1, 4, f);
  };
  auto u16 = [f](uint16_t v) {
    const unsigned char b[2] = {static_cast<unsigned char>(v), static_cast<unsigned char>(v >> 8)};
    std::fwrite(b, 1, 2, f);
  };
  const uint32_t data_bytes = static_cast<uint32_t>(s.size() * 2);
  std::fwrite("RIFF", 1, 4, f);
  u32(36 + data_bytes);
  std::fwrite("WAVEfmt ", 1, 8, f);
  u32(16);
  u16(1);  // PCM
  u16(1);  // mono
  u32(kRate);
  u32(kRate * 2);
  u16(2);
  u16(16);
  std::fwrite("data", 1, 4, f);
  u32(data_bytes);
  for (int16_t v : s) u16(static_cast<uint16_t>(v));
  return std::fclose(f) == 0;
}

double GoertzelPower(const std::vector<double>& x, double hz) {
  const double c = 2.0 * std::cos(2.0 * kPi * hz / kRate);
  double s1 = 0.0, s2 = 0.0;
  for (double v : x) {
    const double s0 = v + c * s1 - s2;
    s2 = s1;
    s1 = s0;
  }
  return s1 * s1 + s2 * s2 - c * s1 * s2;
}

struct Measure {
  double level_dbfs = kFloorDbfs;
  double freq_hz = 0.0;
  size_t analysed = 0;
};

// Level and dominant frequency of what was received, from the first received audio plus a settle interval.
Measure Analyse(const std::vector<int16_t>& s) {
  Measure m;
  size_t start = 0;
  while (start < s.size() && std::abs(static_cast<int>(s[start])) <= kArrivalThreshold) ++start;
  start += static_cast<size_t>(kRate) * kSettleMs / 1000;
  if (start >= s.size()) return m;
  m.analysed = s.size() - start;
  double sum = 0.0;
  for (size_t i = start; i < s.size(); ++i) sum += static_cast<double>(s[i]) * s[i];
  const double rms = std::sqrt(sum / static_cast<double>(m.analysed)) / 32768.0;
  m.level_dbfs = rms > 0.0 ? std::max(kFloorDbfs, 20.0 * std::log10(rms)) : kFloorDbfs;
  // At most 2 s, Hann-windowed: a coarse scan every 5 Hz, then 0.1 Hz steps around the peak.
  const size_t n = std::min(m.analysed, static_cast<size_t>(2 * kRate));
  if (n < 2) return m;
  std::vector<double> x(n);
  for (size_t i = 0; i < n; ++i) {
    const double w = 0.5 - 0.5 * std::cos(2.0 * kPi * static_cast<double>(i) / static_cast<double>(n - 1));
    x[i] = w * s[start + i];
  }
  double best = 0.0, best_hz = 0.0;
  for (double hz = 50.0; hz <= 8000.0; hz += 5.0) {
    const double p = GoertzelPower(x, hz);
    if (p > best) {
      best = p;
      best_hz = hz;
    }
  }
  const double lo = best_hz - 5.0, hi = best_hz + 5.0;
  for (double hz = lo; hz <= hi; hz += 0.1) {
    const double p = GoertzelPower(x, hz);
    if (p > best) {
      best = p;
      best_hz = hz;
    }
  }
  m.freq_hz = best_hz;
  return m;
}

// ---- the peer ------------------------------------------------------------------------------------------------

bool LoopbackUdpHost(const webrtc::Candidate& c) {
  const webrtc::SocketAddress& a = c.address();
  return c.type() == webrtc::IceCandidateType::kHost && c.protocol() == "udp" && a.family() == AF_INET &&
         webrtc::IPIsLoopback(a.ipaddr()) && a.ipaddr().ToString() == "127.0.0.1";
}

bool EqualsNoCase(const std::string& a, const char* b) {
  if (a.size() != std::strlen(b)) return false;
  for (size_t i = 0; i < a.size(); ++i) {
    if (std::tolower(static_cast<unsigned char>(a[i])) != std::tolower(static_cast<unsigned char>(b[i]))) {
      return false;
    }
  }
  return true;
}

// The SDP's audio section uses DTLS-SRTP (UDP/TLS/RTP/SAVPF with a fingerprint) and its first codec is Opus.
bool SdpIsOpusOverDtlsSrtp(const std::string& sdp) {
  std::istringstream in(sdp);
  std::string line, pt;
  bool audio = false, fingerprint = false, opus = false, savpf = false;
  while (std::getline(in, line)) {
    if (!line.empty() && line.back() == '\r') line.pop_back();
    if (line.rfind("m=", 0) == 0) {
      audio = line.rfind("m=audio ", 0) == 0;
      if (audio) {
        std::istringstream m(line);
        std::string media, port, proto;
        m >> media >> port >> proto >> pt;
        savpf = proto == "UDP/TLS/RTP/SAVPF";
      }
      continue;
    }
    if (line.rfind("a=fingerprint:", 0) == 0) fingerprint = true;
    if (audio && !pt.empty() && line.rfind("a=rtpmap:" + pt + " ", 0) == 0) {
      const std::string codec = line.substr(10 + pt.size());
      opus = EqualsNoCase(codec.substr(0, codec.find('/')), "opus");
    }
  }
  return savpf && fingerprint && opus;
}

class SldObserver : public webrtc::SetLocalDescriptionObserverInterface {
 public:
  explicit SldObserver(std::function<void(webrtc::RTCError)> fn) : fn_(std::move(fn)) {}
  void OnSetLocalDescriptionComplete(webrtc::RTCError e) override { fn_(std::move(e)); }

 private:
  std::function<void(webrtc::RTCError)> fn_;
};

class SrdObserver : public webrtc::SetRemoteDescriptionObserverInterface {
 public:
  explicit SrdObserver(std::function<void(webrtc::RTCError)> fn) : fn_(std::move(fn)) {}
  void OnSetRemoteDescriptionComplete(webrtc::RTCError e) override { fn_(std::move(e)); }

 private:
  std::function<void(webrtc::RTCError)> fn_;
};

class Peer : public webrtc::PeerConnectionObserver {
 public:
  Peer(bool offerer, Signal* sig) : offerer_(offerer), sig_(sig) {}

  bool Init(std::unique_ptr<webrtc::TestAudioDeviceModule::Renderer> renderer) {
    network_ = webrtc::Thread::CreateWithSocketServer();
    signaling_ = webrtc::Thread::Create();
    if (!network_->Start() || !signaling_->Start()) return false;
    env_ = std::make_unique<webrtc::Environment>(webrtc::CreateEnvironment());
    adm_ = webrtc::TestAudioDeviceModule::Create(*env_, std::make_unique<SineCapturer>(), std::move(renderer));
    factory_ = webrtc::CreatePeerConnectionFactory(network_.get(), signaling_.get(), adm_,
                                                   webrtc::CreateBuiltinAudioEncoderFactory(),
                                                   webrtc::CreateBuiltinAudioDecoderFactory(), nullptr, nullptr,
                                                   nullptr, nullptr);
    if (!factory_) return false;
    // Every adapter type but loopback is ignored; LoopbackUdpHost() then refuses anything else that remains.
    webrtc::PeerConnectionFactoryInterface::Options options;
    options.network_ignore_mask = ~static_cast<int>(webrtc::ADAPTER_TYPE_LOOPBACK);
    factory_->SetOptions(options);

    webrtc::PeerConnectionInterface::RTCConfiguration config;
    config.sdp_semantics = webrtc::SdpSemantics::kUnifiedPlan;
    config.tcp_candidate_policy = webrtc::PeerConnectionInterface::kTcpCandidatePolicyDisabled;
    // No ICE servers: no STUN, no TURN.
    webrtc::PeerConnectionDependencies deps(this);
    auto pc = factory_->CreatePeerConnectionOrError(config, std::move(deps));
    if (!pc.ok()) return false;
    pc_ = pc.MoveValue();

    // The capture is a test tone: no echo canceller, gain control, noise suppression or high-pass on it.
    webrtc::AudioOptions audio;
    audio.echo_cancellation = false;
    audio.auto_gain_control = false;
    audio.noise_suppression = false;
    audio.highpass_filter = false;
    track_ = factory_->CreateAudioTrack("relay-audio", factory_->CreateAudioSource(audio).get());
    return track_ != nullptr;
  }

  // Offer side: add the track (Opus only), create and send the offer.
  bool StartOffer() {
    if (!AddTrack()) return false;
    std::vector<webrtc::RtpCodecCapability> opus;
    for (const auto& c : factory_->GetRtpSenderCapabilities(webrtc::MediaType::AUDIO).codecs) {
      if (EqualsNoCase(c.name, "opus")) opus.push_back(c);
    }
    if (opus.empty()) return false;
    for (const auto& t : pc_->GetTransceivers()) {
      if (t->media_type() == webrtc::MediaType::AUDIO && !t->SetCodecPreferences(opus).ok()) return false;
    }
    pc_->SetLocalDescription(webrtc::make_ref_counted<SldObserver>([this](webrtc::RTCError e) {
      if (!e.ok()) return Fail();
      SendLocalDescription(kOffer);
    }));
    return true;
  }

  // Reader thread: one frame from the far side.
  void OnFrame(char type, const std::string& payload) {
    if (type == kDone) {
      Set(&done_);
    } else if (type == kOffer && !offerer_) {
      ApplyRemote(webrtc::SdpType::kOffer, payload);
    } else if (type == kAnswer && offerer_) {
      ApplyRemote(webrtc::SdpType::kAnswer, payload);
    } else if (type == kCandidate) {
      OnRemoteCandidate(payload);
    } else {
      Fail();
    }
  }

  // Waits for `flag`, or a failure, or `deadline`. True only when `flag` was set without a failure.
  bool WaitFor(const bool* flag, Clock::time_point deadline) {
    std::unique_lock<std::mutex> lock(mu_);
    cv_.wait_until(lock, deadline, [&] { return *flag || failed_; });
    return *flag && !failed_;
  }
  bool Failed() {
    std::lock_guard<std::mutex> lock(mu_);
    return failed_;
  }
  const bool* connected() const { return &connected_; }
  const bool* done() const { return &done_; }

  // Opus over DTLS-SRTP, in both descriptions and on the transport the audio sender uses.
  bool OpusOverDtlsSrtp() {
    return signaling_->BlockingCall([this] {
      std::string local, remote;
      if (!pc_->local_description() || !pc_->local_description()->ToString(&local)) return false;
      if (!pc_->remote_description() || !pc_->remote_description()->ToString(&remote)) return false;
      if (!SdpIsOpusOverDtlsSrtp(local) || !SdpIsOpusOverDtlsSrtp(remote)) return false;
      for (const auto& t : pc_->GetTransceivers()) {
        if (t->media_type() != webrtc::MediaType::AUDIO) continue;
        auto dtls = t->sender()->dtls_transport();
        if (!dtls) return false;
        const webrtc::DtlsTransportInformation info = dtls->Information();
        return info.state() == webrtc::DtlsTransportState::kConnected && info.srtp_cipher_suite().has_value();
      }
      return false;
    });
  }

  void Close() {
    if (pc_) pc_->Close();
    pc_ = nullptr;
    track_ = nullptr;
    factory_ = nullptr;
    adm_ = nullptr;
    if (signaling_) signaling_->Stop();
    if (network_) network_->Stop();
  }

  int sent() const { return sent_; }
  int received() const { return received_; }
  int dropped() const { return dropped_; }

  // webrtc::PeerConnectionObserver
  void OnSignalingChange(webrtc::PeerConnectionInterface::SignalingState) override {}
  void OnDataChannel(webrtc::scoped_refptr<webrtc::DataChannelInterface>) override {}
  void OnIceGatheringChange(webrtc::PeerConnectionInterface::IceGatheringState) override {}
  void OnConnectionChange(webrtc::PeerConnectionInterface::PeerConnectionState s) override {
    using State = webrtc::PeerConnectionInterface::PeerConnectionState;
    if (s == State::kConnected) Set(&connected_);
    if (s == State::kFailed || s == State::kClosed) Fail();
  }
  void OnIceCandidate(const webrtc::IceCandidate* c) override {
    if (!c || !LoopbackUdpHost(c->candidate())) {
      ++dropped_;
      return;
    }
    const std::string payload = c->sdp_mid() + "\n" + std::to_string(c->sdp_mline_index()) + "\n" + c->ToString();
    if (sig_->Send(kCandidate, payload)) ++sent_;
  }

 private:
  bool AddTrack() { return pc_->AddTrack(track_, {"relay"}).ok(); }

  void SendLocalDescription(char type) {
    std::string sdp;
    if (!pc_->local_description() || !pc_->local_description()->ToString(&sdp) || !sig_->Send(type, sdp)) {
      Fail();
    }
  }

  void ApplyRemote(webrtc::SdpType type, const std::string& sdp) {
    auto desc = webrtc::CreateSessionDescription(type, sdp);
    if (!desc) return Fail();
    pc_->SetRemoteDescription(std::move(desc), webrtc::make_ref_counted<SrdObserver>([this, type](webrtc::RTCError e) {
      if (!e.ok()) return Fail();
      FlushCandidates();
      if (type != webrtc::SdpType::kOffer) return;
      // Answer side: the track goes on the transceiver the offer made, so the call is one track each way.
      if (!AddTrack()) return Fail();
      pc_->SetLocalDescription(webrtc::make_ref_counted<SldObserver>([this](webrtc::RTCError e2) {
        if (!e2.ok()) return Fail();
        SendLocalDescription(kAnswer);
      }));
    }));
  }

  void OnRemoteCandidate(const std::string& payload) {
    const size_t a = payload.find('\n');
    const size_t b = a == std::string::npos ? a : payload.find('\n', a + 1);
    if (b == std::string::npos) return Fail();
    char* end = nullptr;
    const std::string index = payload.substr(a + 1, b - a - 1);
    const long mline = std::strtol(index.c_str(), &end, 10);
    if (index.empty() || *end != '\0' || mline < 0 || mline > 16) return Fail();
    auto c = webrtc::IceCandidate::Create(payload.substr(0, a), static_cast<int>(mline), payload.substr(b + 1));
    if (!c || !LoopbackUdpHost(c->candidate())) {
      ++dropped_;
      return;
    }
    ++received_;
    std::vector<std::unique_ptr<webrtc::IceCandidate>> ready;
    {
      std::lock_guard<std::mutex> lock(pending_mu_);
      pending_.push_back(std::move(c));
      if (remote_set_) ready.swap(pending_);
    }
    AddCandidates(std::move(ready));
  }

  // Candidates that arrive before the remote description wait here. The lock is never held across a call into
  // the PeerConnection: the reader thread blocks on the signaling thread there, which may want this lock.
  void FlushCandidates() {
    std::vector<std::unique_ptr<webrtc::IceCandidate>> ready;
    {
      std::lock_guard<std::mutex> lock(pending_mu_);
      remote_set_ = true;
      ready.swap(pending_);
    }
    AddCandidates(std::move(ready));
  }

  void AddCandidates(std::vector<std::unique_ptr<webrtc::IceCandidate>> ready) {
    for (auto& c : ready) {
      pc_->AddIceCandidate(std::move(c), std::function<void(webrtc::RTCError)>([this](webrtc::RTCError e) {
                             if (!e.ok()) Fail();
                           }));
    }
  }

  void Set(bool* flag) {
    {
      std::lock_guard<std::mutex> lock(mu_);
      *flag = true;
    }
    cv_.notify_all();
  }
  void Fail() { Set(&failed_); }

  const bool offerer_;
  Signal* const sig_;
  std::unique_ptr<webrtc::Thread> network_;
  std::unique_ptr<webrtc::Thread> signaling_;
  std::unique_ptr<webrtc::Environment> env_;
  webrtc::scoped_refptr<webrtc::AudioDeviceModule> adm_;
  webrtc::scoped_refptr<webrtc::PeerConnectionFactoryInterface> factory_;
  webrtc::scoped_refptr<webrtc::PeerConnectionInterface> pc_;
  webrtc::scoped_refptr<webrtc::AudioTrackInterface> track_;

  std::mutex mu_;
  std::condition_variable cv_;
  bool connected_ = false;
  bool done_ = false;
  bool failed_ = false;

  std::mutex pending_mu_;
  bool remote_set_ = false;
  std::vector<std::unique_ptr<webrtc::IceCandidate>> pending_;

  std::atomic<int> sent_{0};
  std::atomic<int> received_{0};
  std::atomic<int> dropped_{0};
};

int Run(const Args& args) {
  const bool offerer = args.role == "offer";
  Signal sig;
  const auto connect_deadline = Clock::now() + kConnectTimeout;
  if (!(offerer ? sig.Connect(args.sock, connect_deadline) : sig.Listen(args.sock, connect_deadline))) {
    std::printf("relay_loopback: role=%s signalling=0\n", args.role.c_str());
    if (!offerer) std::printf("LOOPBACK FAIL level=%.1f freq=%.1f\n", kFloorDbfs, 0.0);
    return 1;
  }

  const size_t max_samples = static_cast<size_t>(args.seconds + 60) * kRate;
  auto recorder = std::make_unique<Recorder>(max_samples);
  Recorder* rec = recorder.get();
  Peer peer(offerer, &sig);
  const bool ready = peer.Init(std::move(recorder));

  std::thread reader([&] {
    char type = 0;
    std::string payload;
    while (sig.Recv(&type, &payload)) peer.OnFrame(type, payload);
  });

  bool connected = ready && (!offerer || peer.StartOffer()) && peer.WaitFor(peer.connected(), Clock::now() + kConnectTimeout);
  bool ok = false;
  if (offerer) {
    // The answer side measures for N seconds, then says it is done.
    ok = connected && peer.WaitFor(peer.done(), Clock::now() + std::chrono::seconds(args.seconds + 45));
  } else {
    if (connected) {
      const auto until = Clock::now() + std::chrono::seconds(args.seconds);
      while (Clock::now() < until && !peer.Failed()) std::this_thread::sleep_for(std::chrono::milliseconds(100));
    }
    const std::vector<int16_t> samples = rec->Snapshot();
    const bool secure = connected && !peer.Failed() && peer.OpusOverDtlsSrtp();
    const Measure m = Analyse(samples);
    const bool wav = WriteWav(args.out, samples);
    const bool pass = secure && wav && m.level_dbfs > kPassLevelDbfs && std::fabs(m.freq_hz - kToneHz) <= kFreqToleranceHz;
    std::printf("relay_loopback: role=answer connected=%d opus_dtls_srtp=%d samples=%zu analysed=%zu wav=%d\n",
                connected ? 1 : 0, secure ? 1 : 0, samples.size(), m.analysed, wav ? 1 : 0);
    std::printf("LOOPBACK %s level=%.1f freq=%.1f\n", pass ? "PASS" : "FAIL", m.level_dbfs, m.freq_hz);
    std::fflush(stdout);
    sig.Send(kDone, std::string());
    ok = pass;
  }
  if (offerer && !args.out.empty()) WriteWav(args.out, rec->Snapshot());

  sig.Shutdown();
  reader.join();
  const int sent = peer.sent(), received = peer.received(), dropped = peer.dropped();
  peer.Close();
  sig.Close();
  std::printf("relay_loopback: role=%s connected=%d candidates_sent=%d candidates_received=%d candidates_dropped=%d\n",
              args.role.c_str(), connected ? 1 : 0, sent, received, dropped);
  return ok ? 0 : 1;
}

}  // namespace

int main(int argc, char** argv) {
  Args args;
  if (!ParseArgs(argc, argv, &args)) {
    std::fprintf(stderr,
                 "usage: relay_loopback --role offer|answer --sock <path> [--seconds N] [--out <wav>]"
                 " (--out is required for the answer side; N is 1 to 600, default 10)\n");
    return 2;
  }
  ::signal(SIGPIPE, SIG_IGN);
  webrtc::LogMessage::LogToDebug(webrtc::LS_NONE);
  webrtc::LogMessage::SetLogToStderr(false);
  return Run(args);
}
