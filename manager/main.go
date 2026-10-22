//go:build windows

// Diagnostic Workstation Manager - Win32 per-user universal setup and supervisor.
package main

import (
	"embed"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"syscall"
	"time"
	"unsafe"
)

//go:embed assets/*
var assets embed.FS

const (
	WS_OVERLAPPEDWINDOW = 0x00CF0000
	WS_VISIBLE          = 0x10000000
	WS_CHILD            = 0x40000000
	WS_TABSTOP          = 0x00010000
	WS_BORDER           = 0x00800000
	WS_VSCROLL          = 0x00200000
	CBS_DROPDOWNLIST    = 0x0003
	BS_AUTOCHECKBOX     = 0x00000003
	ES_MULTILINE        = 0x0004
	ES_READONLY         = 0x0800
	ES_AUTOVSCROLL      = 0x0040
	WM_DESTROY          = 2
	WM_COMMAND          = 0x0111
	WM_CREATE           = 1
	WM_SETFONT          = 0x0030
	WM_CTLCOLORSTATIC   = 0x0138
	WM_APP_STATUS       = 0x8001
	WM_CLOSE            = 0x0010
	CBN_SELCHANGE       = 1
	BN_CLICKED          = 0
	CB_ADDSTRING        = 0x0143
	CB_GETCURSEL        = 0x0147
	CB_SETCURSEL        = 0x014E
	BM_GETCHECK         = 0x00F0
	BM_SETCHECK         = 0x00F1
	BST_CHECKED         = 1
	PBM_SETPOS          = 0x0402
	SW_SHOW             = 5
	SW_HIDE             = 0
	GWLP_WNDPROC        = -4
	createNoWindow      = 0x08000000
	MB_ICONERROR        = 0x10
	MB_ICONINFORMATION  = 0x40
	MB_YESNO            = 4
	MB_ICONQUESTION     = 0x20
	IDYES               = 6
	WM_USER             = 0x0400
)

type POINT struct{ X, Y int32 }
type MSG struct {
	Hwnd           uintptr
	Message        uint32
	_pad0          uint32
	WParam, LParam uintptr
	Time           uint32
	Pt             POINT
	LPrivate       uint32
}
type WNDCLASSEX struct {
	Size                                                            uint32
	Style                                                           uint32
	WndProc                                                         uintptr
	ClsExtra, WndExtra                                              int32
	Instance, Icon, Cursor, Background, MenuName, ClassName, IconSm uintptr
}

var (
	u32                                                                                           = syscall.NewLazyDLL("user32.dll")
	g32                                                                                           = syscall.NewLazyDLL("gdi32.dll")
	k32                                                                                           = syscall.NewLazyDLL("kernel32.dll")
	registerClass                                                                                 = u32.NewProc("RegisterClassExW")
	createWindow                                                                                  = u32.NewProc("CreateWindowExW")
	defaultProc                                                                                   = u32.NewProc("DefWindowProcW")
	sendMessage                                                                                   = u32.NewProc("SendMessageW")
	postMessage                                                                                   = u32.NewProc("PostMessageW")
	showWindow                                                                                    = u32.NewProc("ShowWindow")
	updateWindow                                                                                  = u32.NewProc("UpdateWindow")
	getMessage                                                                                    = u32.NewProc("GetMessageW")
	translateMessage                                                                              = u32.NewProc("TranslateMessage")
	dispatchMessage                                                                               = u32.NewProc("DispatchMessageW")
	destroyWindow                                                                                 = u32.NewProc("DestroyWindow")
	postQuit                                                                                      = u32.NewProc("PostQuitMessage")
	enableWindow                                                                                  = u32.NewProc("EnableWindow")
	setWindowText                                                                                 = u32.NewProc("SetWindowTextW")
	messageBox                                                                                    = u32.NewProc("MessageBoxW")
	loadCursor                                                                                    = u32.NewProc("LoadCursorW")
	setBkMode                                                                                     = g32.NewProc("SetBkMode")
	setTextColor                                                                                  = g32.NewProc("SetTextColor")
	createBrush                                                                                   = g32.NewProc("CreateSolidBrush")
	createFont                                                                                    = g32.NewProc("CreateFontW")
	hwnd, combo, installBtn, uninstallBtn, legacyBtn, statusBox, brandLabel, startCheck, progress uintptr
	fontBody, fontHeadline, backgroundBrush                                                       uintptr
	brands                                                                                        []brand
	stateMu                                                                                       sync.Mutex
	statusText                                                                                    string
	busy                                                                                          bool
)

