import SwiftUI
import AVFoundation
import Vision

// MARK: - Models

struct ConversionResult: Equatable {
    let originalText: String
    let amount: Double
    let currency: String
    let currencySymbol: String
    let euroAmount: Double
    let rate: Double
}

// MARK: - Exchange Rates

struct ExchangeRates {
    static let toEuro: [String: Double] = [
        "USD": 0.92, "GBP": 1.17, "JPY": 0.0062, "CNY": 0.13,
        "CHF": 1.04, "CAD": 0.68, "AUD": 0.60, "SEK": 0.088,
        "NOK": 0.087, "DKK": 0.134, "PLN": 0.23, "CZK": 0.041,
        "HUF": 0.0026, "RON": 0.20, "BGN": 0.51, "HRK": 0.133,
        "TRY": 0.027, "RUB": 0.010, "INR": 0.011, "BRL": 0.18,
        "MXN": 0.047, "ZAR": 0.050, "KRW": 0.00067, "SGD": 0.68,
        "HKD": 0.118, "NZD": 0.55, "THB": 0.026, "IDR": 0.000057,
        "MYR": 0.20, "PHP": 0.016, "AED": 0.25, "SAR": 0.245,
        "ILS": 0.25, "EGP": 0.019, "NGN": 0.00058, "KES": 0.0071,
        "ARS": 0.00096, "CLP": 0.00099, "COP": 0.00022, "PEN": 0.24,
        "EUR": 1.0
    ]
    static let symbols: [String: String] = [
        "USD": "$", "GBP": "£", "JPY": "¥", "CNY": "¥", "EUR": "€",
        "CHF": "Fr", "CAD": "CA$", "AUD": "A$", "SEK": "kr", "NOK": "kr",
        "DKK": "kr", "PLN": "zł", "CZK": "Kč", "HUF": "Ft", "RON": "lei",
        "TRY": "₺", "RUB": "₽", "INR": "₹", "BRL": "R$", "MXN": "MX$",
        "ZAR": "R", "KRW": "₩", "SGD": "S$", "HKD": "HK$", "THB": "฿",
        "IDR": "Rp", "AED": "د.إ", "SAR": "﷼", "ILS": "₪", "PHP": "₱",
        "ARS": "AR$", "CLP": "CL$", "COP": "CO$", "PEN": "S/"
    ]
    static func convert(_ amount: Double, from currency: String) -> Double? {
        guard let rate = toEuro[currency.uppercased()] else { return nil }
        return amount * rate
    }
    static func symbol(for currency: String) -> String {
        return symbols[currency.uppercased()] ?? currency
    }
}

// MARK: - Price Parser

struct PriceParser {
    // Ordered indicators — most-specific first to avoid substring overlap (e.g. CA$ before $)
    static let currencyIndicators: [(String, String)] = [
        ("¥", "JPY"), ("·", "JPY"),
        ("£", "GBP"), ("€", "EUR"), ("₺", "TRY"), ("₹", "INR"),
        ("₩", "KRW"), ("₪", "ILS"), ("₱", "PHP"), ("฿", "THB"),
        ("R$", "BRL"), ("CA$", "CAD"), ("A$", "AUD"), ("S$", "SGD"),
        ("HK$", "HKD"), ("MX$", "MXN"), ("$", "USD"),
        ("Fr", "CHF"), ("Rp", "IDR"), ("zł", "PLN"),
        ("JPY", "JPY"), ("USD", "USD"), ("EUR", "EUR"), ("GBP", "GBP"),
        ("CHF", "CHF"), ("CAD", "CAD"), ("AUD", "AUD"), ("KRW", "KRW"),
        ("SEK", "SEK"), ("NOK", "NOK"), ("DKK", "DKK"), ("TRY", "TRY"),
        ("INR", "INR"), ("BRL", "BRL"), ("SGD", "SGD"), ("HKD", "HKD"),
        ("MXN", "MXN"), ("MYR", "MYR"), ("PLN", "PLN"), ("ZAR", "ZAR"),
        ("THB", "THB"), ("IDR", "IDR"), ("PHP", "PHP"), ("ILS", "ILS"),
    ]

    // `+` on the thousands-separator group requires at least one separator,
    // so bare integers of any length fall through to the `[0-9]+` alternative.
    static func numberPattern(for currency: String) -> String {
        switch currency {
        case "JPY", "KRW":
            return "[0-9]{1,3}(?:,[0-9]{3})+|[0-9]+"
        default:
            return "[0-9]{1,3}(?:[.,][0-9]{3})+(?:[.,][0-9]{1,2})?|[0-9]+(?:[.,][0-9]{1,2})?"
        }
    }

