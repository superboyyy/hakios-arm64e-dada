# metal2vulkan 升级试验（2026-10-29，只在 Mac 上，没上手机）

从 720ef1c（10-14，Data A Live 固定的版本）升到上游 master 0dfdbcd（10-28），中间 775 个提交。

## 位置（都不影响现有构建）

- 源码：`src/metal2vulkan-next`，分支 `dada-next`，每个补丁一个提交
- bridge 适配补丁：`patches/nativemetal-next/0201-m2v-0dfdbcd-api.patch`（能打在当前 `src/nativemetal` 上）
- 构建脚本：`build/next/build_bridge_next.sh host|ios`，输出到 `out/next/bridge/{host,ios}`，target 目录是 `build/next/m2v-target`
- 对比结果：`test/next/ab_*.log`

## 补丁去向

| 补丁 | 结果 |
| --- | --- |
| UniXNU 0001、0002、我们的 0102 | 直接打上 |
| UniXNU 0004、我们的 0103 | 三方合并打上 |
| 我们的 0101（大常量表进 blob） | 手工移植（上游代码只差上下文） |
| UniXNU 0006（管线为空时跳过 draw） | 不需要：上游 d7d4870 起，创建失败的 draw 会被丢掉，并记 `draw-dropped-unmade` |
| UniXNU 0007（`_RB4` 双平面 RGB surface） | 不需要：上游不再用 OSType 白名单，除压缩格式外都接受 |
| UniXNU 0008、0016（填充行纹理直接别名，16x4 tile 写回检查） | 没移植：上游删了 `PaddedReadsPolicy`，`linear_plan::holding` 重写了；现在一律走影子图像，相当于原来的 `pandora_m2v_padded=shadow` |
| UniXNU 0003、0005、0009–0015（预热缓存、减少每次 draw 的分配、保留 draw 列表、跳过没变的重复绑定、tracker 的 KeyMap 等） | 没移植：都是性能补丁，上游相关代码大改，要逐个重写 |

bridge 侧：`MetalLevel` 被删（上游固定按 macOS 27.0.1 回答）；`padded_targets` / `render_store_alignment` / `refuse_rebinds` 这几个选项不存在了；`SharedEventListener::new()` 不再返回 Result。

## 验证（Mac，MoltenVK，mtl_ab 和 Apple GPU 逐像素对比）

| 库 | 旧（720ef1c） | 新（0dfdbcd） |
| --- | --- | --- |
| rb | 32 同 / 0 差 | 32 同 / 0 差 |
| qc | 115 同 / 3 差（narrow_blur half） | 116 同 / 0 差 |
| space_00 | 7 同 / 3 差（Flocon） | 10 同 / 0 差 |

host 和 iOS arm64e（pauthtest）bridge 都能编译通过。

## 从上游 AdrenoMetal 移植的三项（10-29 14:20）

补丁在 `patches/nativemetal-next/`，都能打在 14:16 的 `src/nativemetal` 上。0202、0203 只改 .mm 和 .h，不依赖 metal2vulkan 升级，可以单独用在现在的构建上。

| 项目 | 结果 |
| --- | --- |
| 0202 返回拒绝 encoder，不返回 nil | 已移植。Mac 测试：encoder 不是 nil，`methodForSelector:` 取得到 IMP，后续调用不崩，command buffer 以错误结束（status 5），下一个 buffer 正常完成 |
| 0203 第一个问题 | 部分移植。我们的 NBLOG 本来就把每个问题当场写到 console；只补了每个进程一行 `first problem: ...`（跳过 "no device answer"），外加 `native_bridge_metal_first_problem()`。上游那套走内核标记流的上报方式我们用不了 |
| 设备属性回答缓存 | 不用改：Data A Live 早已加过同样的缓存（`askAnswer`，每对 selector 和参数只问一次，被拒的也记住） |

验证：host 的 frontend_host 和 carenderer_host 都 PASS，强制拒绝 encoder 的测试也通过；iOS arm64e 插件 `out/next/plugin/RedwoodMetal.bundle` 能编出来。手机上还没跑。

## 还没做

- Turnip/A830 上的编译检查（test/run_tu.sh 用新的 SPIR-V），以及上手机测试
- 性能：render server 的帧时间，没有 0008–0015 时可能变慢，要在手机上量
- 上游 0a18511（no-copy 导入被拒时改成复制）和前端里 GPU 会话加的 no-copy 镜像，两者的关系需要理清
