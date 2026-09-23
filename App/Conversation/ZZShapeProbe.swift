// 一次性探针（第 4 轮）：用 CGFloat 变量（模拟真实代码）测准最终可用写法。
// 只存在于探针分支，不进任何正式提交。
import SwiftUI

struct T01: View { var body: some View { let r: CGFloat = 18; Color.clear
    .clipShape(ConcentricRectangle(corners: .fixed(r))) } }

struct T02: View { var body: some View { let r: CGFloat = 18; Color.clear
    .clipShape(ConcentricRectangle(corners: .concentric(minimum: .fixed(r)))) } }

struct T03: View { var body: some View { let r: CGFloat = 18; Color.clear
    .contentShape(ConcentricRectangle(corners: .fixed(r))) } }

struct T04: View { var body: some View { let r: CGFloat = 18; Color.clear
    .contentShape(ConcentricRectangle(corners: .concentric(minimum: .fixed(r)))) } }

struct T05: View { var body: some View { let r: CGFloat = 18; Color.clear
    .containerShape(.rect(cornerRadii: .init(topLeading: r, bottomLeading: r, bottomTrailing: r, topTrailing: r), style: .continuous)) } }

struct T06: View { var body: some View { Color.clear
    .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous)) } }

struct T07: View { var body: some View { let r: CGFloat = 18; Color.clear
    .clipShape(ConcentricRectangle(corners: .concentric(minimum: .fixed(r)), isUniform: true)) } }

struct T08: View { var body: some View { let r: CGFloat = 18; Color.clear
    .background(.regularMaterial, in: ConcentricRectangle(corners: .fixed(r))) } }
