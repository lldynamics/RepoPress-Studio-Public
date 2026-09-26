import RepoPressAppleSupport

// The macOS knowledge module retains these names as a compatibility surface.
// Their implementation and interchange bytes are owned by the identical shared
// snapshot consumed by iOS; keep app-specific persistence and UI adapters here.
public typealias RPNotePackage = RepoPressAppleSupport.RPNotePackage
public typealias RPNote = RepoPressAppleSupport.RPNote
public typealias RPNoteAttachment = RepoPressAppleSupport.RPNoteAttachment
public typealias RPNotesPackageError = RepoPressAppleSupport.RPNotesPackageError
public typealias RPNotesPackageCodec = RepoPressAppleSupport.RPNotesPackageCodec
