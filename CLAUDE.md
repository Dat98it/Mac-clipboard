# Mac ClipBoard

App thanh menu cho macOS: ghi lại clipboard từ lúc bắt đầu theo dõi, bấm một mục để khôi phục và gửi Cmd+V tới ô nhập của app trước đó. File này chỉ ghi những điều **không thấy được từ code** nhưng dễ làm sai. Tài liệu cho người dùng nằm trong `README.md` (duy nhất, ở thư mục gốc).

**Nguyên tắc số một: không làm mất hay làm lộ nội dung clipboard của người dùng.** Không đọc clipboard sẵn có lúc khởi động, không bao giờ báo "đã xóa" khi dữ liệu trên đĩa còn, không dán khi không chắc đúng ô nhập. Mọi thay đổi chạm tới lưu trữ, Clear All, dán hay gỡ cài đặt phải kèm test.

## Cấu trúc

| Target | Vai trò |
|---|---|
| `MacClipBoardCore` | Payload, giới hạn (`HistoryLimits`), `ClipboardSession` (dedup, revision chống ghi đè muộn, hủy dán), `SelfUninstallRules`. Chỉ Foundation; hiệu ứng qua protocol `ClipboardAccess`, `HistoryPersisting`, `PasteDelivering`. |
| `MacClipBoardSystem` | `MacPasteboard` + `ClipboardMonitor` (timer 0,5 s), `FileHistoryStore` (actor, plist nhị phân), `PasteRouter` (Accessibility + CGEvent), `SelfUninstaller`. |
| `MacClipBoard` | App: status item, `HistoryPanel` (nonactivating), `AppModel`, `HistoryView`. Lớp mỏng. |
| `clipboard-fixture` | Editor tổng hợp để thử tay end-to-end. **Không đóng vào app/DMG.** |

## Lệnh thường dùng

```bash
swift build
Scripts/test.sh                                    # swift test, tự chạy lại khi gặp lỗi TestingMacros của CLT
Scripts/mutate.py [tên ...]                         # phá từng chốt an toàn, mọi đột biến phải bị test bắt (--check: chỉ kiểm mẫu còn khớp mã)
Scripts/build_app.sh [release|debug] [universal]   # ghép "build/Mac ClipBoard.app", ký ad-hoc
Scripts/make_dmg.sh                                # build universal, tạo build/MacClipBoard-<version>.dmg và .sha256
bash Scripts/build_fixture.sh                      # in đường dẫn Clipboard Fixture.app
swift Scripts/make_icon.swift                      # Resources/AppIcon.icns từ Resources/AppIcon-source.png
open -n "build/Mac ClipBoard.app" --args --sandbox /private/tmp/macclipboard-sandbox
```

`--sandbox <thư mục>`: pasteboard có tên riêng + lịch sử trong thư mục đó, **chặn Cmd+V tự động**, không đụng `NSPasteboard.general`. `--test-system-clipboard <thư mục dưới /tmp>`: dùng clipboard hệ thống thật nhưng **ghi đè** bằng baseline tổng hợp (không đọc/khôi phục clipboard cũ). Hai cờ này loại trừ nhau. Mặc định các thử nghiệm dùng `--sandbox`.

## Môi trường: chỉ có Command Line Tools

- Test dùng **Swift Testing**; `swift test` hay báo `plugin for module 'TestingMacros' not found`, `Scripts/test.sh` tự chạy lại.
- **Không dùng `@State`** (macro thiếu plugin). Trạng thái view nằm trong `AppModel` (ObservableObject), binding viết tay bằng `Binding(get:set:)`.
- Trong `#expect`, đừng truyền key path như hàm; viết closure.
- Chuỗi giao diện: key là câu tiếng Anh, dịch trong `Resources/vi.lproj/Localizable.strings`. Thêm chuỗi mới thì thêm bản dịch (lệnh trích key: `grep -rhoE 'L\("[^"]+"\)' Sources | sort -u`).

## Viết test

- Core test trên pasteboard và store giả trong bộ nhớ. Không test nào đọc clipboard thật, `UserDefaults` thật, `~/Library` thật hay gỡ app thật. Pasteboard thật chỉ dùng `NSPasteboard.withUniqueName()`.
- Hiệu ứng gỡ cài đặt test bằng `SelfUninstaller.Checks` và closure `trash` giả.

