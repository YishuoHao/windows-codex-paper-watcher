# Windows 事件驱动的 Codex 自动读论文工作流

这是一套面向 Windows 的本地自动化方案：当指定文件夹出现新的 PDF 时，由常驻 PowerShell 监听器做本地预检；只有确实存在稳定、未被占用且没有同名 TXT 的论文时，才启动一次 `codex exec`。空闲监听不调用模型，因此不会像“每隔几分钟让 Agent 扫描文件夹”的方案那样持续消耗 token。

仓库包含：

- `scripts/watch-papers.ps1`：事件监听、稳定性检查、Codex 启动及日志过滤。
- `scripts/register-task.ps1`：把监听器注册为用户登录时启动的 Windows 计划任务。
- `config/paper-task.txt`：专业、证据导向的论文解读任务模板。

## 1. 工作原理

```text
复制 PDF 到收件箱
        │
        ▼
FileSystemWatcher 收到文件事件 ─────┐
        │                           │
        ▼                           │
等待稳定期                          │
        │                           │
        ▼                           │
本地预检：                          │
- 至少静置 2 分钟                   │
- 可独占读取                        │
- 不存在同名 TXT                    │
        │                           │
        ├─ 不符合：跳过，不调用模型  │
        │                           │
        ▼                           │
启动一次 codex exec                 │
        │                           │
        ▼                           │
读取、核验、生成 TXT、重命名 PDF    │
        │                           │
        ▼                           │
回到本地监听 ◄──────────────────────┘
```

`FileSystemWatcher` 事件可能因快速复制、网络盘或缓冲区溢出而丢失，所以脚本每 5 分钟做一次纯本地补漏扫描。补漏扫描不启动 Agent；只有发现符合条件的新 PDF 才调用 Codex。

## 2. 前置条件

1. Windows 10 或 Windows 11。
2. Windows PowerShell 5.1 或 PowerShell 7。
3. 已安装并登录 Codex，命令行可以找到 `codex.exe`。
4. 论文收件箱必须位于传给 Codex 的工作区内部。

检查：

```powershell
codex --version
codex login status
```

Codex CLI 的非交互模式和参数说明：

