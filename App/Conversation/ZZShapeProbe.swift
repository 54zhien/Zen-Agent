// 一次性探针（第 3 轮）：探明 Edge.Corner.Style 的合法取值（用 clipShape 隔离，它接受任意 Shape）。
// 只存在于探针分支，不进任何正式提交。
import SwiftUI

struct S01: View { var body: some View { Color.clear
    .clipShape(ConcentricRectangle(corners: .circular)) } }

struct S02: View { var body: some View { Color.clear
    .clipShape(ConcentricRectangle(corners: .continuous)) } }

struct S03: View { var body: some View { Color.clear
    .clipShape(ConcentricRectangle(corners: .concentric(minimum: .circular))) } }

struct S04: View { var body: some View { Color.clear
    .clipShape(ConcentricRectangle(corners: .concentric(minimum: .continuous))) } }

struct S05: View { var body: some View { Color.clear
    .clipShape(ConcentricRectangle(corners: .concentric)) } }

struct S06: View { var body: some View { Color.clear
    .clipShape(ConcentricRectangle(corners: .concentric(minimum: nil))) } }

struct S07: View { var body: some View { Color.clear
    .clipShape(ConcentricRectangle(corners: .fixed(18))) } }

struct S08: View { var body: some View { Color.clear
    .clipShape(ConcentricRectangle(corners: .concentric(minimum: .fixed(18)))) } }

struct S09: View { var body: some View { Color.clear
    .clipShape(ConcentricRectangle(corners: .concentric(minimum: .rect(cornerRadii: .init(topLeading: 18, bottomLeading: 18, bottomTrailing: 18, topTrailing: 18), style: .continuous)))) } }

struct S10: View { var body: some View { let m: CGFloat = 18; Color.clear
    .background(.regularMaterial, in: .rect(corners: .concentric(minimum: m))) } }

struct S11: View { var body: some View { Color.clear
    .containerShape(.rect(cornerRadii: .init(topLeading: 18, bottomLeading: 18, bottomTrailing: 18, topTrailing: 18), style: .continuous)) } }

struct S12: View { var body: some View { Color.clear
    .containerShape(RoundedRectangle(cornerRadius: 18, style: .continuous)) } }