## Kiểm tra đột biến (`Scripts/mutate.py`)

- Mỗi dòng trong `MUTATIONS` gỡ hoặc đảo **một** chốt an toàn bằng thay chuỗi nguyên văn, chạy `Scripts/test.sh` và mong test **fail**. Kết quả: `KILLED` (tốt), `SURVIVED` (lỗ hổng test: viết test, đừng sửa danh sách), `BUILD-FAILED` (đột biến làm hỏng build, sửa mẫu), `EQUIVALENT` (nằm trong `EQUIVALENT` kèm lý do).
- Script từ chối chạy khi `Sources/` còn thay đổi chưa commit và luôn khôi phục file (kể cả khi Ctrl-C/SIGTERM). Chạy cả bộ mất khoảng 40 phút (82 đột biến, mỗi lần build + test); chạy nền, hoặc lọc theo tên: `Scripts/mutate.py session- store-`.
- **Thêm chốt an toàn mới thì thêm một dòng đột biến**, và chạy `Scripts/mutate.py --check` sau khi đổi mã để mẫu không bị lệch. Đừng đưa vào `EQUIVALENT` chỉ vì khó test: phải đo hoặc chứng minh được là không quan sát được từ ngoài.
- Lần chạy đầu: 52/82 bị bắt. 25 đột biến sống sót là lỗ hổng thật (ví dụ nhận bản sao khi đang nạp lịch sử có thể làm mất lịch sử đã lưu; revision cũ ghi đè; quyền thư mục) và đã có test trong `SafetyGateTests.swift`. 5 đột biến còn lại là tương đương (4 do suy luận, 1 do đo thực tế), lý do ghi ngay trong script.

## Những cái bẫy đã gặp