type brand struct {
	ID          string `json:"id"`
	DisplayName string `json:"displayName"`
	Short       string `json:"short"`
	Accent      string `json:"accent"`
	AccentSoft  string `json:"accentSoft"`
	Logo        string `json:"logo"`
	Apps        []app  `json:"apps"`
}
type app struct {
	Name, Path, Icon, Symbol, Description string
	Enabled, ShowDescription              bool
}
type profile struct {
	ID           string `json:"id"`
	DisplayName  string `json:"displayName"`
	Short        string `json:"short"`
	UpdateFamily string `json:"updateFamily"`
	Accent       string `json:"accent"`
	AccentSoft   string `json:"accentSoft"`
	Logo         string `json:"logo"`
}

func ptr(s string) *uint16       { p, _ := syscall.UTF16PtrFromString(s); return p }
func color(r, g, b byte) uintptr { return uintptr(uint32(r) | uint32(g)<<8 | uint32(b)<<16) }
func callText(proc *syscall.LazyProc, s string, args ...uintptr) uintptr {
	p := ptr(s)
	all := append(args, uintptr(unsafe.Pointer(p)))
	r, _, _ := proc.Call(all...)
	runtime.KeepAlive(p)
	return r
}
func notify(title, msg string, flags uintptr) int {
	a, b := ptr(title), ptr(msg)
	r, _, _ := messageBox.Call(hwnd, uintptr(unsafe.Pointer(b)), uintptr(unsafe.Pointer(a)), flags)
	runtime.KeepAlive(a)
	runtime.KeepAlive(b)
	return int(r)
}
func create(class, text string, style uint32, x, y, w, h int32, parent uintptr, id uintptr) uintptr {
	c, t := ptr(class), ptr(text)
	ret, _, _ := createWindow.Call(0, uintptr(unsafe.Pointer(c)), uintptr(unsafe.Pointer(t)), uintptr(style), uintptr(x), uintptr(y), uintptr(w), uintptr(h), parent, id, 0, 0)
	runtime.KeepAlive(c)
	runtime.KeepAlive(t)
	if ret != 0 && fontBody != 0 {
		sendMessage.Call(ret, WM_SETFONT, fontBody, 1)
	}
	return ret
}
func editText(control uintptr, text string) {
	p := ptr(text)
	setWindowText.Call(control, uintptr(unsafe.Pointer(p)))
	runtime.KeepAlive(p)
}
func post(text string, pct int) {
	stateMu.Lock()
	statusText = text
	stateMu.Unlock()
	if hwnd != 0 {
		postMessage.Call(hwnd, WM_APP_STATUS, uintptr(pct), 0)
	}
}
func setBusy(v bool) {
	busy = v
	for _, c := range []uintptr{combo, installBtn, uninstallBtn, legacyBtn} {
		enableWindow.Call(c, func() uintptr {
			if v {
				return 0
			}
			return 1
		}())
	}
}
func wproc(h uintptr, msg uint32, w, l uintptr) uintptr {
	switch msg {
	case WM_CREATE:
		return 0
	case WM_CTLCOLORSTATIC:
		setBkMode.Call(w, 1)
		setTextColor.Call(w, color(226, 237, 248))
		return backgroundBrush
	case WM_APP_STATUS:
		stateMu.Lock()
		s := statusText
		stateMu.Unlock()
		editText(statusBox, s)
		if l != 1 {
			sendMessage.Call(progress, PBM_SETPOS, w, 0)
		}
		if l == 1 {
			setBusy(false)
		}
		return 0
	case WM_COMMAND:
		id := uint16(w & 0xffff)
		note := uint16((w >> 16) & 0xffff)
		if id == 100 && note == CBN_SELCHANGE {
			updateSelected()
			return 0
		}
		if note != BN_CLICKED {
			return 0
		}
		switch id {
		case 200:
			if !busy {
				selectInstall()
			}
		case 201:
			if !busy {
				startTask("uninstall")
			}
		case 202:
			if !busy {
				startTask("legacy")
			}
		case 203:
			destroyWindow.Call(h)
		}
		return 0
	case WM_DESTROY:
		postQuit.Call(0)
		return 0
	}
	r, _, _ := defaultProc.Call(h, uintptr(msg), w, l)
	return r
}
func updateSelected() {
	i, _, _ := sendMessage.Call(combo, CB_GETCURSEL, 0, 0)
	if len(brands) == 0 || int(i) < 0 || int(i) >= len(brands) {
		return
	}
	b := brands[i]
	editText(brandLabel, fmt.Sprintf("%s  •  Diagnostics launcher, glass dock, ADMIN, SYSTEM menu\n%s", b.DisplayName, "No manufacturer software or licenses are included."))
}
func mainUI() {
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	brandBytes, err := assets.ReadFile("assets/brands.json")
	if err != nil {
		panic(err)
	}
	if err = json.Unmarshal(brandBytes, &brands); err != nil {
		panic(err)
	}
	brands = brandsMatching(brands, embeddedBrand)
	syscall.NewLazyDLL("comctl32.dll").NewProc("InitCommonControls").Call()
	backgroundBrush, _, _ = createBrush.Call(color(16, 27, 43))
	face := ptr("Segoe UI")
	fontBody, _, _ = createFont.Call(18, 0, 0, 0, 400, 0, 0, 0, 1, 0, 0, 0, 0, uintptr(unsafe.Pointer(face)))
	fontHeadline, _, _ = createFont.Call(28, 0, 0, 0, 600, 0, 0, 0, 1, 0, 0, 0, 0, uintptr(unsafe.Pointer(face)))
	name := ptr("UniversalDiagnosticWorkstationManager")
	cursor, _, _ := loadCursor.Call(0, 32512)
	inst, _, _ := k32.NewProc("GetModuleHandleW").Call(0)
	wc := WNDCLASSEX{Size: uint32(unsafe.Sizeof(WNDCLASSEX{})), WndProc: syscall.NewCallback(wproc), Instance: inst, Cursor: cursor, Background: backgroundBrush, ClassName: uintptr(unsafe.Pointer(name))}
	registerClass.Call(uintptr(unsafe.Pointer(&wc)))
	windowTitle := ptr("Diagnostic Workstation | Universal Manager")
	hwnd, _, _ = createWindow.Call(0, uintptr(unsafe.Pointer(name)), uintptr(unsafe.Pointer(windowTitle)), WS_OVERLAPPEDWINDOW|WS_VISIBLE, 250, 160, 770, 560, 0, 0, inst, 0)
	if hwnd == 0 {
		panic("Could not create manager window")
	}
	title := create("STATIC", "DIAGNOSTIC WORKSTATION", WS_CHILD|WS_VISIBLE, 34, 25, 650, 38, hwnd, 10)
	sendMessage.Call(title, WM_SETFONT, fontHeadline, 1)
	create("STATIC", "One installer  •  Nine manufacturers  •  One shared update system", WS_CHILD|WS_VISIBLE, 36, 69, 670, 26, hwnd, 11)
	create("STATIC", "CHOOSE YOUR MANUFACTURER", WS_CHILD|WS_VISIBLE, 36, 125, 610, 22, hwnd, 12)
	combo = create("COMBOBOX", "", WS_CHILD|WS_VISIBLE|WS_TABSTOP|CBS_DROPDOWNLIST|WS_VSCROLL, 36, 151, 660, 250, hwnd, 100)
	for _, b := range brands {
		p := ptr(b.DisplayName)
		sendMessage.Call(combo, CB_ADDSTRING, 0, uintptr(unsafe.Pointer(p)))
		runtime.KeepAlive(p)
	}
	sendMessage.Call(combo, CB_SETCURSEL, 0, 0)
	brandLabel = create("STATIC", "", WS_CHILD|WS_VISIBLE, 36, 192, 675, 49, hwnd, 13)
	updateSelected()
	startCheck = create("BUTTON", "Start automatically when I sign in", WS_CHILD|WS_VISIBLE|WS_TABSTOP|BS_AUTOCHECKBOX, 36, 258, 600, 30, hwnd, 150)
	sendMessage.Call(startCheck, BM_SETCHECK, BST_CHECKED, 0)
	installBtn = create("BUTTON", "INSTALL SELECTED BRAND", WS_CHILD|WS_VISIBLE|WS_TABSTOP, 36, 316, 235, 44, hwnd, 200)
	uninstallBtn = create("BUTTON", "UNINSTALL WORKSTATION", WS_CHILD|WS_VISIBLE|WS_TABSTOP, 284, 316, 230, 44, hwnd, 201)
	legacyBtn = create("BUTTON", "REMOVE OLD MERCEDES", WS_CHILD|WS_VISIBLE|WS_TABSTOP, 528, 316, 208, 44, hwnd, 202)
	progress = create("msctls_progress32", "", WS_CHILD|WS_VISIBLE, 36, 380, 700, 17, hwnd, 300)
	statusBox = create("EDIT", "Ready. Select a brand to install. All installation settings are per Windows user.", WS_CHILD|WS_VISIBLE|ES_READONLY|ES_MULTILINE|ES_AUTOVSCROLL|WS_VSCROLL|WS_BORDER, 36, 410, 700, 67, hwnd, 301)
	create("STATIC", "Installed apps include an Uninstall entry in Windows Settings > Apps. Explorer remains the shell during first-run testing.", WS_CHILD|WS_VISIBLE, 36, 492, 700, 29, hwnd, 15)
	showWindow.Call(hwnd, SW_SHOW)
	updateWindow.Call(hwnd)
	var m MSG
	for {
		r, _, _ := getMessage.Call(uintptr(unsafe.Pointer(&m)), 0, 0, 0)
		if int32(r) <= 0 {
			break
		}
		translateMessage.Call(uintptr(unsafe.Pointer(&m)))
		dispatchMessage.Call(uintptr(unsafe.Pointer(&m)))
	}
}
func selectedBrand() brand {
	if len(brands) == 0 {
		return brand{}
	}
	i, _, _ := sendMessage.Call(combo, CB_GETCURSEL, 0, 0)
	if int(i) < 0 || int(i) >= len(brands) {
		return brands[0]
	}
	return brands[i]
}

