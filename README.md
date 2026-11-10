# Crown the Cub

Cờ thú trên bàn 3×4, làm bằng [Rive](https://rive.app). Mỗi bên có 4 quân. Bắt được Vua đối phương, hoặc đưa Vua của mình lên hàng cuối an toàn, là thắng.

**Chơi thử:** mở trang GitHub Pages của repo này (xem mục [Đưa lên GitHub Pages](#đưa-lên-github-pages)).

## Cách chơi

- **Chế độ:** chơi với máy (Dễ, Vừa, Khó) hoặc hai người chơi trên cùng một máy.
- **Cách đi:** mỗi quân đi 1 ô theo các hướng được chấm trên viền quân. Bật hoặc tắt các chấm này bằng ô tick "Hướng đi".
  - Vua: 8 hướng
  - Quân đi thẳng: lên, xuống, trái, phải
  - Quân đi chéo: 4 góc
  - Tốt: tiến 1 ô
  - Tốt phong cấp: 6 hướng, không đi chéo lùi
- **Bắt và thả quân:** quân bị bắt về khay của bên bắt. Đến lượt, có thể thả quân trong khay xuống ô trống thay cho việc đi quân.
- **Phong cấp:** Tốt đi vào hàng cuối sẽ phong cấp. Bị bắt thì trở lại làm Tốt.
- **Thắng:** bắt được Vua đối phương, hoặc đưa Vua lên hàng cuối và sống sót qua lượt kế tiếp.
- **Hoà:** cùng một thế cờ lặp lại 3 lần.

## Cấu trúc repo

```
.
├── index.html        Trang chơi game (GitHub Pages phục vụ thẳng file này)
├── myproject.riv     Bản build đã ký, file index.html tải và chạy
├── .nojekyll
└── project/          Mã nguồn Rive CLI
    ├── rive.yaml     Cấu hình project
    ├── scene.rml     Toàn bộ artboard, ViewModel, state machine
    ├── engine.luau   Luật chơi và bot (không phụ thuộc giao diện)
    ├── engine_test.luau  20 bài test luật
    ├── game.luau     Lượt đi, điều khiển, chuyển động quân, hiệu ứng
    ├── splash.luau   Các màn splash (phong cấp, bắt Vua)
    ├── Inter.ttf     Font chữ
    └── art/          Ảnh quân, nền menu, khung splash
```

## Chạy trên máy

Trình duyệt chặn tải file `.riv` khi mở thẳng `index.html`, nên cần một web server bất kỳ:

```bash
python3 -m http.server 8000
```

Sau đó mở `http://localhost:8000`.

## Đưa lên GitHub Pages

1. Đẩy repo lên GitHub.
2. Vào **Settings → Pages**, phần **Build and deployment**, chọn **Deploy from a branch**, nhánh `main`, thư mục `/ (root)`.
3. Sau khoảng một phút, game chạy ở `https://<tên-tài-khoản>.github.io/<tên-repo>/`.

## Phát triển tiếp

Cần [Rive CLI](https://rive.app/cli). Các lệnh chạy trong thư mục `project/`:

```bash
rive .              # mở cửa sổ xem trước, tự cập nhật khi sửa file
rive . --verify     # kiểm tra project biên dịch được
rive . --test       # chạy test luật trong engine_test.luau
```

### Cập nhật bản web

Web runtime chỉ chạy script đã được Rive ký, nên sau mỗi lần sửa phải build lại bằng `--publish` (cần `rive login`):

```bash
cd project
rive . --publish --output-dir=..
```

Lệnh này ghi đè `myproject.riv` ở thư mục gốc. Commit file đó là trang web cập nhật theo.

### Thay motion cho màn splash

Mỗi màn splash là một artboard riêng trong `scene.rml`:

| Artboard | Khi nào hiện |
|---|---|
| `Splash_Promote` | Tốt phong cấp |
| `Splash_Capture_Pawn` | Tốt bắt Vua |
| `Splash_Capture_Gold` | Tốt phong cấp bắt Vua |
| `Splash_Capture_Bishop` | Quân đi chéo bắt Vua |
| `Splash_Capture_Rook` | Quân đi thẳng bắt Vua |

Làm lại motion thoải mái trong Rive editor, chỉ cần giữ:

1. tên artboard, kích thước 390×844 (artboard vẽ phủ cả màn hình);
2. state machine mặc định chạy splash một lần;
3. một timeline tên `Splash`: game chờ đúng độ dài timeline này rồi mới đi tiếp.

ViewModel `SplashVM` có số `side` (0 là phe xanh ở dưới, 1 là phe đỏ ở trên), dùng nếu muốn motion đổi theo phe bắt.

## Ghi công

- Hình nhân vật, thiết kế giao diện và storyboard splash: tác giả repo.
- Font [Inter](https://rsms.me/inter/), giấy phép SIL Open Font License 1.1 (xem `project/Inter-LICENSE.txt`).
- Chạy bằng [Rive web runtime](https://github.com/rive-app/rive-wasm) (`@rive-app/webgl2`).
