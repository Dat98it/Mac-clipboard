# Mac ClipBoard

Ứng dụng thanh menu cho macOS 14 trở lên, ghi lại clipboard từ khi app bắt đầu theo dõi. Bấm một mục để khôi phục nội dung vào clipboard và gửi Cmd+V tới ô nhập của ứng dụng trước đó. **Clear All** xóa lịch sử trong bộ nhớ, lịch sử trên ổ đĩa và clipboard hệ thống.

## Build và chạy

```bash
git clone https://github.com/Dat98it/Mac-clipboard.git MacClipBoard
cd MacClipBoard
swift build
Scripts/test.sh
Scripts/build_app.sh release
open "build/Mac ClipBoard.app"
```

`Scripts/build_app.sh release universal` tạo bản Intel + Apple Silicon. `Scripts/make_dmg.sh` build bản universal rồi đóng gói `build/MacClipBoard-<phiên bản>.dmg` kèm file `.sha256`. Bản build hiện tại ký ad-hoc, chưa notarize. Có thể chép app sang `/Applications` bằng Finder trước khi cấp quyền để dùng lâu dài. Chạy `swift run MacClipBoard` được nhưng nên dùng bundle `.app` để macOS gắn quyền vào đúng ứng dụng.

Icon riêng được đóng gói trong `Resources/AppIcon.icns`, có đủ kích thước 16–1024 px. Ảnh gốc ở `Resources/AppIcon-source.png`, prompt tạo ảnh ở `Resources/AppIcon-prompt.txt`; chạy `swift Scripts/make_icon.swift` để xuất lại icon và ảnh preview. Script build tự xuất lại khi ảnh gốc hoặc script thay đổi.

