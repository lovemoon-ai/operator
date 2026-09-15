use std::any::Any;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::slice;
use std::str;

use operator_core::BlueprintPublisher;

#[repr(C)]
pub struct operator_bytes_t {
    pub data: *mut u8,
    pub len: usize,
    pub capacity: usize,
}

impl operator_bytes_t {
    const fn empty() -> Self {
        Self {
            data: std::ptr::null_mut(),
            len: 0,
            capacity: 0,
        }
    }

    fn from_string(value: String) -> Self {
        let mut bytes = value.into_bytes();
        let result = Self {
            data: bytes.as_mut_ptr(),
            len: bytes.len(),
            capacity: bytes.capacity(),
        };
        std::mem::forget(bytes);
        result
    }
}

#[repr(C)]
pub struct operator_string_view_t {
    pub data: *const u8,
    pub len: usize,
}

impl operator_string_view_t {
    fn from_static(value: &'static str) -> Self {
        Self {
            data: value.as_ptr(),
            len: value.len(),
        }
    }
}

#[allow(non_camel_case_types)]
pub struct operator_blueprint_publisher_t(BlueprintPublisher);

fn panic_message(value: Box<dyn Any + Send>) -> String {
    if let Some(message) = value.downcast_ref::<&str>() {
        format!("liboperator panic: {message}")
    } else if let Some(message) = value.downcast_ref::<String>() {
        format!("liboperator panic: {message}")
    } else {
        "liboperator panic".to_string()
    }
}

unsafe fn input<'a>(data: *const u8, len: usize) -> Result<&'a str, String> {
    if len == 0 {
        return Ok("");
    }
    if data.is_null() {
        return Err("null input pointer".to_string());
    }
    str::from_utf8(unsafe { slice::from_raw_parts(data, len) }).map_err(|error| error.to_string())
}

unsafe fn publisher<'a>(
    value: *mut operator_blueprint_publisher_t,
) -> Result<&'a BlueprintPublisher, String> {
    unsafe { value.as_ref() }
        .map(|publisher| &publisher.0)
        .ok_or_else(|| "null Blueprint publisher pointer".to_string())
}

unsafe fn initialize_bytes(value: *mut operator_bytes_t) {
    if let Some(value) = unsafe { value.as_mut() } {
        *value = operator_bytes_t::empty();
    }
}

unsafe fn write_result<F>(
    operation: F,
    output: *mut operator_bytes_t,
    error: *mut operator_bytes_t,
) -> bool
where
    F: FnOnce() -> Result<String, String>,
{
    unsafe {
        initialize_bytes(output);
        initialize_bytes(error);
    }
    let result =
        catch_unwind(AssertUnwindSafe(operation)).unwrap_or_else(|panic| Err(panic_message(panic)));
    match result {
        Ok(value) => {
            if let Some(output) = unsafe { output.as_mut() } {
                *output = operator_bytes_t::from_string(value);
            }
            true
        }
        Err(value) => {
            if let Some(error) = unsafe { error.as_mut() } {
                *error = operator_bytes_t::from_string(value);
            }
            false
        }
    }
}

#[no_mangle]
pub extern "C" fn operator_blueprint_spec_sha256() -> operator_string_view_t {
    operator_string_view_t::from_static(operator_core::SPEC_SHA256)
}

#[no_mangle]
pub extern "C" fn operator_blueprint_spec_version() -> u32 {
    operator_core::SPEC_VERSION
}

#[no_mangle]
pub extern "C" fn operator_blueprint_publisher_new() -> *mut operator_blueprint_publisher_t {
    catch_unwind(|| {
        Box::into_raw(Box::new(operator_blueprint_publisher_t(
            BlueprintPublisher::new(),
        )))
    })
    .unwrap_or(std::ptr::null_mut())
}

#[no_mangle]
/// # Safety
///
/// `value` must be null or a pointer returned by
/// [`operator_blueprint_publisher_new`] that has not already been freed.
pub unsafe extern "C" fn operator_blueprint_publisher_free(
    value: *mut operator_blueprint_publisher_t,
) {
    if !value.is_null() {
        drop(unsafe { Box::from_raw(value) });
    }
}

#[no_mangle]
/// # Safety
///
/// `value` must be empty or returned by a `liboperator` function, and ownership
/// must not have already been released.
pub unsafe extern "C" fn operator_bytes_free(value: operator_bytes_t) {
    if !value.data.is_null() {
        drop(unsafe { Vec::from_raw_parts(value.data, value.len, value.capacity) });
    }
}

#[no_mangle]
/// # Safety
///
/// The publisher must be valid, `data` must reference `len` readable bytes,
/// and `error`, when non-null, must reference writable storage.
pub unsafe extern "C" fn operator_blueprint_set_json(
    publisher_ptr: *mut operator_blueprint_publisher_t,
    data: *const u8,
    len: usize,
    error: *mut operator_bytes_t,
) -> bool {
    unsafe {
        write_result(
            || {
                let publisher = publisher(publisher_ptr)?;
                let value = input(data, len)?;
                publisher
                    .set_blueprint_json(value)
                    .map_err(|error| error.to_string())?;
                Ok(String::new())
            },
            std::ptr::null_mut(),
            error,
        )
    }
}

