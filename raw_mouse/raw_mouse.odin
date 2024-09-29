package raw_mouse

import "core:fmt"
import "core:mem"
import "core:strings"
import win "core:sys/windows"

MAX_MOUSE_BUTTONS :: 3

// TODO: Refactor / "private" vars 
mouse_list: [dynamic]Raw_Mouse

Raw_Mouse :: struct {
	handle:          win.HANDLE,
	x:               i32,
	y:               i32,
	z:               i32,
	buttons_pressed: [MAX_MOUSE_BUTTONS]bool,
}

init_raw_mouse :: proc(hwnd: win.HWND, allocator := context.allocator) -> bool {
	// Get all raw input devices
	devices := _get_raw_devices(allocator) or_return

	// Init mouse list memory (4 mice by default)
	mouse_list = make([dynamic]Raw_Mouse, 0, 4, allocator = allocator)

	// Get all mouses
	RDP_String := "\\??\\Root#RDP_MOU#0000#"
	for device in devices {
		if device.dwType != win.RIM_TYPEMOUSE do continue

		size: u32
		if win.GetRawInputDeviceInfoW(device.hDevice, win.RIDI_DEVICENAME, nil, &size) != 0 {
			fmt.eprintln("Could not get device name size, ignoring...")
			continue
		}

		device_name_buf := make([]u8, size, allocator)
		if win.GetRawInputDeviceInfoW(device.hDevice, win.RIDI_DEVICENAME, raw_data(device_name_buf), &size) == 4294967295 {
			fmt.eprintln("Could not get device name, ignoring...")
			continue
		}
		device_name := transmute(string)device_name_buf

		// Skip RDP mouse (Windows terminal / remote desktop)
		if !strings.contains(device_name, RDP_String) {
			if win.GetRawInputDeviceInfoW(device.hDevice, win.RIDI_DEVICEINFO, nil, &size) != 0 {
				fmt.eprintln("Could not get size of Device Info struct for device:", device)
				continue
			}

			mouse_info := win.RID_DEVICE_INFO {
				cbSize = u32(size_of(win.RID_DEVICE_INFO)),
			}

			if win.GetRawInputDeviceInfoW(device.hDevice, win.RIDI_DEVICEINFO, &mouse_info, &size) == 4294967295 {
				fmt.eprintln("Could not get information for device:", device)
				continue
			}

			mouse := Raw_Mouse {
				handle = device.hDevice,
			}
			append(&mouse_list, mouse)
		}
	}

	// Register the app so it receives raw input
	return _register_raw_mouse(hwnd)
}

@(private)
_get_raw_devices :: proc(allocator := context.allocator) -> (devices: []win.RAWINPUTDEVICELIST, ok: bool) {
	num_devices: u32
	if win.GetRawInputDeviceList(nil, &num_devices, size_of(win.RAWINPUTDEVICELIST)) != 0 {
		fmt.eprintln("Could not get raw input device count")
		return []win.RAWINPUTDEVICELIST{}, false
	}

	if num_devices <= 0 {
		fmt.println("No mouses, returning gracefully")
		return []win.RAWINPUTDEVICELIST{}, true
	}

	returned_devices := make([]win.RAWINPUTDEVICELIST, num_devices, allocator)
	// TODO: Check if error case is being handled correctly on all systems
	// https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getrawinputdevicelist#return-value
	if win.GetRawInputDeviceList(raw_data(returned_devices), &num_devices, size_of(win.RAWINPUTDEVICELIST)) == 4294967295 {
		fmt.eprintln("Could not get raw input device list")
		return []win.RAWINPUTDEVICELIST{}, false
	}

	return returned_devices, true
}

@(private)
_register_raw_mouse :: proc(hwnd: win.HWND) -> bool {
	raw_input_device := win.RAWINPUTDEVICE {
		usUsagePage = win.HID_USAGE_PAGE_GENERIC,
		usUsage     = win.HID_USAGE_GENERIC_MOUSE,
		dwFlags     = win.RIDEV_DEVNOTIFY,
		hwndTarget  = hwnd,
	}

	if !win.RegisterRawInputDevices(&raw_input_device, 1, size_of(win.RAWINPUTDEVICELIST)) {
		fmt.eprintln("Could not register the current hwnd as a raw device.")
		return false
	}

	return true
}

// https://ph3at.github.io/posts/Windows-Input/
update_raw_mouse :: proc(dHandle: win.HRAWINPUT) -> bool {
	size: u32
	if win.GetRawInputData(dHandle, win.RID_INPUT, nil, &size, size_of(win.RAWINPUTHEADER)) != 0 {
		fmt.eprintln("Could not raw input data header size for device:", dHandle)
		return false
	}

	raw_input := win.RAWINPUT{}
	if win.GetRawInputData(dHandle, win.RID_INPUT, &raw_input, &size, size_of(win.RAWINPUTHEADER)) == 4294967295 {
		fmt.eprintln("Could not populate raw input header on device:", dHandle)
		return false
	}

	for &mouse in mouse_list {
		if mouse.handle == raw_input.header.hDevice {
			// Position data
			mouse.x += raw_input.data.mouse.lLastX
			mouse.y += raw_input.data.mouse.lLastY

			// Mouse buttons
			if (raw_input.data.mouse.usButtonFlags & win.RI_MOUSE_BUTTON_1_DOWN) > 0 do mouse.buttons_pressed[0] = true
			if (raw_input.data.mouse.usButtonFlags & win.RI_MOUSE_BUTTON_1_UP) > 0 do mouse.buttons_pressed[0] = false
			if (raw_input.data.mouse.usButtonFlags & win.RI_MOUSE_BUTTON_2_DOWN) > 0 do mouse.buttons_pressed[1] = true
			if (raw_input.data.mouse.usButtonFlags & win.RI_MOUSE_BUTTON_2_UP) > 0 do mouse.buttons_pressed[1] = false
			if (raw_input.data.mouse.usButtonFlags & win.RI_MOUSE_BUTTON_3_DOWN) > 0 do mouse.buttons_pressed[2] = true
			if (raw_input.data.mouse.usButtonFlags & win.RI_MOUSE_BUTTON_3_UP) > 0 do mouse.buttons_pressed[2] = false

			// Mouse wheel
			if (raw_input.data.mouse.usButtonFlags & win.RI_MOUSE_WHEEL) > 0 {
				if (i16(raw_input.data.mouse.usButtonData) > 0) {
					mouse.z += 1
				}
				if (i16(raw_input.data.mouse.usButtonData) < 0) {
					mouse.z -= 1
				}
			}

			fmt.println(mouse)
		}
	}

	return true
}
