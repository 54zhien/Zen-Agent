# 0005 — 思考档位采用 RequestConfigSeed v2

Status: accepted (2026-10-20)

用户要求思考选择实际改变模型请求，并适配不同模型的三档、四档等能力。现有 v1 seed 没有请求选项；旧程序会忽略未知 JSON 字段。如果只在 v1 增加 effort，旧程序恢复新 Run 时就会静默丢失选项，破坏 Send 冻结约定。

新 Send 写 v2，明确携带可空的 typed thinkingEffort。v1 仍按原格式读取，effort 为 nil；v1 添加显式 effort 时升级为 v2。v2 缺少字段或含未知值视为损坏，未来版本仍拒绝。旧程序会因版本未知拒绝恢复 v2，代价是降级程序不能执行新 Run，优于改写已冻结请求。

选项属于 seed，不复制进 Prompt 或 execution snapshot。Runtime 在原子提交前依据 Provider 的 ModelDescriptor 再校验；每轮请求从同一个 frozen seed 编码。幂等摘要仅在显式 effort 非空时追加带版本的字段，保留既有 nil 请求的摘要。Conversation 冷恢复与 bounded summary 投影包含相同选项，保持 session 可重建性比较的准确性。

不推断 Provider 的实际能力：reasoning 内容输出不代表可调节强度。DeepSeek 依据当前官方文档声明 low/high/max（默认 high）；兼容别名不被标成新的有效强度。无显式选择时省略 wire 选项，维持既有服务端默认行为。