func brandsMatching(all []brand, embedded string) []brand {
	if embedded == "" {
		return all
	}
	ids := make([]string, len(all))
	for i, b := range all {
		ids[i] = b.ID
	}
	allowed := make(map[string]struct{}, 1)
	for _, id := range keepBrandIDs(ids, embedded) {
		allowed[id] = struct{}{}
	}
	next := make([]brand, 0, len(allowed))
	for _, b := range all {
		if _, ok := allowed[b.ID]; ok {
			next = append(next, b)
		}
	}
	return next
}
func selectInstall() {
	b := selectedBrand()
	title, err := installPromptTitle(b.DisplayName)
	if err != nil || strings.TrimSpace(b.ID) == "" {
		notify(unresolvedBrandTitle, unresolvedBrandMessage, MB_ICONERROR)
		return
	}
	root := installationRoot()
	if _, e := os.Stat(filepath.Join(root, "profile.json")); e == nil {
		p, err := readProfile(root)
		if err == nil && p.ID != b.ID {
			notify("Another brand is installed", "This Windows account already has "+p.DisplayName+" installed. Uninstall it first, then select "+b.DisplayName+".", MB_ICONERROR)
			return
		}
	}
	if notify(title, "Install the "+b.DisplayName+" Diagnostic Workstation for the current Windows user?\n\nIncludes Home, glass dock, ADMIN, SYSTEM, startup option, and the shared universal updater.\n\nWindows Explorer stays available as a recovery desktop.\n\nNo OEM programs, keys, or licenses are included.", MB_YESNO|MB_ICONQUESTION) != IDYES {
		return
	}
	startTask("install")
}
func startTask(which string) {
	setBusy(true)
	sendMessage.Call(progress, PBM_SETPOS, 0, 0)
	var b brand
	var startup bool
	if which == "install" {
		b = selectedBrand()
		v, _, _ := sendMessage.Call(startCheck, BM_GETCHECK, 0, 0)
		startup = v == BST_CHECKED
	}
	go func() {
		var err error
		switch which {
		case "install":
			err = install(b, startup)
		case "legacy":
			err = removeLegacy()
		case "uninstall":
			err = uninstallUniversal()
		}
		if err != nil {
			post("ERROR: "+err.Error(), 0)
		} else {
			post("Completed. "+map[string]string{"install": "The selected workstation is installed. If the Home window does not appear, use its desktop shortcut and check the logs.", "legacy": "Old Mercedes program files and startup entry removed; preserved backup under LocalAppData.", "uninstall": "Workstation uninstalled; settings backed up."}[which], 100)
		}
		postMessage.Call(hwnd, WM_APP_STATUS, 0, 1)
	}()
}

