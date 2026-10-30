# hakios-arm64e-dada：在小米 15 上运行 iOS 26

[English](README.md) | 简体中文

在小米 15（代号 dada，骁龙 8 至尊版 SM8750）上启动 Apple 开源的 XNU 内核（xnu-12377.121.6，即 iOS 26 的内核），并运行 iOS 26 的 arm64e 用户态。

本项目基于 [HakiOS](https://github.com/oosexgang/hakios-xnu-kernel)。在此之上加入了 arm64e、iOS 26 以及 dada 机型的支持。

> 实验性项目。需要解锁 Bootloader，可能导致数据丢失，甚至变砖。请确保有一定的折腾能力和风险承受能力。

## 现状

| 部分 | 状态 |
| --- | --- |
| CPU | 在 Oryon 核心上原生运行 arm64e：8 核全部启动（含超大核），使用硬件 PAC，通过 SCMI 调频至 3.52 GHz，没有指令翻译 |
| 启动 | 自研 EFI 引导器，从 Mu-Silicium UEFI 启动；iOS 镜像放在 Android DSU 分区里 |
| 系统 | iOS 26 能进入主屏幕，触摸可用，按需读写闪存 |
| GPU | Adreno 830 已经上电。Metal 依次经过 metal2vulkan（Metal→Vulkan）、Turnip、内核驱动，最后在 Adreno 上执行 |
| 液态玻璃 | 核心着色器能正确翻译（在 Mac 上和 Apple GPU 逐像素对比）；仍有问题需要调试 |
| 音频 | ADSP、AudioReach 和 CS35L43 功放组成的扬声器播放链路已打通；系统声音和麦克风还在适配 |
| 电池 | 电量计已接入 iOS |
| WiFi / 蓝牙 | 蓝牙能工作。WiFi 能走到 WMI，但固件在大多数运行中会崩溃。注意：当前内核源码里的 WiFi 驱动是临时版本 |
| HDR、相机、基带 | 尚未开始 |

## 目录

| 目录 | 内容 | 许可证 |
| --- | --- | --- |
| `kernel/` | `xnu-12377.121.6-dada.patch`：相对 Apple xnu-12377.121.6 的全部内核修改；`apply.sh` 用来生成内核源码树 | APSL 2.0 |
| `base/` | HakiOS 内核仓库及我们的修改：EFI 引导器（`xnuloader/`）、构建与烧录工具（`tools/dada-*.sh`）、设备配置、文档 | 沿用 HakiOS（APSL 2.0） |
| `userland/` | HakiOS 用户态及我们的修改：iOS 26 启动、注入、Metal 插件、音频 HAL 插件 | 沿用 HakiOS |
| `gpu2/` | GPU 路线：分别对 metal2vulkan、UniXNU NativeMetal、Mesa Turnip 的补丁，以及构建脚本 | 各补丁沿用所改项目的许可证，见 NOTICE.md |
| `tools/` | `export-from-work.sh` 从工作目录重新导出本仓库；`check-publishable.sh` 在提交前检查有没有不能公开的文件 | MIT |

## 本项目不包含

本仓库不含任何 Apple、高通、小米或其他厂商的二进制文件或固件。

## 致谢

- [HakiOS](https://github.com/oosexgang/hakios-xnu-kernel)：本项目的基础
- [UniXNU](https://github.com/UniXNU/UniXNU)：NativeAdreno / NativeMetal、Ath12kWifi、骁龙平台参考
- [Data A Live](https://github.com/ShueiTsuki/data-a-live)：骁龙 8 Elite Gen 5 上 iOS 的 GPU、音频与调频参考
- [metal2vulkan](https://github.com/steelbrain/metal2vulkan)：Metal 到 Vulkan 的翻译层
- [Mesa](https://mesa3d.org/)（Turnip / freedreno）
- [Project Silicium / Mu-Silicium](https://github.com/Project-Silicium/Mu-Silicium)
- Linux 内核的 msm、ath12k、qcom 驱动：寄存器布局和上电顺序参考

驱动是参照 Linux 的公开资料编写的。具体说明见 NOTICE.md。

Apple、iOS、Metal 是 Apple Inc. 的商标。本项目与 Apple、高通、小米均无关联。
