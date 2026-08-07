# Mouse Display Lock

macOS 菜单栏应用，将鼠标光标限制在指定显示器边界内，避免在多屏环境下误划到其他屏幕。专为游戏玩家设计（如 LOL），不影响游戏中鼠标操作手感。

## 功能

- 一键锁定鼠标到当前所在显示器
- 支持指定应用：仅在前台应用为指定程序时启用边界限制
- 软边界模式：基于 CGEventTap 预拦截 + 异步 Warp，无卡顿、无边界突破
- 菜单栏图标实时反映状态（未锁定 / 等待应用 / 边界激活 / 应用未激活）
- 全局快捷键开关

## 系统要求

- macOS 14.0+（推荐 macOS 15+）
- 需要授予「辅助功能」权限

## 安装

### 方式 1：自行编译

```bash
git clone https://github.com/<your-username>/MouseDisplayLock.git
cd MouseDisplayLock
open MouseDisplayLock.xcodeproj
```

在 Xcode 中 `⌘R` 编译运行即可。

### 方式 2：下载预编译版本

前往 [Releases](../../releases) 下载最新的 `MouseDisplayLock.app.zip`，解压后拖入「应用程序」文件夹。

首次启动需在「系统设置 → 隐私与安全性 → 辅助功能」中授权。

## 使用说明

1. 启动后菜单栏出现锁形图标
2. 点击图标打开菜单：
   - **锁定当前显示器**：立即将鼠标限制在当前所在屏幕
   - **选择触发应用**：可选指定应用（如 LOL），仅在该应用前台时启用限制
   - **解锁**：解除限制
3. 鼠标被限制时图标变为 `lock.fill`

## 技术实现

### 架构

```
┌─────────────────────────────────────────────────┐
│  EventTap 线程 (userInteractive QoS)            │
│  ─ 拦截鼠标事件，累加 delta 到目标位置            │
│  ─ 边界 clamp                                    │
└──────────────────┬──────────────────────────────┘
                   │ positionLock
┌──────────────────▼──────────────────────────────┐
│  Warp 定时器线程 (250Hz, userInteractive QoS)   │
│  ─ 读取最新位置                                   │
│  ─ CGDisplayMoveCursorToPoint 移动光标           │
└─────────────────────────────────────────────────┘
```

### 关键设计

- **CGEventTap 预拦截**：在系统处理事件前修改光标位置，防止边界突破
- **线程分离**：EventTap 线程只做 delta 累加（零 IPC），Warp 在独立线程异步执行，避免 8000Hz 鼠标事件被 IPC 阻塞
- **dissociated 鼠标模式**：`CGAssociateMouseAndMouseCursorPosition(0)` 解耦物理鼠标与光标，由我们完全接管光标位置
- **异步 Warp**：`DispatchSourceTimer` 以 250Hz（4ms）节流 Warp 频率，匹配 160Hz 显示器刷新率
- **QoS 对齐**：EventTap 线程与 Warp 线程均为 `.userInteractive`，避免优先级反转

### 诊断日志

应用内置诊断统计，每秒输出一次到 stdout：

```
📊 [Stats] 事件 980Hz | Warp 247Hz | 最大间隔 事件5ms Warp4ms | 锁等待0ms | Warp耗时3ms
```

异常时即时输出：
- `⚠️ [EventTap] 事件间隔 Xms` — EventTap 线程被阻塞
- `⚠️ [Delta] 锁等待 Xms` — 锁竞争
- `⚠️ [Warp] 触发间隔 Xms` — warpQueue 调度延迟
- `⚠️ [Warp] 执行 Xms` — CGDisplayMoveCursorToPoint IPC 耗时

查看日志：
- Xcode 运行：底部 Debug Console
- 已运行 App：`log stream --predicate 'process == "MouseDisplayLock"' --level info`

## 项目结构

```
MouseDisplayLock/
├── MouseDisplayLockApp.swift   # 主程序：UI、事件处理、边界限制
├── Assets.xcassets/            # 资源（AppIcon、AccentColor）
├── MouseDisplayLock.xcodeproj/
├── .github/workflows/          # CI/CD
└── README.md
```

## 开发

### 编译

```bash
xcodebuild -project MouseDisplayLock.xcodeproj \
  -scheme MouseDisplayLock \
  -configuration Debug \
  build \
  CODE_SIGNING_ALLOWED=NO
```

### 产物位置

```
~/Library/Developer/Xcode/DerivedData/MouseDisplayLock-*/Build/Products/Debug/MouseDisplayLock.app
```

## 许可证

MIT License