func installationRoot() string {
	return filepath.Join(os.Getenv("LOCALAPPDATA"), "DiagnosticWorkstation")
}
func logLine(root, msg string) {
	_ = os.MkdirAll(filepath.Join(root, "logs"), 0700)
	f, e := os.OpenFile(filepath.Join(root, "logs", "Manager.log"), os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0600)
	if e == nil {
		fmt.Fprintln(f, time.Now().Format(time.RFC3339), msg)
		f.Close()
	}
}
func readProfile(root string) (profile, error) {
	var p profile
	b, e := os.ReadFile(filepath.Join(root, "profile.json"))
	if e != nil {
		return p, e
	}
	e = json.Unmarshal(b, &p)
	return p, e
}
func shell(command string, args ...string) error {
	c := exec.Command(command, args...)
	c.SysProcAttr = &syscall.SysProcAttr{CreationFlags: createNoWindow}
	out, e := c.CombinedOutput()
	if e != nil {
		return fmt.Errorf("%s: %v - %s", command, e, strings.TrimSpace(string(out)))
	}
	return nil
}
func regAdd(path, key, value string) error {
	return shell("reg.exe", "add", path, "/v", key, "/t", "REG_SZ", "/d", value, "/f")
}
func regDel(path, key string) { _ = shell("reg.exe", "delete", path, "/v", key, "/f") }
func regDelKey(path string)   { _ = shell("reg.exe", "delete", path, "/f") }
func runPS(path string, args ...string) error {
	ps := filepath.Join(os.Getenv("WINDIR"), "System32", "WindowsPowerShell", "v1.0", "powershell.exe")
	all := []string{"-NoProfile", "-STA", "-ExecutionPolicy", "Bypass", "-File", path}
	all = append(all, args...)
	return shell(ps, all...)
}
func backupFile(src, backup string) {
	if _, e := os.Stat(src); e == nil {
		b, e := os.ReadFile(src)
		if e == nil {
			_ = os.MkdirAll(filepath.Dir(backup), 0700)
			_ = os.WriteFile(backup, b, 0600)
		}
	}
}
func installEmbeddedLogos(root string, selected brand) error {
	if err := brandInstallError(embeddedBrand, selected.ID); err != nil {
		return err
	}
	entries, err := assets.ReadDir("assets/branding")
	if err != nil {
		return fmt.Errorf("missing branding for %s: %w", selected.DisplayName, err)
	}
	foundSelected := false
	wrote := 0
	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		name := entry.Name()
		if !strings.HasSuffix(strings.ToLower(name), ".png") {
			continue
		}
		if name != embeddedBrand+".png" {
			return fmt.Errorf("this WorkstationManager build includes only the %s logo", embeddedBrand)
		}
		raw, err := assets.ReadFile("assets/branding/" + name)
		if err != nil {
			return err
		}
		if name == selected.ID+".png" {
			foundSelected = true
		}
		target := filepath.Join(root, "branding", name)
		if err = os.MkdirAll(filepath.Dir(target), 0700); err != nil {
			return err
		}
		if err = os.WriteFile(target, raw, 0600); err != nil {
			return err
		}
		wrote++
	}
	if !foundSelected || wrote == 0 {
		return fmt.Errorf("missing branding for %s", selected.DisplayName)
	}
	return nil
}

