# 无人值守远程调试

GUI 运行时会轮询：

- 命令文件：`Logs\LocalDailyGui\debug_commands.jsonl`
- 状态文件：`Logs\LocalDailyGui\debug_status.json`

推荐用辅助脚本发送命令：

```powershell
# 请求 GUI 写入最新状态
.\Scripts\Send-LocalDailyGuiCommand.ps1 status
Get-Content .\Logs\LocalDailyGui\debug_status.json -Raw

# 强制退出单个任务或全部任务
.\Scripts\Send-LocalDailyGuiCommand.ps1 stop -AppId maa
.\Scripts\Send-LocalDailyGuiCommand.ps1 stop_all
.\Scripts\Send-LocalDailyGuiCommand.ps1 clear_queue

# 远程启动；Reason=scheduled 时仍会触发 30 分钟自动强退
.\Scripts\Send-LocalDailyGuiCommand.ps1 start -AppId maa -Reason scheduled

# 远程修改定时
.\Scripts\Send-LocalDailyGuiCommand.ps1 set_schedule -AppId maa -Enabled true -Times "07:00","19:00"

# 强制退出任务后关闭 GUI
.\Scripts\Send-LocalDailyGuiCommand.ps1 exit -Force
```

## 可用 AppId

- `maa-gui`
- `maa`
- `bettergi`
- `wuthering`
- `endfield`
- `nte`

## 状态文件

`debug_status.json` 会记录每个任务的运行状态，包括：

- `running`
- `pid`
- `start_reason`
- `started_at`
- `elapsed_seconds`
- `scheduled_timeout_remaining_seconds`
- `stop_requested`
- `log_file`

也会记录当前定时队列 `pending_scheduled`。无人值守测试时优先读取这个文件判断 GUI 是否仍在轮询、任务是否还在运行、定时强退还剩多久。

## 原始 JSON 命令

辅助脚本也可以直接追加原始 JSON：

```powershell
.\Scripts\Send-LocalDailyGuiCommand.ps1 -RawJson '{"command":"status"}'
.\Scripts\Send-LocalDailyGuiCommand.ps1 -RawJson '{"command":"start","app_id":"maa","reason":"scheduled"}'
```

GUI 启动时会跳过命令文件里已有的历史内容，只处理启动后追加的新行。
