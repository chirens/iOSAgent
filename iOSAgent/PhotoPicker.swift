import SwiftUI
import PhotosUI

/// 从相册选取一张图片（用于截图视觉识别）。
/// 注意：iOS 第三方 app 不能自行截取系统/其他 app 的屏幕，
/// 截图需由用户在系统或「快捷指令」中截好后进相册，此处只负责读取。
struct AttachPhotoButton: View {
    @Binding var image: UIImage?
    @State private var item: PhotosPickerItem?

    var body: some View {
        PhotosPicker(selection: $item, matching: .images) {
            Image(systemName: "photo")
                .font(.title2)
                .foregroundStyle(.tint)
        }
        .onChange(of: item) { _, _ in
            Task {
                if let data = try? await item?.loadTransferable(type: Data.self),
                   let ui = UIImage(data: data) {
                    image = ui
                }
            }
        }
    }
}
