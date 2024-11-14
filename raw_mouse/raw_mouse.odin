package raw_mouse

import "core:c"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:strings"
import win "core:sys/windows"

Mouse_Button :: enum u8 {
	LEFT = 0,
	RIGHT,
	MIDDLE,
}

Raw_Mouse_State :: struct {
	handle:             win.HANDLE,
	device_name:        string,
	delta_x:            i32,
	delta_y:            i32,
	scroll_wheel_delta: i32,
	button_down:        [Mouse_Button]bool,
}

RAW_ERROR_VALUE :: transmute(win.UINT)i32(-1)
RDP_STRING :: "\\??\\Root#RDP_MOU#0000#"

registered_mice: map[win.HANDLE]Raw_Mouse_State
lib_allocator: mem.Allocator
ready: bool = false

// TODO: Remove all fmt.xxx calls, use logging

// Inits the library, if report_device_changes is false, all the devices must be manually added using 
// add_all_connected_mice. Otherwise, the message should be handled by calling add or remove raw mouse.
init_raw_mouse :: proc(hwnd: win.HWND, report_device_changes: bool = true, allocator := context.allocator) -> bool {
	// Save the allocator for all further operations
	lib_allocator = allocator

	// Init mouse info memory
	registered_mice = make(map[win.HANDLE]Raw_Mouse_State, allocator = lib_allocator)

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

	ready = true
	return true
}

// Adds all mice currently connected to the system (excludes RDP mouse if detected)
add_all_connected_mice :: proc() -> bool {
	if !ready {
		fmt.eprintln("Cannot add mice, library is not yet initialized")
		return false
	}

	num_devices: u32
	if win.GetRawInputDeviceList(nil, &num_devices, size_of(win.RAWINPUTDEVICELIST)) != 0 {
		fmt.eprintln("Could not get raw input device count")
		return false
	}

	if num_devices <= 0 {
		fmt.println("No devices, returning gracefully")
		return true
	}

	devices := make([]win.RAWINPUTDEVICELIST, num_devices, context.temp_allocator)
	if win.GetRawInputDeviceList(raw_data(devices), &num_devices, size_of(win.RAWINPUTDEVICELIST)) == RAW_ERROR_VALUE {
		fmt.eprintln("Could not get raw input device list")
		return false
	}

	for device in devices {
		device_name_buf, validated := validate_and_get_device_name(device.hDevice, device.dwType)
		if validated {
			mouse := Raw_Mouse_State {
				handle      = device.hDevice,
				device_name = transmute(string)device_name_buf,
			}

			registered_mice[device.hDevice] = mouse
		}
	}

	return true
}

@(private)
validate_and_get_device_name :: proc(hDevice: win.HANDLE, dwType: win.DWORD) -> (device_name_buf: []u8, validated: bool) {
	if dwType != win.RIM_TYPEMOUSE do return nil, false

	size: u32
	if win.GetRawInputDeviceInfoW(hDevice, win.RIDI_DEVICENAME, nil, &size) != 0 {
		fmt.eprintln("Could not get device name size, ignoring...")
		return nil, false
	}

	device_name_buf = make([]u8, size, lib_allocator)
	if win.GetRawInputDeviceInfoW(hDevice, win.RIDI_DEVICENAME, raw_data(device_name_buf), &size) == RAW_ERROR_VALUE {
		fmt.eprintln("Could not get device name, ignoring...")
		return nil, false
	}
	device_name_str := transmute(string)device_name_buf

	// Skip RDP mouse (Windows terminal / remote desktop)
	if strings.contains(device_name_str, RDP_STRING) {
		return nil, false
	}

	return device_name_buf, true
}

