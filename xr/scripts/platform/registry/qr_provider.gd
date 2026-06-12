class_name QrProvider
extends RefCounted
## QR_SCAN provider: wraps the QRScannerPlugin singleton so app code does not
## reference the vendor singleton name directly.

const SINGLETON := "QRScannerPlugin"


static func bind() -> Object:
	if Engine.has_singleton(SINGLETON):
		return Engine.get_singleton(SINGLETON)
	return null


static func is_available() -> bool:
	return Engine.has_singleton(SINGLETON)