    static func detectCurrency(in text: String) -> String? {
        let upper = text.uppercased()
        for (indicator, currency) in currencyIndicators {
            if upper.contains(indicator.uppercased()) {
                return currency
            }
        }
        return nil
    }

    // Converts a raw number string (from regex match) to a Double.
    // Handles thousands separators (comma or dot) and decimal separators.
    static func normalizeAmountString(_ s: String) -> Double? {
        var s = s
        if s.filter({ $0 == "." }).count > 1 {
            // Multiple dots → all are thousands separators (e.g. "1.234.567")
            s = s.replacingOccurrences(of: ".", with: "")
        } else if s.contains(",") && s.contains(".") {
            // Both present — whichever comes last is the decimal separator
            if s.lastIndex(of: ",")! > s.lastIndex(of: ".")! {
                s = s.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
            } else {
                s = s.replacingOccurrences(of: ",", with: "")
            }
        } else if s.contains(",") {
            // If the last comma-separated segment is exactly 3 digits, it's a thousands separator
            // (e.g. ¥1,980 or ¥12,345,678). Otherwise treat comma as decimal separator.
            let parts = s.components(separatedBy: ",")
            if parts.count > 1 && parts.last?.count == 3 {
                s = s.replacingOccurrences(of: ",", with: "")
            } else {
                s = s.replacingOccurrences(of: ",", with: ".")
            }
        }
        return Double(s)
    }

    static func extractAmount(_ text: String, currency: String) -> ConversionResult? {
        let pattern = numberPattern(for: currency)
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsRange = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: nsRange),
              let range = Range(match.range, in: text) else { return nil }
        let s = String(text[range])
        guard let amount = normalizeAmountString(s), amount > 0,
              let euroAmount = ExchangeRates.convert(amount, from: currency),
              let rate = ExchangeRates.toEuro[currency] else { return nil }
        return ConversionResult(originalText: text, amount: amount, currency: currency,
                                currencySymbol: ExchangeRates.symbol(for: currency),
                                euroAmount: euroAmount, rate: rate)
    }

    // Two-pass entry point: currency detection per observation, then amount extraction
    static func parse(from observations: [String]) -> ConversionResult? {
        for (idx, obs) in observations.enumerated() {
            guard let currency = detectCurrency(in: obs) else { continue }
            let candidates = [obs]
                + (idx > 0 ? [observations[idx - 1]] : [])
                + (idx < observations.count - 1 ? [observations[idx + 1]] : [])
                + [observations.joined(separator: " ")]
            for candidate in candidates {
                if let result = extractAmount(candidate, currency: currency) {
                    return result
                }
            }
        }
        return parse(from: observations.joined(separator: " "))
    }

    // Single-string convenience: detect currency then extract amount
    static func parse(from text: String) -> ConversionResult? {
        guard let currency = detectCurrency(in: text) else { return nil }
        return extractAmount(text, currency: currency)
    }
}

// MARK: - Camera Preview

/// Uses layerClass override so AVCaptureVideoPreviewLayer IS the backing layer.
/// This means layoutSubviews automatically keeps it full-size — no manual frame math.
final class PreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var videoPreviewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    override func layoutSubviews() {
        super.layoutSubviews()
        videoPreviewLayer.frame = bounds
    }
}

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.backgroundColor = .black
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        if let conn = view.videoPreviewLayer.connection, conn.isVideoOrientationSupported {
            conn.videoOrientation = .portrait
        }
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        if uiView.videoPreviewLayer.session !== session {
            uiView.videoPreviewLayer.session = session
        }
    }
}

// MARK: - Camera Controller

final class CameraController: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {

    @Published var conversionResult: ConversionResult?
    @Published var showResult = false
    @Published var torchOn = false
    @Published var permissionStatus: AVAuthorizationStatus = .notDetermined
    @Published var detectedCurrencyCode: String? = nil

