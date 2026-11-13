# 彩虹 Linux rootfs

[English](README.md) | 简体中文

本仓库为一加平板 Pro（`caihong`）构建 Arch Linux ARM 用户空间、配套的
mainline Linux 内核和 Android boot 镜像。目前属于该设备的开发版本，安装前请先
阅读下方设备状态表。

boot 镜像采用 Android boot image v2 格式，仅包含 Linux `Image` 和 Caihong
设备树，不含 ramdisk。双系统镜像直接挂载 GPT 分区名为 `linux` 的分区：

```text
root=PARTLABEL=linux rootfstype=ext4 rootwait rw
```

单系统镜像则挂载 `PARTLABEL=userdata`。所有可加载驱动、固件和设备专用用户空间
组件都存放在 rootfs 中。

## 设备状态

| 功能 | 状态 | 说明 |
| --- | --- | --- |
| 显示、GPU | 基本正常 | 3000×2120 内屏、Adreno GPU、亮度调节；60/72/96/120 Hz 可无感切换，144 Hz 仍需黑屏模式切换。偶尔仍会出现小面积屏幕花屏。 |
| 触摸与手写笔 | 正常 | 10 点触控、悬停、压感、绘画、休眠恢复、磁吸充电和首次自动配对已验证。 |
| Pogo／蓝牙键盘 | 基本正常 | 顶部按键映射为 F1–F12，搜索键作为 Fn；蓝牙 F4 补偿由系统默认管理，不主动重连附件。标准 F 键优先可在工具箱切换；该模式下 Fn+F4 切换触控板，图标优先时两者互换。按键时触控板仍可能短暂停顿。 |
| Wi-Fi | 基本正常 | 联网、硬件 MAC 和 STA/AP 并发可用；休眠恢复偶尔偏慢，BDF 目前使用兼容的厂商条目而非 Caihong 专属校准。 |
| 蓝牙 | 正常 | 扫描、配对、BLE、HID 和手写笔电量可用。 |
| 摄像头与闪光灯 | 基本正常 | 前后摄全分辨率 NV12 采集已切换到 SM8650 Camera ICP/BPS 硬件 ISP，并已接入 libcamera 与 GStreamer。软件 ISP 及其回退路径均已移除。自动曝光通过抽样输出亮度闭环调节传感器曝光/增益；场景自适应白平衡抽样低饱和度输出像素，在各传感器固定校准基础上调节 BPS 红/蓝增益。前摄 3264x2448、后摄 4208x3120 均已完成约 24 fps 的连续 80 帧验证。硬件 ISP 内部统计尚未开放。 |
| 传感器与霍尔开关 | 正常 | 加速度计、陀螺仪、环境光、自动亮度和保护套霍尔开关可用。 |
| 音频 | 正常 | 麦克风和立体声扬声器可用；音量低于原厂 Android，未包含 Dolby 和完整原厂调音。 |
| USB 与外接显示 | 正常 | USB host/device 控制器和 DP Alt Mode 可用。 |
| CPU 与休眠 | 正常 | CPU 调频以及 `s2idle` 和深度休眠恢复可用；唤醒后网络重连可能较慢。默认关闭 3.3024 GHz boost。 |
| 电池与快充 | 基本正常 | 电量显示以及已测试的 PPS/VOOC 快充可用。VOOC 会按温度限制电流，进入快充时可能记录瞬时重试/故障消息；仍需持续监控。其他充电协议暂未适配。 |
| NPU 与 VPU | 正常 | CDSP/HTP NPU 测试通过，包括 Hexagon v75、QNN 浮点和量化 Conv2d 负载。Iris VPU 的 H.264、HEVC、VP9 和 AV1 硬件解码可通过 V4L2 与 VA-API 使用；Firefox 和 Chrome 均走 VA-API。编码能力尚未验证。 |
| 存储 | 正常 | UFS 存储可用，MCQ 已启用（实测日志为 9 个硬件队列、最大命令深度 64）。设备专属完整频率表仍待补充。 |


