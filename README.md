# TourMix

**TourMix** 是一款专为 **TourBox Lite** 与 **RME Fireface UCX（TotalMix FX 2.10+）** 打造的原生 macOS 菜单栏监听与按键控制软件（Swift 6 + AppKit + SwiftUI，零第三方依赖）。

## 核心特性

- **原生底层串口直连**：基于 `IOKit`（`VID:PID = 0xCAFE:0x4001`）自动发现设备、支持 USB 热插拔与系统睡眠唤醒自愈，内置四阶段解锁握手与 `40 ms` 污染帧隔离保护。
- **TotalMix FX `Global OSC` 双向同步**：支持 RME 1023 级非线性推子分贝曲线、冷启动防跳变保护、`220 ms` 乐观防抖与停手 `/sendchan` 权威校准。
- **录音棚级旋钮手感**：基于脉冲时间间隔 $\Delta t$ 的三级动态转速加速（慢拧精调 `0.5 dB` / `0.2 dB`，快拧顺滑加速，换向首格自动重置）与 **`0.0 dB` 过载安全限位锁**。
- **全屏无焦点毛玻璃 HUD**：采用 `.nonactivatingPanel` + `.fullScreenAuxiliary`，在全屏 DAW / 剪辑软件中实时显示分贝进度与刻度，绝不抢夺键盘焦点。
- **可视化矢量按键工作台**：1:1 还原 TourBox Lite 机身轮廓，支持真机操作实时高亮、多预设管理，以及扩展绑定 RME 通道静音、子混音发送、监听室开关（Dim / Mono / Speaker B）、快照调用、电脑快捷键与系统媒体键。

## TotalMix FX 首次设置（macOS）

1. 打开 `Totalmix.app`，菜单栏勾选 **`Options → Enable OSC Control`**。
2. 打开 **`Options → Mixer Settings...`**（快捷键 `F3`），切换到 **`OSC`** 标签页（选择 `Remote Controller 1`）：
   - 勾选 **`In Use`**
   - **`Port (incoming)`**: `7001` ｜ **`Port (outgoing)`**: `9001`
   - **`Remote Controller Address`**: `127.0.0.1`
   - **`Compatibility (Mode)`**: 选择 **`Global OSC`**
   - *（推荐）* 点击 **`Details`**：勾选 `Re-send received` 与 `Receive to hidden channels`。

## 编译、测试与安装

要求：macOS 14.0+（Apple Silicon），Xcode / Swift 6.0+。

```bash
# 运行全部自动化单元测试
swift test

# 编译 Release 应用包并签名安装到 /Applications/TourMix.app
./scripts/build_app.sh --install
```

配置文件默认保存在 `~/Library/Application Support/TourMix/config.json`。