func install(b brand, startup bool) error {
	if err := brandInstallError(embeddedBrand, b.ID); err != nil {
		return err
	}
	if os.Getenv("LOCALAPPDATA") == "" {
		return errors.New("LOCALAPPDATA unavailable; sign in as a normal Windows user")
	}
	root := installationRoot()
	post("Preparing a clean installation for "+b.DisplayName, 8)
	if p, e := readProfile(root); e == nil && p.ID != b.ID {
		return fmt.Errorf("%s is already installed in this Windows account", p.DisplayName)
	}
	// Never overwrite a legacy BMW custom shell or another manufacturer's per-partition setup.
	oldBMW := filepath.Join(os.Getenv("LOCALAPPDATA"), "BMW-Stealth-Launcher")
	if _, e := os.Stat(filepath.Join(oldBMW, "Launcher.ps1")); e == nil {
		return errors.New("An older BMW workstation was detected in this Windows account. Do not overwrite it; use the separate Windows installation")
	}
	if e := os.MkdirAll(root, 0700); e != nil {
		return e
	}
	backup := filepath.Join(os.Getenv("LOCALAPPDATA"), "DiagnosticWorkstation-Backups", time.Now().Format("20060102-150405"))
	if _, e := os.Stat(filepath.Join(root, "Launcher.ps1")); e == nil {
		for _, n := range []string{"Launcher.ps1", "Dock.ps1", "SystemPanel.ps1", "profile.json", "apps.json", "version.json", "UpdateAgent.ps1"} {
			backupFile(filepath.Join(root, n), filepath.Join(backup, n))
		}
	}
	post("Installing universal runtime and manufacturer profile...", 30)
	items := []string{"Launcher.ps1", "Dock.ps1", "SystemPanel.ps1", "Watchdog.ps1", "UpdateAgent.ps1", "UpdateRunner.ps1", "ApplyUpdate.ps1", "Uninstall.ps1", "Remove-Legacy-Mercedes.ps1"}
	for _, n := range items {
		data, e := assets.ReadFile("assets/" + n)
		if e != nil {
			return e
		}
		if e = os.WriteFile(filepath.Join(root, n), data, 0600); e != nil {
			return e
		}
	}
	// Brand assets are installed alongside the shared core and validated before startup.
	// Only logos staged into this build are written. A brand build stages its own mark.
	if err := installEmbeddedLogos(root, b); err != nil {
		return err
	}
	// A single per-user manager binary provides installation and supervision for every brand.
	exe, e := os.Executable()
	if e != nil {
		return e
	}
	dest := filepath.Join(root, "WorkstationManager.exe")
	if !strings.EqualFold(exe, dest) {
		input, e := os.Open(exe)
		if e != nil {
			return e
		}
		defer input.Close()
		tmp := dest + ".new"
		output, e := os.Create(tmp)
		if e != nil {
			return e
		}
		_, e = io.Copy(output, input)
		output.Close()
		if e != nil {
			return e
		}
		_ = os.Remove(dest)
		if e = os.Rename(tmp, dest); e != nil {
			return fmt.Errorf("could not update installed manager binary; close it first: %w", e)
		}
	}
	p := profile{ID: b.ID, DisplayName: b.DisplayName, Short: b.Short, UpdateFamily: "universal", Accent: b.Accent, AccentSoft: b.AccentSoft, Logo: b.Logo}
	pb, _ := json.MarshalIndent(p, "", "  ")
	if e = os.WriteFile(filepath.Join(root, "profile.json"), pb, 0600); e != nil {
		return e
	}
	if _, e := os.Stat(filepath.Join(root, "apps.json")); os.IsNotExist(e) {
		bb, _ := json.MarshalIndent(map[string]any{"apps": b.Apps}, "", "  ")
		if e = os.WriteFile(filepath.Join(root, "apps.json"), bb, 0600); e != nil {
			return e
		}
	}
	for _, n := range []string{"version.json", "update-settings.json", "update-status.json"} {
		dst := filepath.Join(root, n)
		if _, e := os.Stat(dst); os.IsNotExist(e) || n == "update-settings.json" {
			bb, e := assets.ReadFile("assets/" + n)
			if e != nil {
				return e
			}
			if e = os.WriteFile(dst, bb, 0600); e != nil {
				return e
			}
		}
	}
	// Validate installed PowerShell source before registering anything to launch at sign-in.
	validate, err := assets.ReadFile("assets/Validate.ps1")
	if err != nil {
		return err
	}
	validationScript := filepath.Join(root, "Validate.ps1")
	if err = os.WriteFile(validationScript, validate, 0600); err != nil {
		return err
	}
	post("Checking PowerShell syntax before enabling startup...", 49)
	if err = runPS(validationScript, "-Root", root); err != nil {
		return fmt.Errorf("validation failed; startup not registered, files kept for diagnosis: %w", err)
	}
	post("Registering Windows uninstall and startup...", 60)
	runKey := `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`
	if startup {
		if e = regAdd(runKey, "UniversalDiagnosticWorkstation", `"`+dest+`" /supervise`); e != nil {
			return e
		}
	} else {
		regDel(runKey, "UniversalDiagnosticWorkstation")
	}
	uninstallKey := `HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\UniversalDiagnosticWorkstation`
	entries := map[string]string{"DisplayName": "Diagnostic Workstation — " + b.DisplayName, "DisplayVersion": "0.1.2-beta.1", "Publisher": "Diagnostic Workstation", "InstallLocation": root, "UninstallString": `"` + filepath.Join(os.Getenv("WINDIR"), "System32", "WindowsPowerShell", "v1.0", "powershell.exe") + `" -NoProfile -STA -ExecutionPolicy Bypass -File "` + filepath.Join(root, "Uninstall.ps1") + `"`, "DisplayIcon": dest, "NoModify": "1"}
	for k, v := range entries {
		if e = regAdd(uninstallKey, k, v); e != nil {
			return e
		}
	}
	post("Creating shortcuts...", 77)
	shortcutPath := filepath.Join(root, "Create-Shortcuts.ps1")
	content := `param([string]$Root)
$ws=New-Object -ComObject WScript.Shell
$paths=@((Join-Path ([Environment]::GetFolderPath('Desktop')) 'Diagnostic Workstation.lnk'),(Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Diagnostic Workstation\Diagnostic Workstation.lnk'))
foreach($p in $paths){New-Item -ItemType Directory -Force -Path (Split-Path $p)|Out-Null;$s=$ws.CreateShortcut($p);$s.TargetPath=Join-Path $Root 'WorkstationManager.exe';$s.Arguments='/supervise';$s.WorkingDirectory=$Root;$s.Description='Launch Diagnostic Workstation';$s.Save()}
`
	_ = os.WriteFile(shortcutPath, []byte(content), 0600)
	if e = runPS(shortcutPath, "-Root", root); e != nil {
		logLine(root, "Shortcut creation warning: "+e.Error())
	}
	post("Starting the workstation supervisor...", 89)
	cmd := exec.Command(dest, "/supervise")
	cmd.Dir = root
	if e = cmd.Start(); e != nil {
		return fmt.Errorf("installed files, but could not launch workstation supervisor: %w", e)
	}
	_ = cmd.Process.Release()
	logLine(root, "Installed universal runtime for "+b.DisplayName+"; startup="+fmt.Sprint(startup)+"; shell=Explorer")
	post("Finished installing. Mercedes legacy and BMW installation are untouched.", 97)
	return nil
}
func runUninstaller(script string) error { e := runPS(script, "-Quiet"); return e }
func uninstallUniversal() error {
	root := installationRoot()
	_, e := os.Stat(filepath.Join(root, "Uninstall.ps1"))
	if e != nil {
		return errors.New("No universal workstation is installed")
	}
	if notify("Uninstall Diagnostic Workstation", "Uninstall the universal workstation for this Windows account?\n\nSettings will be backed up. OEM diagnostic software is never removed.", MB_YESNO|MB_ICONQUESTION) != IDYES {
		return nil
	}
	post("Removing the universal workstation...", 30)
	return runUninstaller(filepath.Join(root, "Uninstall.ps1"))
}
func removeLegacy() error {
	p := filepath.Join(os.Getenv("LOCALAPPDATA"), "Mercedes-Diagnostic-Workstation")
	if _, e := os.Stat(p); os.IsNotExist(e) {
		post("Old Mercedes directory is already absent. Removing its startup setting if present...", 30)
	}
	if notify("Remove old Mercedes", "Clean up the PREVIOUS Mercedes V2/V3 installation in this Windows account?\n\nBackups/logs are saved separately. This will not remove Mercedes diagnostic software or BMW.", MB_YESNO|MB_ICONQUESTION) != IDYES {
		return nil
	}
	post("Removing old Mercedes workstation...", 50)
	temp, e := os.MkdirTemp("", "legacy-mercedes-cleanup-")
	if e != nil {
		return e
	}
	defer os.RemoveAll(temp)
	data, e := assets.ReadFile("assets/Remove-Legacy-Mercedes.ps1")
	if e != nil {
		return e
	}
	script := filepath.Join(temp, "Remove-Legacy-Mercedes.ps1")
	if e = os.WriteFile(script, data, 0600); e != nil {
		return e
	}
	return runUninstaller(script)
}
func supervise() {
	runtime.LockOSThread()
	root := installationRoot()
	mut := k32.NewProc("CreateMutexW")
	name := ptr("Local\\UniversalDiagnosticWorkstationSupervisorV1")
	h, _, last := mut.Call(0, 1, uintptr(unsafe.Pointer(name)))
	runtime.KeepAlive(name)
	if h == 0 {
		return
	}
	if eno, ok := last.(syscall.Errno); ok && eno == 183 {
		return
	}
	defer k32.NewProc("CloseHandle").Call(h)
	logLine(root, "Supervisor started")
	var wg sync.WaitGroup
	for _, n := range []string{"Launcher.ps1", "Dock.ps1", "UpdateAgent.ps1"} {
		wg.Add(1)
		go func(file string) { defer wg.Done(); superviseFile(root, file) }(n)
	}
	wg.Wait()
}
func superviseFile(root, n string) {
	ps := filepath.Join(os.Getenv("WINDIR"), "System32", "WindowsPowerShell", "v1.0", "powershell.exe")
	outFile := filepath.Join(root, "logs", strings.TrimSuffix(n, ".ps1")+".log")
	for {
		if _, e := os.Stat(filepath.Join(root, n)); e != nil {
			return
		}
		// A shared update worker replaces the core transactionally. Do not
		// restart Home or Dock halfway through file replacement.
		if n != "UpdateAgent.ps1" {
			if _, err := os.Stat(filepath.Join(root, "install-in-progress.lock")); err == nil {
				time.Sleep(2 * time.Second)
				continue
			}
		}
		_ = os.MkdirAll(filepath.Dir(outFile), 0700)
		out, _ := os.OpenFile(outFile, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0600)
		cmd := exec.Command(ps, "-NoProfile", "-STA", "-ExecutionPolicy", "Bypass", "-File", filepath.Join(root, n))
		cmd.Dir = root
		cmd.SysProcAttr = &syscall.SysProcAttr{CreationFlags: createNoWindow}
		cmd.Stdout = out
		cmd.Stderr = out
		start := time.Now()
		e := cmd.Start()
		if e == nil {
			logLine(root, fmt.Sprintf("Starting %s PID=%d", n, cmd.Process.Pid))
			e = cmd.Wait()
		}
		if out != nil {
			out.Close()
		}
		logLine(root, fmt.Sprintf("Stopped %s after %s: %v", n, time.Since(start).Round(time.Second), e))
		if _, e := os.Stat(filepath.Join(root, n)); e != nil {
			return
		}
		time.Sleep(8 * time.Second)
	}
}
func main() {
	if len(os.Args) >= 2 && strings.EqualFold(os.Args[1], "/report-brand") {
		if len(os.Args) != 3 || writeBrandReport(os.Args[2]) != nil {
			os.Exit(2)
		}
		return
	}
	args := strings.ToLower(strings.Join(os.Args[1:], " "))
	switch args {
	case "/supervise", "--supervise":
		supervise()
		return
	case "/uninstall", "--uninstall":
		root := installationRoot()
		script := filepath.Join(root, "Uninstall.ps1")
		_ = runPS(script)
		return
	case "/remove-legacy-mercedes":
		_ = removeLegacy()
		return
	}
	mainUI()
}