    let session = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "camera.session", qos: .userInitiated)
    private let ocrQueue    = DispatchQueue(label: "camera.ocr",     qos: .userInitiated)
    private var isConfigured = false
    private var freezeOCR   = false
    private var lastOCRTime  = Date.distantPast
    private var audioPlayer: AVAudioPlayer?
    private var soundIndex  = 0
    private let roiLock = NSLock()
    private var _regionOfInterest: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)

    // Called from main thread whenever the viewfinder frame is known.
    // Converts UIKit screen coordinates (origin top-left) to Vision normalized
    // coordinates (origin bottom-left) so OCR is limited to the viewport.
    func updateROI(viewfinderFrame: CGRect, screenSize: CGSize) {
        let x = viewfinderFrame.minX / screenSize.width
        let y = 1.0 - viewfinderFrame.maxY / screenSize.height
        let w = viewfinderFrame.width  / screenSize.width
        let h = viewfinderFrame.height / screenSize.height
        roiLock.withLock { _regionOfInterest = CGRect(x: x, y: y, width: w, height: h) }
    }

    private static let soundNames = ["cha-ching", "cha-ching_2", "cha-ching_3"]

    private func playNextSound() {
        let name = Self.soundNames[soundIndex % Self.soundNames.count]
        soundIndex += 1
        guard let url = Bundle.main.url(forResource: name, withExtension: "mp3") else { return }
        audioPlayer = try? AVAudioPlayer(contentsOf: url)
        audioPlayer?.play()
    }

    func requestAndStart() {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        DispatchQueue.main.async { self.permissionStatus = status }
        switch status {
        case .authorized:    configure()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async { self?.permissionStatus = granted ? .authorized : .denied }
                if granted { self?.configure() }
            }
        default: break
        }
    }

    func startRunning() {
        sessionQueue.async { [weak self] in
            guard let self, self.isConfigured, !self.session.isRunning else { return }
            self.session.startRunning()
        }
    }

    func stopRunning() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    func resumeScanning() {
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.3)) { self.detectedCurrencyCode = nil }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { self.showResult = false }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { self.conversionResult = nil }
            // Delay OCR until the viewfinder is fully visible (after sheet dismiss animation)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { self.freezeOCR = false }
        }
    }

    func toggleTorch() {
        guard let device = AVCaptureDevice.default(for: .video), device.hasTorch else { return }
        try? device.lockForConfiguration()
        torchOn.toggle()
        device.torchMode = torchOn ? .on : .off
        device.unlockForConfiguration()
    }

    private func configure() {
        sessionQueue.async { [weak self] in
            guard let self, !self.isConfigured else { return }
            self.session.beginConfiguration()
            self.session.sessionPreset = .hd1280x720

            guard
                let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                let input  = try? AVCaptureDeviceInput(device: device),
                self.session.canAddInput(input)
            else { self.session.commitConfiguration(); return }
            self.session.addInput(input)

            // Continuous autofocus & autoexposure
            if device.isFocusModeSupported(.continuousAutoFocus) {
                try? device.lockForConfiguration()
                device.focusMode  = .continuousAutoFocus
                device.exposureMode = .continuousAutoExposure
                device.unlockForConfiguration()
            }

            let output = AVCaptureVideoDataOutput()
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: self.ocrQueue)
            guard self.session.canAddOutput(output) else { self.session.commitConfiguration(); return }
            self.session.addOutput(output)

            // Lock capture connection to portrait so OCR orientation is always correct
            if let conn = output.connection(with: .video), conn.isVideoOrientationSupported {
                conn.videoOrientation = .portrait
            }

            self.session.commitConfiguration()
            self.isConfigured = true
            self.session.startRunning()
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard !freezeOCR else { return }
        let now = Date()
        guard now.timeIntervalSince(lastOCRTime) >= 0.6 else { return }
        lastOCRTime = now

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let request = VNRecognizeTextRequest { [weak self] req, _ in
            guard let self else { return }
            let strings = (req.results as? [VNRecognizedTextObservation] ?? [])
                .compactMap { $0.topCandidates(1).first?.string }
            let currency = strings.compactMap { PriceParser.detectCurrency(in: $0) }.first
            DispatchQueue.main.async {
                withAnimation(.easeInOut(duration: 0.3)) { self.detectedCurrencyCode = currency }
            }
            guard let result = PriceParser.parse(from: strings) else { return }
            self.freezeOCR = true
            self.playNextSound()
            DispatchQueue.main.async {
                self.conversionResult = result
                withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) { self.showResult = true }
            }
        }
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.015
        request.regionOfInterest = roiLock.withLock { _regionOfInterest }

        // Orientation .up because we already locked the capture connection to portrait
        try? VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up).perform([request])
    }
}

// MARK: - Content View

struct ContentView: View {
    @StateObject private var camera = CameraController()
    @State private var scanLineOffset: CGFloat = -55
    @Environment(\.scenePhase) private var scenePhase

