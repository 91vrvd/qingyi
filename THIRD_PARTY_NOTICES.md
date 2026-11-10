# Third-Party Notices · 第三方组件说明

This repository contains only original source code and assets. The components below are **not** included in the repository; Xcode downloads them through Swift Package Manager at build time, or iOS / Google provide them at runtime. Each is governed by its own licence or terms.

本仓库只包含原创代码和资源。下列组件**不在仓库里**，由 Xcode 在构建时通过 Swift Package Manager 下载，或由 iOS / Google 在运行时提供，各自遵守自己的许可证或条款。

## Swift Packages（见 `iOS/Lingjing.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`）

| Package | Version | Licence / Terms |
|---|---|---|
| [d-date/google-mlkit-swiftpm](https://github.com/d-date/google-mlkit-swiftpm) — wraps Google ML Kit `MLKitTranslate`, `MLKitBarcodeScanning` binaries | 9.0.2 | Wrapper: Apache-2.0. ML Kit binaries: [Google ML Kit Terms](https://developers.google.com/ml-kit/terms) |
| [google/GoogleDataTransport](https://github.com/google/GoogleDataTransport) | 10.1.1 | Apache-2.0 |
| [google/GoogleUtilities](https://github.com/google/GoogleUtilities) | 8.1.5 | Apache-2.0 |
| [google/gtm-session-fetcher](https://github.com/google/gtm-session-fetcher) | 3.5.0 | Apache-2.0 |
| [google/promises](https://github.com/google/promises) | 2.4.1 | Apache-2.0 |
| [firebase/nanopb](https://github.com/firebase/nanopb) | 2.30910.1 | Zlib |

`MLKitTranslate_resource.bundle` ships inside Google's `MLKitTranslate.framework`. It is copied into the app by the "Copy ML Kit resources" build phase and is not redistributed in this repository.

`MLKitTranslate_resource.bundle` 位于 Google 的 `MLKitTranslate.framework` 内，构建时由「Copy ML Kit resources」步骤复制进 App，本仓库不再分发它。

## Runtime services · 运行时服务

- **ML Kit translation models** are downloaded from Google servers on first use of each language. ML Kit 翻译模型在首次使用某语言时从 Google 服务器下载。
- **Apple frameworks** — SwiftUI, Vision, VisionKit, NaturalLanguage, Translation, Speech, AVFoundation, AVKit, ReplayKit, PhotosUI, Photos, AppIntents, WidgetKit — are part of iOS and used through public APIs only. Apple translation languages are system-managed downloads. 苹果框架均为 iOS 系统自带，只通过公开 API 调用。

## Original assets · 原创资源

- App icon (`AppIcon-1024.png`), default wallpaper (`wallpaper.png`) and README images (`docs/images/`) were created for this project and are released under this repository's licence. README images are frames from the project's own promo video; the web page shown in them is fictional.
- App 图标、默认壁纸和 README 图片为本项目自制，随本仓库许可证发布。README 图片取自本项目自制宣传片，画面中的网页为虚构示例。
