package win32_software_rendering

import rm "/raw_mouse"
import "base:runtime"
import "core:fmt"
import "core:image"
import "core:image/png"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:slice"
import win "core:sys/windows"
import "core:time"

_ :: png

Vec2 :: [2]f32
Color :: [4]u8

// Rectangle with position, width and height
Rect :: struct {
	x, y, w, h: f32,
}

// Single bit texture: data is just an array of booleans saying if there is
// color or not there.
Texture :: struct {
	data: []bool,
	w:    int,
	h:    int,
}

Key :: enum {
	None,
	R,
	ESC,
}

Game :: struct {
	texture_atlas: Texture,
	hand_one_pos:  Vec2,
	hand_two_pos:  Vec2,
	ball_pos:      Vec2,
	ball_vel:      Vec2,
}

Mouse_Button :: enum u8 {
	LEFT = 0,
	RIGHT,
	MIDDLE,
}

Mouse_State :: struct {
	// TODO: Use generational handle from lib when implemented
	id:                 win.HANDLE,
	x, y, scroll_wheel: i32,
	button_down:        [Mouse_Button]bool,
	button_pressed:     [Mouse_Button]bool,
	button_released:    [Mouse_Button]bool,
}

App_State :: struct {
	cursor_shown:     bool,
	player_one_mouse: Mouse_State,
	player_two_mouse: Mouse_State,
}

// Game constants
GRAVITY :: Vec2{0, 10}
HAND_BBOX :: Vec2{16, 16}
BALL_BBOX :: Vec2{16, 16}

// The size of the bitmap we will use for drawing. Will be scaled up to window.
SCREEN_WIDTH :: 320
SCREEN_HEIGHT :: 180
MOUSE_SENS_MULT: f32 : 4

game: Game
app_state: App_State

// State of held keys
key_down: [Key]bool

// 2 color palette (1 bit graphics)
PALETTE :: [2]Color{{41, 61, 49, 255}, {241, 167, 189, 255}}

screen_buffer_bitmap_handle: win.HBITMAP

// This is the pixels for the screen. 0 means first color of PALETTE and 1 means
// second color of PALETTE. Higher numbers mean nothing.
screen_buffer: []u8

run := true

main :: proc() {
	context.logger = log.create_console_logger()

	// Make program respect DPI scaling.
	win.SetProcessDPIAware()

	// The handle of this executable. Some Windows API functions use it to
	// identify the running program.
	instance := win.HINSTANCE(win.GetModuleHandleW(nil))
	assert(instance != nil, "Failed to fetch current instance")

	// Create a new type of window with the type name `window_class_name`,
	// `win_proc` is the procedure that is run when the window is sent messages.
	window_class_name := win.L("SoftwareRenderingExample")
	window_class := win.WNDCLASSW {
		lpfnWndProc   = win_proc,
		lpszClassName = window_class_name,
		hInstance     = instance,
	}
	class := win.RegisterClassW(&window_class)
	assert(class != 0, "Class creation failed")

	// Create window, note that we reuse the class name to make this window
	// a window of that type. Other than that we mostly provide a window title,
	// a window size and a position. WS_OVERLAPPEDWINDOW makes this a "normal
	// looking window" and WS_VISIBLE makes the window not hidden. See
	// https://learn.microsoft.com/en-us/windows/win32/winmsg/window-styles for
	// all styles.
	hwnd := win.CreateWindowW(
		window_class_name,
		win.L("Software Rendering"),
		win.WS_OVERLAPPEDWINDOW | win.WS_VISIBLE,
		100,
		100,
		1280,
		720,
		nil,
		nil,
		instance,
		nil,
	)
	assert(hwnd != nil, "Window creation Failed")

	// In case the window doesn't end up in the foreground for some reason.
	win.SetForegroundWindow(hwnd)

	// Init raw_mouse_lib
	if !rm.init_raw_mouse(hwnd) {
		panic("Could not init raw mouse lib")
	}

	// Lock cursor
	app_state.cursor_shown = true
	lock_cursor(hwnd)

	// Load texture atlas
	texture_atlas, texture_atlas_ok := load_texture("texture_atlas.png")

	if !texture_atlas_ok {
		log.error("Failed to load texture_atlas.png")
		return
	}

	game = {
		hand_one_pos  = {SCREEN_WIDTH / 3, SCREEN_HEIGHT / 3 * 2},
		hand_two_pos  = {SCREEN_WIDTH / 3 * 2, SCREEN_HEIGHT / 3 * 2},
		ball_pos      = {SCREEN_WIDTH / 2, 16},
		texture_atlas = texture_atlas,
	}

	// Use built in Odin high resolution timer for tracking frame time.
	prev_time := time.tick_now()

	for run {
		// Calculate frame time: the time from previous to current frame
		dt := f32(time.duration_seconds(time.tick_lap_time(&prev_time)))

		tick(dt, hwnd)

		// This will make WM_PAINT run in the message loop, see wnd_proc
		win.InvalidateRect(hwnd, nil, false)

		pump()

		// Anything on temp allocator is valid until end of frame.
		free_all(context.temp_allocator)
	}

	// Unload resources and libs
	rm.destroy_raw_mouse()
	delete_texture(game.texture_atlas)
}

