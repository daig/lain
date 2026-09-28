import LainClientCore
import UIKit

/// Full-screen connect screen (§6.6). Becomes the stream view controller in M2/M3.
final class ConnectViewController: UIViewController {
    private let status = ClientStatus.waitingForMac

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        let title = UILabel()
        title.text = status.title
        title.font = .systemFont(ofSize: 34, weight: .semibold)
        title.textColor = .white
        title.accessibilityIdentifier = "connect.title"

        let detail = UILabel()
        detail.text = status.detail
        detail.font = .preferredFont(forTextStyle: .body)
        detail.textColor = .secondaryLabel
        detail.accessibilityIdentifier = "connect.detail"

        let stack = UIStackView(arrangedSubviews: [title, detail])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }
}
