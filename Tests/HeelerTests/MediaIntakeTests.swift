import Foundation
import Testing
import UniformTypeIdentifiers

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

    /// A PDF conforms to `public.data`, never to `public.file-url`: the
    /// narrower rule refused every PDF dropped out of Files.
    @Test("A PDF is a file")
    func classifiesPDF() {
        #expect(MediaIntake.classify(typeIdentifiers: ["com.adobe.pdf"]) == .file)
        #expect(
            MediaIntake.classify(typeIdentifiers: ["com.adobe.pdf", "public.file-url"])
                == .file)
        #expect(MediaIntake.classify(typeIdentifiers: ["public.zip-archive"]) == .file)
    }

    /// Text alone is still text — the paste path types it, and a drop of it is
    /// refused rather than uploaded as a file.
    @Test("Plain text with no file representation stays text")
    func classifiesBarePlainText() {
        #expect(MediaIntake.classify(typeIdentifiers: ["public.plain-text"]) == .text)
    }

    /// A `.txt` out of Files registers its content type *and* a file URL. It is
    /// a document to upload, not a string to type.
    @Test("A text file carrying a file URL is a file")
    func classifiesTextFileAsFile() {
        #expect(
            MediaIntake.classify(
                typeIdentifiers: ["public.plain-text", "public.file-url"]) == .file)
    }

    /// What the drop interaction offers to take, before classification decides.
    @Test("Accepted drop types cover data and content, not only file URLs")
    func acceptedDropTypesCoverData() {
        #expect(MediaIntake.acceptedDropTypeIdentifiers.contains("public.data"))
        #expect(MediaIntake.acceptedDropTypeIdentifiers.contains("public.content"))
        #expect(MediaIntake.acceptedDropTypeIdentifiers.contains("public.image"))
        #expect(MediaIntake.acceptedDropTypeIdentifiers.contains("public.file-url"))
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

    /// The drop bug in one test: the request has to leave while the session is
    /// still alive, and the owner's later `loadItems` has to join that load
    /// rather than ask the dead providers again.
    @MainActor
    @Test("A load begun for a drop is started once and joined afterwards")
    func beginLoadingIsJoinedByLoadItems() async {
        let loads = LoadCounter()
        let provider = NSItemProvider()
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.png.identifier,
            visibility: .all
        ) { completion in
            loads.increment()
            completion(Data([0x89, 0x50, 0x4E, 0x47]), nil)
            return nil
        }

        // `NSItemProvider` may run the registered loader on its own queue, so
        // only the joining is asserted here; that the request *leaves* inside
        // `performDrop` is structural — `beginLoading` has no suspension
        // before it.
        MediaIntake.beginLoading([provider])
        let items = await MediaIntake.loadItems(from: [provider])
        #expect(items.count == 1)
        #expect(loads.count == 1, "the owner started a second load of its own")
        if case .image(let data, _) = items.first {
            #expect(data == Data([0x89, 0x50, 0x4E, 0x47]))
        } else {
            Issue.record("expected an image item, got \(String(describing: items.first))")
        }
    }

    /// Providers `NSItemProvider` loads on its own queue, counted safely.
    private final class LoadCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func increment() {
            lock.lock()
            value += 1
            lock.unlock()
        }
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