    private let accentColor = Color(red: 0.25, green: 0.92, blue: 0.58)

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch camera.permissionStatus {
            case .authorized:
                scannerView
            case .denied, .restricted:
                permissionDeniedView
            default:
                Color.black.ignoresSafeArea()
            }
        }
        .onAppear { camera.requestAndStart() }
        .onChange(of: scenePhase) { phase in
            if phase == .active      { camera.startRunning() }
            else if phase == .background { camera.stopRunning() }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
    }

    // MARK: Scanner

    var scannerView: some View {
        ZStack {
            CameraPreviewView(session: camera.session)
                .ignoresSafeArea()

            LinearGradient(
                colors: [.black.opacity(0.65), .clear, .clear, .black.opacity(0.75)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                headerView
                Spacer()
                if !camera.showResult { viewfinder }
                Spacer()
                if !camera.showResult { hintLabel }
            }

            VStack {
                HStack {
                    resetButton.padding(.top, 56).padding(.leading, 24)
                    Spacer()
                    torchButton.padding(.top, 56).padding(.trailing, 24)
                }
                Spacer()
            }

            if camera.showResult, let result = camera.conversionResult {
                resultSheet(result: result)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(10)
            }
        }
    }

    var headerView: some View {
        VStack(spacing: 3) {
            Text("PRICE SCANNER")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(.white.opacity(0.5))
                .kerning(5)
            Text("→ EUR")
                .font(.system(size: 30, weight: .black, design: .rounded))
                .foregroundColor(.white)
        }
        .padding(.top, 62)
    }

    var viewfinder: some View {
        ZStack {
            // Darkened mask outside frame
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .mask(
                    Rectangle().overlay(
                        RoundedRectangle(cornerRadius: 18)
                            .frame(width: 290, height: 155)
                            .blendMode(.destinationOut)
                    )
                    .compositingGroup()
                )
                .allowsHitTesting(false)

            ForEach(0..<4) { i in
                CornerBracket(index: i)
                    .stroke(accentColor, lineWidth: 2.5)
                    .frame(width: 290, height: 155)
            }

            // Scan line clipped inside the frame
            RoundedRectangle(cornerRadius: 18)
                .frame(width: 290, height: 155)
                .foregroundColor(.clear)
                .background(
                    GeometryReader { geo in
                        Color.clear.onAppear {
                            camera.updateROI(
                                viewfinderFrame: geo.frame(in: .global),
                                screenSize: UIScreen.main.bounds.size
                            )
                        }
                    }
                )
                .overlay(
                    LinearGradient(
                        colors: [.clear, accentColor.opacity(0.9), .clear],
                        startPoint: .leading, endPoint: .trailing
                    )
                    .frame(height: 2)
                    .offset(y: scanLineOffset)
                )
                .clipped()
                .onAppear {
                    withAnimation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true)) {
                        scanLineOffset = 55
                    }
                }
                .allowsHitTesting(false)

            if let code = camera.detectedCurrencyCode {
                HStack(spacing: 6) {
                    Image(systemName: "scope")
                    Text("\(ExchangeRates.symbol(for: code))  \(code) detected")
                }
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(accentColor)
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(accentColor.opacity(0.15), in: Capsule())
                .transition(.opacity.combined(with: .scale))
                .offset(y: 95)
            }
        }
    }

    var hintLabel: some View {
        Text("Point camera at any price tag")
            .font(.system(size: 13, weight: .medium, design: .rounded))
            .foregroundColor(.white.opacity(0.45))
            .padding(.bottom, 52)
    }

    var torchButton: some View {
        Button(action: { camera.toggleTorch() }) {
            Image(systemName: camera.torchOn ? "bolt.fill" : "bolt.slash.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(camera.torchOn ? .yellow : .white.opacity(0.6))
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: Circle())
        }
    }

    var resetButton: some View {
        Button(action: { camera.resumeScanning() }) {
            Image(systemName: "arrow.counterclockwise")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white.opacity(0.6))
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: Circle())
        }
    }

    func resultSheet(result: ConversionResult) -> some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 0) {
                Capsule()
                    .fill(Color.white.opacity(0.2))
                    .frame(width: 38, height: 5)
                    .padding(.top, 14)
                    .padding(.bottom, 22)

                HStack(spacing: 6) {
                    Text("Detected")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(.white.opacity(0.4))
                    Text("\(result.currencySymbol)\(formatAmount(result.amount)) \(result.currency)")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundColor(.white.opacity(0.9))
                }
                .padding(.bottom, 20)

                Image(systemName: "arrow.down")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(accentColor.opacity(0.7))
                    .padding(.bottom, 18)

                (Text("€")
                    .font(.system(size: 36, weight: .thin, design: .rounded))
                    .foregroundColor(accentColor)
                + Text(String(format: "%.2f", result.euroAmount))
                    .font(.system(size: 68, weight: .black, design: .rounded))
                    .foregroundColor(.white))
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .padding(.horizontal, 24)

                Text("EURO")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(accentColor)
                    .kerning(4)
                    .padding(.top, 6)

                Text("1 \(result.currency) = €\(String(format: "%.4f", result.rate))")
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundColor(.white.opacity(0.3))
                    .padding(.top, 18)

                Button(action: { camera.resumeScanning() }) {
                    HStack(spacing: 8) {
                        Image(systemName: "viewfinder")
                            .font(.system(size: 15, weight: .semibold))
                        Text("SCAN AGAIN")
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .kerning(2)
                    }
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 17)
                    .background(accentColor)
                    .cornerRadius(16)
                }
                .padding(.horizontal, 28)
                .padding(.top, 28)
                .padding(.bottom, 44)
            }
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 34)
                    .fill(Color(red: 0.06, green: 0.06, blue: 0.09))
                    .overlay(RoundedRectangle(cornerRadius: 34).stroke(Color.white.opacity(0.06), lineWidth: 1))
                    .ignoresSafeArea(edges: .bottom)
            )
        }
        .ignoresSafeArea(edges: .bottom)
        .gesture(DragGesture().onEnded { if $0.translation.height > 60 { camera.resumeScanning() } })
    }

    var permissionDeniedView: some View {
        VStack(spacing: 22) {
            Image(systemName: "camera.slash.fill")
                .font(.system(size: 56))
                .foregroundColor(accentColor)
            Text("Camera Access Required")
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundColor(.white)
            Text("Please enable camera access in\nSettings → Privacy → Camera.")
                .font(.system(size: 15))
                .foregroundColor(.white.opacity(0.55))
                .multilineTextAlignment(.center)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .font(.system(size: 15, weight: .semibold, design: .rounded))
            .foregroundColor(.black)
            .padding(.horizontal, 36)
            .padding(.vertical, 15)
            .background(accentColor)
            .cornerRadius(14)
        }
        .padding()
    }

    func formatAmount(_ amount: Double) -> String {
        amount == amount.rounded() && amount >= 1
            ? String(format: "%.0f", amount)
            : String(format: "%.2f", amount)
    }
}

