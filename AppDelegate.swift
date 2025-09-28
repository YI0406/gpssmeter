import Flutter
import Intents
import UIKit
import MapKit
import ReplayKit
import FirebaseCore
import AppIntents

// ✅ 新增：將 32-bit ARGB 轉為 UIColor
private extension UIColor {
  // 0xAARRGGBB
  convenience init(argb: UInt32) {
    let a = CGFloat((argb >> 24) & 0xFF) / 255.0
    let r = CGFloat((argb >> 16) & 0xFF) / 255.0
    let g = CGFloat((argb >> 8)  & 0xFF) / 255.0
    let b = CGFloat(argb & 0xFF) / 255.0
    self.init(red: r, green: g, blue: b, alpha: a)
  }
}
@main
@objc class AppDelegate: FlutterAppDelegate, RPPreviewViewControllerDelegate {
  private var replayKitChannel: FlutterMethodChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    FirebaseApp.configure()
    GeneratedPluginRegistrant.register(with: self)

    if let controller = window?.rootViewController as? FlutterViewController {
      let channel = FlutterMethodChannel(name: "trip_thumb", binaryMessenger: controller.binaryMessenger)
      channel.setMethodCallHandler { call, result in
        guard call.method == "snapshot" else {
          result(FlutterMethodNotImplemented)
          return
        }
        guard let args = call.arguments as? [String: Any],
              let pts = args["points"] as? [[Double]],
              let width = args["width"] as? Double,
              let height = args["height"] as? Double,
              let scale = args["scale"] as? Double else {
          result(FlutterError(code: "bad_args", message: "Missing args", details: nil))
          return
        }
        if pts.count < 2 {
          result(FlutterError(code: "no_points", message: "Need 2+ points", details: nil))
          return
        }

        // ✅ 新增：從 Flutter 接收樣式；預設紅色 3px
        let strokeColorARGB = (args["strokeColor"] as? NSNumber)?.uint32Value ?? 0xFFFF0000
        let strokeWidth = (args["strokeWidth"] as? Double) ?? 3.0
        let strokeUIColor = UIColor(argb: strokeColorARGB)

        let coords = pts.map { CLLocationCoordinate2D(latitude: $0[0], longitude: $0[1]) }
        var minLat = coords[0].latitude, maxLat = coords[0].latitude
        var minLng = coords[0].longitude, maxLng = coords[0].longitude
        for c in coords {
          minLat = min(minLat, c.latitude)
          maxLat = max(maxLat, c.latitude)
          minLng = min(minLng, c.longitude)
          maxLng = max(maxLng, c.longitude)
        }
        let latDelta = max((maxLat - minLat) * 1.3, 0.002)
        let lngDelta = max((maxLng - minLng) * 1.3, 0.002)
        let span = MKCoordinateSpan(latitudeDelta: latDelta, longitudeDelta: lngDelta)
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2.0, longitude: (minLng + maxLng) / 2.0)

        let options = MKMapSnapshotter.Options()
        options.region = MKCoordinateRegion(center: center, span: span)
        options.size = CGSize(width: width, height: height)  // point 單位
        options.scale = scale                               // devicePixelRatio
        if #available(iOS 13.0, *) {
          options.pointOfInterestFilter = .excludingAll
        } else {
          options.showsPointsOfInterest = false
        }
        options.showsBuildings = false
        options.mapType = .standard

