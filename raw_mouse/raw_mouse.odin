package raw_mouse

import "core:fmt"
import "core:math"
import "core:mem"
import "core:strings"
import win "core:sys/windows"

mouse_list: [dynamic]Raw_Mouse

Raw_Mouse :: struct {
	handle:             win.HANDLE,
	x:                  i32,
	y:                  i32,
	z:                  i32,
	left_button_down:   bool,
	right_button_down:  bool,
	middle_button_down: bool,
}

// Inits the library, if report_device_changes is false, all the devices must be manually added using 
// get_valid_raw_mice_handles and add_raw_mouse. Otherwise, the message should be handled by calling add or remove raw mouse.
init_raw_mouse :: proc(hwnd: win.HWND, report_device_changes: bool = true, allocator := context.allocator) -> bool {
	// Init mouse list memory (4 mice by default)
	mouse_list = make([dynamic]Raw_Mouse, 0, 4, allocator = allocator)

	dwFlags: u32
	if report_device_changes do dwFlags = win.RIDEV_DEVNOTIFY

	raw_input_device := win.RAWINPUTDEVICE {
		usUsagePage = win.HID_USAGE_PAGE_GENERIC,
		usUsage     = win.HID_USAGE_GENERIC_MOUSE,
		dwFlags     = dwFlags,
		hwndTarget  = hwnd,
	}

	if !win.RegisterRawInputDevices(&raw_input_device, 1, size_of(win.RAWINPUTDEVICELIST)) {
		fmt.eprintln("Could not register the current hwnd as a raw device.")
		return false
	}

	return true
}

// Returns the handles of all mice currently connected to the system for later use with add_raw_mouse (excludes RDP mouse if detected)
get_valid_raw_mice_handles :: proc(allocator := context.allocator) -> (handles: []win.HANDLE, ok: bool) {
	num_devices: u32
	if win.GetRawInputDeviceList(nil, &num_devices, size_of(win.RAWINPUTDEVICELIST)) != 0 {
		fmt.eprintln("Could not get raw input device count")
		return []win.HANDLE{}, false
	}

	if num_devices <= 0 {
		fmt.println("No mouses, returning gracefully")
		return []win.HANDLE{}, true
	}

	devices := make([]win.RAWINPUTDEVICELIST, num_devices, allocator)
	// TODO: Check if error case is being handled correctly on all systems
	// https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getrawinputdevicelist#return-value
	if win.GetRawInputDeviceList(raw_data(devices), &num_devices, size_of(win.RAWINPUTDEVICELIST)) == 4294967295 {
		fmt.eprintln("Could not get raw input device list")
		return []win.HANDLE{}, false
	}

	valid_handles := make([dynamic]win.HANDLE, 0, len(devices))

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
			append(&valid_handles, device.hDevice)
		}
	}

	return valid_handles[:], true
}

update_mouse_pos_proc :: proc(mouse: Raw_Mouse, deltaX: i32, deltaY: i32) -> (x: i32, y: i32)

// https://ph3at.github.io/posts/Windows-Input/
update_raw_mouse :: proc(dHandle: win.HRAWINPUT) -> (raw_mouse: Raw_Mouse, updated: bool) {
	raw_mouse = Raw_Mouse{}

	size: u32
	if win.GetRawInputData(dHandle, win.RID_INPUT, nil, &size, size_of(win.RAWINPUTHEADER)) != 0 {
		fmt.eprintln("Could not raw input data header size for device:", dHandle)
		return raw_mouse, false
	}

	raw_input := win.RAWINPUT{}
	if win.GetRawInputData(dHandle, win.RID_INPUT, &raw_input, &size, size_of(win.RAWINPUTHEADER)) == 4294967295 {
		fmt.eprintln("Could not populate raw input header on device:", dHandle)
		return raw_mouse, false
	}

	for &mouse in mouse_list {
		if mouse.handle == raw_input.header.hDevice {
			// Position data
			mouse.x = raw_input.data.mouse.lLastX
			mouse.y = raw_input.data.mouse.lLastY

			// Mouse buttons
			if (raw_input.data.mouse.usButtonFlags & win.RI_MOUSE_BUTTON_1_DOWN) > 0 do mouse.left_button_down = true
			if (raw_input.data.mouse.usButtonFlags & win.RI_MOUSE_BUTTON_1_UP) > 0 do mouse.left_button_down = false

			if (raw_input.data.mouse.usButtonFlags & win.RI_MOUSE_BUTTON_2_DOWN) > 0 do mouse.right_button_down = true
			if (raw_input.data.mouse.usButtonFlags & win.RI_MOUSE_BUTTON_2_UP) > 0 do mouse.right_button_down = false

			if (raw_input.data.mouse.usButtonFlags & win.RI_MOUSE_BUTTON_3_DOWN) > 0 do mouse.middle_button_down = true
			if (raw_input.data.mouse.usButtonFlags & win.RI_MOUSE_BUTTON_3_UP) > 0 do mouse.middle_button_down = false

			// Mouse wheel
			if (raw_input.data.mouse.usButtonFlags & win.RI_MOUSE_WHEEL) > 0 {
				if (i16(raw_input.data.mouse.usButtonData) > 0) {
					mouse.z += 1
				}
				if (i16(raw_input.data.mouse.usButtonData) < 0) {
					mouse.z -= 1
				}
			}

			return mouse, true
		}
	}

	return raw_mouse, false
}

add_raw_mouse :: proc(hDevice: win.HANDLE) -> bool {
	size: u32
	if win.GetRawInputDeviceInfoW(hDevice, win.RIDI_DEVICEINFO, nil, &size) != 0 {
		fmt.eprintln("Could not get size of Device Info struct for device:", hDevice)
		return false
	}

	mouse_info := win.RID_DEVICE_INFO {
		cbSize = u32(size_of(win.RID_DEVICE_INFO)),
	}

	if win.GetRawInputDeviceInfoW(hDevice, win.RIDI_DEVICEINFO, &mouse_info, &size) == 4294967295 {
		fmt.eprintln("Could not get information for device:", hDevice)
		return false
	}

	mouse := Raw_Mouse {
		handle = hDevice,
	}
	append(&mouse_list, mouse)

	return true
}

// TODO: Deal with how mouses are exposed, needs generational handles
remove_raw_mouse :: proc(dHandle: win.HANDLE) -> bool {
	pos: int = -1
	for mouse, i in mouse_list {
		if mouse.handle == dHandle {
			pos = i
			break
		}
	}

	if pos == -1 do return false

	unordered_remove(&mouse_list, pos)

	return true
}

get_raw_mouse :: proc(mouse_id: int) -> (mouse: Raw_Mouse, ok: bool) {
	if mouse_id >= len(mouse_list) || mouse_id < 0 do return Raw_Mouse{}, false

	return mouse_list[mouse_id], true
}

destroy_raw_mouse :: proc() {
	delete(mouse_list)
}
