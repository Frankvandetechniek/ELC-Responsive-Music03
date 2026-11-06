// Prints the labels of Apple's built-in on-device sound classifier (diagnostics).
import SoundAnalysis
if let r = try? SNClassifySoundRequest(classifierIdentifier: .version1) {
    print("SOUNDCLASSES(\(r.knownClassifications.count)): " + r.knownClassifications.sorted().joined(separator: ","))
} else {
    print("SOUNDCLASSES: unavailable")
}