## 发布文件

- `caihong-boot-linux-<kernel-release>.img`：双系统镜像，根分区使用
  `linux`。
- `caihong-boot-userdata-<kernel-release>.img`：单系统镜像，根分区使用
  `userdata`。
- `caihong-rootfs-<kernel-release>.ext4.sparse.img.zst`：经过 zstd 压缩的
  Android sparse ext4 rootfs 镜像；先压缩完整镜像，再将大于等于 2 GiB 的压缩
  流拆成按顺序排列的 `.part-00`、`.part-01` 等文件。
- `linux-caihong-<version>-1-aarch64.pkg.tar.zst`：包含两种 boot 镜像
  和配套内核模块的 pacman 软件包。
- `linux-caihong-<version>-1.aarch64.rpm`：供 Fedora 基础 Armada 使用的 RPM，
  内容与 pacman 包相同。
- `caihong-platform-archlinuxarm-<version>.tar.zst`：Caihong 服务、固件、
  工具、Caihong Toolbox、libcamera、Plasma Camera、qbootctl、带 Qualcomm
  CPU 驱动的 power-profiles-daemon、Qualcomm Iris VA-API 驱动和设备集成的
  完整载荷。它既是增量更新包，也是新构建 rootfs
  镜像中设备内容的唯一来源。
- `caihong-npu-<version>-lib[64].tar.zst`：Qualcomm NPU 运行时与 Hexagon DSP
  组件的增量更新载荷。

Release 说明会记录每个资产、重组后 zstd 压缩流和解压后可刷写镜像的 SHA-256，
以及文件系统逻辑大小和实际使用的源码版本。可安装资产不会使用 ZIP 打包。

## 实验性 Armada rootfs

统一发布工作流会在 GitHub ARM64 runner 上同时构建普通的
`caihong-rootfs-*` 和实验性 `caihong-armada-rootfs-*` 镜像。两个 rootfs
构建任务并行执行；CI 源码检查保持独立。