- **File là tham chiếu, đọc bằng `NSURL`**, không phải chuỗi. Finder đưa URL kiểu `file:///.file/id=…`; chuẩn hóa bằng `(url as NSURL).filePathURL`. Khôi phục bằng `writeObjects([NSURL])`, **không bao giờ** ghi tên/đường dẫn file dưới dạng text thay thế, và nếu một file trong nhóm mất thì từ chối cả nhóm.
- Tên file ở dạng text trên pasteboard (`public.utf8-plain-text` đi kèm file URL) là fallback hiển thị của Finder, không phải item thứ hai: bỏ đi khi lưu.
- **Mọi ghi đĩa đều mang `revision`.** Yêu cầu cũ hoặc cùng revision với lần Clear All không được tạo lại file. Đừng thêm đường ghi nào không qua `HistoryPersisting.save(_:revision:)`.
- Gỡ cài đặt: sau `store.freezeWrites()` không được flush nữa, nếu không sẽ tạo lại thư mục lịch sử vừa chuyển vào Thùng rác (xem `terminating` trong `AppDelegate`).
- **Chrome/Electron không lộ ô nhập đang focus** (`kAXFocusedUIElement` trả `noValue` cho tới khi có công cụ trợ năng bật `AXManualAccessibility`; app không tự bật vì làm trình duyệt chậm hơn). Trước đây app từ chối dán ở đó ("Không xác nhận được focus ô nhập"). Giờ `PasteFocusRules` (Core) chọn mức kiểm tra: ô nhập nếu có, nếu không thì cửa sổ đang focus, nếu không có gì thì không gửi. Mọi quyết định gửi Cmd+V đi qua `PasteFocusRules.mayPaste` (có test và đột biến); phần Accessibility trong `PasteRouter` thì không unit test được. Đã đo bằng AX trên Chrome thật, chưa thử đầu-cuối sau thay đổi này.
- Dán: `NSApp.yieldActivation` + `activate(from:)` bất đồng bộ trên macOS 14; chỉ gửi Cmd+V khi focus Accessibility đúng đối tượng đã nhớ và không còn phím modifier nào đang giữ. Sự kiện gửi bằng `postToPid`. macOS không báo editor có nhận lệnh hay không, nên thông báo chỉ được nói "đã gửi Cmd+V".
- **Tiến trình dùng chung quyền của thứ đã mở nó.** App mở từ shell của Claude (kể cả `open -n`) dùng ké Accessibility của Claude/Claude Code. Phép thử quyền Accessibility phải để người dùng mở app từ Finder. Bản ký ad-hoc mới (CDHash khác) có thể cần cấp quyền lại.
- **Mục đã ghim (`ClipboardEntry.isPinned`) phụ thuộc vào `HistoryLimits.bounded`**: ghim được giữ trước, trong trần `maxPinnedEntries` (20) và `maxPinnedBytes` (một nửa ngân sách) để một lần copy tối đa 8 MiB luôn còn chỗ. Mọi đường nạp/ghi đều đi qua `bounded`, đừng cắt danh sách bằng cách khác. `isPinned` giải mã bằng `decodeIfPresent`: lịch sử 0.1.0 không có khóa này và phải vẫn mở được, không được nâng `version` của archive. Clear All xóa cả mục ghim, và xóa/ghim cũng đi qua `revision` + `scheduleSave` như mọi thay đổi khác.
- **Phím ↑ ↓ Enter xử lý ở `HistoryPanel.sendEvent`**, không dùng `onKeyPress` (ô tìm kiếm sẽ nuốt phím). Phải bỏ qua khi `NSTextView.hasMarkedText()` (bộ gõ Telex/VNI đang soạn), và chỉ nhận khi không có modifier. Enter chỉ dán khi người dùng đã chọn rõ một mục; `prepareToShow` xóa lựa chọn. Logic chọn nằm ở `ListSelection` (Core) để test được.
- Thumbnail (`Thumbnailer`, ImageIO) chỉ trong bộ nhớ, dựng ở luồng nền, và `AppModel.refresh()` tỉa cache theo danh sách mục. Đừng ghi thumbnail ra đĩa. Có trần 100 megapixel vì file nhỏ vẫn có thể khai báo kích thước khổng lồ.
- **Thử UI tự động:** tắt app bằng PID, không bằng `pkill -f MacClipBoard.app` (đường dẫn thật là `Mac ClipBoard.app`, có dấu cách nên mẫu đó không khớp gì). Trước mỗi lần chụp, kiểm tra `pgrep -fl "Mac ClipBoard.app" | wc -l` bằng 1: nhiều bản cùng chạy sẽ dùng chung thư mục sandbox và cho kết quả sai. Chụp bằng `screencapture -l <windowID>` (lấy ID qua `CGWindowListCopyWindowInfo`), không bao giờ chụp cả màn hình. Gửi phím bằng `CGEvent.postToPid` để phím không lọt vào ứng dụng đang dùng. Cửa sổ chưa hiện thì SwiftUI chưa vẽ danh sách; mở lại bằng `open "build/Mac ClipBoard.app"` (không `-n`) rồi mới chụp.
- **Cài đặt nằm trong `settings.plist` cạnh `history.plist`, không dùng UserDefaults**, để `--sandbox` cô lập và gỡ cài đặt dọn luôn. `Preferences` chỉ nhận các lựa chọn cố định (không tin giá trị trong file). `FileHistoryStore` luôn dùng `HistoryLimits.ceiling` (lựa chọn lớn nhất) chứ không dùng giới hạn đang chọn, nếu không file sẽ bị cắt trước khi người dùng nâng giới hạn; chỉ `ClipboardSession.limits` áp giới hạn thật. Mọi lựa chọn phải thỏa `maxPinnedBytes + maxEntryBytes <= maxTotalBytes` (có test).
- **Launch at Login chỉ do người dùng bật, và không bao giờ đụng tới login item thật khi test.** `SystemLoginItemService` chỉ được tạo ở lần chạy thường (xem `main.swift`); `--sandbox`/`--test-system-clipboard` truyền `nil`. Test dùng `FakeLoginItem`. Gỡ cài đặt phải tắt login item **trước** khi chuyển app vào Thùng rác và đăng ký lại nếu việc chuyển thất bại. Khi gỡ xong app thoát ngay nên cảnh báo phải dùng `runModal`, không dùng sheet. **`SMAppService.mainApp.status` trả `.notFound` cho app chưa từng đăng ký** (đã gặp thật trên bản trong /Applications): phải coi là "tắt" và vẫn cho thử `register()`, như MacClean/ShelfDrop. Từng chặn trường hợp này và công tắc bị khóa vĩnh viễn; `State.unavailable` chỉ dành cho môi trường test (không có service). Việc nhận biết "mở lúc đăng nhập" (`AppDelegate.launchedAsLoginItem`, sự kiện `lgit`) chưa được thử trên đăng nhập thật.
- **Thử UI: không click theo tọa độ màn hình khi người dùng đang dùng máy.** Cửa sổ khác thường nằm đè lên panel (không kích hoạt app) và cú click rơi vào đó. Dùng `--open-settings` (sandbox) và phím qua `postToPid`; chuột qua `postToPid` không trúng cửa sổ bị che. Nếu bắt buộc phải click, kiểm tra cửa sổ trên cùng tại điểm đó là panel ngay trước khi click.
- **Phím tắt toàn cục dùng Carbon `RegisterEventHotKey`** (`GlobalHotKey`, qua protocol `HotkeyRegistering` để test bằng giả): không cần quyền nào, và đừng đổi sang event tap (cần Input Monitoring và thấy mọi phím). Mặc định ⇧⌘V (người dùng yêu cầu) dù nó là "dán không định dạng" ở nhiều app và phím tắt toàn cục sẽ che nó; ⌃⌥V/⌃⌥⌘V là lựa chọn không va chạm. Chỉ đăng ký ở lần chạy thường; `--sandbox`/`--test-system-clipboard` không đăng ký trừ khi thêm `--enable-hotkey` cùng `--sandbox`, để lần thử không giành phím của bản đang dùng. `toggleFromHotkey` chỉ ẩn khi panel đang là cửa sổ key, còn lại thì đưa lên (panel không kích hoạt app nên thường không phải key khi bạn đang ở app khác).
- **Panel phải đi theo Space (desktop) hiện tại**: `collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]` và `showWindow` gọi `orderOut` trước khi đưa lên nếu panel còn nằm ở Space khác. Panel mở ở Space khác vẫn có `isVisible == true`, nên trước đây ⇧⌘V (và bấm icon) coi như "đang hiện" và ẩn một cửa sổ người dùng không thấy, hoặc không kéo nó về. Quyết định ẩn/hiện nằm ở `PanelToggleRules` (Core, có test và đột biến). Đo trên máy thật bằng `CGSGetActiveSpace` + `CGSCopySpacesForWindows` (API riêng, chỉ dùng khi thử); chuyển Space bằng `osascript … key code 123/124 using control down` (CGEvent ctrl+mũi tên không chuyển được; phím trái không chuyển được khi đã ở Space ngoài cùng).
- **Hover của từng mục nằm trong `AppModel.hoveredID`** (không có `@State`); `.onHover` chạy được cả khi panel không phải cửa sổ active.
- **Cảnh báo "định dạng riêng" chỉ dựa vào `lostContentCount`**, đếm các kiểu bị bỏ thuộc `ClipboardPayload.lostContentTypes` (JPEG, PDF, RTFD...). `omittedTypeCount` đếm mọi kiểu bị bỏ nên chỉ mang tính thông tin: trình duyệt/editor gắn vào mỗi lần copy text (và Finder gắn vào mỗi file) cả loạt kiểu phụ (`org.chromium.*`, `dyn.*`, `NSFilenamesPboardType`...), dùng nó để cảnh báo là báo động giả. Lịch sử cũ không có `lostContentCount` nên không cảnh báo. So sánh `ClipboardPayload` chỉ theo `items`, không theo các số đếm, để copy lại không tạo mục trùng. Mục file luôn `lostContentCount: 0` và UI còn chặn bằng `containsOnlyFileReferences`.
- **Thử UI/phím tắt tự động cần chọn đúng tiến trình**: bản thật của người dùng thường đang chạy cùng lúc. Lấy PID bằng `pgrep -f 'MacClipBoard --sandbox <thư mục>'`, không dùng `pgrep ... | head -1`. Gửi ⌃⌥V toàn hệ thống chỉ sau khi đọc được dòng trạng thái "Đã đăng ký" (AX, `settings.hotkeyStatus`); nếu đăng ký thất bại tổ hợp phím sẽ lọt vào app đang dùng. Chỉ di chuyển con trỏ (không click) sau khi kiểm tra cửa sổ trên cùng tại điểm đó là panel, rồi trả con trỏ về chỗ cũ.
- **Phép thử dán thật (đã chạy một lần, kết quả: dán file `.pptx` vào Chrome bằng click thành công)**: Chrome hồ sơ tạm (`open -na "Google Chrome" --args --user-data-dir=/private/tmp/... --disable-extensions <trang>`), trang cục bộ phục vụ bằng `python3 -I` ghi lại mọi sự kiện `keydown`/`paste` (kèm `clipboardData.files`) vào một file log qua POST, và bản app đã cài chạy với `--test-system-clipboard /private/tmp/...` (cần quyền Trợ năng; không có thẻ xin quyền nghĩa là đã có). Bản `--sandbox` không thử được vì chặn Cmd+V. Pasteboard do `writeObjects([NSURL])` tạo ra có `public.file-url`, `NSFilenamesPboardType`, `CorePasteboardFlavorType 0x6675726C` và vài kiểu `dyn.*`.
- **Phép thử trên phải kiểm tra `NSWorkspace.shared.frontmostApplication` đúng là Chrome tạm ngay trước mỗi cú click.** Nơi dán là app đang ở phía trước **vào lúc click** (app chụp lại ở `leftMouseDown`), nên nếu app khác chen lên (đã gặp: Phản chiếu iPhone) thì Cmd+V đi vào app đó. Cổng "panel đang là cửa sổ trên cùng" chỉ chặn click nhầm cửa sổ, không chặn việc này.
- **Phép thử ghi đè clipboard hệ thống, nên bản app thật đang chạy cũng ghi các mục giả vào lịch sử thật.** Sau khi thử: làm trống clipboard (`NSPasteboard.general.clearContents()`), xóa các mục chứa "synthetic" khỏi bản đang chạy qua AX (`history.delete.<uuid>`), rồi mới xóa file thử.
- **Dán file từ thư mục được bảo vệ: người GHI clipboard phải đọc được file.** Đây là nguyên nhân của "click mục file mà không dán được, không có thông báo gì" (Teams trong Chrome, file ở Desktop). Đã đo: cùng file Desktop, tiến trình ghi có quyền Desktop → Chrome nhận `Files`; Mac ClipBoard (chưa được cấp) ghi → Chrome nhận `types: []`. Tên tiếng Việt không liên quan. Vì vậy `ClipboardAccess.prepareRestore` (async) gọi `FileReadAccess.isDenied` (chỉ `open(O_RDONLY|O_NONBLOCK)`, không đọc) trước `restore`: lần đầu nó làm macOS hiện hộp xin quyền Tệp và thư mục (mô tả nằm ở các khóa `NS*FolderUsageDescription` trong `Info.plist`, dịch ở `vi.lproj/InfoPlist.strings`); bị từ chối (`EPERM`/`EACCES`) thì không ghi clipboard và báo `fileAccessDenied`. `ENOENT` không phải từ chối. `select` đặt `isPasting = true` từ đầu để click thứ hai không xếp hàng sau hộp xin quyền. Chưa kiểm chứng đầu-cuối phần hộp xin quyền vì không bấm được hộp bảo mật của người dùng.
- Panel không kích hoạt app (`nonactivating`, `becomesKeyOnlyIfNeeded`) để không cướp focus của editor; `onBeforeInteraction` chụp lại đích dán trước mỗi lần click.
- **App icon là ảnh người dùng chọn** (`Resources/AppIcon-source.png`, prompt ở `AppIcon-prompt.txt`). Đừng vẽ lại bằng code; muốn đổi thì thay ảnh gốc (nền trong suốt) rồi chạy lại `make_icon.swift`.
- Lịch sử lưu **không mã hóa** ở `~/Library/Application Support/local.macclipboard.app/history.plist`. `history.plist` và `*.log` nằm trong `.gitignore`: đừng bao giờ commit.

## Git và phát hành

- Danh tính commit đặt ở mức repo, giống AppClean/MacClean: `Dat98it <dat98.it@gmail.com>`. Kiểm `git config user.email` trước khi commit.
- **Không thêm trailer `Co-Authored-By`.** Commit message tiếng Anh, theo từng thay đổi lô-gic.
- Chỉ commit, push, release khi được yêu cầu. Release: tag `vX.Y.Z`, đính kèm DMG và SHA-256, ghi chú bằng tiếng Việt. Sửa phiên bản trong `Resources/Info.plist` bằng sửa văn bản (hai dòng `CFBundleShortVersionString`, `CFBundleVersion`), không dùng PlistBuddy.
- App ký ad-hoc, chưa notarize. Hướng dẫn mở app khi Gatekeeper chặn: bấm **Done** (đừng bấm "Move to Trash") rồi **Open Anyway** trong System Settings → Privacy & Security.