#[no_mangle]
/// # Safety
///
/// The publisher must be valid and `error`, when non-null, must reference
/// writable storage.
pub unsafe extern "C" fn operator_blueprint_clear(
    publisher_ptr: *mut operator_blueprint_publisher_t,
    error: *mut operator_bytes_t,
) -> bool {
    unsafe {
        write_result(
            || {
                publisher(publisher_ptr)?
                    .clear()
                    .map_err(|error| error.to_string())?;
                Ok(String::new())
            },
            std::ptr::null_mut(),
            error,
        )
    }
}

#[no_mangle]
/// # Safety
///
/// The publisher must be valid, `data` must reference `len` readable bytes,
/// and output pointers, when non-null, must reference writable storage.
pub unsafe extern "C" fn operator_blueprint_update_values_json(
    publisher_ptr: *mut operator_blueprint_publisher_t,
    data: *const u8,
    len: usize,
    timestamp_ns: u64,
    sequence: *mut u64,
    error: *mut operator_bytes_t,
) -> bool {
    if let Some(sequence) = unsafe { sequence.as_mut() } {
        *sequence = 0;
    }
    let mut next_sequence = 0;
    let ok = unsafe {
        write_result(
            || {
                let publisher = publisher(publisher_ptr)?;
                let value = input(data, len)?;
                next_sequence = publisher
                    .update_values_json(value, timestamp_ns)
                    .map_err(|error| error.to_string())?;
                Ok(String::new())
            },
            std::ptr::null_mut(),
            error,
        )
    };
    if ok {
        if let Some(sequence) = unsafe { sequence.as_mut() } {
            *sequence = next_sequence;
        }
    }
    ok
}

macro_rules! json_function {
    ($name:ident, $method:ident) => {
        #[no_mangle]
        /// # Safety
        ///
        /// The publisher must be valid and output pointers, when non-null,
        /// must reference writable storage.
        pub unsafe extern "C" fn $name(
            publisher_ptr: *mut operator_blueprint_publisher_t,
            output: *mut operator_bytes_t,
            error: *mut operator_bytes_t,
        ) -> bool {
            unsafe {
                write_result(
                    || {
                        publisher(publisher_ptr)?
                            .$method()
                            .map_err(|error| error.to_string())
                    },
                    output,
                    error,
                )
            }
        }
    };
}

json_function!(
    operator_blueprint_definition_message_json,
    definition_message_json
);
json_function!(operator_blueprint_state_message_json, state_message_json);

#[no_mangle]
/// # Safety
///
/// The publisher must be valid, `data` must reference `len` readable bytes,
/// and output pointers, when non-null, must reference writable storage.
pub unsafe extern "C" fn operator_blueprint_descriptor_message_json(
    publisher_ptr: *mut operator_blueprint_publisher_t,
    data: *const u8,
    len: usize,
    output: *mut operator_bytes_t,
    error: *mut operator_bytes_t,
) -> bool {
    unsafe {
        write_result(
            || {
                let publisher = publisher(publisher_ptr)?;
                publisher
                    .descriptor_message_json(input(data, len)?)
                    .map_err(|error| error.to_string())
            },
            output,
            error,
        )
    }
}

#[no_mangle]
/// # Safety
///
/// The publisher must be valid, `data` must reference `len` readable bytes,
/// and output pointers, when non-null, must reference writable storage.
pub unsafe extern "C" fn operator_blueprint_parse_event_message_json(
    publisher_ptr: *mut operator_blueprint_publisher_t,
    data: *const u8,
    len: usize,
    output: *mut operator_bytes_t,
    error: *mut operator_bytes_t,
) -> bool {
    unsafe {
        write_result(
            || {
                let publisher = publisher(publisher_ptr)?;
                publisher
                    .parse_event_message_json(input(data, len)?)
                    .map_err(|error| error.to_string())
            },
            output,
            error,
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const BLUEPRINT: &str = r#"{"schema":"operator.blueprint.v1","blueprint_id":"test","revision":1,"components":[{"id":"status","type":"status_lamp","bindings":{"state":"status"}}]}"#;

    fn take(value: operator_bytes_t) -> String {
        if value.len == 0 {
            return String::new();
        }
        unsafe {
            String::from_utf8_unchecked(Vec::from_raw_parts(value.data, value.len, value.capacity))
        }
    }

    #[test]
    fn c_api_reports_metadata_and_handles_clear() {
        let hash = operator_blueprint_spec_sha256();
        let hash = unsafe { str::from_utf8_unchecked(slice::from_raw_parts(hash.data, hash.len)) };
        assert_eq!(hash, operator_core::SPEC_SHA256);
        assert_eq!(
            operator_blueprint_spec_version(),
            operator_core::SPEC_VERSION
        );

        let publisher = operator_blueprint_publisher_new();
        assert!(!publisher.is_null());
        let mut error = operator_bytes_t::empty();
        assert!(unsafe {
            operator_blueprint_set_json(publisher, BLUEPRINT.as_ptr(), BLUEPRINT.len(), &mut error)
        });
        assert_eq!(error.len, 0);
        assert!(unsafe { operator_blueprint_clear(publisher, &mut error) });
        assert_eq!(error.len, 0);
        unsafe { operator_blueprint_publisher_free(publisher) };
    }

    #[test]
    fn c_api_rejects_null_publishers_and_initializes_outputs() {
        let mut error = operator_bytes_t::empty();
        let mut sequence = 99;
        assert!(!unsafe {
            operator_blueprint_update_values_json(
                std::ptr::null_mut(),
                std::ptr::null(),
                0,
                0,
                &mut sequence,
                &mut error,
            )
        });
        assert_eq!(sequence, 0);
        assert!(take(error).contains("null Blueprint publisher pointer"));
    }
}