tick :: proc(dt: f32, hwnd: win.HWND) {
	if key_down[.ESC] {
		unlock_cursor(hwnd)
	}

	if key_down[.R] {
		game.ball_vel = {}
		game.ball_pos = {SCREEN_WIDTH / 2, 16}
	}

	// Update ball "physics"
	game.ball_vel += GRAVITY * dt
	game.ball_pos += game.ball_vel * dt

	game.hand_one_pos.x = f32(app_state.player_one_mouse.x)
	game.hand_one_pos.y = f32(app_state.player_one_mouse.y)

	game.hand_two_pos.x = f32(app_state.player_two_mouse.x)
	game.hand_two_pos.y = f32(app_state.player_two_mouse.y)

	hand_one_rect := Rect {
		x = f32(game.hand_one_pos.x),
		y = f32(game.hand_one_pos.y),
		w = HAND_BBOX.x,
		h = HAND_BBOX.y,
	}

	hand_two_rect := Rect {
		x = f32(game.hand_two_pos.x),
		y = f32(game.hand_two_pos.y),
		w = HAND_BBOX.x,
		h = HAND_BBOX.y,
	}

	ball_rect := Rect {
		x = f32(game.ball_pos.x),
		y = f32(game.ball_pos.y),
		w = BALL_BBOX.x,
		h = BALL_BBOX.y,
	}

	if rects_intersect(ball_rect, hand_one_rect) {
		fmt.println("hand1 intersect")
	}

	if rects_intersect(ball_rect, hand_two_rect) {
		fmt.println("hand2 intersects")
	}
}

calculate_hand_rect :: proc(x, y: i32) -> Rect {
	return Rect{x = f32(x), y = f32(y), w = HAND_BBOX.x, h = HAND_BBOX.y}
}

rects_intersect :: proc(a: Rect, b: Rect) -> bool {
	return a.x <= (b.x + b.w) && (a.x + a.w) >= b.x && (a.y + a.h) >= b.y && a.y <= (b.y + b.h)
}

// Runs Windows message pump. The DispatchMessageW call will run `wnd_proc` if
// the message belongs to this window. `wnd_proc` as specified in the
// `window_class` in `main`.
pump :: proc() {
	msg: win.MSG

	// Use PeekMessage instead of GetMessage to not block and wait for message.
	// This makes it so that our main game loop continues and we can draw frames
	// although no messages occur.
	for win.PeekMessageW(&msg, nil, 0, 0, win.PM_REMOVE) {
		if (msg.message == win.WM_QUIT) {
			run = false
			break
		}

		win.DispatchMessageW(&msg)
	}
}