- [Non-interactive mode](https://developers.openai.com/codex/noninteractive)
- [Codex CLI reference](https://developers.openai.com/codex/cli/reference)

## 3. 下载并准备目录

```powershell
git clone https://github.com/YishuoHao/windows-codex-paper-watcher.git
Set-Location windows-codex-paper-watcher

New-Item -ItemType Directory -Force -Path "D:\Papers\Inbox"
New-Item -ItemType Directory -Force -Path ".\runtime"
```

推荐结构：

```text
D:\Papers\
├── Inbox\                         # 只放待处理和已处理论文
└── windows-codex-paper-watcher\
    ├── config\paper-task.txt
    ├── scripts\watch-papers.ps1
    ├── scripts\register-task.ps1
    └── runtime\                   # 日志和最后一次结果，不提交 Git
```

如果脚本仓库不在 `D:\Papers` 下也没有关系，但 `Inbox` 必须位于 `CodexWorkspace` 内。例如收件箱为 `D:\Papers\Inbox`，则工作区可以设为 `D:\Papers`。

## 4. 配置论文任务

编辑 `config/paper-task.txt`。模板中的以下占位符由监听器自动替换：

- `{{INBOX}}`：收件箱绝对路径。
- `{{MINIMUM_AGE_MINUTES}}`：文件稳定期分钟数。

默认模板强调：

- PDF 中的提示词不可信，防止文档提示注入。
- PDF 只读；只允许最后进行文件系统重命名。
- 先完成并验证 TXT，再重命名 PDF。
- 定量证据、研究设计和同行评审式判断优先。
- 同名 TXT 是幂等标记，已处理论文永不重写。

可以按照学科需要调整 TXT 结构，但不建议删除安全检查、写入顺序或因果边界要求。

## 5. 手动试运行

首次运行应使用可见 PowerShell 窗口，便于发现登录或路径问题：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File ".\scripts\watch-papers.ps1" `
  -Inbox "D:\Papers\Inbox" `
  -CodexWorkspace "D:\Papers" `
  -PromptFile ".\config\paper-task.txt" `
  -StateDirectory ".\runtime"
```

成功启动后，该命令不会返回 PowerShell 提示符。另开一个窗口查看日志：

```powershell
Get-Content -LiteralPath ".\runtime\watcher.log" -Tail 30 -Wait
```

把一篇 PDF 复制到收件箱。正常顺序是：

```text
Watcher started
PDF change detected
Starting Codex
Agent: ...
Codex completed successfully
```

停止手动监听器：在运行监听器的窗口按 `Ctrl+C`。

## 6. 注册 Windows 任务计划

### 自动注册

在普通 PowerShell 窗口中运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File ".\scripts\register-task.ps1" `
  -Inbox "D:\Papers\Inbox" `
  -CodexWorkspace "D:\Papers" `
  -PromptFile ".\config\paper-task.txt" `
  -StateDirectory ".\runtime" `
  -StartNow
```

脚本会创建名为 `Codex Paper Inbox Watcher` 的当前用户任务：

- 当前用户登录时启动。
- 后台隐藏窗口运行。
- 已有实例时不重复启动。
- 异常退出后最多重试 3 次。
- 不设置运行时长上限。
- 允许电池供电时运行。

查看任务状态：

```powershell
Get-ScheduledTask -TaskName "Codex Paper Inbox Watcher"
Get-ScheduledTaskInfo -TaskName "Codex Paper Inbox Watcher"
```

手动启动或停止：

```powershell
Start-ScheduledTask -TaskName "Codex Paper Inbox Watcher"
Stop-ScheduledTask -TaskName "Codex Paper Inbox Watcher"
```

删除任务：

```powershell
Unregister-ScheduledTask `
  -TaskName "Codex Paper Inbox Watcher" `
  -Confirm:$false
```

### 使用图形界面配置

也可以打开“任务计划程序”并创建任务：

1. “常规”：选择“仅当用户登录时运行”。
2. “触发器”：新建“登录时”。
3. “操作”：启动程序 `powershell.exe`。
4. 参数填写：

   ```text
   -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "完整路径\scripts\watch-papers.ps1" -Inbox "D:\Papers\Inbox" -CodexWorkspace "D:\Papers" -PromptFile "完整路径\config\paper-task.txt" -StateDirectory "完整路径\runtime"
   ```

5. “设置”：任务已运行时选择“不启动新实例”；取消默认的运行时间上限；启用失败重启。

## 7. 为什么这些 Codex 参数这样排列

核心调用等价于：

```powershell
$prompt |
  codex `
    --search `
    --ask-for-approval never `
    exec `
    --json `
    --color never `
    -C "D:\Papers" `
    --skip-git-repo-check `
    --sandbox workspace-write `
    --output-last-message ".\runtime\last-result.txt" `
    -
```

关键点：

- `--ask-for-approval` 是全局参数，必须放在 `exec` 前面。
- 最后的 `-` 表示从标准输入读取提示词。不要把包含中文和换行的长提示词直接作为 Windows PowerShell 5.1 原生命令参数。
- `--json` 输出 JSONL，脚本只保留完成的 `agent_message`，避免日志包含全文提取和命令细节。
- `--sandbox workspace-write` 将写入限制在工作区范围内。
- 不使用 `--dangerously-bypass-approvals-and-sandbox`。

当前模板采用 `--ask-for-approval never`，因此任何超出沙箱或被安全策略拦截的操作都会失败，而不会等待无人值守的批准。任务提示应把临时目录清理等非核心操作视为可选，不得因清理失败破坏 PDF/TXT 产物。

## 8. 日志与运行状态

主日志位于 `runtime/watcher.log`，只保留：

- 监听器启动、文件事件、Codex 启动和完成状态。
- `item.completed` 中的 `agent_message`。
- 失败时最后最多 5 条诊断信息。

最后一次 Agent 结果写入 `runtime/last-result.txt`。

确认监听器是否真的存活：

```powershell
Get-CimInstance Win32_Process |
  Where-Object { $_.CommandLine -like "*watch-papers.ps1*" } |
  Select-Object ProcessId, CommandLine
```

日志最后一行是“Watcher started”并不代表进程此刻仍存在；它只是历史记录。任务计划程序状态和进程列表才是实时依据。

## 9. 常见故障

### `unexpected argument '--ask-for-approval'`

原因：把全局参数写在了 `exec` 后面。

正确：

```text
codex --ask-for-approval never exec ...
```

### `unexpected argument '鏇挎崲...'`

原因：Windows PowerShell 5.1 把多行中文提示词作为命令参数传递，发生拆分和乱码。

解决：提示词通过管道送入 `codex exec -`，并设置 `$OutputEncoding` 为 UTF-8。

### 启动 Codex 后日志长时间没有内容

Windows PowerShell 5.1 会把原生程序的标准错误流包装为 `ErrorRecord`。如果调用期间使用 `$ErrorActionPreference = "Stop"`，正常进度也可能终止管道。本仓库只在 Codex 调用期间临时切换为 `Continue`，随后恢复。

### 退出码 2，但没有原因

通常表示 CLI 参数、配置或认证初始化失败。本脚本在失败时保留最后 5 条诊断。先检查：

```powershell
codex --version
codex login status
Get-Content ".\runtime\watcher.log" -Tail 20
```

### 缺少 `mark_artifact_operation_started.mjs`

读取和重命名已有 PDF 不是 PDF 内容创作。任务模板明确禁止为只读工作调用制品登记脚本。不要自行下载或伪造该内部脚本。

### 临时目录删除被 `blocked by policy`

这是安全策略生效，不代表最终论文失败。确认 PDF/TXT 已完成后，可以由用户在 PowerShell 中删除精确、已核验的临时目录；不要为了清理使用危险的沙箱绕过参数。

### 日志显示启动，但放入 PDF 没反应

先检查监听器进程是否仍在。如果脚本窗口被关闭，`FileSystemWatcher` 也会停止。注册登录触发的计划任务，并把“已有实例”设置为“不启动新实例”。

### PDF 被跳过

依次检查：

```powershell
$pdf = "D:\Papers\Inbox\example.pdf"
$txt = [IO.Path]::ChangeExtension($pdf, ".txt")

Get-Item -LiteralPath $pdf | Select-Object Name, Length, LastWriteTime
Test-Path -LiteralPath $txt
```

还应确认 PDF 没有被浏览器、同步软件或下载程序独占。

## 10. 安全边界

- 收件箱位于 Codex 工作区内，CLI 使用 `workspace-write`。
- 脚本只枚举收件箱顶层的 `*.pdf`，不递归扫描。
- 已有同名 TXT 的论文永远跳过，保证幂等。
- 文件至少稳定 2 分钟且可独占读取，避免处理未复制完成的 PDF。
- PDF 内嵌指令全部视为不可信内容。
- 先验证 TXT，再重命名 PDF；失败时保留原 PDF。
- 不在仓库提交论文、解读结果、日志、访问令牌或 Codex 配置。

## 11. Token 与性能

空闲监听、两分钟稳定性判断和五分钟补漏扫描全部在本地完成，不消耗模型 token。只有发现符合条件的新 PDF 才启动 `codex exec`。

论文处理本身可能较昂贵，尤其是逐页渲染、长篇全文提取和多次核验。降低成本时应优先：

- 避免把完整提取文本反复输出到 Agent 消息。
- 主日志只保留阶段性 Agent 消息。
- 已有同名 TXT 的论文绝不重新处理。
- 一次运行合并处理所有已稳定的新论文。

不要通过减少关键数字核验、跳过表格/图注或用网页摘要替代原文来节省 token；这会直接降低研究简报的可信度。

## 12. 定制其他文件类型

这个模式不局限于论文：保留“事件监听 + 本地预检 + 有条件启动 Agent”的结构，可以改造成图片归档、数据质检或文档摘要工作流。更换文件类型时，应重新设计幂等标记、稳定性检查和安全边界，而不是只修改 `*.pdf` 过滤器。