// MARK: - Corner Bracket

struct CornerBracket: Shape {
    let index: Int
    private let arm: CGFloat = 22
    private let r: CGFloat = 7
    func path(in rect: CGRect) -> Path {
        var p = Path()
        switch index {
        case 0:
            p.move(to: .init(x: rect.minX, y: rect.minY + arm))
            p.addLine(to: .init(x: rect.minX, y: rect.minY + r))
            p.addArc(center: .init(x: rect.minX + r, y: rect.minY + r), radius: r, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
            p.addLine(to: .init(x: rect.minX + arm, y: rect.minY))
        case 1:
            p.move(to: .init(x: rect.maxX - arm, y: rect.minY))
            p.addLine(to: .init(x: rect.maxX - r, y: rect.minY))
            p.addArc(center: .init(x: rect.maxX - r, y: rect.minY + r), radius: r, startAngle: .degrees(270), endAngle: .degrees(0), clockwise: false)
            p.addLine(to: .init(x: rect.maxX, y: rect.minY + arm))
        case 2:
            p.move(to: .init(x: rect.minX, y: rect.maxY - arm))
            p.addLine(to: .init(x: rect.minX, y: rect.maxY - r))
            p.addArc(center: .init(x: rect.minX + r, y: rect.maxY - r), radius: r, startAngle: .degrees(180), endAngle: .degrees(90), clockwise: true)
            p.addLine(to: .init(x: rect.minX + arm, y: rect.maxY))
        default:
            p.move(to: .init(x: rect.maxX - arm, y: rect.maxY))
            p.addLine(to: .init(x: rect.maxX - r, y: rect.maxY))
            p.addArc(center: .init(x: rect.maxX - r, y: rect.maxY - r), radius: r, startAngle: .degrees(90), endAngle: .degrees(0), clockwise: true)
            p.addLine(to: .init(x: rect.maxX, y: rect.maxY - arm))
        }
        return p
    }
}

// MARK: - App Entry

@main
struct PriceScannerApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