draw :: proc(hwnd: win.HWND) {
	// This clears the screen.
	slice.zero(screen_buffer)

	// Draw hands
	{
		hand_rect := Rect {
			x = 16,
			y = 0,
			w = HAND_BBOX.x,
			h = HAND_BBOX.y,
		}

		draw_texture(game.texture_atlas, hand_rect, game.hand_one_pos, false)
		draw_texture(game.texture_atlas, hand_rect, game.hand_two_pos, true)
	}

	// Draw the ball
	{
		ball_rect := Rect {
			x = 0,
			y = 0,
			w = BALL_BBOX.x,
			h = BALL_BBOX.y,
		}

		draw_texture(game.texture_atlas, ball_rect, game.ball_pos, false)
	}

	// Begin painting of window. This gives a hdc: A device context handle,
	// which is a handle we can use to instruct the Windows API to draw stuff
	// for us.
	ps: win.PAINTSTRUCT
	dc := win.BeginPaint(hwnd, &ps)

	// Make make dc into an in-memory DC we can draw into. Then select the
	// our screen buffer bitmap, so we can draw it to the screen.
	bitmap_dc := win.CreateCompatibleDC(dc)
	old_bitmap_handle := win.SelectObject(bitmap_dc, win.HGDIOBJ(screen_buffer_bitmap_handle))

	// Get size of window
	client_rect: win.RECT
	win.GetClientRect(hwnd, &client_rect)
	width := client_rect.right - client_rect.left
	height := client_rect.bottom - client_rect.top

	// Draw bitmap onto window. Note that this is stretched to size of window.
	win.StretchBlt(dc, 0, 0, width, height, bitmap_dc, 0, 0, SCREEN_WIDTH, SCREEN_HEIGHT, win.SRCCOPY)

	// Delete the temporary bitmap DC
	win.SelectObject(bitmap_dc, old_bitmap_handle)
	win.DeleteDC(bitmap_dc)

	// This must happen if `BeginPaint` has happened.
	win.EndPaint(hwnd, &ps)
}


// Draw rectangle onto screen by looping over pixels in the rect and setting
// pixels on screen.
draw_rect :: proc(r: Rect) {
	for x in r.x ..< r.x + r.w {
		for y in r.y ..< r.y + r.h {
			idx := int(math.floor(y) * SCREEN_WIDTH) + int(math.floor(x))
			if idx >= 0 && idx < len(screen_buffer) {
				// 1 means the second color in PALETTE
				screen_buffer[idx] = 1
			}
		}
	}
}

// Draws texture `t` on screen. `src` is the rectangle inside `t` to pick stuff
// from. `pos` is where on screen to draw it. `flip_x` flips the texture.
draw_texture :: proc(t: Texture, src: Rect, pos: Vec2, flip_x: bool) {
	for x in 0 ..< src.w {
		for y in 0 ..< src.h {
			sx := x + src.x
			sy := y + src.y
			src_idx := floor_to_int(sy) * t.w + (flip_x ? floor_to_int(src.w - x + src.x) - 1 : floor_to_int(sx))

			if src_idx >= 0 && src_idx < len(t.data) && t.data[src_idx] {
				xx := floor_to_int(pos.x) + floor_to_int(x)
				yy := floor_to_int(pos.y) + floor_to_int(y)

				idx := yy * SCREEN_WIDTH + xx

				if idx >= 0 && idx < len(screen_buffer) {
					// 1 means the second color in PALETTE
					screen_buffer[idx] = 1
				}
			}
		}
	}
}

