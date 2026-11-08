//! Local image storage — port of `image_host.ts`.
//!
//! Trust boundary: the multipart `Content-Type` is a declaration, not a check;
//! Meander's Dart client sends `application/octet-stream` for gallery files.
//! Real safety comes from the magic-byte check, which also blocks SVG/HTML/XML
//! payloads that would turn an avatar into stored XSS.

use std::path::Path;

use uuid::Uuid;

#[derive(Debug)]
pub enum ImageError {
    /// The content is not an acceptable image (415, retrying is pointless).
    Unsupported(String),
    /// Disk or configuration failure (500).
    Save(String),
}

impl std::fmt::Display for ImageError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ImageError::Unsupported(msg) | ImageError::Save(msg) => f.write_str(msg),
        }
    }
}

const MAGIC_BYTES: [(&str, &[u8]); 5] = [
    (".jpg", &[0xff, 0xd8, 0xff]),
    (".jpeg", &[0xff, 0xd8, 0xff]),
    (".png", &[0x89, 0x50, 0x4e, 0x47]),
    (".gif", &[0x47, 0x49, 0x46]),
    (".webp", &[0x52, 0x49, 0x46, 0x46]),
];

const BLOCKED_SIGNATURES: [(&str, &[u8]); 4] = [
    ("SVG/XML", &[0x3c, 0x73, 0x76, 0x67]),
    ("XML declaration", &[0x3c, 0x3f, 0x78, 0x6d]),
    ("HTML", &[0x3c, 0x21, 0x44, 0x4f]),
    ("HTML tag", &[0x3c, 0x68, 0x74, 0x6d]),
];

/// Meander's Dart client sends `application/octet-stream` for gallery files;
/// only a declared type that is clearly something else is refused here.
pub fn accepts_image_part_mime(mimetype: Option<&str>) -> bool {
    let mime = mimetype.unwrap_or("").to_ascii_lowercase();
    mime.starts_with("image/")
        || matches!(
            mime.as_str(),
            "" | "application/octet-stream" | "binary/octet-stream"
        )
}

/// Checks the leading bytes against the extension and rejects markup.
pub fn check_magic_bytes(bytes: &[u8], ext: &str) -> Result<(), ImageError> {
    let ext = ext.to_ascii_lowercase();
    let Some((_, expected)) = MAGIC_BYTES.iter().find(|(e, _)| *e == ext) else {
        return Err(ImageError::Unsupported(format!(
            "Unsupported image extension: {ext}"
        )));
    };

    for (name, signature) in BLOCKED_SIGNATURES {
        if bytes.len() >= signature.len() && bytes.starts_with(signature) {
            return Err(ImageError::Unsupported(format!(
                "File appears to be {name}, not a valid image"
            )));
        }
    }

    if !bytes.starts_with(expected) {
        let header = bytes
            .iter()
            .take(8)
            .map(|b| format!("{b:02x}"))
            .collect::<String>();
        return Err(ImageError::Unsupported(format!(
            "Magic bytes do not match extension {ext}. Header: {header}"
        )));
    }
    Ok(())
}

/// Extension (with dot) from a client-supplied file name, lowercased.
pub fn extension_of(file_name: &str) -> String {
    Path::new(file_name)
        .extension()
        .and_then(|e| e.to_str())
        .map(|e| format!(".{}", e.to_ascii_lowercase()))
        .unwrap_or_default()
}

/// Writes the bytes under a fresh UUID name and returns the public URL.
pub fn save_uploaded_image(
    uploads_dir: &Path,
    bytes: &[u8],
    original_name: &str,
    base_url: &str,
) -> Result<String, ImageError> {
    let mut ext = extension_of(original_name);
    if ext.is_empty() {
        ext = ".jpg".to_string();
    }
    check_magic_bytes(bytes, &ext)?;

    std::fs::create_dir_all(uploads_dir)
        .map_err(|err| ImageError::Save(format!("Failed to save image locally: {err}")))?;
    let file_name = format!("{}{}", Uuid::new_v4(), ext);
    std::fs::write(uploads_dir.join(&file_name), bytes)
        .map_err(|err| ImageError::Save(format!("Failed to save image locally: {err}")))?;

    Ok(format!(
        "{}/uploads/{file_name}",
        base_url.trim_end_matches('/')
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    const PNG: &[u8] = &[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];

    #[test]
    fn accepts_real_images() {
        assert!(check_magic_bytes(PNG, ".png").is_ok());
        assert!(check_magic_bytes(&[0xff, 0xd8, 0xff, 0xe0], ".jpg").is_ok());
        assert!(check_magic_bytes(b"RIFF....WEBP", ".webp").is_ok());
    }

    #[test]
    fn blocks_markup_and_mismatches() {
        assert!(check_magic_bytes(b"<svg xmlns='x'/>", ".png").is_err());
        assert!(check_magic_bytes(b"<?xml version='1.0'?>", ".jpg").is_err());
        assert!(check_magic_bytes(b"<html><body>", ".gif").is_err());
        assert!(check_magic_bytes(PNG, ".gif").is_err());
        assert!(check_magic_bytes(PNG, ".svg").is_err());
    }

    #[test]
    fn mime_declaration_is_permissive_but_not_blind() {
        assert!(accepts_image_part_mime(Some("image/png")));
        assert!(accepts_image_part_mime(Some("application/octet-stream")));
        assert!(accepts_image_part_mime(None));
        assert!(!accepts_image_part_mime(Some("application/pdf")));
        assert!(!accepts_image_part_mime(Some("text/html")));
    }

    #[test]
    fn saved_file_uses_uuid_and_extension() {
        let dir = tempfile::tempdir().unwrap();
        let url =
            save_uploaded_image(dir.path(), PNG, "avatar.PNG", "https://example.test/").unwrap();
        assert!(url.starts_with("https://example.test/uploads/"));
        assert!(url.ends_with(".png"));
        let name = url.rsplit('/').next().unwrap();
        assert!(dir.path().join(name).exists());
    }

    #[test]
    fn saves_without_extension_using_jpeg_fallback() {
        let dir = tempfile::tempdir().unwrap();
        let jpeg = [0xffu8, 0xd8, 0xff, 0xe0];
        let url = save_uploaded_image(dir.path(), &jpeg, "photo", "http://localhost:3000").unwrap();
        assert!(url.ends_with(".jpg"));
    }
}
