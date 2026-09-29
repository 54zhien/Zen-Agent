---
status: accepted
date: 2026-09-30
---

# Card Delete 在计时器丢失后由用户处置

## 决定

App Space 的 Card Delete 提交时，仍原子保存 `pendingDeletion` 和 10 秒绝对截止时间。进程内计时器完成撤销窗口后，才尝试原子最终删除。冷启动或前台恢复时如果原计时器已丢失，保留正文和资产，显示「保留会话」「确认删除」；不依据墙上时钟自动清理。两种明确处置都在持久事务中检查当前生命周期与删除意图。

## 依据与取舍

原 Blueprint 要求冷启动按持久截止时间清理过期项，同时要求时钟异常时保留正文。仅有墙上时钟截止时间时，这两项无法同时保证：用户调快时间与真实经过十秒在重启后可能呈现相同的持久数据。Apple 的 [Task.sleep(for:)](https://developer.apple.com/documentation/swift/task/sleep%28for%3Atolerance%3Aclock%3A%29) 默认使用连续时钟，但 [ContinuousClock](https://developer.apple.com/documentation/swift/continuousclock) 的 Instant 只在程序执行期间可比较；[ProcessInfo.systemUptime](https://developer.apple.com/documentation/foundation/processinfo/systemuptime) 从系统重启重新计时，不能单独证明跨重启的经过时间。

选择保留正文，需要用户在恢复后多做一次明确操作。代价是有些实际超过十秒的待删除数据会保留更久。相反，按无法验证的时间自动删除可能永久清理完整 Conversation。保留持久截止时间供诊断和界面说明，但它不再是计时器丢失后的自动清理授权。

## 边界

- 进程内计时器仍按提交后的十秒窗口收口；前后台切换若计时器存活，不产生新的窗口。
- 计时器丢失后，不把「保留会话」伪装成仍在十秒内的普通 Undo；它是恢复处置。
- 存储失败时维持 `pendingDeletion` 与正文，处置可重试。
- 此决定只涉及 Card Delete；普通生命周期删除及 FileAsset 的独立所有权保持原语义。
