import Flutter
import PhotosUI
import UIKit
import UniformTypeIdentifiers

/// Answers `helm/document_picker` for `IosDocumentTreeGateway` in Dart.
///
/// Registered by hand from `AppDelegate.swift`, in the same spirit as
/// `SessionHoldPlugin.kt` on Android: this is a few hundred lines against
/// two system pickers, not a dependency whose plugin-review surface,
/// transitive deps, and own opinions about threading would have to be
/// argued with. The channel name is duplicated in
/// `ios_document_tree_gateway.dart` as `kDocumentPickerMethodChannel`; the
/// two sides MUST stay equal.
final class DocumentPickerPlugin: NSObject, FlutterPlugin {
  private static let channelName = "helm/document_picker"

  private weak var registrar: FlutterPluginRegistrar?

  /// The single in-flight picker's completion, or nil when idle.
  ///
  /// GUARDS AGAINST A SECOND CONCURRENT PICK. `UIDocumentPickerViewController`
  /// and `PHPickerViewController` are each only ever presented one at a
  /// time by this plugin, but Dart could in principle fire `pickFile`
  /// twice before the first reply lands (a double-tap, say). Without this
  /// guard the second call would silently overwrite `pendingResult`, and
  /// the FIRST caller's `result` callback — the one Flutter is actually
  /// waiting on — would never be invoked at all, hanging that `Future`
  /// forever. Refusing the second call with a named error is the only
  /// shape that cannot leak a handler.
  private var pendingResult: FlutterResult?

  init(registrar: FlutterPluginRegistrar) {
    self.registrar = registrar
  }

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: channelName, binaryMessenger: registrar.messenger())
    let instance = DocumentPickerPlugin(registrar: registrar)
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "pickFile":
      pickFile(result: result)
    case "pickMedia":
      pickMedia(result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - Presentation

  /// The view controller to present over.
  ///
  /// Deliberately NOT `UIApplication.shared.keyWindow`, which is
  /// deprecated and, on a multi-scene app, may not even be the window
  /// Flutter is drawing into. `FlutterPluginRegistrar.viewController` is
  /// the view controller the engine itself considers current, so it is
  /// the only answer that stays correct if this app ever adds a second
  /// scene.
  private func presentingViewController() -> UIViewController? {
    registrar?.viewController
  }

  // MARK: - pickFile

  private func pickFile(result: @escaping FlutterResult) {
    guard pendingResult == nil else {
      result(
        FlutterError(
          code: "ALREADY_PICKING",
          message: "A document or media pick is already in progress",
          details: nil))
      return
    }
    guard let presenter = presentingViewController() else {
      result(
        FlutterError(
          code: "NO_PRESENTER",
          message: "No view controller is available to present the picker",
          details: nil))
      return
    }
    pendingResult = result

    // `asCopy: true` is the whole design, not an incidental flag. Without
    // it, the picker hands back a security-scoped URL into storage this
    // app does not own, and using it correctly means bracketing every
    // read in `startAccessingSecurityScopedResource` /
    // `stopAccessingSecurityScopedResource` for as long as the handle is
    // kept — exactly the lifetime management `DocumentTreeGateway`'s own
    // class comment says this app avoids by not touching SAF-like APIs
    // off their one Android implementation. `asCopy: true` instead hands
    // back a file ALREADY INSIDE THIS APP'S CONTAINER: ordinary,
    // unscoped, readable for as long as this process wants, with no
    // lifetime contract to uphold.
    let picker = UIDocumentPickerViewController(
      forOpeningContentTypes: [.item], asCopy: true)
    picker.allowsMultipleSelection = false
    picker.delegate = self
    presenter.present(picker, animated: true)
  }

  // MARK: - pickMedia

  private func pickMedia(result: @escaping FlutterResult) {
    guard pendingResult == nil else {
      result(
        FlutterError(
          code: "ALREADY_PICKING",
          message: "A document or media pick is already in progress",
          details: nil))
      return
    }
    guard let presenter = presentingViewController() else {
      result(
        FlutterError(
          code: "NO_PRESENTER",
          message: "No view controller is available to present the picker",
          details: nil))
      return
    }
    pendingResult = result

    // NO `photoLibrary:` argument, and that omission is the privacy
    // property rather than an oversight. `PHPickerConfiguration(photoLibrary:)`
    // exists for ONE purpose: making `PHPickerResult.assetIdentifier`
    // non-nil so the app can fetch `PHAsset`s through PhotoKit — which
    // is precisely the path that requires photo-library authorisation.
    // This plugin never reads `assetIdentifier`; it loads bytes through
    // `loadFileRepresentation`. Passing a library would therefore buy
    // nothing and couple an upload picker to an permission prompt Apple
    // explicitly tells apps not to raise before showing the picker
    // (WWDC20, "Meet the new Photos picker"). The bare initialiser keeps
    // the out-of-process picker's guarantee intact: no permission, and
    // the app only ever sees what the user actually chose.
    var configuration = PHPickerConfiguration()
    configuration.filter = .any(of: [.images, .videos])
    configuration.selectionLimit = 0  // 0 means unlimited, matching Android's `multiple: true`.
    let picker = PHPickerViewController(configuration: configuration)
    picker.delegate = self
    presenter.present(picker, animated: true)
  }

  // MARK: - Staging into the temporary directory

  /// Copies `source` into a FRESH subdirectory of the temporary directory,
  /// and reads its length ONCE, right here.
  ///
  /// The fresh subdirectory matters because `UIDocumentPickerViewController`
  /// and `PHPickerViewController` may both hand back files that share a
  /// display name (two different photos the system both calls `IMG_0001`,
  /// or a document picked twice); writing every pick into the same flat
  /// directory would let the second copy silently replace the first
  /// before Dart ever saw it. One subdirectory per pick makes that
  /// collision impossible without this plugin inventing a renaming
  /// scheme.
  ///
  /// The byte count is read here, once, because
  /// `PickedDocument.length`'s contract (see `document_tree_gateway.dart`)
  /// is that this single reading is the number every later check — the
  /// progress bar, the completion receipt — is computed against. Reading
  /// it lazily on the Dart side would risk a second, possibly different,
  /// answer if the file somehow changed between the pick and the read.
  private func stage(_ source: URL, suggestedName: String) throws -> (
    path: String, name: String, length: Int
  ) {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("document_picker", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true)
    let destination = directory.appendingPathComponent(suggestedName)
    if FileManager.default.fileExists(atPath: destination.path) {
      try FileManager.default.removeItem(at: destination)
    }
    try FileManager.default.copyItem(at: source, to: destination)
    let attributes = try FileManager.default.attributesOfItem(
      atPath: destination.path)
    let length = (attributes[.size] as? NSNumber)?.intValue ?? 0
    return (destination.path, suggestedName, length)
  }

  private func replyMap(_ picked: (path: String, name: String, length: Int))
    -> [String: Any]
  {
    ["path": picked.path, "name": picked.name, "length": picked.length]
  }

  private func finish(_ value: Any?) {
    let result = pendingResult
    pendingResult = nil
    result?(value)
  }

  private func finishError(_ error: FlutterError) {
    let result = pendingResult
    pendingResult = nil
    result?(error)
  }
}

