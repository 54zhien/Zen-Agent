// 一次性探针：目的只有一个——让 CI 的 swiftc 逐行告诉我 ConcentricRectangle /
// Edge.Corner.Style / containerShape 在 CI 所用 SDK 上的合法写法。
// 本文件只存在于探针分支，不进任何正式提交。每行独立，编译器会逐行报错。
import SwiftUI

struct Probe01: View { var body: some View { Color.clear
    .containerShape(ConcentricRectangle()) } }

struct Probe02: View { var body: some View { Color.clear
    .containerShape(ConcentricRectangle(corners: .concentric)) } }

struct Probe03: View { var body: some View { Color.clear
    .containerShape(ConcentricRectangle(corners: .concentric(minimum: 18))) } }

struct Probe04: View { var body: some View { Color.clear
    .containerShape(ConcentricRectangle(corners: 18)) } }

struct Probe05: View { var body: some View { Color.clear
    .containerShape(.rect(corners: .concentric(minimum: 18))) } }

struct Probe06: View { var body: some View { Color.clear
    .containerShape(.rect(corners: .concentric)) } }

struct Probe07: View { var body: some View { Color.clear
    .containerShape(RoundedRectangle(cornerRadius: 18, style: .continuous)) } }

struct Probe08: View { var body: some View { Color.clear
    .clipShape(ConcentricRectangle(corners: .concentric)) } }

struct Probe09: View { var body: some View { Color.clear
    .background(.regularMaterial, in: .rect(corners: .concentric(minimum: 18))) } }

struct Probe10: View { var body: some View { Color.clear
    .containerShape(ConcentricRectangle(corners: .concentric(minimum: .init(18)))) } }

struct Probe11: View { var body: some View { Color.clear
    .containerShape(ConcentricRectangle(corners: [.concentric(minimum: 18)])) } }

struct Probe12: View { var body: some View { Color.clear
    .containerShape(.rect(cornerRadii: .init(topLeading: 18, bottomLeading: 18, bottomTrailing: 18, topTrailing: 18), style: .continuous)) } }