镜像直接使用上游
[`ghcr.io/armada-os/armada:stable`](https://github.com/armada-os/armada)
OCI 镜像，保留 Armada 名称、`armada` 桌面账户、Steam Client、FEX、Proton、
Gamescope、KDE Plasma 以及其他 Armada 组件，并叠加配套的 Caihong 内核模块、
固件、音频、传感器、输入映射和设备工具。每个镜像都会在
`/etc/caihong-rootfs-build-info` 中记录实际解析到的 Armada OCI digest。

该产物是适配现有 Android `linux` 或 `userdata` 分区布局的传统直挂载 ext4
镜像，目前没有启用 Armada 的 bootc 原子更新流程；更新时需要安装重新构建的
镜像。默认 Armada 用户名和密码均为 `armada`，首次启动后应立即修改密码。下方
安装步骤同样适用于 Armada，只需将 `caihong-rootfs-*` 替换为配套的
`caihong-armada-rootfs-*` 文件。

## 安装方法

请严格按步骤操作。错误的重新分区或刷写目标会清除 Android 及设备上的其他数据。

### 前置条件

- bootloader 已解锁。
- 电脑已安装 `adb`、`fastboot` 和 `zstd`。
- Android 与内部存储中的重要数据已经备份。
- boot 镜像与 rootfs 镜像来自同一个 Release。
- 双系统安装需要 GPT 分区名为 `linux` 的分区；如果已经存在，请跳过下面的建分区
  步骤。

### 准备文件

从 Release 下载一个 boot 镜像和全部 rootfs 镜像分片：

- 双系统使用 `caihong-boot-linux-<kernel-release>.img`。
- 单系统使用 `caihong-boot-userdata-<kernel-release>.img`。
- 两种布局共用压缩后的
  `caihong-rootfs-<kernel-release>.ext4.sparse.img.zst`。

逐一对照 Release 说明中的 SHA-256。rootfs 分片不能单独解压或刷写；按编号顺序
重组压缩流并校验，然后解压并校验可刷写的 sparse 镜像：

```sh
sha256sum caihong-boot-*.img caihong-rootfs-*.ext4.sparse.img.zst.part-*
cat caihong-rootfs-*.ext4.sparse.img.zst.part-* \
  > caihong-rootfs.ext4.sparse.img.zst
sha256sum caihong-rootfs.ext4.sparse.img.zst
zstd -d caihong-rootfs.ext4.sparse.img.zst \
  -o caihong-rootfs.ext4.sparse.img
sha256sum caihong-rootfs.ext4.sparse.img
```

如果 Release 直接提供一个未分片的 `.ext4.sparse.img.zst`，直接使用并跳过 `cat`。
Release 说明中会同时列出两个完整文件的摘要。

### 双系统安装

#### 1. 创建或核对 Linux 分区

已有 `linux` 分区时跳过本步骤。否则进入能够运行 `parted` 的 recovery；可以使用
recovery 自带版本，也可以推送兼容的静态二进制：

```sh
adb reboot recovery
adb push /path/to/parted /tmp/parted
adb shell
chmod +x /tmp/parted
/tmp/parted /dev/block/sda
```

先在 `parted` 中查看真实分区表：

```text
unit GB
print
```

具体分区编号与边界取决于设备容量和现有布局。必须保持原 `userdata` 起点不变，选择
能够同时容纳两个系统的分界点，并确保 `linux` 大于 Release 记录的 rootfs 逻辑
大小。执行下面的破坏性命令前，必须替换所有尖括号内容：

```text
rm <userdata-分区编号>
mkpart userdata ext4 <原-userdata-起点> <linux-起点>
mkpart linux ext4 <linux-起点> 100%
print
quit
```

确认新分区名称严格为 `userdata` 和 `linux`，然后返回 bootloader：

```sh
exit
adb reboot bootloader
```

#### 2. 刷写镜像

明确选择 Linux 所在槽位。下面以 B 槽为例；如果为 Linux 保留的是 A 槽，请改为
`a`：

```sh
fastboot devices
fastboot getvar current-slot

fastboot --disable-verity --disable-verification flash vbmeta vbmeta.img

LINUX_SLOT=b
BOOT=caihong-boot-linux-<kernel-release>.img
ROOTFS=caihong-rootfs.ext4.sparse.img

fastboot erase "dtbo_${LINUX_SLOT}"
fastboot flash "boot_${LINUX_SLOT}" "$BOOT"
fastboot flash linux "$ROOTFS"
fastboot --set-active="$LINUX_SLOT"
fastboot reboot
```

只擦除所选 Linux 槽对应的 DTBO。Caihong 设备树已经包含在 boot 镜像内；务必保留
Android 槽的 DTBO。

启动 Caihong 前必须关闭 Android Verified Boot。请使用设备官方 Android 出厂镜像
中配套的 `vbmeta.img`，并加 `--disable-verity --disable-verification` 刷写。如果
跳过这一步，bootloader 可能拒绝自定义 boot 镜像。

### 单系统安装

该方式会覆盖 `userdata` 并删除 Android 用户数据，不需要单独的 `linux` 分区：

```sh
adb reboot bootloader
fastboot devices
fastboot getvar current-slot

fastboot --disable-verity --disable-verification flash vbmeta vbmeta.img

LINUX_SLOT=b
BOOT=caihong-boot-userdata-<kernel-release>.img
ROOTFS=caihong-rootfs.ext4.sparse.img

fastboot erase "dtbo_${LINUX_SLOT}"
fastboot flash "boot_${LINUX_SLOT}" "$BOOT"
fastboot flash userdata "$ROOTFS"
fastboot --set-active="$LINUX_SLOT"
fastboot reboot
```

### 首次启动

镜像内的 ext4 文件系统标签为 `linux`。第一次成功启动时，
`caihong-grow-rootfs.service` 会将文件系统扩展至整个 `linux` 或 `userdata` 分区，
`caihong-mark-boot-successful.service` 会标记实际运行槽启动成功，不需要手动运行
`resize2fs`。

## 默认用户和密码

| 用户 | 密码 | 用途 |
| --- | --- | --- |
| `alarm` | `alarm` | Plasma 桌面用户；属于 `wheel` 组，可使用自身密码运行 `sudo`。 |
| `root` | `root` | 系统管理员用户。 |

以 `alarm` 登录后，请立即修改两个账户的密码：

```sh
passwd
sudo passwd root
```

## Caihong 用户空间工具

rootfs 在 `/usr/local` 中预装以下设备专用工具。修改硬件或启动状态的命令需要
root 权限。

| 工具 | 用途与示例 |
| --- | --- |
| `caihong-slot` | 查看或切换 A/B 槽：`sudo caihong-slot status`、`sudo caihong-slot android --reboot`。 |
| `caihong-flashlight` | 控制后置手电筒：`sudo caihong-flashlight on 40`、`status` 或 `off`。 |
| `caihong-flashlight-panel` | 首次登录时将“手电筒”小程序添加到 Plasma 面板。`--status` 查看是否已添加，`--force` 在移除后重新添加。 |
| `caihong-hotspot` | 在保持 STA 连接的同时启动热点：`sudo caihong-hotspot start`；还支持 `status`、`stop` 和 `regulatory {show\|set CODE\|reset}`。配置文件为 `/etc/caihong-hotspot.conf`。 |
| `caihong-hardware-mac` | 启动时应用 WLAN 与蓝牙地址；优先使用手动配置或认证通过的原厂 NVRAM，读取失败时使用持久化备用地址。 |
| `caihong-npu-info` | `sudo caihong-npu-info` 显示 CDSP 固件状态和 FastRPC 能力；`--self-test` 验证通用 v75 DSP 执行，`--htp-self-test` 验证浮点 QAIRT/QNN 图，`--htp-conv-self-test` 验证量化 Conv2d 并与 CPU 参考结果逐元素比较。 |
| `caihong-bluetooth-autostart` | 启动时打开已经配置地址的蓝牙控制器。 |
| `caihong-charge` | 使用 `status` / `health` 读取电池状态和固件健康数据；`sudo caihong-charge limit 75 80` 设置充电阈值，`sudo caihong-charge bypass on` / `off` 控制停充并保留适配器输入，不承诺电池完全隔离。 |
| `caihong-autocharge` | 可选守护进程，通过切换停充把电量维持在设定的充电区间。使用 `sudo systemctl enable --now caihong-autocharge` 启用，并在 `/etc/caihong-autocharge.json` 中配置 `stop`、`resume` 和 `interval`；`--status` 显示当前判断。默认不启用，也不会修改 `caihong-charge` 已保存的阈值。 |
| `caihong-pen-pair` | 使用通过 CPS8601 磁吸事件校验得到的地址配对手写笔，通常由 systemd 定时器调用。 |
| `caihong-pen-charge` | 执行有时间限制的 CPS8601 充电与吸附观察，通常由 systemd 定时器调用。 |
| `caihong-pen-autoconnect` | 恢复已配对手写笔连接和触摸屏手写笔扫描模式，通常由 systemd 定时器调用。 |
| `caihong-mark-boot-successful` | 记录实际启动槽，并只将该槽标记为启动成功；开机时自动运行。 |
| `caihong-fix-kwin-brightness` | 将参考原厂的环境光曲线写入 `alarm` 用户的 KWin 显示配置。 |
| `caihong-clean-pogo-kde` | 删除不适用于 Pogo 键盘的 KDE 键盘背光操作。 |
| `caihong-nvram-mac` | 位于 `/usr/local/libexec` 的内部读取器，由 `caihong-hardware-mac` 调用。 |
| `caihong-switch-to-android.desktop` | Plasma 应用菜单中的“切换到 Android”入口，通过 polkit 执行 `caihong-slot android --reboot`。 |
| `caihong-toolbox` | 从应用菜单打开 Caihong 图形设置工具。硬件修改经其 D-Bus/Polkit 后台执行；后台不启用为开机服务。 |

首次登录后，Plasma 面板会添加一个**手电筒**小程序，包含后置手电筒开关和亮度
滑块。该小程序安装在系统目录中，因此也可以在**添加部件**中找到。每个用户只会
自动添加一次；如果手动移除，之后登录不会再次添加。可用
`caihong-flashlight-panel --force` 或“添加部件”重新添加。

rootfs 还包含 Caihong SSC 服务、定制 libcamera、Plasma Camera 集成、
Caihong Toolbox、设备固件、音频拓扑和匹配的内核模块。

ADB 使用 `oplusboot.serialno` 中的设备序列号作为 USB 序列号，缺失时回退到
`androidboot.serialno`。若要覆盖，可在 `/etc/caihong-adbd-serial` 写入一行
不含空白的值，该值会原样使用。两个来源都不可用时，会根据 machine-id 派生
稳定的 `caihong-<machine-id 前缀>` 串号；只有 machine-id 也无效时才回退为
`caihong-adb`。

默认自动充电，不额外限制电量。只有显式使用 `--save` 保存设置并启用
`caihong-charge.service` 才会在开机时恢复；该服务默认不启用。
固件报告的健康度和容量不是独立测得的电池损耗。

`caihong-autocharge` 是可选的守护进程，与内核阈值二选一使用：控制器的原始
电量达到 `stop` 时停充，降到 `resume` 时恢复充电。它读取
`/etc/caihong-autocharge.json`（默认 `stop` 80、`resume` 79、`interval` 30 秒），
只在状态变化时调用 `caihong-charge bypass`。该服务默认不启用，安装后仍保持
原厂充电行为，直到执行 `sudo systemctl enable --now caihong-autocharge`。
使用 `sudo systemctl disable --now caihong-autocharge` 关闭；停充仍不承诺
电池硬件隔离。

### WLAN 与蓝牙地址回退

`caihong-hardware-mac` 分别按以下优先级选择 WLAN 与蓝牙地址：

1. 可选配置文件 `/etc/caihong-hardware-mac.conf` 中人工确认的地址。
   可以只设置其中一项；该文件不会作为 shell 脚本执行。
2. 冗余 NVRAM 中通过完整认证的原厂地址。
3. 首次需要时生成的两个不同的本地管理单播地址，保存在
   `/var/lib/caihong-hardware-mac/addresses`，以后启动重复使用，不会每次随机更换。

手动配置格式如下，地址仅为示例，请换成本机地址，勿多机共用：

```ini
WLAN_MAC=02:12:34:56:78:90
BLUETOOTH_MAC=02:12:34:56:78:91
```

地址使用六组十六进制、冒号分隔，不加引号，等号两侧不留空格，两个地址不能相同。
保存后重启生效。

备用地址不是恢复出的原厂地址，不会写回 `nonmodemst1/2`，也不会绕过 NVRAM 认证。
若要恢复原厂地址，可先从同机原厂 Android 或已配对主机的历史记录核对，再填入配置文件；
不要直接使用别台设备或固件中的通用示例地址。
配置或已保存地址损坏时会报错，不会静默更换蓝牙身份。
请保留备用地址文件；删除它、重装系统或改回原厂地址可能需要重新配对。
应用地址会中断 WLAN 或蓝牙连接，首次验证应在本机终端进行，不要依赖当前 SSH 会话。

## 内核升级

Arch Linux ARM 安装使用 Release 中的 pacman 软件包升级内核、设备树和模块：

```sh
sudo pacman -U ./linux-caihong-*-aarch64.pkg.tar.zst
```

基于 Fedora 的 Armada 安装使用匹配的 RPM：

```sh
sudo dnf install ./linux-caihong-*-1.aarch64.rpm
```

软件包会读取本次启动时记录的实际槽位，根据根分区是 `linux` 还是 `userdata`
选择镜像，只写入当前运行槽并读回校验。它不会修改 A/B 槽的 active、bootable 或
successful 标记。

## 设备组件更新

已刷入 rootfs 的设备不需要重刷。按顺序安装对应的平台载荷和 NPU 载荷：

```sh
sudo /usr/libexec/caihong-platform/install-caihong-platform \
  ./caihong-platform-archlinuxarm-<version>.tar.zst
sudo pacman -U ./linux-caihong-<version>-1-aarch64.pkg.tar.zst
sudo /usr/libexec/caihong-platform/install-caihong-platform \
  ./caihong-npu-<version>-lib.tar.zst
```

安装器会校验 manifest，并把被覆盖文件备份到
`/var/lib/caihong-packages/<component>/previous`。systemd 候选配置暂存在
`/var/lib/caihong-config-pending/<component>/etc/systemd`，其他 `/etc` 配置以
`<file>.caihong-new` 保存，供手动审阅。旧版本遗留的候选文件需手动整理。Armada 使用
`caihong-platform-armada-<version>.tar.zst`。如需恢复上一版文件，运行
`install-caihong-platform --rollback <component>`。

平台包包含 SSC 传感器默认数据，安装时补齐 `/var/lib/caihong-ssc/root` 下缺失的
文件，并保留已有的传感器配置和校准数据。

Arch Linux ARM 安装平台更新包时还会安装、启用 Plasma Login Manager 并移除
SDDM；管理员已选择其他显示管理器时保留原选择。全新镜像在打包时启用 PLM。

同一个更新交付物包含内核 RPM。Armada 基于 Fedora：用事务安装器安装
`caihong-platform-armada-<version>.tar.zst`，再用 DNF 安装
`linux-caihong-<version>-1.aarch64.rpm`。

## 本地构建

在 AArch64 主机上安装原生 GCC、Python 3、bsdtar、zstd、kmod、alsa-utils、
e2fsprogs 和 Android sparse 镜像工具（`img2simg`）；其他架构还需要 AArch64
交叉编译器和 QEMU user-mode。脚本会自动选择原生或交叉工具链：

```sh
scripts/checkout-dependencies.sh
scripts/build-kernel-release.sh
sudo -E scripts/build-caihong-platform-package.sh release
scripts/build-caihong-npu-package.sh release
sudo -E env CHROOT_TOOL=chroot MODULE_TREE="$PWD/modules-current" \
  OUTPUT_FORMAT=ext4 SPARSE_IMAGE=1 \
  scripts/package-archlinuxarm-rootfs.sh \
  "release/caihong-rootfs-$(cat release/KERNEL_RELEASE).ext4.sparse.img"
```

GitHub Actions 使用原生 AArch64 构建，并在不同运行之间保存 ccache。每个
Release 说明都会记录实际使用的各组件提交。统一发布工作流会并行构建两份
rootfs；Armada rootfs 文件名以 `caihong-armada-rootfs-` 开头。
Actions artifacts 按发布文件逐个原样上传，不再合并成一个 ZIP，可按需下载
启动镜像、对应发行版的 rootfs 或更新包，保留 3 天。已有的 `.zst` 压缩和分卷格式不变；
分卷 rootfs 仍需下载同一套的全部分卷。

## 许可证

项目编写的构建脚本和工具采用 GPL-2.0-only，除非文件中另有 SPDX 声明。随附
设备固件仍受厂商条款约束。Armada 项目代码采用
GPL-2.0-or-later，所包含的各组件保留自身条款；上游 Armada 包含的 Steam Client
是专有软件，仍受 Valve 适用的 Steam 协议和分发条款约束。