handle_mouse_update :: proc(mouse_state: ^Mouse_State, raw_mouse: rm.Raw_Mouse) {
	scaled_delta_x := math.ceil(f32(abs(raw_mouse.x)) / MOUSE_SENS_MULT) * math.sign(f32(raw_mouse.x))
	scaled_delta_y := math.ceil(f32(abs(raw_mouse.y)) / MOUSE_SENS_MULT) * math.sign(f32(raw_mouse.y))

	mouse_state.x = math.clamp(i32(scaled_delta_x) + mouse_state.x, 0, SCREEN_WIDTH - 16)
	mouse_state.y = math.clamp(i32(scaled_delta_y) + mouse_state.y, 0, SCREEN_HEIGHT - 16)
	mouse_state.scroll_wheel = raw_mouse.z

	mouse_state.button_pressed[.LEFT] = !mouse_state.button_down[.LEFT] && raw_mouse.left_button_down
	mouse_state.button_pressed[.RIGHT] = !mouse_state.button_down[.RIGHT] && raw_mouse.right_button_down
	mouse_state.button_pressed[.MIDDLE] = !mouse_state.button_down[.MIDDLE] && raw_mouse.middle_button_down

	mouse_state.button_released[.LEFT] = mouse_state.button_down[.LEFT] && !raw_mouse.left_button_down
	mouse_state.button_released[.RIGHT] = mouse_state.button_down[.RIGHT] && !raw_mouse.right_button_down
	mouse_state.button_released[.MIDDLE] = mouse_state.button_down[.MIDDLE] && !raw_mouse.middle_button_down

	mouse_state.button_down[.LEFT] = raw_mouse.left_button_down
	mouse_state.button_down[.RIGHT] = raw_mouse.right_button_down
	mouse_state.button_down[.MIDDLE] = raw_mouse.middle_button_down
}

win_proc :: proc "stdcall" (hwnd: win.HWND, msg: win.UINT, wparam: win.WPARAM, lparam: win.LPARAM) -> win.LRESULT {
	context = runtime.default_context()
	switch (msg) {
	case win.WM_DESTROY:
		// This makes the WM_QUIT message happen, which will set run = false
		win.PostQuitMessage(0)
		return 0

	case win.WM_INPUT:
		raw_mouse, was_updated := rm.update_raw_mouse(win.HRAWINPUT(uintptr(lparam)))
		if was_updated {
			if raw_mouse.handle == app_state.player_one_mouse.id {
				handle_mouse_update(&app_state.player_one_mouse, raw_mouse)
				return 0
			}
			if raw_mouse.handle == app_state.player_two_mouse.id {
				handle_mouse_update(&app_state.player_two_mouse, raw_mouse)
				return 0
			}

			fmt.eprintln("Got raw_mouse:", raw_mouse, "but it is not assigned to any player")
			panic("Unexpected")
		}
		return 0

	case win.WM_INPUT_DEVICE_CHANGE:
		GIDC_ARRIVAL :: 1
		GIDC_REMOVAL :: 2

		switch wparam {
		case GIDC_ARRIVAL:
			fmt.println("added dev:", lparam)
			dev_handle := win.HANDLE(uintptr(lparam))
			if rm.add_raw_mouse(dev_handle) {
				//Assign mouse to player, TODO: Allow player to choose via KB
				if app_state.player_one_mouse.id == nil {
					app_state.player_one_mouse = Mouse_State {
						id = dev_handle,
					}
					break
				}
				if app_state.player_two_mouse.id == nil {
					app_state.player_two_mouse = Mouse_State {
						id = dev_handle,
					}
					break
				}
				fmt.println("Got new device, but all players have one assigned: ", dev_handle)
			}
		case GIDC_REMOVAL:
			fmt.println("removed dev:", lparam)
			dev_handle := win.HANDLE(uintptr(lparam))
			if rm.remove_raw_mouse(dev_handle) {
				if app_state.player_one_mouse.id == dev_handle {
					app_state.player_one_mouse = Mouse_State {
						id = nil,
					}
					break
				}
				if app_state.player_two_mouse.id == dev_handle {
					app_state.player_two_mouse = Mouse_State {
						id = nil,
					}
					break
				}
				fmt.println("Removed a device, but it didnt belong to any player: ", dev_handle)
			}
		}

		return 0

	case win.WM_KEYDOWN:
		switch wparam {
		case win.VK_R:
			key_down[.R] = true
		case win.VK_ESCAPE:
			key_down[.ESC] = true
		}
		return 0

	case win.WM_KEYUP:
		switch wparam {
		case win.VK_R:
			key_down[.R] = false
		case win.VK_ESCAPE:
			key_down[.ESC] = false
		}
		return 0

	case win.WM_PAINT:
		draw(hwnd)
		return 0

	case win.WM_CREATE:
		dc := win.GetDC(hwnd)

		// Create bitmap for drawing into. For this bitmap setup I got some help
		// from this win32 software rendering example:
		// https://github.com/odin-lang/examples/blob/master/win32/game_of_life/game_of_life.odin

		// There is a BITMAPINFO in windows API, but to make it easier to
		// specify our palette we make our own.
		Bitmap_Info :: struct {
			bmiHeader: win.BITMAPINFOHEADER,
			bmiColors: [len(PALETTE)]Color,
		}

		bitmap_info := Bitmap_Info {
			bmiHeader = win.BITMAPINFOHEADER {
				biSize        = size_of(win.BITMAPINFOHEADER),
				biWidth       = SCREEN_WIDTH,
				biHeight      = -SCREEN_HEIGHT, // Minus for top-down
				biPlanes      = 1,
				biBitCount    = 8, // We are actually doing 1 bit graphics, but 8 bit is minimum bitmap size.
				biCompression = win.BI_RGB,
				biClrUsed     = len(PALETTE), // Palette contains 2 colors. This tells it how big the bmiColors in the palette actually is.
			},
			bmiColors = PALETTE,
		}

		// buf will contain our pixels, of the size we specify in bitmap_info
		buf: [^]u8
		screen_buffer_bitmap_handle = win.CreateDIBSection(dc, cast(^win.BITMAPINFO)&bitmap_info, win.DIB_RGB_COLORS, &buf, nil, 0)

		// Make a slice we can use for drawing onto the screen
		screen_buffer = slice.from_ptr(buf, SCREEN_WIDTH * SCREEN_HEIGHT)

		win.ReleaseDC(hwnd, dc)

		return 0
	}

	return win.DefWindowProcW(hwnd, msg, wparam, lparam)
}

