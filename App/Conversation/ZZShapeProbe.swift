// 一次性探针（第 2 轮）：把两件事分开测清楚——
// (1) `.concentric(minimum:)` 的参数到底收什么类型（用 clipShape 隔离，它接受任意 Shape）；
// (2) containerShape 需要 RoundedRectangularShape，哪些写法真的能过。
// 只存在于探针分支，不进任何正式提交。
import SwiftUI

struct R01: View { var body: some View { let m: CGFloat = 18; Color.clear
    .clipShape(ConcentricRectangle(corners: .concentric(minimum: m))) } }

struct R02: View { var body: some View { Color.clear
    .clipShape(ConcentricRectangle(corners: .concentric(minimum: 18))) } }

struct R03: View { var body: some View { let m: CGFloat = 18; Color.clear
    .clipShape(ConcentricRectangle(corners: .concentric(minimum: .init(m)))) } }

struct R04: View { var body: some View { let m: CGFloat = 18; Color.clear
    .clipShape(ConcentricRectangle(corners: .concentric(minimum: .absolute(m)))) } }

struct R05: View { var body: some View { let m: CGFloat = 18; Color.clear
    .clipShape(ConcentricRectangle(corners: .concentric(minimum: .flexible(m)))) } }

struct R06: View { var body: some View { Color.clear
    .containerShape(RoundedRectangle(cornerRadius: 18, style: .continuous)) } }

struct R07: View { var body: some View { let m: CGFloat = 18; Color.clear
    .containerShape(.rect(cornerRadii: .init(topLeading: m, bottomLeading: m, bottomTrailing: m, topTrailing: m), style: .continuous)) } }

struct R08: View { var body: some View { Color.clear
    .containerShape(ConcentricRectangle(corners: .concentric(minimum: 18), isUniform: true)) } }

struct R09: View { var body: some View { let m: CGFloat = 18; Color.clear
    .containerShape(.rect(corners: .concentric(minimum: m), style: .continuous)) } }

struct R10: View { var body: some View { let m: CGFloat = 18; Color.clear
    .containerShape(.rect(corners: .concentric(minimum: m))) } }
