# Photo Organizer for Windows

The macOS app's Windows twin: the same window, the same date rules and folder layout, the same models where models are
involved. Native C# / WPF on .NET 10; recognition runs on the graphics card through ONNX Runtime with DirectML (any
DirectX 12 card), or on the processor without one.

## Building

```powershell
.\build.ps1          # build\PhotoOrganizer-Windows\PhotoOrganizer.exe
.\build.ps1 run      # build and start
.\build.ps1 clean    # remove the Windows build output
```

`build.ps1` is in the repository root. It needs the .NET 10 SDK and installs it for the current user when it is missing
(no administrator rights). The result is one self-contained `PhotoOrganizer.exe`: nothing to install on the user's PC.
Releases are not built by hand: every push to `main` makes GitHub Actions build the macOS and the Windows app and
publish both in a new release (see the root README).

## How it maps onto the macOS app

| macOS | Windows |
|---|---|
| ImageIO / AVFoundation metadata | own EXIF reader (JPEG, TIFF, RAW) + the Windows Property System (HEIC, PNG, video…) |
| QuickLook thumbnails | the thumbnails File Explorer shows (`IShellItemImageFactory`) |
| Vision: labels, feature prints, salient objects | MobileCLIP-S0 (45 MB, downloaded on first use): labels from the macOS label list, vectors of the photo and its parts |
| Vision faces + ArcFace on MLX | YuNet (OpenCV) + the same ArcFace weights, turned into ONNX by the app (`Core/VitOnnx.cs`) |
| Nudity models on MLX / Core ML | the same three Hugging Face models, turned into ONNX the same way |
| MapKit | OpenStreetMap in the WebView2 built into Windows |
| `renamex_np(RENAME_EXCL)` | `MoveFileEx` without replace (`File.Move(…, overwrite: false)`) |

The labels' text vectors are computed once and shipped in `PhotoOrganizer/Resources/clip-labels.bin`, so the app needs
only MobileCLIP's image half; `Tools/make_clip_labels.py` regenerates them (Python with numpy, onnxruntime, tokenizers
and huggingface_hub).

The VK album download (Settings → VK) works as on the Mac: vk.ru opens in a window of the app (WebView2), the user
signs in there, and the token VK's own site uses is kept encrypted for the Windows user (DPAPI) in the data folder.

## Where things are kept

| Where | What |
|---|---|
| `%APPDATA%\Photo Organizer` | settings, what scans read from each file (`scans\`, so an interrupted scan goes on where it stopped), recognition results, dates set by hand, people's names, the move journal, the ONNX models built from downloaded weights, the VK sign-in |
| `%USERPROFILE%\.cache\huggingface\hub` | the downloaded models (the standard Hugging Face cache, shared with other tools) |

Setting `PHOTO_ORGANIZER_DATA` moves the first folder elsewhere (a portable copy, a test run).