// https://ph3at.github.io/posts/Windows-Input/
update_raw_mouse :: proc(dHandle: win.HRAWINPUT) -> (mouse_state: Raw_Mouse_State, updated: bool) {
	if !ready {
		fmt.eprintln("Cannot update mouse, library is not yet initialized")
		return Raw_Mouse_State{}, false
	}

	size: u32
	if win.GetRawInputData(dHandle, win.RID_INPUT, nil, &size, size_of(win.RAWINPUTHEADER)) != 0 {
		fmt.eprintln("Could not raw input data header size for device:", dHandle)
		return Raw_Mouse_State{}, false
	}

	raw_input := win.RAWINPUT{}
	if win.GetRawInputData(dHandle, win.RID_INPUT, &raw_input, &size, size_of(win.RAWINPUTHEADER)) == RAW_ERROR_VALUE {
		fmt.eprintln("Could not populate raw input header on device:", dHandle)
		return Raw_Mouse_State{}, false
	}

	// Windows only reports state changes, therefore we must constantly write over the last state
	// in order to ensure button presses mantain their state (if there's no update, it is still pressed
	// even if the mouse just moved and windows only reports that)
	last_mouse_state, exists := &registered_mice[raw_input.header.hDevice]
	if exists {
		// Set handle
		last_mouse_state.handle = raw_input.header.hDevice

		// Position data
		last_mouse_state.delta_x = raw_input.data.mouse.lLastX
		last_mouse_state.delta_y = raw_input.data.mouse.lLastY

		// Mouse buttons
		if (raw_input.data.mouse.usButtonFlags & win.RI_MOUSE_BUTTON_1_DOWN) > 0 do last_mouse_state.button_down[.LEFT] = true
		if (raw_input.data.mouse.usButtonFlags & win.RI_MOUSE_BUTTON_1_UP) > 0 do last_mouse_state.button_down[.LEFT] = false

		if (raw_input.data.mouse.usButtonFlags & win.RI_MOUSE_BUTTON_2_DOWN) > 0 do last_mouse_state.button_down[.RIGHT] = true
		if (raw_input.data.mouse.usButtonFlags & win.RI_MOUSE_BUTTON_2_UP) > 0 do last_mouse_state.button_down[.RIGHT] = false

		if (raw_input.data.mouse.usButtonFlags & win.RI_MOUSE_BUTTON_3_DOWN) > 0 do last_mouse_state.button_down[.MIDDLE] = true
		if (raw_input.data.mouse.usButtonFlags & win.RI_MOUSE_BUTTON_3_UP) > 0 do last_mouse_state.button_down[.MIDDLE] = false

		// Mouse wheel
		if (raw_input.data.mouse.usButtonFlags & win.RI_MOUSE_WHEEL) > 0 {
			if (i16(raw_input.data.mouse.usButtonData) > 0) {
				last_mouse_state.scroll_wheel_delta += 1
			}
			if (i16(raw_input.data.mouse.usButtonData) < 0) {
				last_mouse_state.scroll_wheel_delta -= 1
			}
		}

		return last_mouse_state^, true
	}

	return Raw_Mouse_State{}, false
}

add_raw_mouse :: proc(hDevice: win.HANDLE) -> bool {
	if !ready {
		fmt.eprintln("Cannot add mouse, library is not yet initialized")
		return false
	}

	size: u32
	if win.GetRawInputDeviceInfoW(hDevice, win.RIDI_DEVICEINFO, nil, &size) != 0 {
		fmt.eprintln("Could not get size of Device Info struct for device:", hDevice)
		return false
	}

	mouse_info := win.RID_DEVICE_INFO {
		cbSize = u32(size_of(win.RID_DEVICE_INFO)),
	}

	if win.GetRawInputDeviceInfoW(hDevice, win.RIDI_DEVICEINFO, &mouse_info, &size) == RAW_ERROR_VALUE {
		fmt.eprintln("Could not get information for device:", hDevice)
		return false
	}

	device_name_buf, validated := validate_and_get_device_name(hDevice, mouse_info.dwType)
	if validated {
		mouse := Raw_Mouse_State {
			handle      = hDevice,
			device_name = transmute(string)device_name_buf,
		}
		registered_mice[hDevice] = mouse
		return true
	}

	return false
}

remove_raw_mouse :: proc(dHandle: win.HANDLE) -> bool {
	if !ready {
		fmt.eprintln("Cannot remove mouse, library is not yet initialized")
		return false
	}

	if !(dHandle in registered_mice) do return false

	delete_key(&registered_mice, dHandle)

	return true
}

get_raw_mouse_info :: proc(dHandle: win.HANDLE) -> (mouse_info: Raw_Mouse_State, ok: bool) {
	if !ready {
		fmt.eprintln("Cannot get mouse, library is not yet initialized")
		return Raw_Mouse_State{}, false
	}

	mouse_info, ok = registered_mice[dHandle]

	return mouse_info, ok
}

// Clears all device names and mouse list
destroy_raw_mouse :: proc() {
	if !ready do return

	for _, info in registered_mice {
		delete(info.device_name)
	}
	delete(registered_mice)
	ready = false
}
