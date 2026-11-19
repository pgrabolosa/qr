# qr

A small macOS command-line tool that generates QR Codes as PNG, JPEG, TIFF, PDF, SVG, or text in the terminal.

```sh
qr --format=png --size=500px "https://www.apple.com/"
```

It's written in Swift. The QR encoder is written from scratch using only Foundation. Drawing uses CoreGraphics, and ImageIO saves the image formats. Command-line parsing uses Apple's [Swift Argument Parser](https://github.com/apple/swift-argument-parser).

## Requirements

- macOS 13 or later
- Swift 6 toolchain (Xcode 16+ or the Command Line Tools: `xcode-select --install`)
- Network access for the first build, so Swift Package Manager can download Swift Argument Parser

## Installation

The included `Makefile` builds a release binary with Swift Package Manager and installs it.

### Install to `/usr/local/bin`

```sh
git clone <repository-url> qr   # or download and unpack the sources
cd qr
make
sudo make install
```

Check that it works:

```sh
qr --help
```

### Install without `sudo`

Set `PREFIX` to a directory you own; the tool goes in `$PREFIX/bin`. Make sure that folder is on your `PATH`:

```sh
make install PREFIX=~/.local
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc   # if not already on PATH
```

### Makefile targets

| Command | What it does |
| --- | --- |
| `make` | Build the release binary |
| `make test` | Run the tests |
| `make install` | Build, then install to `$(PREFIX)/bin` (default `/usr/local/bin`) |
| `make uninstall` | Remove the installed binary (pass the same `PREFIX` you installed with) |
| `make universal` | Build one binary that runs on both Apple silicon and Intel Macs |
| `make clean` | Delete build products |

`DESTDIR` is supported for staged installs, e.g. by packaging scripts: `make install DESTDIR=/tmp/stage`.

### Without `make`

```sh
swift build -c release
sudo install "$(swift build -c release --show-bin-path)/qr" /usr/local/bin/qr
```

Swift Package Manager also has a built-in, still experimental, install command. It installs into `~/.swiftpm/bin`, which you need to add to your `PATH`:

```sh
swift package experimental-install
```

### Run without installing

```sh
swift run qr -f text "Hello"
```

### Uninstall

```sh
sudo make uninstall               # or: make uninstall PREFIX=~/.local
```

## Usage

```
qr [options] [text ...]
```

The text to encode comes from the arguments. Multiple arguments are joined with spaces. With no text (or `-`), `qr` reads from standard input and ignores a single trailing newline.

| Option | Description |
| --- | --- |
| `-f`, `--format <format>` | `png` (default), `jpeg`, `tiff`, `pdf`, `svg`, or `text`. When omitted, the format is taken from the `--output` file extension. |
| `-s`, `--size <size>` | Width and height, e.g. `500px` (default `512px`). Points for PDF; ignored for `text`. |
| `-o`, `--output <path>` | Output file, or `-` for standard output. |
| `-e`, `--ecc <ecc>` | Minimum error correction: `L` (~7%), `M` (~15%, default), `Q` (~25%), `H` (~30%). Raised automatically when that doesn't make the code bigger. |
| `-m`, `--margin <margin>` | Width of the white border (quiet zone) in modules (default `4`). |
| `--foreground`, `--fg <color>` | Color of the dark modules (default `black`). See [Colors](#colors). |
| `--background`, `--bg <color>` | Background color, or `transparent` for none (default `white`). See [Colors](#colors). |
| `-h`, `--help` | Show help. |

Long options accept their value either after a space or after `=` (`--size 500px` or `--size=500px`).

### Where the output goes

- With `--output`, the code is written to that file.
- Otherwise it goes to standard output, so you can redirect or pipe it.
- If standard output is a terminal and the format is binary (PNG, JPEG, TIFF, PDF), `qr` saves to `./qr.<ext>` instead and prints the file name.

### Examples

```sh
# PNG, 500×500 pixels (saved as ./qr.png when run in a terminal)
qr --format=png --size=500px "https://www.apple.com/"

# Choose the file name; the format comes from the extension
qr -o apple.pdf "https://www.apple.com/"

# Read from standard input
echo "Hello, world" | qr -f svg -o hello.svg
pbpaste | qr > clipboard.png

# Show the code right in the terminal
qr -f text "https://www.apple.com/"

# Wi-Fi network with high error correction
qr -e H -o wifi.png "WIFI:T:WPA;S:MyNetwork;P:secret;;"

# Red code on a transparent background
qr -o red.png --fg red --bg transparent "Hello, world!"
```

### Colors

`--fg` and `--bg` accept CSS color syntax:

| Syntax | Examples |
| --- | --- |
| Named colors (all 148 CSS names) | `red`, `navy`, `rebeccapurple` |
| Transparent | `transparent`, `clear` |
| Hex: `#RGB`, `#RGBA`, `#RRGGBB`, `#RRGGBBAA` | `#f00`, `#FF0000`, `#FFFFFF00` |
| `rgb()` / `rgba()` | `rgb(255, 0, 0)`, `rgba(255, 255, 255, 0.0)`, `rgb(255 0 0 / 50%)`, `rgb(100% 0% 0%)` |
| `hsl()` / `hsla()` | `hsl(0, 100%, 50%)`, `hsl(120deg 100% 25% / 0.5)` |

Names are case-insensitive, and the `#` on hex colors is optional. Quote colors containing `#`, spaces or parentheses in the shell.

```sh
qr -o my_qr.png --fg "#FF0000" --bg "#FFFFFF00" "Hello, world!"
qr -o my_qr.png --fg red --bg clear "Hello, world!"
qr -o my_qr.png --fg "rgb(255, 0, 0)" --bg "rgba(255, 255, 255, 0.0)" "Hello, world!"
```

Notes:

- PNG, TIFF, PDF and SVG keep transparency. JPEG has none, so a translucent background is composited over white.
- In the terminal (`-f text`), custom colors use 24-bit color escape codes, and a transparent background shows the terminal's own background.
- Scanners need dark modules on a lighter background. `qr` prints a warning when the contrast is low, or when the foreground is lighter than the background (inverted codes, which not every scanner reads).

### Exit status

| Code | Meaning |
| --- | --- |
| `0` | Success |
| `1` | Encoding or rendering error (e.g. text too long, size too small) |
| `64` | Invalid command-line usage |

## Development

```sh
swift build          # debug build
swift test           # run the tests
```

The tests decode every generated code with CoreImage's built-in QR detector. They cover all error-correction levels, all eight mask patterns, and a range of code sizes.

### Layout

| Path | Contents |
| --- | --- |
| `Sources/QRCore/QRCode.swift` | QR encoder: mode selection, Reed–Solomon error correction, module placement, masking |
| `Sources/QRCore/QRColor.swift` | CSS color parsing |
| `Sources/QRCore/Rendering.swift` | Output: CoreGraphics drawing, ImageIO for PNG/JPEG/TIFF, PDF, SVG, terminal text |
| `Sources/qr/QRCommand.swift` | Command-line interface (Swift Argument Parser) and I/O |
| `Tests/QRCoreTests/` | Tests |
| `Makefile` | Build, test, install and uninstall targets |