App mở lịch sử khi khởi động; dùng `--background` để chỉ hiện biểu tượng thanh menu. Bấm trái biểu tượng để mở/ẩn lịch sử, bấm phải để tạm dừng hoặc thoát. Phím tắt toàn cục (mặc định **⇧⌘V**) cũng mở/ẩn lịch sử từ bất kỳ app nào, xem [Phím tắt](#phím-tắt). Đóng cửa sổ vẫn tiếp tục theo dõi; thoát app sẽ dừng theo dõi. Mặc định app **không** tự chạy khi đăng nhập; chỉ khi bạn bật **Mở cùng lúc đăng nhập** (trong Cài đặt hoặc menu chuột phải) thì app mới được đăng ký làm login item, không có launch agent nào khác.

## Gỡ cài đặt

Nút **Gỡ cài đặt… / Uninstall…** nằm trên thanh công cụ phía trên, bên cạnh Clear All; cũng có trong menu chuột phải của biểu tượng thanh menu. App hiện hộp thoại xác nhận với **Hủy** là lựa chọn mặc định.

Khi xác nhận, app dừng timer, hủy dán đang chờ, flush lịch sử, khóa các lần ghi còn lại, rồi chuyển **đúng bundle đang chạy** và thư mục lịch sử riêng của Mac ClipBoard vào Thùng rác, sau đó thoát. Clipboard hệ thống hiện tại được giữ nguyên. Nếu **Mở cùng lúc đăng nhập** đang bật, app tắt nó trước khi chuyển (và bật lại nếu việc chuyển app thất bại); nếu không tắt được, app báo để bạn gỡ trong Cài đặt hệ thống → Cài đặt chung → Mục đăng nhập. Nếu không chuyển được app, lịch sử vẫn ở chỗ cũ và app tiếp tục hoạt động; nếu chỉ chuyển lịch sử thất bại, app thông báo riêng. Đây là thao tác chuyển vào Thùng rác, không xóa vĩnh viễn.

Chức năng bị chặn khi chạy từ mã nguồn (`swift run`), sai bundle ID, ổ chỉ đọc, không có quyền gỡ hoặc đang ở chế độ kiểm thử. Mọi hiệu ứng gỡ đều có test bằng đối tượng giả; không test nào gỡ app thật. Chốt khóa actor bảo đảm tác vụ ghi đến muộn không tạo lại thư mục lịch sử sau khi gỡ.

## Dán vào ứng dụng trước đó

1. Đặt con trỏ vào ô nhập của ứng dụng đích.
2. Bấm biểu tượng Mac ClipBoard trên thanh menu.
3. Bấm một mục lịch sử.

Lần đầu, vào **Cài đặt hệ thống → Quyền riêng tư & Bảo mật → Trợ năng (Accessibility) → +**, chọn **Mac ClipBoard.app** và bật quyền. Trong app có nút **Mở Cài đặt** cùng hướng dẫn. Sau khi cấp quyền, quay về ô nhập đích rồi mở lại lịch sử; nếu trạng thái quyền chưa cập nhật, bấm **Kiểm tra lại** hoặc mở lại app. Bản build có chữ ký mới có thể cần được cấp lại quyền.

App ghi nhớ ứng dụng, cửa sổ và đối tượng nhập liệu Accessibility, không đọc văn bản của ứng dụng đích. Trước khi gửi Cmd+V, app khôi phục ứng dụng/cửa sổ và xác nhận đối tượng focus vẫn đúng; sự kiện được gửi tới PID cụ thể. Nếu app đích **không cho thấy ô nhập đang focus** (Chrome và các app Electron như Slack, Notion, Discord chỉ dựng thông tin đó khi có công cụ trợ năng bật chế độ riêng; app không bật chế độ này của app khác), app chuyển sang xác nhận ở mức **cửa sổ**: vẫn đúng ứng dụng và đúng cửa sổ đang focus thì mới gửi. Mức này yếu hơn: không xác nhận được ô nào nhận, nhưng panel của app không lấy focus nên ô bạn đang gõ vẫn giữ nguyên focus lúc bạn bấm. Nếu không xác nhận được cả ô lẫn cửa sổ thì không gửi gì. Nếu clipboard đã thay đổi trong lúc chờ, thao tác dán bị hủy. Clear All cũng hủy thao tác dán đang chờ.

Khi thiếu quyền, không có ứng dụng đích hoặc không khôi phục được focus an toàn, nội dung đã chọn vẫn nằm trong clipboard và giao diện hướng dẫn quay lại ứng dụng, nhấn **Cmd+V**. App chỉ thông báo **đã gửi Cmd+V**, vì macOS không cung cấp xác nhận rằng editor đã chấp nhận thao tác dán. Các editor có Secure Input, hộp nhập bị khóa hoặc hỗ trợ Accessibility không đầy đủ có thể cần dán thủ công. Không cần Automation, Screen Recording hay Input Monitoring. Riêng việc dán **file** có thể cần quyền đọc file, xem [Dán file từ Desktop, Documents, Downloads](#dán-file-từ-desktop-documents-downloads).

## Ghim và xóa từng mục

Mỗi mục có hai nút nhỏ ở bên phải: **ghim** (hình đinh ghim) và **xóa** (dấu ×).

- Mục đã ghim nổi lên đầu danh sách, có viền màu nhấn, và **không bị loại** khi lịch sử đầy hay khi có lần copy mới. Chỉ bỏ ghim, xóa mục đó hoặc Clear All mới làm nó biến mất.
- Tối đa **20 mục ghim** và không quá **một nửa tổng dung lượng** (mặc định 16 MiB trên 32 MiB), để lần copy mới luôn còn chỗ. Vượt giới hạn thì app báo và không ghim.
- Copy lại đúng nội dung của một mục đã ghim thì mục đó vẫn được ghim.
- Xóa một mục chỉ gỡ nó khỏi lịch sử, **không đổi clipboard hệ thống** (nếu mục đó đang nằm trong clipboard thì nó vẫn ở đó nhưng không bị lưu lại lần nữa). Lần ghi đĩa theo sau có debounce 350 ms như mọi thay đổi khác; nếu force quit trước đó, mục đã xóa có thể còn trong file.
- **Clear All xóa cả mục đã ghim.**
- Lịch sử lưu bởi bản 0.1.0 (chưa có ghim) vẫn mở bình thường, mọi mục coi như chưa ghim.

## Dán file từ Desktop, Documents, Downloads

macOS chỉ cho ứng dụng nhận (Chrome, Teams, Slack...) đọc các file trong clipboard khi **chính ứng dụng ghi clipboard đọc được các file đó**. Finder đọc được mọi nơi, còn Mac ClipBoard, trừ khi bạn cho phép, thì không đọc được file trong Desktop, Documents, Downloads, iCloud Drive hay ổ ngoài. Nếu không có quyền, ứng dụng nhận thấy clipboard rỗng và **không có gì xảy ra**: đã đo trên Chrome, cùng một file ở Desktop dán được khi người ghi có quyền và dán ra rỗng khi không. File ở chỗ không được bảo vệ (ví dụ `/private/tmp`) thì không bị ảnh hưởng.

- Lần đầu bạn bấm một mục file trong thư mục được bảo vệ, Mac ClipBoard thử **mở file để đọc** (không đọc nội dung) và macOS hiện hộp xin quyền *"Mac ClipBoard muốn truy cập các file trong thư mục Desktop"*. Bấm **Cho phép**; quyền được nhớ cho thư mục đó. Cần cấp lại mỗi khi cài một bản build mới (chữ ký ad-hoc đổi).
- Nếu bạn từ chối, app **không ghi đè clipboard** và báo rõ: "Mac ClipBoard chưa được phép đọc file này...". Cấp lại ở Cài đặt hệ thống → Quyền riêng tư & Bảo mật → **Tệp và thư mục** (hoặc **Toàn bộ ổ đĩa**), rồi chọn lại mục.
- Hộp xin quyền xuất hiện ngay trong lúc app chờ trả lời; giao diện vẫn phản hồi.

## Phím tắt

- **⇧⌘V** (mặc định) hiện lịch sử từ bất kỳ app nào, và bấm lần nữa để ẩn. Hiện lịch sử cũng ghi nhớ app đang ở phía trước làm nơi dán, nên quy trình nhanh là: **⇧⌘V → ↓ → Enter**.
- Đổi trong Cài đặt: **⇧⌘V** (mặc định), **⌃⌥V**, **⌃⌥⌘V** hoặc **Tắt**. Lưu ý ⇧⌘V cũng là "dán không định dạng" trong nhiều app (Chrome, Slack, Notes...); khi phím tắt đang bật, tổ hợp này thuộc về Mac ClipBoard trên toàn hệ thống và các app đó không nhận được nữa. Nếu bạn hay dùng "dán không định dạng", chọn ⌃⌥V hoặc ⌃⌥⌘V. Dòng trạng thái trong Cài đặt cho biết đã đăng ký được chưa; nếu app khác đang giữ tổ hợp đó thì app báo thay vì im lặng.
- Dùng `RegisterEventHotKey` của macOS: **không cần quyền nào thêm** (không Trợ năng, không Input Monitoring) và app chỉ được báo đúng tổ hợp đó, không thấy phím nào khác.
- Ở chế độ `--sandbox` hoặc `--test-system-clipboard` phím tắt bị tắt để không chiếm phím của bản đang dùng thật; thêm `--enable-hotkey` cùng `--sandbox` để thử có chủ đích.
- Rê chuột lên một mục thì mục đó có viền và nền nhạt để phân biệt; mục đang chọn bằng bàn phím có viền đậm hơn.

## Thumbnail ảnh và phím tắt trong danh sách

- Mục ảnh (PNG, TIFF) hiện **thumbnail** 56 pt thay cho biểu tượng. Thumbnail dựng bằng ImageIO ở luồng nền, **chỉ nằm trong bộ nhớ**, không ghi ra đĩa, và bị bỏ cùng mục khi xóa hoặc Clear All. Bytes ảnh lưu và khôi phục vẫn nguyên gốc. Ảnh khai báo quá 100 megapixel không có thumbnail (vẫn lưu và dán được).
- Khi cửa sổ lịch sử đang nhận phím: **↓/↑** chọn mục (lần đầu chọn mục trên cùng, dừng ở hai đầu), **Enter** dán mục đang chọn như khi bấm vào nó, **Esc** đóng cửa sổ. Mở lại cửa sổ thì bỏ chọn, nên Enter không bao giờ dán mục chưa được chọn rõ ràng.
- Khi bộ gõ tiếng Việt đang soạn chữ trong ô tìm kiếm (Telex/VNI), ↑↓ và Enter thuộc về bộ gõ, app không chặn.

## Cài đặt

Bấm biểu tượng bánh răng trên thanh công cụ, hoặc **Cài đặt…** trong menu chuột phải của biểu tượng thanh menu.

- **Số mục giữ lại:** 50, 100 (mặc định) hoặc 200. **Tổng dung lượng:** 16, 32 (mặc định) hoặc 64 MiB. Mỗi lần copy vẫn tối đa 8 MiB. Chỉ nhận các lựa chọn này: file cài đặt bị hỏng hoặc sửa tay thành giá trị lạ sẽ quay về mặc định.
- Hạ giới hạn **xóa ngay** các mục cũ nhất chưa ghim không còn vừa (mục ghim được giữ trước). Hộp Cài đặt ghi rõ số mục sẽ bị xóa trước khi bấm **Áp dụng**, và việc này không hoàn tác được. Nâng giới hạn không xóa gì.
- **Mở cùng lúc đăng nhập:** tắt mặc định, áp dụng ngay khi bật/tắt (không cần Áp dụng). Khi chạy lúc đăng nhập, app chỉ hiện biểu tượng thanh menu, không bật cửa sổ lịch sử; việc nhận biết này dựa vào sự kiện khởi động của macOS và **chưa được kiểm chứng trên một lần đăng nhập thật**. Nếu macOS yêu cầu, hãy cho phép trong Cài đặt hệ thống → Cài đặt chung → Mục đăng nhập. Nên cài app vào `/Applications` trước khi bật. Chức năng bị tắt khi chạy từ mã nguồn, hoặc ở chế độ `--sandbox`/`--test-system-clipboard`.

## Dữ liệu được hỗ trợ

| Nội dung | Cách lưu/khôi phục |
|---|---|
| Text UTF-8 | Giữ toàn bộ bytes, Unicode, xuống dòng và tab; chỉ preview bị giới hạn 320 ký tự/3 dòng |
| RTF, HTML | Giữ bytes gốc cùng text nếu nguồn có cung cấp; không render HTML hay tải tài nguyên từ mạng |
| PNG, TIFF | Giữ bytes ảnh gốc, không chuyển mã; hiển thị thumbnail, loại ảnh và kích thước dữ liệu |
| URL | Giữ định dạng URL gốc |
| File/Finder nhiều file | Đọc bằng `NSURL`, chuẩn hóa URL tham chiếu Finder thành URL đường dẫn ổn định và khôi phục bằng `writeObjects([NSURL])`; mỗi file vẫn là một file, không xuất tên/đường dẫn thay thế dưới dạng text |
| Định dạng riêng | Bỏ qua. Mục chỉ gắn cảnh báo "Một số định dạng riêng không được lưu" khi định dạng bị bỏ là **nội dung thật** (JPEG, HEIC, GIF, WebP, PDF, SVG, RTFD). Văn bản copy từ trình duyệt hay editor luôn kèm định dạng phụ (bản UTF-16, `org.chromium.*`, `dyn.*`...) nên không bị coi là mất gì. Nếu một item hoàn toàn không được hỗ trợ thì bỏ qua cả lần copy |
| File promise | Không tải/nhận file promise; nếu không có định dạng hỗ trợ thì thông báo không lưu được |

File là **tham chiếu**, nên file bị đổi tên, di chuyển hoặc xóa sau khi copy có thể không dán lại được. Mục chỉ gồm file **không bao giờ** hiện cảnh báo "Một số định dạng riêng không được lưu": Finder luôn kèm các định dạng cũ/động cho mỗi file được copy (không phải nội dung bị mất), và khôi phục qua `NSURL` tạo lại đúng các biểu diễn gốc. Cảnh báo chỉ còn dành cho text, ảnh... thật sự có định dạng bị bỏ. Ảnh/text quá lớn không bị chuyển thành dữ liệu khác để lách giới hạn. Clipboard có marker concealed/transient/autogenerated, gồm marker thông dụng của trình quản lý mật khẩu, bị bỏ qua trước khi đọc payload. Nội dung không có marker riêng tư vẫn được xử lý như clipboard bình thường.

Với file, AppKit cung cấp định dạng và thông tin truy cập cho ứng dụng đích; các file `.png`, `.pptx`, `.md` được chuyển như file đính kèm thay vì text tên file. Không đọc/chuyển mã nội dung file khi lưu lịch sử. Nếu một file không còn truy cập được, app báo không khôi phục được và giữ nguyên clipboard; không dán tên file thay thế hoặc chỉ dán một phần nhóm file. Lịch sử cũ có URL file hợp lệ cũng đi qua cơ chế native này. Mục lịch sử vốn chỉ chứa text sẽ tiếp tục là text; app không tự biến chuỗi đường dẫn thành thao tác tải file lên ứng dụng khác.

Lịch sử mới nhất đứng trước, các lần copy cùng payload được gộp lại. Việc app tự khôi phục một mục không tạo bản ghi mới. Clipboard rỗng không tạo item. App không đọc clipboard sẵn có lúc khởi động, không khôi phục các lần copy trước khi theo dõi và không thu thập nội dung trong lúc tạm dừng.

## Lưu trữ và Clear All

- Mặc định tối đa **100 mục**, **32 MiB** dữ liệu gốc tổng cộng (chỉnh được trong Cài đặt), **8 MiB** mỗi lần copy và 128 pasteboard items mỗi lần copy; mục cũ nhất chưa ghim bị loại khi vượt giới hạn.
- Lưu dưới `~/Library/Application Support/local.macclipboard.app/history.plist`, property list nhị phân, thư mục `0700`, file `0600`. Dữ liệu được lưu cục bộ **không mã hóa**. Cài đặt nằm cạnh đó trong `settings.plist` (không chứa nội dung clipboard); gỡ cài đặt chuyển cả hai vào Thùng rác.
- Ghi bằng actor, debounce 350 ms và atomic replacement; thoát app bình thường sẽ flush. Nếu bị force quit trước lần ghi, mục mới nhất có thể chưa lưu.
- Clear All làm trống UI ngay, xóa clipboard, hủy debounce và xóa file lịch sử. Mỗi yêu cầu ghi có revision; yêu cầu cũ hoặc cùng revision với lần xóa không thể tái tạo file. Không có tác vụ tải lịch sử cũ ghi đè kết quả xóa.
- Nếu không xóa được file, thử thay bằng archive rỗng. Nếu cả hai cách đều thất bại, báo lỗi rõ và tạm dừng theo dõi; người dùng cần thử Clear All lại. Không báo xóa thành công khi dữ liệu trên đĩa còn tồn tại.
- Nếu không đọc được archive, báo lỗi và tạm dừng; không âm thầm coi dữ liệu hỏng là lịch sử rỗng.
- Không gửi clipboard ra mạng, không telemetry, không ghi payload hoặc chi tiết lỗi chứa payload vào log.

## Kiểm thử an toàn

`Scripts/test.sh` chạy Swift Testing. Các test dùng clipboard trong bộ nhớ hoặc `NSPasteboard.withUniqueName()` và thư mục tạm; không đọc clipboard thật, UserDefaults thật hoặc lịch sử thật. Script chỉ thử lại lỗi macro `TestingMacros` đã biết của Command Line Tools; các lỗi khác được trả nguyên trạng.

`Scripts/mutate.py` kiểm tra chính bộ test: nó phá từng chốt an toàn (không ghi đè sau Clear All, từ chối nhóm file khi một file mất, các chốt gỡ cài đặt, giới hạn lịch sử...) và báo đột biến nào test không bắt được. Chi tiết cách dùng ở `CLAUDE.md`.

`Scripts/test.sh --filter FilePasteTests` kiểm tra riêng việc giữ file sau khi copy nội dung khác, lưu/mở lại lịch sử, tương thích URL tham chiếu cũ của Finder, không xuất text thay thế, từ chối cả nhóm nếu một file mất và giữ nguyên các chuỗi đường dẫn vốn là text. Các fixture đều được tạo trong thư mục tạm.

Bản xử lý file native đã được kiểm chứng với PNG, PPTX và Markdown trên trang nhận paste cục bộ trong Chrome, profile riêng: focus input → click mục file cũ trong app → app tự gửi Cmd+V → sự kiện paste nhận đủ ba `File`, không có `text/plain`, và nội dung file khớp nguyên bản. Phép thử này dùng dữ liệu tự tạo và không gửi lệnh dán bổ sung từ bộ kiểm thử.

Mở app cô lập hoàn toàn, chưa có dữ liệu mẫu:

```bash
open -n "build/Mac ClipBoard.app" --args --sandbox /private/tmp/macclipboard-sandbox
```

Chế độ này dùng pasteboard có tên riêng và thư mục được chỉ định, **chặn gửi Cmd+V tự động** để không vô tình dán clipboard thật vào ứng dụng khác. Không gọi `NSPasteboard.general` trong nhánh sandbox, và không đụng tới login item của máy. Thêm `--open-settings` để mở sẵn hộp Cài đặt (chỉ có tác dụng ở chế độ này).

Để kiểm chứng luồng native bằng dữ liệu tự tạo:

```bash
bash Scripts/build_fixture.sh
# Mở đường dẫn Clipboard Fixture.app do script in ra.
open -n "build/Mac ClipBoard.app" --args --test-system-clipboard /private/tmp/macclipboard-e2e
```

`--test-system-clipboard` chỉ nhận thư mục dưới `/tmp` hoặc `/private/tmp`, lưu lịch sử tại đó và **thay clipboard hệ thống bằng baseline tổng hợp mà không đọc/khôi phục nội dung cũ**. Chỉ dùng chế độ này khi chủ động kiểm thử. Fixture editor có hai nút Copy A/B và một editor trống; không mở file người dùng, không được đóng gói vào app phát hành.

Quy trình: bấm Copy A → chờ A xuất hiện → Copy B → xác nhận B đứng trước A → đặt con trỏ vào editor fixture → mở lịch sử → chọn A → xác nhận text A và định dạng HTML được dán. Khi chưa có Accessibility, kiểm tra thông báo và dùng Cmd+V tại fixture. Thoát/mở lại cùng đường dẫn tạm để kiểm tra lưu trữ; bấm Clear All rồi mở lại để kiểm tra dữ liệu không quay về.

## Kiến trúc

Giữ cách tổ chức của AppClean/MacClean: SwiftPM, macOS 14, AppKit + SwiftUI, không thư viện bên thứ ba.

| Target | Vai trò |
|---|---|
| `MacClipBoardCore` | Payload, giới hạn, trạng thái phiên, dedup, chống stale write, hủy dán; chỉ Foundation và protocol hiệu ứng |
| `MacClipBoardSystem` | NSPasteboard, timer 0,5 giây, lưu file bằng actor, Accessibility và CGEvent |
| `MacClipBoard` | AppModel ObservableObject, panel, thanh menu, UI Anh–Việt và wiring |
| `clipboard-fixture` | Editor phục vụ kiểm chứng bằng dữ liệu tổng hợp; không phát hành |

Giao diện dùng `ObservableObject` và binding tường minh như AppClean, tránh `@State` macro do môi trường chỉ có Command Line Tools. Panel không kích hoạt app tham khảo cách làm của ShelfDrop. Các app gốc không bị chỉnh sửa và không bị import thành dependency.

API macOS tham khảo: [NSPasteboard.changeCount](https://developer.apple.com/documentation/appkit/nspasteboard/changecount), [AXIsProcessTrustedWithOptions](https://developer.apple.com/documentation/applicationservices/1459186-axisprocesstrustedwithoptions), [CGEvent.postToPid](https://developer.apple.com/documentation/coregraphics/cgevent/posttopid(_:)).
