import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    private let message = UILabel()
    private let activity = UIActivityIndicatorView(style: .large)
    private let done = UIButton(type: .system)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        message.text = "正在导入图片…"
        message.textAlignment = .center
        message.numberOfLines = 0
        message.font = .preferredFont(forTextStyle: .headline)
        activity.startAnimating()
        done.setTitle("完成", for: .normal)
        done.addTarget(self, action: #selector(close), for: .touchUpInside)
        done.isHidden = true
        let stack = UIStackView(arrangedSubviews: [activity, message, done])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 22
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24)
        ])
        importImage()
    }

    private func importImage() {
        guard let provider = extensionContext?.inputItems
            .compactMap({ $0 as? NSExtensionItem })
            .flatMap({ $0.attachments ?? [] })
            .first(where: { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }),
              let type = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .image) == true }) else {
            finish("没有收到可识别的图片")
            return
        }
        provider.loadDataRepresentation(forTypeIdentifier: type) { [weak self] data, error in
            guard let self else { return }
            guard let data, UIImage(data: data) != nil,
                  let folder = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.liu.lingjing.translate") else {
                DispatchQueue.main.async { self.finish("图片导入失败：\(error?.localizedDescription ?? "格式或共享容器不可用")") }
                return
            }
            do {
                try data.write(to: folder.appendingPathComponent("shortcut-image"), options: .atomic)
                DispatchQueue.main.async { self.finish("已导入。请打开青译，智能镜头会自动识别。") }
            } catch {
                DispatchQueue.main.async { self.finish("图片导入失败：\(error.localizedDescription)") }
            }
        }
    }

    private func finish(_ text: String) {
        activity.stopAnimating()
        message.text = text
        done.isHidden = false
    }

    @objc private func close() {
        extensionContext?.completeRequest(returningItems: nil)
    }
}
