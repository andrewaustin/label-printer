# Y813BT BLE Printing Notes

## Summary

The KNAON / Y813BT label printer can be printed to from macOS over Bluetooth Low Energy using CoreBluetooth. The printer accepts TSPL commands over a writable BLE characteristic.

This is confirmed working on real hardware. It was first done with a standalone Swift script that printed a `HELLO` TSPL test label and a file-based `.tspl` label. Later, the Label Printer app in this repo printed 4x6 PDF labels.

## Printer Details

From the printer self-test label:

- Model: Y813BT-YT
- Printer language / PCL: TSPL
- Print speed: 5
- Print density: 8
- Interface: USB | BT2.0 | BT4.0
- BT name: Y813BT-XXXX
- BLE name seen by scanner: Y813BT-XXXX-LE (suffix varies per unit)
- BT code: 0000
- Resolution: 203 dpi (a 4x6 in label is 812 × 1218 dots)

## BLE Service and Characteristics

Primary BLE service: `49535343-FE7D-4AE5-8FA9-9FAFD205E455`

| Characteristic | Properties | Status |
| --- | --- | --- |
| `49535343-6DAA-4D02-ABF6-19569ACA69FE` | Read, Write | Unused |
| `49535343-ACA3-481C-91EC-D85E28A60318` | Write, Notify | Works with `.withResponse` writes |
| `49535343-1E4D-4BD9-BA61-23C647249616` | Notify | Unused |
| `49535343-8841-43F4-A8D4-ECBE34729BB3` | Write, Write Without Response | Works with `.withoutResponse` writes; fastest |

## Sending Data

- Send TSPL with CRLF line endings.
- **Acked writes (`ACA3`, `.withResponse`):** chunks of up to 180 bytes, sending the next chunk after each `didWriteValueFor` callback. This is reliable but slow, because every chunk costs a round trip. A full-frame 4x6 bitmap (~124 KB) took about 20 s.
- **Fast writes (`8841`, `.withoutResponse`):** chunks of `maximumWriteValueLength(for: .withoutResponse)`, written while `canSendWriteWithoutResponse` is true and resumed from `peripheralIsReady(toSendWriteWithoutResponse:)`. No extra application-level flow control was needed. The printed label was identical to one sent with acked writes, and the same 4x6 PDF label took about 4 s. The Label Printer app uses this by default.

## Printing Images

- Render the image to 1-bit and send it with `BITMAP x,y,width_bytes,height,0,<raw rows>`. A `0` bit prints black and a `1` bit is white. Rows are packed MSB-first.
- Bluetooth transfer time is the bottleneck, so don't send one full-label bitmap. After `CLS`, send one `BITMAP` per run of non-blank rows (up to 64 rows each), cropped horizontally to the bytes that contain ink. The printer composes the strips correctly. A typical shipping label goes from ~124 KB to ~20 KB.
- Settings used for 4x6: `SIZE 101.6 mm,152.4 mm`, `GAP 2 mm,0`, `DENSITY 8`, `SPEED 5`, `DIRECTION 0`, `REFERENCE 0,0`.

`test-hello.tspl` in this repo is a minimal 40x30 mm text label that is known to work.

## macOS App Requirements

- The app bundle's `Info.plist` needs `NSBluetoothAlwaysUsageDescription`. macOS asks for Bluetooth permission on first launch, and may ask again after an ad-hoc-signed rebuild.
- A sandboxed app needs the Bluetooth entitlement. The Label Printer app isn't sandboxed.
- Quit FlashLabel Pro before connecting from your own app. The printer may only allow one active BLE connection at a time.
- Match the printer by a name beginning with `Y813BT` or by the advertised service UUID. It may already be connected at the system level, so check `retrieveConnectedPeripherals(withServices:)` before scanning.
