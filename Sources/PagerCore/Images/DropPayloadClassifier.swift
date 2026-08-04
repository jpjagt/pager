import Foundation

/// What a drop/paste resolved to. `.image` carries RAW bytes — the caller runs
/// ImageCodec.process (via EditorSession.setImage) before anything is stored.
public enum DropPayload: Equatable {
    case image(Data)
    case text(String)
}

/// Pure decision logic for drops and pastes: given everything readable off the
/// pasteboard, pick what the pager should hold. Image beats text; first
/// decodable image wins; text is capped at the editor's max length.
public enum DropPayloadClassifier {
    public static func classify(imageDatas: [Data], strings: [String]) -> DropPayload? {
        if let data = imageDatas.first(where: { ImageCodec.isDecodableImage($0) }) {
            return .image(data)
        }
        guard let text = strings.first(where: {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else { return nil }
        return .text(String(text.prefix(EditorSession.maxLength)))
    }
}
