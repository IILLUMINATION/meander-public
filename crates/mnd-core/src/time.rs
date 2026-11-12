//! Текущее время — в одном месте.
//!
//! На `wasm32-unknown-unknown` `std::time::SystemTime::now()` не возвращает
//! ошибку, а **паникует** («time not implemented on this platform»), поэтому
//! вызовы `SystemTime` прямо в коде движка обронили бы веб-плеер на первой же
//! ноде. Здесь время берётся у JS (`Date.now()`), а на нативных целях — у
//! стандартных часов.

/// Наносекунд с UNIX-эпохи. Без паники: если часов нет, возвращает 0.
pub fn unix_now_nanos() -> u128 {
    #[cfg(target_arch = "wasm32")]
    {
        // Date.now() — миллисекунды; суб-миллисекундной точности нет ни у JS,
        // ни у браузера, и ниже по коду она не используется.
        js_sys::Date::now().max(0.0) as u128 * 1_000_000
    }
    #[cfg(not(target_arch = "wasm32"))]
    {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0)
    }
}

/// Секунд с UNIX-эпохи.
pub fn unix_now_secs() -> u64 {
    (unix_now_nanos() / 1_000_000_000) as u64
}

/// Время из `Metadata::modified()` в миллисекундах UNIX-эпохи.
///
/// Часы std не должны встречаться вне этого файла (см.
/// `tests/wasm_clock.rs`): на wasm `SystemTime::now()` паникует. Здесь же
/// только арифметика над уже полученным временем файла, поэтому функция
/// безопасна в обоих мирах; если часы вернули ошибку — 0.
pub fn mtime_millis(modified: std::io::Result<std::time::SystemTime>) -> Option<u64> {
    modified
        .ok()?
        .duration_since(std::time::UNIX_EPOCH)
        .ok()
        .map(|d| d.as_millis() as u64)
}
