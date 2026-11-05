import CoreNFC
import Foundation

/// Reads an NFC tag's hardware UID. Any cheap NTAG213/215/216 sticker or
/// card works - no need to write anything to the tag.
final class NFCScanner: NSObject, NFCTagReaderSessionDelegate {
    enum ScanError: LocalizedError {
        case unavailable, cancelled, unreadable
        var errorDescription: String? {
            switch self {
            case .unavailable: return "This iPhone can't read NFC tags."
            case .cancelled: return "Scan cancelled."
            case .unreadable: return "Couldn't read that tag. Try holding it still near the top of your phone."
            }
        }
    }

    static var isAvailable: Bool { NFCTagReaderSession.readingAvailable }

    private var session: NFCTagReaderSession?
    private var continuation: CheckedContinuation<String, Error>?
    private var successMessage = "Done"

    /// Returns the tag UID formatted like ESPHome does, e.g. "04-A1-B2-C3".
    @MainActor
    func scan(prompt: String, success: String = "Done") async throws -> String {
        guard Self.isAvailable else { throw ScanError.unavailable }
        successMessage = success
        return try await withCheckedThrowingContinuation { cont in
            continuation = cont
            session = NFCTagReaderSession(pollingOption: [.iso14443, .iso15693], delegate: self, queue: nil)
            session?.alertMessage = prompt
            session?.begin()
        }
    }

    private func finish(_ result: Result<String, Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }

    func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {}

    func tagReaderSession(_ session: NFCTagReaderSession, didInvalidateWithError error: Error) {
        if let nfc = error as? NFCReaderError,
           nfc.code == .readerSessionInvalidationErrorUserCanceled ||
           nfc.code == .readerSessionInvalidationErrorSessionTimeout {
            finish(.failure(ScanError.cancelled))
        } else {
            finish(.failure(error))
        }
        self.session = nil
    }

    func tagReaderSession(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
        guard let tag = tags.first else { return }
        session.connect(to: tag) { [weak self] error in
            guard let self else { return }
            if error != nil {
                session.invalidate(errorMessage: ScanError.unreadable.localizedDescription)
                return
            }
            let uid: Data?
            switch tag {
            case .miFare(let t): uid = t.identifier
            case .iso7816(let t): uid = t.identifier
            case .iso15693(let t): uid = t.identifier
            case .feliCa(let t): uid = t.currentIDm
            @unknown default: uid = nil
            }
            guard let uid, !uid.isEmpty else {
                session.invalidate(errorMessage: ScanError.unreadable.localizedDescription)
                return
            }
            let id = uid.map { String(format: "%02X", $0) }.joined(separator: "-")
            session.alertMessage = self.successMessage
            self.finish(.success(id))
            session.invalidate()
        }
    }
}