floor_to_int :: proc(v: f32) -> int {
	return int(math.floor(v))
}

// Loads an iomage with a specific filename and makes it into a `Texture` struct
load_texture :: proc(filename: string) -> (Texture, bool) {
	img, img_err := image.load_from_file(filename, allocator = context.temp_allocator)

	if img_err != nil {
		log.error(img_err)
		return {}, false
	}

	if img.channels != 4 || img.depth != 8 {
		// This is just because of my hack below to figure out the palette color.
		log.error("Only images with 4 channels and 8 bits per channel are supported.")
		return {}, false
	}

	tex := Texture {
		data = make([]bool, img.width * img.height),
		w    = img.width,
		h    = img.height,
	}

	// This is a hack to convert from RGBA texture to single bit texture. We
	// loop over pixels and only look at alpha value. If alpha is larger than
	// 100, then the pixel is set, otherwise it is not.
	for pi in 0 ..< img.width * img.height {
		i := pi * 4 + 1
		tex.data[pi] = img.pixels.buf[i] > 100
	}

	return tex, true
}

delete_texture :: proc(t: Texture) {
	delete(t.data)
}

// https://learn.microsoft.com/en-us/windows/win32/menurc/using-cursors
lock_cursor :: proc(hwnd: win.HWND) {
	if !app_state.cursor_shown do return

	rect: win.RECT
	win.GetClientRect(hwnd, &rect)
	win.MapWindowPoints(hwnd, nil, &rect, 2)
	if !win.ClipCursor(&rect) {
		fmt.eprintln("Could not lock cursor")
	}
	if win.ShowCursor(false) != -1 {
		fmt.eprintln("Cursor could not be hidden, display count is not -1")
	}
	app_state.cursor_shown = false
}

unlock_cursor :: proc(hwnd: win.HWND) {
	if app_state.cursor_shown do return

	if !win.ClipCursor(nil) {
		fmt.eprintln("Could not unlock cursor")
	}
	if win.ShowCursor(true) != 0 {
		fmt.eprintln("Cursor could not shown, display count is not 0")
	}
	app_state.cursor_shown = true
}