// MARK: - UIDocumentPickerDelegate

extension DocumentPickerPlugin: UIDocumentPickerDelegate {
  func documentPicker(
    _ controller: UIDocumentPickerViewController,
    didPickDocumentsAt urls: [URL]
  ) {
    guard let url = urls.first else {
      finish(nil)
      return
    }
    do {
      let picked = try stage(url, suggestedName: url.lastPathComponent)
      finish(replyMap(picked))
    } catch {
      finishError(
        FlutterError(
          code: "STAGE_FAILED",
          message: "Could not copy the picked file into the app container",
          details: "\(error)"))
    }
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController)
  {
    // A cancelled pick replies nil, never an error — the caller treats a
    // decline and "nothing to upload" as the same outcome, and a thrown
    // PlatformException here would force it to tell the two apart for no
    // reason. See `IosDocumentTreeGateway.pickFile`.
    finish(nil)
  }
}

// MARK: - PHPickerViewControllerDelegate

extension DocumentPickerPlugin: PHPickerViewControllerDelegate {
  func picker(
    _ picker: PHPickerViewController,
    didFinishPicking results: [PHPickerResult]
  ) {
    picker.dismiss(animated: true)

    if results.isEmpty {
      // The user cancelled, or deselected everything before confirming.
      // Same rule as the document picker: nil, never an error.
      finish(nil)
      return
    }

    let group = DispatchGroup()
    var staged = [Int: [String: Any]]()
    var failure: Error?
    let lock = NSLock()

    for (index, item) in results.enumerated() {
      group.enter()
      let suggestedName =
        item.itemProvider.suggestedName
        ?? "media_\(index)"
      item.itemProvider.loadFileRepresentation(
        forTypeIdentifier: item.itemProvider.registeredTypeIdentifiers.first
          ?? UTType.data.identifier
      ) { [weak self] url, error in
        defer { group.leave() }
        guard let self = self else { return }
        if let error = error {
          lock.lock()
          failure = failure ?? error
          lock.unlock()
          return
        }
        guard let url = url else {
          // A nil URL with no error, which `NSItemProvider` is within its
          // rights to hand back. RECORDED AS A FAILURE rather than
          // skipped: returning here without it would leave `staged[index]`
          // unset, and the `compactMap` below would quietly close the gap
          // — so a user who picked three photos would receive two, with
          // no error anywhere to say which one was lost or that anything
          // was. A visible failure is the only honest ending for an item
          // the system refused to produce.
          lock.lock()
          failure =
            failure
            ?? NSError(
              domain: "helm.document_picker", code: 1,
              userInfo: [
                NSLocalizedDescriptionKey:
                  "The system returned no file for picked item \(index)"
              ])
          lock.unlock()
          return
        }
        do {
          // `loadFileRepresentation` hands back a URL valid only for the
          // duration of this callback, so the copy into the temporary
          // directory must happen synchronously, inside the callback,
          // before returning — exactly as Apple's documentation requires.
          let name = url.lastPathComponent.isEmpty
            ? suggestedName : url.lastPathComponent
          let picked = try self.stage(url, suggestedName: name)
          lock.lock()
          staged[index] = self.replyMap(picked)
          lock.unlock()
        } catch {
          lock.lock()
          failure = failure ?? error
          lock.unlock()
        }
      }
    }

    group.notify(queue: .main) { [weak self] in
      guard let self = self else { return }
      if let failure = failure {
        self.finishError(
          FlutterError(
            code: "STAGE_FAILED",
            message: "Could not copy a picked media item into the app container",
            details: "\(failure)"))
        return
      }
      // Every index is present by construction — each callback either
      // stages its item or records a failure, and a recorded failure
      // returned above. The count is still asserted rather than assumed,
      // because `compactMap` is exactly the operation that would hide a
      // future regression in that invariant by silently shortening the
      // list instead of failing.
      let ordered = (0..<results.count).compactMap { staged[$0] }
      guard ordered.count == results.count else {
        self.finishError(
          FlutterError(
            code: "STAGE_FAILED",
            message:
              "Staged \(ordered.count) of \(results.count) picked media items",
            details: nil))
        return
      }
      self.finish(ordered)
    }
  }
}