        let snap = MKMapSnapshotter(options: options)
        snap.start { snapshot, error in
          if let error = error {
            result(FlutterError(code: "snap_error", message: error.localizedDescription, details: nil))
            return
          }
          guard let snapshot = snapshot else {
            result(FlutterError(code: "no_snapshot", message: "nil snapshot", details: nil))
            return
          }

          UIGraphicsBeginImageContextWithOptions(options.size, true, options.scale)
          snapshot.image.draw(at: .zero)

          // ✅ 改用指定顏色/粗細畫軌跡
          let path = UIBezierPath()
          var first = true
          for c in coords {
            let p = snapshot.point(for: c)
            if first { path.move(to: p); first = false } else { path.addLine(to: p) }
          }
          strokeUIColor.setStroke()
          path.lineWidth = CGFloat(strokeWidth)
          path.lineJoinStyle = .round
          path.lineCapStyle = .round
          path.stroke()

          // 起點/終點
          let sp = snapshot.point(for: coords.first!)
          let ep = snapshot.point(for: coords.last!)
          let sDot = UIBezierPath(ovalIn: CGRect(x: sp.x - 4, y: sp.y - 4, width: 8, height: 8))
          UIColor.systemGreen.setFill(); sDot.fill()
          let eDot = UIBezierPath(ovalIn: CGRect(x: ep.x - 4, y: ep.y - 4, width: 8, height: 8))
          UIColor.systemRed.setFill(); eDot.fill()

          let img = UIGraphicsGetImageFromCurrentImageContext()
          UIGraphicsEndImageContext()

          if let data = img?.pngData() {
            result(FlutterStandardTypedData(bytes: data))
          } else {
            result(FlutterError(code: "img_nil", message: "png fail", details: nil))
          }
        }
      }

      // ========= ReplayKit channel =========
      let rpChannel = FlutterMethodChannel(name: "replaykit", binaryMessenger: controller.binaryMessenger)
      self.replayKitChannel = rpChannel
      rpChannel.setMethodCallHandler { [weak self, weak controller] call, result in
        guard let self = self, let controller = controller else {
          result(FlutterError(code: "no_controller", message: "Missing root controller", details: nil))
          return
        }
        let recorder = RPScreenRecorder.shared()

        switch call.method {
        case "startRecording":
          // args: { "mic": true/false }
          let args = call.arguments as? [String: Any]
          let micEnabled = (args?["mic"] as? Bool) ?? true

          guard recorder.isAvailable else {
            result(FlutterError(code: "unavailable", message: "ReplayKit not available", details: nil))
            return
          }

          recorder.isMicrophoneEnabled = micEnabled
          recorder.startRecording { error in
            DispatchQueue.main.async {
              if let error = error {
                result(FlutterError(code: "start_failed", message: error.localizedDescription, details: nil))
              } else {
                result(true) // success
              }
            }
          }

        case "stopRecording":
          if #available(iOS 11.0, *) {
            let filename = "gpssmeter-\(UUID().uuidString).mp4"
            let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)

            recorder.stopRecording(withOutput: outputURL) { [weak self] error in
              DispatchQueue.main.async {
                if let error = error {
                  try? FileManager.default.removeItem(at: outputURL)
                  result(FlutterError(code: "stop_failed", message: error.localizedDescription, details: nil))
                  return
                }
                self?.replayKitChannel?.invokeMethod("recordingStopped", arguments: outputURL.path)
                result(outputURL.path)
              }
            }
          } else {
            recorder.stopRecording { [weak self] preview, error in
              DispatchQueue.main.async {
                if let error = error {
                  result(FlutterError(code: "stop_failed", message: error.localizedDescription, details: nil))
                  return
                }
                if let preview = preview {
                  preview.previewControllerDelegate = self
                  preview.modalPresentationStyle = .fullScreen
                  controller.present(preview, animated: true, completion: nil)
                }
                result(nil)
              }
            }
          }

        default:
          result(FlutterMethodNotImplemented)
        }
      }
      // ========= end ReplayKit channel =========
    }

    // ==== Siri Shortcuts via NSUserActivity: Map Track ====
    let activity = NSUserActivity(activityType: "com.gpssmeter.maptrack")
    activity.title = "Map Track" // English only per your request
    activity.isEligibleForSearch = true
    activity.isEligibleForPrediction = true
    activity.persistentIdentifier = NSUserActivityPersistentIdentifier("com.gpssmeter.maptrack")
    activity.suggestedInvocationPhrase = "Map Track" // Suggested Siri phrase

    self.window?.rootViewController?.userActivity = activity
    activity.becomeCurrent()
    // ==== end Siri Shortcuts ====

    // ==== Siri Shortcuts via NSUserActivity: Accel Mode ====
    let accelActivity = NSUserActivity(activityType: "com.gpssmeter.accel")
    accelActivity.title = "Accel Mode" // English only per your request
    accelActivity.isEligibleForSearch = true
    accelActivity.isEligibleForPrediction = true
    accelActivity.persistentIdentifier = NSUserActivityPersistentIdentifier("com.gpssmeter.accel")
    accelActivity.suggestedInvocationPhrase = "Accel Mode" // Suggested Siri phrase

    self.window?.rootViewController?.userActivity = accelActivity
    accelActivity.becomeCurrent()
    // ==== end Siri Shortcuts ====

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  override func application(_ application: UIApplication, continue userActivity: NSUserActivity, restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void) -> Bool {
    if userActivity.activityType == "com.gpssmeter.maptrack" {
      // Reuse your existing deep link to let Flutter handle navigation
      if let url = URL(string: "gpssmeter://maptrack") {
        DispatchQueue.main.async {
          UIApplication.shared.open(url, options: [:], completionHandler: nil)
        }
      }
      return true
    } else if userActivity.activityType == "com.gpssmeter.accel" {
      // Reuse your existing deep link to let Flutter handle navigation
      if let url = URL(string: "gpssmeter://accel") {
        DispatchQueue.main.async {
          UIApplication.shared.open(url, options: [:], completionHandler: nil)
        }
      }
      return true
    }
    return false
  }

  // MARK: - RPPreviewViewControllerDelegate
  func previewControllerDidFinish(_ previewController: RPPreviewViewController) {
    previewController.dismiss(animated: true, completion: nil)
    replayKitChannel?.invokeMethod("previewClosed", arguments: nil)
    replayKitChannel?.invokeMethod("recordingStopped", arguments: nil)
  }
}
