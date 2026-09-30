// 生成「Agent 完成」提示音：用系统自带的 GM 音源（gs_instruments.dls）离线渲染一小段 MIDI。
// 不引入任何音频素材/依赖，声音本身是可复现的——改几个音符就能换旋律。
//
//   swift render_agent_done.swift AgentDone.aiff
//
// 当前采用 fate 预设：木琴「登·登·登·灯——」，三下同音后落下小三度并叠一记低八度，
// 和 macOS 自带提示音都不像 —— 一听就知道是「agent 跑完了」。
import AVFoundation
import Foundation

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AgentDone.aiff"
// 预设：fate = 登登登·灯（三短一长下行，**当前采用**）；triple = 同音三连；bell = 钟琴上行
let preset = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "fate"
let dls = URL(fileURLWithPath: "/System/Library/Components/CoreAudio.component/Contents/Resources/gs_instruments.dls")

let sampleRate = 44100.0
let engine = AVAudioEngine()
let sampler = AVAudioUnitSampler()
engine.attach(sampler)
guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
    fatalError("无法建立输出格式")
}
engine.connect(sampler, to: engine.mainMixerNode, format: format)

// GM 音色（bank MSB 0x79 = 旋律音色库）：12=Marimba(木质"登")、14=Tubular Bells、9=Glockenspiel
let program: UInt8 = (preset == "bell") ? 9 : 12
try sampler.loadSoundBankInstrument(at: dls, program: program,
                                    bankMSB: UInt8(kAUSampler_DefaultMelodicBankMSB),
                                    bankLSB: UInt8(kAUSampler_DefaultBankLSB))
sampler.overallGain = -3     // dB。别做得比系统提示音还响：这一声是"顺耳提醒"，
                             // 不是警报；太冲的话半夜跑 agent 会被吓一跳（实测 +6 就过了）。

try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
try engine.start()

/// (起始秒, 音高, 力度, 时值秒)
let (notes, totalSeconds): ([(Double, UInt8, UInt8, Double)], Double)
switch preset {
case "fate":   // 登登登·灯——三短一长，最后落下小三度
    notes = [(0.00, 67, 88, 0.16), (0.14, 67, 88, 0.16), (0.28, 67, 90, 0.16),
             (0.46, 63, 94, 0.70), (0.46, 51, 78, 0.70)]
    totalSeconds = 1.9
case "bell":   // 钟琴三音上行 + 八度收尾
    notes = [(0.00, 72, 100, 0.30), (0.09, 76, 108, 0.30),
             (0.18, 79, 115, 0.35), (0.30, 84, 100, 0.60)]
    totalSeconds = 1.6
default:       // triple：登·登·登——同音三连，低八度叠音加厚
    notes = [(0.00, 64, 110, 0.22), (0.00, 52, 95, 0.22),
             (0.16, 64, 112, 0.22), (0.16, 52, 95, 0.22),
             (0.32, 64, 118, 0.50), (0.32, 52, 105, 0.50)]
    totalSeconds = 1.5
}

let outURL = URL(fileURLWithPath: out)
try? FileManager.default.removeItem(at: outURL)
// 用 Optional 持有：写完置 nil 触发 deinit，AIFF 头才会被回填（否则文件头里的长度是 0）。
var file: AVAudioFile? = try AVAudioFile(forWriting: outURL, settings: [
    AVFormatIDKey: kAudioFormatLinearPCM,
    AVSampleRateKey: sampleRate,
    AVNumberOfChannelsKey: 2,
    AVLinearPCMBitDepthKey: 16,
    AVLinearPCMIsFloatKey: false,
    AVLinearPCMIsBigEndianKey: true,      // AIFF
])

guard let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat,
                                    frameCapacity: engine.manualRenderingMaximumFrameCount) else {
    fatalError("无法建立渲染缓冲")
}

// 手动推进渲染时钟：每渲染一块之前，把落在这一块时间窗内的 note on/off 发给采样器。
var pending = notes.flatMap { [(Double($0.0), $0.1, $0.2, true), ($0.0 + $0.3, $0.1, $0.2, false)] }
    .sorted { $0.0 < $1.0 }
var rendered: AVAudioFramePosition = 0
let totalFrames = AVAudioFramePosition(totalSeconds * sampleRate)
while rendered < totalFrames {
    let now = Double(rendered) / sampleRate
    while let first = pending.first, first.0 <= now {
        if first.3 { sampler.startNote(first.1, withVelocity: first.2, onChannel: 0) }
        else { sampler.stopNote(first.1, onChannel: 0) }
        pending.removeFirst()
    }
    let frames = AVAudioFrameCount(min(AVAudioFramePosition(buffer.frameCapacity), totalFrames - rendered))
    let status = try engine.renderOffline(frames, to: buffer)
    guard status == .success else { fatalError("渲染失败: \(status.rawValue)") }
    try file?.write(from: buffer)
    rendered += AVAudioFramePosition(frames)
}
engine.stop()
file = nil
print("写出 \(out)（\(String(format: "%.1f", totalSeconds))s, \(Int(sampleRate))Hz 立体声 16bit AIFF）")
