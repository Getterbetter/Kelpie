import Foundation
import Testing

@testable import Heeler

@Suite("Media intake classification and paste text")
struct MediaIntakeTests {
    @Test("Plain text is text")
    func classifiesPlainText() {
        #expect(
            MediaIntake.classify(typeIdentifiers: ["public.utf8-plain-text"]) == .text)
    }

    @Test("JPEG, HEIC and PNG are images")
    func classifiesImages() {
        #expect(MediaIntake.classify(typeIdentifiers: ["public.jpeg"]) == .image)
        #expect(MediaIntake.classify(typeIdentifiers: ["public.heic"]) == .image)
        #expect(MediaIntake.classify(typeIdentifiers: ["public.png"]) == .image)
    }

    @Test("A file URL is a file, not the URL text it also conforms to")
    func classifiesFileURL() {
        #expect(MediaIntake.classify(typeIdentifiers: ["public.file-url"]) == .file)
    }

    @Test("A PDF is a file")
    func classifiesPDF() {
        #expect(MediaIntake.classify(typeIdentifiers: ["com.adobe.pdf"]) == .file)
    }

    @Test("An identifier the system does not know is unsupported")
    func classifiesUnknownIdentifier() {
        #expect(
            MediaIntake.classify(typeIdentifiers: ["com.kelpie.not-a-real-type"])
                == .unsupported)
    }

    @Test("Text wins when a provider carries both text and an image")
    func prefersTextOverImage() {
        #expect(
            MediaIntake.classify(
                typeIdentifiers: ["public.png", "public.utf8-plain-text"]) == .text)
    }

    @Test("A plain path is typed bare, with one trailing space")
    func pasteTextForPlainPath() {
        #expect(
            MediaIntake.pasteText(forStagedPath: "/tmp/heeler/photo.jpg")
                == "/tmp/heeler/photo.jpg ")
    }

    @Test("A path with a space is single-quoted")
    func pasteTextQuotesWhitespace() {
        #expect(
            MediaIntake.pasteText(forStagedPath: "/tmp/my photo.jpg")
                == "'/tmp/my photo.jpg' ")
    }

    @Test("A single quote in the path is escaped out of its own quoting")
    func pasteTextEscapesSingleQuote() {
        #expect(
            MediaIntake.pasteText(forStagedPath: "/tmp/it's.jpg")
                == "'/tmp/it'\\''s.jpg' ")
    }
}
