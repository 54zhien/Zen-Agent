---
status: accepted
date: 2026-09-19
---

# Keychain accessibility: `AfterFirstUnlockThisDeviceOnly`

凭据项使用 `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`。本 ADR 记录为什么，
以及两条**会让人写错**的操作性事实。

## 决定

```
kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
```

三个维度各自的取值与理由：

| 维度 | 取值 | 理由 |
|---|---|---|
| **何时可读** | `AfterFirstUnlock`（不是 `WhenUnlocked`） | 后台继续执行是被设计的正式能力。`WhenUnlocked` 在锁屏时读不到，会让后台恢复**天然无法**取到 Token——那不是"更安全"，是把已设计的功能变成不可实现 |
| **是否随设备迁移** | `ThisDeviceOnly`（不随备份迁移） | 蓝图明确禁止为 Secret 默认开启 iCloud Keychain 同步（`安全与权限.md:104`）。`ThisDeviceOnly` 同时排除加密备份迁移 |
| **是否同步** | 不同步 | 同上 |

**没有选择 `Always`**：已废弃，且保护等级更低。

**Apple 自己的表述**：该常量适用于「need to be accessed by background applications」的项
（`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`，iOS 4.0+）。
已核实 iOS 26 **没有引入新的 Keychain accessibility API**——
2026 年的公开动静全部是第三方库在修正自己误用 `WhenUnlocked` 的问题，不是新能力。

## 代价，写清楚

选 `AfterFirstUnlock` 意味着：**设备首次解锁后直到下次重启，锁屏状态下该凭据可被读取**。
比 `WhenUnlocked` 弱。这是为「后台继续执行」付的价，**不是疏忽**。

如果将来决定不做后台继续执行，应当把这条改成 `WhenUnlockedThisDeviceOnly`——
但那是一次真实的安全等级提升，需要重新评估恢复路径。

## 两条操作性事实（凭记忆写会写错）

### 1. 后台读取失败**不等于**凭据不存在

`AfterFirstUnlock` 之下，后台读取仍可能返回 `errSecInteractionNotAllowed`（-25308）——
设备尚未首次解锁，或该项是旧版本用别的属性写入的。

**危险写法**：把读取失败当成"没有凭据"，然后删除并重建。
**删除操作在读取失败时仍然会成功**，于是后台启动一次就会把有效 Token 抹掉。

所以实现必须区分：

- `errSecItemNotFound` → 确实没有
- `errSecInteractionNotAllowed` → **暂时读不到**，不是没有

### 2. `SecItemUpdate` 改不了已存在项的 accessibility 属性

属性只在 `SecItemAdd` 时设定。同一项后续更新只改数据。

本实现因此**始终用同一组属性写入**，不存在"属性需要变更"的路径。
若将来必须改属性，正确做法是 delete + add，且要按第 1 条处理中间态。

## Consequences

- 凭据的存在性判断不能只靠"能不能读到"。
- 后台恢复路径必须能表达"凭据暂时不可用"这一独立状态，而不是把它折叠成"未配置"。
  这与 `Provider 与模型.md` 的 `unavailable` / `re-authentication` 状态是同一件事。
- 设备间迁移后凭据不存在（`ThisDeviceOnly` 的设计后果）。换机 = 需要重新输入凭据，
  这一点必须写进用户可见的说明，不能靠用户自己发现。
